import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Flutter adapter for the pinned ephemeral-ui v0 theme contract.
class GlideTheme extends ThemeExtension<GlideTheme> {
  // Shared preference name used by HA-042; the toggle lives there.
  static const turboPreferenceKey = 'turbo_motion_enabled';
  static const asset = 'assets/shared_ui/glide.json';
  final Map<String, dynamic> _json;

  GlideTheme.parse(String source)
    : _json = jsonDecode(source) as Map<String, dynamic> {
    if (_json['v'] != 0) {
      throw const FormatException('Unsupported Glide theme format');
    }
  }

  static Future<GlideTheme> load([AssetBundle? bundle]) async =>
      GlideTheme.parse(await (bundle ?? rootBundle).loadString(asset));

  String get brandName => _json['brand']['name'] as String;
  String get version => _json['version'] as String;
  Color get brandMark => _hex(_json['brand']['mark'] as String);
  double radius(String role) => (_json['radius'][role] as num).toDouble();

  static Color _hex(String hex) {
    // CSS uses RRGGBBAA, while Flutter uses AARRGGBB.
    final rgb = int.parse(hex.substring(1, 7), radix: 16);
    final alpha = hex.length == 9
        ? int.parse(hex.substring(7), radix: 16)
        : 255;
    return Color((alpha << 24) | rgb);
  }

  Color color(Brightness brightness, String role, {String? fallback}) {
    final palette = _json['color'][brightness.name] as Map<String, dynamic>;
    return _hex((palette[role] ?? palette[fallback]) as String);
  }

  ColorScheme colorScheme(ColorScheme base, {required bool sharedAccent}) {
    Color c(String role) => color(base.brightness, role);
    final error = color(base.brightness, 'dangerFg', fallback: 'danger');
    return base.copyWith(
      primary: sharedAccent ? c('primary') : base.primary,
      onPrimary: sharedAccent ? c('primaryFg') : base.onPrimary,
      primaryContainer: sharedAccent ? c('accent') : base.primaryContainer,
      onPrimaryContainer: sharedAccent ? c('fg') : base.onPrimaryContainer,
      secondary: sharedAccent ? c('primary') : base.secondary,
      onSecondary: sharedAccent ? c('primaryFg') : base.onSecondary,
      secondaryContainer: sharedAccent ? c('accent') : base.secondaryContainer,
      onSecondaryContainer: sharedAccent ? c('fg') : base.onSecondaryContainer,
      surface: c('bg'),
      onSurface: c('fg'),
      surfaceContainerLowest: c('bg'),
      surfaceContainerLow: c('card'),
      surfaceContainer: c('muted'),
      surfaceContainerHigh: c('accent'),
      surfaceContainerHighest: c('accent'),
      onSurfaceVariant: c('mutedFg'),
      outline: c('input'),
      outlineVariant: c('border'),
      error: error,
      onError: error.computeLuminance() > 0.179
          ? const Color(0xFF000000)
          : const Color(0xFFFFFFFF),
    );
  }

  TextStyle textStyle(TextStyle base, {String? size, String? tracking}) {
    final type = _json['type'];
    final fontSize = (type['size'][size] ?? type['base']['size']) as num;
    final trackingToken = type['tracking'][tracking] as String?;
    final em = trackingToken == null
        ? 0.0
        : double.parse(trackingToken.replaceFirst('em', ''));
    // The web stack is CSS syntax; use Flutter's platform sans face.
    return base.copyWith(
      fontFamily: 'sans-serif',
      fontSize: fontSize.toDouble(),
      height: (type['base']['lineHeight'] as num).toDouble(),
      letterSpacing: em * fontSize,
    );
  }

  TextTheme textTheme(TextTheme base) => base.copyWith(
    displaySmall: textStyle(
      base.displaySmall!,
      size: 'display',
      tracking: 'display',
    ),
    headlineSmall: textStyle(
      base.headlineSmall!,
      size: 'title',
      tracking: 'tight',
    ),
    titleLarge: textStyle(base.titleLarge!, size: 'title', tracking: 'tight'),
    titleMedium: textStyle(base.titleMedium!, size: 'name', tracking: 'tight'),
    titleSmall: textStyle(base.titleSmall!, size: 'lead'),
    bodyLarge: textStyle(base.bodyLarge!),
    bodyMedium: textStyle(base.bodyMedium!, size: 'body'),
    bodySmall: textStyle(base.bodySmall!, size: 'small'),
    labelLarge: textStyle(base.labelLarge!, size: 'body'),
    labelMedium: textStyle(base.labelMedium!, size: 'meta'),
    labelSmall: textStyle(base.labelSmall!, size: 'label', tracking: 'caps'),
  );

  double _speed(String role) =>
      (_json['motion']['speed'][role] as num).toDouble();
  double get defaultSpeed => _speed('default');
  double get turboFactor => _speed('turbo');

  /// Shared with HA-042: speed is a multiplier, not a second duration table.
  Duration duration(
    String role, {
    double? speed,
    bool turbo = false,
    bool reduceMotion = false,
  }) {
    if (reduceMotion && _json['motion']['reducedMotion'] == 'zero') {
      return Duration.zero;
    }
    final factor = turbo
        ? turboFactor
        : (speed ?? defaultSpeed).clamp(_speed('min'), _speed('max'));
    final ms = _json['motion']['duration'][role] as num;
    return Duration(microseconds: (ms * 1000 / factor).round());
  }

  ({double blur, double saturation, double? tint}) glass(String role) {
    final spec =
        (_json['glass'][role] ?? _json['glass']['none'])
            as Map<String, dynamic>;
    final tint = spec['tint'] as num?;
    return (
      blur: (spec['blur'] as num).toDouble(),
      saturation: (spec['saturate'] as num) / 100,
      tint: tint == null ? null : tint / 100,
    );
  }

  @override
  GlideTheme copyWith() => this;

  @override
  GlideTheme lerp(covariant GlideTheme? other, double t) =>
      t < 0.5 ? this : other ?? this;
}
