/// Surface personalization: how Hermes sits on the phone.
///
/// Extends the existing theme engine (palette + mode in [HermesTokens]) with a
/// second axis, the *surface*. Solid is today's opaque app. Glass makes the
/// window transparent so the Android wallpaper (live wallpapers included)
/// shows through, blurred by the compositor, under one contrast-checked tint.
/// Elemental materials and quiet chrome are personalizations layered on Glass.
///
/// Pure: no widgets, no platform channels, no storage.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'hermes_theme.dart';

enum HermesSurfaceMode { solid, glass }

/// Starting points for the tint/blur pair. Persist [name], never [index].
enum HermesGlassPreset {
  /// Barely there: the wallpaper reads clearly, text keeps AA on mid tones.
  clear(blur: 16),

  /// Default: AA body text even over a white highlight in the wallpaper.
  frost(blur: 32),

  /// Calm reading: wallpaper becomes colour and light, not detail.
  deep(blur: 48);

  const HermesGlassPreset({required this.blur});

  final double blur;
}

/// How an Elemental material is drawn by `shaders/elemental_glass.frag`.
enum HermesMaterialKind { pack, water, quartz }

/// Natural materials from elemental-ui, drawn as a translucent pane.
/// Persist [name], never [index].
enum HermesMaterial {
  none(HermesMaterialKind.pack, null, HermesGlassInk.none, 0, 0),
  water(HermesMaterialKind.water, null, HermesGlassInk.water, 0.14, 1.6),
  quartz(HermesMaterialKind.quartz, null, HermesGlassInk.quartz, 0.08, 0.8),
  slate(
    HermesMaterialKind.pack,
    'geo.slate.layered.v1',
    HermesGlassInk.slate,
    0.22,
    0.55,
  ),
  basalt(
    HermesMaterialKind.pack,
    'geo.basalt.vesicular.v1',
    HermesGlassInk.basalt,
    0.20,
    0.6,
  ),
  limestone(
    HermesMaterialKind.pack,
    'geo.limestone.porous.v1',
    HermesGlassInk.limestone,
    0.16,
    0.5,
  );

  const HermesMaterial(
    this.kind,
    this.packId,
    this.body,
    this.bodyOpacity,
    this.sheen,
  );

  final HermesMaterialKind kind;

  /// elemental-ui pack id; assets live in `assets/elemental/<packId>/`.
  final String? packId;

  /// The material's own colour, used for water/quartz and for swatches.
  final Color body;

  /// How much of the material's body covers the wallpaper on the root pane.
  final double bodyOpacity;

  /// Gain on specular light and glints (crystal edges, caustic lines).
  final double sheen;

  bool get visible => this != HermesMaterial.none;
}

/// The persisted choices. Every field has a safe default, so unknown or
/// damaged backup values fall back instead of failing.
@immutable
class HermesSurfaceStyle {
  const HermesSurfaceStyle({
    this.mode = HermesSurfaceMode.solid,
    this.preset = HermesGlassPreset.frost,
    this.tint,
    this.blur,
    this.material = HermesMaterial.none,
    this.quietChrome = false,
    this.liquidChrome = true,
  });

  static const solid = HermesSurfaceStyle();

  final HermesSurfaceMode mode;
  final HermesGlassPreset preset;

  /// Custom tint opacity 0..1; null follows [preset].
  final double? tint;

  /// Custom compositor blur in dp; null follows [preset].
  final double? blur;
  final HermesMaterial material;

  /// Minimal chrome: no navigation labels, no card outlines, hairline-free.
  final bool quietChrome;

  /// Liquid glass (refracting) navigation; off draws a still glass pill.
  final bool liquidChrome;

  bool get isGlass => mode == HermesSurfaceMode.glass;
  double get effectiveBlur =>
      (blur ?? preset.blur).clamp(0, maxBlur).toDouble();

  static const double maxBlur = 80;

  HermesSurfaceStyle copyWith({
    HermesSurfaceMode? mode,
    HermesGlassPreset? preset,
    double? tint,
    double? blur,
    bool clearCustom = false,
    HermesMaterial? material,
    bool? quietChrome,
    bool? liquidChrome,
  }) {
    return HermesSurfaceStyle(
      mode: mode ?? this.mode,
      preset: preset ?? this.preset,
      tint: clearCustom ? null : (tint ?? this.tint),
      blur: clearCustom ? null : (blur ?? this.blur),
      material: material ?? this.material,
      quietChrome: quietChrome ?? this.quietChrome,
      liquidChrome: liquidChrome ?? this.liquidChrome,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HermesSurfaceStyle &&
      other.mode == mode &&
      other.preset == preset &&
      other.tint == tint &&
      other.blur == blur &&
      other.material == material &&
      other.quietChrome == quietChrome &&
      other.liquidChrome == liquidChrome;

  @override
  int get hashCode => Object.hash(
    mode,
    preset,
    tint,
    blur,
    material,
    quietChrome,
    liquidChrome,
  );
}

/// What the compositor can do right now. Null fields are unknown (first frame,
/// tests, non-Android): treated as "no blur" so text is never under-tinted.
@immutable
class HermesWindowCapabilities {
  const HermesWindowCapabilities({
    this.transparent = false,
    this.crossWindowBlur,
  });

  static const unknown = HermesWindowCapabilities();

  /// The activity was created with a transparent, wallpaper-showing window.
  final bool transparent;
  final bool? crossWindowBlur;

  @override
  bool operator ==(Object other) =>
      other is HermesWindowCapabilities &&
      other.transparent == transparent &&
      other.crossWindowBlur == crossWindowBlur;

  @override
  int get hashCode => Object.hash(transparent, crossWindowBlur);
}

/// Smallest tint opacity (to 0.01) at which [text] keeps [ratio] over [tint]
/// composited on [wallpaper]. Source-over in gamma-encoded sRGB, which is
/// what Android's compositor does.
double minTintFor({
  required Color text,
  required Color tint,
  required Color wallpaper,
  double ratio = 4.5,
}) {
  for (var a = 0; a <= 100; a++) {
    final composite = Color.alphaBlend(
      tint.withValues(alpha: a / 100),
      wallpaper,
    );
    if (contrastRatio(text, composite) >= ratio) return a / 100;
  }
  return 1;
}

double _round2(double v) => (v * 100).roundToDouble() / 100;

/// Resolved glass, carried on [ThemeData.extensions] next to [HermesTokens].
@immutable
class HermesSurface extends ThemeExtension<HermesSurface> {
  const HermesSurface({
    required this.glass,
    required this.scene,
    required this.panel,
    required this.chrome,
    required this.sheet,
    required this.rim,
    required this.tint,
    required this.blurDp,
    required this.material,
    required this.quietChrome,
    required this.liquidChrome,
  });

  /// Opaque surfaces: exactly today's app.
  factory HermesSurface.solid(
    HermesTokens tokens, {
    bool quietChrome = false,
  }) => HermesSurface(
    glass: false,
    scene: tokens.surface,
    panel: tokens.raised,
    chrome: tokens.raised,
    sheet: tokens.raised,
    rim: tokens.border,
    tint: 1,
    blurDp: 0,
    material: HermesMaterial.none,
    quietChrome: quietChrome,
    liquidChrome: false,
  );

  /// Body text must stay AA over a mid-grey wallpaper region (a typical
  /// blurred average). Below this, secondary text fails on mid tones.
  static double tintFloor(HermesTokens tokens) => math.min(
    tintMax,
    minTintFor(
      text: tokens.muted,
      tint: tokens.surface,
      wallpaper: HermesGlassInk.probeMid,
    ),
  );

  /// Body text stays AA even over the worst wallpaper highlight.
  static double tintSafe(HermesTokens tokens) => minTintFor(
    text: tokens.onSurface,
    tint: tokens.surface,
    wallpaper: tokens.brightness == Brightness.dark
        ? HermesGlassInk.probeWhite
        : HermesGlassInk.probeBlack,
  );

  static const double tintMax = 0.95;

  /// With cross-window blur off (battery saver), wallpaper detail is sharp, so
  /// raise the tint until blur returns.
  static const double noBlurBoost = 0.12;

  static double presetTint(HermesGlassPreset preset, HermesTokens tokens) {
    final floor = tintFloor(tokens);
    final safe = tintSafe(tokens);
    return switch (preset) {
      HermesGlassPreset.clear => _round2(floor),
      HermesGlassPreset.frost => _round2(
        math.max(floor, (safe * 20).ceil() / 20),
      ),
      HermesGlassPreset.deep => _round2(math.max(safe, 0.86)),
    };
  }

  /// Glass only renders when both the style asks for it and the window was
  /// actually created transparent; otherwise fall back to Solid so a stale
  /// preference can never paint a see-through app over an opaque window.
  static HermesSurface resolve(
    HermesSurfaceStyle style,
    HermesTokens tokens, {
    HermesWindowCapabilities window = HermesWindowCapabilities.unknown,
  }) {
    if (!style.isGlass || !window.transparent) {
      return HermesSurface.solid(tokens, quietChrome: style.quietChrome);
    }
    final dark = tokens.brightness == Brightness.dark;
    final floor = tintFloor(tokens);
    final blurOn = window.crossWindowBlur == true && style.effectiveBlur > 0;
    final requested = style.tint ?? presetTint(style.preset, tokens);
    final tint = _round2(
      (requested + (blurOn ? 0 : noBlurBoost)).clamp(floor, tintMax).toDouble(),
    );
    // Glass catches light: raised panels add a veil of light, never more dark.
    const light = HermesGlassInk.light;
    final panel = light.withValues(alpha: dark ? 0.07 : 0.42);
    final chrome = Color.alphaBlend(
      light.withValues(alpha: dark ? 0.10 : 0.30),
      tokens.surface.withValues(alpha: math.min(0.32, tintMax - tint + 0.1)),
    );
    return HermesSurface(
      glass: true,
      scene: tokens.surface.withValues(alpha: tint),
      panel: panel,
      chrome: chrome,
      sheet: tokens.raised.withValues(alpha: 0.94),
      rim: light.withValues(alpha: dark ? 0.16 : 0.55),
      tint: tint,
      blurDp: blurOn ? style.effectiveBlur : 0,
      material: style.material,
      quietChrome: style.quietChrome,
      liquidChrome: style.liquidChrome,
    );
  }

  final bool glass;

  /// Painted once behind every route, over the blurred wallpaper.
  final Color scene;

  /// Cards and raised rows: a veil of light, so glass brightens.
  final Color panel;

  /// Floating navigation and composer chrome.
  final Color chrome;

  /// Dialogs and sheets: near-opaque so modal text never fights the wallpaper.
  final Color sheet;

  /// The bright edge that makes a pane read as glass.
  final Color rim;
  final double tint;

  /// Effective compositor blur (0 when unavailable).
  final double blurDp;
  final HermesMaterial material;
  final bool quietChrome;
  final bool liquidChrome;

  static HermesSurface of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<HermesSurface>() ??
        HermesSurface.solid(HermesTokens.of(context));
  }

  @override
  HermesSurface copyWith({
    bool? glass,
    Color? scene,
    Color? panel,
    Color? chrome,
    Color? sheet,
    Color? rim,
    double? tint,
    double? blurDp,
    HermesMaterial? material,
    bool? quietChrome,
    bool? liquidChrome,
  }) {
    return HermesSurface(
      glass: glass ?? this.glass,
      scene: scene ?? this.scene,
      panel: panel ?? this.panel,
      chrome: chrome ?? this.chrome,
      sheet: sheet ?? this.sheet,
      rim: rim ?? this.rim,
      tint: tint ?? this.tint,
      blurDp: blurDp ?? this.blurDp,
      material: material ?? this.material,
      quietChrome: quietChrome ?? this.quietChrome,
      liquidChrome: liquidChrome ?? this.liquidChrome,
    );
  }

  @override
  HermesSurface lerp(ThemeExtension<HermesSurface>? other, double t) {
    if (other is! HermesSurface) return this;
    final pick = t < 0.5 ? this : other;
    return HermesSurface(
      glass: pick.glass,
      scene: Color.lerp(scene, other.scene, t)!,
      panel: Color.lerp(panel, other.panel, t)!,
      chrome: Color.lerp(chrome, other.chrome, t)!,
      sheet: Color.lerp(sheet, other.sheet, t)!,
      rim: Color.lerp(rim, other.rim, t)!,
      tint: tint + (other.tint - tint) * t,
      blurDp: blurDp + (other.blurDp - blurDp) * t,
      material: pick.material,
      quietChrome: pick.quietChrome,
      liquidChrome: pick.liquidChrome,
    );
  }
}
