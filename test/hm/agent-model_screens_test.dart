// Agent settings → Model (Default Model, All models, Advanced Settings) and
// Agent settings → New Agent (Create a New Agent), pumped against a fake
// dashboard. Asserts what the user sees and the requests that go out.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/hermes_sign_in.dart';
import 'package:hermes_android/hm/features/agent_model/hm_model_api.dart';
import 'package:hermes_android/hm/features/agent_model/hm_model_page.dart';
import 'package:hermes_android/hm/features/agent_model/hm_new_agent.dart';
import 'package:hermes_android/hm/hm_bots.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A host that answers from [routes] (`METHOD path` → status + JSON) and
/// records every request.
class FakeHost {
  final routes = <String, List<(int, Object)>>{};
  final requests = <http.Request>[];

  void on(String key, int status, Object body) =>
      (routes[key] ??= []).add((status, body));

  List<http.Request> sent(String key) => [
    for (final r in requests)
      if ('${r.method} ${r.url.path}' == key) r,
  ];

  late final client = MockClient((req) async {
    requests.add(req);
    final key = '${req.method} ${req.url.path}';
    final queue = routes[key];
    if (queue == null || queue.isEmpty) {
      return http.Response('{"detail":"Not Found"}', 404);
    }
    final (status, body) = queue.length > 1 ? queue.removeAt(0) : queue.first;
    return http.Response(jsonEncode(body), status);
  });

  DashboardClient get dashboard =>
      DashboardClient(host: 'host.test', proxied: true, httpClient: client);
}

final rpcCalls = <(String, Map<String, dynamic>)>[];

HmAgentModelApi apiFor(FakeHost host, {bool rpcOk = true}) => HmAgentModelApi(
  host.dashboard,
  rpc: (method, params) async {
    rpcCalls.add((method, params));
    return {
      'ok': rpcOk,
      'applied': {'ui_meta': rpcOk},
    };
  },
);

final coder = HmBot.fromJson({
  'name': 'coder',
  'model': 'claude-opus-5-5',
  'provider': 'anthropic',
});
final hermes = HmBot.fromJson({'name': 'default', 'is_default': true});

const catalog = {
  'provider': 'anthropic',
  'model': 'claude-opus-5-5',
  'providers': [
    {
      'slug': 'anthropic',
      'name': 'Anthropic',
      'models': ['claude-opus-5-5', 'claude-sonnet-5-5'],
      'is_current': true,
    },
    {
      'slug': 'openai',
      'name': 'OpenAI',
      'models': ['gpt-5'],
    },
  ],
};

Widget app(Widget home) => MaterialApp(
  theme: nextGenTheme(Brightness.light, NextGenLook.instance),
  home: home,
);

/// Opens [page] on top of a launcher so it can pop.
Widget launcher(Widget page) => app(
  Builder(
    builder: (ctx) => Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(
            ctx,
          ).push(MaterialPageRoute<void>(builder: (_) => page)),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Map<String, dynamic> bodyOf(http.Request r) =>
    jsonDecode(r.body) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    HermesSignInVault.resetForTesting(MemorySignInSecretStore());
    rpcCalls.clear();
  });
  void tallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
  }

  group('Default Model', () {
    testWidgets('loaded: shows the profile model, scoped to the bot', (
      tester,
    ) async {
      tallScreen(tester);
      final host = FakeHost()
        ..on('GET /api/model/info', 200, {
          'model': 'claude-opus-5-5',
          'provider': 'anthropic',
        });
      await tester.pumpWidget(app(HmModelPage(bot: coder, api: apiFor(host))));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await settle(tester);

      expect(find.text('Default Model'), findsOneWidget);
      expect(find.text('Advanced'), findsOneWidget);
      expect(find.text('Profile Default'), findsOneWidget);
      expect(find.text('Opus 5.5 · anthropic'), findsOneWidget);
      expect(find.text('Favourites'), findsOneWidget);
      expect(find.text('All models'), findsOneWidget);
      expect(
        find.text('Star a model in All models to keep it here.'),
        findsOneWidget,
      );
      expect(
        host.sent('GET /api/model/info').single.url.queryParameters['profile'],
        'coder',
      );
    });

    testWidgets('default bot sends no profile; unset model says so', (
      tester,
    ) async {
      tallScreen(tester);
      final host = FakeHost()
        ..on('GET /api/model/info', 200, {'model': '', 'provider': ''});
      await tester.pumpWidget(app(HmModelPage(bot: hermes, api: apiFor(host))));
      await settle(tester);
      expect(find.text('Inherits the server default'), findsOneWidget);
      expect(
        host.sent('GET /api/model/info').single.url.queryParameters,
        isNot(contains('profile')),
      );
    });

    testWidgets('error: shows the official text and reloads', (tester) async {
      tallScreen(tester);
      final host = FakeHost()
        ..on('GET /api/model/info', 404, {
          'detail': "Profile 'coder' not found",
        })
        ..on('GET /api/model/info', 200, {
          'model': 'gpt-5',
          'provider': 'openai',
        });
      await tester.pumpWidget(app(HmModelPage(bot: coder, api: apiFor(host))));
      await settle(tester);
      expect(find.text('Model settings could not be loaded.'), findsOneWidget);
      expect(find.text("Profile 'coder' not found"), findsOneWidget);

      await tester.tap(find.text('Reload models'));
      await settle(tester);
      expect(find.text('gpt-5 · openai'), findsOneWidget);
    });

    testWidgets('picking in All models saves to the profile and refreshes', (
      tester,
    ) async {
      tallScreen(tester);
      var refreshed = 0;
      final host = FakeHost()
        ..on('GET /api/model/info', 200, {
          'model': 'claude-opus-5-5',
          'provider': 'anthropic',
        })
        ..on('GET /api/model/info', 200, {
          'model': 'gpt-5',
          'provider': 'openai',
        })
        ..on('GET /api/model/options', 200, catalog)
        ..on('POST /api/model/set', 200, {'ok': true, 'scope': 'main'});
      await tester.pumpWidget(
        app(
          HmModelPage(
            bot: coder,
            api: apiFor(host),
            onSaved: () async => refreshed++,
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.text('All models'));
      await settle(tester);

      expect(find.text('Anthropic'), findsOneWidget);
      expect(find.text('OpenAI'), findsOneWidget);
      expect(find.text('Sonnet 5.5'), findsOneWidget);
      expect(
        host
            .sent('GET /api/model/options')
            .single
            .url
            .queryParameters['profile'],
        'coder',
      );

      await tester.tap(find.text('gpt-5'));
      await settle(tester);

      final set = host.sent('POST /api/model/set').single;
      expect(set.url.queryParameters['profile'], 'coder');
      expect(bodyOf(set), {
        'scope': 'main',
        'provider': 'openai',
        'model': 'gpt-5',
      });
      expect(refreshed, 1);
      // Back on Default Model, which now shows the new model.
      expect(find.text('Profile Default'), findsOneWidget);
      expect(find.text('gpt-5 · openai'), findsOneWidget);
    });

    testWidgets('expensive model asks first, then confirms', (tester) async {
      tallScreen(tester);
      final host = FakeHost()
        ..on('GET /api/model/info', 200, {
          'model': 'gpt-5',
          'provider': 'openai',
        })
        ..on('GET /api/model/options', 200, catalog)
        ..on('POST /api/model/set', 200, {
          'ok': false,
          'confirm_required': true,
          'confirm_message': 'Opus 5.5 costs \$15 per million tokens.',
        })
        ..on('GET /api/model/info', 200, {
          'model': 'claude-opus-5-5',
          'provider': 'anthropic',
        })
        ..on('POST /api/model/set', 200, {'ok': true});
      await tester.pumpWidget(app(HmModelPage(bot: coder, api: apiFor(host))));
      await settle(tester);
      await tester.tap(find.text('All models'));
      await settle(tester);
      await tester.tap(find.text('Opus 5.5'));
      await settle(tester);

      expect(find.text('Confirm model change'), findsOneWidget);
      expect(
        find.text('Opus 5.5 costs \$15 per million tokens.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Use anyway'));
      await settle(tester);

      final sets = host.sent('POST /api/model/set');
      expect(sets, hasLength(2));
      expect(bodyOf(sets.first), isNot(contains('confirm_expensive_model')));
      expect(bodyOf(sets.last)['confirm_expensive_model'], true);
      expect(find.text('Opus 5.5 · anthropic'), findsOneWidget);
    });

    testWidgets('a refused save shows the host reason and stays', (
      tester,
    ) async {
      tallScreen(tester);
      final host = FakeHost()
        ..on('GET /api/model/info', 200, {
          'model': 'gpt-5',
          'provider': 'openai',
        })
        ..on('GET /api/model/options', 200, catalog)
        ..on('POST /api/model/set', 400, {
          'detail': 'provider and model required for main',
        });
      await tester.pumpWidget(app(HmModelPage(bot: coder, api: apiFor(host))));
      await settle(tester);
      await tester.tap(find.text('All models'));
      await settle(tester);
      await tester.tap(find.text('Sonnet 5.5'));
      await settle(tester);
      expect(
        find.textContaining('provider and model required for main'),
        findsOneWidget,
      );
      // Still on the picker.
      expect(find.text('OpenAI'), findsOneWidget);
    });

    testWidgets('starred models show under Favourites', (tester) async {
      tallScreen(tester);
      final host = FakeHost()
        ..on('GET /api/model/info', 200, {
          'model': 'gpt-5',
          'provider': 'openai',
        })
        ..on('GET /api/model/options', 200, catalog);
      await tester.pumpWidget(app(HmModelPage(bot: coder, api: apiFor(host))));
      await settle(tester);
      await tester.tap(find.text('All models'));
      await settle(tester);
      await tester.tap(find.byTooltip('Add to favourites').first);
      await settle(tester);
      expect(find.byTooltip('Remove from favourites'), findsOneWidget);
      await tester.pageBack();
      await settle(tester);

      expect(
        find.text('Star a model in All models to keep it here.'),
        findsNothing,
      );
      expect(find.text('Opus 5.5'), findsOneWidget);
    });

    testWidgets('All models: empty and unavailable catalogs', (tester) async {
      tallScreen(tester);
      final host = FakeHost()
        ..on('GET /api/model/info', 200, {'model': 'm', 'provider': 'p'})
        ..on('GET /api/model/options', 200, {'providers': []})
        ..on('GET /api/model/options', 500, {
          'detail': 'Failed to list model options',
        });
      await tester.pumpWidget(app(HmModelPage(bot: coder, api: apiFor(host))));
      await settle(tester);
      await tester.tap(find.text('All models'));
      await settle(tester);
      expect(find.text('No models are configured.'), findsOneWidget);
      await tester.pageBack();
      await settle(tester);

      await tester.tap(find.text('All models'));
      await settle(tester);
      expect(find.text('Models unavailable'), findsOneWidget);
      expect(find.text('Failed to list model options'), findsOneWidget);
      expect(find.text('Reload models'), findsOneWidget);
    });
  });

  group('Advanced Settings', () {
    testWidgets('loaded: main, auxiliary and MoA; pin an auxiliary task', (
      tester,
    ) async {
      tallScreen(tester);
      final host = FakeHost()
        ..on('GET /api/model/auxiliary', 200, {
          'main': {'provider': 'anthropic', 'model': 'claude-opus-5-5'},
          'tasks': [
            {'task': 'vision', 'provider': 'auto', 'model': ''},
            {
              'task': 'title_generation',
              'provider': 'openai',
              'model': 'gpt-5',
            },
          ],
        })
        ..on('GET /api/model/moa', 200, {
          'reference_models': [
            {'provider': 'openai', 'model': 'gpt-5'},
          ],
          'aggregator': {'provider': 'anthropic', 'model': 'claude-opus-5-5'},
        })
        ..on('GET /api/model/options', 200, catalog)
        ..on('POST /api/model/set', 200, {'ok': true});
      await tester.pumpWidget(
        app(HmModelAdvancedPage(bot: coder, api: apiFor(host))),
      );
      await settle(tester);

      expect(find.text('Advanced Settings'), findsOneWidget);
      expect(find.text('Main Model'), findsOneWidget);
      expect(find.text('Vision'), findsOneWidget);
      expect(find.text('Auto — follows main model'), findsOneWidget);
      expect(find.text('Title generation'), findsOneWidget);
      expect(find.text('Mixture of Agents'), findsOneWidget);
      expect(find.text('Aggregator'), findsOneWidget);

      await tester.tap(find.text('Vision'));
      await settle(tester);
      await tester.tap(find.text('Sonnet 5.5'));
      await settle(tester);
      final set = host.sent('POST /api/model/set').single;
      expect(set.url.queryParameters['profile'], 'coder');
      expect(bodyOf(set), {
        'scope': 'auxiliary',
        'provider': 'anthropic',
        'model': 'claude-sonnet-5-5',
        'task': 'vision',
      });
    });

    testWidgets('error and empty states', (tester) async {
      tallScreen(tester);
      final host = FakeHost()
        ..on('GET /api/model/auxiliary', 500, {
          'detail': 'Failed to read auxiliary config',
        })
        ..on('GET /api/model/auxiliary', 200, {'tasks': [], 'main': {}})
        ..on('GET /api/model/moa', 500, {
          'detail': 'Failed to read MoA config',
        });
      await tester.pumpWidget(
        app(HmModelAdvancedPage(bot: coder, api: apiFor(host))),
      );
      await settle(tester);
      expect(find.text('Failed to read auxiliary config'), findsOneWidget);
      expect(find.text('Failed to read MoA config'), findsOneWidget);

      await tester.tap(find.text('Reload models'));
      await settle(tester);
      expect(
        find.text('This profile reports no auxiliary model slots.'),
        findsOneWidget,
      );
      expect(find.text('Server default'), findsOneWidget);
    });
  });

  group('Create a New Agent', () {
    Widget page(
      FakeHost host, {
      Future<void> Function()? onCreated,
      bool rpcOk = true,
    }) => launcher(
      HmNewAgentPage(
        api: apiFor(host, rpcOk: rpcOk),
        bots: [hermes, coder],
        onCreated: onCreated,
      ),
    );

    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.text('open'));
      await settle(tester);
    }

    Finder createButton() => find.widgetWithText(FilledButton, 'Create Agent');

    testWidgets('shows the fields; Create waits for a valid name', (
      tester,
    ) async {
      tallScreen(tester);
      await tester.pumpWidget(page(FakeHost()));
      await open(tester);

      expect(find.text('Create a New Agent'), findsOneWidget);
      expect(find.bySemanticsLabel('Edit agent image'), findsOneWidget);
      expect(find.text('agent-name'), findsOneWidget);
      expect(find.text('Description'), findsOneWidget);
      expect(find.text('What is this agent good at?'), findsOneWidget);
      expect(find.text('Default Model'), findsOneWidget);
      expect(find.text('Server default'), findsOneWidget);
      expect(find.text('Soul'), findsOneWidget);
      expect(find.text('Clone Config From'), findsOneWidget);
      expect(find.text('Hermes'), findsOneWidget);
      expect(tester.widget<FilledButton>(createButton()).onPressed, isNull);

      await tester.enterText(find.byType(TextField).first, '-bad');
      await tester.pump();
      expect(find.text(hmProfileNameRule), findsOneWidget);
      expect(tester.widget<FilledButton>(createButton()).onPressed, isNull);

      await tester.enterText(find.byType(TextField).first, 'My Coder');
      await tester.pump();
      // Typed as a profile id.
      expect(find.text('my-coder'), findsOneWidget);
      expect(find.text(hmProfileNameRule), findsNothing);
      expect(tester.widget<FilledButton>(createButton()).onPressed, isNotNull);
    });

    testWidgets('creates the profile, stores its look, refreshes Home', (
      tester,
    ) async {
      tallScreen(tester);
      var refreshed = 0;
      final host = FakeHost()
        ..on('GET /api/model/options', 200, catalog)
        ..on('POST /api/profiles', 200, {
          'ok': true,
          'name': 'researcher',
          'model_set': true,
          'model_error': null,
          'warnings': [],
        });
      await tester.pumpWidget(page(host, onCreated: () async => refreshed++));
      await open(tester);

      await tester.enterText(find.byType(TextField).at(0), 'researcher');
      await tester.enterText(find.byType(TextField).at(1), 'Digs up papers');
      await tester.tap(find.text('Default Model'));
      await settle(tester);
      // Picks from the clone source's (default profile's) catalog.
      expect(
        host.sent('GET /api/model/options').single.url.queryParameters,
        isNot(contains('profile')),
      );
      await tester.tap(find.text('gpt-5'));
      await settle(tester);
      expect(find.text('gpt-5'), findsOneWidget);

      await tester.tap(createButton());
      await settle(tester);

      final post = host.sent('POST /api/profiles').single;
      expect(bodyOf(post), {
        'name': 'researcher',
        'description': 'Digs up papers',
        'provider': 'openai',
        'model': 'gpt-5',
        'clone_from': 'default',
      });
      final (method, params) = rpcCalls.single;
      expect(method, 'profiles.configure');
      expect(params['name'], 'researcher');
      final character =
          (params['ui_meta'] as Map)['character'] as Map<String, Object?>;
      expect(character['seed'], isA<int>());
      expect(character['color'], matches(RegExp(r'^#[0-9A-F]{6}$')));
      expect(refreshed, 1);
      // Popped back to the launcher.
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('a host refusal is shown in its own words', (tester) async {
      tallScreen(tester);
      const refusal =
          "A profile named 'coder' already exists. Switch to it with "
          '`hermes profile use coder`, or pick another name.';
      final host = FakeHost()
        ..on('POST /api/profiles', 400, {'detail': refusal});
      await tester.pumpWidget(page(host));
      await open(tester);
      await tester.enterText(find.byType(TextField).first, 'coder');
      await tester.pump();
      await tester.tap(createButton());
      await settle(tester);

      expect(find.text(refusal), findsOneWidget);
      expect(find.text('Create a New Agent'), findsOneWidget);
      expect(rpcCalls, isEmpty);
    });

    testWidgets('saving shows progress; a missing picture is reported', (
      tester,
    ) async {
      tallScreen(tester);
      final host = FakeHost()
        ..on('POST /api/profiles', 200, {'ok': true, 'name': 'scribe'});
      await tester.pumpWidget(page(host, rpcOk: false));
      await open(tester);
      await tester.enterText(find.byType(TextField).first, 'scribe');
      await tester.tap(find.text('Clone Config From'));
      await settle(tester);
      await tester.tap(find.text('Coder').last);
      await settle(tester);
      expect(find.text('Coder'), findsOneWidget);

      await tester.tap(createButton());
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(FilledButton),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      await settle(tester);
      expect(
        bodyOf(host.sent('POST /api/profiles').single)['clone_from'],
        'coder',
      );
      expect(
        find.text("Couldn't give the new agent its picture"),
        findsOneWidget,
      );
    });
  });

  group('Entry points', () {
    testWidgets('Model save and New Agent create reload the bots', (
      tester,
    ) async {
      tallScreen(tester);
      final host = FakeHost()
        ..on('GET /api/profiles', 200, {
          'profiles': [
            {'name': 'default', 'is_default': true},
            {'name': 'coder'},
          ],
        })
        ..on('GET /api/model/info', 200, {
          'model': 'gpt-5',
          'provider': 'openai',
        })
        ..on('GET /api/model/options', 200, catalog)
        ..on('POST /api/model/set', 200, {'ok': true})
        ..on('POST /api/profiles', 200, {'ok': true, 'name': 'scout'});
      final gateway = NextGenGateway(
        SavedConnection(
          id: 'c1',
          label: 'Home',
          host: 'host.test',
          port: 9119,
          apiKey: '',
          desktopGatewayUrl: 'http://host.test:9119',
          singleLogin: true,
          signInMethod: 'none',
        ),
        dashboard: host.dashboard,
      );
      final bots = HmBotsModel(gateway);
      addTearDown(() {
        bots.dispose();
        gateway.dispose();
      });
      await tester.pumpWidget(
        app(
          Builder(
            builder: (ctx) => Scaffold(
              body: Column(
                children: [
                  TextButton(
                    onPressed: () =>
                        openHmModelPage(ctx, bot: coder, bots: bots),
                    child: const Text('model'),
                  ),
                  TextButton(
                    onPressed: () => openHmNewAgent(ctx, bots: bots),
                    child: const Text('new'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('model'));
      await settle(tester);
      expect(find.text('Default Model'), findsOneWidget);
      await tester.tap(find.text('All models'));
      await settle(tester);
      await tester.tap(find.text('Sonnet 5.5'));
      await settle(tester);
      expect(host.sent('POST /api/model/set'), hasLength(1));
      expect(host.sent('GET /api/profiles'), hasLength(1));
      expect(bots.byProfile('coder'), isNotNull);
      await tester.pageBack();
      await settle(tester);

      await tester.tap(find.text('new'));
      await settle(tester);
      expect(find.text('Create a New Agent'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'scout');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Create Agent'));
      await settle(tester);
      expect(host.sent('POST /api/profiles'), hasLength(1));
      expect(host.sent('GET /api/profiles'), hasLength(2));
      // No live socket here: the look could not be stored, and says so.
      expect(
        find.text("Couldn't give the new agent its picture"),
        findsOneWidget,
      );
      expect(find.text('new'), findsOneWidget);
    });
  });
}
