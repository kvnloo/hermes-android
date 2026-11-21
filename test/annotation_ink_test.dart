import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/annotation_ink.dart';

const _a = StrokePoint(0.10, 0.20, p: 0.2, t: 100);
const _b = StrokePoint(0.90, 0.20, p: 0.8, t: 120);

Drawing _add(Drawing drawing, {DrawTool tool = DrawTool.pen}) {
  return addStroke(
    drawing,
    tool: tool,
    color: InkColor.accent,
    pointer: InkPointerKind.stylus,
    points: <StrokePoint>[_a, _b],
  );
}

void main() {
  test('empty drawing is immutable and short taps are ignored', () {
    expect(EMPTY_DRAWING.strokes, isEmpty);
    expect(EMPTY_DRAWING.nextId, 1);
    final tap = addStroke(
      EMPTY_DRAWING,
      tool: DrawTool.pen,
      color: InkColor.red,
      pointer: InkPointerKind.touch,
      points: <StrokePoint>[_a],
    );
    expect(identical(tap, EMPTY_DRAWING), isTrue);
    expect(() => EMPTY_DRAWING.strokes.add(_add(EMPTY_DRAWING).strokes.single),
        throwsUnsupportedError);
  });

  test('add records stable IDs, timestamps, pressure and independent points', () {
    final points = <StrokePoint>[_a, _b];
    final targets = <String>['component-1'];
    final first = addStroke(
      EMPTY_DRAWING,
      tool: DrawTool.highlighter,
      color: InkColor.red,
      pointer: InkPointerKind.touch,
      points: points,
      targets: targets,
    );
    points.clear();
    targets.clear();
    final second = _add(first);
    expect(first.strokes.single.points, hasLength(2));
    expect(second.strokes.map((stroke) => stroke.id), <int>[1, 2]);
    expect(second.nextId, 3);
    expect(first.strokes.single.startedAt, 100);
    expect(first.strokes.single.endedAt, 120);
    expect(first.strokes.single.color, InkColor.red);
    expect(first.strokes.single.targets, <String>['component-1']);
    expect(first.strokes.single.tool, DrawTool.highlighter);
    expect(first.strokes.single.pointer, InkPointerKind.touch);
    expect(first.past, hasLength(1));
    expect(second.past.last, same(first.strokes));
  });

  test('undo restores last snapshot without reusing stroke IDs', () {
    final first = _add(EMPTY_DRAWING);
    final second = _add(first);
    final previous = undo(second);
    expect(previous.strokes.map((stroke) => stroke.id), <int>[1]);
    expect(previous.nextId, 3);
    expect(_add(previous).strokes.last.id, 3);
    expect(identical(undo(EMPTY_DRAWING), EMPTY_DRAWING), isTrue);
  });

  test('clear is undoable but an empty clear is a no-op', () {
    final first = _add(EMPTY_DRAWING);
    final cleared = clear(first);
    expect(cleared.strokes, isEmpty);
    expect(cleared.nextId, 2);
    expect(undo(cleared).strokes.single.id, 1);
    expect(identical(clear(EMPTY_DRAWING), EMPTY_DRAWING), isTrue);
  });

  test('eraseAlong intersects segments, groups edits and supports undo', () {
    final first = _add(EMPTY_DRAWING);
    final other = addStroke(
      first,
      tool: DrawTool.pen,
      color: InkColor.accent,
      pointer: InkPointerKind.stylus,
      points: const <StrokePoint>[
        StrokePoint(0.1, 0.8, t: 200),
        StrokePoint(0.9, 0.8, t: 220),
      ],
    );
    final unchanged = eraseAlong(other, const <InkPosition>[InkPosition(0.5, 0.5)]);
    expect(identical(unchanged, other), isTrue);
    final erased = eraseAlong(
      other,
      const <InkPosition>[InkPosition(0.5, 0.21)],
    );
    expect(erased.strokes.map((stroke) => stroke.id), <int>[2]);
    expect(erased.past.length, other.past.length + 1);
    expect(undo(erased).strokes, hasLength(2));
  });

  test('history retains only fifty snapshots', () {
    var drawing = EMPTY_DRAWING;
    for (var index = 0; index < 54; index++) {
      drawing = _add(drawing);
    }
    expect(drawing.strokes, hasLength(54));
    expect(drawing.past, hasLength(MAX_UNDO));
  });

  test('pointer routing, contact and pressure match Dash palm rejection', () {
    expect(routePointer(InkPointerKind.stylus, penMode: true, pointers: 1), isTrue);
    expect(routePointer(InkPointerKind.touch, penMode: true, pointers: 1), isFalse);
    expect(routePointer(InkPointerKind.mouse, penMode: true, pointers: 1), isFalse);
    expect(routePointer(InkPointerKind.touch, penMode: false, pointers: 1), isTrue);
    expect(routePointer(InkPointerKind.other, penMode: false, pointers: 1), isFalse);
    expect(routePointer(InkPointerKind.stylus, penMode: true, pointers: 2), isFalse);
    expect(stylusEnters(InkPointerKind.stylus), isFalse);
    expect(pressureOf(InkPointerKind.touch, 0.9), 0.5);
    expect(pressureOf(InkPointerKind.stylus, -1), 0.5);
    expect(pressureOf(InkPointerKind.stylus, double.nan), 0.5);
    expect(pressureOf(InkPointerKind.stylus, 2), 1);
    expect(pressureOf(InkPointerKind.stylus, 0.3), 0.3);
  });

  test('duplicate sample coordinates update pressure but retain time', () {
    final original = <StrokePoint>[_a];
    final changed = appendInkSample(
      original,
      const StrokePoint(0.10, 0.20, p: 0.9, t: 900),
    );
    expect(changed, hasLength(1));
    expect(changed.single.p, 0.9);
    expect(changed.single.t, 100);
    expect(original.single.p, 0.2);
    expect(
      appendInkSample(changed, const StrokePoint(double.nan, 0, t: 1)),
      hasLength(1),
    );
  });

  test('outlines and widths cover highlighter and geometric tools', () {
    expect(strokeWidth(DrawTool.pen, 0), 1.5);
    expect(strokeWidth(DrawTool.pen, 1), 5.5);
    expect(strokeWidth(DrawTool.highlighter, 0), 18);
    expect(strokeWidth(DrawTool.box, 0.5), 3);
    expect(drawingTool(Tool.eraser), isNull);
    expect(strokeOutline(DrawTool.box, <StrokePoint>[_a, _b]).single, hasLength(5));
    expect(strokeOutline(DrawTool.circle, <StrokePoint>[_a, _b]).single, hasLength(33));
    expect(strokeOutline(DrawTool.arrow, <StrokePoint>[_a, _b]), hasLength(2));
    expect(meanPressure(<StrokePoint>[_a, _b]), closeTo(0.5, 0.00001));
  });
}
