// One live call as a state machine, apart from the widget so tests drive it
// with fakes:
//
//   connecting ─▶ listening ─(heard)─▶ thinking ─(reply)─▶ speaking ─▶ listening
//        │            │  ▲                                    │ (tap orb)
//        ▼            ▼  │ (unmute)                           ▼
//      failed        muted                                listening
//
// end() from any state ▶ ended. Like Hermes Desktop's voice conversation,
// ending stops the mic and the voice but leaves a running turn to finish,
// so its reply still lands in the chat.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'live_strings.dart';
import 'live_transport.dart';

enum LivePhase {
  connecting,
  listening,
  thinking,
  speaking,
  muted,
  ended,
  failed,
}

class LiveController extends ChangeNotifier {
  LiveController({
    required this.host,
    required this.ear,
    required this.brain,
    required this.voice,
  }) {
    brain.addListener(_changed);
  }

  final LiveHost host;
  final LiveEar ear;
  final LiveBrain brain;
  final LiveVoice voice;

  LivePhase _phase = LivePhase.connecting;
  LivePhase get phase => _phase;

  /// What the recognizer has heard so far of the current utterance.
  String partial = '';

  /// Why the call failed (official wording), set with [LivePhase.failed].
  String? failure;

  /// A passing message under the status line (a failed turn, background).
  String? notice;

  /// The host's selected engine, from voice-live/status.
  LiveVoiceStatus? hostStatus;

  bool _muted = false;
  bool get muted => _muted;

  bool _paused = false;
  bool _disposed = false;

  /// Fences every continuation: bumped whenever the mic or voice is cut.
  int _epoch = 0;
  int _earFailures = 0;

  List<LiveLine> get lines => brain.lines;

  bool get isOver => _phase == LivePhase.ended || _phase == LivePhase.failed;

  void _set(LivePhase phase) {
    _phase = phase;
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _fail(String message) {
    _epoch++;
    failure = message;
    partial = '';
    _set(LivePhase.failed);
    unawaited(ear.stop());
    unawaited(voice.stop());
  }

  Future<void> start() async {
    final epoch = _epoch;
    _set(LivePhase.connecting);
    try {
      hostStatus = await host.status();
    } on LiveNoVoiceApi {
      if (epoch == _epoch) _fail(LiveText.noVoiceApi);
      return;
    } catch (_) {
      if (epoch == _epoch) _fail(LiveText.reconnect);
      return;
    }
    if (epoch != _epoch) return;
    final LiveMicAccess access;
    try {
      access = await ear.open();
    } catch (_) {
      if (epoch == _epoch) _fail(LiveText.micCouldNotOpen);
      return;
    }
    if (epoch != _epoch) return;
    switch (access) {
      case LiveMicAccess.denied:
        _fail(LiveText.micOff);
      case LiveMicAccess.unavailable:
        _fail(LiveText.micCouldNotOpen);
      case LiveMicAccess.granted:
        _listen();
    }
  }

  void _listen() {
    if (isOver) return;
    if (_muted) {
      partial = '';
      _set(LivePhase.muted);
      return;
    }
    final epoch = ++_epoch;
    partial = '';
    _set(LivePhase.listening);
    unawaited(
      ear.listen(
        onPartial: (text) {
          if (epoch != _epoch) return;
          partial = text;
          _changed();
        },
        onFinal: (text) {
          if (epoch == _epoch) _heard(text);
        },
        onError: (_) {
          if (epoch != _epoch) return;
          if (++_earFailures >= 3) {
            _fail(LiveText.micCouldNotRestart);
          } else {
            _listen();
          }
        },
      ),
    );
  }

  Future<void> _heard(String text) async {
    final said = text.trim();
    if (said.isEmpty) {
      _listen();
      return;
    }
    _earFailures = 0;
    final epoch = ++_epoch;
    partial = '';
    notice = null;
    _set(LivePhase.thinking);
    String reply;
    try {
      reply = await brain.ask(said);
    } catch (e) {
      if (epoch != _epoch) return;
      notice = '$e';
      _listen();
      return;
    }
    if (epoch != _epoch) return;
    if (reply.trim().isEmpty || _paused) {
      _listen();
      return;
    }
    _set(LivePhase.speaking);
    try {
      await voice.speak(reply);
    } catch (_) {
      // The reply is in the transcript; carry on listening.
    }
    if (epoch != _epoch) return;
    notice = liveVoiceNotice(voice);
    _listen();
  }

  /// The mic button. While thinking or speaking it only takes effect when
  /// the call would next listen.
  void toggleMute() {
    if (isOver) return;
    _muted = !_muted;
    if (_muted) {
      if (_phase == LivePhase.listening) {
        _epoch++;
        partial = '';
        unawaited(ear.stop());
        _set(LivePhase.muted);
      } else {
        _changed();
      }
    } else {
      _paused = false;
      if (notice == LiveText.paused) notice = null;
      if (_phase == LivePhase.muted) {
        _listen();
      } else {
        _changed();
      }
    }
  }

  /// Tapping the orb while the bot speaks cuts it off and listens.
  Future<void> interrupt() async {
    if (_phase != LivePhase.speaking) return;
    _epoch++;
    await voice.stop();
    _listen();
  }

  /// The app went to the background: release the mic and the voice.
  void pause() {
    if (isOver || _paused) return;
    _paused = true;
    _muted = true;
    notice = LiveText.paused;
    if (_phase == LivePhase.listening || _phase == LivePhase.speaking) {
      _epoch++;
      partial = '';
      unawaited(ear.stop());
      unawaited(voice.stop());
      _set(LivePhase.muted);
    } else {
      _changed();
    }
  }

  /// Close: stop the mic and the voice; a running turn finishes in the chat.
  Future<void> end() async {
    if (_phase == LivePhase.ended) return;
    _epoch++;
    partial = '';
    _set(LivePhase.ended);
    await Future.wait([
      ear.stop().catchError((Object _) {}),
      voice.stop().catchError((Object _) {}),
    ]);
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    brain.removeListener(_changed);
    ear.dispose();
    voice.dispose();
    brain.dispose();
    super.dispose();
  }
}
