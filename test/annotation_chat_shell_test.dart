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
}
