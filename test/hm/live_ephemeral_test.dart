// Ephemeral-ui cards (HA-039): a ```ephemeral-ui fence the agent emits
// draws as an inert native card through the chat's fenced-block renderer,
// in the chat and inline in the live call's transcript, and the voice says
// only the words around it. Includes a golden of the live call with a card.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/ephemeral_ui_card.dart';
import 'package:hermes_android/core/widgets/markdown_code_block.dart';
import 'package:hermes_android/hm/features/live/hm_live.dart';
import 'package:hermes_android/hm/features/live/live_transport.dart';
import 'package:hermes_android/hm/hm_bots.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/nextgen/data/chat_controller.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/nextgen/ui/chat_view.dart';

import 'live_fakes.dart';

const _card =
    '{"kind": "merge", "app": "github", "title": "Merge #42", '
    '"subject": "fix(live): redial dropped calls", "status": "checks passing", '
    '"summary": "3 commits, 2 approvals.", '
    '"fields": {"base": "staging", "head": "boat/ha-live/reconnect"}, '
    '"buttons": [{"label": "Merge", "action": "merge"}, "Close"]}';

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

Future<void> _open(WidgetTester tester, LiveRig rig) async {
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
        home: HmLiveScreen(bot: _bot, create: rig.build),
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

Future<LiveRig> _delegated(WidgetTester tester) async {
  final rig = LiveRig(
    host: FakeHost(mode: 'gpt-live', available: true),
    peer: FakePeer(),
  );
  await _open(tester, rig);
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
  group('card.v0 parsing', () {
    test('reads the display fields and keeps only button labels', () {
      final card = EphemeralUiCardData.tryParse(_card)!;
      expect(card.kind, 'merge');
      expect(card.app, 'github');
      expect(card.title, 'Merge #42');
      expect(card.subject, 'fix(live): redial dropped calls');
      expect(card.status, 'checks passing');
      expect(card.texts, ['3 commits, 2 approvals.']);
      expect(card.fields, [
        ('base', 'staging'),
        ('head', 'boat/ha-live/reconnect'),
      ]);
      expect(card.buttons, ['Merge', 'Close']);
    });

    test('anything that is not a valid card is refused', () {
      for (final bad in [
        'not json',
        '[1, 2]',
        '{"app": "github"}',
        '{"kind": "merge"}',
        '{"kind": "Merge!", "app": "github"}',
        '{"kind": "merge", "app": "git hub"}',
        '{"kind": "merge", "app": "github", "title": "evil\u202Etxt"}',
        '{"kind": "merge", "app": "github", "title": "${'x' * 70000}"}',
      ]) {
        expect(EphemeralUiCardData.tryParse(bad), isNull, reason: bad);
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

    test('both chat renderers hand the fence to the card renderer', () {
      final classic = splitMarkdownCodeBlocks(
        _reply,
      ).whereType<MarkdownCodeBlock>().single;
      expect(classic.language, ephemeralUiLanguage);
      final fence = ngSplitCodeFences(_reply).where((r) => r.$2).single.$1;
      expect(ngCodeFenceParts(fence).language, ephemeralUiLanguage);
    });
  });

  testWidgets('the chat renderer draws a card, and code for a bad one', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ListView(
            children: const [
              MarkdownCodeBlock(code: _card, language: ephemeralUiLanguage),
              MarkdownCodeBlock(
                code: '{"kind": 1}',
                language: ephemeralUiLanguage,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('ephemeral-ui-card')), findsOneWidget);
    expect(find.text('Merge #42'), findsOneWidget);
    expect(find.text('github · merge'), findsOneWidget);
    expect(find.text('Merge'), findsOneWidget);
    // Labels only: nothing in the card is a button.
    expect(
      find.descendant(
        of: find.byKey(const Key('ephemeral-ui-card')),
        matching: find.byWidgetPredicate(
          (w) => w is ButtonStyleButton || w is InkWell || w is GestureDetector,
        ),
      ),
      findsNothing,
    );
    expect(find.textContaining('{"kind": 1}'), findsOneWidget);
  });

  testWidgets(
    'GPT-Live: the reply\'s card renders inline; the voice gets the words',
    (tester) async {
      final rig = await _delegated(tester);
      rig.brain.reply(_reply);
      await _frames(tester);
      expect(find.byKey(const ValueKey('live-card')), findsOneWidget);
      expect(find.byKey(const Key('ephemeral-ui-card')), findsOneWidget);
      expect(find.text('Merge #42'), findsOneWidget);
      final said = rig.peer!.sent
          .where((f) => f['type'] == 'session.commentary.append')
          .single;
      expect(said['content'], 'Here is the pull request. Want me to merge it?');
    },
  );

  testWidgets('GPT-Live: a card-only reply is a quiet note, not speech', (
    tester,
  ) async {
    final rig = await _delegated(tester);
    rig.brain.reply('```ephemeral-ui\n$_card\n```');
    await _frames(tester);
    expect(find.byKey(const Key('ephemeral-ui-card')), findsOneWidget);
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
    expect(find.byKey(const Key('ephemeral-ui-card')), findsOneWidget);
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
