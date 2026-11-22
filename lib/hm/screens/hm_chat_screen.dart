// A bot's chat: the floating header (back, character + name pill, More)
// over the shared chat surface.
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../core/services/voice_composer_adapter.dart';
import '../../core/services/android_share_intent_service.dart';
import '../../nextgen/data/chat_controller.dart';
import '../../nextgen/theme/nextgen_theme.dart';
import '../../nextgen/ui/chat_view.dart';
import '../../nextgen/ui/model_sheet.dart';
import '../hm_bots.dart';
import '../avatar/hm_avatar.dart';
import '../avatar/hm_avatar_state.dart';
import '../hm_ui.dart';

/// What the More menu can open; the screen that owns the chat decides how.
enum HmChatAction {
  chatSettings,
  liveMode,
  terminal,
  execution,
  routines,
  artifacts,
  council,
  archive,
  delete,
}

class HmChatScreen extends StatefulWidget {
  const HmChatScreen({
    super.key,
    required this.bot,
    required this.chat,
    required this.onAction,
    required this.onNewChat,
    this.onOpenBot,
    this.voiceFactory,
    this.sharedDraft,
  });

  final AndroidSharePayload? sharedDraft;
  final HmBot bot;
  final NgChatController chat;
  final Future<void> Function(HmChatAction action) onAction;
  final VoidCallback onNewChat;
  final VoidCallback? onOpenBot;

  /// Test hook: the composer's speech recognizer (a fake dictation source).
  @visibleForTesting
  final VoiceComposerAdapter Function()? voiceFactory;

  @override
  State<HmChatScreen> createState() => _HmChatScreenState();
}

class _HmChatScreenState extends State<HmChatScreen> {
  /// Written by the composer's mic, read by the header's avatar.
  final _dictation = ValueNotifier(false);

  @override
  void dispose() {
    _dictation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NgChatView(
      chat: widget.chat,
      sharedDraft: widget.sharedDraft,
      onOpenSidebar: () => Navigator.of(context).maybePop(),
      onNewChat: widget.onNewChat,
      botName: widget.bot.displayName,
      dictation: _dictation,
      voiceFactory: widget.voiceFactory,
      appBar: _HmChatHeader(
        bot: widget.bot,
        chat: widget.chat,
        dictation: _dictation,
        onOpenBot: widget.onOpenBot,
        onAction: widget.onAction,
      ),
    );
  }
}

class _HmChatHeader extends StatelessWidget implements PreferredSizeWidget {
  const _HmChatHeader({
    required this.bot,
    required this.chat,
    required this.dictation,
    required this.onAction,
    this.onOpenBot,
  });

  final HmBot bot;
  final NgChatController chat;
  final ValueListenable<bool> dictation;
  final Future<void> Function(HmChatAction action) onAction;
  final VoidCallback? onOpenBot;

  @override
  Size get preferredSize => const Size.fromHeight(HmMetrics.roundButton + 44);

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          HmMetrics.edge,
          HmMetrics.headerTop,
          HmMetrics.edge,
          0,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const HmBackButton(),
                const Spacer(),
                _HmMoreButton(onAction: onAction),
              ],
            ),
            Align(
              alignment: Alignment.topCenter,
              child: Semantics(
                button: onOpenBot != null,
                label: 'Agent settings',
                // One tap target: the character and the pill both open Agent
                // settings. The face has its own poke handler, which would
                // win the gesture arena, so the children ignore pointers and
                // this detector takes every hit in its box.
                child: GestureDetector(
                  key: const ValueKey('hm-chat-header-bot'),
                  behavior: HitTestBehavior.opaque,
                  onTap: onOpenBot,
                  child: IgnorePointer(
                    child: ListenableBuilder(
                      listenable: Listenable.merge([chat, dictation]),
                      builder: (context, _) {
                        final title = chat.title.trim().isEmpty
                            ? bot.displayName
                            : chat.title.trim();
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            HmAvatar(
                              spec: bot.character,
                              size: 44,
                              state: hmAvatarStateOf(
                                chat,
                                listening: dictation.value,
                                reducedMotion: MediaQuery.of(
                                  context,
                                ).disableAnimations,
                              ),
                            ),
                            Transform.translate(
                              offset: const Offset(0, -6),
                              child: Container(
                                constraints: const BoxConstraints(
                                  maxWidth: 220,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: c.surface,
                                  borderRadius: BorderRadius.circular(999),
                                  boxShadow: hmShadow(c),
                                ),
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: HmType.pill.copyWith(color: c.text),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HmMoreButton extends StatelessWidget {
  const _HmMoreButton({required this.onAction});
  final Future<void> Function(HmChatAction action) onAction;

  @override
  Widget build(BuildContext context) {
    return HmRoundButton(
      icon: Icons.more_horiz,
      label: 'More',
      onPressed: () async {
        final picked = await showHmMenu<HmChatAction>(
          context,
          groups: const [
            [
              HmMenuItem(
                HmChatAction.chatSettings,
                Icons.tune,
                'Chat Settings',
              ),
            ],
            [HmMenuItem(HmChatAction.liveMode, Icons.graphic_eq, 'Live Mode')],
            [
              HmMenuItem(HmChatAction.terminal, Icons.terminal, 'Terminal'),
              HmMenuItem(HmChatAction.execution, Icons.code, 'Execution'),
            ],
            [
              HmMenuItem(HmChatAction.routines, Icons.schedule, 'Routines'),
              HmMenuItem(
                HmChatAction.artifacts,
                Icons.inventory_2_outlined,
                'Artifacts',
              ),
              HmMenuItem(
                HmChatAction.council,
                Icons.groups_2_outlined,
                'Council',
              ),
            ],
            [
              HmMenuItem(
                HmChatAction.archive,
                Icons.archive_outlined,
                'Archive',
              ),
              HmMenuItem(
                HmChatAction.delete,
                Icons.delete_outline,
                'Delete',
                danger: true,
              ),
            ],
          ],
        );
        if (picked != null) await onAction(picked);
      },
    );
  }
}

@immutable
class HmMenuItem<T> {
  const HmMenuItem(this.value, this.icon, this.label, {this.danger = false});
  final T value;
  final IconData icon;
  final String label;
  final bool danger;
}

/// The rounded popover menu anchored under the top-right control, grouped
/// with dividers between groups.
Future<T?> showHmMenu<T>(
  BuildContext context, {
  required List<List<HmMenuItem<T>>> groups,
}) {
  final c = NgColors.of(context);
  final top =
      MediaQuery.of(context).padding.top +
      HmMetrics.headerTop +
      HmMetrics.roundButton +
      6;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (context, _, _) => Stack(
      children: [
        Positioned(
          top: top,
          right: HmMetrics.edge,
          width: 244,
          child: Material(
            color: c.surface,
            elevation: 8,
            shadowColor: c.menuShadow,
            borderRadius: BorderRadius.circular(HmMetrics.groupRadius),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var g = 0; g < groups.length; g++) ...[
                    if (g > 0)
                      Divider(
                        height: 1,
                        indent: 12,
                        endIndent: 12,
                        color: c.stroke,
                      ),
                    for (final item in groups[g])
                      InkWell(
                        onTap: () => Navigator.of(context).pop(item.value),
                        child: SizedBox(
                          height: 56,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: Row(
                              children: [
                                Icon(
                                  item.icon,
                                  size: 24,
                                  color: item.danger ? c.danger : c.text,
                                ),
                                const SizedBox(width: 18),
                                // A long label (or large text) ellipsizes
                                // instead of overflowing the fixed width.
                                Flexible(
                                  child: Text(
                                    item.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: HmType.row.copyWith(
                                      color: item.danger ? c.danger : c.text,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    ),
    transitionBuilder: (context, a, _, child) => FadeTransition(
      opacity: a,
      child: ScaleTransition(
        alignment: Alignment.topRight,
        scale: Tween(
          begin: 0.92,
          end: 1.0,
        ).animate(CurvedAnimation(parent: a, curve: Curves.easeOut)),
        child: child,
      ),
    ),
  );
}

/// Chat Settings: what this chat runs on (model + effort) and its title.
Future<void> showHmChatSettings(BuildContext context, NgChatController chat) =>
    showNgModelSheet(context, chat);

/// What the chat's bot is doing, from the chat and the composer's mic alone:
/// the person dictating is listening (even mid-turn, to steer); a running turn
/// before reply text is thinking, streaming reply text is speaking; a failed
/// last turn (or a refused send) is an error, else idle. With reduced motion every moving state
/// is asleep; an error still shows, since it is news and does not move.
HmAvatarState hmAvatarStateOf(
  NgChatController chat, {
  bool listening = false,
  bool reducedMotion = false,
}) {
  final HmAvatarState state;
  if (listening) {
    state = HmAvatarState.listening;
  } else if (chat.running) {
    final last = chat.items.isEmpty ? null : chat.items.last;
    state = last is NgAssistantItem && last.open && last.text.isNotEmpty
        ? HmAvatarState.speaking
        : HmAvatarState.thinking;
  } else {
    final last = chat.items.isEmpty ? null : chat.items.last;
    final refused = last is NgUserItem && last.failure != null;
    state = chat.lastTurnFailed || refused
        ? HmAvatarState.error
        : HmAvatarState.idle;
  }
  if (reducedMotion && state != HmAvatarState.error) {
    return HmAvatarState.asleep;
  }
  return state;
}
