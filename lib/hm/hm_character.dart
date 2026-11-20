// A bot's character: a soft blob with two pill eyes, shaped by a seed so
// each bot keeps its own silhouette. Drawn procedurally (no artwork).
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// What a character looks like. Stored per bot in the profile's `ui_meta`
/// under `character` so every client of the host draws the same one.
@immutable
class HmCharacterSpec {
  const HmCharacterSpec({
    required this.seed,
    this.color,
    this.eyes = HmEyes.pill,
  });

  final int seed;
  final Color? color;
  final HmEyes eyes;

  factory HmCharacterSpec.forName(String name) =>
      HmCharacterSpec(seed: _stableHash(name));

  /// Reads `ui_meta.character` (`{seed, color: "#RRGGBB", eyes}`); anything
  /// missing falls back to the name's seed.
  factory HmCharacterSpec.fromMeta(Object? meta, String name) {
    final fallback = HmCharacterSpec.forName(name);
    if (meta is! Map) return fallback;
    final raw = meta['character'];
    if (raw is! Map) return fallback;
    final seed = raw['seed'];
    final color = raw['color'];
    final eyes = HmEyes.values.where((e) => e.name == raw['eyes']).firstOrNull;
    Color? parsed;
    if (color is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(color)) {
      parsed = Color(0xFF000000 | int.parse(color.substring(1), radix: 16));
    }
    return HmCharacterSpec(
      seed: seed is int ? seed : fallback.seed,
      color: parsed,
      eyes: eyes ?? HmEyes.pill,
    );
  }

  Map<String, Object?> toMeta() => {
    'seed': seed,
    if (color != null)
      'color':
          '#${(color!.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
    'eyes': eyes.name,
  };

  static int _stableHash(String s) {
    var h = 0x811C9DC5;
    for (final u in s.codeUnits) {
      h = ((h ^ u) * 0x01000193) & 0x7FFFFFFF;
    }
    return h;
  }
}

enum HmEyes { pill, round, sleepy }

/// The character at [size]. [working] gently breathes the outline (a turn
/// is running); eyes blink every few seconds unless reduced motion is on.
class HmCharacter extends StatefulWidget {
  const HmCharacter({
    super.key,
    required this.spec,
    this.size = 40,
    this.working = false,
  });

  final HmCharacterSpec spec;
  final double size;
  final bool working;

  @override
  State<HmCharacter> createState() => _HmCharacterState();
}

class _HmCharacterState extends State<HmCharacter>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat();

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.of(context).disableAnimations;
    final body = widget.spec.color ?? const Color(0xFF51545C);
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: still
            ? CustomPaint(
                painter: _CharacterPainter(widget.spec, body, 0, false),
              )
            : AnimatedBuilder(
                animation: _t,
                builder: (context, _) => CustomPaint(
                  painter: _CharacterPainter(
                    widget.spec,
                    body,
                    _t.value,
                    widget.working,
                  ),
                ),
              ),
      ),
    );
  }
}

class _CharacterPainter extends CustomPainter {
  _CharacterPainter(this.spec, this.body, this.t, this.working);

  final HmCharacterSpec spec;
  final Color body;
  final double t; // 0..1 over the loop
  final bool working;

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(spec.seed);
    const lobes = 7;
    final phase = List.generate(lobes, (_) => rnd.nextDouble() * math.pi * 2);
    final amp = List.generate(lobes, (_) => 0.04 + rnd.nextDouble() * 0.07);
    final tilt = (rnd.nextDouble() - 0.5) * 0.25;
    final c = size.center(Offset.zero);
    final r = size.shortestSide * 0.46;
    final breathe = working ? math.sin(t * math.pi * 2 * 3) * 0.025 : 0.0;

    double radiusAt(double a) {
      var k = 1.0 + breathe;
      for (var i = 0; i < lobes; i++) {
        k += amp[i] * math.sin(a * (i % 3 + 2) + phase[i]) / (i + 1) * 1.6;
      }
      return r * k.clamp(0.82, 1.08);
    }

    final path = Path();
    const steps = 72;
    for (var i = 0; i <= steps; i++) {
      final a = i / steps * math.pi * 2;
      final rr = radiusAt(a);
      final p =
          c + Offset(math.cos(a + tilt) * rr, math.sin(a + tilt) * rr * 0.94);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..color = body
        ..isAntiAlias = true,
    );

    // Eyes: two vertical pills just above centre; a blink squashes them.
    final cycle = (t * 6) % 1; // ~1 s slices of a 6 s loop
    final blinkSlice = (spec.seed % 5) == (t * 6).floor() % 5;
    final blink = blinkSlice && cycle > 0.86
        ? (1 - math.sin((cycle - 0.86) / 0.14 * math.pi))
        : 1.0;
    final eyeW = size.width * 0.105;
    final eyeH =
        size.height *
        (spec.eyes == HmEyes.sleepy ? 0.12 : 0.22) *
        blink.clamp(0.12, 1.0);
    final gap = size.width * 0.085;
    final eyeY = c.dy - size.height * 0.02;
    final eyePaint = Paint()
      ..color = Colors.white
      ..isAntiAlias = true;
    for (final dx in [-gap - eyeW / 2, gap + eyeW / 2]) {
      final rect = Rect.fromCenter(
        center: Offset(c.dx + dx, eyeY),
        width: eyeW,
        height: eyeH,
      );
      if (spec.eyes == HmEyes.round) {
        canvas.drawOval(
          Rect.fromCenter(
            center: rect.center,
            width: eyeW * 1.3,
            height: eyeW * 1.3 * blink.clamp(0.12, 1.0),
          ),
          eyePaint,
        );
      } else {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(eyeW / 2)),
          eyePaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CharacterPainter old) =>
      old.t != t ||
      old.spec != spec ||
      old.body != body ||
      old.working != working;
}
