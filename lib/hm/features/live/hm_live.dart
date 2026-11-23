// Live Mode: a full-screen voice call with the bot (official S-LV1,
// shots/official-s25/live-01.png): an immersive dark surface in every app
// theme, a translucent bot pill at the top, a glowing orb, one status line,
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
import '../../../core/ephemeral/ephemeral_fence.dart';
import '../../../core/widgets/markdown_code_block.dart';
import '../../../nextgen/data/chat_controller.dart';
import '../../../nextgen/nextgen_preferences.dart';
import '../../../nextgen/theme/nextgen_theme.dart';
import '../../../nextgen/ui/tool_rows.dart';
import '../../../nextgen/ui/chat_view.dart' show NgInputPanel;
import 'live_approval.dart';
import '../../../shared_ui/glide_theme.dart';
import '../../avatar/hm_avatar.dart';
import '../../avatar/hm_avatar_state.dart';
import '../../hm_bots.dart';
import '../../hm_ui.dart';
import 'live_controller.dart';
import 'live_lanes.dart';
import 'live_strings.dart';
import 'live_session_host.dart';
import '../../../core/services/background_work_prefs.dart';
import 'live_transport.dart';
import 'live_webrtc.dart';

Future<void> openHmLive(
  BuildContext context, {
  required HmBot bot,
  required HmBotsModel bots,
  required NgChatController chat,
  required VoidCallback openChat,
}) async {
  final host = HmLiveScope.of(context);
  final transport = DashboardLiveHost(
    bots.gateway.dashboard,
    profile: bot.scope,
  );
  await presentHmLive(
    context,
    host: host,
    bot: bot,
    create: () {
      final live = LiveController(
        host: transport,
        ear: DeviceLiveEar(createVoiceComposerAdapter()),
        brain: ChatLiveBrain(chat),
        voice: HostLiveVoice(transport),
        call: () => LiveCall(host: transport, peer: FlutterWebRtcPeer.new),
        lanes: kLiveLanesFixture ? FixtureLiveLanes() : null,
      );
      host.bindChat(chat, openChat);
      live.approval = host.approval;
      live.onRequestAction = host.act;
      return live;
    },
  );
}

Future<void> presentHmLive(
  BuildContext context, {
  required LiveSessionHost host,
  required HmBot bot,
  required LiveController Function() create,
}) async {
  if (host.choosingBot) return;
  if (host.active && host.bot?.profile == bot.profile) {
    host.onReturn?.call();
    return;
  }
  final navigator = Navigator.of(context);
  host.choosingBot = true;
  try {
    if (host.active) {
      final change = await showDialog<bool>(
        context: context,
        useRootNavigator: false,
        builder: (context) => AlertDialog(
          title: Text('Switch Live to ${bot.displayName}?'),
          content: Text('This ends the call with ${host.bot?.displayName}.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep call'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Switch'),
            ),
          ],
        ),
      );
      if (change != true) return;
    }
    if (!context.mounted) return;
    await host.begin(bot, create);
    final live = host.live;
    if (!navigator.mounted || live == null) return;
    host.onOpenRequest = () {
      if (!navigator.mounted) return;
      final context = navigator.overlay?.context;
      if (context != null) _openLiveRequest(context, host);
    };
    host.onRetry = () async {
      final overlay = navigator.overlay;
      if (!navigator.mounted || overlay == null) return;
      final release = host.approval?.chat.retain();
      try {
        await presentHmLive(
          overlay.context,
          host: host,
          bot: bot,
          create: create,
        );
      } finally {
        release?.call();
      }
    };
    host.onReturn = () => _showCall(navigator, host, bot, live);
    host.onReturn!();
  } finally {
    host.choosingBot = false;
  }
}

void _showCall(
  NavigatorState navigator,
  LiveSessionHost host,
  HmBot bot,
  LiveController live,
) {
  if (!navigator.mounted || host.live != live) return;
  final existing = host.fullRoute;
  if (existing != null && existing.isActive) {
    // Do not discard other app routes just to re-open the call. Remove only
    // the covered copy of the Live view (it owns no session state).
    if (existing.isCurrent) return;
    navigator.removeRoute(existing);
  }
  final route = _LiveRoute(host, bot, live);
  host.fullRoute = route;
  unawaited(navigator.push(route));
  route._sync();
}

class _LiveRoute extends MaterialPageRoute<void> {
  _LiveRoute(this.host, HmBot bot, LiveController live)
    : super(
        builder: (_) => HmLiveScreen(bot: bot, host: host, live: live),
      );

  final LiveSessionHost host;

  void _sync() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (identical(host.fullRoute, this)) host.setFullScreen(isCurrent);
  });

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    super.didChangeNext(nextRoute);
    _sync();
  }

  @override
  bool didPop(void result) {
    final popped = super.didPop(result);
    _sync();
    if (popped && identical(host.fullRoute, this)) {
      final open = host.takeApprovedDestination();
      if (open != null) {
        final release = host.approval?.chat.retain();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          try {
            open();
          } finally {
            release?.call();
          }
        });
      }
    }
    return popped;
  }

  @override
  void dispose() {
    _sync();
    super.dispose();
  }
}

/// Owns the session and a safe-area band above the hm navigator. The pill
/// takes layout space instead of floating over each screen's header/composer.
class HmLiveScope extends StatefulWidget {
  const HmLiveScope({
    super.key,
    required this.child,
    this.background,
    this.policy,
  });

  final Widget child;
  final LiveBackground? background;
  final ValueNotifier<bool>? policy;

  static LiveSessionHost? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_LiveScope>()?.host;

  static LiveSessionHost of(BuildContext context) => maybeOf(context)!;

  @override
  State<HmLiveScope> createState() => _HmLiveScopeState();
}

class _HmLiveScopeState extends State<HmLiveScope> {
  late final host = LiveSessionHost(
    background: widget.background ?? AndroidLiveBackground(),
    backgroundAllowed: widget.policy ?? backgroundWorkEnabled,
  );

  @override
  void dispose() {
    host.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _LiveScope(
    host: host,
    child: ListenableBuilder(
      listenable: host,
      child: widget.child,
      builder: (context, child) {
        final visible = host.showPill && !host.fullScreen;
        return Column(
          children: [
            if (visible) SafeArea(bottom: false, child: _MiniLive(host)),
            Expanded(
              key: const ValueKey('hm navigator'),
              child: MediaQuery(
                data: visible
                    ? MediaQuery.of(context).removePadding(removeTop: true)
                    : MediaQuery.of(context),
                child: child!,
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _LiveScope extends InheritedWidget {
  const _LiveScope({required this.host, required super.child});
  final LiveSessionHost host;

  @override
  bool updateShouldNotify(_LiveScope oldWidget) => host != oldWidget.host;
}

String _liveStatus(LiveController live) => live.paused
    ? LiveText.paused
    : switch (live.phase) {
        LivePhase.connecting => LiveText.connecting,
        LivePhase.listening => LiveText.listening,
        LivePhase.thinking => LiveText.working,
        LivePhase.speaking =>
          live.webRtc ? LiveText.talkOver : LiveText.speaking,
        LivePhase.muted => LiveText.muted,
        LivePhase.ended => LiveText.stopped,
        LivePhase.failed => live.failure ?? LiveText.stopped,
      };

/// The pill sits above the navigator and its Overlay. Use accessibility
/// labels rather than Tooltip, which requires an ancestor presentation layer.
class _LiveIcon extends StatelessWidget {
  const _LiveIcon({
    required this.label,
    required this.onPressed,
    required this.icon,
  });
  final String label;
  final VoidCallback? onPressed;
  final Icon icon;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: label,
    button: true,
    child: IconButton(onPressed: onPressed, icon: icon),
  );
}

class _MiniLive extends StatelessWidget {
  const _MiniLive(this.host);
  final LiveSessionHost host;

  @override
  Widget build(BuildContext context) {
    final bot = host.bot!;
    final live = host.live!;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            key: const ValueKey('live-mini'),
            children: [
              Expanded(
                child: InkWell(
                  onTap: host.onReturn,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        IgnorePointer(
                          child: HmAvatar(spec: bot.character, size: 28),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${bot.displayName} · ${_liveStatus(live)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (host.newCard)
                          Icon(
                            Icons.fiber_manual_record,
                            size: 10,
                            color: Theme.of(context).colorScheme.primary,
                            semanticLabel: 'New card',
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (live.phase == LivePhase.failed)
                _LiveIcon(
                  label: 'Retry Live',
                  onPressed: host.onRetry,
                  icon: const Icon(Icons.refresh),
                )
              else
                _LiveIcon(
                  label: live.muted ? LiveText.unmute : LiveText.mute,
                  onPressed: live.paused ? null : live.toggleMute,
                  icon: Icon(
                    live.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                  ),
                ),
              _LiveIcon(
                label: LiveText.end,
                onPressed: () {
                  host.takeApprovedDestination()?.call();
                  unawaited(host.end());
                },
                icon: const Icon(Icons.call_end_rounded),
              ),
            ],
          ),
          LiveRequestStrip(host: host),
        ],
      ),
    );
  }
}

void _openLiveRequest(BuildContext context, LiveSessionHost host) {
  final approval = host.approval;
  if (approval?.pending == null || host.requestDialogOpen) return;
  host.requestDialogOpen = true;
  // Speech can open this while Android is backgrounded; the protected
  // navigator presents it when the user returns. No credential is spoken.
  unawaited(
    showDialog<void>(
      context: context,
      useRootNavigator: false,
      builder: (context) => Dialog(
        child: ListenableBuilder(
          listenable: host,
          builder: (context, _) {
            final current = identical(approval, host.approval)
                ? approval!.pending
                : null;
            if (current == null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted &&
                    ModalRoute.of(context)?.isCurrent == true) {
                  Navigator.of(context).pop();
                }
              });
              return const SizedBox.shrink();
            }
            return NgInputPanel(
              chat: approval!.chat,
              request: current,
              onApproved: () => approval.returnToChat = true,
            );
          },
        ),
      ),
    ).whenComplete(() => host.requestDialogOpen = false),
  );
}

class LiveRequestStrip extends StatelessWidget {
  const LiveRequestStrip({
    super.key,
    required this.host,
    this.expanded = false,
  });
  final LiveSessionHost host;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final request = host.active ? host.approval?.pending : null;
    if (request == null) return const SizedBox.shrink();
    final detail = [
      request.command,
      request.questions.firstOrNull?.question,
      request.body,
    ].whereType<String>().where((text) => text.isNotEmpty).firstOrNull;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (expanded)
            Text(request.title, style: Theme.of(context).textTheme.titleSmall),
          Row(
            children: [
              Expanded(
                child: Text(
                  expanded
                      ? (detail ?? request.title)
                      : '${request.title} · ${detail ?? ""}',
                  maxLines: expanded ? 3 : 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (request.kind == NgRequestKind.approval)
                _LiveIcon(
                  label: 'Allow once',
                  icon: const Icon(Icons.check),
                  onPressed: () => host.act(request, LiveRequestAction.allow),
                ),
              _LiveIcon(
                label: 'Deny',
                icon: const Icon(Icons.close),
                onPressed: () => host.act(request, LiveRequestAction.deny),
              ),
              _LiveIcon(
                label: 'Open request',
                icon: const Icon(Icons.open_in_new),
                onPressed: () => host.act(request, LiveRequestAction.open),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class HmLiveScreen extends StatefulWidget {
  const HmLiveScreen({
    super.key,
    required this.bot,
    required this.host,
    required this.live,
  });

  final HmBot bot;
  final LiveSessionHost host;
  final LiveController live;

  @override
  State<HmLiveScreen> createState() => _HmLiveScreenState();
}

class _HmLiveScreenState extends State<HmLiveScreen> {
  LiveController get live => widget.live;

  void _minimize() {
    if (ModalRoute.of(context)?.isCurrent == true) Navigator.of(context).pop();
  }

  @override
  void initState() {
    super.initState();
    widget.host.addListener(_onHostChanged);
  }

  void _onHostChanged() {
    if (identical(widget.host.live, live)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route?.isActive == true) Navigator.of(context).removeRoute(route!);
    });
  }

  @override
  void dispose() {
    widget.host.removeListener(_onHostChanged);
    super.dispose();
  }

  void _end() {
    _minimize();
    if (identical(widget.host.live, live)) unawaited(widget.host.end());
  }

  HmAvatarState get _avatar => switch (live.phase) {
    LivePhase.connecting || LivePhase.muted => HmAvatarState.idle,
    LivePhase.listening => HmAvatarState.listening,
    LivePhase.thinking => HmAvatarState.thinking,
    LivePhase.speaking => HmAvatarState.speaking,
    LivePhase.ended => HmAvatarState.asleep,
    LivePhase.failed => HmAvatarState.error,
  };

  String get _status => _liveStatus(live);

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
    final orb = (width * 0.2).clamp(72.0, 112.0);
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

  Widget _orb(double orb) => Semantics(
    key: const ValueKey('live-orb'),
    button:
        (live.phase == LivePhase.speaking && !live.webRtc) ||
        live.target != null,
    selected: live.lanes != null && live.target == null,
    label: widget.bot.displayName,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _tapOrb,
      child: _GlowOrb(bot: widget.bot, state: _avatar, size: orb),
    ),
  );

  Widget _call(BuildContext context, NgColors c, double orb) {
    final lanes = live.lanes;
    final gap = lanes == null ? orb * 0.45 : 8.0;
    return Scaffold(
      backgroundColor: c.background,
      body: ListenableBuilder(
        listenable: Listenable.merge([live, widget.host]),
        builder: (context, _) => SafeArea(
          child: Column(
            children: [
              const SizedBox(height: HmMetrics.headerTop + 20),
              _BotPill(bot: widget.bot),
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
              SizedBox(height: gap),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  _status,
                  key: const ValueKey('live-status'),
                  textAlign: TextAlign.center,
                  style: HmType.display.copyWith(
                    color: live.phase == LivePhase.failed ? c.danger : c.text,
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
                  host: widget.host,
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
                      icon: Icons.expand_more_rounded,
                      label: 'Minimize',
                      size: 56,
                      onPressed: _minimize,
                    ),
                    const SizedBox(width: 16),
                    HmRoundButton(
                      icon: live.muted
                          ? Icons.mic_off_rounded
                          : Icons.mic_rounded,
                      label: live.muted ? LiveText.unmute : LiveText.mute,
                      size: 56,
                      onPressed: live.isOver || live.paused
                          ? null
                          : live.toggleMute,
                    ),
                    const SizedBox(width: 16),
                    HmRoundButton(
                      icon: Icons.close_rounded,
                      label: LiveText.end,
                      size: 56,
                      onPressed: _end,
                    ),
                  ],
                ),
              ),
            ],
          ),
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
          Text(
            bot.displayName,
            style: HmType.row.copyWith(
              color: c.text,
              fontSize: 17,
              fontWeight: FontWeight.w500,
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
  const _Transcript({
    required this.live,
    required this.bot,
    required this.host,
  });
  final LiveSessionHost host;
  final LiveController live;
  final HmBot bot;

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
        children: [
          if (host.active && host.approval?.pending != null)
            LiveRequestStrip(host: host, expanded: true),
          ...rows.reversed,
        ],
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
