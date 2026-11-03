import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/controllers/annotation_controller.dart';
import 'package:hermes_android/core/models/annotation_ink.dart';
import 'package:hermes_android/core/widgets/ink_overlay.dart';

void main() {
  testWidgets('stylus drag commits ink; touch drag is ignored in pen mode', (
    tester,
  ) async {
    final controller = AnnotationController()
      ..enter()
      ..setPenMode(true);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: InkOverlay(controller: controller),
            ),
          ),
        ),
      ),
    );
    final origin = tester.getTopLeft(find.byType(InkOverlay));
    final stylus = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await stylus.down(origin + const Offset(20, 40));
    await stylus.moveTo(origin + const Offset(130, 70));
    await stylus.up();
    await tester.pump();

    expect(controller.drawing.strokes, hasLength(1));
    final stroke = controller.drawing.strokes.single;
    expect(stroke.pointer, InkPointerKind.stylus);
    expect(stroke.points.first.x, closeTo(0.10, 0.001));
    expect(stroke.points.last.y, closeTo(0.35, 0.001));
    expect(controller.live, isNull);
    expect(find.byType(CustomPaint), findsWidgets);

    final finger = await tester.createGesture(kind: PointerDeviceKind.touch);
    await finger.down(origin + const Offset(30, 90));
    await finger.moveTo(origin + const Offset(140, 110));
    await finger.up();
    await tester.pump();

    expect(controller.drawing.strokes, hasLength(1));
    expect(controller.live, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('finger scroll passes through the active pen-mode overlay', (
    tester,
  ) async {
    final controller = AnnotationController()
      ..enter()
      ..setPenMode(true);
    final scroll = ScrollController();
    addTearDown(controller.dispose);
    addTearDown(scroll.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              ListView(
                controller: scroll,
                children: const <Widget>[SizedBox(height: 1600)],
              ),
              InkOverlay(controller: controller),
            ],
          ),
        ),
      ),
    );

    await tester.drag(
      find.byType(InkOverlay),
      const Offset(0, -180),
      kind: PointerDeviceKind.touch,
    );
    await tester.pumpAndSettle();

    expect(scroll.offset, greaterThan(0));
    expect(controller.drawing.strokes, isEmpty);
  });

  testWidgets('closed mode does not intercept pointers or restore a draft', (
    tester,
  ) async {
    final controller = AnnotationController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InkOverlay(controller: controller),
        ),
      ),
    );
    expect(controller.active, isFalse);
    await tester.drag(
      find.byType(InkOverlay),
      const Offset(90, 30),
      kind: PointerDeviceKind.stylus,
      warnIfMissed: false,
    );
    await tester.pump();
    expect(controller.drawing.strokes, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
