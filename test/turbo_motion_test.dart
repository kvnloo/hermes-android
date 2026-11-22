import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/turbo_motion.dart';
import 'package:hermes_android/core/widgets/turbo_motion_controls.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/ui/widgets.dart';
import 'package:hermes_android/shared_ui/glide_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Classic appearance enables the badge in both interfaces', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    TurboMotion.load(prefs);
    await NextGenPreferences.setEnabled(prefs, false);
    addTearDown(() async {
      await NextGenPreferences.setEnabled(prefs, false);
      await TurboMotion.setEnabled(prefs, false);
    });
    final glide = await tester.runAsync(GlideTheme.load);
    await tester.pumpWidget(
      HermesApp(connManager: ConnectionManager(prefs), glideTheme: glide!),
    );
    await tester.pumpAndSettle();

    final badge = find.byKey(const ValueKey('turbo-motion-badge'));
    expect(badge, findsNothing);
    await tester.tap(find.byKey(const Key('home_appearance_button')));
    await tester.pumpAndSettle();
    final toggle = find.text('Turbo motion');
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    Navigator.of(tester.element(toggle)).pop();
    await tester.pumpAndSettle();
    expect(badge, findsOneWidget);

    await tester.tap(find.byKey(const Key('setup-interface-nextgen')));
    await tester.pumpAndSettle();
    expect(nextGenEnabled.value, isTrue);
    expect(badge, findsOneWidget);
  });

  for (final reduceMotion in [false, true]) {
    testWidgets('Shared Turbo factor (reduced: $reduceMotion)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      TurboMotion.load(prefs);
      addTearDown(() async => TurboMotion.setEnabled(prefs, false));

      final source = (await tester.runAsync(
        () => rootBundle.loadString(GlideTheme.asset),
      ))!;
      final data = jsonDecode(source) as Map<String, dynamic>;
      // Deliberately differ from the bundled token, so a hard-coded
      // multiplier cannot satisfy the route, sheet, and widget assertions.
      const configuredFactor = 1.6;
      data['motion']['speed']['turbo'] = configuredFactor;
      final glide = GlideTheme.parse(jsonEncode(data));
      const widgetDuration = Duration(milliseconds: 320);
      const widgetKey = ValueKey('timed-widget');
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Builder(
            builder: (context) => ValueListenableBuilder<bool>(
              valueListenable: TurboMotion.enabled,
              builder: (context, _, _) => MaterialApp(
                navigatorKey: navigator,
                theme: TurboMotion.applyToTheme(
                  context,
                  ThemeData(extensions: [glide]),
                ),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (_, child) => MediaQuery(
                  data: MediaQueryData(
                    size: const Size(800, 600),
                    disableAnimations: reduceMotion,
                  ),
                  child: child!,
                ),
                home: Scaffold(
                  body: Column(
                    children: [
                      TurboMotionSwitch(preferences: prefs),
                      const TurboMotionBadge(),
                      Builder(
                        builder: (context) => AnimatedContainer(
                          key: widgetKey,
                          duration: TurboMotion.duration(
                            context,
                            widgetDuration,
                          ),
                        ),
                      ),
                      Builder(
                        builder: (context) => TextButton(
                          onPressed: () => showNgSheet<void>(
                            context,
                            builder: (_) => const SizedBox(height: 100),
                          ),
                          child: const Text('Open sheet'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final badge = find.byKey(const ValueKey('turbo-motion-badge'));
      expect(badge, findsNothing);

      Future<(Duration, Duration)> openPage() async {
        final page = MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Destination')),
        );
        navigator.currentState!.push(page);
        await tester.pumpAndSettle();
        final durations = (
          page.transitionDuration,
          page.reverseTransitionDuration,
        );
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        return durations;
      }

      Future<(Duration, Duration)> openSheet() async {
        await tester.tap(find.text('Open sheet'));
        await tester.pumpAndSettle();
        final route = ModalRoute.of(tester.element(find.byType(BottomSheet)))!;
        expect(route, isA<ModalBottomSheetRoute<void>>());
        final durations = (
          route.transitionDuration,
          route.reverseTransitionDuration,
        );
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        return durations;
      }

      final standardPage = await openPage();
      final standardSheet = await openSheet();
      expect(standardSheet, (
        const Duration(milliseconds: 250),
        const Duration(milliseconds: 200),
      ));
      Duration currentWidgetDuration() =>
          tester.widget<AnimatedContainer>(find.byKey(widgetKey)).duration;
      expect(currentWidgetDuration(), widgetDuration);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(badge, findsOneWidget);
      expect(find.text('Turbo'), findsOneWidget);
      expect(prefs.getBool(TurboMotion.preferenceKey), isTrue);
      TurboMotion.load(prefs);
      expect(TurboMotion.enabled.value, isTrue);

      Duration expected(Duration standard) => reduceMotion
          ? standard
          : Duration(
              microseconds: (standard.inMicroseconds / configuredFactor)
                  .round(),
            );
      expect(await openPage(), (
        expected(standardPage.$1),
        expected(standardPage.$2),
      ));
      expect(await openSheet(), (
        expected(standardSheet.$1),
        expected(standardSheet.$2),
      ));
      expect(currentWidgetDuration(), expected(widgetDuration));

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(badge, findsNothing);
      expect(prefs.getBool(TurboMotion.preferenceKey), isFalse);
      expect(await openPage(), standardPage);
      expect(await openSheet(), standardSheet);
      expect(currentWidgetDuration(), widgetDuration);
    });
  }
}
