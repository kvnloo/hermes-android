/// Ephemeral-ui cards in chat.
///
/// A reply carries cards as card documents (`card.v0.json`: `kind`, `app`,
/// optional `input`) in an ```ephemeral-ui fence: one card object, an array
/// of them, or `{"title": ..., "cards": [...]}`. Each card resolves against
/// the vendored catalog to the props the kit would draw, and renders with
/// the same native renderer as the gallery. Cards are read-only.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../theme/hermes_theme.dart';
import 'ephemeral_card.dart';
import 'ephemeral_catalog.dart';

/// The fence language that carries cards.
const ephemeralFenceLanguage = 'ephemeral-ui';

final _fence = RegExp(
  r'^[ ]{0,3}```ephemeral-ui[ \t]*\r?\n([\s\S]*?)^[ ]{0,3}```[ \t]*$\n?',
  multiLine: true,
);

// A stopped or interrupted turn can leave a fence open. Its tail is still
// card data, not text for a voice to read.
final _unfinishedFence = RegExp(
  r'^[ ]{0,3}```ephemeral-ui[ \t]*(?:\r?\n[\s\S]*)?$',
  multiLine: true,
);

/// The sources of every closed ephemeral-ui fence in [text], in order.
List<String> ephemeralUiFences(String text) => [
  for (final m in _fence.allMatches(text)) m.group(1)!,
];

/// [text] with its ephemeral-ui fences removed: what is worth saying aloud.
String withoutEphemeralUi(String text) => text
    .replaceAll(_fence, '')
    .replaceAll(_unfinishedFence, '')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();

/// Cards drawn from one fence at most.
const ephemeralFenceMaxCards = 8;

/// Fence bodies larger than this are shown as source only.
const ephemeralFenceMaxBytes = 256 * 1024;

/// One card of a fence: drawable [data], or the [problem] that stops it.
final class EphemeralResolution {
  const EphemeralResolution.card(EphemeralCardData this.data) : problem = null;
  const EphemeralResolution.problem(String this.problem) : data = null;

  final EphemeralCardData? data;
  final String? problem;
}

bool _deepEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a == b;
  return a == b;
}

/// Resolves one card document against [catalog].
///
/// A card equal to a catalog fixture's card draws that fixture's props
/// exactly. Otherwise sample kinds draw the kind's sample for the app,
/// `appInput`/`data` kinds draw the given input, and a data kind with no
/// input draws its unavailable state, as the kit does.
EphemeralResolution resolveEphemeralCard(
  EphemeralCatalog catalog,
  Object? card,
) {
  if (card is! Map || card['kind'] is! String) {
    return const EphemeralResolution.problem(
      'A card needs an object with a "kind".',
    );
  }
  final kindId = card['kind'] as String;
  final kind = catalog.kind(kindId);
  if (kind == null) {
    return EphemeralResolution.problem(
      'Unknown card kind "$kindId" (catalog v${catalog.version}).',
    );
  }
  final rawApp = card['app'];
  if (rawApp != null && rawApp is! String) {
    return const EphemeralResolution.problem('"app" must be a string.');
  }
  final input = card['input'];
  final appId = (rawApp as String?) ?? kind.fixtures.first.appId;

  EphemeralCardData build(Map<String, Object?> props, String note) {
    final app = kind.app(appId);
    return EphemeralCardData(
      kind: kind.kind,
      props: props,
      label: kind.label,
      group: kind.group,
      appId: appId,
      appName: app?.name ?? appId,
      appInCatalog: app?.inCatalog ?? true,
      footnote: note,
    );
  }

  String noteFor(EphemeralFixtureState state) => switch (state) {
    EphemeralFixtureState.unavailable => 'No data supplied',
    EphemeralFixtureState.sample => 'Sample data',
    _ => 'From the card\'s data',
  };

  final probe = <String, Object?>{
    'kind': kind.kind,
    'app': appId,
    'input': ?input,
  };
  for (final fixture in kind.fixtures) {
    if (_deepEquals(fixture.card, probe)) {
      return EphemeralResolution.card(
        build(fixture.props, noteFor(fixture.state)),
      );
    }
  }

  final takesInput = kind.input == 'data' || kind.input == 'appInput';
  final hasInput = input is Map || input is List;
  if (takesInput && hasInput) {
    EphemeralFixture? base;
    for (final fixture in kind.fixtures) {
      if (fixture.state == EphemeralFixtureState.example ||
          fixture.state == EphemeralFixtureState.input) {
        base = fixture;
        break;
      }
    }
    final props = <String, Object?>{
      for (final entry in (base?.props ?? const {}).entries)
        if (entry.key != 'unavailable') entry.key: entry.value,
      'app': appId,
      'input': input,
      'kind': kind.kind,
    };
    return EphemeralResolution.card(build(props, 'From the card\'s data'));
  }

  if (kind.input == 'data') {
    for (final fixture in kind.fixtures) {
      if (fixture.state == EphemeralFixtureState.unavailable) {
        return EphemeralResolution.card(
          build({...fixture.props, 'app': appId}, 'No data supplied'),
        );
      }
    }
  }

  EphemeralFixture? sample;
  for (final fixture in kind.fixtures) {
    if (fixture.state != EphemeralFixtureState.sample) continue;
    sample ??= fixture;
    if (fixture.appId == appId) {
      sample = fixture;
      break;
    }
  }
  sample ??= kind.fixtures.first;
  final props = sample.appId == appId
      ? sample.props
      : {...sample.props, 'app': appId};
  final note = input == null
      ? 'Sample data'
      : 'Sample data · this kind draws no input on Android';
  return EphemeralResolution.card(build(props, note));
}

/// A fence body parsed into card documents.
final class EphemeralFence {
  const EphemeralFence({this.title, required this.cards, this.problem});

  final String? title;
  final List<Object?> cards;

  /// Why the body is not drawable as cards.
  final String? problem;

  /// True when the body is cut off, as while a reply is streaming.
  bool get incomplete => problem == _incomplete;

  static const _incomplete = 'incomplete';

  static EphemeralFence parse(String source) {
    if (utf8.encode(source).length > ephemeralFenceMaxBytes) {
      return const EphemeralFence(
        cards: [],
        problem: 'The card is too large to draw.',
      );
    }
    final Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException catch (error) {
      final trimmed = source.trimRight();
      final cutOff =
          trimmed.isEmpty ||
          error.offset == null ||
          error.offset! >= trimmed.length ||
          error.message.contains('Unexpected end');
      return EphemeralFence(
        cards: const [],
        problem: cutOff ? _incomplete : 'The card is not valid JSON.',
      );
    }
    String? title;
    List<Object?> cards;
    if (json is List) {
      cards = json;
    } else if (json is Map && json['cards'] is List) {
      cards = json['cards'] as List;
      final rawTitle = json['title'];
      if (rawTitle is String && rawTitle.isNotEmpty) title = rawTitle;
    } else if (json is Map) {
      cards = [json];
    } else {
      return const EphemeralFence(
        cards: [],
        problem: 'Expected a card object or a list of cards.',
      );
    }
    if (cards.isEmpty) {
      return const EphemeralFence(
        cards: [],
        problem: 'The fence has no cards.',
      );
    }
    return EphemeralFence(
      title: title,
      cards: cards.take(ephemeralFenceMaxCards).toList(),
    );
  }
}

/// Draws an ```ephemeral-ui fence natively, keeping the source viewable.
class EphemeralUiFence extends StatefulWidget {
  const EphemeralUiFence({super.key, required this.source});

  final String source;

  @override
  State<EphemeralUiFence> createState() => _EphemeralUiFenceState();
}

class _EphemeralUiFenceState extends State<EphemeralUiFence> {
  late EphemeralFence _fence = EphemeralFence.parse(widget.source);
  bool _showSource = false;

  @override
  void didUpdateWidget(covariant EphemeralUiFence oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _fence = EphemeralFence.parse(widget.source);
    }
  }

  @override
  Widget build(BuildContext context) => _body(context);

  Widget _source(BuildContext context) {
    final tokens = HermesTokens.of(context);
    return Container(
      key: const Key('ephemeral-fence-source'),
      width: double.infinity,
      padding: const EdgeInsets.all(HermesSpacing.md),
      decoration: BoxDecoration(
        color: tokens.raised,
        borderRadius: HermesRadius.card,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText(
          widget.source,
          style: tokens.typography.mono.copyWith(color: tokens.onSurface),
        ),
      ),
    );
  }

  Widget _notice(BuildContext context, String message) {
    final tokens = HermesTokens.of(context);
    return Container(
      key: const Key('ephemeral-fence-notice'),
      margin: const EdgeInsets.symmetric(vertical: HermesSpacing.sm),
      padding: const EdgeInsets.all(HermesSpacing.md),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: HermesRadius.card,
        border: Border.all(color: tokens.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 18, color: tokens.muted),
              const SizedBox(width: HermesSpacing.sm),
              Expanded(
                child: Text(
                  message,
                  style: tokens.typography.body.copyWith(
                    color: tokens.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: HermesSpacing.sm),
          _source(context),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final fence = _fence;
    if (fence.incomplete) {
      return _notice(context, 'Card still arriving…');
    }
    if (fence.problem case final problem?) return _notice(context, problem);
    final tokens = HermesTokens.of(context);
    return Padding(
      key: const Key('ephemeral-fence'),
      padding: const EdgeInsets.symmetric(vertical: HermesSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (fence.title case final title?)
            Padding(
              padding: const EdgeInsets.only(bottom: HermesSpacing.xs),
              child: Text(
                title,
                style: tokens.typography.section.copyWith(
                  color: tokens.onSurface,
                ),
              ),
            ),
          EphemeralCardList(cards: fence.cards),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const Key('ephemeral-fence-source-toggle'),
              onPressed: () => setState(() => _showSource = !_showSource),
              icon: Icon(_showSource ? Icons.code_off : Icons.code, size: 16),
              label: Text(_showSource ? 'Hide source' : 'Show source'),
            ),
          ),
          if (_showSource) _source(context),
        ],
      ),
    );
  }
}

/// Card documents resolved against the vendored catalog and drawn natively;
/// a card that cannot be drawn shows why instead of disappearing.
class EphemeralCardList extends StatefulWidget {
  const EphemeralCardList({super.key, required this.cards});

  final List<Object?> cards;

  @override
  State<EphemeralCardList> createState() => _EphemeralCardListState();
}

class _EphemeralCardListState extends State<EphemeralCardList> {
  Future<EphemeralCatalog>? _catalog;

  @override
  Widget build(BuildContext context) {
    final ready = EphemeralCatalog.loaded;
    if (ready != null) return _cards(context, ready);
    return FutureBuilder<EphemeralCatalog>(
      future: _catalog ??= EphemeralCatalog.load(),
      builder: (context, snapshot) {
        final catalog = snapshot.data;
        if (catalog != null) return _cards(context, catalog);
        if (snapshot.hasError) {
          return _problem(context, 'The card catalog could not be read.');
        }
        return const SizedBox(
          key: Key('ephemeral-fence-loading'),
          height: 48,
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        );
      },
    );
  }

  Widget _problem(BuildContext context, String message) {
    final tokens = HermesTokens.of(context);
    return Container(
      key: const Key('ephemeral-fence-problem'),
      margin: const EdgeInsets.symmetric(vertical: HermesSpacing.xs),
      padding: const EdgeInsets.all(HermesSpacing.md),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: HermesRadius.card,
        border: Border.all(color: tokens.warning),
      ),
      child: Text(
        message,
        style: tokens.typography.body.copyWith(color: tokens.onSurface),
      ),
    );
  }

  Widget _cards(BuildContext context, EphemeralCatalog catalog) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final card in widget.cards.take(ephemeralFenceMaxCards))
        switch (resolveEphemeralCard(catalog, card)) {
          EphemeralResolution(:final data?) => EphemeralCardView(data: data),
          EphemeralResolution(:final problem) => _problem(
            context,
            problem ?? 'This card cannot be drawn.',
          ),
        },
    ],
  );
}
