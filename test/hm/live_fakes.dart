// Fakes for the four live-call seams: every test drives the call by hand.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hermes_android/hm/features/live/live_controller.dart';
import 'package:hermes_android/hm/features/live/live_transport.dart';

class FakeHost implements LiveHost {
  FakeHost({this.statusError});
  Object? statusError;
  int statusCalls = 0;

  @override
  Future<LiveVoiceStatus> status() async {
    statusCalls++;
    if (statusError != null) throw statusError!;
    return const LiveVoiceStatus(mode: 'chained', gptLiveAvailable: false);
  }

  @override
  Future<LiveSpeech> speak(String text) => throw UnimplementedError();
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
  List<LiveLine> get lines => List.of(shown);

  @override
  Future<String> ask(String text) {
    asked.add(text);
    shown.add(LiveLine(key: 'u${shown.length}', fromUser: true, text: text));
    notifyListeners();
    return (_reply = Completer<String>()).future;
  }

  void reply(String text) {
    shown.add(LiveLine(key: 'a${shown.length}', fromUser: false, text: text));
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
  LiveRig({FakeHost? host, FakeEar? ear})
    : host = host ?? FakeHost(),
      ear = ear ?? FakeEar();
  final FakeHost host;
  final FakeEar ear;
  final FakeBrain brain = FakeBrain();
  final FakeVoice voice = FakeVoice();

  LiveController build() =>
      LiveController(host: host, ear: ear, brain: brain, voice: voice);
}
