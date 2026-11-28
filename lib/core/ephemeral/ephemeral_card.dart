/// Native, read-only renderer for ephemeral-ui cards.
///
/// A card is drawn straight from its props (the kit's `spec`), so a gallery
/// cell and a chat card for the same fixture show the same data. Every
/// catalog kind has an explicit entry in [ephemeralKindLayouts]; a kind the
/// catalog adds without an entry fails the gallery coverage test.
library;

import 'package:flutter/material.dart';

import '../theme/ephemeral_service_theme.dart';
import '../theme/hermes_theme.dart';
import 'ephemeral_catalog.dart';
import 'ephemeral_card_style.dart';
import 'ephemeral_layouts.dart';

export 'ephemeral_layouts.dart';
export 'ephemeral_card_style.dart'
    show EphemeralCardStyle, EphemeralCardPreferences, ephemeralCardStyle;

/// What a renderer needs to draw one card.
final class EphemeralCardData {
  const EphemeralCardData({
    required this.kind,
    required this.props,
    this.label,
    this.group,
    this.appId,
    this.appName,
    this.appInCatalog = true,
    this.fixtureId,
    this.footnote,
  });

  /// Builds the card for a catalog fixture: props are the fixture's props.
  factory EphemeralCardData.fixture(
    EphemeralKind kind,
    EphemeralFixture fixture,
  ) {
    final app = kind.app(fixture.appId);
    return EphemeralCardData(
      kind: kind.kind,
      props: fixture.props,
      label: kind.label,
      group: kind.group,
      appId: fixture.appId,
      appName: app?.name,
      appInCatalog: app?.inCatalog ?? true,
      fixtureId: fixture.id,
    );
  }

  final String kind;
  final Map<String, Object?> props;
  final String? label;
  final String? group;
  final String? appId;
  final String? appName;
  final bool appInCatalog;
  final String? fixtureId;

  /// Shown under the card in chat: where its data came from.
  final String? footnote;

  /// The kit marks a card with no data by an `unavailable` reason.
  String? get unavailable {
    final reason = props['unavailable'];
    return reason is String && reason.isNotEmpty ? reason : null;
  }
}

/// Keys every renderer leaves to the header, never to the body.
const _headerKeys = {'kind', 'app', 'unavailable'};

class EphemeralCardView extends StatelessWidget {
  const EphemeralCardView({super.key, required this.data});

  final EphemeralCardData data;

  /// The props this cell renders from (props parity in the gallery test).
  Map<String, Object?> get props => data.props;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: ephemeralCardStyle,
    builder: (context, style, _) {
      final theme = Theme.of(context);
      final palette = style == EphemeralCardStyle.serviceNative
          ? serviceCardPalette(data.appId, theme.brightness)
          : null;
      final card = Builder(
        key: ValueKey('ephemeral-style-${style.name}'),
        builder: (context) => _buildCard(context, palette),
      );
      if (palette == null) return card;
      return Theme(
        data: theme.copyWith(
          extensions: [
            ...theme.extensions.values.where((e) => e is! HermesTokens),
            serviceCardTokens(palette),
          ],
        ),
        child: card,
      );
    },
  );

  Widget _buildCard(BuildContext context, ServiceCardPalette? palette) {
    final tokens = HermesTokens.of(context);
    final layout = ephemeralKindLayouts[data.kind];
    final unavailable = data.unavailable;
    final body = <Widget>[];
    if (unavailable != null) {
      body.add(_Unavailable(reason: unavailable));
    } else if (layout == null) {
      body.add(_Unsupported(kind: data.kind));
    } else if (palette != null &&
        (data.appId == 'github' || data.appId == 'github-actions') &&
        data.kind == 'merge' &&
        (data.props['input'] == null || data.props['input'] is Map)) {
      final input = data.props['input'];
      body.add(
        _PullRequest(
          values: input is Map ? input.cast<String, Object?>() : data.props,
        ),
      );
    } else {
      final inbox =
          palette != null &&
          data.appId == 'gmail' &&
          data.kind == 'inbox' &&
          data.props['results'] is List;
      final hero = inbox
          ? _Inbox(
              query: data.props['query'],
              results: data.props['results'] as List,
            )
          : _hero(layout);
      if (hero != null) body.add(hero);
      final rest = <String, Object?>{
        for (final entry in data.props.entries)
          if (!_headerKeys.contains(entry.key) &&
              !layout.heroKeys.contains(entry.key) &&
              !(inbox && (entry.key == 'query' || entry.key == 'results')))
            entry.key: entry.value,
      };
      if (rest.isNotEmpty) body.add(_Fields(values: rest, depth: 0));
    }
    return Container(
      key: ValueKey('ephemeral-card-${data.fixtureId ?? data.kind}'),
      margin: const EdgeInsets.symmetric(vertical: HermesSpacing.xs),
      padding: const EdgeInsets.all(HermesSpacing.md),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: palette == null
            ? HermesRadius.card
            : BorderRadius.circular(palette.radius),
        border: Border.all(color: tokens.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(data: data, palette: palette),
          for (final widget in body) ...[
            const SizedBox(height: HermesSpacing.sm),
            widget,
          ],
          if (data.footnote case final footnote?) ...[
            const SizedBox(height: HermesSpacing.sm),
            Text(
              footnote,
              key: const Key('ephemeral-footnote'),
              style: tokens.typography.label.copyWith(color: tokens.muted),
            ),
          ],
        ],
      ),
    );
  }

  Widget? _hero(EphemeralLayout layout) {
    // Data and appInput fixtures carry the document under `input`; the hero
    // reads a key from there when the spec has no top-level value.
    final input = data.props['input'];
    Object? lookup(String? key) {
      if (key == null) return null;
      final value = data.props[key];
      if (value == null && input is Map) return input[key];
      return value;
    }

    switch (layout.type) {
      case EphemeralLayoutType.fields:
        return null;
      case EphemeralLayoutType.metric:
        return _Metric(
          value: lookup(layout.a),
          unit: lookup(layout.b),
          delta: lookup(layout.c),
          caption: lookup(layout.d),
        );
      case EphemeralLayoutType.meter:
        return _Meter(used: lookup(layout.a), limit: lookup(layout.b));
      case EphemeralLayoutType.route:
        return _Route(from: lookup(layout.a), to: lookup(layout.b));
      case EphemeralLayoutType.messages:
        return _Messages(items: lookup(layout.a));
    }
  }
}

// ---------------------------------------------------------------------------
// Formatting

/// Human text for a scalar; never `null`, `undefined` or `NaN`.
String ephemeralScalar(Object? value, {String? key}) {
  if (value == null) return '—';
  if (value is bool) return value ? 'yes' : 'no';
  if (value is int) {
    final isTime =
        key != null &&
        (key == 'at' || key.endsWith('At')) &&
        value > 100000000000;
    if (isTime) {
      return DateTime.fromMillisecondsSinceEpoch(
        value,
        isUtc: true,
      ).toIso8601String().replaceFirst('.000Z', 'Z');
    }
    return _grouped(value);
  }
  if (value is double) {
    if (!value.isFinite) return '—';
    if (value == value.truncateToDouble() && value.abs() < 1e15) {
      return _grouped(value.toInt());
    }
    final fixed = value.toStringAsFixed(2);
    return fixed
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }
  if (value is String) return value.isEmpty ? '—' : value;
  if (value is List) return '${value.length} items';
  if (value is Map) return '${value.length} fields';
  return value.toString();
}

String _grouped(int value) {
  final digits = value.abs().toString();
  if (digits.length <= 4) return value.toString();
  final out = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// `distance_km` → `Distance km`, `capturedAt` → `Captured at`.
String ephemeralLabel(String key) {
  final spaced = key
      .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .replaceAll(RegExp(r'[_\-]+'), ' ')
      .trim()
      .toLowerCase();
  if (spaced.isEmpty) return key;
  return spaced[0].toUpperCase() + spaced.substring(1);
}

/// Keys whose string lists are ordered steps rather than a set of tags.
const _stepKeys = {'pipeline', 'stages', 'steps', 'ops', 'progression'};

/// The field of an object row that names it.
const _nameKeys = [
  'name',
  'title',
  'subject',
  'label',
  'tool',
  'who',
  'callsign',
  'id',
];

// ---------------------------------------------------------------------------
// Pieces

class _Header extends StatelessWidget {
  const _Header({required this.data, required this.palette});

  final ServiceCardPalette? palette;

  final EphemeralCardData data;

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    final appId = data.appId ?? '';
    final appName = data.appName ?? (appId.isEmpty ? data.kind : appId);
    final letters = appName
        .split(RegExp(r'[\s\-_.]+'))
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    var hash = 0;
    for (final unit in appId.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    // Monogram tints come from the active tokens, so every theme recolours
    // them; host apps outside the catalog stay neutral.
    final tints = [
      tokens.accent,
      tokens.running,
      tokens.success,
      tokens.warning,
      tokens.blocked,
      tokens.danger,
    ];
    final tint = palette != null
        ? tokens.accent
        : data.appInCatalog
        ? tints[hash % tints.length]
        : tokens.muted;
    return Row(
      children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: tint.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(HermesRadius.sm),
            border: Border.all(color: tint.withValues(alpha: 0.5)),
          ),
          child: palette?.icon != null
              ? Icon(palette!.icon, color: tint, size: 18)
              : Text(
                  letters.isEmpty ? '?' : letters,
                  style: tokens.typography.label.copyWith(
                    color: tint,
                    fontWeight: FontWeight.w700,
                  ),
                ),
        ),
        const SizedBox(width: HermesSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                data.label ?? ephemeralLabel(data.kind),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tokens.typography.body.copyWith(
                  color: tokens.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                appName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tokens.typography.label.copyWith(color: tokens.muted),
              ),
            ],
          ),
        ),
        if (palette == null)
          _Chip(text: data.kind, mono: true)
        else if (palette?.icon == null)
          Flexible(child: _Chip(text: data.kind, mono: true)),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, this.mono = false, this.strong = false});

  final String text;
  final bool mono;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    final base = mono ? tokens.typography.mono : tokens.typography.label;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: strong ? tokens.accentContainer : tokens.raised,
        borderRadius: BorderRadius.circular(HermesRadius.sm),
        border: Border.all(color: tokens.border),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: base.copyWith(
          fontSize: 11,
          color: strong ? tokens.onAccentContainer : tokens.onSurface,
        ),
      ),
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    return Container(
      key: const Key('ephemeral-unavailable'),
      padding: const EdgeInsets.all(HermesSpacing.md),
      decoration: BoxDecoration(
        color: tokens.raised,
        borderRadius: BorderRadius.circular(HermesRadius.sm),
        border: Border.all(color: tokens.border),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 18, color: tokens.muted),
          const SizedBox(width: HermesSpacing.sm),
          Expanded(
            child: Text(
              'Unavailable · $reason',
              style: tokens.typography.body.copyWith(color: tokens.muted),
            ),
          ),
        ],
      ),
    );
  }
}

class _Unsupported extends StatelessWidget {
  const _Unsupported({required this.kind});

  final String kind;

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    return Container(
      key: const Key('ephemeral-unsupported'),
      padding: const EdgeInsets.all(HermesSpacing.md),
      decoration: BoxDecoration(
        color: tokens.raised,
        borderRadius: BorderRadius.circular(HermesRadius.sm),
        border: Border.all(color: tokens.warning),
      ),
      child: Text(
        'Not supported on Android yet: $kind',
        style: tokens.typography.body.copyWith(color: tokens.warning),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.value, this.unit, this.delta, this.caption});

  final Object? value;
  final Object? unit;
  final Object? delta;
  final Object? caption;

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    final d = delta;
    final up = d is num && d >= 0;
    return Column(
      key: const Key('ephemeral-metric'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (caption != null)
          Text(
            ephemeralScalar(caption),
            style: tokens.typography.label.copyWith(color: tokens.muted),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: Text(
                ephemeralScalar(value),
                style: tokens.typography.title.copyWith(
                  color: tokens.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (unit != null) ...[
              const SizedBox(width: HermesSpacing.xs),
              Text(
                ephemeralScalar(unit),
                style: tokens.typography.body.copyWith(color: tokens.muted),
              ),
            ],
            if (d is num) ...[
              const SizedBox(width: HermesSpacing.sm),
              Icon(
                up ? Icons.trending_up : Icons.trending_down,
                size: 16,
                color: up ? tokens.success : tokens.danger,
              ),
              Text(
                '${up ? '+' : ''}${ephemeralScalar(d)}%',
                style: tokens.typography.label.copyWith(
                  color: up ? tokens.success : tokens.danger,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _Meter extends StatelessWidget {
  const _Meter({required this.used, required this.limit});

  final Object? used;
  final Object? limit;

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    final u = used;
    final l = limit;
    final ratio = u is num && l is num && l > 0
        ? (u / l).clamp(0.0, 1.0).toDouble()
        : 0.0;
    final hot = ratio >= 0.8;
    return Column(
      key: const Key('ephemeral-meter'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${ephemeralScalar(u)} / ${ephemeralScalar(l)} · ${(ratio * 100).round()}%',
          style: tokens.typography.body.copyWith(color: tokens.onSurface),
        ),
        const SizedBox(height: HermesSpacing.xs),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 6,
            backgroundColor: tokens.raised,
            color: hot ? tokens.warning : tokens.accent,
          ),
        ),
      ],
    );
  }
}

class _Route extends StatelessWidget {
  const _Route({required this.from, required this.to});

  final Object? from;
  final Object? to;

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    final style = tokens.typography.section.copyWith(color: tokens.onSurface);
    return Row(
      key: const Key('ephemeral-route'),
      children: [
        Flexible(child: Text(ephemeralScalar(from), style: style)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HermesSpacing.sm),
          child: Icon(Icons.arrow_forward, size: 18, color: tokens.accent),
        ),
        Flexible(child: Text(ephemeralScalar(to), style: style)),
      ],
    );
  }
}

/// Service-native pull request preview. The merge action, if any, belongs
/// to a separate host approval, not to this model-supplied card.
class _PullRequest extends StatelessWidget {
  const _PullRequest({required this.values});

  final Map<String, Object?> values;

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    final title = values['title'];
    final number = values['number'] ?? values['pr'];
    final state = values['state'];
    final checks = values['checks'];
    final conflicts = values['conflicts'];
    final commits = values['commits'];
    final rest = <String, Object?>{
      for (final entry in values.entries)
        if (!_headerKeys.contains(entry.key) &&
            !const {
              'title',
              'number',
              'pr',
              'state',
              'head',
              'base',
              'checks',
              'conflicts',
              'commits',
            }.contains(entry.key))
          entry.key: entry.value,
    };
    final body = tokens.typography.body.copyWith(color: tokens.onSurface);
    final label = tokens.typography.label.copyWith(color: tokens.muted);
    return Column(
      key: const Key('ephemeral-pull-request'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title is String && title.isNotEmpty)
          Text(title, style: body.copyWith(fontWeight: FontWeight.w700)),
        if (number != null ||
            state != null ||
            (conflicts is num && conflicts > 0))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (number != null) _Chip(text: '#${ephemeralScalar(number)}'),
                if (state is String && state.isNotEmpty)
                  _Chip(text: state, strong: true),
                if (conflicts is num && conflicts > 0)
                  _Chip(text: '${ephemeralScalar(conflicts)} conflicts'),
              ],
            ),
          ),
        if (values['head'] != null && values['base'] != null)
          _Route(from: values['head'], to: values['base']),
        if (checks is num)
          Text('${ephemeralScalar(checks)} checks', style: label),
        if (checks is List && checks.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('Checks', style: label),
          for (final check in checks.take(6))
            if (check is Map)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      switch (check['status']) {
                        'pass' => Icons.check_circle_outline,
                        'fail' => Icons.error_outline,
                        'running' => Icons.timelapse,
                        _ => Icons.remove_circle_outline,
                      },
                      color: switch (check['status']) {
                        'pass' => tokens.success,
                        'fail' => tokens.danger,
                        'running' => tokens.warning,
                        _ => tokens.muted,
                      },
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(ephemeralScalar(check['name']), style: body),
                    ),
                    if (check['detail'] case final String detail)
                      Flexible(
                        child: Text(
                          detail,
                          style: label,
                          textAlign: TextAlign.end,
                        ),
                      ),
                  ],
                ),
              ),
          if (checks.length > 6)
            Text('+${checks.length - 6} more checks', style: label),
        ],
        if (commits is List && commits.isNotEmpty)
          Text('${commits.length} commits', style: label),
        if (rest.isNotEmpty) _Fields(values: rest, depth: 0),
      ],
    );
  }
}

/// A read-only inbox preview. Do not invent senders or dates: some kit
/// fixtures include only a message id and subject.
class _Inbox extends StatelessWidget {
  const _Inbox({required this.query, required this.results});

  final Object? query;
  final List<Object?> results;

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    final text = tokens.typography.body.copyWith(color: tokens.onSurface);
    final muted = tokens.typography.label.copyWith(color: tokens.muted);
    return Column(
      key: const Key('ephemeral-inbox'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (query is String && (query as String).isNotEmpty)
          DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.raised,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.search, color: tokens.muted, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(query as String, style: text)),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 2),
          child: Text(
            results.isEmpty ? 'No results' : 'Top results',
            style: muted,
          ),
        ),
        for (final row in results.take(6))
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: tokens.border)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                ephemeralScalar(row is Map ? row['subject'] ?? row['id'] : row),
                style: text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        if (results.length > 6)
          Text('+${results.length - 6} more', style: muted),
      ],
    );
  }
}

class _Messages extends StatelessWidget {
  const _Messages({required this.items});

  final Object? items;

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    final list = items is List ? items as List : const [];
    final rows = <(String, String)>[];
    for (final item in list.take(6)) {
      if (item is Map) {
        rows.add((
          ephemeralScalar(item['who'] ?? item['from'] ?? item['title']),
          ephemeralScalar(item['text'] ?? item['body'] ?? item['detail']),
        ));
      } else if (item is List && item.isNotEmpty) {
        rows.add((
          ephemeralScalar(item.first),
          item.length > 1
              ? item.skip(1).map((v) => ephemeralScalar(v)).join(' · ')
              : '',
        ));
      } else {
        rows.add(('', ephemeralScalar(item)));
      }
    }
    return Column(
      key: const Key('ephemeral-messages'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (who, text) in rows)
          Container(
            margin: const EdgeInsets.only(bottom: HermesSpacing.xs),
            padding: const EdgeInsets.symmetric(
              horizontal: HermesSpacing.sm,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: tokens.raised,
              borderRadius: BorderRadius.circular(HermesRadius.sm),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (who.isNotEmpty)
                  Text(
                    who,
                    style: tokens.typography.label.copyWith(
                      color: tokens.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (text.isNotEmpty)
                  Text(
                    text,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.typography.body.copyWith(color: tokens.muted),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Generic, depth-limited view of the remaining props.
class _Fields extends StatelessWidget {
  const _Fields({required this.values, required this.depth});

  static const maxDepth = 2;
  static const maxRows = 4;

  final Map<String, Object?> values;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    final labelStyle = tokens.typography.label.copyWith(color: tokens.muted);
    final valueStyle = tokens.typography.body.copyWith(color: tokens.onSurface);
    final children = <Widget>[];
    for (final MapEntry(:key, :value) in values.entries) {
      Widget content;
      var stacked = true;
      if (value is List) {
        content = _list(context, key, value);
      } else if (value is Map) {
        if (depth >= maxDepth) {
          content = Text(ephemeralScalar(value), style: valueStyle);
          stacked = false;
        } else {
          content = Container(
            padding: const EdgeInsets.only(left: HermesSpacing.sm),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: tokens.border, width: 2)),
            ),
            child: _Fields(
              values: value.cast<String, Object?>(),
              depth: depth + 1,
            ),
          );
        }
      } else {
        content = Text(
          ephemeralScalar(value, key: key),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: valueStyle,
        );
        stacked = false;
      }
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ephemeralLabel(key), style: labelStyle),
                    const SizedBox(height: 2),
                    content,
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 96,
                      child: Text(ephemeralLabel(key), style: labelStyle),
                    ),
                    Expanded(child: content),
                  ],
                ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _list(BuildContext context, String key, List<Object?> list) {
    final tokens = HermesTokens.of(context);
    if (list.isEmpty) {
      return Text(
        '—',
        style: tokens.typography.body.copyWith(color: tokens.muted),
      );
    }
    final more = list.length > maxRows * 2 ? list.length - maxRows * 2 : 0;
    if (list.every((v) => v is! Map && v is! List)) {
      final steps = _stepKeys.contains(key);
      final shown = list.take(maxRows * 2).toList();
      return Wrap(
        spacing: 4,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (var i = 0; i < shown.length; i++) ...[
            _Chip(text: ephemeralScalar(shown[i]), strong: steps),
            if (steps && i < shown.length - 1)
              Icon(Icons.chevron_right, size: 14, color: tokens.muted),
          ],
          if (more > 0) _Chip(text: '+$more'),
        ],
      );
    }
    final rows = list.take(maxRows).toList();
    final rest = list.length - rows.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in rows) _row(context, row),
        if (rest > 0)
          Text(
            '+$rest more',
            style: tokens.typography.label.copyWith(color: tokens.muted),
          ),
      ],
    );
  }

  Widget _row(BuildContext context, Object? row) {
    final tokens = HermesTokens.of(context);
    String title;
    String detail;
    if (row is Map) {
      final map = row.cast<String, Object?>();
      final nameKey = _nameKeys.firstWhere(
        (k) => map[k] is String || map[k] is num,
        orElse: () => '',
      );
      title = nameKey.isEmpty ? '' : ephemeralScalar(map[nameKey]);
      detail = [
        for (final MapEntry(:key, :value) in map.entries)
          if (key != nameKey &&
              value != null &&
              value is! Map &&
              value is! List)
            '${ephemeralLabel(key)} ${ephemeralScalar(value, key: key)}',
        for (final MapEntry(:key, :value) in map.entries)
          if (value is List) '${ephemeralLabel(key)} ${value.length}',
      ].join(' · ');
    } else if (row is List) {
      title = row.isEmpty ? '—' : ephemeralScalar(row.first);
      detail = row.skip(1).map((v) => ephemeralScalar(v)).join(' · ');
    } else {
      title = ephemeralScalar(row);
      detail = '';
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: tokens.raised,
        borderRadius: BorderRadius.circular(HermesRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty)
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.typography.body.copyWith(
                color: tokens.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          if (detail.isNotEmpty)
            Text(
              detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: tokens.typography.label.copyWith(color: tokens.muted),
            ),
        ],
      ),
    );
  }
}
