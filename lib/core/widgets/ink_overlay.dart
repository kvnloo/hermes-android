import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../controllers/annotation_controller.dart';
import '../models/annotation_ink.dart';

/// Composable annotation surface; deliberately not connected to chat_screen.
///
/// Raw pointer events retain pressure and device kind. The stylus-only pan
/// recognizer competes with scroll gestures, while a finger in pen mode is
/// excluded from that arena and can scroll the content below.
class InkOverlay extends StatefulWidget {
  const InkOverlay({required this.controller, super.key});

  final AnnotationController controller;

  @override
  State<InkOverlay> createState() => _InkOverlayState();
}

class _InkOverlayState extends State<InkOverlay> {
  final Set<int> _pointers = <int>{};
  int? _inkPointer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onAnnotationChanged);
  }

  @override
  void didUpdateWidget(covariant InkOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_onAnnotationChanged);
    _pointers.clear();
    _inkPointer = null;
    widget.controller.addListener(_onAnnotationChanged);
  }

  void _onAnnotationChanged() {
    if (widget.controller.active) return;
    _pointers.clear();
    _inkPointer = null;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onAnnotationChanged);
    super.dispose();
  }

  InkPointerKind _kind(PointerDeviceKind kind) => switch (kind) {
    PointerDeviceKind.stylus => InkPointerKind.stylus,
    PointerDeviceKind.touch => InkPointerKind.touch,
    PointerDeviceKind.mouse => InkPointerKind.mouse,
    _ => InkPointerKind.other,
  };

  StrokePoint? _sample(PointerEvent event, Size size) {
    if (size.width <= 0 || size.height <= 0) return null;
    final position = event.localPosition;
    if (!position.dx.isFinite || !position.dy.isFinite) return null;
    return StrokePoint(
      (position.dx / size.width).clamp(0.0, 1.0),
      (position.dy / size.height).clamp(0.0, 1.0),
      p: pressureOf(_kind(event.kind), event.pressure),
      t: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void _down(PointerDownEvent event, Size size) {
    _pointers.add(event.pointer);
    if (_pointers.length != 1) {
      _inkPointer = null;
      widget.controller.cancelStroke();
      return;
    }
    final kind = _kind(event.kind);
    if (!routePointer(
      kind,
      penMode: widget.controller.penMode,
      pointers: _pointers.length,
    )) {
      return;
    }
    final sample = _sample(event, size);
    if (sample == null) return;
    _inkPointer = event.pointer;
    widget.controller.startStroke(
      pointer: kind,
      point: sample,
      pointers: _pointers.length,
    );
  }

  void _move(PointerMoveEvent event, Size size) {
    if (_inkPointer != event.pointer || _pointers.length != 1) return;
    final sample = _sample(event, size);
    if (sample != null) widget.controller.appendStrokePoint(sample);
  }

  void _up(PointerUpEvent event) {
    _pointers.remove(event.pointer);
    if (_inkPointer != event.pointer) return;
    _inkPointer = null;
    widget.controller.finishStroke();
  }

  void _cancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    if (_inkPointer != event.pointer) return;
    _inkPointer = null;
    widget.controller.cancelStroke();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, child) {
        if (!widget.controller.active) return const SizedBox.expand();
        final scheme = Theme.of(context).colorScheme;
        return LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            return GestureDetector(
              behavior: HitTestBehavior.translucent,
              supportedDevices: widget.controller.penMode
                  ? const <PointerDeviceKind>{PointerDeviceKind.stylus}
                  : const <PointerDeviceKind>{
                      PointerDeviceKind.stylus,
                      PointerDeviceKind.touch,
                      PointerDeviceKind.mouse,
                    },
              // Installing a pan recognizer lets ink win against a scrollable's
              // competing drag. Raw samples are received by Listener below.
              onPanStart: (_) {},
              onPanCancel: () {
                _inkPointer = null;
                widget.controller.cancelStroke();
              },
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (event) => _down(event, size),
                onPointerMove: (event) => _move(event, size),
                onPointerUp: _up,
                onPointerCancel: _cancel,
                child: CustomPaint(
                  painter: InkPainter(
                    drawing: widget.controller.drawing,
                    live: widget.controller.live,
                    accent: scheme.primary,
                    red: scheme.error,
                    eraserColor: scheme.onSurface,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Renders saved and in-flight strokes in logical pixels using theme colors.
class InkPainter extends CustomPainter {
  const InkPainter({
    required this.drawing,
    required this.live,
    required this.accent,
    required this.red,
    required this.eraserColor,
  });

  final Drawing drawing;
  final LiveInk? live;
  final Color accent;
  final Color red;
  final Color eraserColor;

  Color _inkColor(InkColor color) =>
      color == InkColor.red ? red : accent;

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in drawing.strokes) {
      _paintStroke(
        canvas,
        size,
        stroke.tool,
        stroke.points,
        _inkColor(stroke.color),
      );
    }
    final preview = live;
    if (preview == null || preview.points.isEmpty) return;
    final tool = drawingTool(preview.tool);
    if (tool != null) {
      _paintStroke(canvas, size, tool, preview.points, _inkColor(preview.color));
    } else {
      final point = preview.points.last;
      canvas.drawCircle(
        Offset(point.x * size.width, point.y * size.height),
        12,
        Paint()
          ..color = eraserColor.withValues(alpha: 0.3)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  void _paintStroke(
    Canvas canvas,
    Size size,
    DrawTool tool,
    List<StrokePoint> points,
    Color color,
  ) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = strokeWidth(tool, meanPressure(points))
      ..color = tool == DrawTool.highlighter
          ? color.withValues(alpha: 0.35)
          : color;

    for (final line in strokeOutline(tool, points)) {
      if (line.isEmpty) continue;
      final path = Path()
        ..moveTo(line.first.x * size.width, line.first.y * size.height);
      for (final point in line.skip(1)) {
        path.lineTo(point.x * size.width, point.y * size.height);
      }
      canvas.drawPath(path, paint);
    }
  }

  /// Translucent hit testing lets finger drags reach scrollables behind us.
  /// The stylus-only pan recognizer above still enters the gesture arena.
  @override
  bool? hitTest(Offset position) => false;

  @override
  bool shouldRepaint(covariant InkPainter oldDelegate) =>
      !identical(drawing, oldDelegate.drawing) ||
      !identical(live, oldDelegate.live) ||
      accent != oldDelegate.accent ||
      red != oldDelegate.red ||
      eraserColor != oldDelegate.eraserColor;
}
