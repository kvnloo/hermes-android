// Live Mode over GPT-Live (WebRTC), driven through fake signalling and a fake
// peer/data channel: status branches, the offer/answer request, each channel
// event, delegation round trips, mute, close, the setup limit and fallback.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dashboard_api_client.dart';
import 'package:hermes_android/hm/features/live/live_controller.dart';
import 'package:hermes_android/hm/features/live/live_strings.dart';
import 'package:hermes_android/hm/features/live/live_transport.dart';
import 'package:hermes_android/hm/features/live/live_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'live_fakes.dart';

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

LiveRig _gptLive({FakePeer? peer, FakeHost? host, Duration? setupLimit}) =>
    LiveRig(
      host: host ?? FakeHost(mode: 'gpt-live', available: true),
      peer: peer ?? FakePeer(),
      setupLimit: setupLimit,
    );

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

void main() {
  group('status branches', () {
    test('gpt-live selected and available: the call goes over WebRTC', () async {
      final rig = _gptLive();
      final live = rig.build();
      await live.start();
      expect(live.webRtc, isTrue);
      expect(live.phase, LivePhase.listening);
      expect(rig.host.sessions, hasLength(1));
      expect(rig.peer!.appliedAnswer, 'v=0 answer\r\n');
      expect(rig.ear.listens, 0, reason: 'the voice model owns the mic');
      expect(live.notice, isNull);
    });

    test('chained selected: the chained loop, no session request', () async {
      final rig = _gptLive(host: FakeHost(mode: 'chained', available: true));
      final live = rig.build();
      await live.start();
      expect(live.webRtc, isFalse);
      expect(rig.host.sessions, isEmpty);
      expect(rig.ear.listening, isTrue);
      expect(live.notice, isNull);
    });

    test('gpt-live selected but not startable: chained, with notice', () async {
      final rig = _gptLive(host: FakeHost(mode: 'gpt-live', available: false));
      final live = rig.build();
      await live.start();
      expect(live.webRtc, isFalse);
      expect(rig.host.sessions, isEmpty);
      expect(rig.ear.listening, isTrue);
      expect(live.notice, LiveText.gptLiveNotConfigured);
    });

    test('status parses the host shape, underscore spelling included', () {
      final s = LiveVoiceStatus.fromJson({
        'ok': true,
        'mode': 'gpt_live',
        'available': true,
        'reason': null,
        'model': 'gpt-live-1',
        'voice': 'marin',
      });
      expect(s.useWebRtc, isTrue);
      expect(s.model, 'gpt-live-1');
      expect(s.voice, 'marin');
      expect(
        LiveVoiceStatus.fromJson({'mode': 'chained', 'available': true}).useWebRtc,
        isFalse,
      );
    });
  });

  group('setup', () {
    test('seeds the session with this chat\'s recent turns', () async {
      final rig = _gptLive();
      rig.brain.shown.addAll(const [
        LiveLine(key: 'a', fromUser: true, text: 'hi'),
        LiveLine(key: 'b', fromUser: false, text: 'hello  there'),
      ]);
      await rig.build().start();
      expect(rig.host.sessions.single.sdp, 'v=0 offer\r\n');
      expect(rig.host.sessions.single.history, [
        {
          'type': 'message',
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': 'hi'},
          ],
        },
        {
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': 'hello there'},
          ],
        },
      ]);
    });

    test('mic refused: fails with the official mic text', () async {
      final rig = _gptLive(peer: FakePeer(offerError: const LiveCallMicDenied()));
      final live = rig.build();
      await live.start();
      expect(live.phase, LivePhase.failed);
      expect(live.failure, LiveText.micOff);
    });

    test('peer cannot be built: falls back with the official notice', () async {
      final rig = _gptLive(peer: FakePeer(offerError: StateError('no ICE')));
      final live = rig.build();
      await live.start();
      expect(live.webRtc, isFalse);
      expect(live.phase, LivePhase.listening);
      expect(rig.ear.listening, isTrue);
      expect(live.notice, LiveText.gptLiveNoConnection);
      expect(rig.peer!.closed, isTrue);
    });

    test('host returns no answer SDP: falls back', () async {
      final rig = _gptLive(
        host: FakeHost(
          mode: 'gpt-live',
          available: true,
          answer: const LiveSessionAnswer(sessionId: 'x'),
        ),
      );
      final live = rig.build();
      await live.start();
      expect(live.webRtc, isFalse);
      expect(live.notice, LiveText.gptLiveNoSession);
      expect(rig.ear.listening, isTrue);
    });

    test('session request fails: falls back', () async {
      final rig = _gptLive(
        host: FakeHost(
          mode: 'gpt-live',
          available: true,
          sessionError: const DashboardRequestException(502, 'vendor down'),
        ),
      );
      final live = rig.build();
      await live.start();
      expect(live.webRtc, isFalse);
      expect(live.notice, LiveText.gptLiveCouldNotConnect);
      expect(rig.ear.listening, isTrue);
    });

    test('a channel that never opens hits the setup limit and falls back', () async {
      final peer = FakePeer(openOnAnswer: false);
      final rig = _gptLive(
        peer: peer,
        setupLimit: const Duration(milliseconds: 30),
      );
      final live = rig.build();
      await live.start();
      expect(live.webRtc, isFalse);
      expect(peer.closed, isTrue);
      expect(live.notice, LiveText.gptLiveCouldNotConnect);
      expect(live.phase, LivePhase.listening);
      expect(rig.ear.listening, isTrue);
    });

    test('session.started also counts as up', () async {
      final peer = FakePeer(openOnAnswer: false);
      final rig = _gptLive(peer: peer);
      final live = rig.build();
      final starting = live.start();
      await _settle();
      expect(live.phase, LivePhase.connecting);
      peer.event({
        'type': 'session.started',
        'session': {'id': 'live_9'},
      });
      await starting;
      expect(live.phase, LivePhase.listening);
      expect(rig.call!.sessionId, 'live_9');
    });

    test('closing during setup tears down and does not fall back', () async {
      final peer = FakePeer(openOnAnswer: false);
      final rig = _gptLive(peer: peer);
      final live = rig.build();
      final starting = live.start();
      await _settle();
      await live.end();
      await starting;
      expect(live.phase, LivePhase.ended);
      expect(peer.closed, isTrue);
      expect(rig.ear.listens, 0);
    });
  });

  group('channel events', () {
    late LiveRig rig;
    late LiveController live;
    late FakePeer peer;

    setUp(() async {
      rig = _gptLive();
      peer = rig.peer!;
      live = rig.build();
      await live.start();
    });

    test('input transcript is You, output transcript is the bot', () {
      peer.event(_delta(true, 'What is'));
      peer.event(_delta(true, ' the time?'));
      peer.event(_delta(false, 'Let me'));
      peer.event(_delta(false, ' check.'));
      expect(
        live.lines.map((l) => (l.fromUser, l.text)),
        [(true, 'What is the time?'), (false, 'Let me check.')],
      );
    });

    test('output transcript means speaking; the user talking over listens', () {
      peer.event(_delta(false, 'Hello'));
      expect(live.phase, LivePhase.speaking);
      peer.event(_delta(true, 'wait'));
      expect(live.phase, LivePhase.listening);
    });

    test('speaking settles back to listening after the voice goes quiet', () async {
      peer.event(_delta(false, 'Hello'));
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      expect(live.phase, LivePhase.listening);
    });

    test('thinking and commentary appends show thinking', () {
      peer.event({'type': 'session.thinking.append', 'content': 'checking'});
      expect(live.phase, LivePhase.thinking);
      peer.event(_delta(false, 'Done.'));
      expect(live.phase, LivePhase.speaking);
      peer.event({'type': 'session.commentary.append', 'content': 'x'});
      peer.event(_delta(true, 'ok'));
      expect(live.phase, LivePhase.thinking);
    });

    test('a provider error shows the official notice and the call goes on', () {
      peer.event({
        'type': 'error',
        'error': {'code': 'bad', 'message': 'vendor text'},
      });
      expect(live.notice, LiveText.gptLiveError);
      expect(live.phase, LivePhase.listening);
    });

    test('late-append noise after close is ignored', () {
      peer.event({
        'type': 'error',
        'error': {'code': 'context_injection_incomplete'},
      });
      expect(live.notice, isNull);
    });

    test('junk frames and unknown events are ignored', () {
      peer.event({'type': 'session.something_new'});
      peer.raw('not json');
      peer.raw('[1, 2]');
      expect(live.phase, LivePhase.listening);
      expect(live.lines, isEmpty);
    });

    test('provider close ends the call with the official text', () {
      peer.event({'type': 'session.closed', 'reason': 'limit'});
      expect(live.phase, LivePhase.failed);
      expect(live.failure, LiveText.gptLiveClosed);
      expect(peer.closed, isTrue);
    });

    test('transport loss ends the call with the official text', () {
      peer.lose();
      expect(live.phase, LivePhase.failed);
      expect(live.failure, LiveText.gptLiveLost);
    });
  });

  group('delegation', () {
    late LiveRig rig;
    late LiveController live;
    late FakePeer peer;

    setUp(() async {
      rig = _gptLive();
      peer = rig.peer!;
      live = rig.build();
      await live.start();
    });

    test('runs the user\'s words as a chat turn and returns the final message',
        () async {
      peer.event(_delta(false, 'Hi, how can I help?'));
      peer.event(_delta(true, ' Check  the build '));
      peer.event(_delegation('del_1'));
      await _settle();
      expect(live.phase, LivePhase.thinking);
      expect(rig.brain.asked, ['Check the build']);

      rig.brain.reply('The build is green.');
      await _settle();
      expect(peer.sent, [
        {
          'type': 'session.commentary.append',
          'delegation_id': 'del_1',
          'event_id': 'say_1',
          'content': 'The build is green.',
        },
      ]);
      expect(live.phase, LivePhase.listening);
    });

    test('a long reply goes back in append-sized sentence chunks', () async {
      peer.event(_delta(true, 'read it'));
      peer.event(_delegation('d'));
      await _settle();
      final sentence = '${'word ' * 60}end.';
      rig.brain.reply(List.filled(8, sentence).join(' '));
      await _settle();
      expect(peer.sent.length, greaterThan(1));
      for (final frame in peer.sent) {
        expect(frame['delegation_id'], 'd');
        expect((frame['content'] as String).length, lessThanOrEqualTo(1400));
      }
    });

    test('an empty reply sends a quiet thinking note instead', () async {
      peer.event(_delta(true, 'do it'));
      peer.event(_delegation('d'));
      await _settle();
      rig.brain.reply('');
      await _settle();
      expect(peer.sent.single['type'], 'session.thinking.append');
      expect(peer.sent.single['delegation_id'], 'd');
    });

    test('a failed turn tells the voice and shows the failure', () async {
      peer.event(_delta(true, 'do it'));
      peer.event(_delegation('d'));
      await _settle();
      rig.brain.failTurn('Not delivered.');
      await _settle();
      expect(peer.sent.single['type'], 'session.commentary.append');
      expect(live.notice, 'Not delivered.');
      expect(live.phase, LivePhase.listening);
    });

    test('a repeated delegation id is ignored', () async {
      peer.event(_delta(true, 'one'));
      peer.event(_delegation('d'));
      peer.event(_delegation('d'));
      await _settle();
      expect(rig.brain.asked, ['one']);
    });

    test('a superseded delegation\'s reply is not spoken', () async {
      peer.event(_delta(true, 'first'));
      peer.event(_delegation('d1'));
      await _settle();
      peer.event(_delta(false, 'ok'));
      peer.event(_delta(true, 'no, second'));
      peer.event(_delegation('d2'));
      await _settle();
      rig.brain.reply('first answer');
      await _settle();
      expect(peer.sent, isEmpty);
      expect(rig.brain.asked, ['first', 'no, second']);
      rig.brain.reply('second answer');
      await _settle();
      expect(peer.sent.single['delegation_id'], 'd2');
      expect(peer.sent.single['content'], 'second answer');
    });

    test('replies to ids the provider never opened are refused', () {
      expect(rig.call!.reply('nope', 'text'), isFalse);
      expect(rig.call!.think('nope', 'text'), isFalse);
      expect(peer.sent, isEmpty);
    });

    test('a reply after the call ended stays in the chat only', () async {
      peer.event(_delta(true, 'go'));
      peer.event(_delegation('d'));
      await _settle();
      await live.end();
      rig.brain.reply('late answer');
      await _settle();
      expect(peer.sent.where((f) => f['type'] != 'session.close'), isEmpty);
    });
  });

  group('mute, pause and close', () {
    late LiveRig rig;
    late LiveController live;
    late FakePeer peer;

    setUp(() async {
      rig = _gptLive();
      peer = rig.peer!;
      live = rig.build();
      await live.start();
    });

    test('mute disables the mic track; unmute restores it', () {
      live.toggleMute();
      expect(peer.micEnabled, isFalse);
      expect(live.phase, LivePhase.muted);
      expect(live.muted, isTrue);
      live.toggleMute();
      expect(peer.micEnabled, isTrue);
      expect(live.phase, LivePhase.listening);
    });

    test('background pauses: mic off, paused notice', () {
      live.pause();
      expect(peer.micEnabled, isFalse);
      expect(live.phase, LivePhase.muted);
      expect(live.notice, LiveText.paused);
      live.toggleMute();
      expect(peer.micEnabled, isTrue);
      expect(live.notice, isNull);
    });

    test('close asks the provider to close and tears the peer down', () async {
      await live.end();
      expect(live.phase, LivePhase.ended);
      expect(peer.sent.last, {'type': 'session.close'});
      expect(peer.closed, isTrue);
      peer.event(_delta(false, 'ignored'));
      expect(live.lines, isEmpty);
    });
  });

  group('DashboardLiveHost.createSession', () {
    late List<http.Request> sent;
    DashboardLiveHost host(http.Response Function(http.Request) reply) {
      sent = [];
      final client = MockClient((request) async {
        sent.add(request);
        return reply(request);
      });
      return DashboardLiveHost(
        DashboardClient(host: '10.0.0.5', proxied: true, httpClient: client),
        profile: 'poteto',
      );
    }

    test('posts the offer byte-exact with history, reads the answer', () async {
      final h = host(
        (_) => http.Response(
          jsonEncode({
            'ok': true,
            'session': {'id': 'live_x'},
            'transport': {'type': 'webrtc', 'sdp': 'v=0 answer\r\n'},
          }),
          200,
        ),
      );
      final answer = await h.createSession(
        'v=0 offer\r\n',
        history: [liveHistoryMessage(fromUser: true, text: 'hi')],
      );
      expect(sent.single.method, 'POST');
      expect(sent.single.url.path, '/api/audio/voice-live/session');
      expect(sent.single.url.queryParameters, {'profile': 'poteto'});
      expect(jsonDecode(sent.single.body), {
        'sdp': 'v=0 offer\r\n',
        'history': [
          {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': 'hi'},
            ],
          },
        ],
      });
      expect(answer.sessionId, 'live_x');
      expect(answer.sdp, 'v=0 answer\r\n');
    });

    test('503 (no key on the host) reads as not configured', () async {
      final h = host((_) => http.Response('{"detail":"no key"}', 503));
      await expectLater(
        h.createSession('v=0'),
        throwsA(
          isA<LiveCallSetupFailed>().having(
            (e) => e.message,
            'message',
            LiveText.gptLiveNotConfigured,
          ),
        ),
      );
    });
  });

  test('chunkForCommentary keeps sentences whole under the limit', () {
    expect(chunkForCommentary('  a  b  '), ['a b']);
    expect(chunkForCommentary('One. Two. Three.', limit: 9), ['One. Two.', 'Three.']);
    expect(chunkForCommentary('x' * 25, limit: 10), ['x' * 10, 'x' * 10, 'x' * 5]);
  });
}
