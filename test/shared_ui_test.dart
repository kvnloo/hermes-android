import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/android_launch_intent_service.dart';
import 'package:hermes_android/core/services/android_share_intent_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/turbo_motion.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/main.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/shared_ui/glide_theme.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'loading the bundled Glide asset builds light and dark themes',
    () async {
      final glide = await GlideTheme.load();
      expect(glide.brandName, 'Glide');
      for (final brightness in Brightness.values) {
        final expected = glide.color(brightness, 'primary');
        final classic = hermesTheme(brightness, glide: glide);
        final nextGen = nextGenTheme(
          brightness,
          NextGenLook.instance,
          glide: glide,
        );
        for (final theme in [classic, nextGen]) {
          expect(theme.colorScheme.primary, expected);
          expect(theme.scaffoldBackgroundColor, glide.color(brightness, 'bg'));
          expect(theme.extension<GlideTheme>(), same(glide));
          expect(theme.textTheme.bodyLarge!.fontSize, 15);
          expect(theme.textTheme.bodyLarge!.height, 1.5);
          final shape = theme.cardTheme.shape as RoundedRectangleBorder;
          expect(
            shape.borderRadius,
            BorderRadius.circular(glide.radius('card')),
          );
        }
      }
      expect(glide.color(Brightness.dark, 'messageBorder'), Colors.transparent);
      expect(glide.duration('base'), const Duration(milliseconds: 250));
      expect(
        glide.duration('base', turbo: true),
        const Duration(milliseconds: 125),
      );
      expect(
        glide.duration('base', speed: 0.1),
        const Duration(milliseconds: 500),
      );
      expect(
        glide.duration('base', turbo: true, reduceMotion: true),
        Duration.zero,
      );
      expect(glide.glass('bar'), (blur: 16.0, saturation: 1.3, tint: 0.82));
    },
  );

  testWidgets('changing the loaded asset changes both app themes', (
    tester,
  ) async {
    final source = (await tester.runAsync(
      () => rootBundle.loadString(GlideTheme.asset),
    ))!;
    final data = jsonDecode(source) as Map<String, dynamic>;
    data['color']['light']['primary'] = '#123456';
    data['color']['dark']['primary'] = '#ABCDEF';
    data['radius']['card'] = 25;
    data['type']['base']['size'] = 19;
    data['motion']['duration']['base'] = 312;
    data['motion']['speed']['turbo'] = 1.5;
    final changed = GlideTheme.parse(jsonEncode(data));
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Glide',
      packageName: 'test',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'flutter_tts',
      AndroidShareIntentService.channelName,
      AndroidLaunchIntentService.channelName,
    ]) {
      final channel = MethodChannel(name);
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }
    final saved = nextGenEnabled.value;
    addTearDown(() => nextGenEnabled.value = saved);
    Future<GlideTheme> load() async => changed;

    await tester.pumpWidget(
      StartupApp(
        loadTheme: load,
        createConnectionManager: (prefs) async => ConnectionManager(prefs),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(HermesApp), findsOneWidget);

    for (final nextGen in [false, true]) {
      nextGenEnabled.value = nextGen;
      await tester.pumpAndSettle();
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.themeAnimationDuration, const Duration(milliseconds: 312));
      expect(app.theme!.colorScheme.primary, const Color(0xFF123456));
      expect(app.darkTheme!.colorScheme.primary, const Color(0xFFABCDEF));
      expect(app.theme!.textTheme.bodyLarge!.fontSize, 19);
      final shape = app.theme!.cardTheme.shape as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(25));
    }
    final prefs = await SharedPreferences.getInstance();
    addTearDown(() => TurboMotion.setEnabled(prefs, false));
    await TurboMotion.setEnabled(prefs, true);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MaterialApp>(find.byType(MaterialApp))
          .themeAnimationDuration,
      const Duration(milliseconds: 208),
    );
  });

  test('rejects unsupported theme formats', () {
    expect(() => GlideTheme.parse('{"v":1}'), throwsFormatException);
  });
}
