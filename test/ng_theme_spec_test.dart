import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/nextgen/theme/ng_theme_spec.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';

void main() {
  test('every preset round-trips through its own JSON', () {
    for (final t in ngThemePresets) {
      final back = NgThemeSpec.parse(t.encode());
      expect(back.toJson(), t.toJson(), reason: t.id);
    }
  });

  test('a theme overrides only the roles it names', () {
    final theme = NgThemeSpec.parse(
      '{"id":"x","name":"X","dark":{"background":"#102030"}}',
    );
    final base = NgColors.build(Brightness.dark, NgAccent.blue, false, true);
    final c = NgColors.build(Brightness.dark, NgAccent.blue, false, true, theme);
    expect(c.background, const Color(0xFF102030));
    expect(c.text, base.text);
  });

  test('bad theme JSON is rejected with a readable reason', () {
    for (final bad in [
      'nope',
      '{"id":"x","name":"X","dark":{"bogus":"#000000"}}',
      '{"id":"x","name":"X","dark":{"text":"red"}}',
      '{"id":"x","name":"X","dark":{"text":3}}',
    ]) {
      expect(() => NgThemeSpec.parse(bad), throwsFormatException, reason: bad);
    }
  });

  test('the default preset is the monochrome OLED look', () {
    final c = NgColors.build(
      Brightness.dark,
      NgAccent.blue,
      false,
      true,
      ngThemePresets.first,
    );
    expect(c.background, const Color(0xFF000000));
  });
}
