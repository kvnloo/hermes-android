// Pure Dart port of Dash's transcript-to-stroke alignment.
import 'dart:math' as math;

import 'annotation_types.dart';

const int alignSlackMs = 3000;

String marker(int id) => '⟦stroke $id⟧';

/// First containing segment, otherwise the minimum-gap segment within 3s.
/// Input order decides ties, matching Dash's first-match semantics.
Segment? segmentFor(Stroke stroke, List<Segment> segments) {
  for (final segment in segments) {
    if (stroke.startedAt >= segment.start &&
        stroke.startedAt <= segment.end) {
      return segment;
    }
  }

  Segment? best;
  num bestGap = double.infinity;
  for (final segment in segments) {
    final gap = math.max(
      0,
      math.max(
        segment.start - stroke.endedAt,
        stroke.startedAt - segment.end,
      ),
    );
    if (gap <= alignSlackMs && gap < bestGap) {
      best = segment;
      bestGap = gap;
    }
  }
  return best;
}

/// One-based word slot after which the stroke marker should be inserted.
int wordSlot(Segment segment, int words, int at) {
  if (words == 0) return 0;
  final span = segment.end - segment.start;
  final k = span <= 0 ? 1.0 : (at - segment.start) / span;
  final clamped = k.clamp(0.0, 1.0);
  final slot = (clamped * words).ceil();
  if (slot < 1) return 1;
  if (slot > words) return words;
  return slot;
}

final class TranscriptAlignment {
  const TranscriptAlignment({required this.text, required this.unspoken});

  final String text;
  final List<int> unspoken;
}

/// Sorts nonblank segments by start (stably), and retains input stroke order
/// within each segment and among the unspoken markers.
TranscriptAlignment annotateTranscript(
  List<Stroke> strokes,
  List<Segment> segments,
) {
  final ordered = <({int index, Segment segment})>[];
  for (var i = 0; i < segments.length; i++) {
    if (segments[i].text.trim().isNotEmpty) {
      ordered.add((index: i, segment: segments[i]));
    }
  }
  ordered.sort((a, b) {
    final byStart = a.segment.start.compareTo(b.segment.start);
    return byStart != 0 ? byStart : a.index.compareTo(b.index);
  });
  final usable = ordered.map((entry) => entry.segment).toList();

  final bySegment = <String, List<Stroke>>{};
  final unspoken = <int>[];
  for (final stroke in strokes) {
    final segment = segmentFor(stroke, usable);
    if (segment == null) {
      unspoken.add(stroke.id);
    } else {
      bySegment.putIfAbsent(segment.id, () => <Stroke>[]).add(stroke);
    }
  }

  final parts = <String>[];
  for (final segment in usable) {
    final words = segment.text.trim().split(RegExp(r'\s+'));
    final after = <int, List<int>>{};
    for (final stroke in bySegment[segment.id] ?? <Stroke>[]) {
      final slot = wordSlot(segment, words.length, stroke.startedAt);
      after.putIfAbsent(slot, () => <int>[]).add(stroke.id);
    }

    final marked = <String>[];
    for (var i = 0; i < words.length; i++) {
      marked.add(words[i]);
      for (final id in after[i + 1] ?? <int>[]) {
        marked.add(marker(id));
      }
    }
    parts.add(marked.join(' '));
  }

  return TranscriptAlignment(text: parts.join(' '), unspoken: unspoken);
}
