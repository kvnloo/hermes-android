// Drives the whole annotation mode through ChatScreen, as a user would:
// chat menu -> "Annotate screen" -> draw -> attach -> the marked-up PNG is an
// attachment draft in the composer, ready to send with the next message.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/controllers/annotation_controller.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/annotation_snapshot.dart';
import 'package:hermes_android/core/services/attachment_draft_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/widgets/attachment_draft_tile.dart';
import 'package:hermes_android/core/widgets/ink_overlay.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_composer_adapter.dart';

Future<ui.Image> _boundary(RenderRepaintBoundary boundary, double scale) async {
  final width = (boundary.size.width * scale).round();
  final height = (boundary.size.height * scale).round();
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const Color(0xff0000ff),
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

void main() {
  testWidgets('chat menu annotates the screen and attaches the PNG', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // A small 1x surface keeps the pure-Dart PNG re-encode quick.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const picker = MethodChannel('plugins.flutter.io/image_picker');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(picker, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(picker, null));
    final sandbox = Directory.systemTemp.createTempSync('annotation-flow-');
    addTearDown(() => sandbox.deleteSync(recursive: true));
    final ink = AnnotationController();
    addTearDown(ink.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChatScreen(
          connection: SavedConnection(
            id: 'annotation-flow-test',
            label: 'Local test',
            host: '127.0.0.1',
            port: 1,
            apiKey: 'test-key',
          ),
          session: const Session(
            id: 'annotation-flow',
            title: 'Annotation',
            model: 'test',
            source: 'test',
            messageCount: 0,
            isActive: false,
            preview: '',
            startedAt: 1,
          ),
          annotationController: ink,
          testApiClient: ApiClient(
            baseUrl: 'https://fixture.invalid',
            apiKey: 'test-key',
            httpClient: MockClient(
              (_) async => http.Response(jsonEncode({'data': []}), 200),
            ),
          ),
          testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
          testAnnotationSnapshotCapture: const AnnotationSnapshotCapture(
            captureBoundary: _boundary,
          ),
          testAttachmentDraftService: AttachmentDraftService(
            cacheDirectoryProvider: () async =>
                Directory('${sandbox.path}/cache'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(ink.active, isFalse);
    expect(find.byType(InkOverlay), findsNothing);

    await tester.tap(find.byTooltip('Chat actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Annotate screen'));
    await tester.pumpAndSettle();
    expect(ink.active, isTrue);
    expect(find.byType(InkOverlay), findsOneWidget);

    final overlay = tester.getRect(find.byType(InkOverlay));
    final gesture = await tester.startGesture(
      overlay.center - const Offset(60, 0),
    );
    for (var step = 1; step <= 6; step++) {
      await gesture.moveBy(const Offset(20, 4));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump();
    expect(ink.drawing.strokes, hasLength(1));

    await tester.tap(find.byKey(const Key('annotation-snapshot')));
    for (
      var i = 0;
      i < 200 && find.byType(AttachmentDraftTile).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    final tile = tester.widget<AttachmentDraftTile>(
      find.byType(AttachmentDraftTile),
    );
    expect(tile.draft.name, startsWith('annotation-'));
    expect(tile.draft.name, endsWith('.png'));
    expect(tile.draft.mediaType, 'image/png');
    expect(tile.draft.sanitized, isTrue);
    final cached = Directory('${sandbox.path}/cache')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.png'))
        .toList();
    expect(cached, hasLength(1));
    expect(cached.single.lengthSync(), greaterThan(0));

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
