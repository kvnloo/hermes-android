/// Card gallery: every kind and fixture of the vendored ephemeral-ui catalog.
///
/// Opened from Settings. Shows the catalog version and pinned commit so a
/// screenshot says which catalog it is; cross-app parity is the gallery test
/// passing at the same `catalog-v<VERSION>` in every app.
library;

import 'package:flutter/material.dart';

import '../theme/hermes_theme.dart';
import 'ephemeral_card.dart';
import 'ephemeral_catalog.dart';

class EphemeralGalleryScreen extends StatefulWidget {
  const EphemeralGalleryScreen({super.key, this.catalog});

  /// Injected in tests; the vendored asset otherwise.
  final Future<EphemeralCatalog>? catalog;

  @override
  State<EphemeralGalleryScreen> createState() => _EphemeralGalleryScreenState();
}

class _EphemeralGalleryScreenState extends State<EphemeralGalleryScreen> {
  late final Future<EphemeralCatalog> _catalog =
      widget.catalog ?? EphemeralCatalog.load();
  String? _group;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Card gallery')),
      body: FutureBuilder<EphemeralCatalog>(
        future: _catalog,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(HermesSpacing.lg),
                child: Text(
                  'The card catalog could not be read: ${snapshot.error}',
                  key: const Key('ephemeral-gallery-error'),
                ),
              ),
            );
          }
          final catalog = snapshot.data;
          if (catalog == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return _body(context, catalog);
        },
      ),
    );
  }

  Widget _body(BuildContext context, EphemeralCatalog catalog) {
    final tokens = HermesTokens.of(context);
    final groups = catalog.groups;
    final kinds = _group == null ? catalog.kinds : groups[_group] ?? const [];
    final pin = catalog.pin;
    return CustomScrollView(
      key: const Key('ephemeral-gallery-scroll'),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              HermesSpacing.lg,
              HermesSpacing.md,
              HermesSpacing.lg,
              0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ephemeral-ui catalog v${catalog.version}',
                  key: const Key('ephemeral-gallery-version'),
                  style: tokens.typography.section.copyWith(
                    color: tokens.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${catalog.kinds.length} kinds · ${catalog.fixtureCount} '
                  'fixtures${pin == null ? '' : ' · pinned ${pin.shortCommit}'}'
                  ' · read-only',
                  style: tokens.typography.label.copyWith(color: tokens.muted),
                ),
                const SizedBox(height: HermesSpacing.sm),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _filter('All', null),
                      for (final group in groups.keys)
                        _filter('$group ${groups[group]!.length}', group),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            HermesSpacing.lg,
            HermesSpacing.sm,
            HermesSpacing.lg,
            HermesSpacing.xxl,
          ),
          sliver: SliverList.builder(
            itemCount: kinds.length,
            itemBuilder: (context, index) =>
                EphemeralKindSection(kind: kinds[index]),
          ),
        ),
      ],
    );
  }

  Widget _filter(String label, String? group) => Padding(
    padding: const EdgeInsets.only(right: HermesSpacing.xs),
    child: ChoiceChip(
      key: ValueKey('ephemeral-gallery-group-${group ?? 'all'}'),
      label: Text(label),
      selected: _group == group,
      onSelected: (_) => setState(() => _group = group),
    ),
  );
}

/// One kind: its title row and a cell per fixture.
class EphemeralKindSection extends StatelessWidget {
  const EphemeralKindSection({super.key, required this.kind});

  final EphemeralKind kind;

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    return Padding(
      key: ValueKey('ephemeral-kind-${kind.kind}'),
      padding: const EdgeInsets.only(bottom: HermesSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: kind.label,
                  style: tokens.typography.body.copyWith(
                    color: tokens.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                TextSpan(
                  text:
                      '  ${kind.kind} · ${kind.group}'
                      '${kind.programmable ? ' · programmable' : ''}',
                  style: tokens.typography.label.copyWith(color: tokens.muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: HermesSpacing.xs),
          for (final fixture in kind.fixtures)
            EphemeralFixtureCell(kind: kind, fixture: fixture),
        ],
      ),
    );
  }
}

/// A gallery cell: the fixture id over its card.
class EphemeralFixtureCell extends StatelessWidget {
  const EphemeralFixtureCell({
    super.key,
    required this.kind,
    required this.fixture,
  });

  final EphemeralKind kind;
  final EphemeralFixture fixture;

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    return Padding(
      key: ValueKey('ephemeral-cell-${fixture.id}'),
      padding: const EdgeInsets.only(bottom: HermesSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${fixture.id} · ${fixture.state.name}',
            style: tokens.typography.mono.copyWith(
              fontSize: 11,
              color: tokens.muted,
            ),
          ),
          EphemeralCardView(data: EphemeralCardData.fixture(kind, fixture)),
        ],
      ),
    );
  }
}
