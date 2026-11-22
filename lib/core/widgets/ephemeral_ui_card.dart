// Ephemeral-UI answer cards: a ```ephemeral-ui fence holding one card.v0
// JSON object ({"kind", "app", "title", ...}) that agents with the glide
// prompt emit. Desktop frontends draw it with the ephemeral-ui kit; this
// client has no kit, so it draws an inert native summary of what the agent
// wrote: kind and app, the title, the text values, the fields and the button
// labels. Nothing in a card can run, open, fetch or send; buttons are labels.
// A fence that is not a valid card stays a code block.
import 'dart:convert';

import 'package:flutter/material.dart';

import '../theme/hermes_theme.dart';

/// The fence info string that marks a card.
const ephemeralUiLanguage = 'ephemeral-ui';

final _fence = RegExp(
  r'^[ ]{0,3}```ephemeral-ui[ \t]*\r?\n([\s\S]*?)^[ ]{0,3}```[ \t]*$\n?',
  multiLine: true,
);

/// The sources of every closed ephemeral-ui fence in [text], in order.
List<String> ephemeralUiFences(String text) => [
  for (final m in _fence.allMatches(text)) m.group(1)!,
];

/// [text] with its ephemeral-ui fences removed: what is worth saying aloud.
String withoutEphemeralUi(String text) =>
    text.replaceAll(_fence, '').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();

/// One validated card.v0 document, display fields only.
@immutable
class EphemeralUiCardData {
  const EphemeralUiCardData({
    required this.kind,
    required this.app,
    this.title,
    this.subject,
    this.status,
    this.texts = const [],
    this.fields = const [],
    this.buttons = const [],
  });

  final String kind;
  final String app;
  final String? title;
  final String? subject;
  final String? status;

  /// summary, description, text, body, message, query, label, note: in that
  /// order, the ones present.
  final List<String> texts;
  final List<(String, String)> fields;
  final List<String> buttons;

  static const maxSourceBytes = 64 * 1024;
  static const maxText = 2048;
  static const _textKeys = [
    'summary',
    'description',
    'text',
    'body',
    'message',
    'query',
    'label',
    'note',
  ];
  static final _id = RegExp(r'^[a-z0-9][a-z0-9._/-]{0,63}$');
  // C0/C1 controls except tab and newlines, and bidi overrides/isolates.
  static final _unsafe = RegExp(
    '[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F'
    '\u202A-\u202E\u2066-\u2069]',
  );

  /// The card in [source], or null when it is not a valid card (then the
  /// fence shows as code).
  static EphemeralUiCardData? tryParse(String source) {
    if (utf8.encode(source).length > maxSourceBytes) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final kind = decoded['kind'];
    final app = decoded['app'];
    if (kind is! String || !_id.hasMatch(kind)) return null;
    if (app is! String || !_id.hasMatch(app)) return null;

    String? text(Object? value) {
      if (value is! String) return null;
      final clean = value.trim();
      if (clean.isEmpty) return null;
      if (_unsafe.hasMatch(clean)) throw const FormatException('unsafe text');
      return clean.length > maxText ? '${clean.substring(0, maxText)}…' : clean;
    }

    try {
      final fields = <(String, String)>[];
      final rawFields = decoded['fields'];
      if (rawFields is Map) {
        for (final entry in rawFields.entries.take(16)) {
          final label = text(entry.key);
          final value = entry.value;
          final shown = value is num || value is bool ? '$value' : text(value);
          if (label != null && shown != null) fields.add((label, shown));
        }
      }
      final buttons = <String>[];
      final rawButtons = decoded['buttons'];
      if (rawButtons is List) {
        for (final b in rawButtons.take(8)) {
          final label = text(b is Map ? b['label'] : b);
          if (label != null) buttons.add(label);
        }
      }
      return EphemeralUiCardData(
        kind: kind,
        app: app,
        title: text(decoded['title']),
        subject: text(decoded['subject']),
        status: text(decoded['status']),
        texts: [for (final key in _textKeys) ?text(decoded[key])],
        fields: fields,
        buttons: buttons,
      );
    } on FormatException {
      return null;
    }
  }
}

/// "pr-merge" → "Pr merge": a readable fallback title from the kind.
String _readable(String kind) {
  final words = kind.split(RegExp(r'[-_./]+')).where((w) => w.isNotEmpty);
  final text = words.join(' ');
  return text.isEmpty ? kind : '${text[0].toUpperCase()}${text.substring(1)}';
}

/// The inert native card for one [EphemeralUiCardData].
class EphemeralUiCard extends StatelessWidget {
  const EphemeralUiCard({super.key, required this.card});

  final EphemeralUiCardData card;

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    final type = tokens.typography;
    final title = card.title ?? _readable(card.kind);
    return Semantics(
      container: true,
      label: '$title, ${card.app} ${card.kind} card',
      child: Container(
        key: const Key('ephemeral-ui-card'),
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: HermesSpacing.sm),
        padding: const EdgeInsets.all(HermesSpacing.md),
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: HermesRadius.card,
          border: Border.all(color: tokens.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.dashboard_outlined, size: 18, color: tokens.muted),
                const SizedBox(width: HermesSpacing.sm),
                Expanded(
                  child: Text(
                    title,
                    style: type.section.copyWith(color: tokens.onSurface),
                  ),
                ),
                const SizedBox(width: HermesSpacing.sm),
                _Pill(text: '${card.app} · ${card.kind}', tokens: tokens),
              ],
            ),
            if (card.subject != null) ...[
              const SizedBox(height: HermesSpacing.sm),
              Text(
                card.subject!,
                style: type.body.copyWith(
                  color: tokens.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (card.status != null) ...[
              const SizedBox(height: HermesSpacing.sm),
              _Pill(text: card.status!, tokens: tokens, accent: true),
            ],
            for (final text in card.texts) ...[
              const SizedBox(height: HermesSpacing.sm),
              Text(text, style: type.body.copyWith(color: tokens.onSurface)),
            ],
            if (card.fields.isNotEmpty) ...[
              const SizedBox(height: HermesSpacing.sm),
              for (final (label, value) in card.fields)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 2,
                        child: Text(
                          label,
                          style: type.label.copyWith(color: tokens.muted),
                        ),
                      ),
                      const SizedBox(width: HermesSpacing.sm),
                      Expanded(
                        flex: 3,
                        child: Text(
                          value,
                          style: type.label.copyWith(color: tokens.onSurface),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            if (card.buttons.isNotEmpty) ...[
              const SizedBox(height: HermesSpacing.md),
              Wrap(
                spacing: HermesSpacing.sm,
                runSpacing: HermesSpacing.sm,
                children: [
                  for (final label in card.buttons)
                    // A label only: the card cannot act.
                    _Pill(text: label, tokens: tokens, outlined: true),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.text,
    required this.tokens,
    this.accent = false,
    this.outlined = false,
  });

  final String text;
  final HermesTokens tokens;
  final bool accent;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HermesSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: outlined
            ? null
            : accent
            ? tokens.accentContainer
            : tokens.raised,
        borderRadius: BorderRadius.circular(HermesRadius.lg),
        border: outlined ? Border.all(color: tokens.border) : null,
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: tokens.typography.label.copyWith(
          color: accent ? tokens.onAccentContainer : tokens.muted,
        ),
      ),
    );
  }
}
