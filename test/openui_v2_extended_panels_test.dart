import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/openui/openui_v2_catalog.dart';

// Additional native, read-only v2 panels on the typed parser from PR #11.
// The original T3 catalog panels remain validated independently.
const _board = r'''
root = Board("Release signals", "Six requests completed.", [stat, bars, stacked, line, table])
stat = Stat("Requests", 6, "today")
bars = BarChart("Requests by model", "turns", [{label: "Fast", value: 4}, {label: "Deep", value: 2}])
stacked = StackedBar("Turns per day", "turns", ["Mon", "Tue", "Wed"], [{name: "Fast", values: [2, 3, 4]}, {name: "Deep", values: [1, 2, 0]}])
line = LineChart("Latency", "ms", ["Mon", "Tue", "Wed"], [{name: "P50", values: [12, 10, 11]}, {name: "P95", values: [18, 19, 17]}])
table = Table("Builds", ["Suite", "Result"], [["Parser", "pass"], ["Widgets", 12]])
''';

OpenUiCatalogStatus _status(String code) =>
    OpenUiV2Catalog.inspect(code).status;

void main() {
  test('all five native panel variants resolve through the parent parser', () {
    final result = OpenUiV2Catalog.inspect(_board);
    expect(
      result.status,
      OpenUiCatalogStatus.ready,
      reason: result.problem?.toString(),
    );
    expect(result.board!.title, 'Release signals');
    expect(result.board!.summary, 'Six requests completed.');
    expect(result.board!.panels.map((panel) => panel.typeName), [
      'Stat',
      'BarChart',
      'StackedBar',
      'LineChart',
      'Table',
    ]);
  });

  test('stat accepts only bounded text or finite numeric data', () {
    expect(
      _status('root = Board("B", "", [Stat("A", -2)])'),
      OpenUiCatalogStatus.ready,
    );
    expect(
      _status('root = Board("B", "", [Stat("A", "ok", "note")])'),
      OpenUiCatalogStatus.ready,
    );
    for (final invalid in [
      'Stat("A", true)',
      'Stat("A", 1000000000001)',
      'Stat("A")',
    ]) {
      expect(
        _status('root = Board("B", "", [$invalid])'),
        OpenUiCatalogStatus.invalid,
      );
    }
  });

  test('series length and numeric bounds are enforced for line and stack', () {
    for (final name in ['LineChart', 'StackedBar']) {
      final good =
          'root = Board("B", "", [$name("T", "", '
          '["Mon", "Tue"], [{name:"A",values:[0,2]}])])';
      expect(_status(good), OpenUiCatalogStatus.ready, reason: name);
      expect(
        _status(good.replaceFirst('[0,2]', '[0]')),
        OpenUiCatalogStatus.invalid,
      );
      expect(
        _status(good.replaceFirst('[0,2]', '[-1,2]')),
        OpenUiCatalogStatus.invalid,
      );
      expect(
        _status(good.replaceFirst('["Mon", "Tue"]', '["Mon"]')),
        OpenUiCatalogStatus.invalid,
      );
    }
  });

  test('table cells are safe scalars and rows exactly match columns', () {
    const valid =
        'root = Board("B", "", '
        '[Table("T", ["Name", "Value"], [["a", 0], ["b", -1]])])';
    expect(_status(valid), OpenUiCatalogStatus.ready);
    expect(
      _status(valid.replaceFirst('["a", 0]', '["a"]')),
      OpenUiCatalogStatus.invalid,
    );
    expect(
      _status(valid.replaceFirst('["a", 0]', '["a", true]')),
      OpenUiCatalogStatus.invalid,
    );
    expect(
      _status(valid.replaceFirst('["a", 0]', '["a", [0]]')),
      OpenUiCatalogStatus.invalid,
    );
    expect(
      _status(valid.replaceFirst('["Name", "Value"]', '[]')),
      OpenUiCatalogStatus.invalid,
    );
  });

  test('board still rejects tools, oversized input, and ninth panel', () {
    expect(
      _status('$_board\ndata = Query("remote", {})'),
      OpenUiCatalogStatus.invalid,
    );
    final nine =
        'root = Board("B", "", [${List.filled(9, 'Stat("A", "1")').join(',')}])';
    expect(_status(nine), OpenUiCatalogStatus.invalid);
    expect(
      _status(List.filled(65537, 'x').join()),
      OpenUiCatalogStatus.invalid,
    );
    expect(
      _status('root = Board("B", "", [Stat('),
      OpenUiCatalogStatus.incomplete,
    );
  });
}
