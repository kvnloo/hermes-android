// Settings → Device access is a Flutter page: it follows the active app theme
// (light and dark, including the Glide palette) and leads with the shared
// back bar, while the five sources keep their copy and order.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/hm/features/settings/device_access_screen.dart';
import 'package:hermes_android/hm/features/settings/settings_prefs.dart';
import 'package:hermes_android/hm/hm_bots.dart';
import 'package:hermes_android/hm/screens/hm_settings_screen.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/nextgen/ui/nextgen_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/hm/hm_ui.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/shared_ui/glide_theme.dart';

import 'settings_support.dart';

const _labels = {
  'HEALTH': 'Health Connect steps',
  'CALENDAR': 'Calendar',
  'CONTACTS': 'Contacts',
  'LOCATION': 'Approximate location',
  'ALARM': 'Exact alarms',
};

/// Mirrors DeviceAccessSettings: off by default, "denied" once turned on.
class _FakeBackend extends HmDeviceAccessBackend {
  _FakeBackend({this.requestOk = true});

  final bool requestOk;
  final enabled = <String>{};
  final granted = <String>{};
  final requests = <String>[];

  @override
  Future<List<HmDeviceSource>> states() async => [
    for (final e in _labels.entries)
      HmDeviceSource(
        id: e.key,
        label: e.value,
        enabled: enabled.contains(e.key),
        state: !enabled.contains(e.key)
            ? 'Off'
            : granted.contains(e.key)
            ? 'Permission granted'
            : 'Permission denied or not yet granted',
        canRequest: enabled.contains(e.key) && !granted.contains(e.key),
      ),
  ];

  @override
  Future<void> setEnabled(String source, bool on) async =>
      on ? enabled.add(source) : enabled.remove(source);

  @override
  Future<bool> request(String source) async {
    requests.add(source);
    return requestOk;
  }
}

GlideTheme _glide() =>
    GlideTheme.parse(File(GlideTheme.asset).readAsStringSync());

ThemeData _theme(Brightness b) =>
    nextGenTheme(b, NextGenLook.instance, glide: _glide());

/// Settings-like home with one row that pushes the Device access page.
Widget _app(Brightness brightness, HmDeviceAccessBackend backend) =>
    MaterialApp(
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => HmDeviceAccessScreen(backend: backend),
                ),
              ),
              child: const Text('Open device access'),
            ),
          ),
        ),
      ),
    );

Future<void> _open(WidgetTester tester, Brightness b, _FakeBackend fake) async {
  phoneSize(tester);
  await tester.pumpWidget(_app(b, fake));
  await tester.tap(find.text('Open device access'));
  await tester.pumpAndSettle();
}

void main() {
  for (final brightness in Brightness.values) {
    group('Device access (${brightness.name})', () {
      testWidgets('the back button returns to Settings', (tester) async {
        await _open(tester, brightness, _FakeBackend());
        expect(find.byType(HmDeviceAccessScreen), findsOneWidget);
        expect(find.byType(HmBackButton), findsOneWidget);

        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(find.byType(HmDeviceAccessScreen), findsNothing);
        expect(find.text('Open device access'), findsOneWidget);
      });

      testWidgets('system back also returns to Settings', (tester) async {
        await _open(tester, brightness, _FakeBackend());
        final handled = await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(handled, isTrue);
        expect(find.byType(HmDeviceAccessScreen), findsNothing);
      });

      testWidgets('paints with the active theme colours', (tester) async {
        await _open(tester, brightness, _FakeBackend());
        final context = tester.element(find.byType(HmDeviceAccessScreen));
        final theme = Theme.of(context);
        final c = NgColors.of(context);
        expect(theme.brightness, brightness);

        final scaffold = tester.widget<Scaffold>(
          find.descendant(
            of: find.byType(HmDeviceAccessScreen),
            matching: find.byType(Scaffold),
          ),
        );
        expect(scaffold.backgroundColor, c.background);
        expect(
          c.background,
          _glide().color(brightness, 'bg'),
          reason: 'the page canvas is the Glide background',
        );
        final title = tester.widget<Text>(find.text('Device access'));
        expect(title.style?.color, c.text);
        // Light text on a dark canvas and the reverse: never the old white page.
        final dark = brightness == Brightness.dark;
        expect(c.background.computeLuminance() < 0.2, dark);
        expect(c.text.computeLuminance() > 0.5, dark);
      });

      testWidgets('golden', (tester) async {
        final fake = _FakeBackend()..enabled.add('CONTACTS');
        await _open(tester, brightness, fake);
        await expectLater(
          find.byType(HmDeviceAccessScreen),
          matchesGoldenFile('goldens/device_access_${brightness.name}.png'),
        );
      });
    });
  }

  testWidgets('Settings opens Device access in-app, and back returns', (
    tester,
  ) async {
    phoneSize(tester);
    HmSettingsPrefs.instance.load(await freshPrefs());
    final prefs = await SharedPreferences.getInstance();
    final conn = SavedConnection(
      id: 'c1',
      label: 'Home',
      host: 'example.invalid',
      port: 9119,
      apiKey: '',
      desktopGatewayUrl: 'http://example.invalid:9119',
      singleLogin: true,
      signInMethod: 'none',
    );
    final gateway = NextGenGateway(conn);
    final bots = HmBotsModel(gateway);
    addTearDown(bots.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(Brightness.dark),
        home: NgScope(
          connManager: ConnectionManager(prefs),
          gateway: gateway,
          connections: [conn],
          switchTo: (_) async {},
          addGateway: () async {},
          signOut: (_) async {},
          reload: () async {},
          signInAgain: () async {},
          child: HmSettingsScreen(bots: bots),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Device access'));
    await tester.pumpAndSettle();
    expect(find.byType(HmDeviceAccessScreen), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(HmDeviceAccessScreen), findsNothing);
    expect(find.byType(HmSettingsScreen), findsOneWidget);
  });

  group('Device access content', () {
    testWidgets('keeps the native copy and source order', (tester) async {
      await _open(tester, Brightness.dark, _FakeBackend());
      expect(find.text('Device access'), findsOneWidget);
      expect(
        find.text(
          'Sources are off by default. '
          'This build does not send device data to a host.',
        ),
        findsOneWidget,
      );
      final rows = tester
          .widgetList<HmSwitchRow>(find.byType(HmSwitchRow))
          .map((r) => r.label)
          .toList();
      expect(rows, [
        'Health Connect steps · Off',
        'Calendar · Off',
        'Contacts · Off',
        'Approximate location · Off',
        'Exact alarms · Off',
      ]);
      expect(find.textContaining('Grant or manage'), findsNothing);
    });

    testWidgets('turning a source on shows its grant action under it', (
      tester,
    ) async {
      final fake = _FakeBackend();
      await _open(tester, Brightness.light, fake);
      await tester.tap(find.byType(Switch).at(1));
      await tester.pumpAndSettle();
      expect(fake.enabled, {'CALENDAR'});
      expect(
        find.text('Calendar · Permission denied or not yet granted'),
        findsOneWidget,
      );
      final labels = tester
          .widgetList<HmRow>(find.byType(HmRow))
          .map((r) => r.label)
          .toList();
      final i = labels.indexOf(
        'Calendar · Permission denied or not yet granted',
      );
      expect(labels[i + 1], 'Grant or manage Calendar permission');

      await tester.tap(find.text('Grant or manage Calendar permission'));
      await tester.pumpAndSettle();
      expect(fake.requests, ['CALENDAR']);
    });

    testWidgets('a failed request says so', (tester) async {
      final fake = _FakeBackend(requestOk: false)..enabled.add('ALARM');
      await _open(tester, Brightness.light, fake);
      await tester.tap(find.text('Grant or manage Exact alarms permission'));
      await tester.pumpAndSettle();
      expect(find.text('Permission settings are unavailable.'), findsOneWidget);
    });

    testWidgets('reads and writes through the native channel', (tester) async {
      final calls = <MethodCall>[];
      var calendarOn = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        HmDeviceAccessBackend.channel,
        (call) async {
          calls.add(call);
          switch (call.method) {
            case 'states':
              return [
                for (final e in _labels.entries)
                  {
                    'source': e.key,
                    'label': e.value,
                    'enabled': e.key == 'CALENDAR' && calendarOn,
                    'state': e.key == 'CALENDAR' && calendarOn
                        ? 'Permission granted'
                        : 'Off',
                    'canRequest': false,
                  },
              ];
            case 'setEnabled':
              calendarOn = (call.arguments as Map)['enabled'] as bool;
              return null;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          HmDeviceAccessBackend.channel,
          null,
        ),
      );
      phoneSize(tester);
      await tester.pumpWidget(hmTestApp(const HmDeviceAccessScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Calendar · Off'), findsOneWidget);
      await tester.tap(find.byType(Switch).at(1));
      await tester.pumpAndSettle();
      expect(find.text('Calendar · Permission granted'), findsOneWidget);
      expect(calls.map((c) => c.method), ['states', 'setEnabled', 'states']);
      expect(calls[1].arguments, {'source': 'CALENDAR', 'enabled': true});
    });

    testWidgets('a failing native backend reads as unavailable', (
      tester,
    ) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        HmDeviceAccessBackend.channel,
        (call) async => throw PlatformException(code: 'unavailable'),
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          HmDeviceAccessBackend.channel,
          null,
        ),
      );
      phoneSize(tester);
      await tester.pumpWidget(hmTestApp(const HmDeviceAccessScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Device access is unavailable.'), findsOneWidget);
    });
  });
}
