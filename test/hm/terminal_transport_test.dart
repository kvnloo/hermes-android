import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/features/terminal/terminal_transport.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';

/// A loopback stand-in for Hermes's `/api/host-terminal`.
class _Host {
  late HttpServer server;
  final dials = <Uri>[];
  final received = <String>[];
  final sockets = <WebSocket>[];
  late Future<void> Function(WebSocket ws, Uri uri) onDial;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      dials.add(req.uri);
      final ws = await WebSocketTransformer.upgrade(req);
      sockets.add(ws);
      ws.listen((m) => received.add(m is String ? m : utf8.decode(m)));
      await onDial(ws, req.uri);
    });
  }

  String get base => 'http://127.0.0.1:${server.port}';
}

String _meta(Map<String, Object?> m) => '$hmTerminalMetaPrefix${jsonEncode(m)}';

void main() {
  late _Host host;
  final requests = <String>[];
  var mintStatus = 200;
  var sessionBody = '{"id":"s1","cwd":"/srv/app"}';
  var sessionStatus = 200;

  Future<http.Response> request(
    String method,
    String endpoint, {
    Map<String, String>? queryParameters,
  }) async {
    final q = queryParameters == null || queryParameters.isEmpty
        ? ''
        : '?${Uri(queryParameters: queryParameters).query}';
    requests.add('$method $endpoint$q');
    if (endpoint == 'webapp/socket-ticket') {
      return http.Response(
        mintStatus == 200 ? '{"ticket":"t-${requests.length}"}' : '{}',
        mintStatus,
      );
    }
    return http.Response(sessionBody, sessionStatus);
  }

  HostTerminalBackend backend({String? cwd, String? stored = 's1'}) =>
      HostTerminalBackend(
        baseUrl: host.base,
        request: request,
        connect: (uri) => IOWebSocketChannel.connect(uri),
        profile: 'work',
        storedSessionId: stored,
        requestedCwd: cwd,
        openTimeout: const Duration(seconds: 5),
      );

  setUp(() async {
    HostTerminalBackend.forgetAttachments();
    requests.clear();
    mintStatus = 200;
    sessionStatus = 200;
    sessionBody = '{"id":"s1","cwd":"/srv/app"}';
    host = _Host();
    await host.start();
  });

  tearDown(() => host.server.close(force: true));

  group('workingDirectory', () {
    test('reads the stored session row for this profile', () async {
      expect(await backend().workingDirectory(), '/srv/app');
      expect(requests, ['GET sessions/s1?profile=work']);
    });

    test('a cwd the chat was created with wins without a request', () async {
      expect(await backend(cwd: '/tmp/x').workingDirectory(), '/tmp/x');
      expect(requests, isEmpty);
    });

    test('unknown when the chat is not stored or has no cwd', () async {
      expect(await backend(stored: null).workingDirectory(), isNull);
      sessionStatus = 404;
      expect(await backend().workingDirectory(), isNull);
      sessionStatus = 200;
      sessionBody = '{"id":"s1","cwd":""}';
      expect(await backend().workingDirectory(), isNull);
    });

    test('a host error is a failure with its message', () async {
      sessionStatus = 500;
      sessionBody = '{"detail":"database locked"}';
      await expectLater(
        backend().workingDirectory(),
        throwsA(
          isA<HmTerminalFailure>().having(
            (e) => e.message,
            'message',
            'database locked',
          ),
        ),
      );
    });
  });

  test('a host that mints no host-terminal ticket is unavailable', () async {
    mintStatus = 404;
    await expectLater(
      backend().open(cwd: '/srv/app', cols: 80, rows: 24),
      throwsA(isA<HmTerminalUnavailable>()),
    );
    expect(requests.single, 'POST webapp/socket-ticket?socket=host-terminal');
    expect(host.dials, isEmpty);
  });

  test('opens a shell, streams output, sends keys and resizes', () async {
    host.onDial = (ws, uri) async {
      ws.add(
        _meta({'shell': 'zsh', 'terminalId': 'term-1', 'cwd': '/srv/app'}),
      );
      final bytes = utf8.encode('ok ✓\r\n');
      // Split inside the multi-byte check mark.
      ws.add(bytes.sublist(0, 5));
      ws.add(bytes.sublist(5));
    };
    final session = await backend().open(cwd: '/srv/app', cols: 100, rows: 30);
    expect(session.meta.shell, 'zsh');
    expect(session.meta.cwd, '/srv/app');

    final dial = host.dials.single;
    expect(dial.path, '/api/host-terminal');
    expect(dial.queryParameters, {
      'ticket': 't-1',
      'cwd': '/srv/app',
      'cols': '100',
      'rows': '30',
      'profile': 'work',
    });

    final text = StringBuffer();
    final sub = session.output.listen(text.write);
    await _until(() => text.toString().contains('\n'));
    expect(text.toString(), 'ok ✓\r\n');

    session.write('ls\r');
    session.resize(120, 40);
    await _until(() => host.received.length >= 2);
    expect(host.received, ['ls\r', '\x1b[RESIZE:120;40]']);

    await host.sockets.single.close(hmTerminalClosedCode, 'Process exited');
    final end = await session.done;
    expect(end.shellClosed, isTrue);
    await sub.cancel();
  });

  test('a start-up failure before the meta frame is shown', () async {
    host.onDial = (ws, uri) async {
      ws.add('\r\n\x1b[31mTerminal could not start: no shell\x1b[0m\r\n');
      await ws.close(1011);
    };
    await expectLater(
      backend().open(cwd: '/srv/app', cols: 80, rows: 24),
      throwsA(
        isA<HmTerminalFailure>().having(
          (e) => e.message,
          'message',
          'Terminal could not start: no shell',
        ),
      ),
    );
  });

  test('reopening reattaches; an expired shell starts a fresh one', () async {
    var n = 0;
    host.onDial = (ws, uri) async {
      n++;
      if (uri.queryParameters['attach'] != null && n == 3) {
        await ws.close(hmTerminalClosedCode, 'Terminal or profile expired');
        return;
      }
      // A reattach reports the same terminal, as the host does.
      final id = uri.queryParameters['attach'] ?? 'term-$n';
      ws.add(_meta({'terminalId': id, 'cwd': '/srv/app'}));
    };
    final b = backend();
    final first = await b.open(cwd: '/srv/app', cols: 80, rows: 24);
    await first.close();
    final second = await b.open(cwd: '/srv/app', cols: 80, rows: 24);
    expect(host.dials[1].queryParameters['attach'], 'term-1');
    await second.close();
    final third = await b.open(cwd: '/srv/app', cols: 80, rows: 24);
    expect(host.dials[2].queryParameters['attach'], 'term-1');
    expect(host.dials[3].queryParameters.containsKey('attach'), isFalse);
    expect(third.meta.terminalId, 'term-4');
    await third.close();
  });
}

Future<void> _until(bool Function() ok) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ok()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
