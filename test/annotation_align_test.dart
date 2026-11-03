import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/annotation/annotation_align.dart';
import 'package:hermes_android/core/annotation/annotation_types.dart';

Segment segment(
  String id,
  String text,
  int start,
  int end, {
  String source = 'mic',
}) => Segment(
  id: id,
  text: text,
  start: start,
  end: end,
  source: source,
);

Stroke stroke(
  int id,
  int startedAt, {
  int? endedAt,
}) => Stroke(
  id: id,
  tool: 'pen',
  color: 'accent',
  pointer: 'stylus',
  points: const <StrokePoint>[
    StrokePoint(x: 0.1, y: 0.2, p: 0.5, t: 0),
    StrokePoint(x: 0.3, y: 0.4, p: 0.5, t: 10),
  ],
  startedAt: startedAt,
  endedAt: endedAt ?? startedAt + 10,
);

void main() {
  group('segmentFor', () {
    test('marker format and empty input', () {
      expect(marker(14), '⟦stroke 14⟧');
      expect(segmentFor(stroke(1, 250), <Segment>[]), isNull);
    });

    test('first containing segment wins at inclusive boundaries', () {
      final segments = <Segment>[
        segment('first', 'one', 100, 200),
        segment('second', 'two', 150, 250),
      ];
      expect(segmentFor(stroke(1, 150), segments)?.id, 'first');
      expect(segmentFor(stroke(1, 200), segments)?.id, 'first');
      expect(segmentFor(stroke(1, 250), segments)?.id, 'second');
    });

    test('nearest gap uses both stroke endpoints', () {
      final segments = <Segment>[
        segment('far', 'first', 0, 100),
        segment('near', 'second', 1000, 1100),
      ];
      expect(segmentFor(stroke(1, 1400), segments)?.id, 'near');
      expect(
        segmentFor(
          stroke(2, 400, endedAt: 750),
          <Segment>[segment('crossed', 'middle', 600, 650)],
        )?.id,
        'crossed',
      );
    });

    test('slack includes exactly 3000 ms and rejects 3001 ms', () {
      final segments = <Segment>[segment('old', 'one', 0, 1000)];
      expect(alignSlackMs, 3000);
      expect(segmentFor(stroke(1, 4000, endedAt: 4000), segments)?.id, 'old');
      expect(segmentFor(stroke(2, 4001, endedAt: 4001), segments), isNull);
    });

    test('minimum gap ties keep the first input segment', () {
      final segments = <Segment>[
        segment('before', 'one', 400, 450),
        segment('after', 'two', 550, 600),
      ];
      expect(segmentFor(stroke(1, 500, endedAt: 500), segments)?.id, 'before');
    });
  });

  group('wordSlot', () {
    test('zero words and zero or negative duration', () {
      expect(wordSlot(segment('a', 'text', 100, 300), 0, 200), 0);
      expect(wordSlot(segment('a', 'text', 100, 100), 4, 100), 4);
      expect(wordSlot(segment('a', 'text', 200, 100), 4, 150), 4);
    });

    test('clamps and uses ceil with a minimum slot of one', () {
      final s = segment('a', 'a b c d', 100, 500);
      expect(wordSlot(s, 4, -100), 1);
      expect(wordSlot(s, 4, 100), 1);
      expect(wordSlot(s, 4, 200), 1);
      expect(wordSlot(s, 4, 201), 2);
      expect(wordSlot(s, 4, 300), 2);
      expect(wordSlot(s, 4, 400), 3);
      expect(wordSlot(s, 4, 500), 4);
      expect(wordSlot(s, 4, 900), 4);
    });
  });

  group('annotateTranscript', () {
    test('sorts trimmed nonblank segments without changing input order', () {
      final late = segment('late', '  good   bye  ', 200, 300);
      final early = segment('early', ' hi ', 0, 100);
      final blank = segment('blank', '  \n  ', 110, 150);
      final segments = <Segment>[late, blank, early];

      final result = annotateTranscript(<Stroke>[stroke(7, 250)], segments);
      expect(result.text, 'hi good ⟦stroke 7⟧ bye');
      expect(result.unspoken, isEmpty);
      expect(segments.map((s) => s.id).toList(), <String>[
        'late',
        'blank',
        'early',
      ]);
    });

    test('retains input order for equal-start segments', () {
      final result = annotateTranscript(
        <Stroke>[],
        <Segment>[
          segment('a', 'alpha', 100, 200),
          segment('b', 'beta', 100, 200),
        ],
      );
      expect(result.text, 'alpha beta');
    });

    test('places same-word markers in input stroke order', () {
      final result = annotateTranscript(
        <Stroke>[stroke(5, 100), stroke(2, 100)],
        <Segment>[segment('s', 'alpha beta', 0, 200)],
      );
      expect(result.text, 'alpha ⟦stroke 5⟧ ⟦stroke 2⟧ beta');
      expect(result.unspoken, isEmpty);
    });

    test('uses nearest segment for a marker started after speech', () {
      final result = annotateTranscript(
        <Stroke>[stroke(8, 1400)],
        <Segment>[segment('s', 'hello world', 1000, 1100)],
      );
      expect(result.text, 'hello world ⟦stroke 8⟧');
    });

    test('unspoken order is input stroke order and blanks cannot claim ink', () {
      final result = annotateTranscript(
        <Stroke>[
          stroke(9, 9000),
          stroke(1, 50),
          stroke(4, 10000),
          stroke(6, 250),
        ],
        <Segment>[
          segment('spoken', 'hello', 0, 100),
          segment('blank', '  ', 200, 300),
        ],
      );
      expect(result.text, 'hello ⟦stroke 1⟧ ⟦stroke 6⟧');
      expect(result.unspoken, <int>[9, 4]);
    });

    test('empty inputs and strokes without speech', () {
      final empty = annotateTranscript(<Stroke>[], <Segment>[]);
      expect(empty.text, '');
      expect(empty.unspoken, isEmpty);

      final noSpeech = annotateTranscript(
        <Stroke>[stroke(3, 0), stroke(1, 20)],
        <Segment>[],
      );
      expect(noSpeech.text, '');
      expect(noSpeech.unspoken, <int>[3, 1]);
    });
  });
}
