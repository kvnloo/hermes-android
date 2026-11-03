import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

import '../theme/hermes_surface.dart';
import '../theme/hermes_theme.dart';

/// The glass scene behind every route: one contrast-checked tint over the
/// compositor-blurred wallpaper, plus an optional Elemental material pane.
class HermesGlassBackdrop extends StatelessWidget {
  const HermesGlassBackdrop({required this.surface, super.key});

  final HermesSurface surface;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        key: const Key('hermes_glass_backdrop'),
        fit: StackFit.expand,
        children: [
          ColoredBox(color: surface.scene),
          if (surface.material.visible)
            ElementalPane(material: surface.material, strength: 1),
        ],
      ),
    );
  }
}

/// Floating chrome (navigation, composer): thicker glass with a lit rim.
/// Liquid chrome refracts the content scrolling underneath it.
class HermesGlassPanel extends StatelessWidget {
  const HermesGlassPanel({
    required this.child,
    this.radius = 28,
    this.padding = EdgeInsets.zero,
    super.key,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final surface = HermesSurface.of(context);
    final tokens = HermesTokens.of(context);
    final borderRadius = BorderRadius.circular(radius);
    final body = Stack(
      children: [
        if (surface.material.visible)
          Positioned.fill(
            child: ClipRRect(
              borderRadius: borderRadius,
              child: ElementalPane(material: surface.material, strength: 1.8),
            ),
          ),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _RimPainter(
                radius: radius,
                rim: surface.rim,
                dark: tokens.brightness == Brightness.dark,
              ),
            ),
          ),
        ),
        Padding(padding: padding, child: child),
      ],
    );
    if (surface.glass && surface.liquidChrome) {
      return LiquidGlassLayer(
        settings: LiquidGlassSettings(
          thickness: 22,
          blur: 3,
          glassColor: surface.chrome,
          lightIntensity: 0.9,
          ambientStrength: 0.35,
          refractiveIndex: 1.22,
          saturation: 1.15,
          chromaticAberration: 0.25,
        ),
        child: LiquidGlass(
          shape: LiquidRoundedSuperellipse(borderRadius: radius),
          child: body,
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface.chrome,
        borderRadius: borderRadius,
      ),
      child: body,
    );
  }
}

class _RimPainter extends CustomPainter {
  _RimPainter({required this.radius, required this.rim, required this.dark});

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
    // Light falls from the top left: a bright edge there, fading away.
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          rim.withValues(alpha: math.min(1, rim.a * 2.2)),
          rim.withValues(alpha: rim.a * 0.35),
          rim.withValues(alpha: rim.a * 0.9),
        ],
        stops: const [0, 0.55, 1],
      ).createShader(rect);
    canvas.drawRRect(rrect, edge);
    // A soft sheen across the upper half sells the thickness of the pane.
    final sheen = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.center,
        colors: [
          const Color(0xFFFFFFFF).withValues(alpha: dark ? 0.07 : 0.18),
          const Color(0x00FFFFFF),
        ],
      ).createShader(rect);
    canvas.drawRRect(rrect, sheen);
  }

  @override
  bool shouldRepaint(_RimPainter old) =>
      old.radius != radius || old.rim != rim || old.dark != dark;
}

/// Loads `shaders/elemental_glass.frag` and elemental-ui packs once.
class ElementalResources {
  ElementalResources._();

  static Future<ui.FragmentProgram>? _program;
  static final Map<String, Future<List<ui.Image>>> _packs = {};
  static Future<ui.Image>? _blank;

  static Future<ui.FragmentProgram> program() =>
      _program ??= ui.FragmentProgram.fromAsset('shaders/elemental_glass.frag');

  static Future<List<ui.Image>> maps(HermesMaterial material) {
    final id = material.packId;
    if (id == null) {
      return blank().then((image) => [image, image, image]);
    }
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

/// A translucent pane of an Elemental material, lit by a slowly drifting
/// light. Water moves; stone and crystal only change as the light moves.
/// Honors reduce-motion by freezing the light.
class ElementalPane extends StatefulWidget {
  const ElementalPane({required this.material, this.strength = 1, super.key});

  final HermesMaterial material;

  /// Multiplier on the material's body opacity and sheen (chrome is thicker).
  final double strength;

  @override
  State<ElementalPane> createState() => _ElementalPaneState();
}

class _ElementalPaneState extends State<ElementalPane>
    with SingleTickerProviderStateMixin {
  ui.FragmentShader? _shader;
  List<ui.Image>? _maps;
  late final Ticker _ticker = createTicker(_tick);
  final ValueNotifier<double> _time = ValueNotifier(0);
  Duration _lastFrame = Duration.zero;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ElementalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.material != widget.material) _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still && _ticker.isActive) _ticker.stop();
    if (!still && !_ticker.isActive) _ticker.start();
  }

  Future<void> _load() async {
    try {
      final program = await ElementalResources.program();
      final maps = await ElementalResources.maps(widget.material);
      if (_disposed) return;
      setState(() {
        _shader ??= program.fragmentShader();
        _maps = maps;
      });
    } catch (_) {
      // Shader or pack unavailable (tests, old GPU): glass stays plain.
    }
  }

  void _tick(Duration elapsed) {
    // Water at ~30 fps, stone and crystal at ~12 fps: the light drifts slowly.
    final interval = widget.material.kind == HermesMaterialKind.water
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
        painter: _ElementalPainter(
          shader: shader,
          maps: maps,
          material: widget.material,
          strength: widget.strength,
          time: _time,
          dark: HermesTokens.of(context).brightness == Brightness.dark,
          origin: () {
            final box = context.findRenderObject() as RenderBox?;
            return box != null && box.hasSize
                ? box.localToGlobal(Offset.zero)
                : Offset.zero;
          },
        ),
      ),
    );
  }
}

class _ElementalPainter extends CustomPainter {
  _ElementalPainter({
    required this.shader,
    required this.maps,
    required this.material,
    required this.strength,
    required this.time,
    required this.dark,
    required this.origin,
  }) : super(repaint: time);

  final ui.FragmentShader shader;
  final List<ui.Image> maps;
  final HermesMaterial material;
  final double strength;
  final ValueListenable<double> time;
  final bool dark;
  final Offset Function() origin;

  static double _lin(double c) =>
      c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value;
    final angle = t * 0.12;
    final o = origin();
    final kind = switch (material.kind) {
      HermesMaterialKind.pack => 0.0,
      HermesMaterialKind.water => 1.0,
      HermesMaterialKind.quartz => 2.0,
    };
    var i = 0;
    void f(double v) => shader.setFloat(i++, v);
    f(size.width);
    f(size.height);
    f(material.kind == HermesMaterialKind.water ? 220 : 180); // tile px
    f(t);
    f(math.cos(angle) * 0.55);
    f(math.sin(angle) * 0.35 + 0.45);
    f(0.8);
    f(dark ? 2.6 : 3.2);
    f(_lin(material.body.r));
    f(_lin(material.body.g));
    f(_lin(material.body.b));
    f((material.bodyOpacity * strength).clamp(0, 0.6).toDouble());
    f(kind);
    f(material.kind == HermesMaterialKind.pack ? 1.6 : 1.0); // relief
    f((material.sheen * strength).clamp(0, 2).toDouble());
    f(dark ? 1.0 : 1.25); // exposure
    f(o.dx);
    f(o.dy);
    for (var s = 0; s < 3; s++) {
      shader.setImageSampler(s, maps[s]);
    }
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_ElementalPainter old) =>
      old.material != material ||
      old.strength != strength ||
      old.dark != dark ||
      old.maps != maps;
}
