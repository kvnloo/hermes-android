// Gallery contract for the shared ephemeral-ui catalog (catalog/README.md):
// pin integrity, coverage of every kind, every fixture mounts, props parity,
// unavailable/example states and the version shown.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/ephemeral/ephemeral_card.dart';
import 'package:hermes_android/core/ephemeral/ephemeral_catalog.dart';
import 'package:hermes_android/core/ephemeral/ephemeral_gallery_screen.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';

final _catalogBytes = File(EphemeralCatalogAssets.catalog).readAsBytesSync();
final _pinJson =
    jsonDecode(File(EphemeralCatalogAssets.pin).readAsStringSync())
        as Map<String, Object?>;
final _pin = EphemeralCatalogPin.fromJson(_pinJson);
final _catalog = EphemeralCatalog.parse(utf8.decode(_catalogBytes), pin: _pin);

Widget _host(Widget child, {Brightness brightness = Brightness.dark}) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: hermesTheme(brightness),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

Iterable<String> _texts(WidgetTester tester, Finder within) sync* {
  for (final element
      in find
          .descendant(of: within, matching: find.byType(RichText))
          .evaluate()) {
    yield (element.widget as RichText).text.toPlainText();
  }
}

void main() {
  group('pinned catalog', () {
    test('vendored copy matches its pin (never edited)', () {
      expect(sha256.convert(_catalogBytes).toString(), _pin.sha256);
      expect(_pin.commit, matches(RegExp(r'^[0-9a-f]{40}$')));
      expect(_catalog.version, _pin.version);
    });

    test('reads only file shape v0 and rejects any other', () {
      final json = jsonDecode(utf8.decode(_catalogBytes)) as Map;
      expect(json['v'], EphemeralCatalog.supportedShape);
      expect(
        () => EphemeralCatalog.parse(jsonEncode({...json, 'v': 1})),
        throwsFormatException,
      );
    });

    test('counts agree with the content', () {
      final json = jsonDecode(utf8.decode(_catalogBytes)) as Map;
      final count = json['count'] as Map;
      expect(_catalog.kinds, hasLength(count['kinds']));
      expect(_catalog.fixtureCount, count['fixtures']);
    });
  });

  group('coverage', () {
    test('the app has a native layout for exactly the catalog kinds', () {
      final catalogKinds = {for (final k in _catalog.kinds) k.kind};
      final drawn = ephemeralKindLayouts.keys.toSet();
      final missing = catalogKinds.difference(drawn);
      final extra = drawn.difference(catalogKinds);
      expect(
        missing,
        isEmpty,
        reason:
            'catalog-v${_catalog.version} has kinds with no Android layout; '
            'add them to ephemeralKindLayouts and run '
            'flutter test test/ephemeral_gallery_golden_test.dart '
            '--update-goldens: $missing',
      );
      expect(
        extra,
        isEmpty,
        reason: 'layouts for kinds not in catalog: $extra',
      );
    });

    testWidgets('an unknown kind renders the unsupported cell', (tester) async {
      await tester.pumpWidget(
        _host(
          const EphemeralCardView(
            data: EphemeralCardData(kind: 'not-a-kind', props: {}),
          ),
        ),
      );
      expect(find.byKey(const Key('ephemeral-unsupported')), findsOneWidget);
    });
  });

  group('every fixture mounts', () {
    for (final kind in _catalog.kinds) {
      testWidgets('kind ${kind.kind}', (tester) async {
        tester.view.physicalSize = const Size(1080, 4000);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(_host(EphemeralKindSection(kind: kind)));
        expect(tester.takeException(), isNull);

        final cards = find.byType(EphemeralCardView);
        expect(cards, findsNWidgets(kind.fixtures.length));
        for (final fixture in kind.fixtures) {
          final cell = find.byKey(ValueKey('ephemeral-cell-${fixture.id}'));
          expect(cell, findsOneWidget, reason: fixture.id);
          final card = find.byKey(ValueKey('ephemeral-card-${fixture.id}'));
          expect(card, findsOneWidget, reason: fixture.id);

          // Props parity: the cell renders straight from fixture.props.
          final view = tester.widget<EphemeralCardView>(
            find.ancestor(of: card, matching: find.byType(EphemeralCardView)),
          );
          expect(
            view.props,
            equals(fixture.props),
            reason: '${fixture.id} props differ from the catalog',
          );

          // Not empty; no undefined/NaN.
          final texts = _texts(tester, card).toList();
          expect(texts.length, greaterThan(3), reason: fixture.id);
          for (final text in texts) {
            expect(text, isNot(contains('undefined')), reason: fixture.id);
            expect(text, isNot(contains('NaN')), reason: fixture.id);
          }
          expect(
            find.descendant(
              of: card,
              matching: find.byKey(const Key('ephemeral-unsupported')),
            ),
            findsNothing,
            reason: '${fixture.id} has no native layout',
          );

          // States.
          final unavailable = find.descendant(
            of: card,
            matching: find.byKey(const Key('ephemeral-unavailable')),
          );
          expect(
            unavailable,
            fixture.state == EphemeralFixtureState.unavailable
                ? findsOneWidget
                : findsNothing,
            reason: '${fixture.id} (${fixture.state.name})',
          );
        }
      });
    }
  });

  group('gallery screen', () {
    testWidgets('shows the catalog version, pin and every group', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: hermesTheme(Brightness.light),
          home: EphemeralGalleryScreen(catalog: Future.value(_catalog)),
        ),
      );
      await tester.pump();
      expect(
        find.text('ephemeral-ui catalog v${_catalog.version}'),
        findsOneWidget,
      );
      expect(find.textContaining('pinned ${_pin.shortCommit}'), findsOneWidget);
      expect(
        find.textContaining(
          '${_catalog.kinds.length} kinds · ${_catalog.fixtureCount} fixtures',
        ),
        findsOneWidget,
      );
      for (final group in _catalog.groups.keys) {
        expect(
          find.byKey(ValueKey('ephemeral-gallery-group-$group')),
          findsOneWidget,
        );
      }
      // The first kind is on screen.
      expect(
        find.byKey(ValueKey('ephemeral-kind-${_catalog.kinds.first.kind}')),
        findsOneWidget,
      );
    });

    testWidgets('scrolls to the last kind and filters by group', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: hermesTheme(Brightness.dark),
          home: EphemeralGalleryScreen(catalog: Future.value(_catalog)),
        ),
      );
      await tester.pump();
      final main = find
          .descendant(
            of: find.byKey(const Key('ephemeral-gallery-scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
      final last = _catalog.kinds.last;
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('ephemeral-kind-${last.kind}')),
        800,
        scrollable: main,
        maxScrolls: 400,
      );
      expect(
        find.byKey(ValueKey('ephemeral-kind-${last.kind}')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('ephemeral-gallery-group-trace')),
        -800,
        scrollable: main,
        maxScrolls: 400,
      );
      final chip = find.byKey(const ValueKey('ephemeral-gallery-group-trace'));
      await tester.ensureVisible(chip);
      await tester.pump();
      await tester.tap(chip);
      await tester.pump();
      final trace = _catalog.groups['trace']!;
      expect(
        find.byKey(ValueKey('ephemeral-kind-${trace.first.kind}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('ephemeral-kind-${_catalog.kinds.first.kind}')),
        findsNothing,
      );
    });

    testWidgets('loads the vendored asset through the bundle', (tester) async {
      final catalog = await tester.runAsync(EphemeralCatalog.load);
      expect(catalog!.kinds, hasLength(_catalog.kinds.length));
      expect(catalog.pin!.commit, _pin.commit);
    });
  });

  group('formatting', () {
    test('scalars never print null, undefined or NaN', () {
      expect(ephemeralScalar(null), '—');
      expect(ephemeralScalar(double.nan), '—');
      expect(ephemeralScalar(''), '—');
      expect(ephemeralScalar(12840), '12,840');
      expect(ephemeralScalar(1240), '1240');
      expect(ephemeralScalar(0.62), '0.62');
      expect(ephemeralScalar(38.125), '38.13');
      expect(ephemeralScalar(true), 'yes');
      expect(
        ephemeralScalar(1793758924685, key: 'capturedAt'),
        '2026-11-04T02:22:04.685Z',
      );
    });

    test('labels humanize keys', () {
      expect(ephemeralLabel('distance_km'), 'Distance km');
      expect(ephemeralLabel('capturedAt'), 'Captured at');
      expect(ephemeralLabel('eta_min'), 'Eta min');
    });
  });
}
