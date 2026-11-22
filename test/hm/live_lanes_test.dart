// Live Mode lanes (HA-035): Dash's lane records folded into lanes, the
// fixture driver, and the call routing each turn to the lane it targets.
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/features/live/live_controller.dart';
import 'package:hermes_android/hm/features/live/live_lanes.dart';

import 'live_fakes.dart';

String _jsonl(List<Map<String, Object?>> rows) =>
    rows.map(jsonEncode).join('\n');

Map<String, Object?> _rec(String type, Object ts, Map<String, Object?> data) =>
    {'type': type, 'ts': ts, 'data': data};

Map<String, Object?> _delta(bool user, String text) => {
  'type': user
      ? 'session.input_transcript.delta'
      : 'session.output_transcript.delta',
  'delta': text,
};

void main() {
  group('lane records', () {
    test('attach, step, handoff, error and detach fold in order', () {
      final lanes = foldLiveLanes(
        _jsonl([
          _rec('lane_attached', 100, {
            'lane': 'fast',
            'name': 'Fast',
            'model': 'gpt-5-mini',
          }),
          _rec('lane_attached', 101, {'lane': 'large', 'name': 'Large'}),
          _rec('lane_attached', 102, {'lane': 'council', 'name': 'Council'}),
          _rec('lane_step', 103, {'lane': 'fast', 'step': 'Reading  the diff'}),
          _rec('lane_handoff', 105, {
            'lane': 'large',
            'summary': 'Looks fine',
            'result': 'Looks fine.\nShip it.',
          }),
          _rec('lane_error', 106, {
            'lane': 'council',
            'message': 'Rate limited',
          }),
        ]),
      );
      expect(lanes.map((l) => l.id), ['fast', 'large', 'council']);
      final fast = lanes[0];
      expect(fast.model, 'gpt-5-mini');
      expect(fast.status, LiveLaneStatus.working);
      expect(fast.step, 'Reading the diff');
      expect(liveLaneNow(fast), 'Reading the diff');
      final large = lanes[1];
      expect(large.status, LiveLaneStatus.idle);
      expect(large.handoff!.summary, 'Looks fine');
      expect(large.handoff!.result, 'Looks fine.\nShip it.');
      expect(liveLaneNow(large), 'Idle · handed back');
      expect(liveLaneNow(lanes[2]), 'Failed · Rate limited');
      expect(
        liveLaneSummary(lanes),
        '3 lanes · 1 working · 1 failed · Council failed',
      );

      final after = foldLiveLanes(
        _jsonl([
          _rec('lane_detached', 107, {'lane': 'large'}),
        ]),
        lanes,
      );
      expect(after.map((l) => l.id), ['fast', 'council']);
    });

    test('a step for an unknown lane attaches it under its id', () {
      final lanes = foldLiveLanes(
        _jsonl([
          _rec('lane_step', 1, {'lane': 'scout', 'step': 'Looking'}),
        ]),
      );
      expect(lanes.single.name, 'scout');
      expect(lanes.single.status, LiveLaneStatus.working);
    });

    test('junk, call events and bad lane ids are skipped', () {
      final lanes = foldLiveLanes(
        [
          'not json',
          jsonEncode({'type': 'user_transcript', 'ts': 1, 'text': 'hi'}),
          jsonEncode(_rec('lane_attached', 1, {'lane': '../x'})),
          jsonEncode(_rec('lane_attached', 'nope', {'lane': 'fast'})),
          jsonEncode(_rec('lane_step', 1, {'lane': 'fast', 'step': '  '})),
          jsonEncode(
            _rec('lane_attached', '2026-11-22T10:00:00Z', {'lane': 'fast'}),
          ),
        ].join('\n'),
      );
      expect(lanes.single.id, 'fast');
      expect(lanes.single.status, LiveLaneStatus.idle);
    });

    test('at most $kLiveLanesMax lanes attach', () {
      final lanes = foldLiveLanes(
        _jsonl([
          for (var i = 0; i < kLiveLanesMax + 3; i++)
            _rec('lane_attached', i, {'lane': 'l$i'}),
        ]),
      );
      expect(lanes, hasLength(kLiveLanesMax));
    });

    test('the summary with nothing attached, and all idle', () {
      expect(liveLaneSummary(const []), 'No lanes attached');
      final lanes = foldLiveLanes(
        _jsonl([
          _rec('lane_attached', 1, {'lane': 'fast', 'name': 'Fast'}),
        ]),
      );
      expect(liveLaneSummary(lanes), '1 lane · all idle · Fast attached');
    });
  });

  group('FixtureLiveLanes', () {
    test('a turn steps the lane, then hands back after its latency', () {
      fakeAsync((async) {
        final lanes = FixtureLiveLanes(attached: ['fast']);
        String? reply;
        lanes.ask('fast', 'ship it?').then((r) => reply = r);
        async.flushMicrotasks();
        expect(lanes.lanes.single.status, LiveLaneStatus.working);
        expect(lanes.lanes.single.step, 'Working on “ship it?”');
        async.elapse(const Duration(milliseconds: 600));
        expect(reply, 'Quick take on “ship it?”: yes, go ahead.');
        expect(lanes.lanes.single.status, LiveLaneStatus.idle);
        expect(lanes.lanes.single.handoff!.summary, reply);
        expect(lanes.asked, [('fast', 'ship it?')]);
      });
    });

    test('detaching mid-turn drops the reply', () {
      fakeAsync((async) {
        final lanes = FixtureLiveLanes(attached: ['large']);
        String? reply;
        lanes.ask('large', 'q').then((r) => reply = r);
        async.flushMicrotasks();
        lanes.detach('large');
        async.elapse(const Duration(seconds: 3));
        expect(reply, '');
        expect(lanes.lanes, isEmpty);
      });
    });

    test('asking a lane that is not attached fails', () async {
      final lanes = FixtureLiveLanes();
      await expectLater(lanes.ask('fast', 'q'), throwsStateError);
    });

    test('replay applies Dash broker records', () {
      final lanes = FixtureLiveLanes()
        ..replay(
          _jsonl([
            _rec('lane_attached', 1, {'lane': 'council', 'name': 'Council'}),
            _rec('lane_step', 2, {'lane': 'council', 'step': 'Seat 2 voting'}),
          ]),
        );
      expect(lanes.lanes.single.step, 'Seat 2 voting');
    });
  });

  group('routing turns per lane', () {
    test('a heard turn goes to the targeted lane, then back to the bot', () {
      fakeAsync((async) {
        final lanes = FixtureLiveLanes(attached: ['fast', 'large', 'council']);
        final rig = LiveRig(lanes: lanes);
        final live = rig.build();
        live.start();
        async.flushMicrotasks();
        expect(live.phase, LivePhase.listening);

        live.route('large');
        expect(live.target, 'large');
        rig.ear.hear('is the plan sound');
        async.flushMicrotasks();
        expect(live.phase, LivePhase.thinking);
        expect(rig.brain.asked, isEmpty, reason: 'the bot is not asked');
        expect(lanes.asked, [('large', 'is the plan sound')]);
        expect(lanes.lanes[1].status, LiveLaneStatus.working);

        async.elapse(const Duration(seconds: 2));
        expect(live.phase, LivePhase.speaking);
        expect(rig.voice.spoken.single, startsWith('Considered answer'));
        rig.voice.finish();
        async.flushMicrotasks();
        expect(live.phase, LivePhase.listening);

        live.route('council');
        rig.ear.hear('vote');
        async.elapse(const Duration(seconds: 3));
        rig.voice.finish();
        async.flushMicrotasks();

        live.route(null);
        rig.ear.hear('thanks');
        async.flushMicrotasks();
        expect(rig.brain.asked, ['thanks']);
        rig.brain.reply('Any time.');
        async.flushMicrotasks();

        expect(lanes.asked.map((a) => a.$1), ['large', 'council']);
        expect(
          [for (final l in live.lines) (l.lane, l.fromUser)],
          [
            ('large', true),
            ('large', false),
            ('council', true),
            ('council', false),
            (null, true),
            (null, false),
          ],
        );
        live.dispose();
      });
    });

    test('lane lines sit where they were asked among the bot\'s lines', () {
      fakeAsync((async) {
        final lanes = FixtureLiveLanes(attached: ['fast']);
        final rig = LiveRig(lanes: lanes);
        final live = rig.build();
        live.start();
        async.flushMicrotasks();
        rig.ear.hear('hello');
        async.flushMicrotasks();
        rig.brain.reply('Hi.');
        async.flushMicrotasks();
        rig.voice.finish();
        async.flushMicrotasks();

        live.route('fast');
        rig.ear.hear('quick one');
        async.elapse(const Duration(milliseconds: 600));
        rig.voice.finish();
        async.flushMicrotasks();

        expect(live.lines.map((l) => l.text).toList(), [
          'hello',
          'Hi.',
          'quick one',
          'Quick take on “quick one”: yes, go ahead.',
        ]);
        live.dispose();
      });
    });

    test('routing to an unattached lane, or detaching the target, falls back '
        'to the bot', () async {
      final lanes = FixtureLiveLanes(attached: ['fast']);
      final live = LiveRig(lanes: lanes).build();
      live.route('large');
      expect(live.target, isNull);
      live.route('fast');
      expect(live.target, 'fast');
      expect(live.laneName('fast'), 'Fast');
      await lanes.detach('fast');
      expect(live.target, isNull);
      live.dispose();
    });

    test('a GPT-Live delegation goes to the targeted lane', () {
      fakeAsync((async) {
        final lanes = FixtureLiveLanes(attached: ['fast']);
        final rig = LiveRig(
          host: FakeHost(mode: 'gpt-live', available: true),
          peer: FakePeer(),
          lanes: lanes,
        );
        final live = rig.build();
        live.start();
        // The setup runs off a zero-length timer.
        async.elapse(Duration.zero);
        expect(live.webRtc, isTrue);
        expect(live.phase, LivePhase.listening);
        live.route('fast');
        rig.peer!.event(_delta(true, 'check the build'));
        rig.peer!.event({
          'type': 'session.delegation.created',
          'delegation': {'id': 'd1', 'type': 'client', 'target': 'backend'},
        });
        async.flushMicrotasks();
        expect(lanes.asked, [('fast', 'check the build')]);
        async.elapse(const Duration(milliseconds: 600));
        expect(
          rig.peer!.sent.single['content'],
          'Quick take on “check the build”: yes, go ahead.',
        );
        expect(rig.brain.asked, isEmpty);
        // The voice model already showed what was said: only the reply is
        // added, tagged with its lane.
        expect(
          [for (final l in live.lines) (l.lane, l.fromUser)],
          [(null, true), ('fast', false)],
        );
        // A hidden work marker still anchors the lane to this turn.
        rig.peer!.event(_delta(false, 'All done.'));
        expect(live.lines.map((line) => line.text), [
          'check the build',
          'Quick take on “check the build”: yes, go ahead.',
          'All done.',
        ]);
        live.dispose();
      });
    });

    test('without lanes the call routes to the bot as before', () async {
      final rig = LiveRig();
      final live = rig.build();
      await live.start();
      expect(live.lanes, isNull);
      expect(live.target, isNull);
      rig.ear.hear('hi');
      expect(rig.brain.asked, ['hi']);
      live.dispose();
    });
  });
}
