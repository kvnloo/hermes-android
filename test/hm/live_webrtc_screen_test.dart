// The Live Mode screen on a GPT-Live (WebRTC) call, as a user sees it, with
// signalling and the peer/data channel faked.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/avatar/hm_avatar.dart';
import 'package:hermes_android/hm/avatar/hm_avatar_state.dart';
import 'package:hermes_android/hm/features/live/hm_live.dart';
import 'package:hermes_android/hm/features/live/live_strings.dart';
import 'package:hermes_android/hm/hm_bots.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'live_fakes.dart';

final _bot = HmBot.fromJson({
  'name': 'poteto',
  'display_name': 'poteto',
  'model': 'm',
  'provider': 'p',
});

LiveRig _gptLive({FakePeer? peer, FakeHost? host}) => LiveRig(
  host: host ?? FakeHost(mode: 'gpt-live', available: true),
  peer: peer ?? FakePeer(),
);

Future<void> _open(WidgetTester tester, LiveRig rig) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (_, child) =>
          HmLiveScope(background: FakeLiveBackground(), child: child!),
      theme: nextGenTheme(Brightness.dark, NextGenLook.instance),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => presentHmLive(
                context,
                host: HmLiveScope.of(context),
                bot: _bot,
                create: rig.build,
              ),
              child: const Text('chat'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('chat'));
  await _frames(tester);
}

/// The avatars animate forever, so step frames instead of settling.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _status(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('live-status'))).data!;

final _orb = find.descendant(
  of: find.byKey(const ValueKey('live-orb')),
  matching: find.byType(HmAvatar),
);

HmAvatarState _orbState(WidgetTester tester) =>
    tester.widget<HmAvatar>(_orb).state;

Map<String, Object?> _delta(bool user, String text) => {
  'type': user
      ? 'session.input_transcript.delta'
      : 'session.output_transcript.delta',
  'delta': text,
};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NextGenLook.instance
      ..themeMode = ThemeMode.dark
      ..avatarStyle = HmAvatarStyle.syn;
  });

  testWidgets('connecting until the channel opens, then listening', (
    tester,
  ) async {
    final peer = FakePeer(openOnAnswer: false);
    final rig = _gptLive(peer: peer);
    await _open(tester, rig);
    expect(_status(tester), LiveText.connecting);
    expect(rig.host.sessions.single.sdp, 'v=0 offer\r\n');

    peer.openChannel();
    await _frames(tester);
    expect(_status(tester), LiveText.listening);
    expect(_orbState(tester), HmAvatarState.listening);
    expect(find.text(LiveText.you), findsNothing, reason: 'empty transcript');
    expect(rig.ear.listens, 0);
  });

  testWidgets('a call: You in italics, the bot speaking, Working…, reply', (
    tester,
  ) async {
    final rig = _gptLive();
    await _open(tester, rig);
    final peer = rig.peer!;

    peer.event(_delta(false, 'Hi! What can I do?'));
    await _frames(tester);
    expect(_status(tester), LiveText.talkOver);
    expect(_orbState(tester), HmAvatarState.speaking);
    expect(find.text('Hi! What can I do?'), findsOneWidget);
    expect(find.text('poteto'), findsNWidgets(2));

    peer.event(_delta(true, 'Is the deploy done?'));
    peer.event({
      'type': 'session.delegation.created',
      'delegation': {'id': 'del_1'},
    });
    await _frames(tester);
    expect(_status(tester), LiveText.working);
    expect(_orbState(tester), HmAvatarState.thinking);
    final said = tester.widget<Text>(find.text('Is the deploy done?'));
    expect(said.style?.fontStyle, FontStyle.italic);
    expect(find.text(LiveText.you), findsOneWidget);
    expect(rig.brain.asked, ['Is the deploy done?']);

    rig.brain.reply('Yes, it finished at noon.');
    await _frames(tester);
    expect(peer.sent.single['type'], 'session.commentary.append');
    expect(peer.sent.single['delegation_id'], 'del_1');
    expect(peer.sent.single['content'], 'Yes, it finished at noon.');
    expect(_status(tester), LiveText.listening);

    // The voice says it; quiet after it settles back to listening.
    peer.event(_delta(false, 'It finished at noon.'));
    await _frames(tester);
    expect(_status(tester), LiveText.talkOver);
    await tester.pump(const Duration(seconds: 2));
    expect(_status(tester), LiveText.listening);
  });

  testWidgets('mic button mutes the track', (tester) async {
    final rig = _gptLive();
    await _open(tester, rig);
    await tester.tap(find.bySemanticsLabel(LiveText.mute));
    await _frames(tester);
    expect(_status(tester), LiveText.muted);
    expect(rig.peer!.micEnabled, isFalse);
    await tester.tap(find.bySemanticsLabel(LiveText.unmute));
    await _frames(tester);
    expect(_status(tester), LiveText.listening);
    expect(rig.peer!.micEnabled, isTrue);
  });

  testWidgets('close tears the call down and returns to the chat', (
    tester,
  ) async {
    final rig = _gptLive();
    await _open(tester, rig);
    await tester.tap(find.bySemanticsLabel(LiveText.end));
    await _frames(tester);
    expect(find.byType(HmLiveScreen), findsNothing);
    expect(rig.peer!.closed, isTrue);
    expect(rig.peer!.sent.last, {'type': 'session.close'});
  });

  testWidgets('the connection drops and comes back: reconnecting, then on', (
    tester,
  ) async {
    final rig = LiveRig(
      host: FakeHost(mode: 'gpt-live', available: true),
      peer: FakePeer(),
      redialPeer: FakePeer.new,
    );
    await _open(tester, rig);
    rig.peer!.event({
      'type': 'session.output_transcript.delta',
      'delta': 'Still checking.',
    });
    await _frames(tester);
    rig.peer!.lose();
    await _frames(tester);
    expect(_status(tester), LiveText.connecting);
    expect(find.text(LiveText.gptLiveReconnecting), findsOneWidget);
    expect(find.text('Still checking.'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await _frames(tester);
    expect(rig.peers, hasLength(2));
    expect(find.text(LiveText.gptLiveReconnecting), findsNothing);
    expect(find.text('Still checking.'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(LiveText.end));
    await _frames(tester);
    expect(find.byType(HmLiveScreen), findsNothing);
  });

  testWidgets('the connection stays down: official error, close still works', (
    tester,
  ) async {
    final rig = LiveRig(
      host: FakeHost(mode: 'gpt-live', available: true),
      peer: FakePeer(),
      redialPeer: () => FakePeer(offerError: StateError('offline')),
    );
    await _open(tester, rig);
    rig.peer!.lose();
    await _frames(tester);
    // 1 + 2 + 4 + 8 + 16 s of backoff, every redial failing.
    for (var i = 0; i < 31; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await _frames(tester);
    expect(rig.peers, hasLength(6));
    expect(_status(tester), LiveText.gptLiveLost);
    expect(_orbState(tester), HmAvatarState.error);
    await tester.tap(find.bySemanticsLabel(LiveText.end));
    await _frames(tester);
    expect(find.byType(HmLiveScreen), findsNothing);
  });

  testWidgets('35 s without the channel: falls back to the chained loop', (
    tester,
  ) async {
    final peer = FakePeer(openOnAnswer: false);
    final rig = _gptLive(peer: peer);
    await _open(tester, rig);
    expect(_status(tester), LiveText.connecting);

    await tester.pump(const Duration(seconds: 34));
    expect(_status(tester), LiveText.connecting);
    await tester.pump(const Duration(seconds: 1));
    await _frames(tester);
    expect(peer.closed, isTrue);
    expect(_status(tester), LiveText.listening);
    expect(find.text(LiveText.gptLiveCouldNotConnect), findsOneWidget);
    expect(rig.ear.listening, isTrue, reason: 'the chained loop listens');

    // The chained loop works as before.
    rig.ear.hear('hello');
    await _frames(tester);
    expect(rig.brain.asked, ['hello']);
  });

  testWidgets('GPT-Live selected but not set up: notice, chained loop', (
    tester,
  ) async {
    final rig = _gptLive(host: FakeHost(mode: 'gpt-live', available: false));
    await _open(tester, rig);
    expect(_status(tester), LiveText.listening);
    expect(find.text(LiveText.gptLiveNotConfigured), findsOneWidget);
    expect(rig.host.sessions, isEmpty);
  });
}
