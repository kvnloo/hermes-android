import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/controllers/annotation_controller.dart';
import 'package:hermes_android/core/models/annotation_ink.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/annotation_snapshot.dart';
import 'package:hermes_android/core/services/attachment_draft_service.dart';
import 'package:hermes_android/core/widgets/annotation_chat_shell.dart';
import 'package:hermes_android/core/widgets/ink_overlay.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:image/image.dart' as image_lib;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_composer_adapter.dart';

Future<ui.Image> _fakeBoundary(
  RenderRepaintBoundary boundary,
  double scale,
) async {
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
    final bytes = await tester.runAsync(
      () => capture.capture(
        boundaryKey: key,
        drawing: drawing,
        accent: Colors.green,
        red: Colors.red,
        eraserColor: Colors.black,
        pixelRatio: 2,
      ),
    );
    expect(bytes, isNotNull);
    final decoded = image_lib.decodePng(bytes!);
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
    // Temp setup must also avoid FakeAsync's non-advancing I/O clock.
    final sandbox = Directory.systemTemp.createTempSync('annotation-snapshot-');
    addTearDown(() => sandbox.deleteSync(recursive: true));
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
    // Picture.toImage and PNG encoding need the real async clock in widget
    // tests; the fake RepaintBoundary seam still verifies the 2x scale.
    await tester.runAsync(() async {
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
      expect(
        image_lib.decodePng(await File(draft.cachedPath).readAsBytes()),
        isNotNull,
      );
      await service.removeAll(drafts);
    });
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

  testWidgets('ChatScreen passes its route owner into the snapshot shell', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final owner = AnnotationController()..enter();
    addTearDown(owner.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChatScreen(
          connection: SavedConnection(
            id: 'annotation-owner-test',
            label: 'Local test',
            host: '127.0.0.1',
            port: 1,
            apiKey: '',
          ),
          session: const Session(
            id: 'annotation-session',
            title: 'Annotation',
            model: 'test',
            source: 'test',
            messageCount: 0,
            isActive: false,
            preview: '',
            startedAt: 1,
          ),
          annotationController: owner,
          testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
        ),
      ),
    );
    final shell = tester.widget<AnnotationChatShell>(
      find.byType(AnnotationChatShell),
    );
    expect(identical(shell.controller, owner), isTrue);
    expect(find.byType(InkOverlay), findsOneWidget);
    expect(
      identical(tester.widget<InkOverlay>(find.byType(InkOverlay)).controller, owner),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(owner.active, isTrue);
  });

  testWidgets('chat snapshot uses the one injected ink owner and keeps it alive', (
    tester,
  ) async {
    final owner = AnnotationController()..enter();
    addTearDown(owner.dispose);
    final boundaryKey = GlobalKey();
    Drawing? submittedDrawing;
    var captureActions = 0;

    Widget chat(AnnotationController? controller) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 240,
            child: AnnotationChatShell(
              controller: controller,
              boundaryKey: boundaryKey,
              capturing: false,
              onCapture: () {
                captureActions++;
                submittedDrawing = controller?.drawing;
              },
              child: const ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(chat(owner));
    owner.startStroke(
      pointer: InkPointerKind.stylus,
      point: const StrokePoint(0.1, 0.5, t: 100),
      pointers: 1,
    );
    owner.appendStrokePoint(const StrokePoint(0.9, 0.5, t: 120));
    owner.finishStroke();
    await tester.pump();

    final shell = tester.widget<AnnotationChatShell>(
      find.byType(AnnotationChatShell),
    );
    expect(identical(shell.controller, owner), isTrue);
    expect(find.byType(InkOverlay), findsOneWidget);
    expect(
      identical(tester.widget<InkOverlay>(find.byType(InkOverlay)).controller, owner),
      isTrue,
    );

    await tester.tap(find.byKey(const Key('annotation-snapshot')));
    expect(captureActions, 1);
    expect(identical(submittedDrawing, owner.drawing), isTrue);
    expect(submittedDrawing!.strokes, hasLength(1));

    final bytes = await tester.runAsync(
      () => const AnnotationSnapshotCapture(captureBoundary: _blueChatBoundary)
          .capture(
            boundaryKey: boundaryKey,
            drawing: submittedDrawing!,
            accent: Colors.green,
            red: Colors.red,
            eraserColor: Colors.black,
          ),
    );
    expect(bytes, isNotNull);
    final png = image_lib.decodePng(bytes!);
    expect(png, isNotNull);
    expect(png!.width, 400);
    expect(png.height, 240);
    expect(png.getPixel(200, 10).b, greaterThan(png.getPixel(200, 10).r));
    expect(png.getPixel(200, 120).r, greaterThan(png.getPixel(200, 120).b));

    // Unmounting the attach-only UI never disposes the route-owned controller.
    await tester.pumpWidget(chat(null));
    expect(find.byType(InkOverlay), findsNothing);
    expect(find.byKey(const Key('annotation-snapshot')), findsNothing);
    expect(owner.active, isTrue);
    expect(owner.drawing.strokes, hasLength(1));
  });
}

Future<ui.Image> _throwCapture(
  RenderRepaintBoundary boundary,
  double scale,
) async {
  throw StateError('Fake boundary failure');
}

Future<ui.Image> _blueChatBoundary(
  RenderRepaintBoundary boundary,
  double scale,
) async {
  expect(boundary.size, const Size(400, 240));
  expect(scale, 1);
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, 400, 240),
    ui.Paint()..color = Colors.blue,
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(400, 240);
  } finally {
    picture.dispose();
  }
}
