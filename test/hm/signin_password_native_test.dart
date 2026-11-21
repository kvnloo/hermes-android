// Password sign-in against an HTTPS dashboard whose `/auth/password-login`
// answers 200 (audit `login_success`) but whose Set-Cookie carries only the
// provider hint, as measured on Studio behind Tailscale Serve. The fake host
// below answers every route with the shapes `hermes_cli/dashboard_auth`
// produces (routes.py `auth_native_authorize`, `auth_password_login`,
// `auth_native_token`; cookies.py names and attributes).
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/hermes_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _host = 'studio.example.ts.net';
const _base = 'https://$_host:9119';

/// Starlette's `set_cookie` line for an HTTPS, no-prefix request.
String _cookie(String bare, String value, int maxAge, {String same = 'lax'}) =>
    '__Host-$bare=$value; HttpOnly; Max-Age=$maxAge; Path=/; '
    'SameSite=$same; Secure';

/// Starlette's deletion line (`max_age=0` also writes `expires=`, whose comma
/// the `http` package's comma-joined header must survive).
String _cleared(String name, {String same = 'none'}) =>
    '$name=""; expires=Fri, 20 Nov 2026 00:00:00 GMT; HttpOnly; Max-Age=0; '
    'Path=/; SameSite=$same; Secure';

String _b64url(String s) =>
    base64Url.encode(utf8.encode(s)).replaceAll('=', '');

class _FakeHost {
  _FakeHost({
    this.password = 'right',
    this.nativeFlow = true,
    this.accessCookie = false,
  });

  final String password;
  final bool nativeFlow;

  /// Whether a plain password login's access cookie reaches the app.
  final bool accessCookie;

  final requests = <http.BaseRequest>[];
  final bodies = <String>[];
  String? _challenge;
  String? _clientState;
  String? _pkceValue;
  int tokensIssued = 0;
  int refreshes = 0;
  bool rejectRefresh = false;

  String get accessToken => 'native-at-$tokensIssued';

  List<String> get paths => [for (final r in requests) r.url.path];

  late final client = MockClient((request) async {
    requests.add(request);
    bodies.add(request.body);
    final path = request.url.path;
    if (path == '/auth/native/authorize') {
      if (!nativeFlow) return http.Response('{"detail":"Not Found"}', 404);
      _challenge = request.url.queryParameters['code_challenge'];
      _clientState = request.url.queryParameters['state'];
      _pkceValue = _b64url(
        jsonEncode({'broker': 'brk-1', 'provider': 'basic'}),
      );
      return http.Response(
        '',
        302,
        headers: {
          'location': '/login',
          'set-cookie': _cookie(
            'hermes_session_pkce',
            _pkceValue!,
            600,
            same: 'none',
          ),
        },
      );
    }
    if (path == '/auth/password-login') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['password'] != password) {
        return http.Response('{"detail":"Invalid credentials"}', 401);
      }
      final cookie = request.headers['Cookie'] ?? '';
      if (_pkceValue != null &&
          cookie == '__Host-hermes_session_pkce=$_pkceValue') {
        // Native broker: the loopback redirect, no session cookies.
        return http.Response(
          jsonEncode({
            'ok': true,
            'next':
                'http://127.0.0.1/callback?code=gw-code&state=$_clientState',
          }),
          200,
          headers: {
            'set-cookie': [
              _cleared('__Host-hermes_session_pkce'),
              _cleared('__Secure-hermes_session_pkce'),
              _cleared('hermes_session_pkce', same: 'none'),
            ].join(','),
          },
        );
      }
      return http.Response(
        '{"ok":true,"next":"/"}',
        200,
        headers: {
          'set-cookie': [
            if (accessCookie) _cookie('hermes_session_at', 'cookie-at', 3600),
            _cookie('hermes_session_provider', 'basic', 2592000),
          ].join(','),
        },
      );
    }
    if (path == '/auth/native/token') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final verifier = body['code_verifier'] as String;
      final challenge = base64Url
          .encode(sha256.convert(utf8.encode(verifier)).bytes)
          .replaceAll('=', '');
      if (body['code'] != 'gw-code' || challenge != _challenge) {
        return http.Response(
          '{"detail":"Invalid or expired authorization code."}',
          400,
        );
      }
      tokensIssued++;
      return http.Response(
        jsonEncode({
          'access_token': accessToken,
          'refresh_token': 'native-rt',
          'token_type': 'Bearer',
          'expires_at': 1900000000,
          'provider': 'basic',
          'user_id': 'kevin',
        }),
        200,
      );
    }
    if (path == '/auth/native/refresh') {
      refreshes++;
      return http.Response(
        '{"error":"session_expired","detail":"start a new sign-in."}',
        401,
      );
    }
    if (path == '/api/auth/me') {
      final auth = request.headers['Authorization'];
      final cookie = request.headers['Cookie'] ?? '';
      final ok =
          auth == 'Bearer $accessToken' ||
          cookie.contains('hermes_session_at=cookie-at');
      if (!ok || rejectRefresh) {
        rejectRefresh = false;
        return http.Response('{"detail":"Unauthorized"}', 401);
      }
      return http.Response('{"user_id":"kevin","provider":"basic"}', 200);
    }
    return http.Response('not found', 404);
  });

  DashboardClient dashboard() => DashboardClient(
    host: _host,
    port: 9119,
    useHttps: true,
    username: 'kevin',
    password: 'right',
    httpClient: client,
  );
}

void main() {
  setUp(() => HermesSignInVault.resetForTesting(MemorySignInSecretStore()));

  test('a password login whose access cookie never arrives signs in through '
      'the native broker and calls the API with its bearer', () async {
    final host = _FakeHost();
    final me = await host.dashboard().apiGet('auth/me');

    expect(me['user_id'], 'kevin');
    expect(host.paths, [
      '/auth/password-login',
      '/auth/native/authorize',
      '/auth/password-login',
      '/auth/native/token',
      '/api/auth/me',
    ]);
    final authorize = host.requests[1] as http.Request;
    expect(authorize.followRedirects, isFalse);
    expect(authorize.url.queryParameters, containsPair('provider', 'basic'));
    expect(
      authorize.url.queryParameters,
      containsPair('code_challenge_method', 'S256'),
    );
    expect(
      authorize.url.queryParameters['redirect_uri'],
      'http://127.0.0.1/callback',
    );
    expect(jsonDecode(host.bodies[2]), {
      'provider': 'basic',
      'username': 'kevin',
      'password': 'right',
    });
    expect(host.requests.last.headers['Authorization'], 'Bearer native-at-1');
    expect(host.requests.last.headers.containsKey('Cookie'), isFalse);
    expect(
      HermesSignInVault.instance.sessionFor(_base)?.refreshToken,
      'native-rt',
    );
  });

  test(
    'later calls reuse the brokered bearer without signing in again',
    () async {
      final host = _FakeHost();
      final dashboard = host.dashboard();
      await dashboard.apiGet('auth/me');
      await dashboard.apiGet('auth/me');

      expect(host.paths.where((p) => p.startsWith('/auth/')), hasLength(4));
      expect(host.requests.last.headers['Authorization'], 'Bearer native-at-1');
    },
  );

  test('when the brokered tokens cannot be renewed, the saved password signs '
      'in again', () async {
    final host = _FakeHost();
    final dashboard = host.dashboard();
    await dashboard.apiGet('auth/me');
    host.rejectRefresh = true;

    final me = await dashboard.apiGet('auth/me');

    expect(me['user_id'], 'kevin');
    expect(host.refreshes, 1);
    expect(host.tokensIssued, 2);
    expect(host.requests.last.headers['Authorization'], 'Bearer native-at-2');
  });

  test('a wrong password is reported as one', () async {
    final host = _FakeHost(password: 'other');
    await expectLater(
      host.dashboard().apiGet('auth/me'),
      throwsA(predicate((e) => '$e'.contains('invalid username or password'))),
    );
    expect(host.paths, ['/auth/password-login']);
  });

  test('a host without the native flow keeps the cookie error', () async {
    final host = _FakeHost(nativeFlow: false);
    await expectLater(
      host.dashboard().apiGet('auth/me'),
      throwsA(predicate((e) => '$e'.contains('no session cookie found'))),
    );
    expect(host.paths, ['/auth/password-login', '/auth/native/authorize']);
    expect(HermesSignInVault.instance.sessionFor(_base), isNull);
  });

  test('a host whose access cookie arrives still uses the cookie', () async {
    final host = _FakeHost(accessCookie: true);
    final me = await host.dashboard().apiGet('auth/me');

    expect(me['user_id'], 'kevin');
    expect(host.paths, ['/auth/password-login', '/api/auth/me']);
    expect(
      host.requests.last.headers['Cookie'],
      '__Host-hermes_session_at=cookie-at',
    );
  });

  group('brokeredPasswordSignIn', () {
    test('returns the bearer tokens from /auth/native/token', () async {
      final host = _FakeHost();
      final session = await brokeredPasswordSignIn(
        host.client,
        '$_base/',
        username: 'kevin',
        password: 'right',
      );
      expect(session.accessToken, 'native-at-1');
      expect(session.provider, 'basic');
      expect(host.paths, [
        '/auth/native/authorize',
        '/auth/password-login',
        '/auth/native/token',
      ]);
    });

    test('a next without our state is refused', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/auth/native/authorize') {
          return http.Response(
            '',
            302,
            headers: {'set-cookie': _cookie('hermes_session_pkce', 'abc', 600)},
          );
        }
        return http.Response(
          '{"ok":true,"next":"http://127.0.0.1/callback?code=x&state=other"}',
          200,
        );
      });
      await expectLater(
        brokeredPasswordSignIn(
          client,
          _base,
          username: 'kevin',
          password: 'right',
        ),
        throwsA(
          isA<BrokeredSignInException>().having(
            (e) => e.failure,
            'failure',
            BrokeredSignInFailure.rejected,
          ),
        ),
      );
    });
  });
}
