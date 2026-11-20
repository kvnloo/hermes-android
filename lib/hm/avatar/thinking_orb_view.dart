// Paints the thinking-orbs engine (thinking_orbs.dart) with a shared clock,
// a per-bot tint and the theme's light/dark ink ramp.
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'hm_avatar_state.dart';
import 'thinking_orbs.dart';

/// The orb state each avatar state draws.
OrbState orbStateFor(HmAvatarState s) => switch (s) {
  HmAvatarState.idle ||
  HmAvatarState.asleep ||
  HmAvatarState.error => OrbState.breathing,
  HmAvatarState.listening => OrbState.listening,
  HmAvatarState.thinking => OrbState.working,
  HmAvatarState.speaking => OrbState.composing,
};

class ThinkingOrbView extends StatefulWidget {
  const ThinkingOrbView({
    super.key,
    required this.state,
    required this.size,
    required this.dark,
    this.tint,
    this.animate = true,
  });

  final HmAvatarState state;
  final double size;

  /// Mirrors the ink ramp so near dots read bright on dark substrates.
  final bool dark;

  /// The bot's colour; null draws grayscale.
  final Color? tint;
  final bool animate;

  @override
  State<ThinkingOrbView> createState() => _ThinkingOrbViewState();
}

class _ThinkingOrbViewState extends State<ThinkingOrbView>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(
    (e) => setState(() => _t = e.inMicroseconds / 1e6),
  );
  double _t = 1.0;

  bool get _moving =>
      widget.animate &&
      widget.state != HmAvatarState.asleep &&
      widget.state != HmAvatarState.error;

  @override
  void initState() {
    super.initState();
    if (_moving) _ticker.start();
  }

  @override
  void didUpdateWidget(ThinkingOrbView old) {
    super.didUpdateWidget(old);
    if (_moving && !_ticker.isActive) _ticker.start();
    if (!_moving && _ticker.isActive) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The engine ships tunings for 64, 32 and 20 design px; use the nearest
    // one at or below the drawn size, and scale.
    final design = widget.size >= 56 ? 64 : (widget.size >= 30 ? 32 : 20);
    final r = resolveOrb(orbStateFor(widget.state), design);
    final frame = orbFrame(r.mode, design.toDouble(), _t * r.speed, r.opts);
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _OrbPainter(
          frame,
          design.toDouble(),
          widget.dark,
          widget.tint,
          widget.state == HmAvatarState.error ? const Color(0xFFE5522D) : null,
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter(this.frame, this.design, this.dark, this.tint, this.forced);
  final OrbFrame frame;
  final double design;
  final bool dark;
  final Color? tint, forced;

  // thinking-orbs inkColor: grayscale ramp, or the same ramp on a tint.
  Color _ink(double white, double alpha) {
    final w = white.clamp(0.0, 1.0);
    final t = forced ?? tint;
    if (t == null) {
      final g = ((dark ? 1 - w : w) * 255).round();
      return Color.fromRGBO(g, g, g, alpha);
    }
    int ramp(double c) => (dark ? c * (1 - w) : c + (255 - c) * w).round();
    return Color.fromRGBO(
      ramp(t.r * 255),
      ramp(t.g * 255),
      ramp(t.b * 255),
      alpha,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.shortestSide / design);
    final stroke = Paint()..style = PaintingStyle.stroke;
    for (final l in frame.lines) {
      stroke
        ..color = _ink(l.white, l.a)
        ..strokeWidth = l.w;
      canvas.drawLine(Offset(l.x1, l.y1), Offset(l.x2, l.y2), stroke);
    }
    final fill = Paint();
    for (final d in frame.dots) {
      fill.color = _ink(d.white, d.a);
      canvas.drawCircle(Offset(d.x, d.y), d.r, fill);
    }
  }

  @override
  bool shouldRepaint(_OrbPainter old) => true;
}
