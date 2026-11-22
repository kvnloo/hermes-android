// GPT-Live over WebRTC: the host's full-duplex voice mode
// (voice.voice_chat_mode: gpt-live, tools/voice_live.py).
//
// The phone holds the media session: a local peer with the mic track and the
// `oai-events` data channel. Its SDP offer goes to the host
// (POST /api/audio/voice-live/session), which exchanges it server-side so no
// provider key reaches the phone; the answer comes back and the remote track
// plays. The voice model owns listening and speaking. Every real request
// arrives as `session.delegation.created`; the phone runs it as a turn in its
// open chat and sends the agent's final message back as
// `session.commentary.append`, which the voice says aloud. Same contract as
// Hermes Desktop (apps/desktop/src/lib/voice-live.ts).
//
// [LiveCall] is the protocol (signalling, events, replies); [LivePeer] is the
// media stack, faked in tests; [FlutterWebRtcPeer] is the production peer.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'live_strings.dart';
import 'live_transport.dart';

// ── Data shapes ─────────────────────────────────────────────────────────────

/// `POST /api/audio/voice-live/session`: the provider's answer to our offer.
@immutable
class LiveSessionAnswer {
  const LiveSessionAnswer({this.sessionId, this.sdp});

  final String? sessionId;

  /// The SDP answer; null when the host returned no audio session.
  final String? sdp;

  /// Parses `{ok, session: {id}, transport: {type: "webrtc", sdp}}`.
  factory LiveSessionAnswer.fromJson(Map<String, dynamic> j) {
    final session = j['session'];
    final transport = j['transport'];
    final sdp = transport is Map ? transport['sdp'] : null;
    return LiveSessionAnswer(
      sessionId: session is Map ? session['id']?.toString() : null,
      sdp: sdp is String && sdp.trim().isNotEmpty ? sdp : null,
    );
  }
}

/// One prior chat turn seeding the voice model
/// (`{"type":"message","role":..,"content":[{type,text}]}`, web_models.py).
Map<String, Object?> liveHistoryMessage({
  required bool fromUser,
  required String text,
}) => {
  'type': 'message',
  'role': fromUser ? 'user' : 'assistant',
  'content': [
    {'type': fromUser ? 'input_text' : 'output_text', 'text': text},
  ],
};

/// Seed history from the chat's text turns: newest kept, bounded like
/// Desktop's `toLiveHistory` (24 messages, 6000 chars, 1200 per message).
List<Map<String, Object?>> liveHistoryFrom(
  List<LiveLine> turns, {
  int maxMessages = 24,
  int maxChars = 6000,
}) {
  final out = <Map<String, Object?>>[];
  var budget = maxChars;
  for (final turn in turns.reversed) {
    var text = turn.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) continue;
    if (text.length > 1200) text = text.substring(0, 1200);
    if (out.length >= maxMessages || budget - text.length < 0) break;
    budget -= text.length;
    out.insert(0, liveHistoryMessage(fromUser: turn.fromUser, text: text));
  }
  return out;
}

/// What the call reports to the controller.
sealed class LiveCallEvent {
  const LiveCallEvent();
}

/// The data channel is open (or the provider said `session.started`).
class LiveCallStarted extends LiveCallEvent {
  const LiveCallStarted();
}

/// `session.input_transcript.delta` (the user) or
/// `session.output_transcript.delta` (the voice).
class LiveCallTranscript extends LiveCallEvent {
  const LiveCallTranscript({required this.fromUser, required this.delta});
  final bool fromUser;
  final String delta;
}

/// `session.delegation.created`: run [prompt] as a turn in the chat.
class LiveCallDelegation extends LiveCallEvent {
  const LiveCallDelegation({required this.id, required this.prompt});
  final String id;

  /// What the user last said; the delegation itself carries no text.
  final String prompt;
}

/// `session.thinking.append` / `session.commentary.append` seen on the
/// channel: the voice is waiting on work.
class LiveCallWorking extends LiveCallEvent {
  const LiveCallWorking();
}

/// A non-fatal provider `error` event.
class LiveCallError extends LiveCallEvent {
  const LiveCallError(this.message);
  final String message;
}

/// The call is gone: `session.closed` from the provider ([lost] false) or the
/// transport dropped ([lost] true).
class LiveCallClosed extends LiveCallEvent {
  const LiveCallClosed({required this.reason, required this.lost});
  final String reason;
  final bool lost;
}

/// The mic permission was refused while opening the call.
class LiveCallMicDenied implements Exception {
  const LiveCallMicDenied();
}

/// Setup failed; [message] is the official wording to show.
class LiveCallSetupFailed implements Exception {
  const LiveCallSetupFailed(this.message);
  final String message;
  @override
  String toString() => message;
}

// ── Seams ───────────────────────────────────────────────────────────────────

/// The media stack: one peer with a mic track and one data channel.
abstract interface class LivePeer {
  /// Opens the mic, builds the peer (mic track + `oai-events` channel) and
  /// returns the local SDP offer once ICE gathering ends (or times out).
  /// Throws [LiveCallMicDenied] when the mic permission is refused.
  Future<String> offer();

  /// Applies the provider's SDP answer; remote audio then plays.
  Future<void> answer(String sdp);

  set onOpen(void Function() handler);
  set onMessage(void Function(String text) handler);
  set onLost(void Function() handler);

  /// Sends one text frame; false when the channel is not open.
  bool send(String text);

  /// Mute: the mic track stops carrying frames.
  void setMicEnabled(bool enabled);

  /// Stops tracks, closes the channel and the peer.
  Future<void> close();
}

// ── The call ────────────────────────────────────────────────────────────────

/// Vendor cap is 500 tokens per append; ~4 chars a token, with headroom.
const liveAppendCharLimit = 1400;

/// Splits a reply into append-sized chunks on sentence boundaries.
List<String> chunkForCommentary(String text, {int limit = liveAppendCharLimit}) {
  final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (clean.isEmpty) return const [];
  if (clean.length <= limit) return [clean];
  final chunks = <String>[];
  var current = '';
  for (final sentence in clean.split(RegExp(r'(?<=[.!?])\s+'))) {
    if (sentence.length > limit) {
      if (current.isNotEmpty) {
        chunks.add(current);
        current = '';
      }
      for (var i = 0; i < sentence.length; i += limit) {
        chunks.add(
          sentence.substring(
            i,
            i + limit > sentence.length ? sentence.length : i + limit,
          ),
        );
      }
      continue;
    }
    final candidate = current.isEmpty ? sentence : '$current $sentence';
    if (candidate.length > limit) {
      chunks.add(current);
      current = sentence;
    } else {
      current = candidate;
    }
  }
  if (current.isNotEmpty) chunks.add(current);
  return chunks;
}

/// One GPT-Live call: signalling through the host, events off the channel,
/// replies back onto it.
class LiveCall {
  LiveCall({required this.host, required LivePeer Function() peer})
    : _makePeer = peer;

  final LiveHost host;
  final LivePeer Function() _makePeer;

  LivePeer? _peer;
  void Function(LiveCallEvent event) _emit = (_) {};
  bool _started = false;
  bool _closed = false;
  int _eventCounter = 0;

  String? sessionId;

  /// Delegations the provider opened; replies to any other id are refused.
  final Set<String> _delegations = {};

  /// The spoken exchange so far, for the delegation prompt.
  final List<({bool fromUser, String text})> _turns = [];

  set onEvent(void Function(LiveCallEvent event) handler) => _emit = handler;

  bool get isOpen => _started && !_closed;

  /// Opens the mic and peer, exchanges SDP with the host, applies the answer.
  /// Completes once the answer is applied; [LiveCallStarted] follows when the
  /// channel opens. [turns] is the spoken exchange of an earlier call this
  /// one replaces, so a delegation right after a reconnect still finds the
  /// user's words.
  Future<void> connect({
    List<Map<String, Object?>> history = const [],
    List<({bool fromUser, String text})> turns = const [],
  }) async {
    if (_peer != null) throw StateError('GPT-Live is already started.');
    _turns.addAll(turns);
    final peer = _peer = _makePeer();
    peer
      ..onOpen = _markStarted
      ..onMessage = _handle
      ..onLost = () => _finish('connection_lost', lost: true);
    final String offer;
    try {
      offer = await peer.offer();
    } on LiveCallMicDenied {
      rethrow;
    } catch (_) {
      throw const LiveCallSetupFailed(LiveText.gptLiveNoConnection);
    }
    if (_closed) return;
    final LiveSessionAnswer answer;
    try {
      answer = await host.createSession(offer, history: history);
    } on LiveCallSetupFailed {
      rethrow;
    } catch (_) {
      throw const LiveCallSetupFailed(LiveText.gptLiveCouldNotConnect);
    }
    if (_closed) return;
    final sdp = answer.sdp;
    if (sdp == null) throw const LiveCallSetupFailed(LiveText.gptLiveNoSession);
    sessionId = answer.sessionId;
    try {
      await peer.answer(sdp);
    } catch (_) {
      throw const LiveCallSetupFailed(LiveText.gptLiveCouldNotConnect);
    }
  }

  void _markStarted() {
    if (_started || _closed) return;
    _started = true;
    _emit(const LiveCallStarted());
  }

  void _handle(String raw) {
    if (_closed) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    final event = decoded.cast<String, Object?>();
    switch (event['type']) {
      case 'session.started':
        final session = event['session'];
        if (session is Map && session['id'] != null) {
          sessionId = session['id'].toString();
        }
        _markStarted();
      case 'session.input_transcript.delta':
      case 'session.output_transcript.delta':
        final delta = event['delta'];
        if (delta is! String || delta.isEmpty) return;
        final fromUser = event['type'] == 'session.input_transcript.delta';
        if (_turns.isNotEmpty && _turns.last.fromUser == fromUser) {
          final last = _turns.removeLast();
          _turns.add((fromUser: fromUser, text: last.text + delta));
        } else {
          _turns.add((fromUser: fromUser, text: delta));
          if (_turns.length > 200) _turns.removeRange(0, 100);
        }
        _emit(LiveCallTranscript(fromUser: fromUser, delta: delta));
      case 'session.delegation.created':
        final delegation = event['delegation'];
        final id = delegation is Map ? delegation['id']?.toString() : null;
        if (id == null || id.isEmpty) return;
        _delegations.add(id);
        _emit(LiveCallDelegation(id: id, prompt: _prompt()));
      case 'session.thinking.append':
      case 'session.commentary.append':
        _emit(const LiveCallWorking());
      case 'error':
        final error = event['error'];
        final code = error is Map ? error['code'] : null;
        // Late appends after our own close are expected noise.
        if (code == 'context_injection_incomplete') return;
        final message = error is Map ? error['message']?.toString() : null;
        _emit(LiveCallError(message ?? LiveText.gptLiveError));
      case 'session.closed':
        final reason = event['reason']?.toString() ?? 'closed';
        // The provider's own word for a dropped primary/upstream connection.
        _finish(reason, lost: reason == 'connection_lost');
    }
  }

  /// The user's last words; else the tail of the exchange.
  String _prompt() {
    for (final turn in _turns.reversed) {
      if (!turn.fromUser) continue;
      final said = turn.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (said.isNotEmpty) return said;
    }
    final all = _turns
        .map((t) => t.text.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((t) => t.isNotEmpty)
        .join('\n');
    return all.length > 400 ? all.substring(all.length - 400) : all;
  }

  bool _send(Map<String, Object?> event) {
    final peer = _peer;
    if (peer == null || _closed) return false;
    return peer.send(jsonEncode(event));
  }

  String _nextId(String prefix) => '${prefix}_${++_eventCounter}';

  /// Whether [delegationId] is one the provider opened on this call.
  bool knows(String delegationId) => _delegations.contains(delegationId);

  /// Sends the agent's final message for [delegationId] as commentary the
  /// voice says aloud. False (nothing sent) for an unknown id or a closed
  /// channel.
  bool reply(String delegationId, String text) {
    if (!knows(delegationId)) return false;
    var sent = false;
    for (final chunk in chunkForCommentary(text)) {
      sent = _send({
        'type': 'session.commentary.append',
        'delegation_id': delegationId,
        'event_id': _nextId('say'),
        'content': chunk,
      });
      if (!sent) return false;
    }
    if (sent) _delegations.remove(delegationId);
    return sent;
  }

  /// Quiet progress for the voice ("Hermes finished without…").
  bool think(String delegationId, String text) {
    if (!knows(delegationId)) return false;
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) return false;
    final sent = _send({
      'type': 'session.thinking.append',
      'delegation_id': delegationId,
      'event_id': _nextId('think'),
      'content': clean.length > liveAppendCharLimit
          ? clean.substring(0, liveAppendCharLimit)
          : clean,
    });
    return sent;
  }

  /// A result for a delegation an earlier (lost) call opened: this session
  /// never knew that id, so it goes as session-wide commentary the voice
  /// says aloud.
  bool say(String text) {
    var sent = false;
    for (final chunk in chunkForCommentary(text)) {
      sent = _send({
        'type': 'session.commentary.append',
        'delegation_id': null,
        'event_id': _nextId('say'),
        'content': chunk,
      });
      if (!sent) return false;
    }
    return sent;
  }

  /// Quiet session-wide context (no delegation id): progress or a result
  /// for a delegation an earlier call opened.
  bool note(String text) {
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) return false;
    return _send({
      'type': 'session.thinking.append',
      'delegation_id': null,
      'event_id': _nextId('think'),
      'content': clean.length > liveAppendCharLimit
          ? clean.substring(0, liveAppendCharLimit)
          : clean,
    });
  }

  /// The spoken exchange so far, carried into a replacement call.
  List<({bool fromUser, String text})> get turns => List.of(_turns);

  /// Mute silences the mic track's frames.
  void setMuted(bool muted) => _peer?.setMicEnabled(!muted);

  /// Asks the provider to close, then tears the peer down.
  Future<void> close() async {
    if (_closed) return;
    _send({'type': 'session.close'});
    _closed = true;
    await _teardown();
  }

  void _finish(String reason, {required bool lost}) {
    if (_closed) return;
    _closed = true;
    unawaited(_teardown());
    _emit(LiveCallClosed(reason: reason, lost: lost));
  }

  Future<void> _teardown() async {
    try {
      await _peer?.close();
    } catch (_) {
      // Already gone.
    }
  }
}

// ── Link health ─────────────────────────────────────────────────────────────

/// Reads the peer's connection states into one "lost" signal.
///
/// `disconnected` is transient by design: ICE consent checks missed for a few
/// seconds (a Wi-Fi power-save nap, a cell handover, a busy CPU while a tool
/// drives the phone) and it usually comes back to `connected` by itself.
/// Treating it as fatal, as this client did, dropped calls that would have
/// recovered. Only `failed`/`closed`, or a `disconnected` that outlasts
/// [grace], counts as lost; [onLost] fires once.
class LiveLinkGuard {
  LiveLinkGuard({
    required this.onLost,
    this.grace = const Duration(seconds: 10),
  });

  final void Function() onLost;
  final Duration grace;
  Timer? _timer;
  bool _lost = false;
  bool _closed = false;

  bool get lost => _lost;

  /// Connected (again): a pending disconnect is forgiven.
  void connected() {
    _timer?.cancel();
    _timer = null;
  }

  void disconnected() {
    if (_lost || _closed || _timer != null) return;
    _timer = Timer(grace, _lose);
  }

  /// `failed`, `closed`, or the data channel closing: no way back.
  void failed() => _lose();

  void _lose() {
    _timer?.cancel();
    _timer = null;
    if (_lost || _closed) return;
    _lost = true;
    onLost();
  }

  /// Our own close: nothing after this is a loss.
  void close() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }
}

// ── Production peer ─────────────────────────────────────────────────────────

/// [LivePeer] over flutter_webrtc. Remote audio plays through the native
/// audio device; the speakerphone is turned on so the call is hands-free.
class FlutterWebRtcPeer implements LivePeer {
  static const _iceGatherLimit = Duration(seconds: 10);

  RTCPeerConnection? _pc;
  RTCDataChannel? _channel;
  MediaStream? _mic;
  bool _closed = false;
  late final LiveLinkGuard _link = LiveLinkGuard(
    onLost: () {
      if (!_closed) _onLost();
    },
  );

  void Function() _onOpen = () {};
  void Function(String) _onMessage = (_) {};
  void Function() _onLost = () {};

  @override
  set onOpen(void Function() handler) => _onOpen = handler;
  @override
  set onMessage(void Function(String text) handler) => _onMessage = handler;
  @override
  set onLost(void Function() handler) => _onLost = handler;

  @override
  Future<String> offer() async {
    try {
      _mic = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      });
    } catch (e) {
      if ('$e'.contains('NotAllowedError') || '$e'.contains('ermission')) {
        throw const LiveCallMicDenied();
      }
      rethrow;
    }
    final pc = _pc = await createPeerConnection({'sdpSemantics': 'unified-plan'});
    pc.onConnectionState = (state) {
      if (_closed) return;
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _link.connected();
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          _link.disconnected();
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _link.failed();
        default:
          break;
      }
    };
    for (final track in _mic!.getAudioTracks()) {
      await pc.addTrack(track, _mic!);
    }
    // Register the channel before the offer so its m-line is negotiated.
    final channel = _channel = await pc.createDataChannel(
      'oai-events',
      RTCDataChannelInit(),
    );
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) _onOpen();
      if (state == RTCDataChannelState.RTCDataChannelClosed && !_closed) {
        _link.failed();
      }
    };
    channel.onMessage = (message) {
      if (!message.isBinary) _onMessage(message.text);
    };
    final gathered = Completer<void>();
    pc.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !gathered.isCompleted) {
        gathered.complete();
      }
    };
    final offer = await pc.createOffer({});
    await pc.setLocalDescription(offer);
    // Trickle is fine: the provider answers with the candidates it has.
    await gathered.future.timeout(_iceGatherLimit, onTimeout: () {});
    final local = await pc.getLocalDescription();
    final sdp = local?.sdp;
    if (sdp == null || sdp.isEmpty) throw StateError('Missing local SDP offer');
    return sdp;
  }

  @override
  Future<void> answer(String sdp) async {
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    try {
      await Helper.setSpeakerphoneOn(true);
    } catch (_) {
      // Not every device routes; the call still plays.
    }
  }

  @override
  bool send(String text) {
    final channel = _channel;
    if (channel == null ||
        _closed ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return false;
    }
    unawaited(channel.send(RTCDataChannelMessage(text)).catchError((_) {}));
    return true;
  }

  @override
  void setMicEnabled(bool enabled) {
    for (final track in _mic?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _link.close();
    for (final track in _mic?.getTracks() ?? const <MediaStreamTrack>[]) {
      try {
        await track.stop();
      } catch (_) {}
    }
    try {
      await _mic?.dispose();
    } catch (_) {}
    try {
      await _channel?.close();
    } catch (_) {}
    try {
      await _pc?.close();
      await _pc?.dispose();
    } catch (_) {}
    _mic = null;
    _channel = null;
    _pc = null;
  }
}
