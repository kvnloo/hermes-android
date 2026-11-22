// Fakes for the four live-call seams: every test drives the call by hand.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hermes_android/core/widgets/ephemeral_ui_card.dart';
import 'package:hermes_android/hm/features/live/live_controller.dart';
import 'package:hermes_android/hm/features/live/live_lanes.dart';
import 'package:hermes_android/hm/features/live/live_transport.dart';
import 'package:hermes_android/hm/features/live/live_webrtc.dart';

class FakeHost implements LiveHost {
  FakeHost({
    this.statusError,
    this.mode = 'chained',
    this.available = false,
    this.answer = const LiveSessionAnswer(
      sessionId: 'live_1',
      sdp: 'v=0 answer\r\n',
    ),
    this.sessionError,
  });
  Object? statusError;
  String mode;
  bool available;
  LiveSessionAnswer answer;
  Object? sessionError;
  int statusCalls = 0;

  /// Every `voice-live/session` request: the offer and the seed history.
  final List<({String sdp, List<Map<String, Object?>> history})> sessions = [];

  @override
  Future<LiveVoiceStatus> status() async {
    statusCalls++;
    if (statusError != null) throw statusError!;
    return LiveVoiceStatus(mode: mode, gptLiveAvailable: available);
  }

  @override
  Future<LiveSpeech> speak(String text) => throw UnimplementedError();

  @override
  Future<LiveSessionAnswer> createSession(
    String sdp, {
    List<Map<String, Object?>> history = const [],
  }) async {
    sessions.add((sdp: sdp, history: history));
    if (sessionError != null) throw sessionError!;
    return answer;
  }
}

/// A WebRTC peer driven by hand: no media, frames recorded.
class FakePeer implements LivePeer {
  FakePeer({this.offerError, this.openOnAnswer = true});
  Object? offerError;

  /// Open the data channel as soon as the answer is applied.
  bool openOnAnswer;

  String? appliedAnswer;
  bool micEnabled = true;
  bool closed = false;
  bool open = false;
  final List<Map<String, dynamic>> sent = [];

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
    if (offerError != null) throw offerError!;
    return 'v=0 offer\r\n';
  }

  @override
  Future<void> answer(String sdp) async {
    appliedAnswer = sdp;
    if (openOnAnswer) openChannel();
  }

  void openChannel() {
    open = true;
    _onOpen();
  }

  /// A server event arriving on the data channel.
  void event(Map<String, Object?> e) => _onMessage(jsonEncode(e));

  void raw(String frame) => _onMessage(frame);

  void lose() => _onLost();

  @override
  bool send(String text) {
    if (!open || closed) return false;
    sent.add(jsonDecode(text) as Map<String, dynamic>);
    return true;
  }

  @override
  void setMicEnabled(bool enabled) => micEnabled = enabled;

  @override
  Future<void> close() async {
    closed = true;
    open = false;
  }
}

class FakeEar implements LiveEar {
  FakeEar({this.access = LiveMicAccess.granted});
  LiveMicAccess access;
  int listens = 0;
  int stops = 0;
  void Function(String)? _partial;
  void Function(String)? _final;
  void Function(String)? _error;

  bool get listening => _final != null;

  @override
  Future<LiveMicAccess> open() async => access;

  @override
  Future<void> listen({
    required void Function(String text) onPartial,
    required void Function(String text) onFinal,
    required void Function(String message) onError,
  }) async {
    listens++;
    _partial = onPartial;
    _final = onFinal;
    _error = onError;
  }

  void hearPartial(String text) => _partial!(text);

  void hear(String text) {
    final f = _final!;
    _final = null;
    f(text);
  }

  void fail(String message) {
    final e = _error!;
    _final = null;
    e(message);
  }

  @override
  Future<void> stop() async {
    stops++;
    _final = null;
  }

  @override
  void dispose() {}
}

class FakeBrain extends ChangeNotifier implements LiveBrain {
  final List<LiveLine> shown = [];
  final List<String> asked = [];
  Completer<String>? _reply;

  @override
  String? activeTool;

  /// The running turn moves to [tool] (null: between tools).
  void useTool(String? tool) {
    activeTool = tool;
    notifyListeners();
  }

  @override
  List<LiveLine> get lines => List.of(shown);

  @override
  Future<String> ask(String text) {
    asked.add(text);
    shown.add(LiveLine(key: 'u${shown.length}', fromUser: true, text: text));
    notifyListeners();
    return (_reply = Completer<String>()).future;
  }

  void reply(String text) {
    shown.add(
      LiveLine(
        key: 'a${shown.length}',
        fromUser: false,
        text: text,
        cards: ephemeralUiFences(text),
      ),
    );
    notifyListeners();
    _reply!.complete(text);
  }

  void failTurn(String message) =>
      _reply!.completeError(LiveTurnFailed(message));
}

class FakeVoice implements LiveVoice {
  final List<String> spoken = [];
  int stops = 0;
  Completer<void>? _playing;
  @override
  bool onDevice = false;

  bool get playing => _playing != null && !_playing!.isCompleted;

  @override
  Future<void> speak(String text) {
    spoken.add(text);
    return (_playing = Completer<void>()).future;
  }

  void finish() => _playing!.complete();

  @override
  Future<void> stop() async {
    stops++;
    if (playing) _playing!.complete();
  }

  @override
  void dispose() {}
}

class LiveRig {
  LiveRig({
    FakeHost? host,
    FakeEar? ear,
    this.peer,
    this.setupLimit,
    this.redialPeer,
    this.progressEvery,
    this.reconnectDelays,
    this.lanes,
  }) : host = host ?? FakeHost(),
       ear = ear ?? FakeEar();
  final FakeHost host;
  final FakeEar ear;
  final FakeBrain brain = FakeBrain();
  final FakeVoice voice = FakeVoice();

  /// Set to give the call a GPT-Live (WebRTC) transport.
  final FakePeer? peer;
  final Duration? setupLimit;

  /// Builds the peer of each redial after the first call dropped; null
  /// reuses [peer].
  final FakePeer Function()? redialPeer;
  final Duration? progressEvery;
  final List<Duration>? reconnectDelays;

  /// Set to offer lanes on the call.
  final LiveLanes? lanes;
  LiveCall? call;

  /// Every call the controller built, oldest first.
  final List<LiveCall> calls = [];

  /// Every peer handed out, oldest first.
  final List<FakePeer> peers = [];

  LiveController build() => LiveController(
    host: host,
    ear: ear,
    brain: brain,
    voice: voice,
    call: peer == null
        ? null
        : () {
            final c = call = LiveCall(
              host: host,
              peer: () {
                final p = peers.isEmpty || redialPeer == null
                    ? peer!
                    : redialPeer!();
                peers.add(p);
                return p;
              },
            );
            calls.add(c);
            return c;
          },
    lanes: lanes,
    setupLimit: setupLimit ?? const Duration(seconds: 35),
    progressEvery: progressEvery ?? const Duration(seconds: 20),
    reconnectDelays:
        reconnectDelays ??
        const [
          Duration(seconds: 1),
          Duration(seconds: 2),
          Duration(seconds: 4),
          Duration(seconds: 8),
          Duration(seconds: 16),
        ],
  );
}
