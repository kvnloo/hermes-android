import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/features/settings/app_lock.dart';
import 'package:hermes_android/hm/features/settings/security_screen.dart';
import 'package:hermes_android/hm/features/settings/settings_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings_support.dart';

void main() {
  group('Security page', () {
    testWidgets('loaded: turning the lock on asks first, then persists', (
      tester,
    ) async {
      final settings = await loadedSettings();
      phoneSize(tester);
      final auth = FakeAuthenticator();
      final lock = HmAppLock(prefs: settings, authenticator: auth);
      await tester.pumpWidget(hmTestApp(HmSecurityScreen(lock: lock)));
      await tester.pump();

      expect(find.text('Security'), findsOneWidget);
      expect(find.text('Require Screen Lock'), findsOneWidget);
      expect(find.text('Asked for when the app opens.'), findsOneWidget);
      expect(find.text('Open Security Settings'), findsNothing);
      expect(find.text('Grace Period'), findsNothing);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(auth.reasons, ['Turn on the lock for Hermes Agent.']);
      expect(settings.lockEnabled, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(HmSettingsPrefs.lockEnabledKey), isTrue);
      // The lock isn't put up by turning it on.
      expect(lock.locked, isFalse);

      // Grace period and Lock Now appear once it's on.
      expect(find.text('Grace Period'), findsOneWidget);
      expect(
        find.text('Asks again every time the app leaves the foreground.'),
        findsOneWidget,
      );
      await tester.tap(find.text('After 5 minutes'));
      await tester.pumpAndSettle();
      expect(settings.lockGrace, HmLockGrace.fiveMinutes);
      expect(prefs.getString(HmSettingsPrefs.lockGraceKey), 'fiveMinutes');

      await tester.scrollUntilVisible(find.text('Lock Now'), 200);
      await tester.ensureVisible(find.text('Lock Now'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lock Now'));
      await tester.pump();
      expect(lock.locked, isTrue);
    });

    testWidgets('face-only devices name Face Unlock', (tester) async {
      final settings = await loadedSettings();
      final auth = FakeAuthenticator(
        cap: const HmLockCapability(HmLockSupport.available, face: true),
      );
      await tester.pumpWidget(
        hmTestApp(
          HmSecurityScreen(
            lock: HmAppLock(prefs: settings, authenticator: auth),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Require Face Unlock'), findsOneWidget);
    });

    testWidgets('empty: no screen lock shows the official notice', (
      tester,
    ) async {
      final settings = await loadedSettings();
      final auth = FakeAuthenticator(
        cap: const HmLockCapability(HmLockSupport.none),
      );
      var opened = 0;
      await tester.pumpWidget(
        hmTestApp(
          HmSecurityScreen(
            lock: HmAppLock(prefs: settings, authenticator: auth),
            openSecuritySettings: () async {
              opened++;
              return true;
            },
          ),
        ),
      );
      await tester.pump();

      expect(
        find.text(
          'This device has no screen lock or biometrics set up. Add one in Android Settings to use the lock.',
        ),
        findsOneWidget,
      );
      final sw = tester.widget<Switch>(find.byType(Switch));
      expect(sw.onChanged, isNull);
      await tester.tap(find.text('Open Security Settings'));
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('loading: the switch waits for the device check', (
      tester,
    ) async {
      final settings = await loadedSettings();
      final auth = FakeAuthenticator()
        ..pendingCapability = Completer<HmLockCapability>();
      await tester.pumpWidget(
        hmTestApp(
          HmSecurityScreen(
            lock: HmAppLock(prefs: settings, authenticator: auth),
          ),
        ),
      );
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
      auth.pendingCapability!.complete(
        const HmLockCapability(HmLockSupport.available),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);
    });

    testWidgets('error: a lockout leaves the lock off and says why', (
      tester,
    ) async {
      final settings = await loadedSettings();
      final auth = FakeAuthenticator(result: HmAuthResult.lockedOut);
      await tester.pumpWidget(
        hmTestApp(
          HmSecurityScreen(
            lock: HmAppLock(prefs: settings, authenticator: auth),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(settings.lockEnabled, isFalse);
      expect(
        find.text('Too many attempts. Use the device screen lock to continue.'),
        findsOneWidget,
      );
    });

    testWidgets('error: a failed save rolls back and says so', (tester) async {
      final settings = await loadedSettings(failWrites: true);
      await tester.pumpWidget(
        hmTestApp(
          HmSecurityScreen(
            lock: HmAppLock(
              prefs: settings,
              authenticator: FakeAuthenticator(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(settings.lockEnabled, isFalse);
      expect(find.text("Couldn't save the lock setting."), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    });
  });

  group('App lock', () {
    test('locks on launch when on, and after the grace period', () async {
      final settings = await loadedSettings(
        values: {
          HmSettingsPrefs.lockEnabledKey: true,
          HmSettingsPrefs.lockGraceKey: 'oneMinute',
        },
      );
      var now = DateTime(2026, 11, 20, 9);
      final auth = FakeAuthenticator();
      final lock = HmAppLock(
        prefs: settings,
        authenticator: auth,
        clock: () => now,
      );
      lock.start();
      expect(lock.locked, isTrue);
      expect(await lock.unlock(), HmAuthResult.success);
      expect(auth.reasons.last, 'Unlock Hermes Agent.');
      expect(lock.locked, isFalse);

      // Back within the grace period: still open.
      lock.left();
      now = now.add(const Duration(seconds: 30));
      lock.returned();
      expect(lock.locked, isFalse);

      // Away longer than the grace period: locked.
      lock.left();
      now = now.add(const Duration(minutes: 2));
      lock.returned();
      expect(lock.locked, isTrue);
    });

    test('Immediately covers the app as soon as it leaves', () async {
      final settings = await loadedSettings(
        values: {HmSettingsPrefs.lockEnabledKey: true},
      );
      final lock = HmAppLock(
        prefs: settings,
        authenticator: FakeAuthenticator(),
      );
      lock.left();
      expect(lock.locked, isTrue);
    });

    test('nothing locks while the lock is off', () async {
      final settings = await loadedSettings();
      final lock = HmAppLock(
        prefs: settings,
        authenticator: FakeAuthenticator(),
      );
      lock
        ..start()
        ..left()
        ..returned()
        ..lockNow();
      expect(lock.locked, isFalse);
    });

    testWidgets('the gate hides the app until unlocked', (tester) async {
      final settings = await loadedSettings(
        values: {HmSettingsPrefs.lockEnabledKey: true},
      );
      final auth = FakeAuthenticator(result: HmAuthResult.canceled);
      final lock = HmAppLock(prefs: settings, authenticator: auth);
      await tester.pumpWidget(
        hmTestApp(
          HmLockGate(lock: lock, child: const Text('secret chats')),
        ),
      );
      await tester.pump();

      expect(find.text('Unlock Hermes Agent.'), findsOneWidget);
      expect(find.text('secret chats'), findsNothing);
      // It asked on its own once.
      expect(auth.reasons, ['Unlock Hermes Agent.']);

      auth.result = HmAuthResult.success;
      await tester.tap(find.byKey(const ValueKey('hm-unlock')));
      await tester.pump();
      expect(find.text('secret chats'), findsOneWidget);
      expect(find.text('Unlock Hermes Agent.'), findsNothing);

      // Leaving the app (Immediately) puts it back up.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(find.text('secret chats'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(auth.reasons.length, 3);
      expect(find.text('secret chats'), findsOneWidget);
    });
  });
}
