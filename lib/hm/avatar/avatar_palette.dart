import 'package:flutter/material.dart';

/// Bot identity and animation colours, independent of the surrounding UI theme.
abstract final class AvatarPalette {
  static const bodyTones = [
    Color(0xFF2F4BD8),
    Color(0xFF7A3FD1),
    Color(0xFF0F8A7E),
    Color(0xFFD2552B),
    Color(0xFF6E8A1E),
    Color(0xFFC2357A),
    Color(0xFF3D6C9E),
    Color(0xFF8A5A2B),
  ];
  static const eye = Color(0xFFF6F1E6);
  static const thinking = Color(0xFFFFB020);
  static const active = Color(0xFFD8FF65);
  static const error = Color(0xFFE5522D);
  static const inactive = Colors.transparent;

  /// Council seat inks by mineral name: each tints one seat's thinking orb.
  static const councilMinerals = <String, Color>{
    'citrine': Color(0xFFDC9A32),
    'rose': Color(0xFFD99A9C),
    'smoky': Color(0xFF8B735B),
    'clear': Color(0xFFC9D2D0),
    'malachite': Color(0xFF2F8A5C),
    'labradorite': Color(0xFF4FA8D8),
    'moonstone': Color(0xFF8FB8FF),
    'lapis': Color(0xFF3D62C9),
  };

  /// The council's own orb, which reads the brief and the verdict: brass.
  static const councilBrass = Color(0xFFD7B986);

  static Color? parseBodyTone(Object? value) =>
      value is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)
      ? Color(0xFF000000 | int.parse(value.substring(1), radix: 16))
      : null;

  /// The same grayscale ramp, optionally tinted with a bot's body tone.
  static Color orbInk(double white, double alpha, bool dark, Color? tint) {
    final w = white.clamp(0.0, 1.0);
    if (tint == null) {
      final g = ((dark ? 1 - w : w) * 255).round();
      return Color.fromRGBO(g, g, g, alpha);
    }
    int ramp(double c) => (dark ? c * (1 - w) : c + (255 - c) * w).round();
    return Color.fromRGBO(
      ramp(tint.r * 255),
      ramp(tint.g * 255),
      ramp(tint.b * 255),
      alpha,
    );
  }
}
