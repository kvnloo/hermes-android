// The elemental-ui scene and the Liquid Glass chrome that refracts it.
//
// [NgScene] paints the app's scene once at the root: the opaque (Solid) or
// wallpaper-tint (Glass) colour, then an [NgElementalPane] of the chosen
// material. [NgLiquidChrome] turns a floating control (the composer) into a
// Liquid Glass lens over that scene, with a slab of the same material in it.
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

import '../theme/nextgen_theme.dart';
import '../theme/ng_elemental.dart';

/// What sits under the scene pane: the opaque Solid background, or the Glass
/// tint over a black, white and mid-grey wallpaper.
List<Color> ngSceneBackdrops(NgColors c) {
  final scene = c.glassScene ?? c.background;
  if (scene.a >= 1) return [scene];
  return [
    for (final wallpaper in const [
      Color(0xFF000000),
      Color(0xFFFFFFFF),
      Color(0xFF808080),
    ])
      Color.alphaBlend(scene, wallpaper),
  ];
}

final _doses = <Object, NgMaterialDose>{};

/// The root pane's dose: every text role on the scene keeps AA.
NgMaterialDose ngSceneDose(NgColors c, NgMaterial material) =>
    _doses[(
      #scene,
      material,
      c.glassScene,
      c.background,
      c.text,
      c.text2,
      c.text3,
      c.textMuted,
    )] ??= ngSafeMaterialDose(material, ngSceneBackdrops(c), [
      c.text,
      c.text2,
      c.text3,
      c.textMuted,
    ]);

/// The composer's slab: text and hint on the lens (tint over the lit scene)
/// keep AA.
NgMaterialDose ngChromeDose(NgColors c, NgMaterial material) =>
    _doses[(
      #chrome,
      material,
      c.glassScene,
      c.background,
      c.surface,
      c.text,
      c.text2,
      c.text3,
    )] ??= () {
      final scene = ngSceneDose(c, material);
      final tint = ngLiquidTint(c);
      return ngSafeMaterialDose(
        material,
        [
          for (final backdrop in ngSceneBackdrops(c))
            for (final lit in ngMaterialExtremes(material, backdrop, scene))
              Color.alphaBlend(tint, lit),
        ],
        [c.text, c.text2, c.text3],
        strength: ngChromeStrength,
      );
    }();

/// The Liquid Glass composer's tint: the surface at 60%, so the lens shows
/// the scene while the composer's text keeps its contrast.
Color ngLiquidTint(NgColors c) =>
    c.surface.withValues(alpha: c.surface.a * 0.6);

/// The root scene behind every NextGen route.
class NgScene extends StatelessWidget {
  const NgScene({
    super.key,
    required this.color,
    required this.material,
    required this.child,
  });

  final Color color;
  final NgMaterial material;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!material.visible) return ColoredBox(color: color, child: child);
    final dose = ngSceneDose(NgColors.of(context), material);
    return ColoredBox(
      color: color,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: NgElementalPane(
                key: const ValueKey('ng-elemental-scene'),
                material: material,
                dose: dose,
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// Floating chrome as Liquid Glass: a refracting lens with a lit rim and a
/// thicker slab of the scene's material. Off, it paints [fallback] as before.
class NgLiquidChrome extends StatelessWidget {
  const NgLiquidChrome({
    super.key,
    required this.enabled,
    required this.material,
    required this.tint,
    required this.rim,
    required this.radius,
    required this.fallback,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  final bool enabled;
  final NgMaterial material;

  /// The glass colour; keep it near the surface colour so text stays legible.
  final Color tint;

  /// The rim's base colour (white on dark scenes, ink on light ones).
  final Color rim;
  final double radius;
  final BoxDecoration fallback;
  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return Container(decoration: fallback, padding: padding, child: child);
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    final borderRadius = BorderRadius.circular(radius);
    return DecoratedBox(
      key: const ValueKey('ng-liquid-chrome'),
      // The lens keeps the composer's floating shadow.
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: fallback.boxShadow,
      ),
      child: LiquidGlass.withOwnLayer(
        settings: LiquidGlassSettings(
          thickness: 20,
          blur: 4,
          glassColor: tint,
          lightIntensity: dark ? 0.8 : 1.1,
          ambientStrength: 0.3,
          refractiveIndex: 1.22,
          saturation: 1.2,
          chromaticAberration: 0.2,
        ),
        shape: LiquidRoundedSuperellipse(borderRadius: radius),
        child: Stack(
          children: [
            if (material.visible)
              Positioned.fill(
                child: IgnorePointer(
                  child: ClipRRect(
                    borderRadius: borderRadius,
                    child: NgElementalPane(
                      material: material,
                      dose: ngChromeDose(NgColors.of(context), material),
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: NgRimPainter(radius: radius, rim: rim, dark: dark),
                ),
              ),
            ),
            Padding(padding: padding, child: child),
          ],
        ),
      ),
    );
  }
}

/// A lit edge (light from the top left) and a soft sheen over the top half.
class NgRimPainter extends CustomPainter {
  NgRimPainter({required this.radius, required this.rim, required this.dark});

  final double radius;
  final Color rim;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(0.5),
      Radius.circular(radius),
    );
    final base = dark ? 0.22 : 0.55;
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            rim.withValues(alpha: math.min(1, base * 2)),
            rim.withValues(alpha: base * 0.3),
            rim.withValues(alpha: base * 0.8),
          ],
          stops: const [0, 0.55, 1],
        ).createShader(rect),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.center,
          colors: [
            Colors.white.withValues(alpha: dark ? 0.06 : 0.16),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(NgRimPainter old) =>
      old.radius != radius || old.rim != rim || old.dark != dark;
}

/// Loads `shaders/elemental_glass.frag` and the elemental-ui packs once.
abstract final class NgElementalResources {
  static Future<ui.FragmentProgram>? _program;
  static final Map<String, Future<List<ui.Image>>> _packs = {};
  static Future<ui.Image>? _blank;

  static Future<ui.FragmentProgram> program() =>
      _program ??= ui.FragmentProgram.fromAsset('shaders/elemental_glass.frag');

  /// basecolor, normal and roughness for [material]; flat maps for procedural
  /// materials (water, quartz), which the shader ignores.
  static Future<List<ui.Image>> maps(NgMaterial material) {
    final id = material.packId;
    if (id == null) return blank().then((image) => [image, image, image]);
    return _packs[id] ??= Future.wait([
      for (final map in const ['basecolor', 'normal', 'roughness'])
        _decode('assets/elemental/$id/$map.png'),
    ]);
  }

  static Future<ui.Image> blank() => _blank ??= () {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      Uint8List.fromList(const [128, 128, 255, 255]),
      1,
      1,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }();

  static Future<ui.Image> _decode(String asset) async {
    final data = await rootBundle.load(asset);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    return (await codec.getNextFrame()).image;
  }
}

/// A translucent pane of [material], lit by a slowly drifting light. Water
/// moves; stone and crystal change only as the light moves. Reduce motion
/// freezes the light. Paints nothing until the shader and maps are ready.
class NgElementalPane extends StatefulWidget {
  const NgElementalPane({
    super.key,
    required this.material,
    required this.dose,
  });

  final NgMaterial material;

  /// Body opacity and sheen, already checked against the text over the pane.
  final NgMaterialDose dose;

  @override
  State<NgElementalPane> createState() => _NgElementalPaneState();
}

class _NgElementalPaneState extends State<NgElementalPane>
    with SingleTickerProviderStateMixin {
  ui.FragmentShader? _shader;
  List<ui.Image>? _maps;
  late final Ticker _ticker = createTicker(_tick);
  final ValueNotifier<double> _time = ValueNotifier(0);
  Duration _lastFrame = Duration.zero;
  bool _disposed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(NgElementalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.material != widget.material) _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTicker();
  }

  void _syncTicker() {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final ready = _shader != null && _maps != null;
    if ((still || !ready) && _ticker.isActive) _ticker.stop();
    if (!still && ready && !_ticker.isActive) _ticker.start();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final program = await NgElementalResources.program();
      final maps = await NgElementalResources.maps(widget.material);
      if (_disposed || generation != _generation) return;
      setState(() {
        _shader ??= program.fragmentShader();
        _maps = maps;
      });
      _syncTicker();
    } catch (error) {
      // No shader or pack (an old GPU, a stripped build): the scene stays
      // plain rather than failing the screen.
      debugPrint('Elemental material unavailable: $error');
    }
  }

  void _tick(Duration elapsed) {
    // Water at ~30 fps; stone and crystal at ~12 fps, as only the light moves.
    final interval = widget.material.kind == NgMaterialKind.water
        ? const Duration(milliseconds: 33)
        : const Duration(milliseconds: 83);
    if (elapsed - _lastFrame < interval) return;
    _lastFrame = elapsed;
    _time.value = elapsed.inMicroseconds / 1e6;
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker.dispose();
    _time.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    final maps = _maps;
    if (shader == null || maps == null) return const SizedBox.expand();
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _NgElementalPainter(
          shader: shader,
          maps: maps,
          material: widget.material,
          dose: widget.dose,
          time: _time,
          dark: Theme.of(context).brightness == Brightness.dark,
          origin: () {
            final box = context.findRenderObject() as RenderBox?;
            return box != null && box.hasSize && box.attached
                ? box.localToGlobal(Offset.zero)
                : Offset.zero;
          },
        ),
      ),
    );
  }
}

/// The shader's uniforms, in declaration order.
@visibleForTesting
List<double> ngElementalUniforms({
  required Size size,
  required NgMaterial material,
  required NgMaterialDose dose,
  required double time,
  required bool dark,
  required Offset origin,
}) {
  double lin(double c) =>
      c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  final angle = time * 0.12;
  return [
    size.width,
    size.height,
    material.kind == NgMaterialKind.water ? 220 : 180, // tile px
    time,
    math.cos(angle) * 0.55,
    math.sin(angle) * 0.35 + 0.45,
    0.8,
    dark ? 2.6 : 3.2,
    lin(material.body.r),
    lin(material.body.g),
    lin(material.body.b),
    dose.bodyOpacity.clamp(0.0, ngMaxBodyOpacity),
    switch (material.kind) {
      NgMaterialKind.pack => 0.0,
      NgMaterialKind.water => 1.0,
      NgMaterialKind.quartz => 2.0,
    },
    material.kind == NgMaterialKind.pack ? 1.6 : 1.0, // relief
    dose.sheen.clamp(0.0, ngMaxSheenGain),
    dark ? 1.0 : 1.25, // exposure
    origin.dx,
    origin.dy,
  ];
}

class _NgElementalPainter extends CustomPainter {
  _NgElementalPainter({
    required this.shader,
    required this.maps,
    required this.material,
    required this.dose,
    required this.time,
    required this.dark,
    required this.origin,
  }) : super(repaint: time);

  final ui.FragmentShader shader;
  final List<ui.Image> maps;
  final NgMaterial material;
  final NgMaterialDose dose;
  final ValueListenable<double> time;
  final bool dark;
  final Offset Function() origin;

  @override
  void paint(Canvas canvas, Size size) {
    final uniforms = ngElementalUniforms(
      size: size,
      material: material,
      dose: dose,
      time: time.value,
      dark: dark,
      origin: origin(),
    );
    for (var i = 0; i < uniforms.length; i++) {
      shader.setFloat(i, uniforms[i]);
    }
    for (var s = 0; s < 3; s++) {
      shader.setImageSampler(s, maps[s]);
    }
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_NgElementalPainter old) =>
      old.material != material ||
      old.dose != dose ||
      old.dark != dark ||
      old.maps != maps;
}
