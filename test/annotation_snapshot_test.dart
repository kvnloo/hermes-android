import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/annotation_ink.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/services/annotation_snapshot.dart';
import 'package:hermes_android/core/services/attachment_draft_service.dart';
import 'package:image/image.dart' as image_lib;

Future<ui.Image> _fakeBoundary(RenderRepaintBoundary boundary, double scale) async {
  expect(boundary.size, const Size(100, 60));
  expect(scale, 2);
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, 200, 120),
    ui.Paint()..color = const Color(0xff0000ff),
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(200, 120);
  } finally {
    picture.dispose();
  }
}

void main() {
  testWidgets('composites committed red ink above a fake blue boundary at device scale', (
    tester,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 100,
            height: 60,
            child: RepaintBoundary(
              key: key,
              child: const ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final drawing = Drawing(
      strokes: <Stroke>[
        Stroke(
          id: 1,
          tool: DrawTool.pen,
          color: InkColor.red,
          pointer: InkPointerKind.stylus,
          points: const <StrokePoint>[
            StrokePoint(0.1, 0.5, t: 100),
            StrokePoint(0.9, 0.5, t: 120),
          ],
          startedAt: 100,
          endedAt: 120,
        ),
      ],
      nextId: 2,
      past: const <List<Stroke>>[],
    );
    final capture = AnnotationSnapshotCapture(captureBoundary: _fakeBoundary);
    final bytes = await capture.capture(
      boundaryKey: key,
      drawing: drawing,
      accent: Colors.green,
      red: Colors.red,
      eraserColor: Colors.black,
      pixelRatio: 2,
    );
    final decoded = image_lib.decodePng(bytes);
    expect(decoded, isNotNull);
    expect(decoded!.width, 200);
    expect(decoded.height, 120);
    final background = decoded.getPixel(100, 10);
    final ink = decoded.getPixel(100, 60);
    expect(background.b, greaterThan(background.r));
    expect(ink.r, greaterThan(ink.b));
    expect(drawing.strokes, hasLength(1));
  });

  testWidgets('captured PNG enters existing draft service without submitting', (
    tester,
  ) async {
    final key = GlobalKey();
    final sandbox = await Directory.systemTemp.createTemp('annotation-snapshot-');
    addTearDown(() async => sandbox.delete(recursive: true));
    final drafts = <AttachmentDraft>[];
    final service = AttachmentDraftService(
      cacheDirectoryProvider: () async => Directory('${sandbox.path}/cache'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 100,
            height: 60,
            child: RepaintBoundary(
              key: key,
              child: const ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final bytes = await const AnnotationSnapshotCapture(
      captureBoundary: _fakeBoundary,
    ).capture(
      boundaryKey: key,
      drawing: EMPTY_DRAWING,
      accent: Colors.green,
      red: Colors.red,
      eraserColor: Colors.black,
      pixelRatio: 2,
    );
    final draft = await service.prepareCapturedPng(
      pngBytes: bytes,
      displayName: 'annotation.png',
      existingDrafts: drafts,
      mode: AttachmentDraftMode.remoteGateway,
    );
    drafts.add(draft);
    expect(drafts, hasLength(1));
    expect(draft.name, 'annotation.png');
    expect(draft.sanitized, isTrue);
    expect(draft.mediaType, 'image/png');
    expect(await File(draft.cachedPath).exists(), isTrue);
    expect(image_lib.decodePng(await File(draft.cachedPath).readAsBytes()), isNotNull);
    await service.removeAll(drafts);
  });

  testWidgets('failed capture preserves all ink for retry', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 100,
            height: 60,
            child: RepaintBoundary(
              key: key,
              child: const ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final drawing = addStroke(
      EMPTY_DRAWING,
      tool: DrawTool.pen,
      color: InkColor.accent,
      pointer: InkPointerKind.stylus,
      points: const <StrokePoint>[
        StrokePoint(0.1, 0.1, t: 1),
        StrokePoint(0.8, 0.8, t: 2),
      ],
    );
    await expectLater(
      const AnnotationSnapshotCapture(
        captureBoundary: _throwCapture,
      ).capture(
        boundaryKey: key,
        drawing: drawing,
        accent: Colors.green,
        red: Colors.red,
        eraserColor: Colors.black,
      ),
      throwsStateError,
    );
    expect(drawing.strokes, hasLength(1));
  });
}

Future<ui.Image> _throwCapture(RenderRepaintBoundary boundary, double scale) async {
  throw StateError('Fake boundary failure');
}
