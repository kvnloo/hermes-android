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
