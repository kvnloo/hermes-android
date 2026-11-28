// HA-036: every ephemeral-ui catalog kind renders in chat.
//
// A reply carries a card document in an ```ephemeral-ui fence (or an
// OpenUI `EphemeralCards` panel). Both chat UIs route fences through
// MarkdownCodeBlock: Classic via splitMarkdownCodeBlocks, NextGen via
// ngSplitCodeFences + ngCodeFenceParts. Each fixture's card must resolve to
// exactly the fixture's props.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/ephemeral/ephemeral_card.dart';
import 'package:hermes_android/core/ephemeral/ephemeral_catalog.dart';
import 'package:hermes_android/core/ephemeral/ephemeral_fence.dart';
import 'package:hermes_android/core/openui/openui_v2_catalog.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/core/widgets/markdown_code_block.dart';
import 'package:hermes_android/core/widgets/openui_board.dart';
import 'package:hermes_android/nextgen/ui/chat_view.dart';

import 'support/l10n_test_utils.dart';

final _catalog = EphemeralCatalog.parse(
  File(EphemeralCatalogAssets.catalog).readAsStringSync(),
);

String _reply(Object card) =>
    'Here is the card.\n\n```ephemeral-ui\n${jsonEncode(card)}\n```\n\nDone.';

Widget _host(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: hermesTheme(Brightness.dark),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

MarkdownCodeBlock _classicFence(String reply) {
  final blocks = splitMarkdownCodeBlocks(reply).whereType<MarkdownCodeBlock>();
  expect(blocks, hasLength(1));
  return blocks.single;
}

({String code, String? language}) _nextGenFence(String reply) {
  final runs = ngSplitCodeFences(reply).where((run) => run.$2).toList();
  expect(runs, hasLength(1));
  return ngCodeFenceParts(runs.single.$1);
}

String _note(EphemeralFixtureState state) => switch (state) {
  EphemeralFixtureState.unavailable => 'No data supplied',
  EphemeralFixtureState.sample => 'Sample data',
  _ => "From the card's data",
};

void main() {
  setUp(() => EphemeralCatalog.debugUse(_catalog));
  tearDown(() => EphemeralCatalog.debugUse(null));

  group('every catalog kind renders in chat', () {
    for (final kind in _catalog.kinds) {
      testWidgets('kind ${kind.kind}', (tester) async {
        tester.view.physicalSize = const Size(1080, 6000);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        for (final fixture in kind.fixtures) {
          final reply = _reply(fixture.card);

          final classic = _classicFence(reply);
          expect(classic.language, ephemeralFenceLanguage);
          final nextGen = _nextGenFence(reply);
          expect(nextGen.language, ephemeralFenceLanguage);
          expect(nextGen.code.trim(), classic.code.trim());

          await tester.pumpWidget(
            _host(
              MarkdownCodeBlock(
                code: nextGen.code,
                language: nextGen.language,
                selectable: false,
              ),
            ),
          );
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('ephemeral-fence')), findsOneWidget);
          expect(find.byKey(const Key('markdown-code-block')), findsNothing);
          expect(
            find.byKey(const Key('ephemeral-fence-problem')),
            findsNothing,
            reason: fixture.id,
          );
          final view = tester.widget<EphemeralCardView>(
            find.byType(EphemeralCardView),
          );
          expect(view.props, equals(fixture.props), reason: fixture.id);
          expect(view.data.kind, kind.kind);
          expect(
            find.byKey(const Key('ephemeral-unsupported')),
            findsNothing,
            reason: fixture.id,
          );
          expect(
            find.byKey(const Key('ephemeral-unavailable')),
            fixture.state == EphemeralFixtureState.unavailable
                ? findsOneWidget
                : findsNothing,
            reason: fixture.id,
          );
          expect(find.text(_note(fixture.state)), findsOneWidget);
          for (final text
              in tester
                  .widgetList<RichText>(find.byType(RichText))
                  .map((t) => t.text.toPlainText())) {
            expect(text, isNot(contains('undefined')), reason: fixture.id);
            expect(text, isNot(contains('NaN')), reason: fixture.id);
          }
        }
      });
    }
  });

  group('resolver', () {
    test('an unknown kind is a visible problem, not a blank card', () {
      final r = resolveEphemeralCard(_catalog, {'kind': 'weather'});
      expect(r.data, isNull);
      expect(r.problem, contains('Unknown card kind "weather"'));
      expect(r.problem, contains('v${_catalog.version}'));
    });

    test('a card without a kind is a problem', () {
      expect(resolveEphemeralCard(_catalog, 'metric').problem, isNotNull);
      expect(resolveEphemeralCard(_catalog, {'app': 'npm'}).problem, isNotNull);
      expect(
        resolveEphemeralCard(_catalog, {'kind': 'metric', 'app': 3}).problem,
        isNotNull,
      );
    });

    test('a sample kind for another app draws the sample as that app', () {
      final r = resolveEphemeralCard(_catalog, {
        'kind': 'metric',
        'app': 'my-app',
      });
      expect(r.data!.props['app'], 'my-app');
      expect(r.data!.props['kind'], 'metric');
      expect(r.data!.appName, 'my-app');
      expect(r.data!.footnote, 'Sample data');
    });

    test('a kind with no app falls back to its first fixture app', () {
      final kind = _catalog.kind('metric')!;
      final r = resolveEphemeralCard(_catalog, {'kind': 'metric'});
      expect(r.data!.props, equals(kind.fixtures.first.props));
    });

    test('input on a sample kind is noted, never silently drawn', () {
      final r = resolveEphemeralCard(_catalog, {
        'kind': 'metric',
        'app': 'npm',
        'input': {'value': 1},
      });
      expect(r.data!.footnote, contains('draws no input'));
      expect(r.data!.props.containsKey('input'), isFalse);
    });

    test('a data kind with no input draws its unavailable state', () {
      final r = resolveEphemeralCard(_catalog, {
        'kind': 'fleet-hosts',
        'app': 'k3s',
      });
      expect(r.data!.unavailable, isNotNull);
    });

    test('a data kind with new input draws that input', () {
      final input = {
        'at': '2026-11-22T00:00:00Z',
        'hosts': [
          {'id': 'h1', 'label': 'h1', 'online': true},
        ],
      };
      final r = resolveEphemeralCard(_catalog, {
        'kind': 'fleet-hosts',
        'app': 'k3s',
        'input': input,
      });
      expect(r.data!.props['input'], equals(input));
      expect(r.data!.unavailable, isNull);
      expect(r.data!.footnote, "From the card's data");
    });

    test('new data never borrows content or actions from fixture examples', () {
      final input = {'hosts': <Object?>[]};
      final card = resolveEphemeralCard(_catalog, {
        'kind': 'fleet-hosts',
        'app': 'k3s',
        'input': input,
      }).data!;
      expect(card.props, {'kind': 'fleet-hosts', 'app': 'k3s', 'input': input});
    });

    test('appInput kinds draw the given input', () {
      final input = {'number': 7, 'title': 'Fix', 'head': 'a', 'base': 'b'};
      final r = resolveEphemeralCard(_catalog, {
        'kind': 'merge',
        'app': 'github',
        'input': input,
      });
      expect(r.data!.props, {'app': 'github', 'input': input, 'kind': 'merge'});
    });
  });

  group('fence', () {
    test('accepts one card, a list, or a titled list', () {
      expect(EphemeralFence.parse('{"kind":"metric"}').cards, hasLength(1));
      expect(
        EphemeralFence.parse('[{"kind":"metric"},{"kind":"chat"}]').cards,
        hasLength(2),
      );
      final titled = EphemeralFence.parse(
        '{"title":"Today","cards":[{"kind":"metric"}]}',
      );
      expect(titled.title, 'Today');
      expect(titled.cards, hasLength(1));
    });

    test('caps the cards one fence draws', () {
      final many = jsonEncode([
        for (var i = 0; i < 20; i++) {'kind': 'metric'},
      ]);
      expect(
        EphemeralFence.parse(many).cards,
        hasLength(ephemeralFenceMaxCards),
      );
    });

    test('a cut-off body is incomplete; garbage is invalid', () {
      expect(EphemeralFence.parse('{"kind": "met').incomplete, isTrue);
      expect(EphemeralFence.parse('').incomplete, isTrue);
      final bad = EphemeralFence.parse('{kind: metric}');
      expect(bad.incomplete, isFalse);
      expect(bad.problem, isNotNull);
      expect(EphemeralFence.parse('[]').problem, isNotNull);
      expect(EphemeralFence.parse('42').problem, isNotNull);
    });

    testWidgets('a streaming fence waits, then draws when complete', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const MarkdownCodeBlock(
            code: '{"kind": "metric", "app": "np',
            language: ephemeralFenceLanguage,
          ),
        ),
      );
      expect(find.text('Card still arriving…'), findsOneWidget);
      expect(find.byKey(const Key('ephemeral-fence-source')), findsOneWidget);
      await tester.pumpWidget(
        _host(
          const MarkdownCodeBlock(
            code: '{"kind": "metric", "app": "npm"}',
            language: ephemeralFenceLanguage,
          ),
        ),
      );
      expect(find.byType(EphemeralCardView), findsOneWidget);
    });

    testWidgets('mixed cards: drawn ones draw, bad ones explain', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const EphemeralUiFence(
            source:
                '{"title":"Status","cards":[{"kind":"metric","app":"npm"},'
                '{"kind":"weather"}]}',
          ),
        ),
      );
      expect(find.text('Status'), findsOneWidget);
      expect(find.byType(EphemeralCardView), findsOneWidget);
      expect(find.byKey(const Key('ephemeral-fence-problem')), findsOneWidget);
      expect(find.textContaining('Unknown card kind'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ephemeral-fence-source-toggle')));
      await tester.pump();
      expect(find.byKey(const Key('ephemeral-fence-source')), findsOneWidget);
    });

    testWidgets('waits for the catalog, then draws', (tester) async {
      EphemeralCatalog.debugUse(null);
      await tester.pumpWidget(
        _host(const EphemeralUiFence(source: '{"kind":"metric","app":"npm"}')),
      );
      expect(find.byKey(const Key('ephemeral-fence-loading')), findsOneWidget);
      // Once the catalog is available the same fence draws its card.
      EphemeralCatalog.debugUse(_catalog);
      await tester.pumpWidget(
        _host(const EphemeralUiFence(source: '{"kind":"metric","app":"npm"}')),
      );
      expect(find.byType(EphemeralCardView), findsOneWidget);
    });
  });

  group('OpenUI EphemeralCards panel', () {
    const source =
        'root = Board("Today", "Two cards.", [cards])\n'
        'cards = EphemeralCards("Cards", [{kind: "metric", app: "npm"}, '
        '{kind: "merge", app: "github", input: {number: 7, title: "Fix", '
        'head: "a", base: "b"}}])';

    test('validates and keeps the card documents', () {
      final result = OpenUiV2Catalog.inspect(source);
      expect(result.status, OpenUiCatalogStatus.ready);
      final panel = result.board!.panels.single;
      expect(panel.typeName, 'EphemeralCards');
      expect(OpenUiV2Catalog.plain(panel.call.args[1]), [
        {'kind': 'metric', 'app': 'npm'},
        {
          'kind': 'merge',
          'app': 'github',
          'input': {'number': 7, 'title': 'Fix', 'head': 'a', 'base': 'b'},
        },
      ]);
    });

    test('rejects cards without a kind and too many cards', () {
      expect(
        OpenUiV2Catalog.inspect(
          'root = Board("t", "s", [EphemeralCards("c", [{app: "npm"}])])',
        ).status,
        OpenUiCatalogStatus.invalid,
      );
      final nine = List.filled(9, '{kind: "metric"}').join(', ');
      expect(
        OpenUiV2Catalog.inspect(
          'root = Board("t", "s", [EphemeralCards("c", [$nine])])',
        ).status,
        OpenUiCatalogStatus.invalid,
      );
      expect(
        OpenUiV2Catalog.inspect(
          'root = Board("t", "s", [EphemeralCards("c", [{kind: "metric", '
          'input: 3}])])',
        ).status,
        OpenUiCatalogStatus.invalid,
      );
    });

    testWidgets('renders the cards natively inside the board', (tester) async {
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        testAppWithL10n(
          const Scaffold(
            body: SingleChildScrollView(child: OpenUiBoard(source: source)),
          ),
        ),
      );
      expect(find.byKey(const Key('openui-board')), findsOneWidget);
      expect(find.byType(EphemeralCardView), findsNWidgets(2));
      final merge = tester
          .widgetList<EphemeralCardView>(find.byType(EphemeralCardView))
          .last;
      expect(merge.props['input'], isA<Map<String, Object?>>());
      expect(find.text('Fix'), findsOneWidget);
    });
  });
}
