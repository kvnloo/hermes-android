// The NextGen theme engine. A theme is data: per-brightness colour tokens
// applied over NextGen's base roles. Built-in presets and themes a user
// imports as JSON go through the same parser, so a preset is just a theme
// that ships with the app.
import 'dart:convert';

import 'package:flutter/material.dart';

/// Every colour role a theme may set. Matches the fields of `NgColors`.
const ngThemeTokens = <String>{
  'background', 'surface', 'surface2', 'surface3', 'well', 'thumb', 'sheet',
  'input', 'sidebar', 'userBubble', 'onUserBubble', 'text', 'text2', 'text3',
  'textMuted', 'accent', 'onAccent', 'accentText', 'accentSoft', 'inverse',
  'onInverse', 'stroke', 'strokeStrong', 'danger', 'success', 'warning',
  'dangerSoft', 'successSoft', 'warningSoft',
};

/// Parses `#RRGGBB` or `#RRGGBBAA` (CSS order).
Color ngParseHex(String value) {
  final m = RegExp(r'^#([0-9a-fA-F]{6})([0-9a-fA-F]{2})?$').firstMatch(value);
  if (m == null) throw FormatException('Not a #RRGGBB[AA] colour: $value');
  final rgb = int.parse(m.group(1)!, radix: 16);
  final a = m.group(2) == null ? 0xFF : int.parse(m.group(2)!, radix: 16);
  return Color((a << 24) | rgb);
}

String ngHex(Color c) {
  String h(double v) => (v * 255).round().toRadixString(16).padLeft(2, '0');
  final rgba = '#${h(c.r)}${h(c.g)}${h(c.b)}';
  return c.a >= 1 ? rgba.toUpperCase() : '$rgba${h(c.a)}'.toUpperCase();
}

@immutable
class NgThemeSpec {
  const NgThemeSpec({
    required this.id,
    required this.name,
    this.dark = const {},
    this.light = const {},
    this.glow,
  });

  final String id;
  final String name;
  final Map<String, Color> dark;
  final Map<String, Color> light;

  /// Forces the top glow on or off; null leaves the user's switch in charge.
  final bool? glow;

  Map<String, Color> tokensFor(Brightness b) =>
      b == Brightness.dark ? dark : light;

  /// Whether the theme picks its own accent, so the accent swatches don't apply.
  bool get ownsAccent => dark.containsKey('accent') || light.containsKey('accent');

  /// Strict: unknown tokens, bad colours and missing names are errors, so an
  /// import never half-applies.
  factory NgThemeSpec.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('A theme is a JSON object');
    final name = json['name'];
    if (name is! String || name.trim().isEmpty) {
      throw const FormatException('A theme needs a "name"');
    }
    Map<String, Color> tokens(String key) {
      final raw = json[key];
      if (raw == null) return const {};
      if (raw is! Map) throw FormatException('"$key" must be an object');
      final out = <String, Color>{};
      for (final e in raw.entries) {
        if (!ngThemeTokens.contains(e.key)) {
          throw FormatException('Unknown colour role "${e.key}"');
        }
        if (e.value is! String) {
          throw FormatException('"${e.key}" must be a hex string');
        }
        out[e.key as String] = ngParseHex(e.value as String);
      }
      return out;
    }

    final glow = json['glow'];
    if (glow != null && glow is! bool) {
      throw const FormatException('"glow" must be true or false');
    }
    final id = json['id'];
    return NgThemeSpec(
      id: id is String && id.isNotEmpty ? id : 'custom',
      name: name.trim(),
      dark: tokens('dark'),
      light: tokens('light'),
      glow: glow as bool?,
    );
  }

  static NgThemeSpec parse(String source) =>
      NgThemeSpec.fromJson(jsonDecode(source));

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (glow != null) 'glow': glow,
    'dark': {for (final e in dark.entries) e.key: ngHex(e.value)},
    'light': {for (final e in light.entries) e.key: ngHex(e.value)},
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}

/// The themes that ship with the app. The first is the default.
final ngThemePresets = <NgThemeSpec>[
  // Monochrome OLED chat: true black, white ink, neutral bubbles and a white
  // send button, no coloured glow.
  NgThemeSpec.fromJson({
    'id': 'onyx',
    'name': 'Onyx',
    'glow': false,
    'dark': {
      'background': '#000000', 'surface': '#0F0F0F', 'surface2': '#1A1A1A',
      'surface3': '#242424', 'well': '#0A0A0A', 'thumb': '#2E2E2E',
      'sheet': '#141414', 'input': '#141414', 'sidebar': '#0A0A0A',
      'userBubble': '#242424', 'onUserBubble': '#FFFFFF', 'text': '#FFFFFF',
      'text2': '#D6D6D6', 'text3': '#8C8C8C', 'textMuted': '#666666',
      'accent': '#FFFFFF', 'onAccent': '#000000', 'accentText': '#FFFFFF',
      'accentSoft': '#FFFFFF1F', 'stroke': '#FFFFFF14',
      'strokeStrong': '#FFFFFF26',
    },
    'light': {
      'background': '#FFFFFF', 'surface': '#F7F7F7', 'surface2': '#F0F0F0',
      'surface3': '#E6E6E6', 'well': '#F5F5F5', 'sheet': '#FFFFFF',
      'input': '#F4F4F4', 'sidebar': '#FAFAFA', 'userBubble': '#F0F0F0',
      'onUserBubble': '#0A0A0A', 'text': '#0A0A0A', 'text2': '#2A2A2A',
      'text3': '#6E6E6E', 'textMuted': '#9A9A9A', 'accent': '#0A0A0A',
      'onAccent': '#FFFFFF', 'accentText': '#0A0A0A', 'accentSoft': '#0A0A0A14',
    },
  }),
  // NextGen's original graphite look; accent comes from the swatches.
  const NgThemeSpec(id: 'graphite', name: 'Graphite'),
  // Dash's tokens (kvnloo/dash DESIGN.md): OLED black, cream ink, gold accent.
  NgThemeSpec.fromJson({
    'id': 'dash',
    'name': 'Dash Gold',
    'dark': {
      'background': '#000000', 'surface': '#121212', 'surface2': '#1C1C1C',
      'surface3': '#262626', 'sheet': '#121212', 'input': '#121212',
      'sidebar': '#000000', 'userBubble': '#1F1F1F', 'onUserBubble': '#ECE8DF',
      'text': '#F2F2F2', 'text2': '#B4AFA3', 'text3': '#8B8B8B',
      'textMuted': '#5A5A5A', 'accent': '#E6CD96', 'onAccent': '#000000',
      'accentText': '#E6CD96', 'accentSoft': '#E6CD9624',
      'stroke': '#ECE8DF1A', 'strokeStrong': '#ECE8DF29', 'danger': '#FF6B6B',
      'success': '#34C759', 'warning': '#FFB020',
    },
    'light': {
      'accent': '#7A5C14', 'onAccent': '#FFFFFF', 'accentText': '#7A5C14',
      'accentSoft': '#7A5C141A', 'userBubble': '#7A5C14',
      'onUserBubble': '#FFFFFF',
    },
  }),
];

NgThemeSpec ngPresetById(String? id) => ngThemePresets.firstWhere(
  (t) => t.id == id,
  orElse: () => ngThemePresets.first,
);
