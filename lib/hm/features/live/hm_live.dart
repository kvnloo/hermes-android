// Live Mode: a full-screen voice call with the bot (official S-LV1,
// shots/official-s25/live-01.png): an immersive dark surface in every app
// theme, a translucent bot pill at the top, a glowing orb, one status line,
// the call's transcript (You in muted italics, the bot in full text) and two
// dark round mic + close buttons at the bottom. The call runs over GPT-Live
// (WebRTC) when the host offers it, else the chained loop.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;

import '../../../core/services/android_voice_composer_adapter.dart';
import '../../../core/widgets/ephemeral_ui_card.dart';
import '../../../core/widgets/markdown_code_block.dart';
import '../../../nextgen/data/chat_controller.dart';
import '../../../nextgen/nextgen_preferences.dart';
import '../../../nextgen/theme/nextgen_theme.dart';
import '../../../nextgen/ui/tool_rows.dart';
import '../../../shared_ui/glide_theme.dart';
import '../../avatar/hm_avatar.dart';
import '../../avatar/hm_avatar_state.dart';
import '../../hm_bots.dart';
import '../../hm_ui.dart';
import 'live_controller.dart';
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
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => HmLiveScreen(
        bot: bot,
        create: () => LiveController(
          host: host,
          ear: DeviceLiveEar(createVoiceComposerAdapter()),
          brain: ChatLiveBrain(chat),
          voice: HostLiveVoice(host),
          call: () => LiveCall(host: host, peer: FlutterWebRtcPeer.new),
        ),
      ),
    ),
  );
}

class HmLiveScreen extends StatefulWidget {
  const HmLiveScreen({super.key, required this.bot, required this.create});

  final HmBot bot;

  /// Builds the call's controller; the screen owns and disposes it.
  final LiveController Function() create;

  @override
  State<HmLiveScreen> createState() => _HmLiveScreenState();
}

class _HmLiveScreenState extends State<HmLiveScreen>
    with WidgetsBindingObserver {
  late final LiveController live = widget.create();
  bool _closing = false;

  @override
  void initState() {
    super.initState();
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
    await live.end();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(live.end());
    live.dispose();
    super.dispose();
  }

  HmAvatarState get _avatar => switch (live.phase) {
    LivePhase.connecting || LivePhase.muted => HmAvatarState.idle,
    LivePhase.listening => HmAvatarState.listening,
    LivePhase.thinking => HmAvatarState.thinking,
    LivePhase.speaking => HmAvatarState.speaking,
    LivePhase.ended => HmAvatarState.asleep,
    LivePhase.failed => HmAvatarState.error,
  };

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

  Widget _call(BuildContext context, NgColors c, double orb) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: Scaffold(
        backgroundColor: c.background,
        body: ListenableBuilder(
          listenable: live,
          builder: (context, _) => SafeArea(
            child: Column(
              children: [
                const SizedBox(height: HmMetrics.headerTop + 20),
                _BotPill(bot: widget.bot),
                SizedBox(height: orb * 0.45),
                Semantics(
                  key: const ValueKey('live-orb'),
                  button: live.phase == LivePhase.speaking && !live.webRtc,
                  label: widget.bot.displayName,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: live.interrupt,
                    child: _GlowOrb(bot: widget.bot, state: _avatar, size: orb),
                  ),
                ),
                SizedBox(height: orb * 0.45),
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
                const SizedBox(height: 4),
                Expanded(
                  child: _Transcript(live: live, bot: widget.bot),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
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
  const _Transcript({required this.live, required this.bot});
  final LiveController live;
  final HmBot bot;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final rows = <Widget>[
      for (final line in live.lines)
        if (line.work)
          LiveWork(key: ValueKey(line.key), tools: line.tools, cards: line.cards)
        else
          _Line(
            key: ValueKey(line.key),
            speaker: line.fromUser ? LiveText.you : bot.displayName,
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
/// fenced-block renderer (so it draws exactly as in the chat, and an invalid
/// card shows as code there and here alike).
class LiveCard extends StatelessWidget {
  const LiveCard({super.key, required this.source});
  final String source;

  @override
  Widget build(BuildContext context) => MarkdownCodeBlock(
    key: const ValueKey('live-card'),
    code: source,
    language: ephemeralUiLanguage,
    selectable: false,
  );
}

/// The Live call's theme under a light app theme: the active look's own dark
/// scheme (preset, accent and pure-black all apply).
ThemeData liveDarkTheme(NextGenLook look, {GlideTheme? glide}) =>
    nextGenTheme(Brightness.dark, look, glide: glide);
