// Ephemeral-ui cards (HA-039): a ```ephemeral-ui fence the agent emits
// draws as an inert native card through the chat's fenced-block renderer,
// in the chat and inline in the live call's transcript, and the voice says
// only the words around it. Includes a golden of the live call with a card.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/ephemeral/ephemeral_card.dart';
import 'package:hermes_android/core/ephemeral/ephemeral_catalog.dart';
import 'package:hermes_android/core/ephemeral/ephemeral_fence.dart';
import 'package:hermes_android/core/widgets/markdown_code_block.dart';
import 'package:hermes_android/hm/features/live/hm_live.dart';
import 'package:hermes_android/hm/features/live/live_transport.dart';
import 'package:hermes_android/hm/hm_bots.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/nextgen/data/chat_controller.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/nextgen/ui/chat_view.dart';

import 'live_fakes.dart';

final _catalog = EphemeralCatalog.parse(
  File(EphemeralCatalogAssets.catalog).readAsStringSync(),
);

const _card =
    '{"kind":"merge","app":"github","input":{"number":42,'
    '"title":"Merge #42","base":"staging","head":"live-fix"}}';

const _reply =
    'Here is the pull request.\n\n```ephemeral-ui\n$_card\n```\n\nWant me to merge it?';

final _bot = HmBot.fromJson({
  'name': 'teknium',
  'display_name': 'teknium',
  'model': 'm',
  'provider': 'p',
});

Future<void> _font(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(File(f).readAsBytes().then((b) => ByteData.sublistView(b)));
  }
  await loader.load();
}

Future<void> _open(
  WidgetTester tester,
  LiveRig rig, {
  NgChatController? chat,
}) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    // Animations held still so the golden is one stable frame.
    TickerMode(
      enabled: false,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: nextGenTheme(Brightness.dark, NextGenLook.instance),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HmLiveScreen(bot: _bot, create: rig.build, chat: chat),
      ),
    ),
  );
  await _frames(tester);
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Map<String, Object?> _delta(bool user, String text) => {
  'type': user
      ? 'session.input_transcript.delta'
      : 'session.output_transcript.delta',
  'delta': text,
};

Future<LiveRig> _delegated(
  WidgetTester tester, {
  NgChatController? chat,
}) async {
  final rig = LiveRig(
    host: FakeHost(mode: 'gpt-live', available: true),
    peer: FakePeer(),
  );
  await _open(tester, rig, chat: chat);
  rig.peer!
    ..event(_delta(true, 'Show me the PR for the live fix.'))
    ..event({
      'type': 'session.delegation.created',
      'delegation': {'id': 'd1', 'type': 'delegation', 'target': 'client'},
    })
    ..event(_delta(false, 'Sure, pulling it up.'));
  await _frames(tester);
  return rig;
}

void main() {
  setUp(() => EphemeralCatalog.debugUse(_catalog));
  tearDown(() => EphemeralCatalog.debugUse(null));

  group('card.v0 parsing', () {
    test('resolves live input through the same catalog as chat', () {
      final document = EphemeralFence.parse(_card).cards.single;
      final card = resolveEphemeralCard(_catalog, document).data!;
      expect(card.kind, 'merge');
      expect(card.appId, 'github');
      expect(card.props['input'], {
        'number': 42,
        'title': 'Merge #42',
        'base': 'staging',
        'head': 'live-fix',
      });
    });

    test('an invalid card document cannot resolve to a native card', () {
      for (final bad in [
        '{"kind":1}',
        '{"kind":"unknown"}',
        '{"app":"github"}',
      ]) {
        final document = EphemeralFence.parse(bad).cards.single;
        expect(resolveEphemeralCard(_catalog, document).problem, isNotNull);
      }
    });

    test('fences are found in order and stripped for speech', () {
      const two =
          'A\n```ephemeral-ui\n{"kind":"a","app":"x"}\n```\nB\n'
          '```ephemeral-ui\n{"kind":"b","app":"y"}\n```\n';
      expect(ephemeralUiFences(two), [
        '{"kind":"a","app":"x"}\n',
        '{"kind":"b","app":"y"}\n',
      ]);
      expect(withoutEphemeralUi(two), 'A\nB');
      expect(
        withoutEphemeralUi(_reply),
        'Here is the pull request.\n\nWant me to merge it?',
      );
      expect(ephemeralUiFences('```json\n{}\n```'), isEmpty);
    });

    test('live understands tilde fences but ignores a nested code example', () {
      const reply = 'Top\r\n~~~ephemeral-ui\r\n$_card\r\n~~~~\r\nBottom';
      expect(ephemeralUiFences(reply).single.trim(), _card);
      expect(withoutEphemeralUi(reply), 'Top\r\nBottom');
      const sample = '````md\n```ephemeral-ui\n$_card\n```\n````';
      expect(ephemeralUiFences(sample), isEmpty);
      expect(withoutEphemeralUi(sample), sample);
    });

    test('both chat renderers hand the fence to the card renderer', () {
      final classic = splitMarkdownCodeBlocks(
        _reply,
      ).whereType<MarkdownCodeBlock>().single;
      expect(classic.language, ephemeralFenceLanguage);
      final fence = ngSplitCodeFences(_reply).where((r) => r.$2).single.$1;
      expect(ngCodeFenceParts(fence).language, ephemeralFenceLanguage);
    });
  });

  testWidgets('the chat renderer draws a card and explains an invalid one', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ListView(
            children: const [
              MarkdownCodeBlock(code: _card, language: ephemeralFenceLanguage),
              MarkdownCodeBlock(
                code: '{"kind": 1}',
                language: ephemeralFenceLanguage,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(EphemeralCardView), findsOneWidget);
    expect(find.text('Merge #42'), findsOneWidget);
    // Labels only: nothing in the card is a button.
    expect(
      find.descendant(
        of: find.byType(EphemeralCardView),
        matching: find.byWidgetPredicate(
          (w) => w is ButtonStyleButton || w is InkWell || w is GestureDetector,
        ),
      ),
      findsNothing,
    );
    expect(find.byKey(const Key('ephemeral-fence-problem')), findsOneWidget);
  });

  testWidgets(
    'GPT-Live: the reply\'s card renders inline; the voice gets the words',
    (tester) async {
      final rig = await _delegated(tester);
      rig.brain.reply(_reply);
      await _frames(tester);
      expect(find.byKey(const ValueKey('live-card')), findsOneWidget);
      expect(find.byType(EphemeralCardView), findsOneWidget);
      expect(find.text('Merge #42'), findsOneWidget);
      final said = rig.peer!.sent
          .where((f) => f['type'] == 'session.commentary.append')
          .single;
      expect(said['content'], 'Here is the pull request. Want me to merge it?');
    },
  );

  testWidgets(
    'compact bubble expands above a pending approval and the inline live card',
    (tester) async {
      ephemeralCardStyle.value = EphemeralCardStyle.serviceNative;
      addTearDown(() => ephemeralCardStyle.value = EphemeralCardStyle.appTheme);
      final gateway = NextGenGateway(
        SavedConnection(
          id: 'test',
          label: 'Test',
          host: 'example.invalid',
          port: 9119,
          apiKey: '',
        ),
      );
      addTearDown(gateway.dispose);
      final chat = NgChatController(gateway);
      addTearDown(chat.dispose);
      String? choice;
      chat.request = NgInputRequest.parse(
        NgServerRequest(
          GatewayServerRequest.forTesting(
            id: 'approval',
            method: 'approval',
            params: {'description': 'Read a report', 'allow_session': false},
            respond: (result) {
              choice = result['choice'] as String;
              return true;
            },
          ),
        ),
      );
      final rig = await _delegated(tester, chat: chat);
      rig.brain.reply(_reply);
      await _frames(tester);
      final orb = find.byKey(const ValueKey('live-orb'));
      final approval = find.byKey(const ValueKey('live-approval'));
      expect(tester.getSize(orb).width, 48);
      expect(approval, findsNothing);
      final card = find.byType(EphemeralCardView);
      expect(card, findsOneWidget);
      final expected = resolveEphemeralCard(
        _catalog,
        EphemeralFence.parse(_card).cards.single,
      ).data!;
      expect(tester.widget<EphemeralCardView>(card).data.props, expected.props);
      expect(
        find.descendant(
          of: card,
          matching: find.byKey(const ValueKey('ephemeral-style-serviceNative')),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Enter focus mode'));
      await _frames(tester);
      expect(tester.getSize(orb).width, greaterThan(48));
      expect(approval, findsOneWidget);
      await tester.ensureVisible(approval);
      await _frames(tester);
      expect(
        tester.getTopLeft(approval).dy,
        greaterThan(tester.getBottomLeft(orb).dy),
      );
      await tester.tap(
        find.descendant(of: approval, matching: find.text('Deny')),
      );
      await _frames(tester);
      expect(choice, 'deny');
      expect(approval, findsNothing);
      // After settling the newest approval the inline card remains
      // available in the same focus transcript, below the large orb.
      await tester.ensureVisible(card);
      await _frames(tester);
      expect(
        tester.getTopLeft(card).dy,
        greaterThan(tester.getBottomLeft(orb).dy),
      );
      await tester.tap(find.byTooltip('Exit focus mode'));
      await _frames(tester);
      expect(tester.getSize(orb).width, 48);
      expect(card, findsOneWidget);
    },
  );

  testWidgets(
    'GPT-Live: a fenced card in streamed voice output mounts inline',
    (tester) async {
      final rig = LiveRig(
        host: FakeHost(mode: 'gpt-live', available: true),
        peer: FakePeer(),
      );
      await _open(tester, rig);
      rig.peer!
        ..event(_delta(false, 'Here is the PR.\n\n```ephemeral-ui\n'))
        ..event(_delta(false, '$_card\n```\n'));
      await _frames(tester);
      expect(find.text('Here is the PR.'), findsOneWidget);
      expect(find.byType(EphemeralCardView), findsOneWidget);
      expect(find.text('Merge #42'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ephemeral-style-appTheme')),
        findsOneWidget,
      );
    },
  );

  testWidgets('GPT-Live: a card-only reply is a quiet note, not speech', (
    tester,
  ) async {
    final rig = await _delegated(tester);
    rig.brain.reply('```ephemeral-ui\n$_card\n```');
    await _frames(tester);
    expect(find.byType(EphemeralCardView), findsOneWidget);
    final frames = rig.peer!.sent;
    expect(
      frames.where((f) => f['type'] == 'session.commentary.append'),
      isEmpty,
    );
    expect(
      frames
          .where((f) => f['type'] == 'session.thinking.append')
          .last['content'],
      'Hermes put the answer on screen as a card.',
    );
  });

  testWidgets('chained loop: the card renders under the words it came with', (
    tester,
  ) async {
    final rig = LiveRig();
    await _open(tester, rig);
    rig.ear.hear('show me the PR');
    await _frames(tester);
    rig.brain.reply(_reply);
    await _frames(tester);
    expect(find.byType(EphemeralCardView), findsOneWidget);
    expect(
      find.text('Here is the pull request.\n\nWant me to merge it?'),
      findsOneWidget,
    );
    expect(
      rig.voice.spoken.single,
      'Here is the pull request.\n\nWant me to merge it?',
    );
  });

  group('golden', () {
    setUpAll(() async {
      final sdkFonts =
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';
      await _font('Roboto', ['$sdkFonts/Roboto-Regular.ttf']);
      await _font('MaterialIcons', ['$sdkFonts/MaterialIcons-Regular.otf']);
      List<String> files(String prefix) => Directory('assets/fonts/geist')
          .listSync()
          .map((f) => f.path)
          .where((p) => p.split('/').last.startsWith('$prefix-'))
          .toList();
      await _font('Geist', files('Geist'));
      await _font('GeistMono', files('GeistMono'));
      await _font('Nunito', [
        'assets/fonts/nunito/Nunito-VariableFont_wght.ttf',
        'assets/fonts/nunito/Nunito-Italic-VariableFont_wght.ttf',
      ]);
    });

    testWidgets('live call with tool rows and an ephemeral-ui card', (
      tester,
    ) async {
      final rig = await _delegated(tester);
      rig.brain.shown.add(
        LiveLine(
          key: 'tools',
          fromUser: false,
          text: '',
          tools: [
            NgTool(
              id: 't1',
              name: 'terminal',
              detail: 'gh pr view 42',
              summary: 'open, checks passing',
            ),
            NgTool(id: 't2', name: 'read_file', detail: 'CHANGELOG.md'),
          ],
        ),
      );
      rig.brain.reply(_reply);
      await _frames(tester);
      await expectLater(
        find.byType(HmLiveScreen),
        matchesGoldenFile('goldens/live_ephemeral_card.png'),
      );
    });
  });
}
