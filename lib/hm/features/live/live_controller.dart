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
// A long delegation keeps the voice informed: every [progressEvery], and
// whenever the agent starts a new tool, a quiet `session.thinking.append`
// says the work is still running, so the voice neither guesses ("still
// waiting…") nor sits on a delegation with no word from us. A call whose
// transport drops redials with backoff ([reconnectDelays]) and resumes from
// the transcript so far; a turn still running in the chat carries on, and
// its result is said on the new call (or queued until one is up).
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/widgets/ephemeral_ui_card.dart';

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
    this.setupLimit = const Duration(seconds: 35),
    this.callLimit = const Duration(minutes: 30),
    this.speakingHold = const Duration(milliseconds: 1500),
    this.progressEvery = const Duration(seconds: 20),
    this.reconnectDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
    ],
  }) {
    brain.addListener(_changed);
  }

  final LiveHost host;
  final LiveEar ear;
  final LiveBrain brain;
  final LiveVoice voice;

  /// Builds the GPT-Live call when the host offers it; null keeps the call
  /// on the chained loop.
  final LiveCall Function()? call;

  /// A GPT-Live call not up by then falls back to the chained loop.
  final Duration setupLimit;

  /// The longest a GPT-Live call runs.
  final Duration callLimit;

  /// How long after the voice's last transcript delta it still counts as
  /// speaking.
  final Duration speakingHold;

  /// How often a running delegation tells the voice it is still working.
  final Duration progressEvery;

  /// The wait before each redial of a dropped GPT-Live call; once they are
  /// spent the call fails with [LiveText.gptLiveLost].
  final List<Duration> reconnectDelays;

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

  /// The chat as it stood when the call began, to seed a redial.
  List<LiveLine> _seedLines = const [];
  bool _reconnecting = false;
  Timer? _redialTimer;
  Completer<bool>? _redialWait;
  final Set<Timer> _progressTimers = {};

  /// Results (and quiet notes) that finished while no call was up, said
  /// once one is.
  final List<({String text, bool quiet})> _undelivered = [];

  /// A dropped call is being redialled.
  bool get reconnecting => _reconnecting;

  /// Where each delegation's turn started in [brain]'s lines, so its tool
  /// rows can sit in the call's transcript at the point it was asked.
  final Map<String, int> _workFrom = {};

  List<LiveLine> get lines => webRtc ? _withWork() : brain.lines;

  /// The call's transcript with each work marker filled in from the chat:
  /// the tool calls of the replies its turn produced.
  List<LiveLine> _withWork() {
    final turns = brain.lines;
    final starts = [
      for (final line in _callLines)
        if (line.work) _workFrom[line.key.substring(5)] ?? turns.length,
    ];
    final out = <LiveLine>[];
    var n = 0;
    for (final line in _callLines) {
      if (!line.work) {
        out.add(line);
        continue;
      }
      final from = starts[n].clamp(0, turns.length);
      final to = (n + 1 < starts.length ? starts[n + 1] : turns.length).clamp(
        from,
        turns.length,
      );
      n++;
      final replies = [
        for (final turn in turns.sublist(from, to))
          if (!turn.fromUser) turn,
      ];
      final tools = [for (final r in replies) ...r.tools];
      final cards = [for (final r in replies) ...r.cards];
      if (tools.isEmpty && cards.isEmpty) continue;
      out.add(
        LiveLine(
          key: line.key,
          fromUser: false,
          text: '',
          tools: tools,
          cards: cards,
          work: true,
        ),
      );
    }
    return out;
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
    // A card is for the eyes: the voice says the rest.
    final spoken = withoutEphemeralUi(reply);
    if (spoken.isEmpty) {
      _listen();
      return;
    }
    _set(LivePhase.speaking);
    try {
      await voice.speak(spoken);
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
    _seedLines = brain.lines;
    final c = _call = call!();
    try {
      await _dial(c, history: liveHistoryFrom(_seedLines));
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

  /// Connects [c] and waits for its channel, within [setupLimit].
  Future<void> _dial(
    LiveCall c, {
    required List<Map<String, Object?>> history,
    List<({bool fromUser, String text})> turns = const [],
  }) async {
    final started = _callStarted = Completer<void>();
    // Awaited below; a close during setup must not surface as uncaught.
    unawaited(started.future.catchError((Object _) {}));
    c.onEvent = (event) => _onCallEvent(c, event);
    await Future(() async {
      await c.connect(history: history, turns: turns);
      await started.future;
    }).timeout(setupLimit);
  }

  /// The transport under a running call dropped: redial with backoff and
  /// resume from what was said. Running turns are left alone.
  Future<void> _reconnect(LiveCall lost) async {
    if (_reconnecting) return;
    _reconnecting = true;
    _callUp = false;
    _botSpeaking = false;
    _working = false;
    _speakingTimer?.cancel();
    final epoch = _epoch;
    final turns = lost.turns;
    notice = LiveText.gptLiveReconnecting;
    _set(LivePhase.connecting);
    bool gone() => _disposed || isOver || epoch != _epoch;
    for (final delay in reconnectDelays) {
      if (!await _pause(delay) || gone()) {
        _reconnecting = false;
        return;
      }
      final c = _call = call!();
      try {
        await _dial(
          c,
          history: liveHistoryFrom([..._seedLines, ..._callLines]),
          turns: turns,
        );
      } on LiveCallMicDenied {
        _reconnecting = false;
        if (!gone()) _fail(LiveText.micOff);
        return;
      } catch (_) {
        await c.close();
        if (gone()) {
          _reconnecting = false;
          return;
        }
        continue;
      }
      if (gone()) {
        _reconnecting = false;
        await c.close();
        return;
      }
      _reconnecting = false;
      _callUp = true;
      if (_muted) c.setMuted(true);
      if (notice == LiveText.gptLiveReconnecting) notice = null;
      _flushUndelivered(c);
      _refreshCall();
      return;
    }
    _reconnecting = false;
    if (!gone()) _fail(LiveText.gptLiveLost);
  }

  /// Waits [delay]; false when the call was torn down meanwhile.
  Future<bool> _pause(Duration delay) {
    final done = _redialWait = Completer<bool>();
    _redialTimer = Timer(delay, () {
      if (!done.isCompleted) done.complete(true);
    });
    return done.future;
  }

  void _flushUndelivered(LiveCall c) {
    final pending = List.of(_undelivered);
    _undelivered.clear();
    for (final item in pending) {
      if (item.quiet) {
        c.note(item.text);
      } else {
        c.say(item.text);
      }
    }
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
        if (lost && _callUp && reconnectDelays.isNotEmpty) {
          unawaited(_reconnect(c));
          return;
        }
        _fail(lost ? LiveText.gptLiveLost : LiveText.gptLiveClosed);
    }
  }

  void _addTranscript(bool fromUser, String delta) {
    final last = _callLines.lastOrNull;
    if (last != null && !last.work && last.fromUser == fromUser) {
      _callLines[_callLines.length - 1] = LiveLine(
        key: last.key,
        fromUser: fromUser,
        text: '${last.text}$delta'.trimLeft(),
      );
    } else {
      final text = delta.trimLeft();
      if (text.isEmpty) return;
      _callLines.add(
        LiveLine(key: 'live-${_callLines.length}', fromUser: fromUser, text: text),
      );
    }
  }

  /// A delegation: run it as a turn in the chat and send the final message
  /// back. A newer delegation supersedes one still queued (it never runs);
  /// one already running finishes, and its result reaches the voice as
  /// quiet context instead of being dropped. A repeated id is ignored.
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
      _workFrom[d.id] = brain.lines.length;
      _callLines.add(
        LiveLine(key: 'work-${d.id}', fromUser: false, text: '', work: true),
      );
      _changed();
      final stopProgress = _progress(c, d.id);
      final String reply;
      try {
        reply = await brain.ask(d.prompt);
      } catch (e) {
        stopProgress();
        if (_activeDelegation != d.id) return;
        notice = '$e';
        _deliver(c, d.id, 'Sorry, I could not reach Hermes for that request.');
        _settle(d.id);
        return;
      }
      stopProgress();
      // Cards show in the transcript; the voice gets the words around them.
      final spoken = withoutEphemeralUi(reply);
      final carded = spoken.isEmpty && ephemeralUiFences(reply).isNotEmpty;
      if (_activeDelegation != d.id) {
        if (spoken.isNotEmpty) {
          _deliver(
            c,
            d.id,
            'Result of an earlier request: $spoken',
            quiet: true,
          );
        }
        return;
      }
      if (spoken.isEmpty) {
        _deliver(
          c,
          d.id,
          carded
              ? 'Hermes put the answer on screen as a card.'
              : 'Hermes finished that request without a spoken result.',
          quiet: true,
        );
      } else if (!_deliver(c, d.id, spoken) && !isOver) {
        notice = LiveText.gptLiveRepliesStopped;
      }
      _settle(d.id);
    }();
    unawaited(turn.catchError((Object _) {}));
  }

  /// Sends [text] for delegation [id], opened on [origin]: on that call while
  /// it is up, else (it dropped and a new one is up) as session-wide context
  /// on the new one, else queued for the next call. [quiet] sends thinking,
  /// which the voice uses without saying it.
  bool _deliver(LiveCall origin, String id, String text, {bool quiet = false}) {
    if (isOver) return false;
    final now = _call;
    if (!_callUp || now == null) {
      if (_reconnecting) {
        _undelivered.add((text: text, quiet: quiet));
        return true;
      }
      return false;
    }
    if (identical(now, origin)) {
      return quiet ? origin.think(id, text) : origin.reply(id, text);
    }
    return quiet ? now.note(text) : now.say(text);
  }

  /// While delegation [id] runs: a quiet progress note every [progressEvery]
  /// and whenever the agent moves to another tool. Returns the stopper.
  void Function() _progress(LiveCall origin, String id) {
    String? lastTool;
    void tell(String text) {
      if (!_callUp || isOver) return;
      final now = _call;
      if (now == null) return;
      if (identical(now, origin)) {
        origin.think(id, text);
      } else {
        now.note('An earlier request is still running. $text');
      }
    }

    void onBrain() {
      final tool = brain.activeTool;
      if (tool == null || tool == lastTool) return;
      lastTool = tool;
      tell('Hermes is working: $tool. Not done yet.');
    }

    final timer = Timer.periodic(progressEvery, (_) {
      final tool = brain.activeTool;
      tell(
        tool == null
            ? 'Hermes is still working on that. Not done yet.'
            : 'Hermes is still working: $tool. Not done yet.',
      );
    });
    _progressTimers.add(timer);
    brain.addListener(onBrain);
    return () {
      timer.cancel();
      _progressTimers.remove(timer);
      brain.removeListener(onBrain);
    };
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
    _redialTimer?.cancel();
    _redialTimer = null;
    final wait = _redialWait;
    if (wait != null && !wait.isCompleted) wait.complete(false);
    for (final timer in _progressTimers) {
      timer.cancel();
    }
    _progressTimers.clear();
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
    ear.dispose();
    voice.dispose();
    brain.dispose();
    super.dispose();
  }
}
