import 'dart:async';

import '../services/desktop_gateway_client.dart';
import '../services/normal_gateway_application_session.dart';
import 'annotation_voice_send.dart';

/// Uses the app-owned normal gateway chat: its reservation creates the sole
/// turn ID and its durable pending journal owns the actual submit. This class
/// never opens another transport or uses a REST fallback that could double-send.
class NormalGatewayAnnotationSendPort implements AnnotationSendPort {
  NormalGatewayAnnotationSendPort({
    required this.chat,
    required this.preparePrompt,
  });

  final NormalGatewayChatOwner chat;

  /// Uploads the annotated PNG and JSON through the existing attachment
  /// service, returning the message with gateway file references appended.
  /// Called only after AnnotationVoiceSendController saved the pending turn.
  final Future<String> Function(AnnotationSendEnvelope envelope) preparePrompt;

  @override
  bool get isOnline =>
      chat.snapshot.connectionState == DesktopConnectionState.connected;

  @override
  bool get hasRunningTurn => chat.snapshot.hasActiveTurn;

  @override
  Future<AnnotationSendReservation> reserve({
    required AnnotationSendEnvelope envelope,
    required String mode,
  }) async {
    if (mode == 'steer') {
      final id = chat.snapshot.turnId;
      if (id == null || !chat.canSteer) {
        throw StateError('This running turn cannot accept annotations.');
      }
      return AnnotationSendReservation(
        turnId: id,
        submitOnce: () async {
          final prompt = await preparePrompt(envelope);
          final accepted = await chat.steer(prompt);
          return AnnotationReceipt(
            accepted
                ? AnnotationReceiptKind.accepted
                : AnnotationReceiptKind.failed,
          );
        },
      );
    }
    if (mode != 'queue') throw ArgumentError.value(mode, 'mode');
    final reservation = chat.reserve();
    final id = chat.snapshot.turnId;
    if (reservation == null || id == null) {
      throw StateError('The gateway cannot reserve the annotation turn.');
    }
    return AnnotationSendReservation(
      turnId: id,
      submitOnce: () async {
        final prompt = await preparePrompt(envelope);
        await chat.submitPrepared(
          reservation: reservation,
          text: prompt,
          localContent: envelope.text,
          knownStoredSessionId: chat.storedSessionId,
          canRestoreDraft: false,
        );
        // Completing the submission RPC is not an assistant receipt.
        return const AnnotationReceipt(AnnotationReceiptKind.pending);
      },
    );
  }

  @override
  Future<AnnotationReceipt> receipt(
    AnnotationPendingTurn pending, {
    required Duration timeout,
  }) {
    final completed = Completer<AnnotationReceipt>();
    Object? subscription;
    Timer? deadline;
    void inspect(NormalGatewayChatSnapshot snapshot) {
      if (completed.isCompleted || snapshot.turnId != pending.turnId) return;
      // Server-terminal proof is decisive for queued sends.
      final terminal = snapshot.terminal;
      if (pending.mode == 'queue' &&
          terminal != null &&
          terminal.turnId == pending.turnId) {
        completed.complete(
          AnnotationReceipt(
            terminal.completed == true
                ? AnnotationReceiptKind.finalReply
                : AnnotationReceiptKind.failed,
            reply: terminal.publicFinalText,
          ),
        );
        return;
      }
      if (pending.mode == 'steer') {
        // Existing assistant output belongs to the *original* running turn,
        // not this annotation. Only a confirmed steer row proves its receipt.
        final accepted = snapshot.displayRows.any(
          (row) => row['display_kind'] == 'steer' &&
              row['content'] is String &&
              (row['content'] as String).contains('Annotated '),
        );
        if (accepted) {
          completed.complete(
            const AnnotationReceipt(AnnotationReceiptKind.accepted),
          );
        }
        return;
      }
      // A local queued/preparing marker is never remote acceptance. An actual
      // assistant reply from the current turn is sufficient positive proof.
      if (snapshot.wireEmitted &&
          snapshot.displayRows.any(
            (row) => row['role'] == 'assistant' &&
                row['content'] is String &&
                (row['content'] as String).trim().isNotEmpty,
          )) {
        completed.complete(
          const AnnotationReceipt(AnnotationReceiptKind.accepted),
        );
      }
    }

    subscription = chat.subscribe(inspect);
    inspect(chat.snapshot);
    deadline = Timer(timeout, () {
      if (!completed.isCompleted) {
        completed.complete(const AnnotationReceipt(AnnotationReceiptKind.pending));
      }
    });
    return completed.future.whenComplete(() {
      deadline?.cancel();
      if (subscription != null) chat.unsubscribe(subscription!);
    });
  }
}
