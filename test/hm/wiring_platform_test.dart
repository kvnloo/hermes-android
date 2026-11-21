// The app entry and Android host carry the Settings wiring: MainActivity is
// a FragmentActivity (local_auth) that answers the security channel, and
// main.dart loads the settings, covers NextGen with the lock gate and
// installs the message cache. The gate itself, mounted as main.dart mounts
// it, covers the app at launch when the lock is on.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/features/settings/app_lock.dart';
import 'package:hermes_android/hm/features/settings/settings_prefs.dart';
import 'package:hermes_android/nextgen/nextgen_l10n.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';

import 'settings_support.dart';

const _activity =
    'android/app/src/main/kotlin/com/hermesagent/hermes_android/MainActivity.kt';

void main() {
  test('MainActivity hosts local_auth and answers openSecuritySettings', () {
    final src = File(_activity).readAsStringSync();
    expect(src, contains('class MainActivity : FlutterFragmentActivity()'));
    expect(src, isNot(contains('FlutterActivity()')));
    expect(src, contains('"${hmSecurityChannel.name}"'));
    expect(src, contains('"openSecuritySettings"'));
    expect(src, contains('Settings.ACTION_SECURITY_SETTINGS'));
  });

  test('main.dart loads settings, gates NextGen and keeps messages', () {
    final src = File('lib/main.dart').readAsStringSync();
    final load = src.indexOf('NextGenPreferences.load(prefs);');
    expect(load, greaterThan(0));
    expect(
      src.indexOf('HmSettingsPrefs.instance.load(prefs);'),
      greaterThan(load),
    );
    expect(
      src,
      matches(
        RegExp(
          r'NgLocalizationScope\(\s*child: HmLockGate\(\s*'
          r'prefs: widget\.connManager\.prefs,\s*child: child!,',
        ),
      ),
    );
    expect(
      src,
      contains('NgChatController.messageCache = const _HmMessageCache();'),
    );
  });

  test('the Dart side reaches the channel MainActivity answers', () async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    final seen = <String>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(hmSecurityChannel, (
      call,
    ) async {
      seen.add(call.method);
      return true;
    });
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        hmSecurityChannel,
        null,
      ),
    );
    expect(await hmOpenAndroidSecuritySettings(), isTrue);
    expect(seen, ['openSecuritySettings']);
  });

  testWidgets('with the lock on, the app opens behind the lock screen', (
    tester,
  ) async {
    final prefs = await freshPrefs(
      values: {HmSettingsPrefs.lockEnabledKey: true},
    );
    HmSettingsPrefs.instance.load(prefs);
    final auth = FakeAuthenticator(result: HmAuthResult.canceled);
    HmAppLock.instance.authenticator = auth;
    await tester.pumpWidget(
      MaterialApp(
        theme: nextGenTheme(Brightness.light, NextGenLook.instance),
        builder: (context, child) => NgLocalizationScope(
          child: HmLockGate(prefs: prefs, child: child!),
        ),
        home: const Scaffold(body: Text('Home')),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Unlock Hermes Agent.'), findsWidgets);
    expect(find.text('Home'), findsNothing);
    expect(auth.reasons, isNotEmpty);

    // A successful prompt lowers it.
    auth.result = HmAuthResult.success;
    await HmAppLock.instance.unlock();
    await tester.pump();
    expect(find.text('Home'), findsOneWidget);
  });
}
