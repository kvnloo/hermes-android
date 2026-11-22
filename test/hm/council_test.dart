import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dashboard_api_client.dart';
import 'package:hermes_android/hm/features/council/council_reader.dart';
import 'package:hermes_android/hm/features/council/council_run.dart';
import 'package:hermes_android/hm/features/council/hm_council.dart';
import 'package:hermes_android/hm/features/council/hm_council_session.dart';
import 'package:hermes_android/hm/hm_bots.dart';
import 'package:hermes_android/hm/screens/hm_chat_screen.dart';
import 'package:hermes_android/hm/screens/hm_home.dart';
import 'package:hermes_android/nextgen/data/chat_controller.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Speaks nothing; each sentence waits until the test finishes it.
class FakeVoice implements CouncilVoice {
  final spoken = <String>[];
  Completer<bool>? pending;
  int stops = 0;
  bool fail = false;

  @override
  Future<bool> speak(String text) {
    spoken.add(text);
    if (fail) return Future.value(false);
    return (pending = Completer<bool>()).future;
  }

  void finish() {
    final p = pending;
    pending = null;
    p?.complete(true);
  }

  @override
  Future<void> stop() async {
    stops++;
    final p = pending;
    pending = null;
    if (p != null && !p.isCompleted) p.complete(false);
  }

  @override
  void dispose() {}
}

Map<String, Object?> _run({Object? extra}) => {
  'schema': councilSchema,
  'brief': 'Pick one.',
  'rounds': 1,
  'seats': [
    {'id': 'a', 'name': 'A', 'family': 'Anthropic'},
    {'id': 'b', 'name': 'B', 'family': 'OpenAI'},
  ],
  'events': [
    {'type': 'spawn', 'seat': 'a'},
    {
      'type': 'turn',
      'seat': 'b',
      'round': 1,
      'cites': ['a'],
    },
  ],
  'verdicts': [
    {'seat': 'a', 'stance': 'abstain', 'text': 'Not sure'},
    {'seat': 'b', 'stance': 'agree', 'text': 'Yes. Clearly!'},
  ],
  'extra': ?extra,
};

Widget _app(Widget home, {bool reduce = false}) => MaterialApp(
  home: home,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
    child: child!,
  ),
);

void main() {
  group('council run', () {
    test('the demo run parses into four seats with family minerals', () {
      final run = demoCouncilRun();
      expect(run.seats.map((s) => s.name), ['Argon', 'Astra', 'Fable', 'Opus']);
      expect(run.seats.map((s) => s.mineral), [
        CouncilMineral.malachite,
        CouncilMineral.labradorite,
        CouncilMineral.rose,
        CouncilMineral.citrine,
      ]);
      expect(run.constraints, hasLength(2));
      expect(run.turns, hasLength(16));
      expect(councilTally(run), '3 of 4 agree · 1 dissent');
      expect(run.receiptOf(0), 'Round 4: Argon cited Astra.');
    });

    test('a glide.council-run/v1 snapshot reads unchanged', () {
      final run = parseCouncilRun(_run());
      expect(run.verdictOf(0)!.stance, CouncilStance.abstain);
      expect(run.seats[1].mineral, CouncilMineral.labradorite);
      expect(run.receiptOf(1), 'Round 1: B cited A.');
      expect(run.receiptOf(0), isNull);
      expect(councilOutcome(run), 'The council has spoken');
    });

    test('malformed snapshots are refused, never guessed at', () {
      expect(
        () => parseCouncilRun(_run(extra: 1)),
        throwsA(isA<CouncilParseError>()),
      );
      expect(
        () => parseCouncilRun({..._run(), 'schema': 'other'}),
        throwsA(isA<CouncilParseError>()),
      );
      expect(
        () => parseCouncilRun({
          ..._run(),
          'verdicts': [
            {'seat': 'a', 'stance': 'agree', 'text': 'x'},
            {'seat': 'a', 'stance': 'agree', 'text': 'y'},
          ],
        }),
        throwsA(
          isA<CouncilParseError>().having(
            (e) => e.message,
            'message',
            contains('already has a verdict'),
          ),
        ),
      );
      expect(
        () => parseCouncilRun({
          ..._run(),
          'verdicts': [
            {'seat': 'z', 'stance': 'agree', 'text': 'x'},
          ],
        }),
        throwsA(isA<CouncilParseError>()),
      );
    });

    test('read-aloud order: brief, each report, then the verdict', () {
      final passages = councilPassages(parseCouncilRun(_run()));
      expect(passages.map((p) => p.key), [
        'brief',
        'seat:a',
        'seat:b',
        'verdict',
      ]);
      expect(passages.map((p) => p.seat), [null, 0, 1, null]);
      expect(passages[1].text, 'A abstains. Not sure.');
      expect(councilSentences(passages[2].text), [
        'B agrees.',
        'Yes.',
        'Clearly!',
      ]);
      expect(
        passages.last.text,
        'The council has spoken. 1 of 2 agree, 1 abstain.',
      );
    });
  });

  group('council reader', () {
    test('reads sentence by sentence and ends back on the card', () async {
      final voice = FakeVoice();
      final reader = CouncilReader(parseCouncilRun(_run()), voice);
      final done = reader.readOne('seat:b');
      await pumpEventQueue();
      expect(reader.isReading('seat:b'), isTrue);
      expect(reader.caption, 'B agrees.');
      voice.finish();
      await pumpEventQueue();
      expect(reader.caption, 'Yes.');
      voice.finish();
      await pumpEventQueue();
      voice.finish();
      await done;
      expect(voice.spoken, ['B agrees.', 'Yes.', 'Clearly!']);
      expect(reader.reading, isFalse);
      expect(reader.warning, isNull);
      reader.dispose();
    });

    test('stop cancels the reading; nothing more is spoken', () async {
      final voice = FakeVoice();
      final reader = CouncilReader(parseCouncilRun(_run()), voice);
      final done = reader.readAll();
      await pumpEventQueue();
      expect(reader.passage!.key, 'brief');
      await reader.stop();
      await done;
      expect(reader.reading, isFalse);
      expect(voice.spoken, ['The brief.']);
      reader.dispose();
    });

    test('unavailable speech warns and leaves the text usable', () async {
      final voice = FakeVoice()..fail = true;
      final reader = CouncilReader(parseCouncilRun(_run()), voice);
      await reader.readAll();
      expect(voice.spoken, hasLength(1));
      expect(reader.reading, isFalse);
      expect(reader.warning, contains('unavailable'));
      reader.dispose();
    });
  });

  group('council screen', () {
    testWidgets('renders the brief, every report and the verdict', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(HmCouncilScreen(source: CouncilSource.demo(), voice: FakeVoice())),
      );
      expect(find.text('Council'), findsOneWidget);
      expect(find.text('DEMO'), findsOneWidget);
      expect(find.textContaining('no council RPC'), findsOneWidget);
      expect(
        find.text('Should a small team ship a plugin before its launcher?'),
        findsOneWidget,
      );
      expect(find.text('· Keep the first release small.'), findsOneWidget);
      for (final name in ['Argon', 'Astra', 'Fable', 'Opus']) {
        expect(find.text(name), findsOneWidget);
        expect(
          find.byKey(ValueKey('council-orb-seat:${name.toLowerCase()}')),
          findsOneWidget,
        );
      }
      expect(
        find.text(
          'Without the launcher nobody finds the plugin; ship both together.',
        ),
        findsOneWidget,
      );
      expect(find.text('DISSENTS'), findsOneWidget);
      expect(find.text('AGREES'), findsNWidgets(3));
      await tester.scrollUntilVisible(find.text('Ship the plugin first'), 200);
      expect(find.text('3 of 4 agree · 1 dissent'), findsOneWidget);
    });

    testWidgets('a report plays through its own orb; a tap returns', (
      tester,
    ) async {
      final voice = FakeVoice();
      await tester.pumpWidget(
        _app(HmCouncilScreen(source: CouncilSource.demo(), voice: voice)),
      );
      await tester.tap(find.byTooltip("Read Astra's report aloud"));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('council-speaking-orb')),
        findsOneWidget,
      );
      expect(find.text('ASTRA'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('council-caption'))).data,
        'Astra dissents.',
      );
      voice.finish();
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('council-caption'))).data,
        'Without the launcher nobody finds the plugin; ship both together.',
      );
      expect(voice.spoken.last, contains('ship both together'));

      await tester.tap(find.byKey(const ValueKey('council-speaking')));
      await tester.pump();
      expect(find.byKey(const ValueKey('council-speaking')), findsNothing);
      expect(voice.stops, greaterThan(0));
      expect(find.text('Astra'), findsOneWidget);
    });

    testWidgets('Read all walks brief, reports and verdict in order', (
      tester,
    ) async {
      final voice = FakeVoice();
      await tester.pumpWidget(
        _app(
          HmCouncilScreen(source: CouncilSource.demo(), voice: voice),
          reduce: true,
        ),
      );
      await tester.tap(find.byTooltip('Read all'));
      await tester.pump();
      expect(find.text('THE BRIEF'), findsWidgets);
      final labels = <String>[];
      for (var i = 0; i < 40 && voice.pending != null; i++) {
        labels.add(voice.spoken.last);
        voice.finish();
        // Reduced motion: the orb is still, so the frame settles.
        await tester.pumpAndSettle();
      }
      expect(find.byKey(const ValueKey('council-speaking')), findsNothing);
      expect(labels.first, 'The brief.');
      expect(labels, contains('Argon agrees.'));
      expect(labels, contains('Opus agrees.'));
      expect(labels.last, '3 of 4 agree, 1 dissent.');
      expect(
        labels.indexOf('Argon agrees.'),
        lessThan(labels.indexOf('Ship the plugin first.')),
      );
    });

    testWidgets('unavailable speech shows a warning on the card', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          HmCouncilScreen(
            source: CouncilSource.demo(),
            voice: FakeVoice()..fail = true,
          ),
        ),
      );
      await tester.tap(find.byTooltip('Read the brief aloud'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('council-warning')), findsOneWidget);
      expect(find.byKey(const ValueKey('council-speaking')), findsNothing);
    });

    testWidgets('back while reading returns to the card first', (tester) async {
      final voice = FakeVoice();
      await tester.pumpWidget(_app(const SizedBox()));
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        nav.push(
          MaterialPageRoute<void>(
            builder: (_) =>
                HmCouncilScreen(source: CouncilSource.demo(), voice: voice),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Read all'));
      await tester.pump();
      expect(find.byKey(const ValueKey('council-speaking')), findsOneWidget);
      await nav.maybePop();
      await tester.pump();
      expect(find.byKey(const ValueKey('council-speaking')), findsNothing);
      expect(find.byType(HmCouncilScreen), findsOneWidget);
      await nav.maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(HmCouncilScreen), findsNothing);
    });

    testWidgets('a saved council can read an individual report aloud', (
      tester,
    ) async {
      final voice = FakeVoice();
      var content = 'not JSON';
      final dashboard = DashboardClient(
        host: 'gateway.test',
        proxied: true,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'messages': [
                {'role': 'assistant', 'content': content},
              ],
            }),
            200,
          ),
        ),
      );
      addTearDown(dashboard.close);
      await tester.pumpWidget(
        _app(
          HmCouncilSessionScreen(
            api: DashboardApiClient.withDashboard(dashboard),
            sessionId: 'saved-council',
            voice: voice,
          ),
          reduce: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('This council snapshot could not be read.'),
        findsOneWidget,
      );
      expect(voice.spoken, isEmpty);
      content = jsonEncode(_run());
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip("Read B's report aloud"));
      await tester.pump();
      expect(voice.spoken, ['B agrees.']);
      voice.finish();
      await tester.pump();
      expect(find.text('Yes.'), findsOneWidget);
      expect(voice.spoken, ['B agrees.', 'Yes.']);
      await tester.tap(find.byKey(const ValueKey('council-speaking')));
      await tester.pump();
      expect(find.text('Session: saved-council'), findsOneWidget);
    });

    testWidgets('the chat More menu opens the council', (tester) async {
      final gateway = NextGenGateway(
        SavedConnection(
          id: 'c1',
          label: 'Home',
          host: 'host.invalid',
          port: 9119,
          apiKey: '',
          singleLogin: true,
          signInMethod: 'none',
        ),
      );
      final bots = HmBotsModel(gateway);
      final chat = NgChatController(gateway, profile: 'atlas');
      addTearDown(() {
        chat.dispose();
        bots.dispose();
        gateway.dispose();
      });
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => hmChatAction(
                context,
                HmBot.fromJson({'name': 'atlas'}),
                bots,
                chat,
                HmChatAction.council,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(HmCouncilScreen), findsOneWidget);
      expect(find.text('Argon'), findsOneWidget);
    });
  });
}
