// Settings → Chat: how messages are drawn (Standard or Bubbles), whether
// sending puts the keyboard away, and what new chats show between messages.
// Matches the official Chat page (crawl s016).
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../nextgen/theme/nextgen_theme.dart';
import '../../hm_ui.dart';
import 'settings_kit.dart';
import 'settings_prefs.dart';

class HmChatSettingsScreen extends StatelessWidget {
  const HmChatSettingsScreen({super.key, this.prefs});
  final HmSettingsPrefs? prefs;

  @override
  Widget build(BuildContext context) {
    final p = prefs ?? HmSettingsPrefs.instance;
    Future<void> save(Future<bool> write) async {
      if (!await write && context.mounted) {
        hmSettingsToast(context, "Couldn't save this setting.");
      }
    }

    return ListenableBuilder(
      listenable: p,
      builder: (context, _) => HmPage(
        title: 'Chat',
        children: [
          HmSettingsCard(
            title: 'Chat Style',
            footnote: 'Choose how messages appear in all your conversations.',
            children: [
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final s in HmChatStyle.values) ...[
                      if (s != HmChatStyle.values.first)
                        const SizedBox(width: 12),
                      Expanded(
                        child: _StylePreview(
                          style: s,
                          selected: p.chatStyle == s,
                          onTap: () => unawaited(save(p.setChatStyle(s))),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          HmSettingsCard(
            title: 'Keyboard',
            children: [
              HmToggleTile(
                title: 'Dismiss keyboard after sending',
                description:
                    'Off keeps the keyboard ready for your next message.',
                value: p.dismissKeyboardAfterSend,
                onChanged: (v) =>
                    unawaited(save(p.setDismissKeyboardAfterSend(v))),
              ),
            ],
          ),
          HmSettingsCard(
            icon: Icons.visibility,
            title: 'In New Chats',
            footnote:
                'Each chat can change these in its own settings. Chats you already changed keep their choice.',
            children: [
              HmToggleTile(
                icon: Icons.handyman,
                title: 'Tool calls',
                description: 'General tool activity between messages.',
                value: p.showToolCalls,
                onChanged: (v) => unawaited(save(p.setShowToolCalls(v))),
              ),
              HmToggleTile(
                icon: Icons.smartphone,
                title: 'Device actions',
                description:
                    'Calendar, health and other device requests between messages.',
                value: p.showDeviceActions,
                onChanged: (v) => unawaited(save(p.setShowDeviceActions(v))),
              ),
              HmToggleTile(
                icon: Icons.psychology,
                title: 'Thinking',
                description:
                    'What Hermes reasons through before it answers, when the model shares it.',
                value: p.showThinking,
                onChanged: (v) => unawaited(save(p.setShowThinking(v))),
              ),
              HmToggleTile(
                icon: Icons.unfold_less,
                title: 'Fold finished turns',
                description:
                    'Tuck tool calls and thinking behind one row once Hermes has answered.',
                value: p.foldFinishedTurns,
                onChanged: (v) => unawaited(save(p.setFoldFinishedTurns(v))),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A miniature conversation drawn in [style], with its name and a check.
class _StylePreview extends StatelessWidget {
  const _StylePreview({
    required this.style,
    required this.selected,
    required this.onTap,
  });

  final HmChatStyle style;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final bubbles = style == HmChatStyle.bubbles;
    final textStyle = HmType.caption.copyWith(color: c.text, fontSize: 13);

    Widget bot(String text) => Align(
      alignment: Alignment.centerLeft,
      child: bubbles
          ? _bubble(text, c.surface2, textStyle)
          : Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(text, style: textStyle),
            ),
    );

    Widget me(String text) => Align(
      alignment: Alignment.centerRight,
      child: _bubble(
        text,
        bubbles ? c.accentSoft : c.surface2,
        textStyle.copyWith(color: bubbles ? c.accentText : c.text),
      ),
    );

    return Semantics(
      button: true,
      selected: selected,
      label: style.label,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('hm-chat-style-${style.name}'),
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? c.accent : c.stroke,
              width: selected ? 2.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              bot('Your day is all planned.'),
              const SizedBox(height: 6),
              me('Sounds good!'),
              const SizedBox(height: 6),
              bot('I’ll take care of it.'),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      style.label,
                      style: HmType.row.copyWith(color: c.text),
                    ),
                  ),
                  Icon(
                    selected ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: selected ? c.accent : c.text3,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _bubble(String text, Color bg, TextStyle style) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Text(text, style: style),
  );
}
