import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/controllers/annotation_controller.dart';
import 'package:hermes_android/core/models/annotation_ink.dart';

const _first = StrokePoint(0.1, 0.2, p: 0.4, t: 100);
const _last = StrokePoint(0.7, 0.2, p: 0.7, t: 120);

void _drag(AnnotationController controller, {InkPointerKind kind = InkPointerKind.stylus}) {
  controller.startStroke(pointer: kind, point: _first, pointers: 1);
  controller.appendStrokePoint(_last);
  controller.finishStroke();
}

void main() {
  test('each controller starts closed, unlatched and without persisted ink', () {
    final old = AnnotationController();
    addTearDown(old.dispose);
    old.enter();
    _drag(old);
    old.setPenMode(true);
    expect(old.drawing.strokes, hasLength(1));

    final fresh = AnnotationController();
    addTearDown(fresh.dispose);
    expect(fresh.active, isFalse);
    expect(fresh.buttonDown, isFalse);
    expect(fresh.penMode, isFalse);
    expect(fresh.tool, Tool.pen);
    expect(fresh.color, InkColor.accent);
    expect(identical(fresh.drawing, EMPTY_DRAWING), isTrue);
    expect(fresh.live, isNull);
  });

  test('button rising edges toggle exactly once; release and repeats do not', () {
    final c = AnnotationController();
    addTearDown(c.dispose);
    var notifications = 0;
    c.addListener(() => notifications++);

    c.stylusButton(true);
    expect(c.active, isTrue);
    expect(c.penMode, isTrue);
    expect(c.buttonDown, isTrue);
    c.stylusButton(true);
    expect(c.active, isTrue);
    expect(notifications, 1);

    c.toggle();
    expect(c.active, isFalse);
    expect(c.buttonDown, isTrue);
    c.stylusButton(false);
    expect(c.active, isFalse);
    expect(c.buttonDown, isFalse);
    c.stylusButton(false);
    expect(notifications, 3);

    c.stylusButton(true);
    expect(c.active, isTrue);
    expect(c.buttonDown, isTrue);
    expect(notifications, 4);
  });

  test('contact cannot open the mode, and penMode rejects touch and mouse', () {
    final c = AnnotationController();
    addTearDown(c.dispose);
    c.startStroke(pointer: InkPointerKind.stylus, point: _first, pointers: 1);
    expect(c.active, isFalse);
    expect(c.live, isNull);

    c.enter();
    c.setPenMode(true);
    c.startStroke(pointer: InkPointerKind.touch, point: _first, pointers: 1);
    c.startStroke(pointer: InkPointerKind.mouse, point: _first, pointers: 1);
    c.startStroke(pointer: InkPointerKind.stylus, point: _first, pointers: 2);
    expect(c.live, isNull);
    _drag(c, kind: InkPointerKind.stylus);
    expect(c.drawing.strokes, hasLength(1));
    expect(c.drawing.strokes.single.pointer, InkPointerKind.stylus);
  });

  test('switches preserve unsent ink, including an in-progress stroke', () {
    final c = AnnotationController();
    addTearDown(c.dispose);
    c.enter();
    c.startStroke(pointer: InkPointerKind.touch, point: _first, pointers: 1);
    c.appendStrokePoint(_last);
    c.toggle();
    expect(c.active, isFalse);
    expect(c.live, isNull);
    expect(c.drawing.strokes, hasLength(1));
    c.toggle();
    expect(c.active, isTrue);
    expect(c.drawing.strokes.single.id, 1);

    c.setTool(Tool.highlighter);
    c.setColor(InkColor.red);
    _drag(c, kind: InkPointerKind.touch);
    expect(c.drawing.strokes.last.tool, DrawTool.highlighter);
    expect(c.drawing.strokes.last.color, InkColor.red);
    c.stylusButton(true);
    expect(c.active, isFalse);
    expect(c.drawing.strokes, hasLength(2));
  });

  test('discard is the only exit that destroys the draft', () {
    final c = AnnotationController();
    addTearDown(c.dispose);
    c.enter();
    _drag(c);
    c.stylusButton(true);
    expect(c.active, isFalse);
    c.discard();
    expect(c.active, isFalse);
    expect(identical(c.drawing, EMPTY_DRAWING), isTrue);
    expect(c.buttonDown, isTrue);
    c.stylusButton(true);
    expect(c.active, isFalse);
    c.stylusButton(false);
    c.stylusButton(true);
    expect(c.active, isTrue);
    expect(c.drawing.strokes, isEmpty);
  });

  test('eraser commits one undo step and undo restores erased strokes', () {
    final c = AnnotationController();
    addTearDown(c.dispose);
    c.enter();
    _drag(c);
    c.setTool(Tool.eraser);
    c.startStroke(
      pointer: InkPointerKind.touch,
      point: const StrokePoint(0.5, 0.21, t: 200),
      pointers: 1,
    );
    c.appendStrokePoint(const StrokePoint(0.6, 0.21, t: 210));
    c.finishStroke();
    expect(c.drawing.strokes, isEmpty);
    expect(c.drawing.past, hasLength(2));
    c.undoStroke();
    expect(c.drawing.strokes, hasLength(1));
    c.clearStrokes();
    expect(c.drawing.strokes, isEmpty);
    c.undoStroke();
    expect(c.drawing.strokes, hasLength(1));
  });

  test('confirmed send preserves new ink and cannot undo old ink', () {
    final c = AnnotationController();
    addTearDown(c.dispose);
    c.enter();
    _drag(c);
    final sentId = c.drawing.strokes.single.id;
    _drag(c);
    final newerId = c.drawing.strokes.last.id;
    c.removeSubmittedStrokeIds({sentId});
    expect(c.drawing.strokes.map((stroke) => stroke.id), [newerId]);
    c.undoStroke();
    expect(c.drawing.strokes.map((stroke) => stroke.id), [newerId]);
  });

  test('multi-touch cancellation does not destroy committed ink', () {
    final c = AnnotationController();
    addTearDown(c.dispose);
    c.enter();
    _drag(c);
    c.startStroke(pointer: InkPointerKind.touch, point: _first, pointers: 1);
    c.appendStrokePoint(_last);
    c.cancelStroke();
    expect(c.live, isNull);
    expect(c.drawing.strokes, hasLength(1));
    c.clearStrokes();
    expect(c.drawing.strokes, isEmpty);
  });
}
