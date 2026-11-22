// GPT-Live staying up through long work and dropped links (HA-037): a
// delegation whose tool runs for minutes keeps the voice informed, and a
// call whose transport drops redials, resumes from the transcript and still
// delivers the running turn's result. Time is faked so minutes pass at once.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/features/live/live_controller.dart';
import 'package:hermes_android/hm/features/live/live_strings.dart';
import 'package:hermes_android/hm/features/live/live_webrtc.dart';

import 'live_fakes.dart';

Map<String, Object?> _delta(bool user, String text) => {
  'type': user
      ? 'session.input_transcript.delta'
      : 'session.output_transcript.delta',
  'delta': text,
};

Map<String, Object?> _delegation(String id) => {
  'type': 'session.delegation.created',
  'delegation': {'id': id, 'type': 'client', 'target': 'backend'},
};

LiveRig _rig({FakePeer Function()? redialPeer, List<Duration>? delays}) =>
    LiveRig(
      host: FakeHost(mode: 'gpt-live', available: true),
      peer: FakePeer(),
      redialPeer: redialPeer ?? FakePeer.new,
      reconnectDelays: delays,
    );

/// Starts the call and runs one delegation for [said] up to the chat turn.
LiveController _callWithTurn(FakeAsync async, LiveRig rig, String said) {
  final live = rig.build();
  live.start();
  // The setup runs in a zero-delay timer, not a microtask.
  async.elapse(Duration.zero);
  expect(live.phase, LivePhase.listening);
  rig.peer!.event(_delta(false, 'Hi, what can I do?'));
  rig.peer!.event(_delta(true, said));
  rig.peer!.event(_delegation('d1'));
  async.flushMicrotasks();
  expect(rig.brain.asked, [said]);
  return live;
}

List<Map<String, dynamic>> _type(FakePeer peer, String type) =>
    peer.sent.where((f) => f['type'] == type).toList();

void main() {
  group('a 2+ minute tool call', () {
    test('keeps the call up and tells the voice it is still working', () {
      fakeAsync((async) {
        final rig = _rig();
        final live = _callWithTurn(async, rig, 'summarize the running work');
        final peer = rig.peer!;

        rig.brain.useTool('terminal · kubectl get pods');
        async.elapse(const Duration(seconds: 70));
        rig.brain.useTool('read_file · REPORT.md');
        async.elapse(const Duration(seconds: 80));

        // 150 s of work: still one call, never failed, still thinking.
        expect(live.phase, LivePhase.thinking);
        expect(live.failure, isNull);
        expect(rig.peers, hasLength(1));
        final notes = _type(peer, 'session.thinking.append');
        expect(notes.every((f) => f['delegation_id'] == 'd1'), isTrue);
        expect(
          notes.map((f) => f['content']),
          containsAllInOrder([
            'Hermes is working: terminal · kubectl get pods. Not done yet.',
            'Hermes is still working: terminal · kubectl get pods. Not done yet.',
            'Hermes is working: read_file · REPORT.md. Not done yet.',
            'Hermes is still working: read_file · REPORT.md. Not done yet.',
          ]),
        );
        // One note per tool change plus one every 20 s.
        expect(notes, hasLength(2 + 150 ~/ 20));

        rig.brain.reply('Three jobs are running; the build is green.');
        async.flushMicrotasks();
        expect(_type(peer, 'session.commentary.append').single, {
          'type': 'session.commentary.append',
          'delegation_id': 'd1',
          'event_id': 'say_${notes.length + 1}',
          'content': 'Three jobs are running; the build is green.',
        });
        expect(live.phase, LivePhase.listening);

        // Done: no more progress notes.
        final before = peer.sent.length;
        async.elapse(const Duration(minutes: 2));
        expect(peer.sent, hasLength(before));
        live.end();
        async.flushMicrotasks();
      });
    });
  });

  group('a dropped channel', () {
    test('redials, resumes the transcript and delivers the running result', () {
      fakeAsync((async) {
        final rig = _rig();
        final live = _callWithTurn(async, rig, 'what is running right now');
        final first = rig.peer!;
        async.elapse(const Duration(seconds: 60));

        first.lose();
        expect(live.phase, LivePhase.connecting);
        expect(live.notice, LiveText.gptLiveReconnecting);
        expect(live.lines.map((l) => l.text), [
          'Hi, what can I do?',
          'what is running right now',
        ]);

        async.elapse(const Duration(seconds: 1));
        expect(rig.peers, hasLength(2));
        final second = rig.peers.last;
        expect(second.open, isTrue);
        // Still working on the turn that outlived the old call.
        expect(live.phase, LivePhase.thinking);
        expect(live.notice, isNull);
        expect(live.failure, isNull);
        // The redial is seeded with what was said on the dropped call.
        expect(rig.host.sessions, hasLength(2));
        expect(
          rig.host.sessions.last.history.map(
            (m) => ((m['content'] as List).single as Map)['text'],
          ),
          ['Hi, what can I do?', 'what is running right now'],
        );

        // Progress continues on the new call, as session-wide context.
        async.elapse(const Duration(seconds: 20));
        final progress = _type(second, 'session.thinking.append');
        expect(progress, isNotEmpty);
        expect(progress.first['delegation_id'], isNull);

        // The result lands on the new call (the old id is unknown there).
        final firstSent = first.sent.length;
        rig.brain.reply('Two builds and a deploy.');
        async.flushMicrotasks();
        final said = _type(second, 'session.commentary.append').single;
        expect(said['delegation_id'], isNull);
        expect(said['content'], 'Two builds and a deploy.');
        expect(first.sent, hasLength(firstSent));
        expect(live.phase, LivePhase.listening);

        // A new delegation on the new call still finds the user's words.
        second.event(_delegation('d2'));
        async.flushMicrotasks();
        expect(rig.brain.asked.last, 'what is running right now');
        live.end();
        async.flushMicrotasks();
      });
    });

    test('a result that finishes while redialling is kept and said after', () {
      fakeAsync((async) {
        final rig = _rig(delays: const [Duration(seconds: 3)]);
        final live = _callWithTurn(async, rig, 'go to my home screen');
        rig.peer!.lose();
        rig.brain.reply('Done, you are on the home screen.');
        async.flushMicrotasks();
        expect(live.phase, LivePhase.connecting);
        async.elapse(const Duration(seconds: 3));
        final second = rig.peers.last;
        expect(
          _type(second, 'session.commentary.append').single['content'],
          'Done, you are on the home screen.',
        );
        expect(live.phase, LivePhase.listening);
        live.end();
        async.flushMicrotasks();
      });
    });

    test('the provider\'s connection_lost close also redials', () {
      fakeAsync((async) {
        final rig = _rig();
        final live = rig.build();
        live.start();
        async.elapse(Duration.zero);
        rig.peer!.event({
          'type': 'session.closed',
          'reason': 'connection_lost',
        });
        expect(live.phase, LivePhase.connecting);
        async.elapse(const Duration(seconds: 1));
        expect(rig.peers, hasLength(2));
        expect(live.phase, LivePhase.listening);
        live.end();
        async.flushMicrotasks();
      });
    });

    test('an expired session does not redial', () {
      fakeAsync((async) {
        final rig = _rig();
        final live = rig.build();
        live.start();
        async.elapse(Duration.zero);
        rig.peer!.event({'type': 'session.closed', 'reason': 'expired'});
        expect(live.phase, LivePhase.failed);
        expect(live.failure, LiveText.gptLiveClosed);
        async.elapse(const Duration(minutes: 1));
        expect(rig.peers, hasLength(1));
      });
    });

    test('backs off between redials and gives up with the official text', () {
      fakeAsync((async) {
        final rig = _rig(
          redialPeer: () => FakePeer(offerError: StateError('no network')),
          delays: const [
            Duration(seconds: 1),
            Duration(seconds: 2),
            Duration(seconds: 4),
          ],
        );
        final live = rig.build();
        live.start();
        async.elapse(Duration.zero);
        rig.peer!.lose();
        async.elapse(const Duration(milliseconds: 999));
        expect(rig.peers, hasLength(1));
        async.elapse(const Duration(milliseconds: 1));
        expect(rig.peers, hasLength(2));
        async.elapse(const Duration(seconds: 2));
        expect(rig.peers, hasLength(3));
        expect(live.phase, LivePhase.connecting);
        async.elapse(const Duration(seconds: 4));
        expect(rig.peers, hasLength(4));
        expect(live.phase, LivePhase.failed);
        expect(live.failure, LiveText.gptLiveLost);
        expect(live.reconnecting, isFalse);
      });
    });

    test('ending the call while redialling stops the redials', () {
      fakeAsync((async) {
        final rig = _rig();
        final live = rig.build();
        live.start();
        async.elapse(Duration.zero);
        rig.peer!.lose();
        live.end();
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 1));
        expect(rig.peers, hasLength(1));
        expect(live.phase, LivePhase.ended);
      });
    });

    test('a mute held across the drop stays on the new call', () {
      fakeAsync((async) {
        final rig = _rig();
        final live = rig.build();
        live.start();
        async.elapse(Duration.zero);
        live.toggleMute();
        rig.peer!.lose();
        async.elapse(const Duration(seconds: 1));
        expect(rig.peers.last.micEnabled, isFalse);
        expect(live.phase, LivePhase.muted);
        live.end();
        async.flushMicrotasks();
      });
    });
  });

  group('LiveLinkGuard', () {
    test('a disconnect that recovers within the grace is not a loss', () {
      fakeAsync((async) {
        var lost = 0;
        final guard = LiveLinkGuard(onLost: () => lost++);
        guard.disconnected();
        async.elapse(const Duration(seconds: 9));
        guard.connected();
        async.elapse(const Duration(minutes: 1));
        expect(lost, 0);
      });
    });

    test('a disconnect that outlasts the grace is lost once', () {
      fakeAsync((async) {
        var lost = 0;
        final guard = LiveLinkGuard(onLost: () => lost++);
        guard.disconnected();
        guard.disconnected();
        async.elapse(const Duration(seconds: 10));
        guard.failed();
        expect(lost, 1);
        expect(guard.lost, isTrue);
      });
    });

    test('failed is lost at once; our own close is never a loss', () {
      fakeAsync((async) {
        var lost = 0;
        LiveLinkGuard(onLost: () => lost++).failed();
        expect(lost, 1);
        final closing = LiveLinkGuard(onLost: () => lost++);
        closing.disconnected();
        closing.close();
        async.elapse(const Duration(minutes: 1));
        closing.failed();
        expect(lost, 1);
      });
    });
  });
}
