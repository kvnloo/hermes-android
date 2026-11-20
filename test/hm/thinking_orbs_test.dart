// The Dart orb engine must reproduce thinking-orbs' golden vectors (the same
// fixture the upstream Swift port is held to): every dot and line of 9 states
// x 2 sizes x 4 frozen times, within the spec tolerance.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/avatar/thinking_orbs.dart';

void main() {
  final golden = jsonDecode(
    File('test/hm/fixtures/thinking-orbs-golden.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final tol = (golden['tolerance'] as num).toDouble();

  test('presets resolve to the upstream options', () {
    final resolved = golden['resolved'] as Map<String, dynamic>;
    for (final entry in resolved.entries) {
      final parts = entry.key.split('-');
      final r = resolveOrb(OrbState.values.byName(parts[0]), int.parse(parts[1]));
      final want = entry.value as Map<String, dynamic>;
      expect(r.mode, want['mode'], reason: entry.key);
      expect(r.speed, closeTo((want['speed'] as num).toDouble(), tol), reason: entry.key);
      final opts = (want['opts'] as Map<String, dynamic>).map((k, v) => MapEntry(k, (v as num).toDouble()));
      expect(r.opts.keys.toSet(), opts.keys.toSet(), reason: entry.key);
      for (final k in opts.keys) {
        expect(r.opts[k], closeTo(opts[k]!, tol), reason: '${entry.key}.$k');
      }
    }
  });

  for (final c in (golden['cases'] as List).cast<Map<String, dynamic>>()) {
    test('frame ${c['key']}', () {
      final state = OrbState.values.byName(c['state'] as String);
      final size = c['size'] as int;
      final r = resolveOrb(state, size);
      final f = orbFrame(r.mode, size.toDouble(), (c['t'] as num).toDouble(), r.opts);
      final dots = (c['dots'] as List).cast<num>();
      final lines = (c['lines'] as List).cast<num>();
      expect(f.dots.length, c['dotCount']);
      expect(f.lines.length, c['lineCount']);
      // Draw order must match, except among dots tied in depth: their
      // relative order hangs on last-bit differences between Dart's and
      // V8's sin/cos, and tied dots paint at the same depth anyway. So
      // compare each run of equal-z golden dots as a set.
      List<double> got(int i) {
        final d = f.dots[i];
        return [d.x, d.y, d.z, d.r, d.white, d.a];
      }

      bool same(List<double> a, int w) {
        for (var j = 0; j < 6; j++) {
          if ((a[j] - dots[w * 6 + j]).abs() > tol) return false;
        }
        return true;
      }

      var i = 0;
      while (i < f.dots.length) {
        var end = i + 1;
        while (end < f.dots.length && (dots[end * 6 + 2] - dots[i * 6 + 2]).abs() <= tol) {
          end++;
        }
        final unused = {for (var g = i; g < end; g++) g};
        for (var w = i; w < end; w++) {
          final hit = unused.where((g) => same(got(g), w)).firstOrNull;
          expect(hit, isNotNull, reason: 'golden dot $w has no match in its depth run [$i, $end)');
          unused.remove(hit);
        }
        i = end;
      }
      for (var i = 0; i < f.lines.length; i++) {
        final l = f.lines[i];
        final got = [l.x1, l.y1, l.x2, l.y2, l.white, l.a, l.w];
        for (var j = 0; j < 7; j++) {
          expect(got[j], closeTo(lines[i * 7 + j].toDouble(), tol), reason: 'line $i field $j');
        }
      }
    });
  }
}
