// Live Mode: a compact voice bubble or an immersive focus view, with a
// translucent bot pill at the top, a glowing orb, one status line,
// the call's transcript (You in muted italics, the bot in full text) and two
// dark round mic + close buttons at the bottom. The call runs over GPT-Live
// (WebRTC) when the host offers it, else the chained loop.
//
// With lanes (HA-035) the bot's orb is orbited by one small orb per lane
// attached to the thread (fast, large, council). Tapping a lane orb sends the
// next turns to that lane; tapping the bot's orb brings them back.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;

import '../../../core/services/android_voice_composer_adapter.dart';
import '../../../core/services/connection_mutation_barrier.dart';
import '../../../core/ephemeral/ephemeral_fence.dart';
import '../../../core/widgets/markdown_code_block.dart';
import '../../../nextgen/data/chat_controller.dart';
import '../../../nextgen/nextgen_preferences.dart';
import '../../../nextgen/theme/nextgen_theme.dart';
import '../../../nextgen/ui/chat_view.dart' show NgInputPanel;
import '../../../nextgen/ui/tool_rows.dart';
import '../../../shared_ui/glide_theme.dart';
import '../../avatar/hm_avatar.dart';
import '../../avatar/hm_avatar_state.dart';
import '../../hm_bots.dart';
import '../../hm_ui.dart';
import 'live_controller.dart';
import 'live_lanes.dart';
import 'live_strings.dart';
import 'live_transport.dart';
import 'live_webrtc.dart';

Future<void> openHmLive(
  BuildContext context, {
  required HmBot bot,
  required HmBotsModel bots,
  required NgChatController chat,
}) {
  final host = DashboardLiveHost(bots.gateway.dashboard, profile: bot.scope);
  LiveController create() => LiveController(
    host: host,
    ear: DeviceLiveEar(createVoiceComposerAdapter()),
    brain: ChatLiveBrain(chat),
    voice: HostLiveVoice(host),
    call: () => LiveCall(host: host, peer: FlutterWebRtcPeer.new),
    // No gateway RPC drives lanes yet: only fixture builds offer them.
    lanes: kLiveLanesFixture ? FixtureLiveLanes() : null,
  );
  final navigator = Navigator.of(context);
  final owner = context.findAncestorStateOfType<_HmLiveHostState>();
  return owner?.open(navigator, bot, chat, create) ??
      navigator.push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => HmLiveScreen(bot: bot, chat: chat, create: create),
        ),
      );
}

/// One foreground call per connected NextGen navigator. Routes only present
/// the call; dismissing one does not release the microphone or chat.
class HmLiveHost extends StatefulWidget {
  const HmLiveHost({
    super.key,
    required this.connectionId,
    required this.child,
  });

  final String connectionId;
  final Widget child;

  @override
  State<HmLiveHost> createState() => _HmLiveHostState();
}

class _HmLiveHostState extends State<HmLiveHost> with WidgetsBindingObserver {
  _HostedCall? _call;
  Future<void>? _ending;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ConnectionMutationBarrier.addListener(_accountChanged);
  }

  Future<void> open(
    NavigatorState navigator,
    HmBot bot,
    NgChatController chat,
    LiveController Function() create,
  ) async {
    if (_ending != null ||
        ConnectionMutationBarrier.isPending(widget.connectionId)) {
      return;
    }
    final existing = _call;
    if (existing != null) {
      _show(existing);
      return;
    }
    final call = _HostedCall(navigator, bot, chat, create());
    setState(() => _call = call);
    unawaited(call.live.start());
    _show(call);
  }

  void _show(_HostedCall call) {
    if (call.route != null || !call.navigator.mounted) return;
    late final MaterialPageRoute<void> route;
    void minimize() {
      if (route.isCurrent) call.navigator.pop();
    }

    route = MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => HmLiveScreen._hosted(
        bot: call.bot,
        chat: call.chat,
        controller: call.live,
        minimize: minimize,
        end: _end,
      ),
    );
    setState(() => call.route = route);
    unawaited(call.navigator.push(route));
    unawaited(
      route.completed.then((_) {
        if (mounted && identical(_call, call)) {
          setState(() => call.route = null);
        }
      }),
    );
  }

  void _accountChanged() {
    if (ConnectionMutationBarrier.isPending(widget.connectionId)) {
      unawaited(_end());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_end());
    }
  }

  Future<void> _end() {
    final call = _call;
    if (call == null) return _ending ?? Future<void>.value();
    setState(() => _call = null);
    final route = call.route;
    if (route != null && route.isActive) call.navigator.removeRoute(route);
    return _ending = call
        .finish(route?.completed)
        .whenComplete(() => _ending = null);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ConnectionMutationBarrier.removeListener(_accountChanged);
    final call = _call;
    _call = null;
    if (call != null) unawaited(call.finish());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final call = _call;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (call != null && call.route == null)
          PositionedDirectional(
            top: MediaQuery.paddingOf(context).top + 72,
            end: MediaQuery.paddingOf(context).horizontal + 12,
            child: ListenableBuilder(
              listenable: Listenable.merge([call.live, call.chat]),
              builder: (context, _) => Tooltip(
                message: 'Return to live call',
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _show(call),
                    child: Badge(
                      isLabelVisible: call.chat.request != null,
                      child: _GlowOrb(
                        bot: call.bot,
                        state: _liveAvatar(call.live),
                        size: 48,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _HostedCall {
  _HostedCall(this.navigator, this.bot, this.chat, this.live)
    : _releaseChat = chat.retain();

  final NavigatorState navigator;
  final HmBot bot;
  final NgChatController chat;
  final LiveController live;
  final VoidCallback _releaseChat;
  MaterialPageRoute<void>? route;

  Future<void> finish([Future<void>? unmount]) async {
    try {
      await live.end();
      await unmount;
    } finally {
      live.dispose();
      _releaseChat();
    }
  }
}

HmAvatarState _liveAvatar(LiveController live) => switch (live.phase) {
  LivePhase.connecting || LivePhase.muted => HmAvatarState.idle,
  LivePhase.listening => HmAvatarState.listening,
  LivePhase.thinking => HmAvatarState.thinking,
  LivePhase.speaking => HmAvatarState.speaking,
  LivePhase.ended => HmAvatarState.asleep,
  LivePhase.failed => HmAvatarState.error,
};

class HmLiveScreen extends StatefulWidget {
  const HmLiveScreen({
    super.key,
    required this.bot,
    required this.create,
    this.chat,
  }) : _controller = null,
       _minimize = null,
       _end = null;

  const HmLiveScreen._hosted({
    required this.bot,
    required this.chat,
    required this._controller,
    required this._minimize,
    required this._end,
  }) : create = null;

  final HmBot bot;
  final NgChatController? chat;
  final LiveController Function()? create;
  final LiveController? _controller;
  final VoidCallback? _minimize;
  final Future<void> Function()? _end;

  @override
  State<HmLiveScreen> createState() => _HmLiveScreenState();
}

class _HmLiveScreenState extends State<HmLiveScreen>
    with WidgetsBindingObserver {
  late final LiveController live = widget._controller ?? widget.create!();
  bool _closing = false;
  late bool _focus = widget._controller != null;

  @override
  void initState() {
    super.initState();
    if (widget._controller != null) return;
    WidgetsBinding.instance.addObserver(this);
    unawaited(live.start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      live.pause();
    }
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    final end = widget._end;
    if (end != null) return end();
    await live.end();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    if (widget._controller == null) {
      WidgetsBinding.instance.removeObserver(this);
      unawaited(live.end());
      live.dispose();
    }
    super.dispose();
  }

  HmAvatarState get _avatar => _liveAvatar(live);

  String get _status => switch (live.phase) {
    LivePhase.connecting => LiveText.connecting,
    LivePhase.listening => LiveText.listening,
    LivePhase.thinking => LiveText.working,
    LivePhase.speaking => live.webRtc ? LiveText.talkOver : LiveText.speaking,
    LivePhase.muted => LiveText.muted,
    LivePhase.ended => LiveText.stopped,
    LivePhase.failed => live.failure ?? LiveText.stopped,
  };

  @override
  Widget build(BuildContext context) {
    // The call is always dark, as the official one is, but in the active
    // theme's own dark scheme so presets and accents still apply.
    final theme = Theme.of(context);
    return Theme(
      data: theme.brightness == Brightness.dark
          ? theme
          : liveDarkTheme(
              NextGenLook.instance,
              glide: theme.extension<GlideTheme>(),
            ),
      child: Builder(builder: _buildCall),
    );
  }

  Widget _buildCall(BuildContext context) {
    final c = NgColors.of(context);
    final width = MediaQuery.sizeOf(context).width;
    // About a quarter of the screen across, glow included.
    final orb = _focus ? (width * 0.24).clamp(84.0, 112.0) : 48.0;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: c.background.withValues(alpha: 0),
        systemNavigationBarColor: c.background,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: _call(context, c, orb),
    );
  }

  /// Read inside the builder: lanes change between frames.
  List<LiveLane> get _attached => live.lanes?.lanes ?? const [];

  void _tapOrb() {
    if (live.phase == LivePhase.speaking && !live.webRtc) {
      unawaited(live.interrupt());
    } else if (live.target != null) {
      live.route(null);
    }
  }

  Future<void> _openLanes(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => _LanesSheet(lanes: live.lanes!),
  );

  Widget _orb(double orb, {bool interactive = true}) => Semantics(
    key: const ValueKey('live-orb'),
    button:
        interactive &&
        ((live.phase == LivePhase.speaking && !live.webRtc) ||
            live.target != null),
    selected: live.lanes != null && live.target == null,
    label: widget.bot.displayName,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: interactive ? _tapOrb : null,
      child: _GlowOrb(bot: widget.bot, state: _avatar, size: orb),
    ),
  );

  Widget _call(BuildContext context, NgColors c, double orb) {
    final lanes = live.lanes;
    final gap = _focus && lanes == null ? orb * 0.35 : 8.0;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final minimize = widget._minimize;
        if (minimize != null) {
          minimize();
        } else {
          unawaited(_close());
        }
      },
      child: Scaffold(
        backgroundColor: c.background,
        body: ListenableBuilder(
          listenable: Listenable.merge([live, widget.chat]),
          builder: (context, _) {
            final chat = widget.chat;
            final request = chat?.request;
            return SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: HmMetrics.headerTop + 20),
                  if (_focus) ...[
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        _BotPill(bot: widget.bot),
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: IconButton(
                            tooltip: widget._minimize == null
                                ? 'Exit focus mode'
                                : 'Minimize call',
                            onPressed:
                                widget._minimize ??
                                () => setState(() => _focus = false),
                            icon: const Icon(Icons.fullscreen_exit),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: gap),
                    if (lanes == null)
                      _orb(orb)
                    else
                      _LaneOrbit(
                        live: live,
                        lanes: _attached,
                        size: orb,
                        center: _orb(orb),
                      ),
                  ] else
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Flexible(child: _BotPill(bot: widget.bot)),
                          if (!live.webRtc && live.phase == LivePhase.speaking)
                            IconButton(
                              icon: const Icon(Icons.stop_rounded),
                              tooltip: 'Interrupt speech',
                              onPressed: () => unawaited(live.interrupt()),
                            ),
                          Tooltip(
                            message: 'Enter focus mode',
                            child: Semantics(
                              button: true,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => setState(() => _focus = true),
                                child: Badge(
                                  isLabelVisible: request != null,
                                  child: _orb(orb, interactive: false),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  SizedBox(height: gap),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      _status,
                      key: const ValueKey('live-status'),
                      textAlign: TextAlign.center,
                      style: HmType.display.copyWith(
                        color: live.phase == LivePhase.failed
                            ? c.danger
                            : c.text,
                        fontWeight: FontWeight.w400,
                        letterSpacing: 0,
                        fontSize: live.phase == LivePhase.failed ? 17 : 24,
                      ),
                    ),
                  ),
                  if (live.notice != null && !live.isOver)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                      child: Text(
                        live.notice!,
                        textAlign: TextAlign.center,
                        style: HmType.caption.copyWith(color: c.textMuted),
                      ),
                    ),
                  if (live.target != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                      child: Text(
                        LiveText.toLane(live.laneName(live.target!)),
                        key: const ValueKey('live-route'),
                        textAlign: TextAlign.center,
                        style: HmType.caption.copyWith(
                          color: c.accentText,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (_attached.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                      child: Text(
                        liveLaneSummary(_attached),
                        key: const ValueKey('live-lanes-summary'),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HmType.caption.copyWith(color: c.textMuted),
                      ),
                    ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: _Transcript(
                      live: live,
                      bot: widget.bot,
                      request: _focus && request != null && chat != null
                          ? NgInputPanel(
                              key: ValueKey(
                                request.kind == NgRequestKind.approval
                                    ? 'live-approval'
                                    : 'live-input-request',
                              ),
                              chat: chat,
                              request: request,
                            )
                          : null,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (lanes != null) ...[
                          HmRoundButton(
                            key: const ValueKey('live-lanes-button'),
                            icon: Icons.hub_rounded,
                            label: LiveText.lanes,
                            size: 56,
                            onPressed: live.isOver
                                ? null
                                : () => unawaited(_openLanes(context)),
                          ),
                          const SizedBox(width: 16),
                        ],
                        HmRoundButton(
                          icon: live.muted
                              ? Icons.mic_off_rounded
                              : Icons.mic_rounded,
                          label: live.muted ? LiveText.unmute : LiveText.mute,
                          size: 56,
                          onPressed: live.isOver ? null : live.toggleMute,
                        ),
                        const SizedBox(width: 16),
                        HmRoundButton(
                          icon: Icons.close_rounded,
                          label: LiveText.end,
                          size: 56,
                          onPressed: _close,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _BotPill extends StatelessWidget {
  const _BotPill({required this.bot});
  final HmBot bot;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Container(
      key: const ValueKey('live-pill'),
      padding: const EdgeInsets.fromLTRB(7, 7, 20, 7),
      decoration: BoxDecoration(
        color: c.surface3.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(40),
        border: Border.all(color: c.strokeStrong),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          HmAvatar(spec: bot.character, size: 28),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              bot.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HmType.row.copyWith(
                color: c.text,
                fontSize: 17,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({required this.bot, required this.state, required this.size});
  final HmBot bot;
  final HmAvatarState state;
  final double size;

  @override
  Widget build(BuildContext context) {
    final glow = bot.character.tone;
    final lit =
        state == HmAvatarState.listening || state == HmAvatarState.speaking;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: glow.withValues(alpha: lit ? 0.6 : 0.35),
            blurRadius: size * (lit ? 0.32 : 0.22),
            spreadRadius: size * (lit ? 0.06 : 0.02),
          ),
        ],
      ),
      // The Syn face pokes on tap; here a tap interrupts the bot instead.
      child: IgnorePointer(
        child: HmAvatar(spec: bot.character, size: size, state: state),
      ),
    );
  }
}

class _Transcript extends StatelessWidget {
  const _Transcript({required this.live, required this.bot, this.request});
  final LiveController live;
  final HmBot bot;
  final Widget? request;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final rows = <Widget>[
      for (final line in live.lines)
        if (line.work)
          LiveWork(
            key: ValueKey(line.key),
            tools: line.tools,
            cards: line.cards,
          )
        else
          _Line(
            key: ValueKey(line.key),
            speaker: line.lane != null
                ? (line.fromUser
                      ? LiveText.youToLane(live.laneName(line.lane!))
                      : LiveText.laneSpeaker(live.laneName(line.lane!)))
                : line.fromUser
                ? LiveText.you
                : bot.displayName,
            text: line.text,
            fromUser: line.fromUser,
            tools: line.tools,
            cards: line.cards,
          ),
      if (live.partial.trim().isNotEmpty)
        _Line(
          key: const ValueKey('live-partial'),
          speaker: LiveText.you,
          text: live.partial.trim(),
          fromUser: true,
        ),
      ?request,
    ];
    return ShaderMask(
      shaderCallback: (rect) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [c.background.withValues(alpha: 0), c.background],
        stops: const [0, 0.12],
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: ListView(
        // Newest at the bottom, pinned there as lines arrive.
        reverse: true,
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
        children: rows.reversed.toList(),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    super.key,
    required this.speaker,
    required this.text,
    required this.fromUser,
    this.tools = const [],
    this.cards = const [],
  });
  final String speaker;
  final String text;
  final bool fromUser;
  final List<NgTool> tools;
  final List<String> cards;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final words = cards.isEmpty ? text : withoutEphemeralUi(text);
    if (words.isEmpty) return LiveWork(tools: tools, cards: cards);
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (tools.isNotEmpty) LiveWork(tools: tools, bottom: 6),
          Text(
            speaker,
            style: HmType.caption.copyWith(
              color: c.textMuted,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            words,
            style: HmType.body.copyWith(
              color: fromUser ? c.text3 : c.text,
              fontStyle: fromUser ? FontStyle.italic : FontStyle.normal,
              fontSize: 17,
              height: 1.35,
            ),
          ),
          for (final card in cards) LiveCard(source: card),
        ],
      ),
    );
  }
}

/// The bot's orb with one small orb per attached lane on a slow orbit
/// around it (still when the system turns animations off).
class _LaneOrbit extends StatefulWidget {
  const _LaneOrbit({
    required this.live,
    required this.lanes,
    required this.size,
    required this.center,
  });
  final LiveController live;
  final List<LiveLane> lanes;
  final double size;
  final Widget center;

  @override
  State<_LaneOrbit> createState() => _LaneOrbitState();
}

class _LaneOrbitState extends State<_LaneOrbit>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 40),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still || widget.lanes.isEmpty) {
      _spin.stop();
    } else if (!_spin.isAnimating) {
      unawaited(_spin.repeat());
    }
  }

  @override
  void didUpdateWidget(_LaneOrbit old) {
    super.didUpdateWidget(old);
    didChangeDependencies();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lane = (widget.size * 0.34).clamp(30.0, 40.0);
    const gap = 14.0;
    final radius = widget.size / 2 + gap + lane / 2;
    final box = 2 * (radius + lane / 2);
    final label = lane + 28;
    return SizedBox.square(
      key: const ValueKey('live-orbit'),
      dimension: box,
      child: AnimatedBuilder(
        animation: _spin,
        builder: (context, _) {
          final n = widget.lanes.length;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Center(child: widget.center),
              for (var i = 0; i < n; i++)
                () {
                  final a = -math.pi / 2 + 2 * math.pi * (i / n + _spin.value);
                  return Positioned(
                    left: box / 2 + radius * math.cos(a) - label / 2,
                    top: box / 2 + radius * math.sin(a) - lane / 2,
                    width: label,
                    child: _LaneOrb(
                      lane: widget.lanes[i],
                      size: lane,
                      selected: widget.live.target == widget.lanes[i].id,
                      onTap: () => widget.live.route(
                        widget.live.target == widget.lanes[i].id
                            ? null
                            : widget.lanes[i].id,
                      ),
                    ),
                  );
                }(),
            ],
          );
        },
      ),
    );
  }
}

/// The agent's tool calls while it works on a request, as progress rows in
/// the call's transcript: the chat's own tool header and rows, folded by
/// default (spinner and the running tool while it runs, then "Used …");
/// tap to see each call, tap a call for its input and output.
class LiveWork extends StatefulWidget {
  const LiveWork({
    super.key,
    required this.tools,
    this.cards = const [],
    this.bottom = 16,
  });
  final List<NgTool> tools;

  /// Ephemeral-ui cards the work produced, shown open under the rows.
  final List<String> cards;
  final double bottom;

  @override
  State<LiveWork> createState() => _LiveWorkState();
}

class _LiveWorkState extends State<LiveWork> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final tools = widget.tools;
    final cards = widget.cards;
    if (tools.isEmpty && cards.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: widget.bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (tools.isNotEmpty)
            NgDisclosure(
              key: const ValueKey('live-work'),
              icon: Icons.build_outlined,
              label: ngToolsLabel(tools),
              busy: tools.any((t) => t.running),
              open: _open,
              onTap: () => setState(() => _open = !_open),
              child: Column(
                children: [for (final t in tools) NgToolRow(tool: t)],
              ),
            ),
          for (final card in cards) LiveCard(source: card),
        ],
      ),
    );
  }
}

/// One ephemeral-ui card in the call's transcript, through the chat's own
/// fenced-block renderer, including the same source and error states.
class LiveCard extends StatelessWidget {
  const LiveCard({super.key, required this.source});
  final String source;

  @override
  Widget build(BuildContext context) => MarkdownCodeBlock(
    key: const ValueKey('live-card'),
    code: source,
    language: ephemeralFenceLanguage,
    selectable: false,
  );
}

class _LaneOrb extends StatelessWidget {
  const _LaneOrb({
    required this.lane,
    required this.size,
    required this.selected,
    required this.onTap,
  });
  final LiveLane lane;
  final double size;
  final bool selected;
  final VoidCallback onTap;

  IconData get _icon => switch (lane.id) {
    'fast' => Icons.bolt_rounded,
    'large' => Icons.psychology_rounded,
    'council' => Icons.groups_rounded,
    _ => Icons.blur_on_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final ring = switch (lane.status) {
      LiveLaneStatus.working => c.accent,
      LiveLaneStatus.error => c.danger,
      LiveLaneStatus.idle => selected ? c.accent : c.strokeStrong,
    };
    return Semantics(
      key: ValueKey('live-lane-${lane.id}'),
      button: true,
      selected: selected,
      label: '${LiveText.laneSpeaker(lane.name)}, ${liveLaneNow(lane)}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: size,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected ? c.accentSoft : c.surface3,
                      border: Border.all(color: ring, width: 2),
                      boxShadow: [
                        if (selected || lane.status == LiveLaneStatus.working)
                          BoxShadow(
                            color: ring.withValues(alpha: 0.5),
                            blurRadius: size * 0.4,
                          ),
                      ],
                    ),
                    child: Icon(
                      _icon,
                      size: size * 0.52,
                      color: lane.status == LiveLaneStatus.error
                          ? c.danger
                          : c.text,
                    ),
                  ),
                  if (lane.status == LiveLaneStatus.working)
                    CircularProgressIndicator(strokeWidth: 2, color: c.accent),
                ],
              ),
            ),
            const SizedBox(height: 3),
            Text(
              lane.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HmType.caption.copyWith(
                color: selected ? c.accentText : c.textMuted,
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Attach and detach the thread's lanes.
class _LanesSheet extends StatelessWidget {
  const _LanesSheet({required this.lanes});
  final LiveLanes lanes;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return SafeArea(
      child: ListenableBuilder(
        listenable: lanes,
        builder: (context, _) => Column(
          key: const ValueKey('live-lanes-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
              child: Text(
                LiveText.lanesTitle,
                style: HmType.row.copyWith(
                  color: c.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                lanes is FixtureLiveLanes
                    ? '${LiveText.lanesHint} ${LiveText.lanesFixture}'
                    : LiveText.lanesHint,
                style: HmType.caption.copyWith(color: c.textMuted),
              ),
            ),
            for (final o in lanes.options)
              SwitchListTile(
                key: ValueKey('live-lane-toggle-${o.id}'),
                title: Text(o.name),
                subtitle: o.model == null ? null : Text(o.model!),
                value: lanes.lanes.any((l) => l.id == o.id),
                onChanged: (on) =>
                    unawaited(on ? lanes.attach(o.id) : lanes.detach(o.id)),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// The Live call's theme under a light app theme: the active look's own dark
/// scheme (preset, accent and pure-black all apply).
ThemeData liveDarkTheme(NextGenLook look, {GlideTheme? glide}) =>
    nextGenTheme(Brightness.dark, look, glide: glide);
