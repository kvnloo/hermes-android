// Home with a fake host: group rows appear beside bots, open their room, and
// the Filters menu changes the list.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:hermes_android/hm/screens/hm_home.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/nextgen/ui/nextgen_scope.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'groups_fakes.dart';

SavedConnection _connection() => SavedConnection(
  id: 'c1',
  label: 'Home',
  host: '10.0.0.5',
  port: 9119,
  apiKey: '',
  desktopGatewayUrl: 'http://10.0.0.5:9119',
  singleLogin: true,
  signInMethod: 'none',
  dashboardProxied: true,
);

class FakeHomeGateway extends NextGenGateway {
  FakeHomeGateway(super.connection, {super.dashboard, required this.fake});
  final FakeGroupsHost fake;
  final calls = <String>[];

  @override
  Future<WsClient> connected({
    Duration timeout = const Duration(seconds: 20),
  }) async => WsClient('http://10.0.0.5:9119');

  @override
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    calls.add(method);
    final h = fake.handlers[method];
    if (h == null) {
      throw JsonRpcError(method, 'unknown method: $method', code: -32601);
    }
    return h(params);
  }
}

MockClient _http() => MockClient((request) async {
  final path = request.url.path;
  if (path.endsWith('/profiles')) {
    return http.Response(
      jsonEncode({
        'profiles': [
          {'name': 'default', 'is_default': true},
          {'name': 'atlas'},
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

Future<FakeHomeGateway> pumpHome(WidgetTester tester, FakeGroupsHost fake) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final gateway = FakeHomeGateway(
    _connection(),
    dashboard: DashboardClient(
      host: '10.0.0.5',
      proxied: true,
      httpClient: _http(),
    ),
    fake: fake,
  );
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: NgScope(
        connManager: ConnectionManager(prefs),
        gateway: gateway,
        connections: [gateway.connection],
        switchTo: (_) async {},
        addGateway: () async {},
        signOut: (_) async {},
        reload: () async {},
        signInAgain: () async {},
        child: const HmHome(),
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return gateway;
}

FakeGroupsHost _groupsHost() => FakeGroupsHost()
  ..on('groups.capabilities', {
    'driver': true,
    'methods': ['groups.create', 'groups.list', 'groups.log', 'groups.state'],
  })
  ..on('groups.list', {
    'rooms': [roomJson(name: 'Research Crew', updatedAt: 1e10)],
    'next_offset': null,
  })
  ..on('groups.state', stateJson(room: roomJson(name: 'Research Crew')))
  ..on('groups.log', page([event(1, 'message.user', text: 'Kickoff')]));

void main() {
  testWidgets('group chats list on Home and open their room', (tester) async {
    final gateway = await pumpHome(tester, _groupsHost());
    expect(find.text('Hermes'), findsWidgets);
    expect(find.text('Research Crew'), findsOneWidget);
    expect(find.text('Hermes, Atlas'), findsOneWidget);

    await tester.tap(find.text('Research Crew'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Kickoff'), findsOneWidget);
    expect(gateway.calls, containsAll(['groups.state', 'groups.log']));
  });

  testWidgets('Filters › Include › Group chats hides the rooms', (
    tester,
  ) async {
    await pumpHome(tester, _groupsHost());
    await tester.tap(find.bySemanticsLabel('Filters'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.tap(find.text('Include'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Group chats'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tapAt(const Offset(20, 700)); // dismiss
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('Research Crew'), findsNothing);
    expect(find.text('Hermes'), findsWidgets);
  });

  testWidgets('a host without groups still lists bots', (tester) async {
    await pumpHome(tester, FakeGroupsHost());
    expect(find.text('Atlas'), findsOneWidget);
    expect(find.text('Research Crew'), findsNothing);
  });
}
