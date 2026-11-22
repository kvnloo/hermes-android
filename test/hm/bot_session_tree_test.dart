// Home's session tree: each bot row expands to its sessions (HA-032).
// Covers the per-bot mapping, collapsed/expanded/empty/error states,
// "Show all", "+ New session", saved expanded state and search, plus a
// golden of the expanded tree.
//
// Golden: flutter test test/hm/bot_session_tree_test.dart --update-goldens
// writes test/goldens/home/bot_session_tree.png.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:hermes_android/hm/features/sessions/bot_session_tree.dart';
import 'package:hermes_android/hm/hm_bots.dart';
import 'package:hermes_android/hm/screens/hm_chat_screen.dart';
import 'package:hermes_android/hm/screens/hm_home.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/ui/nextgen_scope.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

SavedConnection _connection() => SavedConnection(
  id: 'c1',
  label: 'Home',
  host: 'gateway.test',
  port: 9119,
  apiKey: '',
  desktopGatewayUrl: 'http://gateway.test:9119',
  singleLogin: true,
  signInMethod: 'none',
  dashboardProxied: true,
);

class _Gateway extends NextGenGateway {
  _Gateway(super.connection, {super.dashboard});

  @override
  Future<WsClient> connected({
    Duration timeout = const Duration(seconds: 20),
  }) async => WsClient('http://gateway.test:9119');

  @override
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 30),
  }) => throw JsonRpcError(method, 'unknown method: $method', code: -32601);
}

double _ago(Duration d) =>
    DateTime.now().subtract(d).millisecondsSinceEpoch / 1000;

Map<String, dynamic> _row(
  String id,
  String title,
  Duration ago, {
  bool unread = false,
  bool active = false,
  String source = 'api_server',
  String preview = '',
  bool archived = false,
}) => {
  'id': id,
  'title': title,
  'source': source,
  'preview': preview,
  'started_at': _ago(ago + const Duration(minutes: 1)),
  'last_active': _ago(ago),
  'unread': unread,
  'is_active': active,
  'archived': archived,
  'message_count': 4,
};

/// A host with three bots: Hermes (default, no chats), Atlas (seven chats
/// plus rows the tree hides) and Nova (whose session read fails until
/// [_Host.novaFails] is cleared).
class _Host {
  final requests = <Uri>[];
  bool novaFails = true;

  List<Map<String, dynamic>> atlas() => [
    // Server order is not trusted: the tree sorts newest first.
    _row('a3', 'Plan the launch', const Duration(minutes: 9)),
    _row('a1', 'Fix the flaky test', const Duration(minutes: 2), active: true),
    _row(
      'a2',
      'Untitled',
      const Duration(minutes: 5),
      unread: true,
      preview: 'Summarize the meeting notes',
    ),
    _row('a4', 'Draft release notes', const Duration(minutes: 14)),
    _row('a5', 'Weekly metrics', const Duration(minutes: 20)),
    _row('a6', 'Refactor the parser', const Duration(minutes: 31)),
    _row('a7', 'Old idea about caching', const Duration(minutes: 45)),
    _row('cron1', 'Nightly backup', const Duration(minutes: 1), source: 'cron'),
    _row('ar1', 'Archived chat', const Duration(minutes: 1), archived: true),
  ];

  MockClient client() => MockClient((request) async {
    requests.add(request.url);
    final path = request.url.path;
    if (path.endsWith('/profiles')) {
      return http.Response(
        jsonEncode({
          'profiles': [
            {'name': 'default', 'is_default': true},
            {'name': 'atlas'},
            {'name': 'nova'},
          ],
        }),
        200,
      );
    }
    if (path.endsWith('/sessions') || path.endsWith('/sessions/search')) {
      final profile = request.url.queryParameters['profile'];
      if (profile == 'nova' && novaFails) {
        return http.Response(jsonEncode({'detail': 'store locked'}), 500);
      }
      var rows = switch (profile) {
        'atlas' => atlas(),
        'nova' => [_row('n1', 'Nova first chat', const Duration(minutes: 3))],
        _ => <Map<String, dynamic>>[],
      };
      final q = request.url.queryParameters['q'];
      if (q != null) {
        rows = [
          for (final r in rows)
            if ('${r['title']}'.toLowerCase().contains(q.toLowerCase())) r,
        ];
        return http.Response(jsonEncode({'results': rows}), 200);
      }
      final offset = int.tryParse(request.url.queryParameters['offset'] ?? '');
      if ((offset ?? 0) > 0) rows = [];
      return http.Response(
        jsonEncode({'sessions': rows, 'total': rows.length}),
        200,
      );
    }
    return http.Response('{}', 200);
  });

  int sessionReads(String? profile) => requests
      .where(
        (u) =>
            u.path.endsWith('/sessions') &&
            u.queryParameters['profile'] == profile,
      )
      .length;
}

Future<void> _settle(WidgetTester tester, [int frames = 10]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<_Gateway> _pumpHome(
  WidgetTester tester,
  _Host host, {
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final sp = await SharedPreferences.getInstance();
  final gateway = _Gateway(
    _connection(),
    dashboard: DashboardClient(
      host: 'gateway.test',
      proxied: true,
      httpClient: host.client(),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // As in the app, the scope sits above the navigator pushed routes use.
      builder: (context, child) => NgScope(
        connManager: ConnectionManager(sp),
        gateway: gateway,
        connections: [gateway.connection],
        switchTo: (_) async {},
        addGateway: () async {},
        signOut: (_) async {},
        reload: () async {},
        signInAgain: () async {},
        child: child!,
      ),
      home: const HmHome(),
    ),
  );
  await _settle(tester);
  return gateway;
}

Future<void> _expand(WidgetTester tester, String bot) async {
  await tester.tap(find.byTooltip('Show $bot sessions'));
  await _settle(tester, 6);
}

void main() {
  group('sessions per bot', () {
    test('each profile maps to its own sessions; failures are kept', () async {
      SharedPreferences.setMockInitialValues({});
      final host = _Host();
      final gateway = _Gateway(
        _connection(),
        dashboard: DashboardClient(
          host: 'gateway.test',
          proxied: true,
          httpClient: host.client(),
        ),
      );
      final bots = HmBotsModel(gateway);
      await bots.refresh();

      expect(bots.bots.map((b) => b.profile), ['default', 'atlas', 'nova']);
      // The default profile is read without a profile scope.
      expect(host.sessionReads(null), 1);
      expect(host.sessionReads('atlas'), 1);
      expect(bots.sessions['default'], isEmpty);
      // Archived rows are dropped by the model; cron rows by the tree.
      expect(bots.sessions['atlas']!.map((s) => s.id), isNot(contains('ar1')));
      final tree = hmBotSessionRows(bots.sessions['atlas']!);
      expect(tree.map((s) => s.id), ['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7']);
      expect(hmSessionLabel(tree[1]), 'Summarize the meeting notes');
      expect(bots.sessionErrors.keys, ['nova']);
      expect(bots.sessions['nova'], isEmpty);

      // A retry reads only that bot, and concurrent retries share one read.
      host.novaFails = false;
      final before = host.requests.length;
      await Future.wait([
        bots.loadBotSessions(bots.byProfile('nova')!),
        bots.loadBotSessions(bots.byProfile('nova')!),
      ]);
      expect(host.requests.length - before, 1);
      expect(host.requests.last.queryParameters['profile'], 'nova');
      expect(bots.sessionErrors, isEmpty);
      expect(bots.sessions['nova']!.single.id, 'n1');
      bots.dispose();
    });

    test('expanded bots are saved per host', () async {
      SharedPreferences.setMockInitialValues({});
      final a = HmExpandedBots();
      await a.load('c1');
      expect(a.toggle('atlas'), isTrue);
      expect(a.toggle('nova'), isTrue);
      expect(a.toggle('nova'), isFalse);
      await Future<void>.delayed(Duration.zero);
      final b = HmExpandedBots();
      await b.load('c1');
      expect(b.profiles, {'atlas'});
      await b.load('c2');
      expect(b.profiles, isEmpty);
    });
  });

  group('Home session tree', () {
    testWidgets('collapsed: each bot has a chevron and no session rows', (
      tester,
    ) async {
      await _pumpHome(tester, _Host());
      expect(find.byTooltip('Show Atlas sessions'), findsOneWidget);
      expect(find.byTooltip('Show Hermes sessions'), findsOneWidget);
      expect(find.byType(HmBotSessionTree), findsNothing);
      expect(find.text('Draft release notes'), findsNothing);
    });

    testWidgets('expanded: newest five, dots, Show all and New session '
        'without another request', (tester) async {
      final host = _Host();
      await _pumpHome(tester, host);
      final reads = host.requests.length;
      await _expand(tester, 'Atlas');

      expect(host.requests.length, reads, reason: 'rows were already held');
      final tree = find.byKey(const ValueKey('hm-tree-atlas'));
      expect(tree, findsOneWidget);
      final titles = [
        'Fix the flaky test',
        'Summarize the meeting notes',
        'Plan the launch',
        'Draft release notes',
        'Weekly metrics',
      ];
      final ys = [
        for (final t in titles)
          tester
              .getTopLeft(find.descendant(of: tree, matching: find.text(t)))
              .dy,
      ];
      expect(ys, orderedEquals([...ys]..sort()));
      expect(
        find.descendant(of: tree, matching: find.text('Refactor the parser')),
        findsNothing,
      );
      expect(find.text('Nightly backup'), findsNothing);
      expect(find.text('Show all (7)'), findsOneWidget);
      expect(
        find.descendant(of: tree, matching: find.text(hmTreeNewSession)),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Fix the flaky test, running'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Summarize the meeting notes, unread'),
        findsOneWidget,
      );

      // Collapsing hides the rows again.
      await tester.tap(find.byTooltip('Hide Atlas sessions'));
      await _settle(tester, 4);
      expect(find.byType(HmBotSessionTree), findsNothing);
    });

    testWidgets('empty: a bot without sessions says so', (tester) async {
      await _pumpHome(tester, _Host());
      await _expand(tester, 'Hermes');
      final tree = find.byKey(const ValueKey('hm-tree-default'));
      expect(
        find.descendant(of: tree, matching: find.text(hmTreeEmpty)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tree, matching: find.text(hmTreeNewSession)),
        findsOneWidget,
      );
      expect(find.textContaining('Show all'), findsNothing);
    });

    testWidgets('error: a failed read shows why, and Retry reads it again', (
      tester,
    ) async {
      final host = _Host();
      await _pumpHome(tester, host);
      final reads = host.sessionReads('nova');
      await _expand(tester, 'Nova');
      // Expanding a bot whose last read failed reads it once more.
      expect(host.sessionReads('nova'), reads + 1);
      final tree = find.byKey(const ValueKey('hm-tree-nova'));
      expect(
        find.descendant(
          of: tree,
          matching: find.textContaining("Couldn't load sessions"),
        ),
        findsOneWidget,
      );
      host.novaFails = false;
      await tester.tap(find.text(hmTreeRetry));
      await _settle(tester, 6);
      expect(host.sessionReads('nova'), reads + 2);
      expect(
        find.descendant(of: tree, matching: find.text('Nova first chat')),
        findsOneWidget,
      );
      expect(find.textContaining("Couldn't load sessions"), findsNothing);
    });

    testWidgets('Show all opens the bot\'s full session list', (tester) async {
      final host = _Host();
      await _pumpHome(tester, host);
      await _expand(tester, 'Atlas');
      await tester.tap(find.text('Show all (7)'));
      await _settle(tester, 12);

      expect(find.byType(HmBotSessionsScreen), findsOneWidget);
      for (final t in [
        'Fix the flaky test',
        'Summarize the meeting notes',
        'Refactor the parser',
        'Old idea about caching',
      ]) {
        expect(find.text(t), findsOneWidget);
      }
      expect(find.text('Nightly backup'), findsNothing);
      expect(host.requests.last.queryParameters['profile'], 'atlas');

      // Its search reads the same bot.
      await tester.enterText(
        find.byKey(const Key('hm-bot-sessions-search')),
        'parser',
      );
      await _settle(tester, 12);
      expect(find.text('Refactor the parser'), findsOneWidget);
      expect(find.text('Weekly metrics'), findsNothing);
      final search = host.requests.lastWhere(
        (u) => u.path.endsWith('/sessions/search'),
      );
      expect(search.queryParameters['profile'], 'atlas');
    });

    testWidgets('+ New session opens a new chat with that bot', (tester) async {
      await _pumpHome(tester, _Host());
      await _expand(tester, 'Atlas');
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('hm-tree-atlas')),
          matching: find.text(hmTreeNewSession),
        ),
      );
      await _settle(tester, 6);
      final chat = tester.widget<HmChatScreen>(find.byType(HmChatScreen));
      expect(chat.bot.profile, 'atlas');
      expect(chat.chat.storedId, isNull);
    });

    testWidgets('a session row opens that chat', (tester) async {
      await _pumpHome(tester, _Host());
      await _expand(tester, 'Atlas');
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('hm-tree-atlas')),
          matching: find.text('Plan the launch'),
        ),
      );
      await _settle(tester, 6);
      final chat = tester.widget<HmChatScreen>(find.byType(HmChatScreen));
      expect(chat.chat.storedId, 'a3');
    });

    testWidgets('expanded state comes back after a restart', (tester) async {
      await _pumpHome(
        tester,
        _Host(),
        prefs: {
          HmExpandedBots.key: jsonEncode({
            'c1': ['atlas'],
          }),
        },
      );
      expect(find.byKey(const ValueKey('hm-tree-atlas')), findsOneWidget);
      expect(find.text('Show all (7)'), findsOneWidget);
      expect(find.byKey(const ValueKey('hm-tree-default')), findsNothing);
    });

    testWidgets('expanded state survives scrolling it out of view', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 260);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pumpHome(tester, _Host());
      await _expand(tester, 'Atlas');
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await _settle(tester, 4);
      await tester.drag(find.byType(ListView), const Offset(0, 1200));
      await _settle(tester, 4);
      expect(find.byKey(const ValueKey('hm-tree-atlas')), findsOneWidget);
    });

    testWidgets('search matches session titles and lists them under the bot', (
      tester,
    ) async {
      await _pumpHome(tester, _Host());
      await tester.tap(find.bySemanticsLabel('Search'));
      await _settle(tester, 4);
      await tester.enterText(find.byType(TextField), 'release');
      await _settle(tester, 4);

      expect(find.text('Atlas'), findsOneWidget);
      expect(find.text('Hermes'), findsNothing);
      final tree = find.byKey(const ValueKey('hm-tree-atlas'));
      expect(
        find.descendant(of: tree, matching: find.text('Draft release notes')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tree, matching: find.text('Plan the launch')),
        findsNothing,
      );
      // First user lines count too.
      await tester.enterText(find.byType(TextField), 'meeting notes');
      await _settle(tester, 4);
      expect(find.text('Summarize the meeting notes'), findsOneWidget);
    });
  });

  group('golden', () {
    Future<void> font(String family, List<String> files) async {
      final loader = FontLoader(family);
      for (final f in files) {
        loader.addFont(
          File(f).readAsBytes().then((b) => ByteData.sublistView(b)),
        );
      }
      await loader.load();
    }

    setUpAll(() async {
      final sdkFonts =
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';
      await font('Roboto', ['$sdkFonts/Roboto-Regular.ttf']);
      await font('MaterialIcons', ['$sdkFonts/MaterialIcons-Regular.otf']);
      await font('Nunito', [
        'assets/fonts/nunito/Nunito-VariableFont_wght.ttf',
        'assets/fonts/nunito/Nunito-Italic-VariableFont_wght.ttf',
      ]);
    });

    testWidgets('expanded session tree', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      NextGenLook.instance.themeId = 'onyx';
      await _pumpHome(
        tester,
        _Host(),
        prefs: {
          HmExpandedBots.key: jsonEncode({
            'c1': ['atlas', 'default'],
          }),
        },
      );
      await _settle(tester, 10);
      await expectLater(
        find.byType(HmHome),
        matchesGoldenFile('../goldens/home/bot_session_tree.png'),
      );
    });
  });
}
