import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/hermes_theme.dart';
import 'ephemeral_service_accents.dart';

enum EphemeralCardStyle { appTheme, serviceNative }

/// A device preference shared by chat, live and the gallery.
final ephemeralCardStyle = ValueNotifier(EphemeralCardStyle.appTheme);

abstract final class EphemeralCardPreferences {
  static const key = 'ephemeral_card_style';

  static void load(SharedPreferences prefs) {
    ephemeralCardStyle.value =
        prefs.get(key) == EphemeralCardStyle.serviceNative.name
        ? EphemeralCardStyle.serviceNative
        : EphemeralCardStyle.appTheme;
  }

  static Future<void> set(
    SharedPreferences prefs,
    EphemeralCardStyle style,
  ) async {
    ephemeralCardStyle.value = style;
    await prefs.setString(key, style.name);
  }
}

/// Original-service-inspired chrome, recreated with native Flutter widgets.
/// Unprofiled services use a neutral card, not the active app's accent.
typedef ServiceCardPalette = ({
  int surface,
  int raised,
  int border,
  int ink,
  int muted,
  int accent,
  double radius,
  IconData? icon,
});

ServiceCardPalette serviceCardPalette(String? app, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final palette = switch ((app, dark)) {
    ('gmail', true) => (
      surface: 0xff1f1f1f,
      raised: 0xff2d2f31,
      border: 0xff444746,
      ink: 0xffe3e3e3,
      muted: 0xffc4c7c5,
      accent: 0xffa8c7fa,
      radius: 20,
      icon: Icons.mail_outline,
    ),
    ('gmail', false) => (
      surface: 0xfff8fafd,
      raised: 0xffeaf1fb,
      border: 0xffc4c7c5,
      ink: 0xff1f1f1f,
      muted: 0xff444746,
      accent: 0xff0b57d0,
      radius: 20,
      icon: Icons.mail_outline,
    ),
    ('github' || 'github-actions', true) => (
      surface: 0xff0d1117,
      raised: 0xff161b22,
      border: 0xff30363d,
      ink: 0xfff0f6fc,
      muted: 0xff9198a1,
      accent: 0xff58a6ff,
      radius: 8,
      icon: Icons.fork_right,
    ),
    ('github' || 'github-actions', false) => (
      surface: 0xffffffff,
      raised: 0xfff6f8fa,
      border: 0xffd0d7de,
      ink: 0xff1f2328,
      muted: 0xff57606a,
      accent: 0xff0969da,
      radius: 8,
      icon: Icons.fork_right,
    ),
    ('stripe', true) => (
      surface: 0xff191d30,
      raised: 0xff22263c,
      border: 0xff3c4260,
      ink: 0xfff3f1ff,
      muted: 0xffb9bfdb,
      accent: 0xffb9a7ff,
      radius: 12,
      icon: Icons.receipt_long_outlined,
    ),
    ('stripe', false) => (
      surface: 0xffffffff,
      raised: 0xfff3f0ff,
      border: 0xffdcd8ee,
      ink: 0xff171c37,
      muted: 0xff4c5371,
      accent: 0xff5542d4,
      radius: 12,
      icon: Icons.receipt_long_outlined,
    ),
    ('spotify', _) => (
      surface: 0xff121212,
      raised: 0xff202020,
      border: 0xff454545,
      ink: 0xffffffff,
      muted: 0xffb3b3b3,
      accent: 0xff1ed760,
      radius: 12,
      icon: Icons.graphic_eq,
    ),
    (_, true) => (
      surface: 0xff20252d,
      raised: 0xff2b323d,
      border: 0xff495461,
      ink: 0xfff4f7fb,
      muted: 0xffbac6d4,
      accent: 0xffa8ceff,
      radius: 10,
      icon: null,
    ),
    (_, false) => (
      surface: 0xfff9fafc,
      raised: 0xffeef1f5,
      border: 0xffc4ccd6,
      ink: 0xff171e28,
      muted: 0xff505c6b,
      accent: 0xff28548b,
      radius: 10,
      icon: null,
    ),
  };
  final brand = ephemeralServiceAccents[app];
  if (palette.icon != null || brand == null) return palette;
  final ink = Color(palette.ink);
  final surface = Color(palette.surface);
  final tint = Color(brand);
  var readable = tint;
  while (_contrast(readable, surface) < 5 ||
      _contrast(readable, Color(palette.raised)) < 4.5) {
    readable = Color.lerp(readable, ink, 0.2)!;
  }
  return (
    surface: palette.surface,
    raised: palette.raised,
    border: palette.border,
    ink: palette.ink,
    muted: palette.muted,
    accent: readable.toARGB32(),
    radius: palette.radius,
    icon: null,
  );
}

double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return x > y ? (x + 0.05) / (y + 0.05) : (y + 0.05) / (x + 0.05);
}

HermesTokens serviceCardTokens(ServiceCardPalette palette) {
  final surface = Color(palette.surface);
  final brightness = ThemeData.estimateBrightnessForColor(surface);
  final base = HermesTokens.forBrightness(brightness);
  final ramp = base.typography;
  TextStyle sans(TextStyle style) =>
      style.copyWith(fontFamily: 'Roboto', letterSpacing: 0);
  return base.copyWith(
    surface: surface,
    raised: Color(palette.raised),
    border: Color(palette.border),
    onSurface: Color(palette.ink),
    muted: Color(palette.muted),
    accent: Color(palette.accent),
    accentContainer: Color(palette.raised),
    onAccentContainer: Color(palette.accent),
    typography: HermesTypography(
      display: sans(ramp.display),
      title: sans(ramp.title),
      section: sans(ramp.section),
      body: sans(ramp.body).copyWith(fontSize: 14, height: 1.35),
      label: sans(ramp.label).copyWith(fontSize: 12, height: 1.3),
      mono: ramp.mono,
    ),
  );
}
