// Pure Dart port of Dash annotation document, message and loop composition.
import 'dart:math' as math;

import 'annotation_align.dart';
import 'annotation_types.dart';

export 'annotation_align.dart';
export 'annotation_types.dart';

const String annotationSchema = 'dash.annotation.v1';

/// JS Math.round semantics: ties go toward positive infinity, including
/// negative half values. Avoid Dart's round(), which rounds ties away from zero.
double _jsRound(num value, int places) {
  final scale = math.pow(10, places).toDouble();
  final scaled = value * scale;
  if (!scaled.isFinite) return scaled.toDouble();
  return (scaled + 0.5).floor() / scale;
}

/// Produces the dash.annotation.v1 wire document, with normalized x/y rounded
/// to four places and pressure rounded to two. Stroke and segment order remains
/// unchanged; only the aligned transcript is chronologically reordered.
Map<String, dynamic> annotationDoc({
  required List<Stroke> strokes,
  required List<Segment> segments,
  required ScreenInfo screen,
  required int createdAt,
}) {
  final alignment = annotateTranscript(strokes, segments);
  return {
    'schema': annotationSchema,
    'createdAt': createdAt,
    'screen': screen.toJson(),
    'strokes': strokes.map((stroke) {
      final segment = segmentFor(stroke, segments);
      return <String, Object?>{
        'id': stroke.id,
        'tool': stroke.tool,
        'color': stroke.color,
        'pointer': stroke.pointer,
        'startedAt': stroke.startedAt,
        'endedAt': stroke.endedAt,
        'targets': stroke.targets ?? <String>[],
        if (segment != null) 'segment': segment.id,
        'points': stroke.points
            .map(
              (point) => <num>[
                _jsRound(point.x, 4),
                _jsRound(point.y, 4),
                _jsRound(point.p, 2),
                point.t - stroke.startedAt,
              ],
            )
            .toList(),
      };
    }).toList(),
    'transcript': {
      'text': alignment.text,
      'segments': segments.map((segment) => segment.toJson()).toList(),
    },
  };
}

/// The two upload names use JS Date.toISOString's UTC millisecond precision.
Map<String, String> attachmentNames(int createdAt) {
  final stamp = DateTime.fromMillisecondsSinceEpoch(
    createdAt,
    isUtc: true,
  ).toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
  return {
    'image': 'annotation-$stamp.png',
    'json': 'annotation-$stamp.json',
  };
}

/// Center of the point bounding box in rounded whole-screen percentages.
/// Dash produces NaN coordinates for an empty set of points.
List<double> strokeCenter(List<StrokePoint> points) {
  if (points.isEmpty) return <double>[double.nan, double.nan];
  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = double.negativeInfinity;
  var maxY = double.negativeInfinity;
  for (final point in points) {
    minX = math.min(minX, point.x);
    minY = math.min(minY, point.y);
    maxX = math.max(maxX, point.x);
    maxY = math.max(maxY, point.y);
  }
  return <double>[
    _jsRound((minX + maxX) * 50, 0),
    _jsRound((minY + maxY) * 50, 0),
  ];
}

String strokeLegend(List<Stroke> strokes) {
  return strokes.map((stroke) {
    final center = strokeCenter(stroke.points);
    final red = stroke.color == 'red' ? ' (red)' : '';
    final targets = stroke.targets;
    final on = targets != null && targets.isNotEmpty
        ? ' on ${targets.join(', ')}'
        : '';
    return '${marker(stroke.id)} ${stroke.tool}$red at '
        '${center[0].toStringAsFixed(0)}%,${center[1].toStringAsFixed(0)}%$on';
  }).join('\n');
}

/// Renders the attachment-bearing chat message, not an attachment or send.
String composeMessage({
  required List<Stroke> strokes,
  required List<Segment> segments,
  required ScreenInfo screen,
  String? typed,
}) {
  final alignment = annotateTranscript(strokes, segments);
  final said = <String>[
    if (typed != null && typed.trim().isNotEmpty) typed.trim(),
    if (alignment.text.isNotEmpty) alignment.text,
  ].join('\n');
  final count = strokes.length;
  final plural = count == 1 ? '' : 's';
  final head = 'Annotated ${screen.route} ($count stroke$plural). '
      'Screenshot with the marks and the strokes JSON are attached.';
  final silent = alignment.unspoken.isNotEmpty
      ? '\nAlso marked without speaking: ${alignment.unspoken.map(marker).join(' ')}'
      : '';
  final body = said.isNotEmpty ? '$said$silent' : '';
  final legend = count > 0 ? strokeLegend(strokes) : '';
  return <String>[
    head,
    if (body.isNotEmpty) body,
    if (legend.isNotEmpty) legend,
  ].join('\n\n');
}

String annotationSendMode(bool steerable) => steerable ? 'steer' : 'queue';

/// Returns a padded screen-DIP crop for a substantial closed stylus loop.
/// A pen needs eight points and must close; recognized boxes/circles need two.
CircleRegion? closedPenLoopRegion(
  Stroke stroke,
  ScreenInfo screen, {
  num padding = 12,
}) {
  if (stroke.pointer != 'stylus' ||
      !<String>['pen', 'circle', 'box'].contains(stroke.tool)) {
    return null;
  }
  if (!screen.width.isFinite ||
      !screen.height.isFinite ||
      screen.width <= 0 ||
      screen.height <= 0 ||
      !padding.isFinite ||
      padding < 0) {
    return null;
  }
  final points = stroke.points;
  if (points.length < (stroke.tool == 'pen' ? 8 : 2)) return null;
  if (points.any((point) => !point.x.isFinite || !point.y.isFinite)) {
    return null;
  }

  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = double.negativeInfinity;
  var maxY = double.negativeInfinity;
  for (final point in points) {
    minX = math.min(minX, point.x);
    minY = math.min(minY, point.y);
    maxX = math.max(maxX, point.x);
    maxY = math.max(maxY, point.y);
  }

  final extentX = (maxX - minX) * screen.width;
  final extentY = (maxY - minY) * screen.height;
  if (extentX < 32 || extentY < 32) return null;

  if (stroke.tool == 'pen') {
    final first = points.first;
    final last = points.last;
    final dx = (first.x - last.x) * screen.width;
    final dy = (first.y - last.y) * screen.height;
    final endGap = math.sqrt(dx * dx + dy * dy);
    final diagonal = math.sqrt(extentX * extentX + extentY * extentY);
    if (endGap > math.max(12, diagonal * 0.2)) return null;
  }

  final leftDip = minX * screen.width - padding;
  final topDip = minY * screen.height - padding;
  final rightDip = maxX * screen.width + padding;
  final bottomDip = maxY * screen.height + padding;
  if (!leftDip.isFinite ||
      !topDip.isFinite ||
      !rightDip.isFinite ||
      !bottomDip.isFinite) {
    return null;
  }
  final x = math.max(0, leftDip.floor());
  final y = math.max(0, topDip.floor());
  final right = math.min(screen.width.ceil(), rightDip.ceil());
  final bottom = math.min(screen.height.ceil(), bottomDip.ceil());
  if (right <= x || bottom <= y) return null;
  return CircleRegion(x: x, y: y, width: right - x, height: bottom - y);
}

/// Returns only nonempty visible box texts with centers inside the region.
/// Boxes are checked in input order, including centers on crop boundaries.
String visibleTextInRegion(CircleRegion region, List<VisibleTextBox> boxes) {
  final lines = <String>[];
  for (final box in boxes) {
    final text = box.text.trim();
    if (text.isEmpty ||
        !box.x.isFinite ||
        !box.y.isFinite ||
        !box.width.isFinite ||
        !box.height.isFinite ||
        box.width <= 0 ||
        box.height <= 0) {
      continue;
    }
    final cx = box.x + box.width / 2;
    final cy = box.y + box.height / 2;
    if (cx >= region.x &&
        cx <= region.x + region.width &&
        cy >= region.y &&
        cy <= region.y + region.height) {
      lines.add(text);
    }
  }
  return lines.join('\n');
}

/// Adds text to a local draft only; no turn or steer is sent by this function.
String circleDraftText(String existing, String route, String visibleText) {
  final visible = visibleText.trim();
  final caption = visible.isNotEmpty
      ? 'Circled on $route:\n$visible'
      : 'Circled on $route.';
  final previous = existing.trimRight();
  return previous.isNotEmpty ? '$previous\n\n$caption' : caption;
}
