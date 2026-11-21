// Shared fakes for the settings_* tests.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/features/settings/app_lock.dart';
import 'package:hermes_android/hm/features/settings/settings_prefs.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _RejectingStore extends InMemorySharedPreferencesStore {
  _RejectingStore() : super.empty();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}

/// Fresh preferences; [failWrites] makes every write report failure.
Future<SharedPreferences> freshPrefs({
  Map<String, Object> values = const {},
  bool failWrites = false,
}) async {
  SharedPreferences.setMockInitialValues(values);
  if (failWrites) SharedPreferencesStorePlatform.instance = _RejectingStore();
  return SharedPreferences.getInstance();
}

Future<HmSettingsPrefs> loadedSettings({
  Map<String, Object> values = const {},
  bool failWrites = false,
}) async {
  final prefs = await freshPrefs(values: values, failWrites: failWrites);
  return HmSettingsPrefs()..load(prefs);
}

Widget hmTestApp(Widget home) => MaterialApp(
  theme: nextGenTheme(Brightness.light, NextGenLook.instance),
  home: home,
);

class FakeAuthenticator implements HmAuthenticator {
  FakeAuthenticator({
    this.cap = const HmLockCapability(HmLockSupport.available),
    this.result = HmAuthResult.success,
  });

  HmLockCapability cap;
  HmAuthResult result;
  Completer<HmLockCapability>? pendingCapability;
  final List<String> reasons = [];

  @override
  Future<HmLockCapability> capability() =>
      pendingCapability?.future ?? Future.value(cap);

  @override
  Future<HmAuthResult> authenticate(String reason) async {
    reasons.add(reason);
    return result;
  }
}

/// A phone-shaped test view (1080x2340 at 3x), reset after the test.
void phoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}
