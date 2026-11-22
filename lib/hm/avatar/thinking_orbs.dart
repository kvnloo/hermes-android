// Dart port of the thinking-orbs geometry engine (MIT, (c) 2026 Jakub
// Antalik, https://libraries.dev/orbs, source packages/thinking-orbs/src/engine
// at Jakubantalik/Libraries.dev@14ae9d2). Pure math: (size, t, opts) -> one
// z-sorted frame of dots and lines. Verified against the upstream golden
// vectors in test/hm/thinking_orbs_test.dart.
//
// Parity notes: JS `Math.round` rounds halves up (toward +inf), JS `%` is a
// truncated remainder, and JS `Array.sort` is stable. The helpers below keep
// all three, so the output matches the web engine number for number.
import 'dart:math' as math;

/// One dot. `white` is ink: 0 = darkest ink on paper, mirrored on dark themes.
class OrbDot {
  OrbDot(this.x, this.y, this.z, this.r, this.white, [this.a = 1]);
  final double x, y, z, white, a;
  double r;
}

/// A stroked edge (the `web` mode). Drawn before dots.
class OrbLine {
  const OrbLine(this.x1, this.y1, this.x2, this.y2, this.white, this.a, this.w);
  final double x1, y1, x2, y2, white, a, w;
}

class OrbFrame {
  const OrbFrame(this.dots, this.lines);
  final List<OrbDot> dots;
  final List<OrbLine> lines;
}

/// The nine shipped states and the mode each one draws.
enum OrbState {
  working('orbits'),
  searching('globe'),
  solving('rubik'),
  listening('wave'),
  connecting('web'),
  weaving('braid'),
  composing('ribbon'),
  breathing('ring'),
  shaping('morph');

  const OrbState(this.mode);
  final String mode;
}

typedef OrbOpts = Map<String, double>;

class ResolvedOrb {
  const ResolvedOrb(this.mode, this.speed, this.opts);
  final String mode;
  final double speed;
  final OrbOpts opts;
}

// --- JS parity helpers --------------------------------------------------

double _jsRound(double x) => (x + 0.5).floorToDouble();
double _jsMod(double a, double b) => a.remainder(b);
double _frac(double x) => x - x.floorToDouble();
double _lerp(double a, double b, double f) => a + (b - a) * f;
double _hashD(double a, double b) {
  final h = math.sin(a * 12.9898 + b * 78.233) * 43758.5453;
  return h - h.floorToDouble();
}

double _vnoise(double x, double y) {
  final xi = x.floorToDouble();
  final yi = y.floorToDouble();
  var fx = x - xi;
  var fy = y - yi;
  fx = fx * fx * (3 - 2 * fx);
  fy = fy * fy * (3 - 2 * fy);
  final a = _hashD(xi, yi);
  final b = _hashD(xi + 1, yi);
  final c = _hashD(xi, yi + 1);
  final d = _hashD(xi + 1, yi + 1);
  return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy;
}

List<double> _fibDir(int i, int n) {
  final golden = math.pi * (3 - math.sqrt(5));
  final y = 1 - (2 * (i + 0.5)) / n;
  final rad = math.sqrt(1 - y * y);
  final a = i * golden;
  return [rad * math.cos(a), y, rad * math.sin(a)];
}

double _angleDelta(double a, double b) =>
    math.atan2(math.sin(a - b), math.cos(a - b));

typedef _Proj = List<double> Function(double x, double y, double z);

_Proj _makeProj(double yaw, double tilt, double cx, double cy, double scale) {
  final st = math.sin(tilt), ct = math.cos(tilt);
  final sy = math.sin(yaw), cyw = math.cos(yaw);
  return (x, y, z) {
    final x1 = x * cyw + z * sy;
    final z1 = -x * sy + z * cyw;
    final y1 = y * ct - z1 * st;
    final z2 = y * st + z1 * ct;
    return [cx + x1 * scale, cy - y1 * scale, z2];
  };
}

double _rs(double size, double pow) => math.pow(size / 300, pow).toDouble();

/// Drop invisible marks, clamp radii, stable z-sort far -> near.
OrbFrame _finalize(List<OrbDot> dots, List<OrbLine> lines, double? rMin) {
  final floor = rMin ?? 0.3;
  final visible = <OrbDot>[];
  for (final d in dots) {
    if (d.a < 0.02) continue;
    d.r = math.max(floor, d.r);
    visible.add(d);
  }
  // Stable: equal-z dots (morph is all z=0) keep their emission order.
  final indexed = List.generate(visible.length, (i) => i);
  indexed.sort((i, j) {
    final c = visible[i].z.compareTo(visible[j].z);
    return c != 0 ? c : i.compareTo(j);
  });
  return OrbFrame(
    [for (final i in indexed) visible[i]],
    [
      for (final l in lines)
        if (l.a >= 0.02) l,
    ],
  );
}

// --- profiles + presets -------------------------------------------------

const _countPairs = [
  ['latRings', 'lonDensity'],
  ['rings', 'lonDensity'],
  ['lanes', 'segs'],
];
const _countKeys = ['orbitN', 'ghostN', 'nodeN', 'strandN', 'signals'];
const _radiusKeys = [
  'rBase',
  'rDepth',
  'rActive',
  'rDot',
  'ghostR',
  'partR',
  'partRDepth',
  'nodeR',
  'nodeRDepth',
];

OrbOpts _scaleCounts(OrbOpts opts, double scale) {
  final out = {...opts};
  final done = <String>{};
  final rt = math.sqrt(scale);
  for (final p in _countPairs) {
    final va = out[p[0]], vb = out[p[1]];
    if (va != null &&
        vb != null &&
        !done.contains(p[0]) &&
        !done.contains(p[1])) {
      out[p[0]] = math.max(2, _jsRound(va * rt));
      out[p[1]] = math.max(2, _jsRound(vb * rt));
      done.addAll(p);
    }
  }
  for (final k in _countKeys) {
    final v = out[k];
    if (v != null && v != 0 && !done.contains(k)) {
      out[k] = math.max(1, _jsRound(v * scale));
    }
  }
  final d = out['iconD'];
  if (d != null) out['iconD'] = math.max(0.02, d * scale);
  return out;
}

OrbOpts _scaleRadii(OrbOpts opts, double scale) {
  final out = {...opts};
  for (final k in _radiusKeys) {
    final v = out[k];
    if (v != null) out[k] = v * scale;
  }
  out['rSizeMul'] = (out['rSizeMul'] ?? 1) * scale;
  return out;
}

const Map<String, OrbOpts> _base = {
  'globe': {
    'latRings': 17,
    'lonDensity': 44,
    'rBase': 0.6,
    'rDepth': 1.7,
    'rBoost': 1.0,
    'inkFar': 0.62,
    'inkSpan': 0.54,
    'rsPow': 0.6,
    'rMin': 0.3,
  },
  'orbits': {
    'orbitN': 12,
    'ghostN': 40,
    'ghostR': 0.9,
    'ghostA': 0.5,
    'particles': 3,
    'partR': 1.2,
    'partRDepth': 1.6,
    'rsPow': 0.6,
    'rMin': 0.3,
  },
  'rubik': {
    'latRings': 15,
    'lonDensity': 40,
    'moveCount': 14,
    'rBase': 0.6,
    'rDepth': 1.7,
    'rActive': 0.3,
    'inkFar': 0.62,
    'inkSpan': 0.54,
    'rsPow': 0.6,
    'rMin': 0.3,
  },
  'wave': {
    'rings': 15,
    'lonDensity': 40,
    'rBase': 0.6,
    'rDepth': 1.7,
    'rsPow': 0.6,
    'rMin': 0.3,
  },
  'web': {
    'nodeN': 30,
    'thr': 0.72,
    'signals': 5,
    'nodeR': 1.4,
    'nodeRDepth': 1.8,
    'lineW': 0.8,
    'rsPow': 0.6,
    'rMin': 0.3,
  },
  'braid': {
    'strandN': 52,
    'turns': 3.0,
    'ghostN': 150,
    'rBase': 1.2,
    'rDepth': 1.8,
    'rsPow': 0.6,
    'rMin': 0.3,
  },
  'ribbon': {
    'lanes': 5,
    'segs': 88,
    'ghostN': 150,
    'rBase': 1.1,
    'rDepth': 1.7,
    'rsPow': 0.6,
    'rMin': 0.3,
  },
  'ring': {
    'lanes': 5,
    'segs': 88,
    'ghostN': 0,
    'faceOn': 1,
    'rBase': 1.1,
    'rDepth': 1.7,
    'rsPow': 0.6,
    'rMin': 0.3,
  },
  'morph': {'rDot': 0.021, 'iconD': 1, 'rMin': 0.25},
};

/// (speed, count, size, extra) per mode and design size (64 / 32 / 20).
const Map<String, Map<int, (double, double, double, OrbOpts?)>> _presets = {
  'orbits': {
    64: (1.885, 1, 1, null),
    32: (2.9072, 0.4251, 1.6849, null),
    20: (3.9, 0.238, 2.4, null),
  },
  'globe': {
    64: (2.015, 0.42, 1.15, {'scanMul': 4.08, 'dimBase': 0.45}),
    32: (2.3803, 0.1839, 1.4769, {'scanMul': 4.2301, 'dimBase': 0.45}),
    20: (2.665, 0.105, 1.75, {'scanMul': 4.335, 'dimBase': 0.45}),
  },
  'rubik': {
    64: (1.82, 0.35, 1.05, null),
    32: (1.8964, 0.1537, 1.4951, null),
    20: (1.95, 0.088, 1.9, null),
  },
  'wave': {
    64: (4.388, 0.341, 1, null),
    32: (4.1512, 0.169, 1.3232, null),
    20: (3.998, 0.105, 1.6, null),
  },
  'web': {
    64: (3.315, 1.35, 0.95, null),
    32: (5.0104, 0.4942, 1.2571, null),
    20: (6.63, 0.25, 1.52, null),
  },
  'braid': {
    64: (1.625, 0.5, 1, null),
    32: (2.2234, 0.2056, 1.2011, null),
    20: (2.75, 0.1125, 1.36, null),
  },
  'ribbon': {
    64: (2.34, 0.25, 0.85, {'spin': 0, 'bandMul': 3.9, 'wobMul': 1}),
    32: (2.7776, 0.0969, 0.9766, {'spin': 0, 'bandMul': 4.49, 'wobMul': 1}),
    20: (3.12, 0.051, 1.073, {'spin': 0, 'bandMul': 4.94, 'wobMul': 1}),
  },
  'ring': {
    64: (3.24, 0.25, 0.956, {'spin': 0, 'bandMul': 3.627, 'wobMul': 0.368}),
    32: (
      3.5517,
      0.0678,
      1.31,
      {'spin': 0, 'bandMul': 3.8265, 'wobMul': 0.4751},
    ),
    20: (3.78, 0.028, 1.622, {'spin': 0, 'bandMul': 3.968, 'wobMul': 0.565}),
  },
  'morph': {
    64: (2.405, 0.702, 0.395, {'spread': 1.45}),
    32: (2.2057, 0.5937, 0.6916, {'spread': 1.45}),
    20: (2.08, 0.53, 1.011, {'spread': 1.45}),
  },
};

final _cache = <String, ResolvedOrb>{};

/// A (state, design size: 64, 32 or 20) pair resolved to its mode and
/// fully-scaled options.
ResolvedOrb resolveOrb(OrbState state, int size) =>
    _cache.putIfAbsent('${state.name}-$size', () {
      final mode = state.mode;
      final (speed, count, sz, extra) = _presets[mode]![size]!;
      var opts = {..._base[mode]!};
      if (count != 1) opts = _scaleCounts(opts, count);
      if (sz != 1) opts = _scaleRadii(opts, sz);
      if (extra != null) opts = {...opts, ...extra};
      return ResolvedOrb(mode, speed, opts);
    });

/// Geometry for one instant of [mode] at CSS-px [size], clock [t].
OrbFrame orbFrame(String mode, double size, double t, OrbOpts o) =>
    switch (mode) {
      'orbits' => _orbits(size, t, o),
      'globe' => _globe(size, t, o),
      'rubik' => _rubik(size, t, o),
      'wave' => _wave(size, t, o),
      'web' => _web(size, t, o),
      'braid' => _braid(size, t, o),
      'ribbon' || 'ring' => _ribbon(size, t, o),
      'morph' => _morph(size, t, o),
      _ => throw ArgumentError.value(mode, 'mode'),
    };

// --- modes ----------------------------------------------------------------

OrbFrame _orbits(double size, double t, OrbOpts o) {
  final cx = size / 2, cy = size / 2;
  final R = (size / 2) * 0.82;
  final pt = _makeProj(t * 0.12, 0.3, cx, cy, 1);
  final rs = _rs(size, o['rsPow'] ?? 0.6);
  final dots = <OrbDot>[];
  final orbitN = (o['orbitN'] ?? 12).toInt();
  final ghostN = (o['ghostN'] ?? 40).toInt();
  final particles = (o['particles'] ?? 3).toInt();
  for (var orb = 0; orb < orbitN; orb++) {
    final h1 = _hashD(orb.toDouble(), 1.7);
    final h2 = _hashD(orb.toDouble(), 5.2);
    final h3 = _hashD(orb.toDouble(), 8.9);
    final ro = R * (0.45 + 0.52 * h1);
    final th = h1 * 2 * math.pi;
    final phi = math.acos(2 * h2 - 1);
    final nx = math.sin(phi) * math.cos(th);
    final ny = math.cos(phi);
    final nz = math.sin(phi) * math.sin(th);
    var ux = -ny;
    var uy = nx;
    const uz = 0.0;
    final ul = math.max(1e-6, math.sqrt(ux * ux + uy * uy));
    ux /= ul;
    uy /= ul;
    final vx = ny * uz - nz * uy;
    final vy = nz * ux - nx * uz;
    final vz = nx * uy - ny * ux;
    final speed = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1);
    List<double> at(double a) => pt(
      (ux * math.cos(a) + vx * math.sin(a)) * ro,
      (uy * math.cos(a) + vy * math.sin(a)) * ro,
      (uz * math.cos(a) + vz * math.sin(a)) * ro,
    );
    for (var k = 0; k < ghostN; k++) {
      final p = at((k / ghostN) * 2 * math.pi);
      final depth = (p[2] / ro + 1) / 2;
      dots.add(
        OrbDot(
          p[0],
          p[1],
          p[2],
          (o['ghostR'] ?? 0.9) * rs,
          0.72,
          (o['ghostA'] ?? 0.5) * (0.4 + 0.6 * depth),
        ),
      );
    }
    for (var m = 0; m < particles; m++) {
      final p = at(t * speed + (m / particles) * 2 * math.pi + h2 * 6);
      final depth = (p[2] / ro + 1) / 2;
      dots.add(
        OrbDot(
          p[0],
          p[1],
          p[2],
          ((o['partR'] ?? 1.2) + (o['partRDepth'] ?? 1.6) * depth) * rs,
          0.3 - 0.22 * depth,
        ),
      );
    }
  }
  return _finalize(dots, const [], o['rMin']);
}

OrbFrame _globe(double size, double t, OrbOpts o) {
  const spin = 0.5;
  final cx = size / 2, cy = size / 2;
  final radius = (size / 2) * 0.82;
  final tilt = 0.4 + 0.06 * math.sin(t * 0.35);
  final pt = _makeProj(t * spin, tilt, cx, cy, radius);
  final scan = t * (spin + (1.7 - spin) * (o['scanMul'] ?? 1));
  final rs = _rs(size, o['rsPow'] ?? 0.6);
  final dimBase = o['dimBase'] ?? 1;
  final dots = <OrbDot>[];
  final latRings = (o['latRings'] ?? 17).toInt();
  final lonDensity = o['lonDensity'] ?? 44;
  for (var li = 0; li <= latRings; li++) {
    final lat = -math.pi / 2 + (li / latRings) * math.pi;
    final cosLat = math.cos(lat), sinLat = math.sin(lat);
    final lonCount = math.max(1, _jsRound(cosLat.abs() * lonDensity).toInt());
    for (var lj = 0; lj < lonCount; lj++) {
      final lon = (lj / lonCount) * 2 * math.pi;
      final p = pt(cosLat * math.cos(lon), sinLat, cosLat * math.sin(lon));
      final z = p[2];
      final depth = (z + 1) / 2;
      final d = _angleDelta(lon + t * spin, scan);
      final boost = math.exp(-(d * d) / 0.18) * math.max(0, z);
      dots.add(
        OrbDot(
          p[0],
          p[1],
          z,
          ((o['rBase'] ?? 0.6) +
                  (o['rDepth'] ?? 1.7) * depth +
                  (o['rBoost'] ?? 1) * boost) *
              rs,
          (o['inkFar'] ?? 0.62) - (o['inkSpan'] ?? 0.54) * depth,
          dimBase + (1 - dimBase) * math.min(1, boost),
        ),
      );
    }
  }
  return _finalize(dots, const [], o['rMin']);
}

class _Move {
  const _Move(this.axis, this.lo, this.hi, this.ang);
  final int axis;
  final double lo, hi, ang;
}

List<_Move> _makeMoves(int count) => [
  for (var i = 0; i < count; i++)
    () {
      final axis = math.min(2, (_hashD(i.toDouble(), 2.3) * 3).floor());
      final lo =
          -1.0 + 0.5 * math.min(3, (_hashD(i.toDouble(), 5.9) * 4).floor());
      final dir = _hashD(i.toDouble(), 7.7) < 0.5 ? 1 : -1;
      return _Move(axis, lo, lo + 0.5, (dir * math.pi) / 2);
    }(),
];

(List<double>, int) _solveCycle(
  double time,
  int count,
  double slotDur,
  double rest,
) {
  final cyc = 2 * count * slotDur + rest;
  final tc = _jsMod(time, cyc);
  final amount = List<double>.filled(count, 0);
  var active = -1;
  if (tc < 2 * count * slotDur) {
    final slot = (tc / slotDur).floor();
    final p = (tc - slot * slotDur) / slotDur;
    final cl = math.min(1.0, p / 0.7);
    final ep = 1 - math.pow(1 - cl, 3);
    if (slot < count) {
      for (var i = 0; i < slot; i++) {
        amount[i] = 1;
      }
      amount[slot] = ep.toDouble();
      active = slot;
    } else {
      final u = 2 * count - 1 - slot;
      for (var i = 0; i < u; i++) {
        amount[i] = 1;
      }
      amount[u] = 1 - ep.toDouble();
      active = u;
    }
  }
  return (amount, active);
}

OrbFrame _rubik(double size, double t, OrbOpts o) {
  final cx = size / 2, cy = size / 2;
  final R = (size / 2) * 0.82;
  final pt = _makeProj(t * 0.55, 0.35 + 0.1 * math.sin(t * 0.9), cx, cy, R);
  final rs = _rs(size, o['rsPow'] ?? 0.6);
  final moveCount = (o['moveCount'] ?? 14).toInt();
  final moves = _makeMoves(moveCount);
  final (amount, active) = _solveCycle(t, moveCount, 0.42, 1.2);
  final dots = <OrbDot>[];
  final latRings = (o['latRings'] ?? 15).toInt();
  final lonDensity = o['lonDensity'] ?? 40;
  for (var li = 0; li <= latRings; li++) {
    final lat = -math.pi / 2 + (li / latRings) * math.pi;
    final cosLat = math.cos(lat), sinLat = math.sin(lat);
    final lonCount = math.max(1, _jsRound(cosLat.abs() * lonDensity).toInt());
    for (var lj = 0; lj < lonCount; lj++) {
      final lon = (lj / lonCount) * 2 * math.pi;
      var x = cosLat * math.cos(lon), y = sinLat, z = cosLat * math.sin(lon);
      var inActive = false;
      for (var i = 0; i < moves.length; i++) {
        if (amount[i] <= 0) continue;
        final mv = moves[i];
        final coord = mv.axis == 0
            ? x
            : mv.axis == 1
            ? y
            : z;
        if (coord < mv.lo || coord >= mv.hi) continue;
        if (i == active) inActive = true;
        final a = mv.ang * amount[i];
        final ca = math.cos(a), sa = math.sin(a);
        if (mv.axis == 0) {
          final y2 = y * ca - z * sa;
          z = y * sa + z * ca;
          y = y2;
        } else if (mv.axis == 1) {
          final x2 = x * ca + z * sa;
          z = -x * sa + z * ca;
          x = x2;
        } else {
          final x2 = x * ca - y * sa;
          y = x * sa + y * ca;
          x = x2;
        }
      }
      final p = pt(x, y, z);
      final depth = (p[2] + 1) / 2;
      dots.add(
        OrbDot(
          p[0],
          p[1],
          p[2],
          ((o['rBase'] ?? 0.6) +
                  (o['rDepth'] ?? 1.7) * depth +
                  (inActive ? (o['rActive'] ?? 0.3) : 0)) *
              rs,
          (o['inkFar'] ?? 0.62) -
              (o['inkSpan'] ?? 0.54) * depth -
              (inActive ? 0.14 : 0),
        ),
      );
    }
  }
  return _finalize(dots, const [], o['rMin']);
}

OrbFrame _wave(double size, double t, OrbOpts o) {
  final cx = size / 2, cy = size / 2;
  final R = (size / 2) * 0.874;
  final pt = _makeProj(t * 0.18, 0.38, cx, cy, 1);
  final rs = _rs(size, o['rsPow'] ?? 0.6);
  final dots = <OrbDot>[];
  final rings = (o['rings'] ?? 15).toInt();
  final lonDensity = o['lonDensity'] ?? 40;
  for (var ri = 0; ri <= rings; ri++) {
    final lat = -math.pi / 2 + (ri / rings) * math.pi;
    final cosLat = math.cos(lat), sinLat = math.sin(lat);
    final w =
        0.62 * math.sin(t * 2.1 - ri * 0.52) +
        0.38 * math.sin(t * 1.27 + ri * 0.83);
    final rr = R * (0.88 + 0.105 * w);
    final lonCount = math.max(1, _jsRound(cosLat.abs() * lonDensity).toInt());
    for (var lj = 0; lj < lonCount; lj++) {
      final lon = (lj / lonCount) * 2 * math.pi;
      final p = pt(
        cosLat * math.cos(lon) * rr,
        sinLat * rr,
        cosLat * math.sin(lon) * rr,
      );
      final depth = (p[2] / R + 1) / 2;
      final crest = math.max(0.0, w);
      dots.add(
        OrbDot(
          p[0],
          p[1],
          p[2],
          ((o['rBase'] ?? 0.6) + (o['rDepth'] ?? 1.7) * depth) *
              (1 + 0.4 * crest) *
              rs,
          0.66 - 0.56 * depth - 0.1 * crest,
        ),
      );
    }
  }
  return _finalize(dots, const [], o['rMin']);
}

OrbFrame _web(double size, double t, OrbOpts o) {
  final cx = size / 2, cy = size / 2;
  final R = (size / 2) * 0.8 * (o['spread'] ?? 1);
  final pt = _makeProj(t * 0.12, 0.32, cx, cy, R);
  final rs = _rs(size, o['rsPow'] ?? 0.6);
  final nodeN = (o['nodeN'] ?? 30).toInt();
  final thr = o['thr'] ?? 0.72;
  final nodeR = o['nodeR'] ?? 1.4;
  final nodeRDepth = o['nodeRDepth'] ?? 1.8;
  final nodes = <List<double>>[];
  for (var i = 0; i < nodeN; i++) {
    final d = _fibDir(i, nodeN);
    final x = d[0] + 0.3 * (_vnoise(i * 0.31 + 9, t * 0.24) - 0.5) * 2;
    final y = d[1] + 0.3 * (_vnoise(i * 0.53 + 27, t * 0.21) - 0.5) * 2;
    final z = d[2] + 0.3 * (_vnoise(i * 0.77 + 55, t * 0.27) - 0.5) * 2;
    final l = math.sqrt(x * x + y * y + z * z);
    nodes.add([x / l, y / l, z / l]);
  }
  final lines = <OrbLine>[];
  final dots = <OrbDot>[];
  for (var i = 0; i < nodeN; i++) {
    for (var j = i + 1; j < nodeN; j++) {
      final dx = nodes[i][0] - nodes[j][0];
      final dy = nodes[i][1] - nodes[j][1];
      final dz = nodes[i][2] - nodes[j][2];
      final dist = math.sqrt(dx * dx + dy * dy + dz * dz);
      if (dist >= thr) continue;
      final p1 = pt(nodes[i][0], nodes[i][1], nodes[i][2]);
      final p2 = pt(nodes[j][0], nodes[j][1], nodes[j][2]);
      final depth = ((p1[2] + p2[2]) / 2 + 1) / 2;
      lines.add(
        OrbLine(
          p1[0],
          p1[1],
          p2[0],
          p2[1],
          0.42,
          (1 - dist / thr) * (0.3 + 0.55 * depth),
          math.max(0.6, (o['lineW'] ?? 0.8) * rs),
        ),
      );
    }
  }
  for (var i = 0; i < nodeN; i++) {
    final p = pt(nodes[i][0], nodes[i][1], nodes[i][2]);
    final depth = (p[2] + 1) / 2;
    final pulse = 1 + 0.25 * math.sin(t * 1.4 + i * 2.7);
    dots.add(
      OrbDot(
        p[0],
        p[1],
        p[2],
        (nodeR + nodeRDepth * depth) * pulse * rs,
        0.55 - 0.45 * depth,
      ),
    );
  }
  final signals = (o['signals'] ?? 5).toInt();
  for (var s = 0; s < signals; s++) {
    final seg = (t * 0.55 + s * 7.31).floorToDouble();
    final a = (_hashD(seg, s * 3.1 + 1.7) * nodeN).floor();
    final b = (_hashD(seg, s * 5.7 + 4.2) * nodeN).floor();
    if (a == b) continue;
    final f = _frac(t * 0.55 + s * 7.31);
    final x = _lerp(nodes[a][0], nodes[b][0], f);
    final y = _lerp(nodes[a][1], nodes[b][1], f);
    final z = _lerp(nodes[a][2], nodes[b][2], f);
    final l = math.max(1e-6, math.sqrt(x * x + y * y + z * z));
    final p = pt(x / l, y / l, z / l);
    final depth = (p[2] + 1) / 2;
    dots.add(
      OrbDot(
        p[0],
        p[1],
        p[2],
        (nodeR * 1.5 + nodeRDepth * depth) * rs,
        0.05,
        0.5 + 0.5 * depth,
      ),
    );
  }
  return _finalize(dots, lines, o['rMin']);
}

void _ghostSphere(
  List<OrbDot> dots,
  int ghostN,
  double R,
  _Proj pt,
  double rs,
) {
  for (var i = 0; i < ghostN; i++) {
    final d = _fibDir(i, ghostN);
    final p = pt(d[0] * R, d[1] * R, d[2] * R);
    final depth = (p[2] / R + 1) / 2;
    dots.add(OrbDot(p[0], p[1], p[2], 0.8 * rs, 0.78, 0.1 + 0.22 * depth));
  }
}

OrbFrame _braid(double size, double t, OrbOpts o) {
  final cx = size / 2, cy = size / 2;
  final R = (size / 2) * 0.76;
  final pt = _makeProj(t * 0.4, 0.3, cx, cy, 1);
  final rs = _rs(size, o['rsPow'] ?? 0.6);
  final dots = <OrbDot>[];
  _ghostSphere(dots, (o['ghostN'] ?? 150).toInt(), R, pt, rs);
  final strandN = (o['strandN'] ?? 52).toInt();
  final turns = o['turns'] ?? 3;
  for (var s = 0; s < 3; s++) {
    final phase = (s / 3) * 2 * math.pi;
    for (var i = 0; i < strandN; i++) {
      final u = (_frac(i / strandN + t * 0.045) * 2 - 1) * 0.96;
      final surf = math.sqrt(math.max(0, 1 - u * u));
      final endFade = math.min(1.0, (1 - u.abs()) / 0.1);
      final a = u * math.pi * turns + phase;
      final weave =
          1 + 0.075 * math.sin(u * math.pi * turns * 2 + phase * 2 + t * 0.8);
      final rr = surf * R * weave;
      final p = pt(math.cos(a) * rr, u * R * weave, math.sin(a) * rr);
      final depth = (p[2] / R + 1) / 2;
      dots.add(
        OrbDot(
          p[0],
          p[1],
          p[2],
          ((o['rBase'] ?? 1.2) + (o['rDepth'] ?? 1.8) * depth) * rs,
          0.55 - 0.45 * depth,
          endFade * (0.45 + 0.55 * depth),
        ),
      );
    }
  }
  return _finalize(dots, const [], o['rMin']);
}

OrbFrame _ribbon(double size, double t, OrbOpts o) {
  final cx = size / 2, cy = size / 2;
  final R = (size / 2) * 0.78;
  final spin = o['spin'] ?? 1;
  const camTilt = 0.3;
  final pt = _makeProj(t * 0.1 * spin, camTilt, cx, cy, 1);
  final rs = _rs(size, o['rsPow'] ?? 0.6);
  final dots = <OrbDot>[];
  _ghostSphere(dots, (o['ghostN'] ?? 150).toInt(), R, pt, rs);
  final faceOn = (o['faceOn'] ?? 0) != 0;
  final ya = t * 0.24 * spin;
  final ta = faceOn ? -camTilt : 0.55 + 0.3 * math.sin(t * 0.18) * spin;
  final ux = math.cos(ya);
  const uy = 0.0;
  final uz = math.sin(ya);
  final vx = -uz * math.sin(ta);
  final vy = math.cos(ta);
  final vz = ux * math.sin(ta);
  final nx = uy * vz - uz * vy;
  final ny = uz * vx - ux * vz;
  final nz = ux * vy - uy * vx;
  final wobMul = o['wobMul'] ?? 1;
  final wobAmp = 0.23 * wobMul;
  final baseR = faceOn ? R / (1 + 0.85 * wobAmp) : R;
  final baseLanes = o['lanes'] ?? 5;
  final segs = (o['segs'] ?? 88).toInt();
  final lanes = math.max(1, _jsRound(baseLanes * (o['bandMul'] ?? 1)).toInt());
  for (var w = 0; w < lanes; w++) {
    final laneOff = (w - (lanes - 1) / 2) * 0.075;
    final edge = (w - (lanes - 1) / 2).abs() / math.max(1, (lanes - 1) / 2);
    for (var k = 0; k < segs; k++) {
      final a = (k / segs) * 2 * math.pi;
      final wob =
          (0.16 * math.sin(a * 3 - t * 1.7 + w * 0.22) +
              0.07 * math.sin(a * 5 + t * 1.1)) *
          wobMul;
      final radial = faceOn ? 1 + wob : 1.0;
      final off = faceOn ? laneOff : laneOff + wob;
      final x = ux * math.cos(a) + vx * math.sin(a) + nx * off;
      final y = uy * math.cos(a) + vy * math.sin(a) + ny * off;
      final z = uz * math.cos(a) + vz * math.sin(a) + nz * off;
      final l = math.sqrt(x * x + y * y + z * z);
      final rr = baseR * radial;
      final p = pt((x / l) * rr, (y / l) * rr, (z / l) * rr);
      final depth = (p[2] / R + 1) / 2;
      dots.add(
        OrbDot(
          p[0],
          p[1],
          p[2],
          ((o['rBase'] ?? 1.1) + (o['rDepth'] ?? 1.7) * depth) *
              (1 - 0.25 * edge) *
              rs,
          0.52 - 0.44 * depth + 0.18 * edge,
          0.4 + 0.6 * depth,
        ),
      );
    }
  }
  return _finalize(dots, const [], o['rMin']);
}

typedef _Path = List<double> Function(double f);

_Path _polyPath(List<List<double>> verts) {
  final v = verts.length;
  final lens = <double>[];
  var total = 0.0;
  for (var i = 0; i < v; i++) {
    final a = verts[i], b = verts[(i + 1) % v];
    final l = math.sqrt(math.pow(b[0] - a[0], 2) + math.pow(b[1] - a[1], 2));
    lens.add(l);
    total += l;
  }
  return (f) {
    var target = f * total;
    var i = 0;
    while (target > lens[i] && i < v - 1) {
      target -= lens[i];
      i++;
    }
    final a = verts[i], b = verts[(i + 1) % v];
    final ff = lens[i] != 0 ? math.min(1.0, target / lens[i]) : 0.0;
    return [a[0] + (b[0] - a[0]) * ff, a[1] + (b[1] - a[1]) * ff];
  };
}

final List<_Path> _cycle = [
  (f) {
    final a = -math.pi / 2 + f * 2 * math.pi;
    return [math.cos(a) * 0.24, math.sin(a) * 0.24];
  },
  _polyPath([
    [0.0, -0.26],
    [0.24, 0.16],
    [-0.24, 0.16],
  ]),
  _polyPath([
    [0, -0.2],
    [0.2, -0.2],
    [0.2, 0.2],
    [-0.2, 0.2],
    [-0.2, -0.2],
  ]),
];

OrbFrame _morph(double size, double t, OrbOpts o) {
  const hold = 1.4, morph = 0.9, seg = hold + morph;
  final kk = _cycle.length;
  final tc = _jsMod(t, seg * kk);
  final shape = o['shape'];
  final held = shape != null && shape >= 0 && shape < kk ? shape.floor() : -1;
  final k = held >= 0 ? held : (tc / seg).floor();
  final local = held >= 0 ? _jsMod(t, seg) : tc - k * seg;
  double smooth(double x) => x * x * (3 - 2 * x);
  final m = held >= 0
      ? 0.0
      : local > hold
      ? smooth((local - hold) / morph)
      : 0.0;
  final sprd = o['spread'] ?? 1;
  final pA = _cycle[k];
  final pB = held >= 0 ? pA : _cycle[(k + 1) % kk];
  const mm = 160;
  final pts = <List<double>>[];
  for (var i = 0; i < mm; i++) {
    final f = i / mm;
    final a = pA(f), b = pB(f);
    pts.add([
      (a[0] + (b[0] - a[0]) * m) * sprd,
      (a[1] + (b[1] - a[1]) * m) * sprd,
    ]);
  }
  final lens = <double>[];
  var total = 0.0;
  for (var i = 0; i < mm; i++) {
    final a = pts[i], b = pts[(i + 1) % mm];
    final l = math.sqrt(math.pow(b[0] - a[0], 2) + math.pow(b[1] - a[1], 2));
    lens.add(l);
    total += l;
  }
  final n = math.max(6, _jsRound(34 * (o['iconD'] ?? 1)).toInt());
  final re = (o['rDot'] ?? 0.021) * 1.35 * sprd;
  final pulse = 1 + 0.02 * math.sin(local * 3.1);
  final dots = <OrbDot>[];
  final c2 = size / 2;
  var sg = 0;
  var acc = 0.0;
  for (var k2 = 0; k2 < n; k2++) {
    final target = (k2 / n) * total;
    while (acc + lens[sg] < target && sg < mm - 1) {
      acc += lens[sg];
      sg++;
    }
    final a = pts[sg], b = pts[(sg + 1) % mm];
    final f = lens[sg] != 0 ? math.min(1.0, (target - acc) / lens[sg]) : 0.0;
    final x = (a[0] + (b[0] - a[0]) * f) * pulse;
    final y = (a[1] + (b[1] - a[1]) * f) * pulse;
    dots.add(
      OrbDot(c2 + x * size, c2 + y * size, 0, math.max(0.35, re * size), 0.1),
    );
  }
  return _finalize(dots, const [], o['rMin']);
}
