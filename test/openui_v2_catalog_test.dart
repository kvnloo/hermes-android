import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/openui/openui_lang.dart';
import 'package:hermes_android/core/openui/openui_v2_catalog.dart';

// Ported from t3code experiments/openui-lab/app-cards.test.ts.
const _ride = r'''
root = Board("Ride to SFO", "UberX is the cheapest option.", [rides])
rides = RideOptions("uber", "Ferry Building", "SFO Terminal 2", [{name: "UberX", minutes: 4, price: "$31.20", seats: 4}, {name: "Comfort", minutes: 6, price: "$38.90", seats: 4}, {name: "UberXL", minutes: 9, price: "$52.10", seats: 6}])
''';
const _mail = r'''
root = Board("Invoices", "Two unread invoices from Acme.", [mail])
mail = MailList("invoices from Acme", [{from: "Acme Billing", subject: "Invoice #4512", snippet: "Your October invoice is ready.", time: "9:41 AM", unread: true}, {from: "Acme Billing", subject: "Invoice #4498", snippet: "September invoice attached.", time: "Oct 2", unread: false}])
''';
const _route = r'''
root = Board("To the Ferry Building", "About 18 minutes by car.", [route])
route = Route("Home", "Ferry Building", "drive", 18, "6.2 mi", ["Head north on Valencia St", "Turn right onto Market St", "Arrive at Ferry Building"])
''';
const _checks = r'''[{name: "Tests", status: "pass", detail: "vitest · 42 passed"}, {name: "Lint", status: "pass", detail: ""}, {name: "Types", status: "pass", detail: ""}]''';

String _pr(String state, int conflicts, [String checks = _checks]) =>
    'root = Board("PR #128", "Status of the auth PR.", [pr])\n'
    'pr = PullRequest(128, "Refresh sessions in the auth middleware", '
    '"$state", "feat/session-refresh", "main", $checks, $conflicts)';

const _mixed = r'''
root = Board("Trip", "Ride and route.", [rides, route, spend])
rides = RideOptions("lyft", "Home", "Airport", [{name: "Lyft", minutes: 3, price: "$28", seats: 4}])
route = Route("Home", "Airport", "transit", 52, "14 mi", ["Walk to 16th St BART"])
spend = BarChart("Ride spend", "USD", [{label: "Uber", value: 120}, {label: "Lyft", value: 80}])
''';

const _heat = r'''root = Board("B", "", [h])
h = Heatmap("H", "", ["Mon"], ["0"], [[1]])''';

OpenUiCatalogStatus _status(String code) => OpenUiV2Catalog.inspect(code).status;

void main() {
  test('all OpenUI lab app-card fixtures resolve and validate', () {
    final cases = <(String, String)>[
      (_ride, 'RideOptions'),
      (_mail, 'MailList'),
      (_route, 'Route'),
      (_pr('ready', 0), 'PullRequest'),
      (_pr('conflict', 3), 'PullRequest'),
      (_pr('merged', 0), 'PullRequest'),
    ];
    for (final (code, type) in cases) {
      final parsed = OpenUiLang.parse(code);
      expect(parsed.status, OpenUiParseStatus.ready, reason: type);
      final result = OpenUiV2Catalog.validate(parsed);
      expect(result.status, OpenUiCatalogStatus.ready,
          reason: result.problem?.toString());
      expect(result.board!.panels.single.typeName, type);
    }
    final mixed = OpenUiV2Catalog.inspect(_mixed);
    expect(mixed.status, OpenUiCatalogStatus.ready);
    expect(mixed.board!.panels.map((panel) => panel.typeName),
        ['RideOptions', 'Route', 'BarChart']);
    final rides = mixed.board!.panels.first.call;
    final options = (rides.args[3] as OpenUiArray).items;
    expect(((options.single as OpenUiObject).fields['price']
        as OpenUiString).value, r'$28');
  });

  test('OpenUI lab invalid chart fixtures are never rendered as ready', () {
    final invalid = <String>[
      'root = Report("B", "", [], [], [], [])',
      'root = Board("B", "", [])',
      'root = Board("B", "", [Unknown("x")])',
      '$_heat\ndata = Query("read_file", {})',
      '$_heat\nm = Mutation("write_file", {})',
      'root = Board("B", "", [Heatmap("H", "", ["Mon", "Tue"], ["0"], [[1]])])',
      'root = Board("B", "", [Heatmap("H", "", ["Mon"], ["0", "6"], [[1]])])',
      'root = Board("B", "", [Heatmap("H", "", ["Mon"], ["0"], [[-1]])])',
      'root = Board("B", "", [StackedArea("S", "", ["Mon", "Tue"], [{name: "A", values: [1]}])])',
      'root = Board("B", "", [Treemap("T", "LOC", "commits", [{path: "a", size: 1, color: 0}, {path: "a/b", size: 1, color: 0}])])',
      'root = Board("B", "", [Treemap("T", "LOC", "commits", [{path: "a", size: 1, color: 0}, {path: "a", size: 2, color: 0}])])',
      'root = Board("B", "", [BarChart("Bars", "", [])])',
    ];
    for (final code in invalid) {
      expect(_status(code), OpenUiCatalogStatus.invalid, reason: code);
    }
    expect(_status('root = Board("B", "", [h])'),
        OpenUiCatalogStatus.incomplete);
    expect(_status('root = Board('), OpenUiCatalogStatus.incomplete);
  });

  test('OpenUI lab app-card incoherence is rejected', () {
    for (final code in <String>[
      _pr('conflict', 0),
      _pr('merged', 2),
      _pr('ready', 0,
          '[{name: "Tests", status: "running", detail: ""}]'),
      _ride.replaceFirst('"uber"', '"bolt"'),
      _ride.replaceFirst('[{name', 
          '[{name: "UberX", minutes: 1, price: "\$1", seats: 4}, {name'),
      _route.replaceFirst('"drive"', '"teleport"'),
    ]) {
      expect(_status(code), OpenUiCatalogStatus.invalid, reason: code);
    }
  });

  test('all panel dimension and scalar bounds match catalog version 2', () {
    final over8 =
        'root = Board("B", "", [${List.filled(9, 'BarChart("A", "", [{label:"a",value:1}])').join(',')}])';
    expect(_status(over8), OpenUiCatalogStatus.invalid);
    final exactly8 =
        'root = Board("B", "", [${List.filled(8, 'BarChart("A", "", [{label:"a",value:1}])').join(',')}])';
    expect(_status(exactly8), OpenUiCatalogStatus.ready);

    final overBars =
        'root = Board("B", "", [BarChart("A", "", [${List.filled(31, '{label:"x",value:1}').join(',')}])])';
    expect(_status(overBars), OpenUiCatalogStatus.invalid);

    final longTitle = List.filled(201, 'a').join();
    expect(_status('root = Board("$longTitle", "", ['
        'BarChart("A", "", [{label:"x",value:1}])])'),
        OpenUiCatalogStatus.invalid);
    final maxSource = List.filled(65537, 'x').join();
    expect(_status(maxSource), OpenUiCatalogStatus.invalid);

    final categories = List.filled(61, '"Day"').join(',');
    expect(_status('root = Board("B", "", ['
        'StackedArea("S", "", [$categories], [{name:"a",values:[1]}])])'),
        OpenUiCatalogStatus.invalid);

    expect(_status('root = Board("B", "", ['
        'BarChart("A", "", [{label:"x",value:1000000000001}])])'),
        OpenUiCatalogStatus.invalid);
    expect(_status('root = Board("B", "", ['
        'BarChart("A", "", [{label:"x",value:1000000000000}])])'),
        OpenUiCatalogStatus.ready);
  });

  test('Heatmap zero counts and full rows are valid', () {
    const code = 'root = Board("B", "", ['
        'Heatmap("H", "turns", ["Mon", "Tue"], ["0", "6"], '
        '[[0,0],[1,2]])])';
    final result = OpenUiV2Catalog.inspect(code);
    expect(result.status, OpenUiCatalogStatus.ready);
    expect((result.board!.panels.single.call.args[4] as OpenUiArray).items,
        hasLength(2));
  });

  test('optional route geometry, map and PR commit details are checked', () {
    const route = 'root = Board("B", "", [Route("A", "B", "walk", 2, '
        '"1 km", ["Go"], "Main St", [[37.7,-122.4],[37.8,-122.5]], '
        '{image:"https://example.com/map.png", bounds:[37,-123,38,-122]})])';
    expect(_status(route), OpenUiCatalogStatus.ready);
    expect(_status(route.replaceFirst('https://', 'javascript:')),
        OpenUiCatalogStatus.invalid);

    const pr = 'root = Board("B", "", [PullRequest(10, "Fix", "ready", '
        '"head", "main", [{name:"Tests",status:"pass",detail:"",'
        'started:2,seconds:3}], 0, [{title:"Fix",sha:"abcdef12",'
        'author:"Dev",age:"1h",lane:"head",conflict:false}])])';
    expect(_status(pr), OpenUiCatalogStatus.ready);
    expect(_status(pr.replaceFirst('lane:"head"', 'lane:"secret"')),
        OpenUiCatalogStatus.invalid);
  });

  test('version-one Report fixture parses as data but is not a v2 board', () {
    const report = 'root = Report("Build results", "Focused suite", '
        '[{label: "Passed", value: "12"}], ["Suite", "Result"], '
        '[["Parser", "pass"]], [{label: "Pass rate", value: 100}])';
    final result = OpenUiLang.parse(report);
    expect(result.status, OpenUiParseStatus.ready);
    final root = result.program!.root as OpenUiCall;
    expect(root.name, 'Report');
    expect(OpenUiV2Catalog.tableShapeProblem(
        root.args[3] as OpenUiArray, root.args[4] as OpenUiArray), isNull);
    final badRows = OpenUiArray(1, 1, [
      OpenUiArray(1, 1, [const OpenUiString(1, 1, 'only one')])
    ]);
    final mismatch = OpenUiV2Catalog.tableShapeProblem(
        root.args[3] as OpenUiArray, badRows);
    expect(mismatch!.message, contains('match'));
    expect(_status(report), OpenUiCatalogStatus.invalid);
  });

  test('validation reports offending node coordinates', () {
    final result = OpenUiV2Catalog.inspect('root = Board("B", "", [p])\n'
        'p = BarChart("bad", "", [{label: "a", value: -1}])');
    expect(result.status, OpenUiCatalogStatus.invalid);
    expect(result.problem!.line, 2);
    expect(result.problem!.column, greaterThan(1));
  });
}
