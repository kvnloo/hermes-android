// Terminal from a stored chat: the folder comes from the attached session's
// info, then the host's session row; with neither, the shell opens in the
// home folder (as the official app does) instead of stopping at
// "Connect or refresh this chat…".
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/features/terminal/hm_terminal.dart';
import 'package:hermes_android/hm/features/terminal/ssh_config.dart';
import 'package:hermes_android/hm/features/terminal/ssh_transport.dart';
import 'package:hermes_android/hm/features/terminal/terminal_page.dart';
import 'package:hermes_android/hm/features/terminal/terminal_transport.dart';
import 'package:http/http.dart' as http;
import 'package:xterm/xterm.dart';

import 'terminal-ssh_fakes.dart';

class _Session implements HmTerminalSession {
  _Session(this.cwd);
  final String cwd;
  final _out = StreamController<String>();

  @override
  HmTerminalMeta get meta => HmTerminalMeta(shell: 'zsh', cwd: cwd);
  @override
  Stream<String> get output => _out.stream;
  @override
  Future<HmTerminalEnd> get done => Completer<HmTerminalEnd>().future;
  @override
  void write(String data) {}
  @override
  void resize(int cols, int rows) {}
  @override
  Future<void> close() async {}
}

/// A backend that knows no folder (or fails to look one up).
class _Unknown implements HmTerminalBackend {
  _Unknown({this.fail = false});
  final bool fail;
  final openedIn = <String>[];

  @override
  Future<String?> workingDirectory() async {
    if (fail) throw const HmTerminalFailure('database locked');
    return null;
  }

  @override
  Future<HmTerminalSession> open({
    required String cwd,
    required int cols,
    required int rows,
  }) async {
    openedIn.add(cwd);
    return _Session('/Users/kevin');
  }
}

void main() {
  group('HostTerminalBackend.workingDirectory', () {
    final requests = <String>[];
    Future<http.Response> request(
      String method,
      String endpoint, {
      Map<String, String>? queryParameters,
    }) async {
      requests.add('$method $endpoint');
      return http.Response(jsonEncode({'id': 's1', 'cwd': null}), 200);
    }

    HostTerminalBackend host({String? live}) => HostTerminalBackend(
      baseUrl: 'http://10.0.0.5:9119',
      request: request,
      connect: (_) => throw UnimplementedError(),
      storedSessionId: 's1',
      liveCwd: () => live,
    );

    setUp(requests.clear);

    test('the attached session folder wins without a request', () async {
      expect(await host(live: '/srv/app').workingDirectory(), '/srv/app');
      expect(requests, isEmpty);
    });

    test('not attached yet: the host session row is asked', () async {
      expect(await host().workingDirectory(), isNull);
      expect(requests, ['GET sessions/s1']);
    });

    test('no folder: the socket asks for no cwd, so the host uses home', () {
      final uri = host().socketUri(ticket: 't', cwd: '', cols: 80, rows: 24);
      expect(uri.queryParameters.containsKey('cwd'), isFalse);
      final withCwd = host().socketUri(
        ticket: 't',
        cwd: '/srv/app',
        cols: 80,
        rows: 24,
      );
      expect(withCwd.queryParameters['cwd'], '/srv/app');
    });
  });

  group('Terminal page with no known folder', () {
    Future<void> pump(WidgetTester tester, HmTerminalBackend backend) async {
      await tester.pumpWidget(
        MaterialApp(
          home: HmTerminalPage(backend: HmHomeFallbackBackend(backend)),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('opens a shell in the home folder, not a dead end', (
      tester,
    ) async {
      final inner = _Unknown();
      await pump(tester, inner);
      expect(find.text(HmTerminalText.noCwd), findsNothing);
      expect(find.byType(TerminalView), findsOneWidget);
      expect(inner.openedIn, ['']);
      // The header shows where the host actually opened it.
      expect(find.text('/Users/kevin'), findsOneWidget);
    });

    testWidgets('a failed folder lookup still opens the shell', (tester) async {
      final inner = _Unknown(fail: true);
      await pump(tester, inner);
      expect(find.byType(TerminalView), findsOneWidget);
      expect(inner.openedIn, ['']);
    });
  });

  group('SSH with no known folder', () {
    test('skips the cd and shows the home folder', () async {
      final mem = MemCredentialStore();
      final store = HmSshStore(store: mem);
      await store.save(
        'c1',
        const HmSshConfig(
          host: 'studio.local',
          username: 'kevin',
          password: 'pw',
          hostKeyType: 'ssh-ed25519',
          hostKeyFingerprint: 'SHA256:serverkeyA',
        ),
      );
      final shell = FakeShell();
      final backend = SshTerminalBackend(
        connectionId: 'c1',
        store: store,
        connector: FakeConnector([FakeDial.shell(shell)]),
        trustPrompt: (_, _, _) async => true,
        cwdLookup: () async => null,
      );
      final session = await backend.open(cwd: '', cols: 80, rows: 24);
      expect(shell.writes, isEmpty);
      expect(session.meta.cwd, '~');
      await session.close();
    });

    test('with a folder it still changes into it', () async {
      final mem = MemCredentialStore();
      final store = HmSshStore(store: mem);
      await store.save(
        'c1',
        const HmSshConfig(
          host: 'studio.local',
          username: 'kevin',
          password: 'pw',
          hostKeyType: 'ssh-ed25519',
          hostKeyFingerprint: 'SHA256:serverkeyA',
        ),
      );
      final shell = FakeShell();
      final backend = SshTerminalBackend(
        connectionId: 'c1',
        store: store,
        connector: FakeConnector([FakeDial.shell(shell)]),
        trustPrompt: (_, _, _) async => true,
        cwdLookup: () async => '/srv/app',
      );
      final session = await backend.open(cwd: '/srv/app', cols: 80, rows: 24);
      expect(shell.writes, [hmSshCdCommand('/srv/app')]);
      await session.close();
    });
  });
}
