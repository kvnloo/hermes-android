// Shared wiring: any screen opens a stored chat through hmOpenChat, Projects'
// chat rows open their chat, Agent settings follow the bots model, the bot
// look comes from the socket's ui_meta, the popover menu never overflows,
// and a chat exposes its working folder.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/android_share_intent_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:hermes_android/hm/features/work/hm_projects.dart';
import 'package:hermes_android/hm/hm_bots.dart';
import 'package:hermes_android/hm/screens/hm_agent_screen.dart';
import 'package:hermes_android/hm/screens/hm_chat_screen.dart';
import 'package:hermes_android/hm/screens/hm_home.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/nextgen/data/chat_controller.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/nextgen/ui/nextgen_scope.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image/image.dart' as image_lib;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'work_fakes.dart';

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

/// REST answers from a [MockClient]; JSON-RPC answers from [rpc]; the
/// socket counts as connected only when [online].
class _Gateway extends NextGenGateway {
  _Gateway(MockClient http, {this.online = false})
    : super(
        _conn(),
        dashboard: DashboardClient(
          host: '10.0.0.5',
          proxied: true,
          httpClient: http,
        ),
      ) {
    if (online) debugSetPhase(NgConnectionPhase.connected);
  }

  final bool online;
  final rpc = <String, Map<String, dynamic>>{};
  final calls = <String>[];

  @override
  Future<WsClient> connected({
    Duration timeout = const Duration(seconds: 20),
  }) async => throw StateError('offline');

  @override
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add(method);
    final a = rpc[method];
    if (a == null) throw StateError('no answer for $method');
    return a;
  }
}

/// A host with two profiles; `coder`'s REST row carries only the
/// `hermes-bots` key of its ui_meta, as `GET /api/profiles` does.
MockClient _host(List<String> requests, {String coderModel = 'm1'}) =>
    MockClient((r) async {
      requests.add('${r.method} ${r.url.path}');
      final path = r.url.path;
      if (path.endsWith('/profiles')) {
        return http.Response(
          jsonEncode({
            'profiles': [
              {'name': 'default', 'is_default': true},
              {
                'name': 'coder',
                'display_name': 'Coder',
                'model': coderModel,
                'ui_meta': {
                  'hermes-bots': {'pinned': true},
                },
              },
            ],
          }),
          200,
        );
      }
      if (path.endsWith('/messages')) {
        return http.Response(
          jsonEncode({
            'messages': [
              {
                'id': 1,
                'role': 'user',
                'content': 'Old question',
                'timestamp': 1,
              },
              {
                'id': 2,
                'role': 'assistant',
                'content': 'Old answer',
                'timestamp': 2,
              },
            ],
          }),
          200,
        );
      }
      if (path.contains('sessions')) {
        return http.Response(jsonEncode({'sessions': [], 'total': 0}), 200);
      }
      return http.Response('{}', 200);
    });

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Widget _scoped(SharedPreferences prefs, NextGenGateway gateway, Widget home) =>
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: nextGenTheme(Brightness.light, NextGenLook.instance),
      // Above the navigator, as in the app, so pushed routes see it.
      builder: (context, child) => NgScope(
        connManager: ConnectionManager(prefs),
        gateway: gateway,
        connections: [gateway.connection],
        switchTo: (_) async {},
        addGateway: () async {},
        signOut: (_) async {},
        reload: () async {},
        signInAgain: () async {},
        child: child!,
      ),
      home: home,
    );

class _SharePaths extends PathProviderPlatform {
  _SharePaths(this.path);
  final String path;

  @override
  Future<String?> getTemporaryPath() async => path;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'Android SEND drafts text and SEND_MULTIPLE drafts an image',
    (tester) async {
      const channel = MethodChannel(AndroidShareIntentService.channelName);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final share = AndroidShareIntentService();
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {'text': 'Text from Android'},
      );
      addTearDown(() {
        share.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      });
      await share.initialize();

      final root = Directory.systemTemp.createTempSync(
        'nextgen-android-share-',
      );
      final previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _SharePaths(root.path);
      addTearDown(() {
        PathProviderPlatform.instance = previousPaths;
        root.deleteSync(recursive: true);
      });
      final image = File('${root.path}/shared-photo.png')
        ..writeAsBytesSync(
          image_lib.encodePng(image_lib.Image(width: 2, height: 2)),
        );

      final prefs = await SharedPreferences.getInstance();
      final gateway = _Gateway(_host([]));
      addTearDown(gateway.dispose);
      await tester.pumpWidget(
        _scoped(prefs, gateway, HmHome(shareIntents: share)),
      );
      await _settle(tester);

      expect(find.byType(HmChatScreen), findsOneWidget);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'Text from Android',
      );
      expect(
        tester.widget<HmChatScreen>(find.byType(HmChatScreen)).chat.storedId,
        isNull,
      );

      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          MethodCall('sharePayload', {
            'files': [
              {
                'path': image.path,
                'name': 'shared-photo.png',
                'mediaType': 'image/png',
                'byteLength': image.lengthSync(),
              },
            ],
          }),
        ),
        (_) {},
      );
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (find.text('shared-photo.png').evaluate().isNotEmpty) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await _settle(tester);

      expect(find.byType(HmChatScreen), findsOneWidget);
      expect(find.text('shared-photo.png'), findsOneWidget);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        isEmpty,
      );
      expect(
        tester.widget<HmChatScreen>(find.byType(HmChatScreen)).chat.storedId,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  testWidgets('hmOpenChat opens a stored chat with its transcript', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final requests = <String>[];
    final gateway = _Gateway(_host(requests));
    final bots = HmBotsModel(gateway);
    final bot = HmBot.fromJson({'name': 'coder', 'display_name': 'Coder'});
    await tester.pumpWidget(
      _scoped(
        prefs,
        gateway,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => hmOpenChat(
                context,
                bot: bot,
                bots: bots,
                sessionId: 's1',
                title: 'Plan the launch',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _settle(tester);

    expect(find.byType(HmChatScreen), findsOneWidget);
    expect(find.text('Old answer'), findsOneWidget);
    expect(requests, contains('GET /api/sessions/s1/messages'));

    // Closing the chat refreshes the bot list.
    requests.clear();
    final popped = await tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .maybePop();
    expect(popped, isTrue);
    await tester.pump(const Duration(seconds: 1));
    await _settle(tester);
    expect(find.byType(HmChatScreen), findsNothing);
    expect(requests, contains('GET /api/profiles'));

    await tester.pumpWidget(const SizedBox());
    bots.dispose();
    gateway.dispose();
  });

  testWidgets('a project chat row opens its chat', (tester) async {
    final dash = FakeDashboard()
      ..on('GET profiles/projects/tree', 200, {
        'projects': [
          {
            'id': 'p_1',
            'label': 'Atlas',
            'path': '/srv/p_1',
            'sessionCount': 1,
            'repos': [],
            'previewSessions': [
              {'id': 's1', 'title': 'Plan the launch', 'started_at': 1.0},
            ],
            'sessionIds': ['s1'],
          },
        ],
      });
    final opened = <String>[];
    final source = HmProjectsSource(
      profile: 'atlas',
      scope: 'atlas',
      request: dash.call,
      rpc: FakeRpc().call,
    );
    await tester.pumpWidget(
      workHost(
        HmProjectsPage(
          source: source,
          onOpenChat: (context, Session s) async => opened.add(s.id),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plan the launch'));
    await tester.pumpAndSettle();
    expect(opened, ['s1']);
  });

  testWidgets('Agent settings show a Model save at once', (tester) async {
    final requests = <String>[];
    final gateway = _Gateway(_host(requests));
    final bots = HmBotsModel(gateway);
    await bots.refresh();
    final coder = bots.byProfile('coder')!;
    await tester.pumpWidget(
      MaterialApp(
        theme: nextGenTheme(Brightness.light, NextGenLook.instance),
        home: HmAgentScreen(bot: coder, bots: bots),
      ),
    );
    await tester.pump();
    expect(find.text('m1'), findsOneWidget);

    // The Model page saved and refreshed the bots: the row follows.
    bots.bots = [
      for (final b in bots.bots)
        b.profile == 'coder'
            ? HmBot.fromJson({
                'name': 'coder',
                'display_name': 'Coder',
                'model': 'claude-opus-5-5',
              })
            : b,
    ];
    bots.notifyListeners();
    await tester.pump();
    expect(find.text('m1'), findsNothing);
    expect(find.text('Opus 5.5'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    bots.dispose();
    gateway.dispose();
  });

  group('bot look', () {
    const character = {'seed': 42, 'color': '#123456'};

    test('the socket ui_meta lays the chosen character over REST', () async {
      final gateway = _Gateway(_host([]), online: true)
        ..rpc['profiles.list'] = {
          'profiles': [
            {'name': 'default', 'ui_meta': <String, dynamic>{}},
            {
              'name': 'coder',
              'ui_meta': {'character': character},
            },
          ],
        };
      final bots = HmBotsModel(gateway);
      await bots.refresh();
      final coder = bots.byProfile('coder')!;
      expect(gateway.calls, contains('profiles.list'));
      expect(coder.uiMeta['character'], character);
      // REST's own key is kept.
      expect(coder.uiMeta['hermes-bots'], {'pinned': true});
      // The avatar draws the chosen character, not a colour by position.
      expect(coder.character.seed, 42);
      expect(coder.character.color, const Color(0xFF123456));
      bots.dispose();
      gateway.dispose();
    });

    test('no socket: the REST rows stand', () async {
      final gateway = _Gateway(_host([]));
      final bots = HmBotsModel(gateway);
      await bots.refresh();
      expect(gateway.calls, isEmpty);
      expect(bots.byProfile('coder')!.uiMeta.containsKey('character'), isFalse);
      expect(bots.error, isNull);
      bots.dispose();
      gateway.dispose();
    });

    test('a refused profiles.list keeps the REST rows', () async {
      final gateway = _Gateway(_host([]), online: true);
      final bots = HmBotsModel(gateway);
      await bots.refresh();
      expect(gateway.calls, ['profiles.list']);
      expect(bots.bots.map((b) => b.displayName), ['Hermes', 'Coder']);
      expect(bots.error, isNull);
      bots.dispose();
      gateway.dispose();
    });
  });

  testWidgets('a long menu label ellipsizes instead of overflowing', (
    tester,
  ) async {
    const long =
        'Delete Project And Every Conversation That Was Ever Started Here';
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: nextGenTheme(Brightness.light, NextGenLook.instance),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => picked = await showHmMenu<String>(
                context,
                groups: [
                  [const HmMenuItem('del', Icons.delete_outline, long)],
                ],
              ),
              child: const Text('menu'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('menu'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final text = tester.widget<Text>(find.text(long));
    expect(text.overflow, TextOverflow.ellipsis);
    await tester.tap(find.text(long));
    await tester.pumpAndSettle();
    expect(picked, 'del');
  });

  test('a chat exposes the folder session.info reports', () async {
    final gateway = NextGenGateway(_conn());
    final chat = NgChatController(gateway)..runtimeId = 'r1';
    expect(chat.cwd, isNull);
    gateway.debugEmit(
      StreamEvent(
        type: 'session.info',
        data: {'cwd': '/srv/atlas', 'model': 'm1'},
        sessionId: 'r1',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(chat.cwd, '/srv/atlas');
    expect(chat.isNew, isTrue);
    chat.dispose();
    gateway.dispose();
  });
}
