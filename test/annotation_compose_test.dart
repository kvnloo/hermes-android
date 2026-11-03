import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/annotation/annotation_compose.dart';

const screen = ScreenInfo(
  id: 'screen-1',
  route: '/chat',
  width: 200,
  height: 100,
);

const ring = <StrokePoint>[
  StrokePoint(x: 0.2, y: 0.2, p: 0.5, t: 0),
  StrokePoint(x: 0.5, y: 0.2, p: 0.5, t: 10),
  StrokePoint(x: 0.8, y: 0.2, p: 0.5, t: 20),
  StrokePoint(x: 0.8, y: 0.5, p: 0.5, t: 30),
  StrokePoint(x: 0.8, y: 0.8, p: 0.5, t: 40),
  StrokePoint(x: 0.5, y: 0.8, p: 0.5, t: 50),
  StrokePoint(x: 0.2, y: 0.8, p: 0.5, t: 60),
  StrokePoint(x: 0.2, y: 0.2, p: 0.5, t: 70),
];

Stroke makeStroke({
  int id = 1,
  String tool = 'pen',
  String color = 'accent',
  String pointer = 'stylus',
  int startedAt = 1000,
  int endedAt = 1100,
  List<StrokePoint> points = ring,
  List<String>? targets,
}) => Stroke(
  id: id,
  tool: tool,
  color: color,
  pointer: pointer,
  points: points,
  startedAt: startedAt,
  endedAt: endedAt,
  targets: targets,
);

Segment makeSegment(String id, String text, int start, int end) => Segment(
  id: id,
  text: text,
  start: start,
  end: end,
  source: 'mic',
);

void main() {
  group('annotationDoc', () {
    test('preserves wire field names, raw order and point rounding', () {
      final later = makeSegment('later', 'second', 900, 1100);
      final earlier = makeSegment('earlier', 'first', 0, 100);
      final s = makeStroke(
        points: const <StrokePoint>[
          StrokePoint(x: 0.123456, y: 0.876543, p: 0.555, t: 1051),
          StrokePoint(x: -0.12505, y: 0.99505, p: 0.2349, t: 1100),
        ],
        targets: <String>['button-7', 'card-2'],
      );
      final document = annotationDoc(
        strokes: <Stroke>[s],
        segments: <Segment>[later, earlier],
        screen: screen,
        createdAt: 1700000000123,
      );
      expect(document.keys.toList(), <String>[
        'schema',
        'createdAt',
        'screen',
        'strokes',
        'transcript',
      ]);
      expect(document['schema'], 'dash.annotation.v1');
      expect(document['createdAt'], 1700000000123);
      expect(document['screen'], <String, Object>{
        'id': 'screen-1',
        'route': '/chat',
        'width': 200,
        'height': 100,
      });

      final strokeJson = (document['strokes'] as List).single as Map;
      expect(strokeJson.keys.toList(), <String>[
        'id', 'tool', 'color', 'pointer',
        'startedAt', 'endedAt', 'targets', 'segment', 'points',
      ]);
      expect(strokeJson['targets'], <String>['button-7', 'card-2']);
      expect(strokeJson['segment'], 'later');
      expect(strokeJson['points'], <List<num>>[
        <num>[0.1235, 0.8765, 0.56, 51],
        <num>[-0.125, 0.9951, 0.23, 100],
      ]);
      final transcript = document['transcript'] as Map;
      expect(transcript['text'], 'first second ⟦stroke 1⟧');
      expect((transcript['segments'] as List).map((e) => (e as Map)['id']),
          <String>['later', 'earlier']);
      expect((transcript['segments'] as List).first, <String, Object>{
        'id': 'later',
        'text': 'second',
        'start': 900,
        'end': 1100,
        'source': 'mic',
      });
      expect(jsonDecode(jsonEncode(document)), document);
    });

    test('absent segment is omitted, absent targets become an empty list', () {
      final document = annotationDoc(
        strokes: <Stroke>[makeStroke(startedAt: 12000, endedAt: 12100)],
        segments: <Segment>[makeSegment('s', 'hi', 0, 100)],
        screen: screen,
        createdAt: 0,
      );
      final strokeJson = (document['strokes'] as List).single as Map;
      expect(strokeJson.containsKey('segment'), isFalse);
      expect(strokeJson['targets'], isEmpty);
      expect((document['transcript'] as Map)['text'], 'hi');
    });

    test('empty strokes and segments retain the empty schema', () {
      final document = annotationDoc(
        strokes: <Stroke>[],
        segments: <Segment>[],
        screen: screen,
        createdAt: 0,
      );
      expect(document['strokes'], isEmpty);
      expect(document['transcript'], <String, Object>{
        'text': '',
        'segments': <Object>[],
      });
    });
  });

  test('attachmentNames uses UTC ISO milliseconds and replaced punctuation', () {
    final names = attachmentNames(
      DateTime.utc(2026, 11, 3, 9, 1, 20, 123).millisecondsSinceEpoch,
    );
    expect(names, <String, String>{
      'image': 'annotation-2026-11-03T09-01-20-123Z.png',
      'json': 'annotation-2026-11-03T09-01-20-123Z.json',
    });
    expect(attachmentNames(0)['image'],
        'annotation-1970-01-01T00-00-00-000Z.png');
  });

  group('strokeCenter and strokeLegend', () {
    test('center uses bounding extrema not mean, rounded to percentages', () {
      final points = <StrokePoint>[
        const StrokePoint(x: 0.1, y: 0.2, p: 0.5, t: 0),
        const StrokePoint(x: 0.2, y: 0.9, p: 0.5, t: 5),
        const StrokePoint(x: 0.9, y: 0.4, p: 0.5, t: 10),
      ];
      expect(strokeCenter(points), <double>[50, 55]);
      expect(strokeCenter(const <StrokePoint>[
        StrokePoint(x: 0.005, y: 0.005, p: 0.5, t: 0),
      ]), <double>[1, 1]);
      expect(strokeCenter(<StrokePoint>[]).every((n) => n.isNaN), isTrue);
    });

    test('one line per stroke, red and targets only when present', () {
      final strokes = <Stroke>[
        makeStroke(
          id: 2, tool: 'circle', color: 'red',
          points: const <StrokePoint>[
            StrokePoint(x: 0.2, y: 0.1, p: 0.5, t: 0),
            StrokePoint(x: 0.8, y: 0.9, p: 0.5, t: 1),
          ],
          targets: <String>['card-1', 'title'],
        ),
        makeStroke(
          id: 1, tool: 'arrow',
          points: const <StrokePoint>[
            StrokePoint(x: 0.1, y: 0.2, p: 0.5, t: 0),
            StrokePoint(x: 0.3, y: 0.6, p: 0.5, t: 1),
          ],
        ),
      ];
      expect(strokeLegend(strokes),
          '⟦stroke 2⟧ circle (red) at 50%,50% on card-1, title\n'
          '⟦stroke 1⟧ arrow at 20%,40%');
      expect(strokeLegend(<Stroke>[]), '');
    });
  });

  group('composeMessage', () {
    test('typed speech, unspoken markers and legend have Dash spacing', () {
      final strokes = <Stroke>[
        makeStroke(
          id: 2, startedAt: 1000, endedAt: 1050,
          color: 'red', targets: <String>['submit'],
        ),
        makeStroke(id: 5, startedAt: 10000, endedAt: 10100),
      ];
      final message = composeMessage(
        strokes: strokes,
        segments: <Segment>[makeSegment('voice', 'hello there', 900, 1100)],
        screen: screen,
        typed: '  Check this  ',
      );
      expect(message,
          'Annotated /chat (2 strokes). Screenshot with the marks and the strokes JSON are attached.\n\n'
          'Check this\nhello ⟦stroke 2⟧ there\n'
          'Also marked without speaking: ⟦stroke 5⟧\n\n'
          '⟦stroke 2⟧ pen (red) at 50%,50% on submit\n'
          '⟦stroke 5⟧ pen at 50%,50%');
    });

    test('zero strokes, no speech, and typed-only message', () {
      final header = 'Annotated /chat (0 strokes). Screenshot with the marks and the strokes JSON are attached.';
      expect(composeMessage(strokes: <Stroke>[], segments: <Segment>[], screen: screen), header);
      expect(
        composeMessage(strokes: <Stroke>[], segments: <Segment>[], screen: screen, typed: '  fix  '),
        '$header\n\nfix',
      );
    });

    test('one silent stroke has no orphan silent-text section', () {
      final result = composeMessage(
        strokes: <Stroke>[makeStroke()],
        segments: <Segment>[],
        screen: screen,
      );
      expect(result,
          'Annotated /chat (1 stroke). Screenshot with the marks and the strokes JSON are attached.\n\n'
          '⟦stroke 1⟧ pen at 50%,50%');
      expect(result.contains('Also marked without speaking'), isFalse);
    });

    test('send mode preserves steer vs queue', () {
      expect(annotationSendMode(true), 'steer');
      expect(annotationSendMode(false), 'queue');
    });
  });

  group('closedPenLoopRegion', () {
    test('closed eight-point pen returns DIP region expanded by 12', () {
      expect(closedPenLoopRegion(makeStroke(), screen)?.toJson(),
          <String, num>{'x': 28, 'y': 8, 'width': 144, 'height': 84});
      expect(closedPenLoopRegion(makeStroke(), screen, padding: 0)?.toJson(),
          <String, num>{'x': 40, 'y': 20, 'width': 120, 'height': 60});
    });

    test('pen rejects open paths and paths shorter than eight points', () {
      final opened = <StrokePoint>[
        ...ring.take(7),
        const StrokePoint(x: 0.8, y: 0.65, p: 0.5, t: 70),
      ];
      expect(closedPenLoopRegion(makeStroke(points: opened), screen), isNull);
      expect(closedPenLoopRegion(makeStroke(points: ring.take(7).toList()), screen), isNull);
    });

    test('two-point recognized circle and box work without closing', () {
      final twoPoints = <StrokePoint>[ring[0], ring[4]];
      for (final tool in <String>['circle', 'box']) {
        expect(closedPenLoopRegion(makeStroke(tool: tool, points: twoPoints), screen)?.toJson(),
            <String, num>{'x': 28, 'y': 8, 'width': 144, 'height': 84});
      }
      expect(closedPenLoopRegion(makeStroke(tool: 'circle', points: <StrokePoint>[ring[0]]), screen),
          isNull);
    });

    test('only stylus and pen, circle, box qualify', () {
      for (final pointer in <String>['touch', 'mouse', 'other']) {
        expect(closedPenLoopRegion(makeStroke(pointer: pointer), screen), isNull);
      }
      for (final tool in <String>['arrow', 'highlighter']) {
        expect(closedPenLoopRegion(makeStroke(tool: tool), screen), isNull);
      }
    });

    test('invalid screen, padding, points and small extents do not crop', () {
      for (final bad in <ScreenInfo>[
        const ScreenInfo(id: 'a', route: 'a', width: 0, height: 100),
        const ScreenInfo(id: 'a', route: 'a', width: 200, height: -1),
        const ScreenInfo(id: 'a', route: 'a', width: double.nan, height: 100),
        const ScreenInfo(id: 'a', route: 'a', width: 200, height: double.infinity),
      ]) {
        expect(closedPenLoopRegion(makeStroke(), bad), isNull);
      }
      for (final padding in <num>[-1, double.nan, double.infinity]) {
        expect(closedPenLoopRegion(makeStroke(), screen, padding: padding), isNull);
      }
      final invalid = <StrokePoint>[
        ...ring.take(7),
        const StrokePoint(x: double.nan, y: 0.2, p: 0.5, t: 70),
      ];
      expect(closedPenLoopRegion(makeStroke(points: invalid), screen), isNull);
      final small = <StrokePoint>[
        const StrokePoint(x: 0.1, y: 0.1, p: 0.5, t: 0),
        const StrokePoint(x: 0.2, y: 0.2, p: 0.5, t: 1),
      ];
      expect(closedPenLoopRegion(makeStroke(tool: 'circle', points: small), screen), isNull);
    });

    test('floor/ceil padding and clipping to screen edges', () {
      final offscreen = <StrokePoint>[
        const StrokePoint(x: -0.01, y: 0.05, p: 0.5, t: 0),
        const StrokePoint(x: 1.04, y: 0.95, p: 0.5, t: 1),
      ];
      expect(
        closedPenLoopRegion(
          makeStroke(tool: 'box', points: offscreen),
          const ScreenInfo(id: 's', route: 's', width: 100, height: 100),
        )?.toJson(),
        <String, num>{'x': 0, 'y': 0, 'width': 100, 'height': 100},
      );
      final fractional = <StrokePoint>[
        const StrokePoint(x: 0.215, y: 0.309, p: 0.5, t: 0),
        const StrokePoint(x: 0.807, y: 0.799, p: 0.5, t: 1),
      ];
      expect(
        closedPenLoopRegion(makeStroke(tool: 'box', points: fractional), screen, padding: 1.2)?.toJson(),
        <String, num>{'x': 41, 'y': 29, 'width': 122, 'height': 53},
      );
    });

    test('crop is rejected when bounding rectangle does not meet screen', () {
      final outside = <StrokePoint>[
        const StrokePoint(x: 2, y: 2, p: 0.5, t: 0),
        const StrokePoint(x: 3, y: 3, p: 0.5, t: 1),
      ];
      expect(closedPenLoopRegion(makeStroke(tool: 'box', points: outside), screen), isNull);
    });
  });

  group('visibleTextInRegion', () {
    test('filters on inclusive box centers, not mere overlap', () {
      const region = CircleRegion(x: 10, y: 20, width: 50, height: 50);
      final boxes = <VisibleTextBox>[
        const VisibleTextBox(x: 5, y: 35, width: 10, height: 10, text: ' left '),
        const VisibleTextBox(x: 55, y: 35, width: 10, height: 10, text: 'right'),
        const VisibleTextBox(x: 58, y: 35, width: 10, height: 10, text: 'overlap only'),
        const VisibleTextBox(x: 20, y: 15, width: 10, height: 10, text: ' top '),
        const VisibleTextBox(x: 20, y: 65, width: 10, height: 10, text: 'bottom'),
        const VisibleTextBox(x: 20, y: 20, width: 10, height: 10, text: '  '),
        const VisibleTextBox(x: 20, y: 20, width: 0, height: 10, text: 'zero'),
        const VisibleTextBox(x: 20, y: 20, width: -1, height: 10, text: 'negative'),
        const VisibleTextBox(x: double.nan, y: 20, width: 10, height: 10, text: 'nan'),
      ];
      expect(visibleTextInRegion(region, boxes), 'left\nright\ntop\nbottom');
      expect(visibleTextInRegion(region, <VisibleTextBox>[]), '');
    });
  });

  group('circleDraftText', () {
    test('appends a visible caption after trimmed draft', () {
      expect(circleDraftText('Keep this \n  ', '/chat', '  important \n text  '),
          'Keep this\n\nCircled on /chat:\nimportant \n text');
    });

    test('empty existing and blank visible text use bare caption', () {
      expect(circleDraftText('  ', '/chat', '\n  '), 'Circled on /chat.');
      expect(circleDraftText('', '/chat', ' title '), 'Circled on /chat:\ntitle');
    });
  });
}
