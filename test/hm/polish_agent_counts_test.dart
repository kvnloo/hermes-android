// Agent settings prints the bot's installed plugin count beside Plugins and
// its MCP server count beside MCP (official s007, s032). Loading and errors
// show no number.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/hm/avatar/hm_avatar.dart';
import 'package:hermes_android/hm/features/integrations/integrations_api.dart';
import 'package:hermes_android/hm/hm_bots.dart';
import 'package:hermes_android/hm/screens/hm_agent_screen.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';

import 'integrations_fakes.dart';

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

const _coder = HmBot(
  profile: 'coder',
  isDefault: false,
  displayName: 'Coder',
  model: 'm',
  provider: 'p',
  skillCount: 43,
  character: HmCharacterSpec(seed: 3),
);

Map<String, dynamic> _plugin(String name) => {
  'name': name,
  'version': '1.0.0',
  'source': 'bundled',
  'runtime_status': 'enabled',
};

Map<String, dynamic> _server(String name) => {
  'name': name,
  'transport': 'http',
  'url': 'https://$name.example/mcp',
};

Future<void> _pump(WidgetTester tester, FakeTransport transport) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final gateway = NextGenGateway(_conn());
  final bots = HmBotsModel(gateway)..bots = [_coder];
  addTearDown(() {
    bots.dispose();
    gateway.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: nextGenTheme(Brightness.light, NextGenLook.instance),
      home: HmAgentScreen(
        bot: _coder,
        bots: bots,
        integrations: HmIntegrationsApi(transport, profile: _coder.scope),
      ),
    ),
  );
}

/// The avatar animates forever, so pump the fake requests through by hand.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The value text in the row labelled [label], if any.
Finder _valueIn(String label, String value) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(InkWell)),
  matching: find.text(value),
);

void main() {
  testWidgets('loaded: installed plugins and MCP servers, scoped to the bot', (
    tester,
  ) async {
    final t = FakeTransport();
    t.rests['GET dashboard/plugins/hub'] = (_) => {
      'plugins': [for (var i = 0; i < 54; i++) _plugin('p$i')],
    };
    t.rests['GET mcp/servers'] = (_) => {
      'servers': [_server('linear'), _server('github')],
    };
    await _pump(tester, t);
    await _settle(tester);
    expect(_valueIn('Plugins', '54'), findsOneWidget);
    expect(_valueIn('MCP', '2'), findsOneWidget);
    expect(t.named('GET dashboard/plugins/hub').single.query, {
      'profile': 'coder',
    });
    expect(t.named('GET mcp/servers').single.query, {'profile': 'coder'});
  });

  testWidgets('empty: no MCP servers leaves the row blank, no "0"', (
    tester,
  ) async {
    final t = FakeTransport();
    t.rests['GET dashboard/plugins/hub'] = (_) => {
      'plugins': [_plugin('a')],
    };
    t.rests['GET mcp/servers'] = (_) => {'servers': <Object>[]};
    await _pump(tester, t);
    await _settle(tester);
    expect(_valueIn('Plugins', '1'), findsOneWidget);
    expect(_valueIn('MCP', '0'), findsNothing);
  });

  testWidgets('loading shows no number', (tester) async {
    final hub = Completer<Object?>();
    final t = FakeTransport();
    t.rests['GET dashboard/plugins/hub'] = (_) => hub.future;
    t.rests['GET mcp/servers'] = (_) => Completer<Object?>().future;
    await _pump(tester, t);
    await tester.pump();
    expect(find.text('Plugins'), findsOneWidget);
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Plugins'),
          matching: find.byType(InkWell),
        ),
        matching: find.byType(Text),
      ),
      findsOneWidget, // the label only
    );
    hub.complete({
      'plugins': [_plugin('a'), _plugin('b')],
    });
    await tester.pump();
    await tester.pump();
    expect(_valueIn('Plugins', '2'), findsOneWidget);
  });

  testWidgets('an error shows no number; the other row still loads', (
    tester,
  ) async {
    final t = FakeTransport();
    t.rests['GET dashboard/plugins/hub'] = (_) => failWith(500);
    t.rests['GET mcp/servers'] = (_) => {
      'servers': [_server('linear')],
    };
    await _pump(tester, t);
    await _settle(tester);
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Plugins'),
          matching: find.byType(InkWell),
        ),
        matching: find.byType(Text),
      ),
      findsOneWidget,
    );
    expect(_valueIn('MCP', '1'), findsOneWidget);
  });
}
