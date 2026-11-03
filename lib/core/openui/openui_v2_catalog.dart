/// Pure-Dart validation for T3 Code's read-only openui-v2 catalog.
///
/// Mirrors the chart and app-card schemas at experiment/openui-app-cards.
/// It only validates data; there are no widgets, actions or network calls.
library;

import 'openui_lang.dart';

enum OpenUiCatalogStatus { ready, incomplete, invalid }

final class OpenUiChartPanel {
  const OpenUiChartPanel(this.typeName, this.call);
  final String typeName;
  final OpenUiCall call;
}

final class OpenUiChartBoard {
  const OpenUiChartBoard(this.title, this.summary, this.panels);
  final String title;
  final String summary;
  final List<OpenUiChartPanel> panels;
}

final class OpenUiCatalogResult {
  const OpenUiCatalogResult(this.status, {this.board, this.problem});
  final OpenUiCatalogStatus status;
  final OpenUiChartBoard? board;
  final OpenUiProblem? problem;
}

final class OpenUiV2Catalog {
  const OpenUiV2Catalog._();

  static const maxPanels = 8;
  static const maxBytes = OpenUiLang.maxSourceBytes;
  static const maxValue = 1e12;
  static const panelTypes = <String>{
    'Treemap', 'BarChart', 'StackedArea', 'Heatmap',
    'RideOptions', 'MailList', 'Route', 'PullRequest',
  };

  static OpenUiCatalogResult inspect(String source) =>
      validate(OpenUiLang.parse(source));

  static OpenUiCatalogResult validate(OpenUiParseResult parsed) {
    if (parsed.status != OpenUiParseStatus.ready) {
      return OpenUiCatalogResult(
        parsed.status == OpenUiParseStatus.incomplete
            ? OpenUiCatalogStatus.incomplete
            : OpenUiCatalogStatus.invalid,
        problem: parsed.problem,
      );
    }
    final program = parsed.program!;
    final check = _Check();
    try {
      for (final expr in program.assignments.values) {
        check.noUnsupportedCalls(expr);
      }
      final root = check.call(program.root, 'Board');
      check.arity(root, 3);
      final title = check.string(root.args[0], 'Board title', max: 200);
      final summary = check.string(root.args[1], 'Board summary', max: 4000);
      final nodes = check.array(root.args[2], 'Board panels',
          min: 1, max: maxPanels);
      final panels = <OpenUiChartPanel>[];
      for (final node in nodes) {
        if (node is! OpenUiCall) {
          check.bad(node, 'Chart board contains an unknown panel.');
        }
        check.panel(node);
        panels.add(OpenUiChartPanel(node.name, node));
      }
      return OpenUiCatalogResult(
        OpenUiCatalogStatus.ready,
        board: OpenUiChartBoard(title, summary,
            List<OpenUiChartPanel>.unmodifiable(panels)),
      );
    } on _CatalogFailure catch (e) {
      return OpenUiCatalogResult(
        OpenUiCatalogStatus.invalid,
        problem: OpenUiProblem(e.message, e.line, e.column),
      );
    }
  }

  /// Shared v1 table invariant; tables are not a v2 panel.
  static OpenUiProblem? tableShapeProblem(
      OpenUiArray columns, OpenUiArray rows) {
    for (final row in rows.items) {
      if (row is! OpenUiArray || row.items.length != columns.items.length) {
        return OpenUiProblem(
            'Table rows must match the declared columns.',
            row.line, row.column);
      }
    }
    return null;
  }
}

final class _CatalogFailure implements Exception {
  const _CatalogFailure(this.message, this.line, this.column);
  final String message;
  final int line;
  final int column;
}

final class _Check {
  Never bad(OpenUiValue node, String message) =>
      throw _CatalogFailure(message, node.line, node.column);

  void noUnsupportedCalls(OpenUiValue node) {
    switch (node) {
      case OpenUiCall():
        if (node.name != 'Board' &&
            !OpenUiV2Catalog.panelTypes.contains(node.name)) {
          bad(node, 'Unsupported or unknown component: ' + node.name);
        }
        for (final arg in node.args) {
          noUnsupportedCalls(arg);
        }
      case OpenUiArray():
        for (final item in node.items) {
          noUnsupportedCalls(item);
        }
      case OpenUiObject():
        for (final value in node.fields.values) {
          noUnsupportedCalls(value);
        }
      default:
        break;
    }
  }

  OpenUiCall call(OpenUiValue node, String type) {
    if (node is! OpenUiCall || node.name != type) {
      bad(node, 'Expected $type component.');
    }
    return node;
  }

  void arity(OpenUiCall node, int min, [int? max]) {
    if (node.args.length < min || node.args.length > (max ?? min)) {
      bad(node, node.name + ' has an invalid number of arguments.');
    }
  }

  String string(OpenUiValue node, String label,
      {int min = 0, required int max}) {
    if (node is! OpenUiString ||
        node.value.length < min || node.value.length > max) {
      bad(node, '$label must be a string of $min–$max characters.');
    }
    return node.value;
  }

  double number(OpenUiValue node, String label,
      {double min = 0, double max = OpenUiV2Catalog.maxValue,
      bool integer = false}) {
    if (node is! OpenUiNumber || !node.value.isFinite ||
        node.value < min || node.value > max ||
        (integer && node.value.truncateToDouble() != node.value)) {
      bad(node, '$label is out of range.');
    }
    return node.value;
  }

  void boolean(OpenUiValue node, String label) {
    if (node is! OpenUiBoolean) bad(node, '$label must be boolean.');
  }

  List<OpenUiValue> array(OpenUiValue node, String label,
      {int min = 0, required int max}) {
    if (node is! OpenUiArray ||
        node.items.length < min || node.items.length > max) {
      bad(node, '$label has an invalid length.');
    }
    return node.items;
  }

  Map<String, OpenUiValue> object(OpenUiValue node, String label) {
    if (node is! OpenUiObject) bad(node, '$label must be an object.');
    return node.fields;
  }

  OpenUiValue field(Map<String, OpenUiValue> obj, String name,
      OpenUiValue parent) {
    final value = obj[name];
    if (value == null) bad(parent, 'Missing field: $name.');
    return value;
  }

  String textField(Map<String, OpenUiValue> obj, String key,
      OpenUiValue parent, {int min = 0, int max = 200}) =>
      string(field(obj, key, parent), key, min: min, max: max);

  double numberField(Map<String, OpenUiValue> obj, String key,
      OpenUiValue parent, {double min = 0,
      double max = OpenUiV2Catalog.maxValue, bool integer = false}) =>
      number(field(obj, key, parent), key,
          min: min, max: max, integer: integer);

  void optionalText(Map<String, OpenUiValue> obj, String key, int max) {
    final val = obj[key];
    if (val != null) string(val, key, max: max);
  }

  void optionalNumber(Map<String, OpenUiValue> obj, String key, double max) {
    final val = obj[key];
    if (val != null) number(val, key, max: max);
  }

  void choice(OpenUiValue node, String label, Set<String> choices) {
    if (!choices.contains(string(node, label, max: 200))) {
      bad(node, '$label is not supported.');
    }
  }

  void panel(OpenUiCall node) {
    switch (node.name) {
      case 'Treemap':
        arity(node, 4);
        string(node.args[0], 'title', max: 200);
        string(node.args[1], 'sizeLabel', min: 1, max: 100);
        string(node.args[2], 'colorLabel', min: 1, max: 100);
        final paths = <String>{};
        for (final entry in array(node.args[3], 'Treemap rows',
            min: 1, max: 500)) {
          final row = object(entry, 'Treemap row');
          final raw = textField(row, 'path', entry, min: 1, max: 500);
          numberField(row, 'size', entry);
          numberField(row, 'color', entry);
          final path = raw.split('/').where((s) => s.isNotEmpty).join('/');
          if (path.isEmpty) bad(entry, 'Treemap rows need a non-empty path.');
          if (!paths.add(path)) {
            bad(entry, 'Treemap path "$path" appears twice.');
          }
        }
        for (final path in paths) {
          if (paths.any((other) => other.startsWith('$path/'))) {
            bad(node, 'Treemap path "$path" is both a file and a folder.');
          }
        }
      case 'BarChart':
        arity(node, 3);
        string(node.args[0], 'title', max: 200);
        string(node.args[1], 'unit', max: 40);
        for (final entry in array(node.args[2], 'bars',
            min: 1, max: 30)) {
          final bar = object(entry, 'bar');
          textField(bar, 'label', entry, min: 1, max: 100);
          numberField(bar, 'value', entry);
        }
      case 'StackedArea':
        arity(node, 4);
        string(node.args[0], 'title', max: 200);
        string(node.args[1], 'unit', max: 40);
        final categories = array(node.args[2], 'categories',
            min: 2, max: 60);
        for (final category in categories) {
          string(category, 'category', min: 1, max: 100);
        }
        for (final entry in array(node.args[3], 'series',
            min: 1, max: 8)) {
          final row = object(entry, 'series');
          final name = textField(row, 'name', entry, min: 1, max: 100);
          final values = array(field(row, 'values', entry),
              'values', max: 60);
          if (values.length != categories.length) {
            bad(entry, 'StackedArea series "$name" needs ' +
                categories.length.toString() + ' values.');
          }
          for (final value in values) {
            number(value, 'value');
          }
        }
      case 'Heatmap':
        arity(node, 5);
        string(node.args[0], 'title', max: 200);
        string(node.args[1], 'unit', max: 40);
        final rows = array(node.args[2], 'rows', min: 1, max: 31);
        final columns = array(node.args[3], 'columns', min: 1, max: 48);
        for (final row in rows) {
          string(row, 'row label', min: 1, max: 100);
        }
        for (final column in columns) {
          string(column, 'column label', min: 1, max: 100);
        }
        final counts = array(node.args[4], 'counts', max: 31);
        if (counts.length != rows.length) {
          bad(node, 'Heatmap needs ' + rows.length.toString() +
              ' count rows.');
        }
        for (var i = 0; i < counts.length; i++) {
          final cells = array(counts[i], 'count row', max: 48);
          if (cells.length != columns.length) {
            final label = (rows[i] as OpenUiString).value;
            bad(counts[i], 'Heatmap row "$label" needs ' +
                columns.length.toString() + ' counts.');
          }
          for (final cell in cells) {
            number(cell, 'count');
          }
        }
      case 'RideOptions':
        arity(node, 4);
        choice(node.args[0], 'app', {'uber', 'lyft'});
        string(node.args[1], 'pickup', min: 1, max: 200);
        string(node.args[2], 'dropoff', min: 1, max: 200);
        final seen = <String>{};
        for (final entry in array(node.args[3], 'ride options',
            min: 1, max: 8)) {
          final row = object(entry, 'ride');
          final name = textField(row, 'name', entry, min: 1);
          numberField(row, 'minutes', entry, max: 100000);
          textField(row, 'price', entry, min: 1, max: 24);
          numberField(row, 'seats', entry,
              min: 1, max: 20, integer: true);
          optionalText(row, 'arrival', 200);
          if (!seen.add(name)) {
            bad(entry, 'RideOptions lists the same option twice.');
          }
        }
      case 'MailList':
        arity(node, 2);
        string(node.args[0], 'query', max: 200);
        for (final entry in array(node.args[1], 'messages', max: 20)) {
          final row = object(entry, 'message');
          textField(row, 'from', entry, min: 1);
          textField(row, 'subject', entry);
          textField(row, 'snippet', entry, max: 400);
          textField(row, 'time', entry);
          boolean(field(row, 'unread', entry), 'unread');
          optionalText(row, 'attachment', 200);
        }
      case 'Route':
        arity(node, 6, 9);
        string(node.args[0], 'origin', min: 1, max: 200);
        string(node.args[1], 'destination', min: 1, max: 200);
        choice(node.args[2], 'mode', {'drive', 'walk', 'transit', 'bike'});
        number(node.args[3], 'minutes', max: 100000);
        string(node.args[4], 'distance', max: 200);
        for (final step in array(node.args[5], 'steps', max: 20)) {
          string(step, 'step', min: 1, max: 200);
        }
        if (node.args.length > 6) {
          string(node.args[6], 'via', max: 200);
        }
        if (node.args.length > 7) {
          final points = array(node.args[7], 'path', min: 2, max: 600);
          for (final point in points) {
            final xy = array(point, 'coordinate', min: 2, max: 2);
            number(xy[0], 'latitude', min: -90, max: 90);
            number(xy[1], 'longitude', min: -180, max: 180);
          }
        }
        if (node.args.length > 8) {
          final map = object(node.args[8], 'map');
          final url = textField(map, 'image', node.args[8],
              min: 1, max: 2000);
          final uri = Uri.tryParse(url);
          if (uri == null ||
              !(uri.scheme == 'https' || uri.scheme == 'http') ||
              uri.host.isEmpty) {
            bad(node.args[8], 'Map image must be an HTTP(S) URL.');
          }
          final bounds = array(field(map, 'bounds', node.args[8]),
              'bounds', min: 4, max: 4);
          number(bounds[0], 'south', min: -90, max: 90);
          number(bounds[1], 'west', min: -180, max: 180);
          number(bounds[2], 'north', min: -90, max: 90);
          number(bounds[3], 'east', min: -180, max: 180);
        }
      case 'PullRequest':
        arity(node, 7, 8);
        number(node.args[0], 'PR number',
            min: 1, max: double.maxFinite, integer: true);
        string(node.args[1], 'title', min: 1, max: 200);
        choice(node.args[2], 'state',
            {'open', 'conflict', 'ready', 'merged', 'closed'});
        string(node.args[3], 'head', min: 1, max: 200);
        string(node.args[4], 'base', min: 1, max: 200);
        var pending = false;
        for (final entry in array(node.args[5], 'checks', max: 12)) {
          final check = object(entry, 'check');
          textField(check, 'name', entry, min: 1);
          final status = textField(check, 'status', entry, min: 1);
          if (!{'pass', 'fail', 'running', 'skip'}.contains(status)) {
            bad(entry, 'Invalid check status.');
          }
          pending |= status == 'fail' || status == 'running';
          textField(check, 'detail', entry);
          optionalNumber(check, 'started', 6000000);
          optionalNumber(check, 'seconds', 6000000);
        }
        final conflicts = number(node.args[6], 'conflicts',
            max: 10000, integer: true);
        final state = (node.args[2] as OpenUiString).value;
        if (state == 'conflict' && conflicts < 1) {
          bad(node, 'PullRequest in conflict needs a conflict count.');
        }
        if (state != 'conflict' && state != 'open' && conflicts > 0) {
          bad(node, 'PullRequest $state cannot have conflicts.');
        }
        if (state == 'ready' && pending) {
          bad(node, 'PullRequest ready needs every check passed or skipped.');
        }
        if (node.args.length > 7) {
          for (final entry in array(node.args[7], 'commits', max: 12)) {
            final item = object(entry, 'commit');
            textField(item, 'title', entry, min: 1);
            textField(item, 'sha', entry, min: 4, max: 12);
            textField(item, 'author', entry, min: 1);
            textField(item, 'age', entry);
            final lane = textField(item, 'lane', entry, min: 1);
            if (!{'base', 'head', 'side'}.contains(lane)) {
              bad(entry, 'Invalid commit lane.');
            }
            optionalText(item, 'branch', 200);
            final conflict = item['conflict'];
            if (conflict != null) boolean(conflict, 'conflict');
          }
        }
      default:
        bad(node, 'Chart board contains an unknown panel.');
    }
  }
}
