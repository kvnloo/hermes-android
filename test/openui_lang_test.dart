import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/openui/openui_lang.dart';
import 'package:hermes_android/core/openui/openui_v2_catalog.dart';

// Exact source-demo-fences.md openui-v2 bodies at t3code 3cf6d0c655.
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

void main() {
  test('all three real source-demo fences resolve into typed board panels', () {
    final cases = <(String, String, List<String>, int)>[
      (_treemap, 'Repository size and churn', ['Treemap', 'BarChart'], 4),
      (_stacked, 'Turns by model', ['StackedArea'], 3),
      (_heatmap, 'Activity by day and hour', ['Heatmap'], 3),
    ];

    for (final (source, title, types, _) in cases) {
      final parsed = OpenUiLang.parse(source);
      expect(parsed.status, OpenUiParseStatus.ready, reason: title);
      expect(parsed.problem, isNull);
      final result = OpenUiV2Catalog.validate(parsed);
      expect(result.status, OpenUiCatalogStatus.ready, reason: title);
      expect(result.board!.title, title);
      expect(result.board!.panels.map((p) => p.typeName), types);
      expect(result.board!.panels.every((p) => p.call.args.isNotEmpty), isTrue);
    }

    final map = OpenUiV2Catalog.inspect(_treemap).board!.panels.first.call;
    final rows = (map.args[3] as OpenUiArray).items;
    expect(rows, hasLength(4));
    final first = (rows.first as OpenUiObject).fields;
    expect((first['path'] as OpenUiString).value, 'src/auth/login.ts');
    expect((first['size'] as OpenUiNumber).value, 80);

    final usage = OpenUiV2Catalog.inspect(_stacked).board!.panels.first.call;
    final series = (usage.args[3] as OpenUiArray).items;
    final codex = (series.first as OpenUiObject).fields;
    final values = (codex['values'] as OpenUiArray).items;
    expect(values.map((v) => (v as OpenUiNumber).value), [8, 4, 10]);

    final heat = OpenUiV2Catalog.inspect(_heatmap).board!.panels.first.call;
    final counts = (heat.args[4] as OpenUiArray).items;
    expect(counts, hasLength(3));
    final tuesday = (counts[1] as OpenUiArray).items;
    expect(tuesday.map((v) => (v as OpenUiNumber).value), [1, 4, 9, 2]);
  });

  test('forward, backward and repeated references resolve throughout the AST', () {
    const code = r'''
first = BarChart("A", "", [{label:"a", value: 1}])
root = Board("Board", "summary", [first, second, first])
second = BarChart("B", "", [{label:"b", value: 2}])
''';
    final parsed = OpenUiLang.parse(code);
    expect(parsed.status, OpenUiParseStatus.ready);
    final program = parsed.program!;
    final board = program.root as OpenUiCall;
    final panels = (board.args[2] as OpenUiArray).items;
    expect(panels.map((v) => (v as OpenUiCall).name),
        ['BarChart', 'BarChart', 'BarChart']);
    expect((panels[0] as OpenUiCall).args.first,
        isA<OpenUiString>().having((s) => s.value, 'title', 'A'));
    expect((panels[1] as OpenUiCall).args.first,
        isA<OpenUiString>().having((s) => s.value, 'title', 'B'));
    expect(program.assignments, contains('second'));
    expect(OpenUiV2Catalog.validate(parsed).status, OpenUiCatalogStatus.ready);
  });

  test('string escapes, number, boolean, null and object literals are typed', () {
    const code = 'root = Board("A\\nB", "", [p])\n'
        'p = BarChart("bars", "", [{label: "quote \\"ok\\"", value: 1.25e2}])\n'
        'data = {flag: true, off: false, empty: null, number: -12}';
    final parsed = OpenUiLang.parse(code);
    expect(parsed.status, OpenUiParseStatus.ready);
    final root = parsed.program!.root as OpenUiCall;
    expect((root.args[0] as OpenUiString).value, 'A\nB');
    final extras = (parsed.program!.assignments['data'] as OpenUiObject).fields;
    expect((extras['flag'] as OpenUiBoolean).value, isTrue);
    expect((extras['off'] as OpenUiBoolean).value, isFalse);
    expect(extras['empty'], isA<OpenUiNull>());
    expect((extras['number'] as OpenUiNumber).value, -12);
    final rows = (((parsed.program!.assignments['p'] as OpenUiCall).args[2])
        as OpenUiArray).items;
    expect(((rows.first as OpenUiObject).fields['value'] as OpenUiNumber).value,
        125);
    expect(OpenUiV2Catalog.validate(parsed).status, OpenUiCatalogStatus.ready);
  });

  test('comments and single quotes follow the OpenUI literal subset', () {
    const code = "# full line\n"
        "root = Board('title', '', [p]) // trailing comment\n"
        "p = BarChart('chart', '', [{label: 'x', value: 0}])";
    expect(OpenUiV2Catalog.inspect(code).status, OpenUiCatalogStatus.ready);
  });

  test('truncation and unclosed expressions report incomplete not invalid', () {
    for (final source in <String>[
      '',
      'root =',
      'root = Board(',
      'root = Board("unfinished',
      'root = Board("B", "", [',
      'root = Board("B", "", [p])',
      'root = Board("B", "", [p])\np =',
      _treemap.substring(0, _treemap.length - 12),
    ]) {
      final parsed = OpenUiLang.parse(source);
      expect(parsed.status, OpenUiParseStatus.incomplete, reason: source);
      expect(parsed.problem, isNotNull);
      expect(OpenUiV2Catalog.inspect(source).status,
          OpenUiCatalogStatus.incomplete);
    }
  });

  test('malformed input reports exact line and column', () {
    final bad = OpenUiLang.parse(
        'root = Board("B", "", [p])\np = BarChart("A", "", [*])');
    expect(bad.status, OpenUiParseStatus.invalid);
    expect(bad.problem!.line, 2);
    expect(bad.problem!.column, greaterThan(1));
    expect(bad.problem!.message, contains('Unexpected character'));

    for (final source in <String>[
      'root = Board("B", "", [])\nroot = Board("B", "", [])',
      'root = a\na = root',
      'root = Board("B" "S", [])',
      'root = {x: 1, x: 2}',
      'root = Board("B", "", [p])\np = BarChart("x", "", [@evil])',
      'root = Board("B", "", [p])\np = BarChart("x", "", [{x: 1e309}])',
    ]) {
      expect(OpenUiLang.parse(source).status, OpenUiParseStatus.invalid,
          reason: source);
    }
  });

  test('64 KiB limit counts UTF-8 bytes, including multibyte characters', () {
    const prefix = 'root = Board("';
    const suffix = '", "", [BarChart("A", "", [{label:"x",value:1}])])';
    final okay = prefix + List.filled(10000, '界').join() + suffix;
    expect(OpenUiLang.parse(okay).status, OpenUiParseStatus.ready);
    final tooBig = prefix + List.filled(22000, '界').join() + suffix;
    final result = OpenUiLang.parse(tooBig);
    expect(result.status, OpenUiParseStatus.invalid);
    expect(result.problem!.message, contains('64 KiB'));
    expect(OpenUiV2Catalog.inspect(tooBig).status,
        OpenUiCatalogStatus.invalid);
  });

  test('nesting and cyclic aliases are rejected without evaluating code', () {
    expect(OpenUiLang.parse('root = a\na = b\nb = a').status,
        OpenUiParseStatus.invalid);
    final deeplyNested = 'root = ' +
        List.filled(90, '[').join() +
        '0' +
        List.filled(90, ']').join();
    expect(OpenUiLang.parse(deeplyNested).status, OpenUiParseStatus.invalid);
  });
}
