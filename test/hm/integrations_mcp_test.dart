import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/features/integrations/hm_mcp.dart';
import 'package:hermes_android/hm/features/integrations/integrations_api.dart';

import 'integrations_fakes.dart';

Map<String, dynamic> _server(
  String name, {
  String? url,
  String? command,
  bool enabled = true,
  String? auth,
  String? plugin,
}) => {
  'name': name,
  'transport': url != null ? 'http' : 'stdio',
  'url': url,
  'command': command,
  'args': command != null ? ['-y', 'pkg'] : <String>[],
  'env': <String, String>{},
  'auth': auth,
  'enabled': enabled,
  'tools': null,
  'source': plugin != null ? 'plugin' : 'config',
  'plugin': plugin,
};

FakeTransport _host(List<Map<String, dynamic>> Function() servers) {
  final t = FakeTransport();
  t.rests['GET mcp/servers'] = (_) => {'servers': servers()};
  return t;
}

void main() {
  testWidgets('no servers shows the official empty state', (tester) async {
    final t = _host(() => []);
    await pumpPage(tester, HmMcpPage(api: HmIntegrationsApi(t, profile: 'atlas')));
    expect(find.text('MCP'), findsOneWidget);
    expect(find.text('No MCP servers'), findsOneWidget);
    expect(
      find.text('Install one from the catalog, or add your own with the plus button.'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Catalog'), findsOneWidget);
    expect(find.bySemanticsLabel('Add Server'), findsOneWidget);
    expect(t.named('GET mcp/servers').single.query, {'profile': 'atlas'});
  });

  testWidgets('load failures: unreachable and forbidden', (tester) async {
    final t = FakeTransport();
    t.rests['GET mcp/servers'] = (_) => failWith(500);
    await pumpPage(tester, HmMcpPage(api: HmIntegrationsApi(t)));
    expect(find.text('MCP unavailable'), findsOneWidget);
    expect(find.text('MCP servers could not be loaded.'), findsOneWidget);

    t.rests['GET mcp/servers'] = (_) => failWith(403);
    await tester.tap(find.text('Try Again'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Hermes denied permission to manage MCP servers. Check server access settings.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('lists servers and the switch disables one for this profile', (
    tester,
  ) async {
    final t = _host(
      () => [
        _server('docs', url: 'https://docs.example/mcp'),
        _server('fs', command: 'npx'),
      ],
    );
    t.rests['PUT mcp/servers/docs/enabled'] = (r) => {'ok': true};
    await pumpPage(tester, HmMcpPage(api: HmIntegrationsApi(t, profile: 'atlas')));

    expect(find.text('docs'), findsOneWidget);
    expect(find.text('https://docs.example/mcp'), findsOneWidget);
    expect(find.text('npx -y pkg'), findsOneWidget);

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    final put = t.named('PUT mcp/servers/docs/enabled').single;
    expect(put.body, {'enabled': false, 'profile': 'atlas'});
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);
  });

  testWidgets('a plugin-provided server cannot be toggled or removed', (
    tester,
  ) async {
    final t = _host(() => [_server('kb', url: 'https://kb/mcp', plugin: 'kb-plugin')]);
    await pumpPage(tester, HmMcpPage(api: HmIntegrationsApi(t)));
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    await tester.tap(find.text('kb'));
    await tester.pumpAndSettle();
    expect(find.text('Remove Server'), findsNothing);
  });

  testWidgets('details: Discover Tools tests the server and lists its tools', (
    tester,
  ) async {
    final t = _host(() => [_server('docs', url: 'https://docs.example/mcp')]);
    t.rests['POST mcp/servers/docs/test'] = (_) => {
      'ok': true,
      'tools': [
        {'name': 'search_docs', 'description': 'Search the docs'},
      ],
    };
    await pumpPage(tester, HmMcpPage(api: HmIntegrationsApi(t)));
    await tester.tap(find.text('docs'));
    await tester.pumpAndSettle();

    expect(find.text('Available Tools'), findsOneWidget);
    expect(
      find.text(
        'Not probed yet. Test connects, lists what it offers, and disconnects.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Discover Tools'));
    await tester.pumpAndSettle();
    expect(find.text('search_docs'), findsOneWidget);
    expect(find.text('Search the docs'), findsOneWidget);
  });

  testWidgets('details: a server with no tools and a failing one', (tester) async {
    final t = _host(() => [_server('docs', url: 'https://docs.example/mcp')]);
    t.rests['POST mcp/servers/docs/test'] = (_) => {'ok': true, 'tools': []};
    await pumpPage(tester, HmMcpPage(api: HmIntegrationsApi(t)));
    await tester.tap(find.text('docs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discover Tools'));
    await tester.pumpAndSettle();
    expect(find.text('Connected, and the server offers no tools.'), findsOneWidget);

    t.rests['POST mcp/servers/docs/test'] = (_) => {
      'ok': false,
      'error': 'OAuth authentication required — no token found.',
      'tools': [],
    };
    await tester.tap(find.text('Discover Tools'));
    await tester.pumpAndSettle();
    expect(
      find.text('OAuth authentication required — no token found.'),
      findsOneWidget,
    );
  });

  testWidgets('details: Remove Server confirms, deletes, and the list updates', (
    tester,
  ) async {
    var rows = [_server('fs', command: 'npx')];
    final t = _host(() => rows);
    t.rests['DELETE mcp/servers/fs'] = (_) {
      rows = [];
      return {'ok': true};
    };
    await pumpPage(tester, HmMcpPage(api: HmIntegrationsApi(t, profile: 'atlas')));
    await tester.tap(find.text('fs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove Server'));
    await tester.pumpAndSettle();
    expect(find.text('Remove this MCP server?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();

    final del = t.named('DELETE mcp/servers/fs').single;
    expect(del.query, {'profile': 'atlas'});
    expect(find.text('No MCP servers'), findsOneWidget);
  });

  testWidgets('details: Sign In With OAuth opens the browser and polls the flow', (
    tester,
  ) async {
    final t = _host(
      () => [_server('linear', url: 'https://mcp.linear.app/sse', auth: 'oauth')],
    );
    t.rests['POST mcp/servers/linear/auth'] = (_) => {
      'flow_id': 'f1',
      'server_name': 'linear',
      'status': 'authorization_required',
      'authorization_url': 'https://linear.app/oauth/authorize?x=1',
      'error': null,
    };
    var polls = 0;
    t.rests['GET mcp/oauth/flows/f1'] = (_) {
      polls++;
      return {
        'flow_id': 'f1',
        'status': polls < 2 ? 'authorization_required' : 'approved',
        'authorization_url': 'https://linear.app/oauth/authorize?x=1',
        'error': null,
        'tools': ['list_issues'],
      };
    };
    t.rests['POST mcp/servers/linear/test'] = (_) => {
      'ok': true,
      'tools': [
        {'name': 'list_issues', 'description': ''},
      ],
    };
    await pumpPage(tester, HmMcpPage(api: HmIntegrationsApi(t)));
    await tester.tap(find.text('linear'));
    await tester.pumpAndSettle();

    final page = tester.widget<HmMcpServerPage>(find.byType(HmMcpServerPage));
    expect(page.server.canOAuth, isTrue);
    await tester.tap(find.text('Sign In With OAuth'));
    await tester.pump();
    await tester.pump();
    expect(t.opened.single.toString(), 'https://linear.app/oauth/authorize?x=1');
    expect(find.text('Waiting for sign-in…'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('Connection established'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('list_issues'), findsOneWidget);
    expect(t.sent.where((r) => r.kind == 'DELETE'), isEmpty);
  });

  testWidgets('catalog installs an entry with its required keys', (tester) async {
    var installed = false;
    final t = _host(() => installed ? [_server('brave', command: 'npx')] : []);
    t.rests['GET mcp/catalog'] = (_) => {
      'entries': [
        {
          'name': 'brave',
          'description': 'Web search',
          'transport': 'stdio',
          'command': 'npx',
          'args': ['-y', 'brave'],
          'required_env': [
            {'name': 'BRAVE_API_KEY', 'prompt': 'Brave API key', 'required': true},
          ],
          'installed': installed,
          'enabled': installed,
        },
      ],
      'diagnostics': [],
    };
    t.rests['POST mcp/catalog/install'] = (_) {
      installed = true;
      return {'ok': true, 'name': 'brave', 'background': false};
    };
    await pumpPage(tester, HmMcpPage(api: HmIntegrationsApi(t, profile: 'atlas')));
    await tester.tap(find.bySemanticsLabel('Catalog'));
    await tester.pumpAndSettle();

    expect(find.text('Official Catalog'), findsOneWidget);
    expect(
      find.text('Browse Nous-approved MCP servers and install them with one tap.'),
      findsOneWidget,
    );
    await tester.tap(find.bySemanticsLabel('Install brave'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        "This server needs the following before it will run. They are written to this profile's .env.",
      ),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), 'k-123');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Install'));
    await tester.pumpAndSettle();

    final req = t.named('POST mcp/catalog/install').single;
    expect(req.body, {
      'name': 'brave',
      'env': {'BRAVE_API_KEY': 'k-123'},
      'enable': true,
      'profile': 'atlas',
    });
    expect(find.text('MCP server added'), findsOneWidget);
    expect(find.text('Installed'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('brave'), findsOneWidget);
  });

  testWidgets('catalog empty and unavailable states', (tester) async {
    final t = _host(() => []);
    t.rests['GET mcp/catalog'] = (_) => {'entries': [], 'diagnostics': []};
    await pumpPage(tester, HmMcpPage(api: HmIntegrationsApi(t)));
    await tester.tap(find.bySemanticsLabel('Catalog'));
    await tester.pumpAndSettle();
    expect(find.text('This install ships no MCP catalog.'), findsOneWidget);

    t.rests['GET mcp/catalog'] = (_) => failWith(500, 'Catalog unavailable');
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Catalog'));
    await tester.pumpAndSettle();
    expect(find.text('MCP catalog unavailable'), findsOneWidget);
  });

  testWidgets('Add Server posts a URL server and returns to the list', (
    tester,
  ) async {
    var rows = <Map<String, dynamic>>[];
    final t = _host(() => rows);
    t.rests['POST mcp/servers'] = (r) {
      rows = [_server('notes', url: 'https://notes.example/mcp')];
      return rows.first;
    };
    await pumpPage(tester, HmMcpPage(api: HmIntegrationsApi(t, profile: 'atlas')));
    await tester.tap(find.bySemanticsLabel('Add Server'));
    await tester.pumpAndSettle();
    expect(find.text('Add MCP Server'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'notes');
    await tester.enterText(
      find.widgetWithText(TextField, 'URL'),
      'https://notes.example/mcp',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Add Server'));
    await tester.pumpAndSettle();

    expect(t.named('POST mcp/servers').single.body, {
      'name': 'notes',
      'url': 'https://notes.example/mcp',
      'profile': 'atlas',
    });
    expect(find.text('MCP server added'), findsOneWidget);
    expect(find.text('notes'), findsOneWidget);
  });

  testWidgets('Add Server shows the host refusal', (tester) async {
    final t = _host(() => []);
    t.rests['POST mcp/servers'] = (_) => failWith(409, "Server 'x' already exists");
    await pumpPage(tester, HmMcpPage(api: HmIntegrationsApi(t)));
    await tester.tap(find.bySemanticsLabel('Add Server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Command'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'x');
    await tester.enterText(find.widgetWithText(TextField, 'Command'), 'uvx');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Add Server'));
    await tester.pumpAndSettle();
    expect(find.text("Server 'x' already exists"), findsOneWidget);
    expect((t.named('POST mcp/servers').single.body as Map)['command'], 'uvx');
  });
}
