// Terminal over SSH: trust on first use, connect → cd → output, resize,
// failures and reconnect, all through a fake SSH connector.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/features/terminal/ssh_config.dart';
import 'package:hermes_android/hm/features/terminal/ssh_transport.dart';
import 'package:hermes_android/hm/features/terminal/terminal_connection_page.dart';
import 'package:hermes_android/hm/features/terminal/terminal_page.dart';
import 'package:hermes_android/hm/features/terminal/terminal_transport.dart';
import 'package:xterm/xterm.dart';

import 'terminal_ssh_fakes.dart';

const _id = 'conn-1';

class _Harness {
  _Harness(
    List<FakeDial> dials, {
    HmSshConfig? config,
    this.fallback,
    Duration? handshakeBudget,
  }) : connector = FakeConnector(dials, handshakeBudget: handshakeBudget) {
    if (config != null) {
      mem.values[HmSshStore.keyFor(_id)] = _encode(config);
    }
  }

  final mem = MemCredentialStore();
  late final store = HmSshStore(store: mem);
  final FakeConnector connector;
  final HmTerminalBackend? fallback;
  final nav = GlobalKey<NavigatorState>();
  int settingsOpened = 0;

  /// What the settings page "saves" when opened from the terminal.
  HmSshConfig? saveOnSettings;

  /// Same JSON the store writes.
  static String _encode(HmSshConfig c) => jsonEncode(c.toJson());

  SshTerminalBackend backend() => SshTerminalBackend(
    connectionId: _id,
    store: store,
    connector: connector,
    trustPrompt: (host, type, fp) => hmConfirmSshHost(
      nav.currentContext!,
      host: host,
      type: type,
      fingerprint: fp,
    ),
    cwdLookup: () async => '/srv/app',
    fallback: fallback,
  );

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(0.6)),
          child: child!,
        ),
        home: HmTerminalPage(
          backend: backend(),
          onOpenSettings: (_) async {
            settingsOpened++;
            final next = saveOnSettings;
            if (next == null) return false;
            await store.save(_id, next);
            return true;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }
}

/// The host's own terminal (round 1), used when no SSH is saved.
class _HostBackend implements HmTerminalBackend, HmTerminalSession {
  final opened = <String>[];
  final _out = StreamController<String>();

  @override
  Future<String?> workingDirectory() async => '/srv/app';
  @override
  Future<HmTerminalSession> open({
    required String cwd,
    required int cols,
    required int rows,
  }) async {
    opened.add(cwd);
    return this;
  }

  @override
  HmTerminalMeta get meta => const HmTerminalMeta(cwd: '/srv/app');
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

/// Bounded pumps: the busy spinner never settles.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Terminal _terminal(WidgetTester tester) =>
    tester.widget<TerminalView>(find.byType(TerminalView)).terminal;

const _trusted = HmSshConfig(
  host: 'studio.local',
  username: 'kevin',
  password: 'pw',
  hostKeyType: 'ssh-ed25519',
  hostKeyFingerprint: 'SHA256:serverkeyA',
);

void main() {
  testWidgets('no Terminal Connection: Connect a Terminal links to settings, '
      'and saving there connects', (tester) async {
    final shell = FakeShell();
    final h = _Harness([FakeDial.shell(shell)])..saveOnSettings = _trusted;
    await h.pump(tester);

    expect(find.text('Connect a Terminal'), findsOneWidget);
    expect(
      find.text('Add SSH credentials in Terminal settings first.'),
      findsOneWidget,
    );
    expect(h.connector.targets, isEmpty);

    await tester.tap(find.text('Add SSH or Mosh'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(h.settingsOpened, 1);
    expect(find.byType(TerminalView), findsOneWidget);
    expect(h.connector.targets.single.host, 'studio.local');
  });

  testWidgets('first connection asks to trust the server fingerprint, saves '
      'it, then cds into the chat folder and shows output', (tester) async {
    final shell = FakeShell();
    // A person reads the fingerprint for longer than an SSH handshake waits
    // (measured on a device: the server dropped the first connection). The
    // first dial only fetches the key; the second connects as trusted.
    final h = _Harness(
      [
        FakeDial.shell(FakeShell(), fingerprint: 'SHA256:firstSeenKey'),
        FakeDial.shell(shell, fingerprint: 'SHA256:firstSeenKey'),
      ],
      handshakeBudget: const Duration(seconds: 15),
      config: const HmSshConfig(
        host: 'studio.local',
        port: 2222,
        username: 'kevin',
        password: 'pw',
      ),
    );
    await h.pump(tester);
    await _settle(tester);

    expect(find.text('Trust this SSH server?'), findsOneWidget);
    expect(
      find.text("Verify this server's SSH identity before connecting."),
      findsOneWidget,
    );
    expect(find.text('SHA256:firstSeenKey'), findsOneWidget);
    expect(find.text('studio.local'), findsOneWidget);

    // Longer than the handshake budget.
    await tester.pump(const Duration(seconds: 20));
    await tester.tap(find.text('Trust and Connect'));
    await _settle(tester);

    expect(find.byType(TerminalView), findsOneWidget);
    expect(h.connector.targets, hasLength(2));
    final target = h.connector.targets.last;
    expect(
      (target.host, target.port, target.username, target.password),
      ('studio.local', 2222, 'kevin', 'pw'),
    );
    expect(h.mem.saved(_id)!['hostKeyFingerprint'], 'SHA256:firstSeenKey');
    expect(shell.writes.first, "cd '/srv/app' && clear\r");

    shell.emit('kevin@studio app % ');
    await tester.pump();
    expect(_terminal(tester).buffer.getText(), contains('kevin@studio app %'));
    expect(find.text('/srv/app'), findsOneWidget);
  });

  testWidgets('declining the fingerprint does not connect or save it', (
    tester,
  ) async {
    final h = _Harness([
      FakeDial.shell(FakeShell()),
    ], config: const HmSshConfig(host: 'h', username: 'u', password: 'p'));
    await h.pump(tester);
    await _settle(tester);
    await tester.tap(find.text('Cancel'));
    await _settle(tester);
    expect(find.byType(TerminalView), findsNothing);
    expect(find.text('Connection failed'), findsOneWidget);
    expect(h.mem.saved(_id)!['hostKeyFingerprint'], isNull);
  });

  testWidgets('a changed host key blocks with the official warning', (
    tester,
  ) async {
    final h = _Harness([
      FakeDial.shell(FakeShell(), fingerprint: 'SHA256:somethingElse'),
    ], config: _trusted);
    await h.pump(tester);
    await _settle(tester);

    expect(find.text('Trust this SSH server?'), findsNothing);
    expect(find.byType(TerminalView), findsNothing);
    expect(
      find.text(
        "This server's SSH identity has changed. Check its host key before connecting again.",
      ),
      findsOneWidget,
    );
    expect(h.mem.saved(_id)!['hostKeyFingerprint'], 'SHA256:serverkeyA');
    expect(find.text('Terminal Connection'), findsOneWidget);
  });

  testWidgets('PTY opens at the view size and a resize sends window-change', (
    tester,
  ) async {
    final shell = FakeShell();
    final h = _Harness([FakeDial.shell(shell)], config: _trusted);
    await h.pump(tester);
    await _settle(tester);
    final (cols, rows) = h.connector.sizes.single;
    expect(cols, greaterThan(0));
    expect(rows, greaterThan(0));

    _terminal(tester).resize(101, 33);
    expect(shell.resizes.last, (101, 33));
  });

  testWidgets('rejected password shows the official auth error; Try Again '
      'reconnects', (tester) async {
    final shell = FakeShell();
    final h = _Harness([
      FakeDial.fail(HmSshErrorKind.authRejected),
      FakeDial.shell(shell),
    ], config: _trusted);
    await h.pump(tester);
    await _settle(tester);
    expect(
      find.text('The SSH server didn’t accept this username and password.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Try Again'));
    await _settle(tester);
    expect(find.byType(TerminalView), findsOneWidget);
    expect(h.connector.targets.length, 2);
  });

  testWidgets('unreachable and refused servers use the official wording', (
    tester,
  ) async {
    final h = _Harness([
      FakeDial.fail(HmSshErrorKind.unreachable),
      FakeDial.fail(HmSshErrorKind.refused),
    ], config: _trusted);
    await h.pump(tester);
    await _settle(tester);
    expect(find.text('Could not reach the server.'), findsOneWidget);
    await tester.tap(find.text('Try Again'));
    await _settle(tester);
    expect(find.text('The server refused the connection.'), findsOneWidget);
  });

  testWidgets('a dropped SSH connection offers reconnect into a new shell', (
    tester,
  ) async {
    final first = FakeShell();
    final second = FakeShell();
    final h = _Harness([
      FakeDial.shell(first),
      FakeDial.shell(second),
    ], config: _trusted);
    await h.pump(tester);
    await _settle(tester);

    first.ended.complete();
    await _settle(tester);
    expect(find.text('Connection lost'), findsOneWidget);

    await tester.tap(find.text('Try Again'));
    await _settle(tester);
    expect(find.text('Connection lost'), findsNothing);
    expect(second.writes.first, "cd '/srv/app' && clear\r");
  });

  testWidgets('a key connection signs in with the parsed key, no password', (
    tester,
  ) async {
    final shell = FakeShell();
    final h = _Harness(
      [FakeDial.shell(shell)],
      config: HmSshConfig(
        host: 'studio.local',
        username: 'kevin',
        password: 'stale',
        privateKey: testOpenSshKey(),
        hostKeyType: 'ssh-ed25519',
        hostKeyFingerprint: 'SHA256:serverkeyA',
      ),
    );
    await h.pump(tester);
    await _settle(tester);
    final target = h.connector.targets.single;
    expect(target.password, isNull);
    expect(target.identities.single.type, 'ssh-ed25519');
  });

  testWidgets('no Terminal Connection but the host has its own terminal: '
      'that one opens, no SSH dial', (tester) async {
    final host = _HostBackend();
    final h = _Harness([], fallback: host);
    await h.pump(tester);
    await _settle(tester);
    expect(find.byType(TerminalView), findsOneWidget);
    expect(host.opened, ['/srv/app']);
    expect(h.connector.targets, isEmpty);
  });

  test('cd command quotes folders with spaces and quotes', () {
    expect(
      hmSshCdCommand("/srv/my app/it's"),
      "cd '/srv/my app/it'\\''s' && clear\r",
    );
  });
}
