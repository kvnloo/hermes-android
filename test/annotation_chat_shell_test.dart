import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/controllers/annotation_controller.dart';
import 'package:hermes_android/core/widgets/annotation_chat_shell.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  testWidgets('mode toggle, capture action and dismiss retain unsent ink state', (
    tester,
  ) async {
    final controller = AnnotationController();
    addTearDown(controller.dispose);
    var attached = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AnnotationChatShell(
            controller: controller,
            boundaryKey: GlobalKey(),
            capturing: false,
            onCapture: () => attached++,
            child: const ColoredBox(color: Colors.blue),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('annotation-snapshot')), findsNothing);
    controller.stylusButton(true);
    await tester.pump();
    expect(controller.active, isTrue);
    expect(find.byKey(const Key('annotation-snapshot')), findsOneWidget);
    controller.stylusButton(true);
    await tester.pump();
    expect(controller.active, isTrue);
    await tester.tap(find.byKey(const Key('annotation-snapshot')));
    expect(attached, 1);
    await tester.tap(find.byKey(const Key('annotation-exit')));
    await tester.pump();
    expect(controller.active, isFalse);
    controller.stylusButton(false);
    controller.stylusButton(true);
    await tester.pump();
    expect(controller.active, isTrue);
  });

  testWidgets('capture action is disabled while the reserved slot is in flight', (
    tester,
  ) async {
    final controller = AnnotationController()..enter();
    addTearDown(controller.dispose);
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AnnotationChatShell(
            controller: controller,
            boundaryKey: GlobalKey(),
            capturing: true,
            onCapture: () => calls++,
            child: const ColoredBox(color: Colors.blue),
          ),
        ),
      ),
    );
    final button = tester.widget<IconButton>(
      find.byKey(const Key('annotation-snapshot')),
    );
    expect(button.onPressed, isNull);
    expect(calls, 0);
    expect(controller.active, isTrue);
  });

  testWidgets('reserved snapshot slot keeps composer geometry on commit', (
    tester,
  ) async {
    Widget composerWithDraftRows(int rows) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 400,
          child: Column(
            children: [
              const Expanded(child: ColoredBox(color: Colors.blue)),
              AnnotationAttachmentSlotViewport(
                annotationActive: true,
                reservedRowCount: 1,
                availableHeight: 400,
                child: ListView.builder(
                  itemCount: rows,
                  itemBuilder: (context, index) =>
                      const SizedBox(height: annotationDraftRowExtent),
                ),
              ),
              const SizedBox(
                key: Key('composer-anchor'),
                height: 56,
              ),
            ],
          ),
        ),
      ),
    );

    // Slot exists before ink begins; committing a draft only changes the
    // scrollable contents, never the composer origin or capture geometry.
    await tester.pumpWidget(composerWithDraftRows(1));
    final slot = find.byType(AnnotationAttachmentSlotViewport);
    final initialHeight = tester.getSize(slot).height;
    final initialComposerTop = tester.getTopLeft(
      find.byKey(const Key('composer-anchor')),
    ).dy;
    expect(initialHeight, annotationDraftRowExtent);

    await tester.pumpWidget(composerWithDraftRows(2));
    expect(tester.getSize(slot).height, initialHeight);
    expect(
      tester.getTopLeft(find.byKey(const Key('composer-anchor'))).dy,
      initialComposerTop,
    );
  });
}
