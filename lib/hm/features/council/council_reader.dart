// Read aloud for the council screen: the brief, then each seat's report, then
// the verdict, one sentence at a time so the speaking orb can caption it.
// Speech goes through the app's existing read-aloud engine (flutter_tts,
// Classic's voice prefs); nothing here records audio or calls a provider.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../nextgen/data/read_aloud.dart';
import 'council_run.dart';

/// Speaks one sentence. Completes when it finished (true), or when it was
/// stopped or could not play (false).
abstract class CouncilVoice {
  Future<bool> speak(String text);
  Future<void> stop();
  void dispose();
}

/// [CouncilVoice] over [NgReadAloud], which owns one TTS engine.
class ReadAloudCouncilVoice implements CouncilVoice {
  ReadAloudCouncilVoice([NgReadAloud? engine])
    : _engine = engine ?? NgReadAloud();
  final NgReadAloud _engine;
  int _n = 0;

  @override
  Future<bool> speak(String text) async {
    final key = 'council-${_n++}';
    var failed = false;
    _engine.onUnavailable = () => failed = true;
    await _engine.read(key, text);
    // Off Android the engine's completion arrives on a side channel after
    // read() returns; wait for it to release this sentence.
    if (_engine.isReading(key)) {
      final done = Completer<void>();
      void check() {
        if (!_engine.isReading(key) && !done.isCompleted) done.complete();
      }

      _engine.addListener(check);
      await done.future;
      _engine.removeListener(check);
    }
    return !failed;
  }

  @override
  Future<void> stop() => _engine.stop();

  @override
  void dispose() => _engine.dispose();
}

class CouncilReader extends ChangeNotifier {
  CouncilReader(this.run, this.voice) : passages = councilPassages(run);

  final CouncilRun run;
  final CouncilVoice voice;
  final List<CouncilPassage> passages;
  int _generation = 0;
  bool _disposed = false;

  CouncilPassage? _passage;
  String _caption = '';
  String? _warning;

  /// The passage being read, or null when the screen shows the card.
  CouncilPassage? get passage => _passage;
  bool get reading => _passage != null;

  /// The sentence being spoken.
  String get caption => _caption;

  /// Set when speech could not play; the text stays usable.
  String? get warning => _warning;

  bool isReading(String key) => _passage?.key == key;

  /// Reads every passage in order.
  Future<void> readAll() => _read(passages);

  /// Reads one passage, e.g. one seat's report through its own orb.
  Future<void> readOne(String key) => _read([
    for (final p in passages)
      if (p.key == key) p,
  ]);

  Future<void> _read(List<CouncilPassage> list) async {
    await stop();
    if (_disposed) return;
    final g = ++_generation;
    _warning = null;
    for (final p in list) {
      for (final s in councilSentences(p.text)) {
        if (_disposed || g != _generation) return;
        _passage = p;
        _caption = s;
        notifyListeners();
        final ok = await voice.speak(s);
        if (_disposed || g != _generation) return;
        if (!ok) {
          _warning =
              'Read aloud is unavailable on this device. The council is still '
              'here as text.';
          _end();
          return;
        }
      }
    }
    _end();
  }

  void _end() {
    _passage = null;
    _caption = '';
    notifyListeners();
  }

  /// Cancels reading and returns to the card.
  Future<void> stop() async {
    _generation++;
    if (_passage != null && !_disposed) _end();
    try {
      await voice.stop();
    } catch (_) {
      // A failed stop must not block the next read.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    unawaited(voice.stop().catchError((Object _) {}));
    super.dispose();
  }
}
