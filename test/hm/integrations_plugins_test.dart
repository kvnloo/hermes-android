import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/features/integrations/hm_plugins.dart';
import 'package:hermes_android/hm/features/integrations/integrations_api.dart';

import 'integrations_fakes.dart';

Map<String, dynamic> _plugin(
  String name, {
  String status = 'enabled',
  bool auth = false,
  bool removable = false,
}) => {
  'name': name,
  'version': '1.0.0',
  'description': '$name does things.',
  'source': removable ? 'git' : 'bundled',
  'runtime_status': status,
  'auth_required': auth,
  'auth_command': auth ? 'hermes auth $name' : '',
  'can_remove': removable,
  'can_update_git': false,
};

FakeTransport _host(List<Map<String, dynamic>> plugins) {
  final t = FakeTransport();
  t.rests['GET dashboard/plugins/hub'] = (_) => {
    'plugins': plugins,
    'orphan_dashboard_plugins': <Object>[],
    'providers': <String, Object>{},
  };
  return t;
}

void main() {
  testWidgets('lists installed plugins with counts, badge and meta', (
    tester,
  ) async {
    final t = _host([
      _plugin('a2a-platform', auth: true),
      _plugin('basic'),
      _plugin('buzz-platform', status: 'inactive'),
    ]);
    await pumpPage(tester, HmPluginsPage(api: HmIntegrationsApi(t, profile: 'atlas')));

    expect(find.text('Plugins'), findsOneWidget);
    expect(find.text('Installed'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('2 enabled'), findsOneWidget);
    expect(find.text('SETUP NEEDED'), findsOneWidget);
    expect(find.text('1.0.0 · bundled'), findsNWidgets(3));
    expect(t.named('GET dashboard/plugins/hub').single.query, {'profile': 'atlas'});
  });

  testWidgets('empty host shows No plugins installed', (tester) async {
    await pumpPage(tester, HmPluginsPage(api: HmIntegrationsApi(_host([]))));
    expect(find.text('No plugins installed'), findsOneWidget);
    expect(
      find.text(
        'Install a Hermes Agent plugin or one from a Git repository with the plus button.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('unreachable host shows Plugins unavailable; Try Again reloads', (
    tester,
  ) async {
    final t = FakeTransport();
    t.rests['GET dashboard/plugins/hub'] = (_) => failWith(500);
    await pumpPage(tester, HmPluginsPage(api: HmIntegrationsApi(t)));
    expect(find.text('Plugins unavailable'), findsOneWidget);
    expect(
      find.text(
        'Plugins could not be reached. Check your server connection and try again.',
      ),
      findsOneWidget,
    );
    t.rests['GET dashboard/plugins/hub'] = (_) => {
      'plugins': [_plugin('basic')],
    };
    await tester.tap(find.text('Try Again'));
    await tester.pumpAndSettle();
    expect(find.text('basic'), findsOneWidget);
  });

  testWidgets('forbidden host says permission was denied', (tester) async {
    final t = FakeTransport();
    t.rests['GET dashboard/plugins/hub'] = (_) => failWith(403);
    await pumpPage(tester, HmPluginsPage(api: HmIntegrationsApi(t)));
    expect(
      find.text(
        'Hermes denied permission to manage plugins. Check server access settings.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('switch disables a plugin', (tester) async {
    final t = _host([_plugin('basic')]);
    t.rests['POST dashboard/agent-plugins/basic/disable'] = (_) => {'ok': true};
    await pumpPage(tester, HmPluginsPage(api: HmIntegrationsApi(t, profile: 'atlas')));

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(t.named('POST dashboard/agent-plugins/basic/disable'), hasLength(1));
    expect(find.text('0 enabled'), findsOneWidget);
  });

  testWidgets('a refused toggle keeps the switch and shows why', (tester) async {
    final t = _host([_plugin('basic')]);
    t.rests['POST dashboard/agent-plugins/basic/disable'] = (_) =>
        failWith(400, 'Disable failed.');
    await pumpPage(tester, HmPluginsPage(api: HmIntegrationsApi(t)));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('Disable failed.'), findsOneWidget);
    expect(find.text('1 enabled'), findsOneWidget);
  });

  testWidgets('Enable All confirms, then enables each disabled plugin', (
    tester,
  ) async {
    final t = _host([
      _plugin('a', status: 'disabled'),
      _plugin('b'),
      _plugin('c', status: 'inactive'),
    ]);
    t.rests['POST dashboard/agent-plugins/a/enable'] = (_) => {'ok': true};
    t.rests['POST dashboard/agent-plugins/c/enable'] = (_) => {'ok': true};
    await pumpPage(tester, HmPluginsPage(api: HmIntegrationsApi(t)));

    await tester.tap(find.text('Installed'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enable All'));
    await tester.pumpAndSettle();
    expect(find.text('Enable installed plugins?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Enable All'));
    await tester.pumpAndSettle();

    expect(t.named('POST dashboard/agent-plugins/a/enable'), hasLength(1));
    expect(t.named('POST dashboard/agent-plugins/c/enable'), hasLength(1));
    expect(t.sent.where((r) => r.name.contains('/b/')), isEmpty);
    expect(find.text('3 enabled'), findsOneWidget);
  });

  testWidgets('details: Remove asks first, then deletes the plugin', (
    tester,
  ) async {
    var rows = [_plugin('my-tool', removable: true, auth: true)];
    final t = FakeTransport();
    t.rests['GET dashboard/plugins/hub'] = (_) => {'plugins': rows};
    t.rests['DELETE dashboard/agent-plugins/my-tool'] = (_) {
      rows = [];
      return {'ok': true};
    };
    await pumpPage(tester, HmPluginsPage(api: HmIntegrationsApi(t)));

    await tester.tap(find.text('my-tool'));
    await tester.pumpAndSettle();
    expect(find.text('Plugin Details'), findsOneWidget);
    expect(
      find.text('This plugin needs authentication before it can work.'),
      findsOneWidget,
    );
    expect(find.text('hermes auth my-tool'), findsOneWidget);

    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Remove this plugin?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(t.named('DELETE dashboard/agent-plugins/my-tool'), hasLength(1));
    expect(find.text('No plugins installed'), findsOneWidget);
  });

  testWidgets('Install Plugin sends the identifier and reloads', (tester) async {
    var rows = <Map<String, dynamic>>[];
    final t = FakeTransport();
    t.rests['GET dashboard/plugins/hub'] = (_) => {'plugins': rows};
    t.rests['POST dashboard/agent-plugins/install'] = (_) {
      rows = [_plugin('fresh')];
      return {'ok': true, 'plugin_name': 'fresh'};
    };
    await pumpPage(tester, HmPluginsPage(api: HmIntegrationsApi(t)));

    await tester.tap(find.bySemanticsLabel('Install Plugin'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'someone/fresh');
    await tester.pump();
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();

    final req = t.named('POST dashboard/agent-plugins/install').single;
    expect((req.body as Map)['identifier'], 'someone/fresh');
    expect(
      find.text(
        'Plugin installed. Restart the Hermes dashboard and agent gateways, then Check Setup.',
      ),
      findsOneWidget,
    );
    expect(find.text('fresh'), findsOneWidget);
  });

  testWidgets('a failed install stays on the page with the reason', (
    tester,
  ) async {
    final t = _host([]);
    t.rests['POST dashboard/agent-plugins/install'] = (_) =>
        failWith(400, 'Install failed.');
    await pumpPage(tester, HmPluginsPage(api: HmIntegrationsApi(t)));
    await tester.tap(find.bySemanticsLabel('Install Plugin'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'bad/repo');
    await tester.pump();
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(find.text('Install failed.'), findsOneWidget);
    expect(find.text('Install Plugin'), findsOneWidget);
  });
}
