import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:hermes_android/hm/features/live/hm_live.dart';
import 'package:hermes_android/hm/features/live/live_approval.dart';
import 'package:hermes_android/hm/features/live/live_session_host.dart';
import 'package:hermes_android/hm/hm_bots.dart';
import 'package:hermes_android/nextgen/data/chat_controller.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'live_fakes.dart';

final _alpha = HmBot.fromJson({'name': 'alpha', 'display_name': 'Alpha'});
final _beta = HmBot.fromJson({'name': 'beta', 'display_name': 'Beta'});
const _pill = ValueKey('live-mini');

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<LiveSessionHost> _mount(
  WidgetTester tester,
  LiveRig first,
  LiveRig second,
  FakeLiveBackground native, {
  NgChatController? chat,
  VoidCallback? approved,
}) async {
  final policy = ValueNotifier(true);
  addTearDown(policy.dispose);
  late LiveSessionHost host;
  await tester.pumpWidget(
    MaterialApp(
      builder: (_, child) =>
          HmLiveScope(background: native, policy: policy, child: child!),
      home: Builder(
        builder: (context) {
          host = HmLiveScope.of(context);
          return Scaffold(
            body: Column(
              children: [
                TextButton(
                  onPressed: () => presentHmLive(
                    context,
                    host: host,
                    bot: _alpha,
                    create: () {
                      final live = first.build();
                      if (chat != null) {
                        host.bindChat(chat, approved ?? () {});
                        live.approval = host.approval;
                        live.onRequestAction = host.act;
                        chat.addListener(first.brain.refresh);
                      }
                      return live;
                    },
                  ),
                  child: const Text('Start Alpha'),
                ),
                TextButton(
                  onPressed: () => presentHmLive(
                    context,
                    host: host,
                    bot: _beta,
                    create: second.build,
                  ),
                  child: const Text('Start Beta'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(body: Text('Settings')),
                    ),
                  ),
                  child: const Text('Settings'),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
  await tester.tap(find.text('Start Alpha'));
  await _frames(tester);
  return host;
}

NextGenGateway _gateway() => NextGenGateway(
  SavedConnection(
    id: 'fixture',
    label: 'Fixture',
    host: 'fixture',
    port: 80,
    apiKey: '',
  ),
);

GatewayServerRequest _request(
  String session,
  String id,
  String method,
  List<Map<String, dynamic>> answers,
) => GatewayServerRequest.forTesting(
  id: id,
  method: method,
  params: {
    'session_id': session,
    'command': 'Read notes',
    'question': 'Which notes?',
  },
  respond: (answer) {
    answers.add(answer);
    return true;
  },
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'matching never approves a negation, compound command or partial word',
    () {
      expect(matchLiveRequest(' Allow once! '), LiveRequestAction.allow);
      expect(matchLiveRequest('deny'), LiveRequestAction.deny);
      expect(matchLiveRequest('open it.'), LiveRequestAction.open);
      for (final phrase in [
        'don’t allow',
        'allow or deny',
        'allow always',
        'allow it then deny',
        'allowed',
        'allowing',
        'can I allow?',
        'allow this?',
        'allow?',
      ]) {
        expect(matchLiveRequest(phrase), isNull, reason: phrase);
      }
    },
  );

  testWidgets(
    'minimize, push settings and pop preserve the same mic; pill End stops it',
    (tester) async {
      final rig = LiveRig();
      final host = await _mount(tester, rig, LiveRig(), FakeLiveBackground());
      final live = host.live;
      expect(find.byKey(_pill), findsNothing);
      await tester.tap(find.bySemanticsLabel('Minimize'));
      await _frames(tester);
      expect(find.byKey(_pill), findsOneWidget);
      expect(rig.ear.listens, 1);
      await tester.tap(find.text('Settings'));
      await _frames(tester);
      expect(find.byKey(_pill), findsOneWidget);
      await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await _frames(tester);
      expect(host.live, same(live));
      expect(rig.ear.stops, 0);
      await tester.tap(find.byIcon(Icons.call_end_rounded));
      await _frames(tester);
      expect(host.live, isNull);
      expect(find.byKey(_pill), findsNothing);
      expect(rig.ear.stops, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'notification actions target the running call and End closes it',
    (tester) async {
      final native = FakeLiveBackground(available: true);
      final rig = LiveRig();
      final host = await _mount(tester, rig, LiveRig(), native);
      final token = native.starts.single;
      native.callback?.call('end', token - 1);
      expect(host.active, isTrue);
      native.action('mute');
      expect(host.live?.muted, isTrue);
      native.action('end');
      await _frames(tester);
      expect(host.active, isFalse);
      expect(find.byType(HmLiveScreen), findsNothing);
      expect(native.stops, [token]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'unavailable foreground service pauses and resumes without losing the call',
    (tester) async {
      final rig = LiveRig();
      final native = FakeLiveBackground();
      final host = await _mount(tester, rig, LiveRig(), native);
      final started = host.live;
      host.didChangeAppLifecycleState(AppLifecycleState.hidden);
      host.didChangeAppLifecycleState(AppLifecycleState.paused);
      await _frames(tester);
      expect(started?.paused, isTrue);
      expect(rig.ear.listening, isFalse);
      expect(find.byKey(const ValueKey('live-status')), findsOneWidget);
      host.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _frames(tester);
      expect(host.live, same(started));
      expect(started?.paused, isFalse);
      expect(rig.ear.listens, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'second bot requires one explicit choice; Keep leaves the original call intact',
    (tester) async {
      final first = LiveRig();
      final second = LiveRig();
      final host = await _mount(tester, first, second, FakeLiveBackground());
      await tester.tap(find.bySemanticsLabel('Minimize'));
      await _frames(tester);
      await tester.tap(find.text('Start Beta'));
      await _frames(tester);
      expect(find.text('Switch Live to Beta?'), findsOneWidget);
      await tester.tap(find.text('Keep call'));
      await _frames(tester);
      expect(host.bot, same(_alpha));
      expect(second.ear.listens, 0);
      await tester.tap(find.text('Start Beta'));
      await _frames(tester);
      await tester.tap(find.text('Switch'));
      await _frames(tester);
      expect(host.bot, same(_beta));
      expect(first.ear.stops, 1);
      expect(second.ear.listens, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'socket requests from other chats stay there; this chat uses the strip and exact speech',
    (tester) async {
      final gateway = _gateway();
      final chat = NgChatController(gateway)..runtimeId = 'mine';
      final other = NgChatController(gateway)..runtimeId = 'other';
      final answers = <Map<String, dynamic>>[];
      final rig = LiveRig();
      var returned = 0;
      final host = await _mount(
        tester,
        rig,
        LiveRig(),
        FakeLiveBackground(),
        chat: chat,
        approved: () => returned++,
      );
      await tester.tap(find.bySemanticsLabel('Minimize'));
      await _frames(tester);
      gateway.debugRequest(_request('other', 'r1', 'approval', answers));
      await _frames(tester);
      expect(other.request?.request.id, 'r1');
      expect(host.approval?.pending, isNull);
      expect(find.byIcon(Icons.check), findsNothing);
      gateway.debugRequest(_request('mine', 'r2', 'approval', answers));
      await _frames(tester);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(rig.voice.spoken, hasLength(1));
      rig.voice.finish();
      await _frames(tester);
      rig.ear.hear('allow or deny');
      await _frames(tester);
      expect(answers, isEmpty);
      expect(rig.voice.spoken, hasLength(2));
      rig.voice.finish();
      await _frames(tester);
      rig.ear.hear('allow');
      await _frames(tester);
      expect(answers, [
        {'choice': 'once'},
      ]);
      expect(other.request?.request.id, 'r1');
      host.onReturn?.call();
      await _frames(tester);
      await tester.tap(find.bySemanticsLabel('Minimize'));
      await _frames(tester);
      expect(returned, 1);
      chat.removeListener(rig.brain.refresh);
      await tester.pumpWidget(const SizedBox());
      chat.dispose();
      other.dispose();
      gateway.dispose();
    },
  );
  testWidgets(
    'WebRTC confirms an exact final utterance and keeps blocked delegation',
    (tester) async {
      final gateway = _gateway();
      final chat = NgChatController(gateway)..runtimeId = 'mine';
      final answers = <Map<String, dynamic>>[];
      final peer = FakePeer();
      final rig = LiveRig(
        host: FakeHost(mode: 'gpt-live', available: true),
        peer: peer,
      );
      final native = FakeLiveBackground(available: true);
      final host = await _mount(tester, rig, LiveRig(), native, chat: chat);
      void delta(String text) =>
          peer.event({'type': 'session.input_transcript.delta', 'delta': text});
      void complete(String text) => peer.event({
        'type': 'session.input_transcript.done',
        'transcript': text,
      });
      delta('Read notes');
      complete('Read notes');
      peer.event({
        'type': 'session.delegation.created',
        'delegation': {'id': 'notes'},
      });
      await _frames(tester);
      expect(rig.brain.asked, ['Read notes']);

      gateway.debugRequest(_request('mine', 'rtc', 'approval', answers));
      await _frames(tester);
      expect(peer.micEnabled, isFalse);
      rig.voice.finish();
      await _frames(tester);
      expect(peer.micEnabled, isTrue);
      host.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(peer.micEnabled, isTrue);
      expect(host.live?.paused, isFalse);
      delta('allow');
      expect(answers, isEmpty);
      delta(' or deny');
      complete('allow');
      expect(answers, isEmpty);
      await _frames(tester);
      rig.voice.finish();
      await _frames(tester);
      delta('allow');
      complete('Allow.');
      expect(answers, [
        {'choice': 'once'},
      ]);
      peer.event({
        'type': 'session.delegation.created',
        'delegation': {'id': 'approval-utterance'},
      });
      rig.brain.reply('Here are the notes.');
      await _frames(tester);
      expect(rig.brain.asked, ['Read notes']);
      expect(
        peer.sent.any(
          (event) =>
              event['type'] == 'session.commentary.append' &&
              event['delegation_id'] == 'notes',
        ),
        isTrue,
      );
      chat.removeListener(rig.brain.refresh);
      await tester.pumpWidget(const SizedBox());
      chat.dispose();
      gateway.dispose();
    },
  );

  testWidgets(
    'a card delivered while minimized flags the pill without reading the fence',
    (tester) async {
      final rig = LiveRig();
      final host = await _mount(tester, rig, LiveRig(), FakeLiveBackground());
      rig.ear.hear('Show me a card');
      await _frames(tester);
      await tester.tap(find.bySemanticsLabel('Minimize'));
      await _frames(tester);
      const card = '{"kind":"card.v0"}';
      rig.brain.reply('Here it is.\n\n```ephemeral-ui\n$card\n```');
      await _frames(tester);
      expect(find.byIcon(Icons.fiber_manual_record), findsOneWidget);
      expect(rig.voice.spoken, ['Here it is.']);
      host.onReturn?.call();
      await _frames(tester);
      expect(host.newCard, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
