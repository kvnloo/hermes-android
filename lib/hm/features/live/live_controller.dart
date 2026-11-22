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
//
// When the host selects GPT-Live and can start it, the same states run off a
// WebRTC [LiveCall] instead: the voice model listens and speaks, its
// transcript deltas fill the transcript, each delegation is a turn in the
// chat (thinking) whose final message goes back on the data channel. A setup
// failure, or a setup slower than 35 s, falls back to the chained loop with
// a notice.
//
// Lanes (HA-035): with [lanes] set, fast / large / council lanes can be
// attached to the call's thread. [route] picks where the next turn goes: the
// bot's own chat (null) or one attached lane. Lane turns show in the
// transcript tagged with their lane, placed where they were asked.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'live_lanes.dart';
import 'live_strings.dart';
import 'live_transport.dart';
import 'live_webrtc.dart';

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
    this.call,
    this.lanes,
    this.setupLimit = const Duration(seconds: 35),
    this.callLimit = const Duration(minutes: 30),
    this.speakingHold = const Duration(milliseconds: 1500),
  }) {
    brain.addListener(_changed);
    lanes?.addListener(_lanesChanged);
  }

  final LiveHost host;
  final LiveEar ear;
  final LiveBrain brain;
  final LiveVoice voice;

  /// Builds the GPT-Live call when the host offers it; null keeps the call
  /// on the chained loop.
  final LiveCall Function()? call;

  /// The lanes this call can attach to its thread; null offers none.
  final LiveLanes? lanes;

  /// A GPT-Live call not up by then falls back to the chained loop.
  final Duration setupLimit;

  /// The longest a GPT-Live call runs.
  final Duration callLimit;

  /// How long after the voice's last transcript delta it still counts as
  /// speaking.
  final Duration speakingHold;

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

  // ── GPT-Live call state ──
  LiveCall? _call;

  /// The call is (or is being) carried over WebRTC.
  bool get webRtc => _call != null;
  bool _callUp = false;
  bool _botSpeaking = false;
  bool _working = false;
  Timer? _speakingTimer;
  Timer? _limitTimer;
  Completer<void>? _callStarted;
  final List<LiveLine> _callLines = [];
  final Set<String> _delegationsSeen = {};
  String? _activeDelegation;
  Future<void>? _turn;

  List<LiveLine> get lines =>
      _merge(webRtc ? List.of(_callLines) : brain.lines);

  // ── Lanes ──
  String? _target;

  /// The lane the next turn goes to; null is the bot's own chat.
  String? get target => _target;

  /// Lane turns, each placed after the first `at` lines of the main
  /// transcript.
  final List<({int at, LiveLine line})> _routed = [];
  int _routedSeq = 0;

  int get _mainCount => webRtc ? _callLines.length : brain.lines.length;

  List<LiveLine> _merge(List<LiveLine> main) {
    if (_routed.isEmpty) return main;
    final out = <LiveLine>[];
    var r = 0;
    for (var i = 0; i <= main.length; i++) {
      while (r < _routed.length && _routed[r].at <= i) {
        out.add(_routed[r++].line);
      }
      if (i < main.length) out.add(main[i]);
    }
    return out;
  }

  /// Name of attached lane [id], else [id].
  String laneName(String id) =>
      lanes?.lanes.where((l) => l.id == id).firstOrNull?.name ?? id;

  /// Sends the next turns to lane [id] (attached), or back to the bot (null).
  void route(String? id) {
    final next = id != null && lanes!.lanes.any((l) => l.id == id) ? id : null;
    if (next == _target) return;
    _target = next;
    _changed();
  }

  void _lanesChanged() {
    final t = _target;
    if (t != null && !lanes!.lanes.any((l) => l.id == t)) _target = null;
    _changed();
  }

  /// One turn to wherever [target] points. [echo] adds the asked text to the
  /// transcript (the chained loop; GPT-Live already shows what was said).
  Future<String> _ask(String text, {bool echo = true}) async {
    final lane = _target;
    if (lane == null) return brain.ask(text);
    if (echo) {
      _routed.add((
        at: _mainCount,
        line: LiveLine(
          key: 'lane-${_routedSeq++}',
          fromUser: true,
          text: text,
          lane: lane,
        ),
      ));
      _changed();
    }
    final reply = await lanes!.ask(lane, text);
    if (reply.trim().isNotEmpty) {
      _routed.add((
        at: _mainCount,
        line: LiveLine(
          key: 'lane-${_routedSeq++}',
          fromUser: false,
          text: reply.trim(),
          lane: lane,
        ),
      ));
      _changed();
    }
    return reply;
  }

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
    _stopCallTimers();
    unawaited(_call?.close());
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
    final status = hostStatus!;
    if (call != null && status.gptLiveSelected) {
      if (status.useWebRtc) {
        if (await _startCall(epoch)) return;
        if (epoch != _epoch || isOver) return;
      } else {
        notice = LiveText.gptLiveNotConfigured;
      }
    }
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
      reply = await _ask(said);
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

  // ── GPT-Live ──

  /// Opens the WebRTC call. True when the call is settled (up, or failed for
  /// good); false, with [notice] set, to fall back to the chained loop.
  Future<bool> _startCall(int epoch) async {
    final c = _call = call!();
    final started = _callStarted = Completer<void>();
    // Awaited below; a close during setup must not surface as uncaught.
    unawaited(started.future.catchError((Object _) {}));
    c.onEvent = (event) => _onCallEvent(c, event);
    try {
      await Future(() async {
        await c.connect(history: liveHistoryFrom(brain.lines));
        await started.future;
      }).timeout(setupLimit);
    } on LiveCallMicDenied {
      if (epoch == _epoch) _fail(LiveText.micOff);
      return true;
    } catch (e) {
      await c.close();
      if (!identical(_call, c)) return true;
      _call = null;
      _callLines.clear();
      if (epoch != _epoch || isOver) return true;
      notice = e is LiveCallSetupFailed
          ? e.message
          : LiveText.gptLiveCouldNotConnect;
      return false;
    }
    if (epoch != _epoch || isOver) {
      await c.close();
      return true;
    }
    _callUp = true;
    _limitTimer = Timer(callLimit, () => unawaited(end()));
    if (_muted) c.setMuted(true);
    _refreshCall();
    return true;
  }

  void _onCallEvent(LiveCall c, LiveCallEvent event) {
    if (!identical(_call, c) || _disposed) return;
    switch (event) {
      case LiveCallStarted():
        final started = _callStarted;
        if (started != null && !started.isCompleted) started.complete();
      case LiveCallTranscript(:final fromUser, :final delta):
        if (isOver) return;
        _addTranscript(fromUser, delta);
        _speakingTimer?.cancel();
        if (fromUser) {
          // The user talking over the voice cuts it off.
          _botSpeaking = false;
        } else {
          _working = false;
          _botSpeaking = true;
          _speakingTimer = Timer(speakingHold, () {
            _botSpeaking = false;
            _refreshCall();
          });
        }
        _refreshCall();
      case LiveCallDelegation():
        if (isOver) return;
        _delegate(c, event);
      case LiveCallWorking():
        _working = true;
        _refreshCall();
      case LiveCallError():
        notice = LiveText.gptLiveError;
        _changed();
      case LiveCallClosed(:final lost):
        final started = _callStarted;
        if (started != null && !started.isCompleted) {
          started.completeError(
            const LiveCallSetupFailed(LiveText.gptLiveCouldNotConnect),
          );
          return;
        }
        if (isOver) return;
        _fail(lost ? LiveText.gptLiveLost : LiveText.gptLiveClosed);
    }
  }

  void _addTranscript(bool fromUser, String delta) {
    final last = _callLines.lastOrNull;
    if (last != null && last.fromUser == fromUser) {
      _callLines[_callLines.length - 1] = LiveLine(
        key: last.key,
        fromUser: fromUser,
        text: '${last.text}$delta'.trimLeft(),
      );
    } else {
      final text = delta.trimLeft();
      if (text.isEmpty) return;
      _callLines.add(
        LiveLine(
          key: 'live-${_callLines.length}',
          fromUser: fromUser,
          text: text,
        ),
      );
    }
  }

  /// A delegation: run it as a turn in the chat and send the final message
  /// back. A newer delegation supersedes one still waiting (its reply is not
  /// spoken); a repeated id is ignored.
  void _delegate(LiveCall c, LiveCallDelegation d) {
    if (!_delegationsSeen.add(d.id)) return;
    _activeDelegation = d.id;
    _refreshCall();
    final previous = _turn;
    final turn = _turn = () async {
      if (previous != null) await previous;
      if (_activeDelegation != d.id) return;
      if (d.prompt.trim().isEmpty) {
        _settle(d.id);
        return;
      }
      final String reply;
      try {
        reply = await _ask(d.prompt, echo: false);
      } catch (e) {
        if (_activeDelegation != d.id) return;
        notice = '$e';
        c.reply(d.id, 'Sorry, I could not reach Hermes for that request.');
        _settle(d.id);
        return;
      }
      if (_activeDelegation != d.id) return;
      final spoken = reply.trim();
      if (spoken.isEmpty) {
        c.think(d.id, 'Hermes finished that request without a spoken result.');
      } else if (!c.reply(d.id, spoken) && !isOver) {
        notice = LiveText.gptLiveRepliesStopped;
      }
      _settle(d.id);
    }();
    unawaited(turn.catchError((Object _) {}));
  }

  void _settle(String id) {
    if (_activeDelegation == id) _activeDelegation = null;
    _refreshCall();
  }

  void _refreshCall() {
    if (!_callUp || isOver) {
      _changed();
      return;
    }
    _set(
      _botSpeaking
          ? LivePhase.speaking
          : (_activeDelegation != null || _working)
          ? LivePhase.thinking
          : _muted
          ? LivePhase.muted
          : LivePhase.listening,
    );
  }

  void _stopCallTimers() {
    // A setup still waiting for the channel gives up now.
    final started = _callStarted;
    if (started != null && !started.isCompleted) {
      started.completeError(
        const LiveCallSetupFailed(LiveText.gptLiveCouldNotConnect),
      );
    }
    _speakingTimer?.cancel();
    _limitTimer?.cancel();
    _speakingTimer = null;
    _limitTimer = null;
  }

  /// The mic button. While thinking or speaking it only takes effect when
  /// the call would next listen.
  void toggleMute() {
    if (isOver) return;
    if (webRtc) {
      _muted = !_muted;
      if (!_muted) {
        _paused = false;
        if (notice == LiveText.paused) notice = null;
      }
      _call!.setMuted(_muted);
      _refreshCall();
      return;
    }
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
    // On a GPT-Live call the user talks over the voice instead.
    if (_phase != LivePhase.speaking || webRtc) return;
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
    if (webRtc) {
      _call!.setMuted(true);
      _refreshCall();
      return;
    }
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
    _stopCallTimers();
    await Future.wait([
      ear.stop().catchError((Object _) {}),
      voice.stop().catchError((Object _) {}),
      if (_call != null) _call!.close().catchError((Object _) {}),
    ]);
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _stopCallTimers();
    unawaited(_call?.close());
    brain.removeListener(_changed);
    lanes?.removeListener(_lanesChanged);
    lanes?.dispose();
    ear.dispose();
    voice.dispose();
    brain.dispose();
    super.dispose();
  }
}
