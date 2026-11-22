// elemental-ui materials for NextGen: stone packs, water and quartz drawn as
// a thin lit pane behind every screen. The packs and the lighting model come
// from elemental-ui (GPL-3.0-only); see third_party/elemental-ui/.
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../core/theme/hermes_theme.dart' show contrastRatio;
import 'nextgen_theme.dart' show NgMaterialInk;

enum NgMaterialKind { pack, water, quartz }

/// A material the app scene can be made of. Persist [name], never [index].
enum NgMaterial {
  none(NgMaterialKind.pack, null, NgMaterialInk.clear, 0, 0),
  basalt(
    NgMaterialKind.pack,
    'geo.basalt.vesicular.v1',
    NgMaterialInk.basalt,
    0.16,
    0.30,
  ),
  slate(
    NgMaterialKind.pack,
    'geo.slate.layered.v1',
    NgMaterialInk.slate,
    0.14,
    0.30,
  ),
  limestone(
    NgMaterialKind.pack,
    'geo.limestone.porous.v1',
    NgMaterialInk.limestone,
    0.14,
    0.26,
  ),
  water(NgMaterialKind.water, null, NgMaterialInk.water, 0.10, 0.30),
  quartz(NgMaterialKind.quartz, null, NgMaterialInk.quartz, 0.08, 0.26);

  const NgMaterial(
    this.kind,
    this.packId,
    this.body,
    this.bodyOpacity,
    this.sheen,
  );

  final NgMaterialKind kind;

  /// elemental-ui pack id; maps live in `assets/elemental/<packId>/`.
  final String? packId;

  /// The material's own colour: water and quartz bodies, and the swatch.
  final Color body;

  /// How much of the material covers the scene (before [ngSceneStrength]).
  final double bodyOpacity;

  /// Gain on specular light and glints (crystal edges, caustic lines).
  final double sheen;

  bool get visible => this != NgMaterial.none;

  static NgMaterial parse(Object? name) => NgMaterial.values.firstWhere(
    (m) => m.name == name,
    orElse: () => NgMaterial.none,
  );
}

/// Chrome (the Liquid Glass composer) asks for a thicker slab of material.
const double ngChromeStrength = 1.8;

/// The shader clamps the body opacity it is given to this.
const double ngMaxBodyOpacity = 0.6;

/// The shader clamps its sheen gain to this.
const double ngMaxSheenGain = 2.0;

/// The most light the shader adds before the sheen gain: a capped GGX
/// highlight (0.6) plus the brightest glint (quartz edges 0.45, water
/// caustics 0.7).
double ngMaxHighlight(NgMaterialKind kind) => switch (kind) {
  NgMaterialKind.pack => 0.6,
  NgMaterialKind.quartz => 1.05,
  NgMaterialKind.water => 1.3,
};

/// How much material a pane may draw: shader body opacity and sheen gain.
@immutable
class NgMaterialDose {
  const NgMaterialDose(this.bodyOpacity, this.sheen);

  static const none = NgMaterialDose(0, 0);

  final double bodyOpacity;
  final double sheen;

  @override
  bool operator ==(Object other) =>
      other is NgMaterialDose &&
      other.bodyOpacity == bodyOpacity &&
      other.sheen == sheen;

  @override
  int get hashCode => Object.hash(bodyOpacity, sheen);

  @override
  String toString() => 'NgMaterialDose($bodyOpacity, $sheen)';
}

/// Worst-case colours a pane with [dose] can lay over [background]: the
/// material's darkest and lightest plausible body, each alone and under the
/// brightest white sheen the shader can emit.
List<Color> ngMaterialExtremes(
  NgMaterial material,
  Color background,
  NgMaterialDose dose,
) {
  if (!material.visible) return [background];
  final bodyAlpha = dose.bodyOpacity.clamp(0.0, ngMaxBodyOpacity);
  final sheen = (ngMaxHighlight(material.kind) * dose.sheen).clamp(0.0, 1.0);
  // Packs vary across the tile and the GGX lighting darkens or brightens the
  // body; bracket it around the swatch.
  final bodies = [
    material.body,
    Color.lerp(material.body, NgMaterialInk.shade, 0.5)!,
    Color.lerp(material.body, NgMaterialInk.light, 0.35)!,
  ];
  final out = <Color>[];
  for (final body in bodies) {
    final veiled = Color.alphaBlend(
      body.withValues(alpha: bodyAlpha),
      background,
    );
    out.add(veiled);
    // The shader adds sheen as white light over the uncovered part.
    out.add(
      Color.alphaBlend(
        NgMaterialInk.light.withValues(alpha: sheen * (1 - bodyAlpha)),
        veiled,
      ),
    );
  }
  return out;
}

/// The most material a pane over [backgrounds] may draw, up to [strength]
/// times the material's own dose, without taking any of [roles] below WCAG
/// AA where it met AA on the plain background. Body first, then sheen, each
/// in 5% steps, so a dark theme keeps its stone and drops the glare.
NgMaterialDose ngSafeMaterialDose(
  NgMaterial material,
  Iterable<Color> backgrounds,
  Iterable<Color> roles, {
  double strength = 1,
}) {
  if (!material.visible) return NgMaterialDose.none;
  final checks = [
    for (final bg in backgrounds)
      for (final role in roles)
        if (contrastRatio(role, bg) >= 4.5) (role, bg),
  ];
  bool readable(NgMaterialDose dose) => checks.every(
    (check) => ngMaterialExtremes(
      material,
      check.$2,
      dose,
    ).every((bg) => contrastRatio(check.$1, bg) >= 4.5),
  );
  double largest(NgMaterialDose Function(double scale) dose) {
    for (var step = 20; step > 0; step--) {
      if (readable(dose(strength * step / 20))) return strength * step / 20;
    }
    return 0;
  }

  final body = largest((s) => NgMaterialDose(material.bodyOpacity * s, 0));
  final bodyOpacity = material.bodyOpacity * body;
  final sheen = largest((s) => NgMaterialDose(bodyOpacity, material.sheen * s));
  return NgMaterialDose(bodyOpacity, material.sheen * sheen);
}
