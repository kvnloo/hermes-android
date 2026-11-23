// The live call's state machine, driven through fake seams, plus the HTTP
// adapter (requests as they go out) and the chat adapter.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/hm/features/live/live_controller.dart';
import 'package:hermes_android/hm/features/live/live_strings.dart';
import 'package:hermes_android/hm/features/live/live_transport.dart';
import 'package:hermes_android/nextgen/data/chat_controller.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'live_fakes.dart';

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('LiveController', () {
    test('connects, then listens', () async {
      final rig = LiveRig();
      final live = rig.build();
      expect(live.phase, LivePhase.connecting);
      await live.start();
      expect(rig.host.statusCalls, 1);
      expect(live.phase, LivePhase.listening);
      expect(rig.ear.listening, isTrue);
    });

    test(
      'a heard utterance becomes a turn, is spoken, then listens again',
      () async {
        final rig = LiveRig();
        final live = rig.build();
        await live.start();

        rig.ear.hearPartial('what is');
        expect(live.partial, 'what is');

        rig.ear.hear('what is the weather');
        expect(live.phase, LivePhase.thinking);
        expect(rig.brain.asked, ['what is the weather']);
        expect(live.partial, isEmpty);

        rig.brain.reply('Sunny and warm.');
        await _settle();
        expect(live.phase, LivePhase.speaking);
        expect(rig.voice.spoken, ['Sunny and warm.']);

        rig.voice.finish();
        await _settle();
        expect(live.phase, LivePhase.listening);
        expect(rig.ear.listens, 2);
        expect(live.lines.map((l) => l.fromUser), [true, false]);
      },
    );

    test('silence re-arms the mic without sending a turn', () async {
      final rig = LiveRig();
      final live = rig.build();
      await live.start();
      rig.ear.hear('   ');
      expect(rig.brain.asked, isEmpty);
      expect(live.phase, LivePhase.listening);
      expect(rig.ear.listens, 2);
    });

    test(
      'tapping the orb while it speaks stops playback and listens',
      () async {
        final rig = LiveRig();
        final live = rig.build();
        await live.start();
        rig.ear.hear('tell me a story');
        rig.brain.reply('Once upon a time…');
        await _settle();
        expect(live.phase, LivePhase.speaking);

        await live.interrupt();
        expect(rig.voice.stops, 1);
        expect(live.phase, LivePhase.listening);
        expect(rig.ear.listens, 2);
      },
    );

    test('mute stops the mic; unmute listens again', () async {
      final rig = LiveRig();
      final live = rig.build();
      await live.start();
      live.toggleMute();
      expect(live.phase, LivePhase.muted);
      expect(live.muted, isTrue);
      expect(rig.ear.stops, 1);

      live.toggleMute();
      expect(live.phase, LivePhase.listening);
      expect(rig.ear.listens, 2);
    });

    test('muting mid-turn lets the reply play, then stays muted', () async {
      final rig = LiveRig();
      final live = rig.build();
      await live.start();
      rig.ear.hear('hi');
      live.toggleMute();
      expect(live.phase, LivePhase.thinking);
      rig.brain.reply('Hello!');
      await _settle();
      expect(live.phase, LivePhase.speaking);
      rig.voice.finish();
      await _settle();
      expect(live.phase, LivePhase.muted);
      expect(rig.ear.listens, 1);
    });

    test('end stops mic and voice and ignores the late reply', () async {
      final rig = LiveRig();
      final live = rig.build();
      await live.start();
      rig.ear.hear('long task');
      await live.end();
      expect(live.phase, LivePhase.ended);
      expect(rig.ear.stops, 1);
      expect(rig.voice.stops, 1);

      // The turn still finishes in the chat, but the call stays ended.
      rig.brain.reply('Done.');
      await _settle();
      expect(live.phase, LivePhase.ended);
      expect(rig.voice.spoken, isEmpty);
    });

    test('a failed turn shows its reason and keeps listening', () async {
      final rig = LiveRig();
      final live = rig.build();
      await live.start();
      rig.ear.hear('hello');
      rig.brain.failTurn('Not delivered. Retry');
      await _settle();
      expect(live.notice, 'Not delivered. Retry');
      expect(live.phase, LivePhase.listening);
    });

    test('mic permission denied fails with the official text', () async {
      final rig = LiveRig(ear: FakeEar(access: LiveMicAccess.denied));
      final live = rig.build();
      await live.start();
      expect(live.phase, LivePhase.failed);
      expect(live.failure, LiveText.micOff);
    });

    test('no recognizer fails with the official text', () async {
      final rig = LiveRig(ear: FakeEar(access: LiveMicAccess.unavailable));
      final live = rig.build();
      await live.start();
      expect(live.failure, LiveText.micCouldNotOpen);
    });

    test('a host without voice routes fails with the official text', () async {
      final rig = LiveRig(host: FakeHost(statusError: const LiveNoVoiceApi()));
      final live = rig.build();
      await live.start();
      expect(live.phase, LivePhase.failed);
      expect(live.failure, LiveText.noVoiceApi);
      expect(rig.ear.listens, 0);
    });

    test('an unreachable host asks to reconnect', () async {
      final rig = LiveRig(host: FakeHost(statusError: Exception('offline')));
      final live = rig.build();
      await live.start();
      expect(live.failure, LiveText.reconnect);
    });

    test(
      'three recognizer errors in a row end in the restart failure',
      () async {
        final rig = LiveRig();
        final live = rig.build();
        await live.start();
        rig.ear.fail('busy');
        rig.ear.fail('busy');
        expect(live.phase, LivePhase.listening);
        rig.ear.fail('busy');
        expect(live.phase, LivePhase.failed);
        expect(live.failure, LiveText.micCouldNotRestart);
      },
    );

    test('backgrounding releases the mic and says so', () async {
      final rig = LiveRig();
      final live = rig.build();
      await live.start();
      live.pause();
      expect(live.phase, LivePhase.muted);
      expect(live.notice, LiveText.paused);
      expect(rig.ear.stops, 1);
      live.resume();
      await _settle();
      expect(live.phase, LivePhase.listening);
      expect(live.notice, isNull);
    });

    test('the on-device voice notice appears after a device reply', () async {
      final rig = LiveRig();
      final live = rig.build();
      await live.start();
      rig.ear.hear('hi');
      rig.brain.reply('Hello.');
      await _settle();
      rig.voice.onDevice = true;
      rig.voice.finish();
      await _settle();
      expect(live.notice, LiveText.speechOnDevice);
    });
  });

  group('DashboardLiveHost', () {
    late List<http.Request> sent;
    DashboardLiveHost host(
      http.Response Function(http.Request) reply, {
      String? profile,
    }) {
      sent = [];
      final client = MockClient((request) async {
        sent.add(request);
        return reply(request);
      });
      return DashboardLiveHost(
        DashboardClient(host: '10.0.0.5', proxied: true, httpClient: client),
        profile: profile,
      );
    }

    test('reads voice-live status for the bot profile', () async {
      final h = host(
        (_) => http.Response(
          jsonEncode({'ok': true, 'mode': 'gpt-live', 'available': true}),
          200,
          headers: {'content-type': 'application/json'},
        ),
        profile: 'poteto',
      );
      final status = await h.status();
      expect(sent.single.method, 'GET');
      expect(sent.single.url.path, '/api/audio/voice-live/status');
      expect(sent.single.url.queryParameters, {'profile': 'poteto'});
      expect(status.mode, 'gpt-live');
      expect(status.gptLiveAvailable, isTrue);
    });

    test('a 404 means the host has no voice API', () async {
      final h = host((_) => http.Response('{"detail":"Not Found"}', 404));
      await expectLater(h.status(), throwsA(isA<LiveNoVoiceApi>()));
    });

    test('speak posts the text and decodes the data URL', () async {
      final h = host(
        (_) => http.Response(
          jsonEncode({
            'ok': true,
            'data_url': 'data:audio/mpeg;base64,${base64Encode([1, 2, 3])}',
            'mime_type': 'audio/mpeg',
          }),
          200,
        ),
      );
      final speech = await h.speak('Hello there');
      expect(sent.single.method, 'POST');
      expect(sent.single.url.path, '/api/audio/speak');
      expect(jsonDecode(sent.single.body), {'text': 'Hello there'});
      expect(speech.bytes, [1, 2, 3]);
      expect(speech.mimeType, 'audio/mpeg');
    });
  });

  group('ChatLiveBrain', () {
    test('sends through the chat and returns the finished reply', () async {
      final chat = _Chat();
      chat.items.add(NgUserItem('old', 'earlier message'));
      final brain = ChatLiveBrain(chat);
      expect(brain.lines, isEmpty, reason: 'only this call\'s turns show');

      final reply = brain.ask('what time is it');
      await _settle();
      expect(chat.sent, ['what time is it']);
      chat.finish('It is noon.');
      expect(await reply, 'It is noon.');
      expect(brain.lines.map((l) => (l.fromUser, l.text)), [
        (true, 'what time is it'),
        (false, 'It is noon.'),
      ]);
    });

    test('a refused send throws the item failure', () async {
      final chat = _Chat()..refuse = 'Not delivered. Retry';
      final brain = ChatLiveBrain(chat);
      await expectLater(
        brain.ask('hi'),
        throwsA(
          isA<LiveTurnFailed>().having(
            (e) => e.message,
            'message',
            'Not delivered. Retry',
          ),
        ),
      );
    });
  });
}

class _Chat extends NgChatController {
  _Chat()
    : super(
        NextGenGateway(
          SavedConnection(
            id: 'c1',
            label: 'Home',
            host: '10.0.0.5',
            port: 9119,
            apiKey: '',
            desktopGatewayUrl: 'http://10.0.0.5:9119',
            singleLogin: true,
            signInMethod: 'none',
            dashboardProxied: true,
          ),
        ),
      );

  final List<String> sent = [];
  String? refuse;

  @override
  Future<bool> send(
    String text, {
    List<AttachmentDraft> attachments = const [],
    String? submissionId,
  }) async {
    sent.add(text);
    final item = NgUserItem('u${items.length}', text);
    items.add(item);
    if (refuse != null) {
      item.failure = refuse;
      return false;
    }
    running = true;
    notifyListeners();
    return true;
  }

  void finish(String text) {
    items.add(NgAssistantItem('a${items.length}')..text = text);
    running = false;
    notifyListeners();
  }
}
