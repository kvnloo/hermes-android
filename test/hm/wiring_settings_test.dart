// Settings → Chat and Caching take effect in the running chat: the display
// options change what a reply shows, the keyboard closes after sending, a
// chat keeps its rows for offline reading, Home seeds its list from the
// cache, and Artifacts keeps what each chat holds.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:hermes_android/hm/avatar/hm_avatar.dart';
import 'package:hermes_android/hm/features/artifacts/artifacts_data.dart';
import 'package:hermes_android/hm/features/settings/cache_store.dart';
import 'package:hermes_android/hm/features/settings/settings_prefs.dart';
import 'package:hermes_android/hm/hm_bots.dart';
import 'package:hermes_android/hm/screens/hm_chat_screen.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/nextgen/data/chat_controller.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/nextgen/ui/nextgen_scope.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings_support.dart';

SavedConnection _conn() => SavedConnection(
  id: 'c1',
  label: 'Home',
  host: '10.0.0.5',
  port: 9119,
  apiKey: '',
  desktopGatewayUrl: 'http://10.0.0.5:9119',
  singleLogin: true,
  signInMethod: 'none',
);

const _bot = HmBot(
  profile: 'default',
  isDefault: true,
  displayName: 'Hermes',
  model: 'm',
  provider: 'p',
  skillCount: 0,
  character: HmCharacterSpec(seed: 3),
);

/// A chat holding one finished turn with thinking and a tool call; send
/// records the text.
class _Chat extends NgChatController {
  _Chat(super.gateway) : super(sessionId: 'stored') {
    items
      ..add(NgUserItem('u0', 'Find the file', time: DateTime(2026)))
      ..add(
        NgAssistantItem('a0', open: false, time: DateTime(2026))
          ..reasoning = 'Look in the docs folder first.'
          ..text = 'It is in docs/plan.md.'
          ..tools.add(NgTool(id: 't1', name: 'search_files')),
      );
  }

  final sent = <String>[];

  @override
  Future<bool> send(
    String text, {
    List attachments = const [],
    String? submissionId,
  }) async {
    sent.add(text);
    return true;
  }
}

Future<(_Chat, NextGenGateway)> _pumpChat(
  WidgetTester tester,
  Map<String, Object> settings,
) async {
  final prefs = await freshPrefs(values: settings);
  HmSettingsPrefs.instance.load(prefs);
  final conn = _conn();
  final gateway = NextGenGateway(conn);
  final chat = _Chat(gateway)..runtimeId = 'stored';
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: nextGenTheme(Brightness.light, NextGenLook.instance),
      home: NgScope(
        connManager: ConnectionManager(prefs),
        gateway: gateway,
        connections: [conn],
        switchTo: (_) async {},
        addGateway: () async {},
        signOut: (_) async {},
        reload: () async {},
        signInAgain: () async {},
        child: HmChatScreen(
          bot: _bot,
          chat: chat,
          onAction: (_) async {},
          onNewChat: () {},
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  addTearDown(() {
    chat.dispose();
    gateway.dispose();
  });
  return (chat, gateway);
}

Future<void> _unmount(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox());

class _FakeMessageCache implements NgMessageCache {
  final puts = <(String, String, int)>[];
  List<Map<String, dynamic>>? kept;

  @override
  Future<void> put(
    String host,
    String sessionId,
    List<Map<String, dynamic>> rows,
  ) async => puts.add((host, sessionId, rows.length));

  @override
  Future<List<Map<String, dynamic>>?> read(
    String host,
    String sessionId,
  ) async => kept;
}

/// REST answers from [http]; the socket is down, so attaching fails fast.
class _OfflineSocketGateway extends NextGenGateway {
  _OfflineSocketGateway(super.connection, {super.dashboard});

  @override
  Future<WsClient> connected({
    Duration timeout = const Duration(seconds: 20),
  }) async => throw StateError('offline');
}

NextGenGateway _gatewayWith(MockClient http) => _OfflineSocketGateway(
  _conn(),
  dashboard: DashboardClient(host: '10.0.0.5', proxied: true, httpClient: http),
);

class _Source implements HmArtifactsSource {
  @override
  String get owner => 'o';

  @override
  Future<List<HmArtifactSession>> sessions() async => [
    const HmArtifactSession(id: 's1', title: 'Plans', lastActive: 10),
  ];

  @override
  Future<HmArtifactMessagePage> messages(
    String sessionId, {
    required int offset,
    required int limit,
  }) async => const HmArtifactMessagePage([
    {
      'role': 'assistant',
      'content': 'See https://example.com/report for details.',
      'timestamp': 10,
    },
  ], limit: 0);
}

class _MemoryIndex implements HmArtifactIndexStore {
  String? data;
  @override
  Future<String?> read(String owner) async => data;
  @override
  Future<void> write(String owner, String data) async => this.data = data;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('chat display options', () {
    testWidgets('defaults: Thinking off hides the reasoning row; tools show', (
      tester,
    ) async {
      await _pumpChat(tester, {});
      expect(find.text('Thought'), findsNothing);
      expect(find.text('Used search_files'), findsOneWidget);
      expect(find.text('It is in docs/plan.md.'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('Thinking on shows it; Tool calls off hides the tools row', (
      tester,
    ) async {
      await _pumpChat(tester, {
        HmSettingsPrefs.showThinkingKey: true,
        HmSettingsPrefs.showToolsKey: false,
      });
      expect(find.text('Thought'), findsOneWidget);
      expect(find.text('Used search_files'), findsNothing);
      // Folded (the default): the reasoning waits behind its row.
      expect(find.text('Look in the docs folder first.'), findsNothing);
      await _unmount(tester);
    });

    testWidgets('Fold finished turns off opens a finished turn', (
      tester,
    ) async {
      await _pumpChat(tester, {
        HmSettingsPrefs.showThinkingKey: true,
        HmSettingsPrefs.foldFinishedKey: false,
      });
      expect(find.text('Look in the docs folder first.'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('Bubbles puts the reply in a bubble; Standard does not', (
      tester,
    ) async {
      await _pumpChat(tester, {});
      expect(find.byKey(const ValueKey('ng-reply-bubble')), findsNothing);
      await _unmount(tester);

      await _pumpChat(tester, {
        HmSettingsPrefs.chatStyleKey: HmChatStyle.bubbles.name,
      });
      expect(find.byKey(const ValueKey('ng-reply-bubble')), findsOneWidget);
      // Switching back in Settings redraws the open chat.
      await HmSettingsPrefs.instance.setChatStyle(HmChatStyle.standard);
      await tester.pump();
      expect(find.byKey(const ValueKey('ng-reply-bubble')), findsNothing);
      await _unmount(tester);
    });

    testWidgets('Dismiss keyboard after sending closes the keyboard', (
      tester,
    ) async {
      final (chat, _) = await _pumpChat(tester, {
        HmSettingsPrefs.dismissKeyboardKey: true,
      });
      await tester.showKeyboard(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'thanks');
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.tap(find.byTooltip('Send'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(chat.sent, ['thanks']);
      expect(tester.testTextInput.isVisible, isFalse);
      await _unmount(tester);
    });

    testWidgets('Dismiss keyboard off keeps the keyboard up', (tester) async {
      final (chat, _) = await _pumpChat(tester, {});
      await tester.showKeyboard(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'thanks');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(chat.sent, ['thanks']);
      expect(tester.testTextInput.isVisible, isTrue);
      await _unmount(tester);
    });
  });

  group('message cache', () {
    tearDown(() => NgChatController.messageCache = null);

    test('a loaded chat is kept for its host', () async {
      final cache = _FakeMessageCache();
      NgChatController.messageCache = cache;
      final gateway = _gatewayWith(
        MockClient(
          (r) async => http.Response(
            jsonEncode({
              'messages': [
                {'id': 1, 'role': 'user', 'content': 'hi', 'timestamp': 1},
                {
                  'id': 2,
                  'role': 'assistant',
                  'content': 'hello',
                  'timestamp': 2,
                },
              ],
            }),
            200,
          ),
        ),
      );
      final chat = NgChatController(gateway, sessionId: 's1');
      await chat.open();
      expect(cache.puts, [('c1', 's1', 2)]);
      expect(chat.historyError, isNull);
      chat.dispose();
      gateway.dispose();
    });

    test('offline: the kept copy shows instead of an error', () async {
      final cache = _FakeMessageCache()
        ..kept = [
          {'id': 1, 'role': 'user', 'content': 'kept question', 'timestamp': 1},
          {
            'id': 2,
            'role': 'assistant',
            'content': 'kept answer',
            'timestamp': 2,
          },
        ];
      NgChatController.messageCache = cache;
      final gateway = _gatewayWith(
        MockClient((r) async => throw const SocketException('offline')),
      );
      final chat = NgChatController(gateway, sessionId: 's1');
      await chat.open();
      expect(chat.historyError, isNull);
      expect(chat.items.whereType<NgAssistantItem>().map((i) => i.text), [
        'kept answer',
      ]);
      chat.dispose();
      gateway.dispose();
    });

    test('offline with nothing kept still says it could not load', () async {
      NgChatController.messageCache = _FakeMessageCache();
      final gateway = _gatewayWith(
        MockClient((r) async => throw const SocketException('offline')),
      );
      final chat = NgChatController(gateway, sessionId: 's1');
      await chat.open();
      expect(chat.historyError, isNotNull);
      chat.dispose();
      gateway.dispose();
    });
  });

  group('chat list and files cache', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('hm_wiring'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test(
      'Home seeds the bots from the cache before the host answers',
      () async {
        final settings = await loadedSettings();
        final store = HmCacheStore(root: () async => tmp, prefs: settings);
        await store.putChatList(
          'c1',
          'coder',
          bot: {'name': 'coder', 'display_name': 'Coder', 'model': 'm1'},
          sessions: [
            Session.fromJson({
              'id': 's9',
              'title': 'Kept chat',
              'started_at': 5.0,
              'last_active': 5.0,
            }),
          ],
        );
        final bots = HmBotsModel(NextGenGateway(_conn()));
        await bots.seedFromCache('c1', store: store);
        expect(bots.bots.map((b) => b.displayName), ['Coder']);
        expect(bots.summaries.single.latest?.title, 'Kept chat');

        // Once loaded, the cache doesn't overwrite the live list.
        bots.bots = [
          HmBot.fromJson({'name': 'default'}),
        ];
        await bots.seedFromCache('c1', store: store);
        expect(bots.bots.map((b) => b.profile), ['default']);
        bots.dispose();
      },
    );

    test('an artifact scan reports what each chat holds', () async {
      final scanned = <String, List<String>>{};
      final loader = HmArtifactsLoader(
        _Source(),
        store: _MemoryIndex(),
        onScanned: (id, items) async =>
            scanned[id] = [for (final a in items) a.value],
      );
      final state = await loader.load();
      expect(state, isA<HmArtifactsLoaded>());
      expect(scanned, {
        's1': ['https://example.com/report'],
      });
    });

    test('putFiles keeps the scanned items for Caching', () async {
      final settings = await loadedSettings();
      final store = HmCacheStore(root: () async => tmp, prefs: settings);
      final loader = HmArtifactsLoader(
        _Source(),
        store: _MemoryIndex(),
        onScanned: (id, items) =>
            store.putFiles('c1', id, [for (final a in items) a.toJson()]),
      );
      await loader.load();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((await store.usage()).files, greaterThan(0));
    });
  });
}
