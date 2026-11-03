import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/annotation/annotation_types.dart';
import 'package:hermes_android/core/annotation/annotation_voice_segments.dart';
import 'package:hermes_android/core/controllers/voice_composer_controller.dart';

import 'support/fake_voice_composer_adapter.dart';

void main() {
  testWidgets('held speech commits one timed segment with last stop result', (
    tester,
  ) async {
    final text = TextEditingController();
    final adapter = FakeVoiceComposerAdapter(
      finalTranscriptOnStop: 'make this taller',
    );
    final composer = VoiceComposerController(
      textController: text,
      adapter: adapter,
    );
    var now = 10000;
    final history = AnnotationVoiceSegments(
      composer: composer,
      clock: () => now,
    );
    addTearDown(composer.dispose);
    addTearDown(text.dispose);

    expect(await history.begin(), isTrue);
    adapter.emitPartial('make this');
    expect(history.recording, isTrue);
    now += 400;
    final segment = await history.end();
    expect(segment, isNotNull);
    expect(segment!.text, 'make this taller');
    expect(segment.start, 10000);
    expect(segment.end, 10400);
    expect(segment.source, 'mic');
    expect(adapter.listenCount, 1);
    expect(adapter.stopCount, 1);
    expect(history.recording, isFalse);

    final stroke = Stroke(
      id: 2,
      tool: 'pen',
      color: 'accent',
      pointer: 'stylus',
      points: const [StrokePoint(x: .3, y: .4, p: .5, t: 10250)],
      startedAt: 10250,
      endedAt: 10250,
    );
    final aligned = history.alignedWith([stroke]);
    expect(aligned.text, contains('⟦stroke 2⟧'));
    expect(aligned.unspoken, isEmpty);
    expect(history.segments.length, 1);

    history.removeSubmitted([segment]);
    expect(history.segments, isEmpty);
  });

  testWidgets('cancel ignores partial result and does not append a segment', (
    tester,
  ) async {
    final text = TextEditingController();
    final adapter = FakeVoiceComposerAdapter();
    final composer = VoiceComposerController(
      textController: text,
      adapter: adapter,
    );
    final history = AnnotationVoiceSegments(composer: composer, clock: () => 1);
    addTearDown(composer.dispose);
    addTearDown(text.dispose);

    expect(await history.begin(), isTrue);
    adapter.emitPartial('not committed');
    await history.cancel();
    expect(await history.end(), isNull);
    expect(history.segments, isEmpty);
    expect(text.text, '');
    expect(adapter.cancelCount, 1);
  });

  testWidgets('empty speech does not create a segment', (tester) async {
    final text = TextEditingController();
    final adapter = FakeVoiceComposerAdapter();
    final composer = VoiceComposerController(
      textController: text,
      adapter: adapter,
    );
    final history = AnnotationVoiceSegments(composer: composer, clock: () => 50);
    addTearDown(composer.dispose);
    addTearDown(text.dispose);

    await history.begin();
    expect(await history.end(), isNull);
    expect(history.segments, isEmpty);
  });

  testWidgets('new microphone speech preserves old and trims aged segments', (
    tester,
  ) async {
    final text = TextEditingController();
    final adapter = FakeVoiceComposerAdapter();
    final composer = VoiceComposerController(
      textController: text,
      adapter: adapter,
    );
    final history = AnnotationVoiceSegments(composer: composer);
    addTearDown(composer.dispose);
    addTearDown(text.dispose);

    const old = Segment(
      id: 'old',
      text: 'old',
      start: 0,
      end: 10,
      source: 'mic',
    );
    const newSegment = Segment(
      id: 'new',
      text: 'new words',
      start: 700010,
      end: 700100,
      source: 'voice',
    );
    history.add(old);
    history.add(newSegment);
    expect(history.segments.map((s) => s.id), ['new']);
    history.add(
      const Segment(
        id: 'new',
        text: 'corrected words',
        start: 700010,
        end: 700150,
        source: 'voice',
      ),
    );
    expect(history.segments.length, 1);
    expect(history.segments.single.text, 'corrected words');
  });
}
