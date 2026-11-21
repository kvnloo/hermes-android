// Volatile, resolution-independent annotation ink. Adapted from Dash's
// annotate/strokes.ts and annotate/pointer.ts at 1e577218da34a2a72e1575c2c7768a2c4d509498.
// Coordinates are normalized to the overlay (0..1); times are epoch ms.
import 'dart:math' as math;

enum DrawTool { pen, highlighter, arrow, box, circle }
enum Tool { pen, highlighter, arrow, box, circle, eraser }
enum InkColor { accent, red }
enum InkPointerKind { stylus, touch, mouse, other }

class InkPosition {
  const InkPosition(this.x, this.y);

  final double x;
  final double y;
}

class StrokePoint extends InkPosition {
  const StrokePoint(
    super.x,
    super.y, {
    required this.t,
    this.p = 0.5,
  });

  final double p;
  final int t;
}

class Stroke {
  const Stroke({
    required this.id,
    required this.tool,
    required this.color,
    required this.pointer,
    required this.points,
    required this.startedAt,
    required this.endedAt,
    this.targets,
  });

  final int id;
  final DrawTool tool;
  final InkColor color;
  final InkPointerKind pointer;
  final List<StrokePoint> points;
  final int startedAt;
  final int endedAt;
  final List<String>? targets;
}

class Drawing {
  const Drawing({
    required this.strokes,
    required this.nextId,
    required this.past,
  });

  final List<Stroke> strokes;
  final int nextId;
  final List<List<Stroke>> past;
}

// ignore: constant_identifier_names
const Drawing EMPTY_DRAWING = Drawing(
  strokes: <Stroke>[],
  nextId: 1,
  past: <List<Stroke>>[],
);

// ignore: constant_identifier_names
const int MAX_UNDO = 50;

DrawTool? drawingTool(Tool tool) => switch (tool) {
  Tool.pen => DrawTool.pen,
  Tool.highlighter => DrawTool.highlighter,
  Tool.arrow => DrawTool.arrow,
  Tool.box => DrawTool.box,
  Tool.circle => DrawTool.circle,
  Tool.eraser => null,
};

bool routePointer(InkPointerKind kind, {required bool penMode, required int pointers}) {
  if (pointers > 1) return false;
  if (penMode) return kind == InkPointerKind.stylus;
  return kind != InkPointerKind.other;
}

/// Only a hardware button rising edge can enter; pen contact never toggles.
bool stylusEnters(InkPointerKind kind) => false;

double pressureOf(InkPointerKind kind, double? pressure) {
  if (kind != InkPointerKind.stylus ||
      pressure == null ||
      !pressure.isFinite ||
      pressure <= 0) {
    return 0.5;
  }
  return math.min(1.0, pressure);
}

/// Repeated coordinates update pressure, but retain the original sample time.
List<StrokePoint> appendInkSample(List<StrokePoint> previous, StrokePoint point) {
  if (!point.x.isFinite || !point.y.isFinite) {
    return List<StrokePoint>.unmodifiable(previous);
  }
  final updated = List<StrokePoint>.of(previous);
  if (updated.isNotEmpty &&
      updated.last.x == point.x &&
      updated.last.y == point.y) {
    final last = updated.last;
    updated[updated.length - 1] = StrokePoint(
      last.x,
      last.y,
      p: point.p,
      t: last.t,
    );
  } else {
    updated.add(point);
  }
  return List<StrokePoint>.unmodifiable(updated);
}

Drawing _commit(Drawing drawing, List<Stroke> strokes, {int? nextId}) {
  final past = <List<Stroke>>[...drawing.past, drawing.strokes];
  if (past.length > MAX_UNDO) past.removeRange(0, past.length - MAX_UNDO);
  return Drawing(
    strokes: List<Stroke>.unmodifiable(strokes),
    nextId: nextId ?? drawing.nextId,
    past: List<List<Stroke>>.unmodifiable(past),
  );
}

/// Taps (<2 samples) are not committed.
Drawing addStroke(
  Drawing drawing, {
  required DrawTool tool,
  required InkColor color,
  required InkPointerKind pointer,
  required List<StrokePoint> points,
  List<String>? targets,
}) {
  if (points.length < 2) return drawing;
  final stroke = Stroke(
    id: drawing.nextId,
    tool: tool,
    color: color,
    pointer: pointer,
    points: List<StrokePoint>.unmodifiable(points),
    startedAt: points.first.t,
    endedAt: points.last.t,
    targets: targets == null ? null : List<String>.unmodifiable(targets),
  );
  return _commit(
    drawing,
    <Stroke>[...drawing.strokes, stroke],
    nextId: drawing.nextId + 1,
  );
}

Drawing undo(Drawing drawing) {
  if (drawing.past.isEmpty) return drawing;
  return Drawing(
    strokes: drawing.past.last,
    nextId: drawing.nextId,
    past: List<List<Stroke>>.unmodifiable(
      drawing.past.sublist(0, drawing.past.length - 1),
    ),
  );
}

Drawing clear(Drawing drawing) {
  if (drawing.strokes.isEmpty) return drawing;
  return _commit(drawing, <Stroke>[]);
}

double segmentDistance2(
  InkPosition point,
  InkPosition start,
  InkPosition end,
) {
  final dx = end.x - start.x;
  final dy = end.y - start.y;
  final length2 = dx * dx + dy * dy;
  final k = length2 == 0
      ? 0.0
      : (((point.x - start.x) * dx + (point.y - start.y) * dy) / length2)
          .clamp(0.0, 1.0);
  final distanceX = start.x + k * dx - point.x;
  final distanceY = start.y + k * dy - point.y;
  return distanceX * distanceX + distanceY * distanceY;
}

/// Normalized outlines shared by eraser hit tests and the painter.
List<List<InkPosition>> strokeOutline(
  DrawTool tool,
  List<StrokePoint> points,
) {
  if (points.isEmpty) return <List<InkPosition>>[];
  final start = points.first;
  final end = points.last;
  switch (tool) {
    case DrawTool.arrow:
      final angle = math.atan2(end.y - start.y, end.x - start.x);
      final head = math.min(
        0.04,
        math.sqrt(
              math.pow(end.x - start.x, 2) +
                  math.pow(end.y - start.y, 2),
            ) *
            0.35,
      );
      const spread = math.pi / 7;
      return <List<InkPosition>>[
        <InkPosition>[start, end],
        <InkPosition>[
          InkPosition(
            end.x - head * math.cos(angle - spread),
            end.y - head * math.sin(angle - spread),
          ),
          end,
          InkPosition(
            end.x - head * math.cos(angle + spread),
            end.y - head * math.sin(angle + spread),
          ),
        ],
      ];
    case DrawTool.box:
      return <List<InkPosition>>[
        <InkPosition>[
          start,
          InkPosition(end.x, start.y),
          end,
          InkPosition(start.x, end.y),
          start,
        ],
      ];
    case DrawTool.circle:
      final cx = (start.x + end.x) / 2;
      final cy = (start.y + end.y) / 2;
      final rx = (end.x - start.x).abs() / 2;
      final ry = (end.y - start.y).abs() / 2;
      return <List<InkPosition>>[
        <InkPosition>[
          for (var i = 0; i <= 32; i++)
            InkPosition(
              cx + rx * math.cos(i / 32 * 2 * math.pi),
              cy + ry * math.sin(i / 32 * 2 * math.pi),
            ),
        ],
      ];
    case DrawTool.pen:
    case DrawTool.highlighter:
      return <List<InkPosition>>[points];
  }
}

bool strokeHit(Stroke stroke, InkPosition point, double radius) {
  final radius2 = radius * radius;
  for (final line in strokeOutline(stroke.tool, stroke.points)) {
    if (line.isEmpty) continue;
    if (line.length == 1 &&
        segmentDistance2(point, line.first, line.first) <= radius2) {
      return true;
    }
    for (var i = 1; i < line.length; i++) {
      if (segmentDistance2(point, line[i - 1], line[i]) <= radius2) {
        return true;
      }
    }
  }
  return false;
}

/// Erase entire intersected strokes in a single undoable operation.
Drawing eraseAlong(
  Drawing drawing,
  List<InkPosition> path, {
  double radius = 0.02,
}) {
  if (path.isEmpty || drawing.strokes.isEmpty) return drawing;
  final kept = <Stroke>[
    for (final stroke in drawing.strokes)
      if (!path.any((point) => strokeHit(stroke, point, radius))) stroke,
  ];
  if (kept.length == drawing.strokes.length) return drawing;
  return _commit(drawing, kept);
}

double meanPressure(List<StrokePoint> points) {
  if (points.isEmpty) return 0.5;
  return points.fold<double>(0, (sum, point) => sum + point.p) /
      points.length;
}

/// Width is in logical pixels; pressure changes only the pen width.
double strokeWidth(DrawTool tool, double pressure) {
  if (tool == DrawTool.highlighter) return 18;
  if (tool != DrawTool.pen) return 3;
  final p = pressure.isFinite ? pressure.clamp(0.0, 1.0) : 0.5;
  return 1.5 + p * 4;
}
