// Syn: a Moodie-style blob face with bloub liveliness, ported from
// kvnloo/synergy.ai companion-bot.js (fd18f25). Face geometry and the
// expression table are adapted from Moodie (MIT,
// https://github.com/arhxam/moodie-react); idle gaze wander, the blink curve
// and breathing from bloub (MIT, https://github.com/jeremy-prt/bloub).
// Notices: third_party/syn-face/LICENSES.md.
//
// Drawn on the companion's 200x200 design square. Drag/flick physics and the
// page-pet seat are web-only and not ported; a tap is a "poke".
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'avatar_palette.dart';
import 'hm_avatar_state.dart';

@immutable
class SynEye {
  const SynEye(
    this.x,
    this.y,
    this.width,
    this.height, [
    this.rotation = 0,
    this.curve = 0.8,
    this.skew = 0,
    this.open = 1,
  ]);
  final double x, y, width, height, rotation, curve, skew, open;

  static SynEye lerp(SynEye a, SynEye b, double t) => SynEye(
    _l(a.x, b.x, t),
    _l(a.y, b.y, t),
    _l(a.width, b.width, t),
    _l(a.height, b.height, t),
    _l(a.rotation, b.rotation, t),
    _l(a.curve, b.curve, t),
    _l(a.skew, b.skew, t),
    _l(a.open, b.open, t),
  );
}

@immutable
class SynBody {
  const SynBody({
    this.rotate = 0,
    this.scaleX = 1,
    this.scaleY = 1,
    this.y = 0,
  });
  final double rotate, scaleX, scaleY, y;

  static SynBody lerp(SynBody a, SynBody b, double t) => SynBody(
    rotate: _l(a.rotate, b.rotate, t),
    scaleX: _l(a.scaleX, b.scaleX, t),
    scaleY: _l(a.scaleY, b.scaleY, t),
    y: _l(a.y, b.y, t),
  );
}

enum SynReaction { none, bounce, tilt, squash }

@immutable
class SynExpression {
  const SynExpression(
    this.left,
    this.right, {
    this.body = const SynBody(),
    this.reaction = SynReaction.none,
  });
  final SynEye left, right;
  final SynBody body;
  final SynReaction reaction;
}

double _l(double a, double b, double t) => a + (b - a) * t;

/// Moodie presets + bloub emotion coverage (MIT), on the 200x200 design square.
const synExpressions = <String, SynExpression>{
  'neutral': SynExpression(
    SynEye(72, 94, 22, 42, -5),
    SynEye(128, 94, 22, 42, 5),
  ),
  'happy': SynExpression(
    SynEye(72, 100, 31, 13, 7, 0.38),
    SynEye(128, 100, 31, 13, -7, 0.38),
    body: SynBody(y: -2),
    reaction: SynReaction.bounce,
  ),
  'excited': SynExpression(
    SynEye(70, 96, 29, 53, -9, 0.92),
    SynEye(130, 96, 29, 53, 9, 0.92),
    body: SynBody(scaleX: 1.03, scaleY: 0.97),
    reaction: SynReaction.bounce,
  ),
  'sleepy': SynExpression(
    SynEye(72, 100, 28, 34, 2, 0.55, 0, 0.42),
    SynEye(128, 100, 28, 34, -2, 0.55, 0, 0.42),
    body: SynBody(rotate: -3, y: 4),
    reaction: SynReaction.tilt,
  ),
  'worried': SynExpression(
    SynEye(72, 96, 22, 38, 16, 0.76),
    SynEye(128, 96, 22, 38, -16, 0.76),
    reaction: SynReaction.tilt,
  ),
  'thinking': SynExpression(
    SynEye(68, 91, 17, 30, -18, 0.88),
    SynEye(126, 101, 32, 15, -24, 0.46),
    body: SynBody(rotate: -4),
    reaction: SynReaction.tilt,
  ),
  'curious': SynExpression(
    SynEye(70, 89, 18, 34, -12, 0.85),
    SynEye(130, 100, 31, 47, 10, 0.84),
    body: SynBody(rotate: 5),
    reaction: SynReaction.tilt,
  ),
  'surprised': SynExpression(
    SynEye(72, 95, 34, 52, 0, 1),
    SynEye(128, 95, 34, 52, 0, 1),
    body: SynBody(scaleX: 0.96, scaleY: 1.04),
    reaction: SynReaction.bounce,
  ),
  'focused': SynExpression(
    SynEye(72, 97, 31, 13, 14, 0.4),
    SynEye(128, 97, 31, 13, -14, 0.4),
    body: SynBody(scaleX: 1.01),
    reaction: SynReaction.squash,
  ),
  'cheeky': SynExpression(
    SynEye(72, 94, 28, 13, 10, 0.35),
    SynEye(128, 95, 21, 42, 8, 0.84),
    body: SynBody(rotate: 4),
    reaction: SynReaction.tilt,
  ),
  'calm': SynExpression(
    SynEye(72, 99, 34, 9, 0, 0.3),
    SynEye(128, 99, 34, 9, 0, 0.3),
    body: SynBody(scaleX: 1.01, scaleY: 0.99),
  ),
  'wink': SynExpression(
    SynEye(72, 99, 35, 8, 8, 0.25),
    SynEye(128, 95, 23, 43, 4, 0.85),
    body: SynBody(rotate: 3),
    reaction: SynReaction.bounce,
  ),
  'alert': SynExpression(
    SynEye(72, 91, 21, 48, -3, 0.9),
    SynEye(128, 91, 21, 48, 3, 0.9),
    body: SynBody(y: -3, scaleY: 1.02),
    reaction: SynReaction.bounce,
  ),
  'angry': SynExpression(
    SynEye(72, 97, 30, 14, 28, 0.4),
    SynEye(128, 97, 30, 14, -28, 0.4),
    body: SynBody(y: 1, scaleY: 0.98),
    reaction: SynReaction.squash,
  ),
  'sad': SynExpression(
    SynEye(72, 100, 20, 36, -26, 0.78),
    SynEye(128, 100, 20, 36, 26, 0.78),
    body: SynBody(y: 3, rotate: -2),
    reaction: SynReaction.tilt,
  ),
  'shy': SynExpression(
    SynEye(68, 98, 16, 28, -4, 0.8),
    SynEye(124, 98, 16, 28, 4, 0.8),
    body: SynBody(rotate: -6, y: 2),
    reaction: SynReaction.tilt,
  ),
  'bored': SynExpression(
    SynEye(70, 99, 30, 11, 0, 0.28),
    SynEye(130, 99, 30, 11, 0, 0.28),
    body: SynBody(rotate: 2),
    reaction: SynReaction.tilt,
  ),
  'proud': SynExpression(
    SynEye(72, 96, 28, 14, 16, 0.36),
    SynEye(128, 96, 28, 14, -16, 0.36),
    body: SynBody(y: -3, scaleY: 1.02),
    reaction: SynReaction.bounce,
  ),
  'confused': SynExpression(
    SynEye(68, 92, 18, 40, -16, 0.85),
    SynEye(130, 100, 28, 14, 12, 0.4),
    body: SynBody(rotate: 7),
    reaction: SynReaction.tilt,
  ),
};

const _pokeExpressions = [
  'happy',
  'cheeky',
  'wink',
  'surprised',
  'excited',
  'curious',
  'proud',
];

/// Which Syn expression shows each avatar state.
String synExpressionFor(HmAvatarState s) => switch (s) {
  HmAvatarState.idle => 'calm',
  HmAvatarState.listening => 'alert',
  HmAvatarState.thinking => 'thinking',
  HmAvatarState.speaking => 'focused',
  HmAvatarState.asleep => 'sleepy',
  HmAvatarState.error => 'worried',
};

// --- geometry ------------------------------------------------------------

const _eyePoints = 12;

double _clamp(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);
double _sign1(double v) => v < 0 ? -1 : 1; // Math.sign(v || 1)

List<Offset> synEyePoints(SynEye g) {
  final width = _clamp(g.width, 2, 120), height = _clamp(g.height, 2, 120);
  final curve = _clamp(g.curve, 0, 1), skew = _clamp(g.skew, -1, 1);
  final rad = _clamp(g.rotation, -180, 180) * math.pi / 180;
  final c = math.cos(rad), s = math.sin(rad);
  final exponent = 2 + curve * 2.4;
  return List.generate(_eyePoints, (i) {
    final angle = (i / _eyePoints) * math.pi * 2;
    final cosine = math.cos(angle), sine = math.sin(angle);
    final lx =
        _sign1(cosine) * math.pow(cosine.abs(), 2 / exponent) * (width / 2) +
        sine * skew * (height / 5);
    final ly = _sign1(sine) * math.pow(sine.abs(), 2 / exponent) * (height / 2);
    return Offset(g.x + lx * c - ly * s, g.y + lx * s + ly * c);
  });
}

/// Closed Catmull-Rom-style curve through [p] (companion-bot's createClosedPath).
Path synClosedPath(List<Offset> p, double tension) {
  final t = _clamp(tension, 0, 2);
  final n = p.length;
  final path = Path()..moveTo(p[0].dx, p[0].dy);
  for (var i = 0; i < n; i++) {
    final prev = p[(i - 1 + n) % n],
        cur = p[i],
        next = p[(i + 1) % n],
        after = p[(i + 2) % n];
    path.cubicTo(
      cur.dx + (next.dx - prev.dx) / 6 * t,
      cur.dy + (next.dy - prev.dy) / 6 * t,
      next.dx - (after.dx - cur.dx) / 6 * t,
      next.dy - (after.dy - cur.dy) / 6 * t,
      next.dx,
      next.dy,
    );
  }
  return path..close();
}

Path synEyePath(SynEye g) =>
    synClosedPath(synEyePoints(g), 0.82 + _clamp(g.curve, 0, 1) * 0.12);

final Path synBodyPath = () {
  final pts = List.generate(16, (i) {
    final angle = (i / 16) * math.pi * 2 - math.pi / 2;
    final cosine = math.cos(angle), sine = math.sin(angle);
    final wobble =
        1 +
        math.sin(angle * 3 + 0.7) * 0.045 +
        math.cos(angle * 2 - 0.4) * 0.025;
    return Offset(100 + cosine * 88 * wobble, 102 + sine * (88 / wobble));
  });
  return synClosedPath(pts, 1);
}();

// --- liveliness (bloub) ----------------------------------------------------

double _loopNoise(double t, double period, double seed) {
  final p = (t / period) * math.pi * 2;
  return 0.55 * math.sin(p + seed) +
      0.3 * math.sin(2 * p + seed * 1.7 + 1.1) +
      0.15 * math.sin(3 * p + seed * 2.3 + 2.4);
}

/// mulberry32, as companion-bot's createRng (32-bit unsigned arithmetic).
double Function() _rng(int seed) {
  var a = seed & 0xffffffff;
  int imul(int x, int y) => (x * y) & 0xffffffff;
  return () {
    a = (a + 0x6d2b79f5) & 0xffffffff;
    var t = imul(a ^ (a >> 15), 1 | a);
    t = ((t + imul(t ^ (t >> 7), 61 | t)) & 0xffffffff) ^ t;
    return ((t ^ (t >> 14)) & 0xffffffff) / 4294967296;
  };
}

const _blinkDur = 0.18;
final List<double> _blinks = () {
  final r = _rng(0x5eed);
  final out = <double>[];
  var t = 1.4;
  while (t < 900) {
    out.add(t);
    t += 1.9 + r() * 2.7;
    if (r() < 0.18) {
      out.add(t);
      t += 0.24;
    }
  }
  return out;
}();

/// 1 open -> 0 closed -> 1 open over a blink (the schedule repeats every 900 s).
double _blinkLid(double tSec) {
  final t = tSec % 900;
  for (final start in _blinks) {
    if (t < start) break;
    final k = (t - start) / _blinkDur;
    if (k >= 0 && k <= 1) return k < 0.45 ? 1 - k / 0.45 : (k - 0.45) / 0.55;
  }
  return 1;
}

class _Spring {
  double x = 0, v = 0;
  _Spring([this.x = 0]);
  double step(double target, double stiffness, double damping, double dt) {
    v = (v + (target - x) * stiffness * dt) * damping;
    x += v * dt;
    if ((target - x).abs() < 0.0005 && v.abs() < 0.0005) {
      x = target;
      v = 0;
    }
    return x;
  }
}

/// The animated Syn face. [color] is the bot's fixed body tone.
class SynFace extends StatefulWidget {
  const SynFace({
    super.key,
    required this.state,
    required this.size,
    required this.color,
    this.eyeColor = AvatarPalette.eye,
    this.seed = 0,
    this.animate = true,
  });

  final HmAvatarState state;
  final double size;
  final Color color;
  final Color eyeColor;

  /// Shifts the clock so bots in a list don't blink in unison.
  final int seed;
  final bool animate;

  @override
  State<SynFace> createState() => _SynFaceState();
}

class _SynFaceState extends State<SynFace> with SingleTickerProviderStateMixin {
  // Made in initState: a still face that first touched it in dispose would
  // look up TickerMode on a deactivated element.
  late final Ticker _ticker;
  final _clock = Stopwatch();
  final _rand = math.Random();
  Duration _last = Duration.zero;
  late SynExpression _from, _to;
  String _name = 'calm';
  double _morph = 1, _morphDur = 0.5;
  double _reactionUntil = 0, _now = 0;
  final _gazeX = _Spring(),
      _gazeY = _Spring(),
      _leanX = _Spring(),
      _leanY = _Spring(),
      _bob = _Spring(),
      _scale = _Spring(1);
  _Frame _frame = const _Frame();

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    _name = synExpressionFor(widget.state);
    _from = _to = synExpressions[_name]!;
    _clock.start();
    _frame = _compose(0, 0.016, still: !widget.animate);
    if (widget.animate) _ticker.start();
  }

  @override
  void didUpdateWidget(SynFace old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) {
      _setExpression(synExpressionFor(widget.state));
    }
    if (old.animate != widget.animate) {
      if (widget.animate && !_ticker.isActive) {
        _ticker.start();
      } else if (!widget.animate && _ticker.isActive) {
        _ticker.stop();
        setState(() => _frame = _compose(_now, 0.016, still: true));
      }
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  SynExpression get _current {
    final t = 1 - math.pow(1 - _clamp(_morph, 0, 1), 3).toDouble();
    return SynExpression(
      SynEye.lerp(_from.left, _to.left, t),
      SynEye.lerp(_from.right, _to.right, t),
      body: SynBody.lerp(_from.body, _to.body, t),
      reaction: _to.reaction,
    );
  }

  void _setExpression(String name, {bool react = false}) {
    final next = synExpressions[name] ?? synExpressions['neutral']!;
    _from = _current;
    _to = next;
    _name = name;
    _morph = 0;
    _morphDur = 0.48 + _rand.nextDouble() * 0.12;
    if (react) _reactionUntil = _now + 0.55;
    if (!_ticker.isActive) {
      setState(() => _frame = _compose(_now, 0.016, still: true));
    }
  }

  void _poke() {
    _setExpression(
      _pokeExpressions[_rand.nextInt(_pokeExpressions.length)],
      react: true,
    );
    Future<void>.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) _setExpression(synExpressionFor(widget.state));
    });
  }

  void _tick(Duration elapsed) {
    final dt = _clamp((elapsed - _last).inMicroseconds / 1e6, 0.001, 0.048);
    _last = elapsed;
    _now = _clock.elapsedMicroseconds / 1e6;
    setState(() => _frame = _compose(_now, dt));
  }

  _Frame _compose(double now, double dt, {bool still = false}) {
    if (_morph < 1) _morph = still ? 1 : _clamp(_morph + dt / _morphDur, 0, 1);
    final t = now + widget.seed * 2.371;
    final idle =
        widget.state == HmAvatarState.idle ||
        widget.state == HmAvatarState.asleep;
    final wander = still ? 0.0 : (idle ? 1.0 : 0.45);
    final dYaw =
        (_loopNoise(t, 11.3, 0.4) * 5.5 + _loopNoise(t, 3.7, 2.1) * 1.6) *
        wander;
    final dPitch =
        (_loopNoise(t, 9.1, 1.3) * 4.2 + _loopNoise(t, 4.3, 0.7) * 1.3) *
        wander;
    final dRoll = _loopNoise(t, 13.7, 3.2) * 2.2 * wander;
    final lid = still ? 1.0 : _blinkLid(t);
    final driftX = still ? 0.0 : _loopNoise(t, 7.9, 1.9) * 0.006;
    final driftY = still ? 0.0 : _loopNoise(t, 5.3, 0.3) * 0.007;
    final breath = still ? 1.0 : 1 + math.sin((t / 3.4) * math.pi * 2) * 0.005;

    final expr = _current;
    final reacting = now < _reactionUntil;
    var targetBob = driftY * 40, targetScale = breath;
    if (!still) {
      if (reacting && expr.reaction == SynReaction.bounce) {
        targetBob = -5;
        targetScale = 1.045;
      } else if (reacting && expr.reaction == SynReaction.squash) {
        targetScale = 0.96;
        targetBob = 2;
      } else if (reacting && expr.reaction == SynReaction.tilt) {
        targetBob = -1;
      } else if (widget.state == HmAvatarState.speaking) {
        // companion "is-talking" bob
        targetBob = math.sin(now * 1000 / 90) * 1.4;
        targetScale = 1.02 + math.sin(now * 1000 / 70) * 0.012;
      } else if (widget.state == HmAvatarState.listening) {
        targetBob = math.sin(now * 1000 / 140) * 2.2;
        targetScale = 1.03;
      }
    }
    if (still) {
      for (final s in [_gazeX, _gazeY, _leanX, _leanY, _bob]) {
        s
          ..x = 0
          ..v = 0;
      }
      _scale
        ..x = 1
        ..v = 0;
    } else {
      _gazeX.step(dYaw / 28, 26, 0.8, dt);
      _gazeY.step(dPitch / 28, 26, 0.8, dt);
      _leanX.step(dRoll * 0.35, 16, 0.84, dt);
      _leanY.step(dPitch * 0.12, 16, 0.84, dt);
      _bob.step(targetBob, 38, 0.76, dt);
      _scale.step(targetScale, 34, 0.74, dt);
    }

    final blinkS = 0.06 + 0.94 * _clamp(lid, 0, 1);
    final pullX = _gazeX.x * 14 + driftX * 80,
        pullY = _gazeY.x * 10 + driftY * 80;
    final compress = 1 - _gazeX.x.abs() * 0.12;
    SynEye eye(SynEye e) => SynEye(
      e.x + pullX,
      e.y + pullY,
      e.width * compress,
      e.height * blinkS * _clamp(e.open, 0.08, 1),
      e.rotation,
      e.curve,
      e.skew,
      e.open,
    );
    return _Frame(
      left: synEyePath(eye(expr.left)),
      right: synEyePath(eye(expr.right)),
      rotate:
          expr.body.rotate +
          _leanX.x * 0.55 +
          (reacting && expr.reaction == SynReaction.tilt ? _leanX.x * 2 : 0) +
          dRoll * 0.15,
      dy: expr.body.y + _leanY.x + _bob.x,
      sx: expr.body.scaleX * _scale.x * (1 + _gazeX.x.abs() * 0.03),
      sy: expr.body.scaleY * _scale.x * (1 - _gazeY.x.abs() * 0.02),
    );
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: _poke,
    child: SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _SynPainter(
          _frame,
          widget.color,
          widget.eyeColor,
          _light(widget.state),
        ),
      ),
    ),
  );

  static Color _light(HmAvatarState s) => switch (s) {
    HmAvatarState.thinking => AvatarPalette.thinking,
    HmAvatarState.speaking ||
    HmAvatarState.listening => AvatarPalette.active,
    HmAvatarState.error => AvatarPalette.error,
    _ => AvatarPalette.inactive,
  };
}

class _Frame {
  const _Frame({
    this.left,
    this.right,
    this.rotate = 0,
    this.dy = 0,
    this.sx = 1,
    this.sy = 1,
  });
  final Path? left, right;
  final double rotate, dy, sx, sy;
}

class _SynPainter extends CustomPainter {
  _SynPainter(this.f, this.body, this.eye, this.light);
  final _Frame f;
  final Color body, eye, light;

  @override
  void paint(Canvas canvas, Size size) {
    // 200-unit design square, inset so bounce and tilt stay inside the box.
    final s = size.shortestSide / 216;
    canvas
      ..save()
      ..scale(s)
      ..translate(108, 108 + f.dy)
      ..rotate(f.rotate * math.pi / 180)
      ..scale(f.sx, f.sy)
      ..translate(-100, -100);
    canvas.drawPath(synBodyPath, Paint()..color = body);
    final ep = Paint()..color = eye;
    if (f.left != null) canvas.drawPath(f.left!, ep);
    if (f.right != null) canvas.drawPath(f.right!, ep);
    if (light.a > 0) {
      canvas.drawCircle(const Offset(148, 52), 7, Paint()..color = light);
      canvas.drawCircle(const Offset(148, 52), 2.6, Paint()..color = eye);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SynPainter old) => true;
}
