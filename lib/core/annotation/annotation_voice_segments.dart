import 'annotation_align.dart';
import 'annotation_types.dart';

import '../controllers/voice_composer_controller.dart';

/// A single annotation tray's timed microphone history. The normal composer
/// controller owns recognition and interim text; this layer records final
/// words and epoch-millisecond intervals for the parent's stroke alignment.
class AnnotationVoiceSegments {
  AnnotationVoiceSegments({
    required this.composer,
    int Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final VoiceComposerController composer;
  final int Function() _clock;
  final List<Segment> _segments = [];
  int _sequence = 0;
  int? _startedAt;
  Future<bool>? _startFlight;
  bool _releasing = false;

  List<Segment> get segments => List<Segment>.unmodifiable(_segments);
  bool get recording => _startedAt != null;

  Future<bool> begin({String? localeId}) {
    if (_startedAt != null || _releasing) return Future.value(false);
    final started = _startedAt = _clock();
    composer.textController.clear();
    final flight = composer.start(localeId: localeId);
    _startFlight = flight;
    return flight.then((success) {
      if (!success && _startedAt == started) _startedAt = null;
      return success;
    }, onError: (Object error, StackTrace trace) {
      if (_startedAt == started) _startedAt = null;
      Error.throwWithStackTrace(error, trace);
    }).whenComplete(() {
      if (identical(_startFlight, flight)) _startFlight = null;
    });
  }

  Future<Segment?> end() async {
    final start = _startedAt;
    if (start == null || _releasing) return null;
    _releasing = true;
    try {
      await _startFlight;
      if (_startedAt != start) return null;
      await composer.stop();
      await composer.settle();
      final words = composer.textController.text.trim();
      if (words.isEmpty) return null;
      final end = _clock();
      final segment = Segment(
        id: 'mic-' + start.toString() + '-' + (_sequence++).toString(),
        text: words,
        start: start,
        end: end < start ? start : end,
        source: 'mic',
      );
      add(segment);
      return segment;
    } finally {
      _startedAt = null;
      _releasing = false;
    }
  }

  Future<void> cancel() async {
    _startedAt = null;
    await composer.cancel();
    await composer.settle();
    composer.textController.clear();
  }

  /// Also accepts already-timed hands-free segments without retranscribing.
  /// Stale segments age out after ten minutes, matching the Dash session.
  void add(Segment segment) {
    final horizon = segment.end - 10 * 60 * 1000;
    _segments.removeWhere(
      (existing) => existing.id == segment.id || existing.end < horizon,
    );
    _segments.add(segment);
  }

  TranscriptAlignment alignedWith(List<Stroke> strokes) =>
      annotateTranscript(strokes, _segments);

  /// Only remove segments included in the confirmed submission. New voice
  /// recorded while the attachment was uploading must survive.
  void removeSubmitted(Iterable<Segment> submitted) {
    final ids = submitted.map((segment) => segment.id).toSet();
    _segments.removeWhere((segment) => ids.contains(segment.id));
  }

  void clear() => _segments.clear();
}
