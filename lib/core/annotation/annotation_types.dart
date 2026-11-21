// Source-compatible value types for Dash annotation composition.
// Normalized coordinates are screen fractions; times are epoch milliseconds.
// This module intentionally has no Flutter dependencies.

final class StrokePoint {
  const StrokePoint({
    required this.x,
    required this.y,
    required this.p,
    required this.t,
  });

  final double x;
  final double y;
  final double p;
  final int t;
}

final class Stroke {
  const Stroke({
    required this.id,
    required this.tool,
    required this.color,
    required this.pointer,
    required this.points,
    required this.startedAt,
    required this.endedAt,
    this.targets,
  });

  final int id;
  final String tool;
  final String color;
  final String pointer;
  final List<StrokePoint> points;
  final int startedAt;
  final int endedAt;
  final List<String>? targets;
}

final class Segment {
  const Segment({
    required this.id,
    required this.text,
    required this.start,
    required this.end,
    required this.source,
  });

  final String id;
  final String text;
  final int start;
  final int end;
  final String source;

  Map<String, Object> toJson() => {
    'id': id,
    'text': text,
    'start': start,
    'end': end,
    'source': source,
  };
}

final class ScreenInfo {
  const ScreenInfo({
    required this.id,
    required this.route,
    required this.width,
    required this.height,
  });

  final String id;
  final String route;
  final num width;
  final num height;

  Map<String, Object> toJson() => {
    'id': id,
    'route': route,
    'width': width,
    'height': height,
  };
}

class CircleRegion {
  const CircleRegion({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final num x;
  final num y;
  final num width;
  final num height;

  Map<String, num> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };
}

final class VisibleTextBox extends CircleRegion {
  const VisibleTextBox({
    required super.x,
    required super.y,
    required super.width,
    required super.height,
    required this.text,
  });

  final String text;
}
