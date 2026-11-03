import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/core/widgets/markdown_code_block.dart';
import 'package:hermes_android/core/widgets/openui_board.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/l10n_test_utils.dart';

// Original source-demo-fences.md bodies from T3 Code at 3cf6d0c655,
// also used as parser fixtures in test/openui_lang_test.dart.
const _treemap = r'''
root = Board("Repository size and churn", "src/ui/chat.ts is the largest file; src/auth/login.ts has the most commits.", [map, churn])
map = Treemap("Size and churn", "LOC", "commits", [{path: "src/auth/login.ts", size: 80, color: 12}, {path: "src/auth/tokens.ts", size: 40, color: 6}, {path: "src/ui/chat.ts", size: 120, color: 4}, {path: "tests/auth.test.ts", size: 60, color: 7}])
churn = BarChart("Top 3 files by churn", "commits", [{label: "login.ts", value: 12}, {label: "auth.test.ts", value: 7}, {label: "tokens.ts", value: 6}])
''';
const _stacked = r'''
root = Board("Turns by model", "Wednesday had the most turns (16); Claude led on Tuesday.", [usage])
usage = StackedArea("Turns by model", "turns", ["Mon", "Tue", "Wed"], [{name: "Codex", values: [8, 4, 10]}, {name: "Claude", values: [4, 10, 6]}])
''';
const _heatmap = r'''
root = Board("Activity by day and hour", "Tuesday 12:00 UTC was the busiest slot with 9 turns.", [heat])
heat = Heatmap("Activity (UTC)", "turns", ["Mon", "Tue", "Wed"], ["00:00", "06:00", "12:00", "18:00"], [[0, 2, 7, 1], [1, 4, 9, 2], [0, 3, 5, 1]])
''';
const _native = r'''
root = Board("Overview", "One chart board with five panel types.", [s, bar, stack, line, table])
s = Stat("Requests", 42, "today")
bar = BarChart("Requests by model", "turns", [{label:"Fast",value:30},{label:"Deep",value:12}])
stack = StackedBar("Turns", "turns", ["Mon","Tue"], [{name:"Fast",values:[2,3]},{name:"Deep",values:[1,4]}])
line = LineChart("Latency", "ms", ["Mon","Tue"], [{name:"P50",values:[10,8]},{name:"P95",values:[20,18]}])
table = Table("Suites", ["Suite","Result"], [["Parser","pass"],["Widgets",12]])
''';

Widget _host(String code) => testAppWithL10n(
  Scaffold(body: SingleChildScrollView(
    child: MarkdownCodeBlock(code: code, language: 'openui-v2'),
  )),
);

void main() {
  test('only a closed fence becomes a markdown code-block widget', () {
    final fence = String.fromCharCodes([96, 96, 96]);
    final complete = 'Before\n${fence}openui-v2\n$_treemap${fence}\nAfter';
    final parts = splitMarkdownCodeBlocks(complete);
    expect(parts.whereType<MarkdownCodeBlock>(), hasLength(1));
    expect((parts.whereType<MarkdownCodeBlock>().single).code, _treemap);
    final partial = splitMarkdownCodeBlocks(
        'Before\n${fence}openui-v2\nroot = Board(');
    expect(partial.whereType<MarkdownCodeBlock>(), isEmpty);
    expect(partial.single, contains('root = Board('));
    final inlineCloser = splitMarkdownCodeBlocks(
        '${fence}openui-v2\nroot = Board($fence');
    expect(inlineCloser.whereType<MarkdownCodeBlock>(), isEmpty);
  });

  testWidgets('all three real parser fixture boards paint natively', (tester) async {
    final cases = <(String, String, String)>[
      (_treemap, 'Repository size and churn', 'openui-treemap-paint'),
      (_stacked, 'Turns by model', 'openui-series-paint'),
      (_heatmap, 'Activity by day and hour', 'openui-heatmap-paint'),
    ];
    for (final (source, title, painterKey) in cases) {
      await tester.pumpWidget(_host(source));
      await tester.pump();
      expect(find.byKey(const Key('openui-board')), findsOneWidget, reason: title);
      expect(find.text(title), findsWidgets);
      expect(find.byKey(Key(painterKey)), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
      expect(find.byKey(const Key('openui-board-notice')), findsNothing);
    }
  });

  testWidgets('five native panel types render and never require network', (tester) async {
    await tester.pumpWidget(_host(_native));
    await tester.pump();
    for (final kind in ['stat', 'barchart', 'stackedbar', 'linechart', 'table']) {
      expect(find.byKey(Key('openui-panel-$kind')), findsOneWidget);
    }
    expect(find.byKey(const Key('openui-table')), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
    expect(find.text('Requests by model'), findsOneWidget);
  });

  testWidgets('source toggle preserves exact original program', (tester) async {
    await tester.pumpWidget(_host(_stacked));
    expect(find.byKey(const Key('openui-original-source')), findsNothing);
    await tester.tap(find.byKey(const Key('openui-source-toggle')));
    await tester.pump();
    expect(find.text('Hide source'), findsOneWidget);
    expect(find.byKey(const Key('openui-original-source')), findsOneWidget);
    final selectable = tester.widget<SelectableText>(
        find.descendant(of: find.byKey(const Key('openui-original-source')),
            matching: find.byType(SelectableText)));
    expect(selectable.data, _stacked);
    await tester.tap(find.byKey(const Key('openui-source-toggle')));
    await tester.pump();
    expect(find.byKey(const Key('openui-original-source')), findsNothing);
  });

  testWidgets('bar and series taps change local readout only', (tester) async {
    await tester.pumpWidget(_host(_native));
    await tester.tap(find.byKey(const Key('openui-bar-1')));
    await tester.pump();
    expect(find.text('Deep · 12 turns'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('openui-category-1')).first);
    await tester.tap(find.byKey(const Key('openui-category-1')).first);
    await tester.pump();
    expect(find.textContaining('Tue · Fast 3 · Deep 4 turns'), findsOneWidget);
  });

  testWidgets('table cell selection is a local readout', (tester) async {
    await tester.pumpWidget(_host(_native));
    await tester.ensureVisible(find.text('pass'));
    await tester.tap(find.text('pass'));
    await tester.pump();
    expect(find.text('Parser · pass'), findsOneWidget);
    expect(find.byKey(const Key('openui-board')), findsOneWidget);
  });

  testWidgets('malformed and closed-but-incomplete source get notice and source', (tester) async {
    for (final source in [
      'root = Board("B", "", [Table("T", ["A","B"], [["one"]])])',
      'root = Board(',
      '$_native\nextra = Mutation("send", {})',
      'root = Board("Travel", "", [RideOptions("uber", "A", "B", '
          '[{name:"X",minutes:2,price:"10",seats:4}])])',
    ]) {
      await tester.pumpWidget(_host(source));
      await tester.pump();
      expect(find.byKey(const Key('openui-board-notice')), findsOneWidget);
      expect(find.byKey(const Key('openui-original-source')), findsOneWidget);
      expect(find.byKey(const Key('openui-board')), findsNothing);
    }
  });

  testWidgets('source update clears selection and source expansion', (tester) async {
    await tester.pumpWidget(_host(_stacked));
    await tester.tap(find.byKey(const Key('openui-category-1')));
    await tester.pump();
    expect(find.byKey(const Key('openui-selection')), findsOneWidget);
    await tester.tap(find.byKey(const Key('openui-source-toggle')));
    await tester.pump();
    await tester.pumpWidget(_host(_heatmap));
    await tester.pump();
    expect(find.byKey(const Key('openui-selection')), findsNothing);
    expect(find.byKey(const Key('openui-original-source')), findsNothing);
  });

  testWidgets('the active Hermes dark palette styles every chart', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: hermesTheme(Brightness.dark),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(
        child: const OpenUiBoard(source: _native),
      )),
    ));
    expect(find.byKey(const Key('openui-board')), findsOneWidget);
    expect(find.byKey(const Key('openui-bar-paint')), findsNWidgets(2));
    expect(find.byKey(const Key('openui-series-paint')), findsNWidgets(2));
  });
}
