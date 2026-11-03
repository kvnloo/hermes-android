import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'annotation_compose.dart';

/// The immutable annotation snapshot being delivered. Transport adapters attach
/// the image and JSON before invoking their one existing Hermes submit path.
final class AnnotationSendEnvelope {
  AnnotationSendEnvelope({
    required this.conversationId,
    required this.strokes,
    required this.segments,
    required this.screen,
    required this.createdAt,
    this.typed = '',
  }) : fingerprint = annotationFingerprint(strokes, segments),
       text = composeMessage(
         strokes: strokes,
         segments: segments,
         screen: screen,
         typed: typed,
       ),
       document = annotationDoc(
         strokes: strokes,
         segments: segments,
         screen: screen,
         createdAt: createdAt,
       );

  final String conversationId;
  final List<Stroke> strokes;
  final List<Segment> segments;
  final ScreenInfo screen;
  final int createdAt;
  final String typed;
  final String fingerprint;
  final String text;
  final Map<String, dynamic> document;
}

/// Includes every stroke coordinate, tool, pressure and time, plus original
/// timestamped segment data. Excludes snapshot creation time and unrelated UI.
String annotationFingerprint(List<Stroke> strokes, List<Segment> segments) {
  final document = annotationDoc(
    strokes: strokes,
    segments: segments,
    screen: const ScreenInfo(id: '', route: '', width: 1, height: 1),
    createdAt: 0,
  );
  return sha256.convert(utf8.encode(jsonEncode([
    document['strokes'],
    document['transcript'],
  ]))).toString();
}

final class AnnotationPendingTurn {
  const AnnotationPendingTurn({
    required this.turnId,
    required this.conversationId,
    required this.fingerprint,
    required this.mode,
  });

  final String turnId;
  final String conversationId;
  final String fingerprint;
  final String mode;

  Map<String, String> toJson() => {
    'turn_id': turnId,
    'conversation_id': conversationId,
    'fingerprint': fingerprint,
    'mode': mode,
  };

  static AnnotationPendingTurn fromJson(Object? raw) {
    if (raw is! Map ||
        raw['turn_id'] is! String ||
        (raw['turn_id'] as String).isEmpty ||
        raw['conversation_id'] is! String ||
        (raw['conversation_id'] as String).isEmpty ||
        raw['fingerprint'] is! String ||
        (raw['fingerprint'] as String).length != 64 ||
        !const ['steer', 'queue'].contains(raw['mode'])) {
      throw const FormatException('Unrecognized annotation pending receipt');
    }
    return AnnotationPendingTurn(
      turnId: raw['turn_id'] as String,
      conversationId: raw['conversation_id'] as String,
      fingerprint: raw['fingerprint'] as String,
      mode: raw['mode'] as String,
    );
  }
}

abstract interface class AnnotationPendingTurnStore {
  Future<AnnotationPendingTurn?> read();
  Future<void> write(AnnotationPendingTurn turn);
  Future<void> clearIfSame(AnnotationPendingTurn turn);
}

/// Only non-sensitive receipt metadata is persisted; no speech, credentials,
/// drawing, screenshot bytes or attachment payload is stored here.
class PreferencesAnnotationPendingTurnStore implements AnnotationPendingTurnStore {
  PreferencesAnnotationPendingTurnStore(this.key);
  final String key;

  @override
  Future<AnnotationPendingTurn?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return null;
    try {
      return AnnotationPendingTurn.fromJson(jsonDecode(raw));
    } catch (_) {
      // Corrupted persistence is not permission to send a duplicate.
      throw StateError('Annotation delivery receipt cannot be read. Keep the drawing and inspect the original turn.');
    }
  }

  @override
  Future<void> write(AnnotationPendingTurn turn) async {
    final prefs = await SharedPreferences.getInstance();
    final old = prefs.getString(key);
    if (old != null) {
      throw StateError('An annotation is already awaiting a receipt.');
    }
    final encoded = jsonEncode(turn.toJson());
    if (!await prefs.setString(key, encoded) ||
        prefs.getString(key) != encoded) {
      throw StateError('Annotation receipt could not be saved; nothing was sent.');
    }
  }

  @override
  Future<void> clearIfSame(AnnotationPendingTurn turn) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await read();
    if (current == null) return;
    if (current.turnId != turn.turnId ||
        current.conversationId != turn.conversationId ||
        current.fingerprint != turn.fingerprint) {
      throw StateError('A newer annotation owns this pending receipt.');
    }
    if (!await prefs.remove(key)) {
      throw StateError('Annotation receipt could not be cleared.');
    }
  }
}

enum AnnotationReceiptKind { pending, accepted, finalReply, failed }

final class AnnotationReceipt {
  const AnnotationReceipt(this.kind, {this.reply});
  final AnnotationReceiptKind kind;
  final String? reply;

  bool get confirmed =>
      kind == AnnotationReceiptKind.accepted ||
      kind == AnnotationReceiptKind.finalReply;
}

/// A reservation MUST provide the exact transport-owned turn ID before any
/// network submission. Its callback must not submit a second turn on retry.
final class AnnotationSendReservation {
  const AnnotationSendReservation({
    required this.turnId,
    required this.submitOnce,
    this.cancelUnsent,
  });
  final String turnId;
  final Future<AnnotationReceipt> Function() submitOnce;
  final void Function()? cancelUnsent;
}

/// Implemented using the existing chat owner's reservation/steer and durable
/// receipt stream, not a second WebSocket or HTTP client.
abstract interface class AnnotationSendPort {
  bool get isOnline;
  bool get hasRunningTurn;
  Future<AnnotationSendReservation> reserve({
    required AnnotationSendEnvelope envelope,
    required String mode,
  });
  Future<AnnotationReceipt> receipt(
    AnnotationPendingTurn pending, {
    required Duration timeout,
  });
}

final class AnnotationSendOutcome {
  const AnnotationSendOutcome({
    required this.turn,
    required this.receipt,
    required this.didDispatch,
  });
  final AnnotationPendingTurn turn;
  final AnnotationReceipt receipt;
  final bool didDispatch;
  bool get confirmed => receipt.confirmed;
}

/// Exactly-once dispatch for each drawing + speech fingerprint.
///
/// A lost acknowledgement, failed receipt, route switch or restart can only
/// inspect the old turn ID. It can NEVER call reserve/submit again. A caller
/// clears only the submitted strokes after [confirmed] and then acknowledges
/// their removal using [drawingCleared]; uncertain delivery keeps the drawing.
class AnnotationVoiceSendController {
  AnnotationVoiceSendController({
    required this.store,
    required this.port,
    this.receiptTimeout = const Duration(seconds: 30),
  });

  final AnnotationPendingTurnStore store;
  final AnnotationSendPort port;
  final Duration receiptTimeout;
  bool _busy = false;

  Future<AnnotationSendOutcome> send(AnnotationSendEnvelope envelope) async {
    if (_busy) {
      throw StateError('The original annotation send is still in progress.');
    }
    _busy = true;
    try {
      // Read BEFORE offline checks. Reconciliation never causes a new send.
      final existing = await store.read();
      if (existing != null) {
        if (existing.conversationId != envelope.conversationId) {
          throw StateError('An annotation is awaiting its original conversation receipt. Check that conversation.');
        }
        if (existing.fingerprint != envelope.fingerprint) {
          throw StateError('The drawing or speech changed while a delivery is unconfirmed. Both are kept; check the original turn.');
        }
        return AnnotationSendOutcome(
          turn: existing,
          receipt: await _receipt(existing),
          didDispatch: false,
        );
      }
      if (!port.isOnline) {
        throw StateError('Offline. Drawing and speech are kept; reconnect before sending.');
      }
      if (envelope.strokes.isEmpty &&
          envelope.segments.isEmpty &&
          envelope.typed.trim().isEmpty) {
        throw StateError('Add a stroke, speak, or type before sending.');
      }

      final mode = annotationSendMode(port.hasRunningTurn);
      final prepared = await port.reserve(envelope: envelope, mode: mode);
      if (prepared.turnId.trim().isEmpty) {
        throw StateError('No transport turn ID was reserved; nothing was sent.');
      }
      final pending = AnnotationPendingTurn(
        turnId: prepared.turnId,
        conversationId: envelope.conversationId,
        fingerprint: envelope.fingerprint,
        mode: mode,
      );
      // Durable write-ahead MUST complete before invoking the wire callback.
      // A failed write proves we never attempted the wire: release only the
      // local reservation so the original chat is not stuck preparing.
      try {
        await store.write(pending);
      } catch (_) {
        prepared.cancelUnsent?.call();
        rethrow;
      }

      // A normal Hermes submit may await an entire streamed response. Observe
      // its receipt concurrently; never mistake Future completion for an ack.
      final Future<AnnotationReceipt> submit =
          prepared.submitOnce().then<AnnotationReceipt>(
        (result) => result.kind == AnnotationReceiptKind.pending
            ? Completer<AnnotationReceipt>().future
            : result,
        onError: (Object _) =>
            const AnnotationReceipt(AnnotationReceiptKind.failed),
      );
      final observation = _receipt(pending);
      final received = await Future.any<AnnotationReceipt>([
        submit,
        observation,
      ]);
      return AnnotationSendOutcome(
        turn: pending,
        receipt: received,
        didDispatch: true,
      );
    } finally {
      _busy = false;
    }
  }

  Future<AnnotationReceipt> _receipt(AnnotationPendingTurn pending) async {
    try {
      return await port.receipt(
        pending,
        timeout: receiptTimeout,
      ).timeout(receiptTimeout);
    } on TimeoutException {
      return const AnnotationReceipt(AnnotationReceiptKind.pending);
    } catch (_) {
      // A missing/broken receipt is unknown, not a failed-to-send assertion.
      return const AnnotationReceipt(AnnotationReceiptKind.pending);
    }
  }

  /// Call only after removing the *submitted* ink and speech from local state.
  /// This is not a retry/re-send API.
  Future<void> drawingCleared(AnnotationPendingTurn acknowledged) async {
    await store.clearIfSame(acknowledged);
  }
}
