// One chat golden per ephemeral-ui catalog kind, plus the real NextGen chat
// view drawing cards from a reply. Real fonts, as in store_screenshots_test.
// Regenerate: flutter test test/ephemeral_chat_golden_test.dart --update-goldens
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/ephemeral/ephemeral_card.dart';
import 'package:hermes_android/core/ephemeral/ephemeral_catalog.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/core/widgets/markdown_code_block.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/nextgen/data/chat_controller.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/nextgen/ui/chat_view.dart';
import 'package:hermes_android/nextgen/ui/nextgen_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _goldenDir = 'test/goldens/ephemeral_chat';

Future<void> _font(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(File(f).readAsBytes().then((b) => ByteData.sublistView(b)));
  }
  await loader.load();
}

/// The fixture a chat shows for a kind: real data where the kind takes it.
EphemeralFixture _chatFixture(EphemeralKind kind) => kind.fixtures.firstWhere(
  (f) =>
      f.state == EphemeralFixtureState.example ||
      f.state == EphemeralFixtureState.input,
  orElse: () => kind.fixtures.first,
);

void main() {
  setUp(() => ephemeralCardStyle.value = EphemeralCardStyle.appTheme);
  tearDown(() => ephemeralCardStyle.value = EphemeralCardStyle.appTheme);
  final catalog = EphemeralCatalog.parse(
    File(EphemeralCatalogAssets.catalog).readAsStringSync(),
  );
  final sdkFonts =
      '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await _font('Roboto', [
      for (final w in ['Regular', 'Medium', 'Bold']) '$sdkFonts/Roboto-$w.ttf',
    ]);
    await _font('MaterialIcons', ['$sdkFonts/MaterialIcons-Regular.otf']);
    List<String> files(String prefix) =>
        Directory('assets/fonts/geist')
            .listSync()
            .map((f) => f.path)
            .where((p) => p.split('/').last.startsWith('$prefix-'))
            .toList();
    await _font('Geist', files('Geist'));
    await _font('GeistMono', files('GeistMono'));
    await _font('monospace', files('GeistMono'));
    await _font('Nunito', [
      'assets/fonts/nunito/Nunito-VariableFont_wght.ttf',
      'assets/fonts/nunito/Nunito-Italic-VariableFont_wght.ttf',
    ]);
  });
  setUp(() => EphemeralCatalog.debugUse(catalog));
  tearDown(() => EphemeralCatalog.debugUse(null));

  test('a chat golden exists for exactly the catalog kinds', () {
    final kinds = {for (final k in catalog.kinds) '${k.kind}.png'};
    final dir = Directory(_goldenDir);
    final files = dir.existsSync()
        ? {
            for (final f in dir.listSync().whereType<File>())
              f.path.split('/').last,
          }
        : <String>{};
    expect(kinds.difference(files), isEmpty, reason: 'run --update-goldens');
    expect(files.difference(kinds), isEmpty);
  }, skip: autoUpdateGoldenFiles ? 'writing goldens' : false);

  for (final style in EphemeralCardStyle.values) {
    for (final kind in catalog.kinds) {
      testWidgets('chat golden ${style.name} ${kind.kind}', (tester) async {
        ephemeralCardStyle.value = style;
        tester.view.physicalSize = const Size(720, 8000);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        final fixture = _chatFixture(kind);
        final reply =
            'Here is the ${kind.label} card.\n\n'
            '```ephemeral-ui\n${jsonEncode(fixture.card)}\n```\n';
        final tokens = HermesTokens.forBrightness(Brightness.dark);
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: hermesTheme(Brightness.dark),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topCenter,
                child: RepaintBoundary(
                  key: const Key('golden'),
                  child: Container(
                    width: 360,
                    color: tokens.raised,
                    padding: const EdgeInsets.all(12),
                    child: DefaultTextStyle.merge(
                      style: const TextStyle(fontFamily: 'Roboto'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final block in splitMarkdownCodeBlocks(reply))
                            if (block is String)
                              Text(
                                block.trim(),
                                style: TextStyle(color: tokens.onSurface),
                              )
                            else
                              block as Widget,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.byType(EphemeralCardView), findsOneWidget);
        expect(find.byKey(const Key('ephemeral-fence-problem')), findsNothing);
        expect(find.byKey(const Key('ephemeral-unsupported')), findsNothing);
        expect(
          find.byKey(ValueKey('ephemeral-style-${style.name}')),
          findsOneWidget,
        );
        await expectLater(
          find.byKey(const Key('golden')),
          matchesGoldenFile(
            style == EphemeralCardStyle.appTheme
                ? 'goldens/ephemeral_chat/${kind.kind}.png'
                : 'goldens/ephemeral_service/${kind.kind}.png',
          ),
        );
      });
    }
  }

  testWidgets('NextGen chat draws cards from a reply', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final prefs = await SharedPreferences.getInstance();
    final look = NextGenLook.instance..themeId = 'onyx';
    final conn = SavedConnection(
      id: 'c1',
      label: 'Home',
      host: 'gateway.local',
      port: 9119,
      apiKey: '',
      desktopGatewayUrl: 'http://gateway.local:9119',
      dashboardPortOverride: 9119,
      singleLogin: true,
      signInMethod: 'none',
    );
    final gateway = NextGenGateway(conn)
      ..debugSetPhase(NgConnectionPhase.connected);
    final chat = NgChatController(gateway, sessionId: 's');
    // ngStamp adds a date to older messages. Keep the golden on today's
    // local date so the fixed 9:41 AM labels don't change after recording.
    final today = DateTime.now();
    final messageTime = DateTime(today.year, today.month, today.day, 9, 41);
    chat.items.addAll([
      NgUserItem(
        'u1',
        'How is the npm package doing, and the PR?',
        time: messageTime,
      ),
      NgAssistantItem('a1', open: false, time: messageTime)
        ..text =
            'Weekly users are up.\n\n'
            '```ephemeral-ui\n'
            '{"title":"Today","cards":[{"kind":"metric","app":"npm"},'
            '{"kind":"merge","app":"github"}]}\n'
            '```\n\n'
            'The PR is green.',
    ]);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: nextGenTheme(Brightness.dark, look),
        home: NgScope(
          connManager: ConnectionManager(prefs),
          gateway: gateway,
          connections: [conn],
          switchTo: (_) async {},
          addGateway: () async {},
          signOut: (_) async {},
          reload: () async {},
          signInAgain: () async {},
          child: Scaffold(
            body: NgChatView(
              chat: chat,
              onOpenSidebar: () {},
              onNewChat: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('ephemeral-fence')), findsOneWidget);
    expect(find.byType(EphemeralCardView), findsNWidgets(2));
    expect(find.text('Today'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/chat_cards/nextgen_chat.png'),
    );
  });
}
