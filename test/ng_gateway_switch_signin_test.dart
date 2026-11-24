// A gateway switch must not show "Your sign-in expired." for a host whose
// sign-in is fine. Right after a switch Home loads the new host's bots over
// the same dashboard client the socket mints its ticket with; when the
// host's access token has lapsed both requests are rejected at once and one
// of them renews it. The other must wait for that renewal instead of
// re-sending the lapsed token and reporting the sign-in as expired.
//
// Real loopback HTTP + WebSocket traffic, so it uses plain `test` (see
// ws_keepalive_test.dart).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/hermes_sign_in.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';

void main() {
  setUp(() => HermesSignInVault.resetForTesting());

  test('switching from signed-in host A to signed-in host B never reports an '
      'expired sign-in', () async {
    final a = await _FakeHost.start(validToken: 'A-live');
    final b = await _FakeHost.start(
      validToken: 'B-live',
      renewTo: 'B-live',
      renewDelay: const Duration(milliseconds: 300),
    );
    addTearDown(a.stop);
    addTearDown(b.stop);
    await HermesSignInVault.instance.setSession(
      a.baseUrl,
      const NativeSession(accessToken: 'A-live', refreshToken: 'A-r'),
    );
    // B was signed in earlier; its access token lapsed while A was in use.
    await HermesSignInVault.instance.setSession(
      b.baseUrl,
      const NativeSession(accessToken: 'B-lapsed', refreshToken: 'B-r'),
    );

    final gatewayA = NextGenGateway(a.connection('a'))..start();
    await _waitFor(() => gatewayA.state.isConnected);

    // Switch: NextGenHome builds and starts B's gateway, then disposes A's;
    // Home immediately loads B's bots on B's dashboard client.
    final gatewayB = NextGenGateway(b.connection('b'));
    addTearDown(gatewayB.dispose);
    final phases = <NgConnectionPhase>[];
    gatewayB.addListener(() => phases.add(gatewayB.state.phase));
    gatewayB.start();
    gatewayA.dispose();
    final profiles = gatewayB.dashboard.apiRequest('GET', 'profiles');

    expect((await profiles).statusCode, 200);
    await _waitFor(
      () =>
          gatewayB.state.isConnected ||
          gatewayB.state.phase == NgConnectionPhase.sessionExpired,
    );
    expect(phases, isNot(contains(NgConnectionPhase.sessionExpired)));
    expect(gatewayB.state.phase, NgConnectionPhase.connected);
    expect(b.renewals, 1);
  });

  test('requests rejected together with a lapsed token share one renewal '
      'and both succeed', () async {
    final b = await _FakeHost.start(
      validToken: 'B-live',
      renewTo: 'B-live',
      renewDelay: const Duration(milliseconds: 300),
    );
    addTearDown(b.stop);
    await HermesSignInVault.instance.setSession(
      b.baseUrl,
      const NativeSession(accessToken: 'B-lapsed', refreshToken: 'B-r'),
    );
    final dashboard = DashboardClient.fromConnection(b.connection('b'));
    addTearDown(dashboard.close);

    final results = await Future.wait([
      dashboard.apiRequest('GET', 'profiles'),
      dashboard.apiRequest('POST', 'auth/ws-ticket'),
      dashboard.apiRequest('GET', 'auth/me'),
    ]);

    expect([for (final r in results) r.statusCode], [200, 200, 200]);
    expect(b.renewals, 1);
  });

  test('host B turning the sign-in down still reports it expired', () async {
    final b = await _FakeHost.start(validToken: 'B-live');
    addTearDown(b.stop);
    await HermesSignInVault.instance.setSession(
      b.baseUrl,
      const NativeSession(accessToken: 'B-revoked', refreshToken: 'B-r'),
    );

    final gatewayB = NextGenGateway(b.connection('b'))..start();
    addTearDown(gatewayB.dispose);
    await _waitFor(
      () => gatewayB.state.phase == NgConnectionPhase.sessionExpired,
    );
    expect(gatewayB.state.phase, NgConnectionPhase.sessionExpired);
    expect(b.wsOpened, 0);
  });
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A browser-sign-in gateway: `/api/*` takes only `Bearer <validToken>`;
/// `/auth/native/refresh` renews to [renewTo] after [renewDelay], or turns
/// the refresh down (401) when [renewTo] is null.
class _FakeHost {
  _FakeHost(this._server, this.validToken, this.renewTo, this.renewDelay);

  final HttpServer _server;
  final String validToken;
  final String? renewTo;
  final Duration renewDelay;
  final List<WebSocket> _sockets = [];
  int renewals = 0;
  int wsOpened = 0;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  SavedConnection connection(String id) => SavedConnection(
    id: id,
    label: id,
    host: 'localhost',
    port: _server.port,
    apiKey: '',
    desktopGatewayUrl: baseUrl,
    singleLogin: true,
    signInMethod: 'browser',
  );

  static Future<_FakeHost> start({
    required String validToken,
    String? renewTo,
    Duration renewDelay = Duration.zero,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _FakeHost(server, validToken, renewTo, renewDelay);
    server.listen(host._handle);
    return host;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final path = req.uri.path;
    if (path == '/auth/native/refresh') {
      renewals++;
      await Future<void>.delayed(renewDelay);
      final next = renewTo;
      if (next == null) {
        res.statusCode = 401;
      } else {
        res.headers.contentType = ContentType.json;
        res.write(
          jsonEncode({'access_token': next, 'refresh_token': '$next-r'}),
        );
      }
      await res.close();
      return;
    }
    if (path == '/api/ws') {
      final socket = await WebSocketTransformer.upgrade(req);
      wsOpened++;
      _sockets.add(socket);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {'type': 'gateway.ready', 'payload': {}},
        }),
      );
      socket.listen((_) {});
      return;
    }
    if (path.startsWith('/api/')) {
      if (req.headers.value('authorization') != 'Bearer $validToken') {
        res.statusCode = 401;
        res.write('{"detail":"Not authenticated"}');
        await res.close();
        return;
      }
      res.headers.contentType = ContentType.json;
      res.write(switch (path) {
        '/api/auth/ws-ticket' => '{"ticket":"ticket-${++_tickets}"}',
        '/api/auth/me' => '{"id":"u1","name":"Kevin"}',
        '/api/profiles' => '{"profiles":[]}',
        _ => '{}',
      });
      await res.close();
      return;
    }
    res.statusCode = 404;
    await res.close();
  }

  int _tickets = 0;

  Future<void> stop() async {
    for (final s in _sockets) {
      await s.close();
    }
    await _server.close(force: true);
  }
}
