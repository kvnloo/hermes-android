import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/features/integrations/hm_connections.dart';
import 'package:hermes_android/hm/features/integrations/integrations_api.dart';

import 'integrations_fakes.dart';

const _catalog = {
  'connectors': [
    {
      'slug': 'shopify',
      'name': 'Shopify',
      'description': 'Manage products, orders, and customers',
      'category': 'Commerce',
    },
    {
      'slug': 'stripe',
      'name': 'Stripe',
      'description': 'Read and manage customers, products, and payments',
      'category': 'Commerce',
    },
    {
      'slug': 'resend',
      'name': 'Resend',
      'description': 'Send and manage transactional email',
      'category': 'Communication',
    },
  ],
};

FakeTransport _host({
  bool available = true,
  Map<String, dynamic> catalog = _catalog,
  List<Map<String, dynamic>> accounts = const [],
}) {
  final t = FakeTransport();
  t.rpcs['connectors.list'] = (_) => {
    'available': available,
    'connectors': [
      {
        'connector': 'shopify',
        'enabled': true,
        'connected': true,
        'connection_status': 'active',
        'status_reason': null,
        'gateway_disabled_tools': <String>[],
      },
    ],
  };
  t.rpcs['connectors.catalog'] = (_) => catalog;
  t.rpcs['connectors.accounts'] = (_) => {'accounts': accounts};
  return t;
}

const _account = {
  'connection_id': 'conn-1',
  'connector': 'shopify',
  'status': 'active',
  'label': 'my-shop.myshopify.com',
  'active': true,
  'created_at': '2026-11-01T00:00:00Z',
  'updated_at': '2026-11-01T00:00:00Z',
};

void main() {
  testWidgets('lists services by category with their state, scoped to the bot', (
    tester,
  ) async {
    final t = _host(accounts: [_account]);
    await pumpPage(
      tester,
      HmConnectionsPage(api: HmIntegrationsApi(t, profile: 'atlas')),
    );

    expect(find.text('Connections'), findsOneWidget);
    expect(find.text('Search services'), findsWidgets);
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Commerce'), findsNWidgets(2)); // chip + heading
    expect(find.text('Shopify'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.bySemanticsLabel('Connect Stripe'), findsOneWidget);
    expect(find.text('Show connected accounts'), findsOneWidget);

    final list = t.named('connectors.list').single.params;
    expect(list['profile'], 'atlas');
    expect(list['owner'], {'type': 'account'});
    expect(t.named('connectors.catalog').single.params['profile'], 'atlas');
  });

  testWidgets('search and category chips filter the services', (tester) async {
    await pumpPage(tester, HmConnectionsPage(api: HmIntegrationsApi(_host())));

    await tester.enterText(find.byType(TextField), 'strip');
    await tester.pumpAndSettle();
    expect(find.text('Stripe'), findsOneWidget);
    expect(find.text('Shopify'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No matching services'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('Communication').first);
    await tester.pumpAndSettle();
    expect(find.text('Resend'), findsOneWidget);
    expect(find.text('Stripe'), findsNothing);
  });

  testWidgets('host without Nous sign-in shows the unavailable state', (
    tester,
  ) async {
    await pumpPage(
      tester,
      HmConnectionsPage(api: HmIntegrationsApi(_host(available: false))),
    );
    expect(find.text('No services available'), findsOneWidget);
    expect(
      find.text(
        'Sign in to Nous on this Hermes instance, then refresh to see available services.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('empty catalog shows the empty state', (tester) async {
    await pumpPage(
      tester,
      HmConnectionsPage(
        api: HmIntegrationsApi(_host(catalog: const {'connectors': []})),
      ),
    );
    expect(find.text('No services available'), findsOneWidget);
    expect(
      find.text('Services available to your Nous account will appear here.'),
      findsOneWidget,
    );
  });

  testWidgets('older host without connectors says to update', (tester) async {
    final t = FakeTransport(); // every method answers "method not found"
    await pumpPage(tester, HmConnectionsPage(api: HmIntegrationsApi(t)));
    expect(find.text('Update Hermes to connect accounts'), findsOneWidget);
  });

  testWidgets('gateway failure shows an error with Try Again', (tester) async {
    final t = _host();
    t.rpcs['connectors.list'] = (_) => throw const HmIntegrationsError(
      HmFailure.unavailable,
      'Connectors are not available.',
      reason: 'CONNECTORS_UNAVAILABLE',
    );
    await pumpPage(tester, HmConnectionsPage(api: HmIntegrationsApi(t)));
    expect(
      find.text(
        'Make sure this Hermes instance is signed in to Nous and connectors are enabled for the account, then refresh.',
      ),
      findsOneWidget,
    );
    expect(find.text('Try Again'), findsOneWidget);
  });

  testWidgets('Connect opens sign-in; returning to the app settles the row', (
    tester,
  ) async {
    final t = _host();
    t.rpcs['connectors.connect'] = (_) => {
      'op_id': 'op-7',
      'seq': 1,
      'deadline_at': 0,
      'settled': false,
      'targets': [
        {
          'name': 'stripe',
          'kind': 'connector',
          'action': 'connect',
          'state': 'initiated',
          'connect_url': 'https://connect.example/stripe?x=1',
        },
      ],
    };
    t.rpcs['connectors.operation.wake'] = (_) => {'status': 'ok'};
    t.rpcs['connectors.operation.status'] = (_) => {
      'op_id': 'op-7',
      'seq': 2,
      'deadline_at': 0,
      'settled': true,
      'targets': [
        {
          'name': 'stripe',
          'kind': 'connector',
          'action': 'connect',
          'state': 'connected',
        },
      ],
    };
    await pumpPage(
      tester,
      HmConnectionsPage(
        api: HmIntegrationsApi(t, profile: 'atlas'),
        pollEvery: const Duration(hours: 1),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Connect Stripe'));
    await tester.pump();
    await tester.pump();

    final connect = t.named('connectors.connect').single.params;
    expect(connect['connectors'], ['stripe']);
    expect(connect['owner'], {'type': 'account'});
    expect(connect['profile'], 'atlas');
    expect(t.opened.single.toString(), 'https://connect.example/stripe?x=1');
    expect(find.text('Waiting for sign-in…'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(t.named('connectors.operation.wake').single.params['op_id'], 'op-7');
    expect(find.text('Account connected.'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Waiting for sign-in…'), findsNothing);
  });

  testWidgets('Connect without a sign-in link says so', (tester) async {
    final t = _host();
    t.rpcs['connectors.connect'] = (_) => {
      'op_id': 'op-8',
      'settled': false,
      'targets': [
        {'name': 'stripe', 'state': 'pending'},
      ],
    };
    await pumpPage(tester, HmConnectionsPage(api: HmIntegrationsApi(t)));
    await tester.tap(find.bySemanticsLabel('Connect Stripe'));
    await tester.pump();
    await tester.pump();
    expect(find.text('The server did not return a sign-in link.'), findsOneWidget);
    expect(t.opened, isEmpty);
  });

  testWidgets('touch and hold an account, confirm, and it disconnects', (
    tester,
  ) async {
    final t = _host(accounts: [_account]);
    var accounts = [_account];
    t.rpcs['connectors.accounts'] = (_) => {'accounts': accounts};
    t.rpcs['connectors.accounts.remove'] = (p) {
      accounts = [];
      return {
        'connection_id': p['connection_id'],
        'connector': 'shopify',
        'status': 'removed',
      };
    };
    await pumpPage(
      tester,
      HmConnectionsPage(api: HmIntegrationsApi(t, profile: 'atlas')),
    );
    await tester.tap(find.text('Show connected accounts'));
    await tester.pumpAndSettle();

    expect(find.text('Connected Accounts'), findsOneWidget);
    expect(find.text('my-shop.myshopify.com'), findsOneWidget);

    await tester.longPress(find.text('my-shop.myshopify.com'));
    await tester.pumpAndSettle();
    expect(find.text('Disconnect this account?'), findsOneWidget);

    // Cancel sends nothing.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(t.named('connectors.accounts.remove'), isEmpty);

    await tester.longPress(find.text('my-shop.myshopify.com'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();

    final remove = t.named('connectors.accounts.remove').single.params;
    expect(remove['connection_id'], 'conn-1');
    expect(remove['profile'], 'atlas');
    expect(find.text('Account disconnected.'), findsOneWidget);
    expect(find.text('No connected services'), findsOneWidget);
  });
}
