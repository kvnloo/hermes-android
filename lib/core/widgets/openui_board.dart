import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hermes_android/core/l10n/l10n.dart';
import 'package:hermes_android/core/openui/openui_lang.dart';
import 'package:hermes_android/core/openui/openui_v2_catalog.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';

/// Read-only native renderer for validated, completed OpenUI-v2 boards.
///
/// The source is never discarded. No panel has access to chat, tools, or
/// navigation; all interactions update local selection state only.
class OpenUiBoard extends StatefulWidget {
  const OpenUiBoard({super.key, required this.source});

  final String source;

  @override
  State<OpenUiBoard> createState() => _OpenUiBoardState();
}

class _OpenUiBoardState extends State<OpenUiBoard> {
  late OpenUiCatalogResult _result = OpenUiV2Catalog.inspect(widget.source);
  bool _showSource = false;

  static const _renderedTypes = <String>{
    'Stat', 'BarChart', 'StackedBar', 'LineChart', 'Table',
    'StackedArea', 'Treemap', 'Heatmap',
  };

  @override
  void didUpdateWidget(covariant OpenUiBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _result = OpenUiV2Catalog.inspect(widget.source);
      _showSource = false;
    }
  }

  Widget _source(BuildContext context) {
    final tokens = HermesTokens.of(context);
    return Container(
      key: const Key('openui-original-source'),
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
      key: const Key('openui-board-notice'),
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
          Row(children: [
            Icon(Icons.info_outline, size: 18, color: tokens.muted),
            const SizedBox(width: HermesSpacing.sm),
            Expanded(child: Text(message,
                style: tokens.typography.body.copyWith(color: tokens.onSurface))),
          ]),
          if (_result.problem != null) ...[
            const SizedBox(height: HermesSpacing.xs),
            Text(_result.problem.toString(),
                style: tokens.typography.label.copyWith(color: tokens.muted)),
          ],
          const SizedBox(height: HermesSpacing.sm),
          _source(context),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_result.status == OpenUiCatalogStatus.incomplete) {
      return _notice(context, context.l10n.openui_board_incomplete);
    }
    if (_result.status != OpenUiCatalogStatus.ready) {
      return _notice(context, context.l10n.openui_board_unavailable);
    }
    final board = _result.board!;
    if (board.panels.any((panel) => !_renderedTypes.contains(panel.typeName))) {
      return _notice(context, context.l10n.openui_board_unsupported);
    }

    final tokens = HermesTokens.of(context);
    return Container(
      key: const Key('openui-board'),
      margin: const EdgeInsets.symmetric(vertical: HermesSpacing.sm),
      padding: const EdgeInsets.all(HermesSpacing.md),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border.all(color: tokens.border),
        borderRadius: HermesRadius.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(board.title,
              style: tokens.typography.section.copyWith(color: tokens.onSurface)),
          if (board.summary.isNotEmpty) ...[
            const SizedBox(height: HermesSpacing.xs),
            Text(board.summary,
                style: tokens.typography.body.copyWith(color: tokens.muted)),
          ],
          const SizedBox(height: HermesSpacing.sm),
          Row(children: [
            Expanded(
              child: Text(context.l10n.openui_read_only,
                  style: tokens.typography.label.copyWith(color: tokens.muted)),
            ),
            TextButton.icon(
              key: const Key('openui-source-toggle'),
              onPressed: () => setState(() => _showSource = !_showSource),
              icon: Icon(_showSource ? Icons.code_off : Icons.code, size: 16),
              label: Text(_showSource
                  ? context.l10n.openui_hide_source
                  : context.l10n.openui_show_source),
            ),
          ]),
          for (var index = 0; index < board.panels.length; index++) ...[
            Divider(height: HermesSpacing.lg, color: tokens.border),
            _OpenUiPanel(
              key: ValueKey('openui-panel-' + index.toString()),
              panel: board.panels[index],
            ),
          ],
          if (_showSource) ...[
            const SizedBox(height: HermesSpacing.md),
            _source(context),
          ],
        ],
      ),
    );
  }
}

String _str(OpenUiValue node) => (node as OpenUiString).value;
double _num(OpenUiValue node) => (node as OpenUiNumber).value;
List<OpenUiValue> _list(OpenUiValue node) => (node as OpenUiArray).items;
Map<String, OpenUiValue> _fields(OpenUiValue node) =>
    (node as OpenUiObject).fields;

String _format(double value) => value == value.truncateToDouble()
    ? value.toInt().toString()
    : value.toString();

String _scalar(OpenUiValue node) {
  if (node is OpenUiString) return node.value;
  if (node is OpenUiNumber) return _format(node.value);
  return '';
}

List<Color> _seriesPalette(ColorScheme scheme) => [
  scheme.primary, scheme.secondary, scheme.tertiary, scheme.error,
  scheme.primaryContainer, scheme.secondaryContainer,
  scheme.tertiaryContainer, scheme.errorContainer,
];

class _OpenUiPanel extends StatefulWidget {
  const _OpenUiPanel({super.key, required this.panel});

  final OpenUiChartPanel panel;

  @override
  State<_OpenUiPanel> createState() => _OpenUiPanelState();
}

class _OpenUiPanelState extends State<_OpenUiPanel> {
  int? _selected;

  @override
  void didUpdateWidget(covariant _OpenUiPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.panel.call, widget.panel.call)) {
      _selected = null;
    }
  }

  void _choose(int index) => setState(() => _selected = index);

  Widget _readout(BuildContext context, String text) {
    final tokens = HermesTokens.of(context);
    return Padding(
      key: const Key('openui-selection'),
      padding: const EdgeInsets.only(top: HermesSpacing.sm),
      child: Text(text,
          style: tokens.typography.label.copyWith(color: tokens.onSurface)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    final call = widget.panel.call;
    final type = widget.panel.typeName;
    final title = _str(call.args.first);
    final titleWidget = Text(title,
        style: tokens.typography.body.copyWith(
            fontWeight: FontWeight.w600, color: tokens.onSurface));
    late final Widget content;
    switch (type) {
      case 'Stat':
        content = _stat(context, call);
      case 'BarChart':
        content = _bars(context, call);
      case 'StackedBar':
      case 'StackedArea':
      case 'LineChart':
        content = _series(context, call, type);
      case 'Table':
        content = _table(context, call);
      case 'Treemap':
        content = _treemap(context, call);
      case 'Heatmap':
        content = _heatmap(context, call);
      default:
        // The board gate excludes unknown and action-bearing catalog panels.
        content = const SizedBox.shrink();
    }
    return Column(
      key: Key('openui-panel-' + type.toLowerCase()),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        titleWidget,
        const SizedBox(height: HermesSpacing.sm),
        content,
      ],
    );
  }

  Widget _stat(BuildContext context, OpenUiCall call) {
    final tokens = HermesTokens.of(context);
    final value = _scalar(call.args[1]);
    final detail = call.args.length > 2 ? _str(call.args[2]) : '';
    return InkWell(
      key: const Key('openui-stat'),
      borderRadius: HermesRadius.card,
      onTap: () => _choose(0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(HermesSpacing.md),
        decoration: BoxDecoration(
          borderRadius: HermesRadius.card,
          color: _selected == 0 ? tokens.accentContainer : tokens.raised,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: tokens.typography.display.copyWith(
              color: _selected == 0 ? tokens.onAccentContainer : tokens.onSurface)),
          if (detail.isNotEmpty) Text(detail,
              style: tokens.typography.label.copyWith(color: tokens.muted)),
        ]),
      ),
    );
  }

  Widget _bars(BuildContext context, OpenUiCall call) {
    final tokens = HermesTokens.of(context);
    final unit = _str(call.args[1]);
    final rows = _list(call.args[2]).map(_fields).toList();
    final maximum = rows.map((row) => _num(row['value']!)).reduce(math.max);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < rows.length; i++)
          InkWell(
            key: Key('openui-bar-' + i.toString()),
            onTap: () => _choose(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: HermesSpacing.xs),
              child: Row(children: [
                SizedBox(
                  width: 82,
                  child: Text(_str(rows[i]['label']!), maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.typography.label.copyWith(color: tokens.onSurface)),
                ),
                const SizedBox(width: HermesSpacing.sm),
                Expanded(
                  child: SizedBox(
                    key: const Key('openui-bar-paint'),
                    height: 20,
                    child: CustomPaint(
                      painter: _BarPainter(
                        value: _num(rows[i]['value']!),
                        maximum: maximum,
                        active: _selected == i,
                        color: tokens.accent,
                        background: tokens.raised,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: HermesSpacing.sm),
                SizedBox(width: 58, child: Text(_format(_num(rows[i]['value']!)),
                    textAlign: TextAlign.right,
                    style: tokens.typography.label.copyWith(color: tokens.onSurface))),
              ]),
            ),
          ),
        if (_selected != null)
          _readout(context, _str(rows[_selected!]['label']!) + ' · ' +
              _format(_num(rows[_selected!]['value']!)) +
              (unit.isEmpty ? '' : ' ' + unit)),
      ],
    );
  }

  Widget _series(BuildContext context, OpenUiCall call, String type) {
    final tokens = HermesTokens.of(context);
    final unit = _str(call.args[1]);
    final categories = _list(call.args[2]).map(_str).toList();
    final rows = _list(call.args[3]).map(_fields).toList();
    final names = rows.map((row) => _str(row['name']!)).toList();
    final values = rows.map((row) =>
        _list(row['values']!).map(_num).toList()).toList();
    final colors = _seriesPalette(Theme.of(context).colorScheme);
    final width = math.max(280.0, categories.length * 36.0);
    final selected = _selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(spacing: HermesSpacing.md, runSpacing: HermesSpacing.xs, children: [
          for (var i = 0; i < names.length; i++)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 10, height: 10, color: colors[i % colors.length]),
              const SizedBox(width: HermesSpacing.xs),
              Text(names[i], style: tokens.typography.label.copyWith(
                  color: tokens.onSurface)),
            ]),
        ]),
        const SizedBox(height: HermesSpacing.sm),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            child: Column(children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) {
                  final index = (details.localPosition.dx / width *
                          categories.length).floor();
                  if (index >= 0 && index < categories.length) _choose(index);
                },
                child: SizedBox(
                  key: const Key('openui-series-paint'),
                  width: width,
                  height: 154,
                  child: CustomPaint(painter: _SeriesPainter(
                    data: values,
                    type: type,
                    colors: colors,
                    selected: selected,
                    grid: tokens.border,
                  )),
                ),
              ),
              Row(children: [
                for (var i = 0; i < categories.length; i++)
                  SizedBox(
                    width: width / categories.length,
                    child: InkWell(
                      key: Key('openui-category-' + i.toString()),
                      onTap: () => _choose(i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: HermesSpacing.xs),
                        child: Text(categories[i], maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: tokens.typography.label.copyWith(
                              color: selected == i ? tokens.accent : tokens.muted,
                            )),
                      ),
                    ),
                  ),
              ]),
            ]),
          ),
        ),
        if (selected != null)
          _readout(context, categories[selected] + ' · ' +
              [
                for (var i = 0; i < names.length; i++)
                  names[i] + ' ' + _format(values[i][selected]),
              ].join(' · ') +
              (unit.isEmpty ? '' : ' ' + unit)),
      ],
    );
  }

  Widget _table(BuildContext context, OpenUiCall call) {
    final tokens = HermesTokens.of(context);
    final columns = _list(call.args[1]).map(_str).toList();
    final rows = _list(call.args[2]).map((row) =>
        _list(row).map(_scalar).toList()).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: columns.length * 132.0,
          child: Table(
            key: const Key('openui-table'),
            border: TableBorder.all(color: tokens.border),
            columnWidths: {
              for (var i = 0; i < columns.length; i++)
                i: const FixedColumnWidth(132),
            },
            children: [
              TableRow(
                decoration: BoxDecoration(color: tokens.raised),
                children: [
                  for (final name in columns)
                    Padding(
                      padding: const EdgeInsets.all(HermesSpacing.sm),
                      child: Text(name, maxLines: 2,
                          style: tokens.typography.label.copyWith(
                              fontWeight: FontWeight.w700, color: tokens.onSurface)),
                    ),
                ],
              ),
              for (var i = 0; i < rows.length; i++)
                TableRow(
                  decoration: BoxDecoration(
                      color: _selected == i ? tokens.accentContainer : null),
                  children: [
                    for (final value in rows[i])
                      InkWell(
                        onTap: () => _choose(i),
                        child: Padding(
                          padding: const EdgeInsets.all(HermesSpacing.sm),
                          child: Text(value, maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: tokens.typography.label.copyWith(
                                  color: tokens.onSurface)),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
      if (_selected != null)
        _readout(context, rows[_selected!].join(' · ')),
    ]);
  }

  Widget _treemap(BuildContext context, OpenUiCall call) {
    final tokens = HermesTokens.of(context);
    final unit = _str(call.args[1]);
    final rows = _list(call.args[3]).map(_fields).toList();
    final sizes = rows.map((row) => _num(row['size']!)).toList();
    final colors = rows.map((row) => _num(row['color']!)).toList();
    final total = sizes.fold<double>(0, (a, b) => a + b);
    final weights = total == 0
        ? List<double>.filled(rows.length, 1)
        : sizes;
    final denominator = weights.fold<double>(0, (a, b) => a + b);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      LayoutBuilder(builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth : 280.0;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            final portion = (details.localPosition.dx / width)
                .clamp(0.0, 1.0);
            var share = 0.0;
            for (var i = 0; i < weights.length; i++) {
              share += weights[i] / denominator;
              if (portion <= share || i == weights.length - 1) {
                _choose(i);
                break;
              }
            }
          },
          child: SizedBox(
            key: const Key('openui-treemap-paint'),
            width: width,
            height: 110,
            child: CustomPaint(painter: _TreemapPainter(
              sizes: weights, colors: colors, selected: _selected,
              background: tokens.accentContainer, foreground: tokens.accent,
              stroke: tokens.border,
            )),
          ),
        );
      }),
      const SizedBox(height: HermesSpacing.xs),
      for (var i = 0; i < rows.length; i++)
        InkWell(
          onTap: () => _choose(i),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: HermesSpacing.xs),
            child: Text(
              _str(rows[i]['path']!) + ' · ' + _format(sizes[i]) + ' ' + unit,
              style: tokens.typography.label.copyWith(
                color: _selected == i ? tokens.accent : tokens.onSurface,
              ),
            ),
          ),
        ),
    ]);
  }

  Widget _heatmap(BuildContext context, OpenUiCall call) {
    final tokens = HermesTokens.of(context);
    final unit = _str(call.args[1]);
    final rows = _list(call.args[2]).map(_str).toList();
    final cols = _list(call.args[3]).map(_str).toList();
    final counts = _list(call.args[4])
        .map((row) => _list(row).map(_num).toList()).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 72,
            child: Column(children: [
              const SizedBox(height: 28),
              for (final label in rows)
                SizedBox(height: 25, child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: tokens.typography.label.copyWith(color: tokens.muted)),
                )),
            ]),
          ),
          Column(children: [
            Row(children: [
              for (final label in cols)
                SizedBox(width: 28, height: 28, child: Center(
                  child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: tokens.typography.label.copyWith(color: tokens.muted)),
                )),
            ]),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) {
                final r = (details.localPosition.dy / 25).floor();
                final c = (details.localPosition.dx / 28).floor();
                if (r >= 0 && r < rows.length && c >= 0 && c < cols.length) {
                  _choose(r * cols.length + c);
                }
              },
              child: SizedBox(
                key: const Key('openui-heatmap-paint'),
                width: cols.length * 28.0,
                height: rows.length * 25.0,
                child: CustomPaint(painter: _HeatmapPainter(
                  values: counts, selected: _selected,
                  low: tokens.accentContainer, high: tokens.accent,
                  stroke: tokens.border,
                )),
              ),
            ),
          ]),
        ]),
      ),
      if (_selected != null)
        _readout(context,
            rows[_selected! ~/ cols.length] + ' · ' +
            cols[_selected! % cols.length] + ' · ' +
            _format(counts[_selected! ~/ cols.length]
                [_selected! % cols.length]) +
            (unit.isEmpty ? '' : ' ' + unit)),
    ]);
  }
}

class _BarPainter extends CustomPainter {
  const _BarPainter({
    required this.value, required this.maximum, required this.active,
    required this.color, required this.background,
  });

  final double value;
  final double maximum;
  final bool active;
  final Color color;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        Paint()..color = background);
    final fraction = maximum > 0 ? value / maximum : 0.0;
    if (fraction > 0) {
      canvas.drawRRect(RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width * fraction, size.height),
          const Radius.circular(4)),
          Paint()..color = color);
    }
    if (active) {
      final outline = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)), outline);
    }
  }

  @override
  bool shouldRepaint(covariant _BarPainter old) =>
      old.value != value || old.maximum != maximum ||
      old.active != active || old.color != color || old.background != background;
}

class _SeriesPainter extends CustomPainter {
  const _SeriesPainter({
    required this.data, required this.type, required this.colors,
    required this.selected, required this.grid,
  });

  final List<List<double>> data;
  final String type;
  final List<Color> colors;
  final int? selected;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    final count = data.first.length;
    final totals = List<double>.generate(count, (i) =>
        data.fold<double>(0, (sum, row) => sum + row[i]));
    final maxValue = type == 'LineChart'
        ? data.expand((row) => row).reduce(math.max)
        : totals.reduce(math.max);
    final maximum = math.max(1.0, maxValue);
    double x(int i) => (i + 0.5) * size.width / count;
    double y(double value) => size.height * (1 - value / maximum);
    canvas.drawLine(Offset(0, size.height), Offset(size.width, size.height),
        (Paint()..color = grid)..strokeWidth = 1);
    if (type == 'StackedBar') {
      for (var i = 0; i < count; i++) {
        var cumulative = 0.0;
        for (var s = 0; s < data.length; s++) {
          final previous = cumulative;
          cumulative += data[s][i];
          canvas.drawRect(
            Rect.fromLTRB(x(i) - size.width / count * 0.35,
                y(cumulative), x(i) + size.width / count * 0.35,
                y(previous)),
            Paint()..color = colors[s % colors.length],
          );
        }
      }
    } else if (type == 'StackedArea') {
      var lower = List<double>.filled(count, 0);
      for (var s = 0; s < data.length; s++) {
        final upper = List<double>.generate(count,
            (i) => lower[i] + data[s][i]);
        final path = Path()..moveTo(x(0), y(upper[0]));
        for (var i = 1; i < count; i++) {
          path.lineTo(x(i), y(upper[i]));
        }
        for (var i = count - 1; i >= 0; i--) {
          path.lineTo(x(i), y(lower[i]));
        }
        canvas.drawPath(path..close(),
            Paint()..color = colors[s % colors.length]);
        lower = upper;
      }
    } else {
      for (var s = 0; s < data.length; s++) {
        final path = Path()..moveTo(x(0), y(data[s][0]));
        for (var i = 1; i < count; i++) {
          path.lineTo(x(i), y(data[s][i]));
        }
        final strokePaint = Paint()
          ..color = colors[s % colors.length]
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5;
        canvas.drawPath(path, strokePaint);
        for (var i = 0; i < count; i++) {
          canvas.drawCircle(Offset(x(i), y(data[s][i])), 2.5,
              Paint()..color = colors[s % colors.length]);
        }
      }
    }
    if (selected != null) {
      canvas.drawLine(
        Offset(x(selected!), 0), Offset(x(selected!), size.height),
        (Paint()..color = colors.first)..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SeriesPainter old) =>
      old.type != type || old.selected != selected ||
      old.data != data || old.colors != colors || old.grid != grid;
}

class _TreemapPainter extends CustomPainter {
  const _TreemapPainter({
    required this.sizes, required this.colors, required this.selected,
    required this.background, required this.foreground, required this.stroke,
  });

  final List<double> sizes;
  final List<double> colors;
  final int? selected;
  final Color background;
  final Color foreground;
  final Color stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final total = sizes.fold<double>(0, (a, b) => a + b);
    final maximum = colors.reduce(math.max);
    var start = 0.0;
    for (var i = 0; i < sizes.length; i++) {
      final width = size.width * sizes[i] / total;
      final rect = Rect.fromLTWH(start, 0, width, size.height);
      canvas.drawRect(rect, Paint()..color = Color.lerp(
          background, foreground,
          maximum > 0 ? colors[i] / maximum : 0.0)!);
      final outline = Paint()
        ..color = (selected == i ? foreground : stroke)
        ..strokeWidth = (selected == i ? 3 : 1)
        ..style = PaintingStyle.stroke;
      canvas.drawRect(rect.deflate(0.5), outline);
      start += width;
    }
  }

  @override
  bool shouldRepaint(covariant _TreemapPainter old) =>
      old.sizes != sizes || old.colors != colors ||
      old.selected != selected || old.foreground != foreground ||
      old.background != background || old.stroke != stroke;
}

class _HeatmapPainter extends CustomPainter {
  const _HeatmapPainter({
    required this.values, required this.selected,
    required this.low, required this.high, required this.stroke,
  });

  final List<List<double>> values;
  final int? selected;
  final Color low;
  final Color high;
  final Color stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final columns = values.first.length;
    final maximum = values.expand((row) => row).reduce(math.max);
    for (var r = 0; r < values.length; r++) {
      for (var c = 0; c < columns; c++) {
        final rect = Rect.fromLTWH(c * 28.0, r * 25.0, 27, 24);
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(3)),
          Paint()..color = Color.lerp(
              low, high, maximum > 0 ? values[r][c] / maximum : 0.0)!,
        );
        if (selected == r * columns + c) {
          final outline = Paint()
            ..color = stroke
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5;
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(3)), outline,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HeatmapPainter old) =>
      old.values != values || old.selected != selected ||
      old.low != low || old.high != high || old.stroke != stroke;
}
