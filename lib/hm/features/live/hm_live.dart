// Live Mode: a full-screen voice call with the bot (official S-LV1,
// shots/official-s25/live-01.png): the bot pill at the top, a large glowing
// orb, one status line, the call's transcript (You in muted italics, the bot
// in full text) and round mic + close buttons at the bottom.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/services/android_voice_composer_adapter.dart';
import '../../../nextgen/data/chat_controller.dart';
import '../../../nextgen/theme/nextgen_theme.dart';
import '../../avatar/hm_avatar.dart';
import '../../avatar/hm_avatar_state.dart';
import '../../hm_bots.dart';
import '../../hm_ui.dart';
import 'live_controller.dart';
import 'live_strings.dart';
import 'live_transport.dart';

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
    LivePhase.speaking => LiveText.speaking,
    LivePhase.muted => LiveText.muted,
    LivePhase.ended => LiveText.stopped,
    LivePhase.failed => live.failure ?? LiveText.stopped,
  };

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
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
                const SizedBox(height: HmMetrics.headerTop + 8),
                _BotPill(bot: widget.bot),
                const SizedBox(height: 28),
                Semantics(
                  button: live.phase == LivePhase.speaking,
                  label: widget.bot.displayName,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: live.interrupt,
                    child: _GlowOrb(bot: widget.bot, state: _avatar, size: 180),
                  ),
                ),
                const SizedBox(height: 28),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    _status,
                    key: const ValueKey('live-status'),
                    textAlign: TextAlign.center,
                    style: HmType.display.copyWith(
                      color: live.phase == LivePhase.failed ? c.danger : c.text,
                      fontWeight: FontWeight.w500,
                      fontSize: live.phase == LivePhase.failed ? 18 : 24,
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
                const SizedBox(height: 12),
                Expanded(
                  child: _Transcript(live: live, bot: widget.bot),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 12, 0, 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      HmRoundButton(
                        icon: live.muted
                            ? Icons.mic_off_rounded
                            : Icons.mic_rounded,
                        label: live.muted ? LiveText.unmute : LiveText.mute,
                        size: 72,
                        onPressed: live.isOver ? null : live.toggleMute,
                      ),
                      const SizedBox(width: 24),
                      HmRoundButton(
                        icon: Icons.close_rounded,
                        label: LiveText.end,
                        size: 72,
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
      padding: const EdgeInsets.fromLTRB(8, 8, 22, 8),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(40),
        border: Border.all(color: c.stroke),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          HmAvatar(spec: bot.character, size: 36),
          const SizedBox(width: 12),
          Text(
            bot.displayName,
            style: HmType.row.copyWith(
              color: c.text,
              fontSize: 20,
              fontWeight: FontWeight.w600,
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
            color: glow.withValues(alpha: lit ? 0.55 : 0.3),
            blurRadius: lit ? 64 : 40,
            spreadRadius: lit ? 10 : 4,
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
        _Line(
          key: ValueKey(line.key),
          speaker: line.fromUser ? LiveText.you : bot.displayName,
          text: line.text,
          fromUser: line.fromUser,
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
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 8),
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
  });
  final String speaker;
  final String text;
  final bool fromUser;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            speaker,
            style: HmType.caption.copyWith(
              color: c.textMuted,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            text,
            style: HmType.body.copyWith(
              color: fromUser ? c.text3 : c.text,
              fontStyle: fromUser ? FontStyle.italic : FontStyle.normal,
              fontSize: 19,
            ),
          ),
        ],
      ),
    );
  }
}
