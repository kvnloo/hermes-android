import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/features/terminal/terminal_page.dart';
import 'package:hermes_android/hm/features/terminal/terminal_transport.dart';
import 'package:xterm/xterm.dart';

class _FakeSession implements HmTerminalSession {
  _FakeSession({this.cwd = '/srv/app'});

  final String cwd;
  final out = StreamController<String>();
  final ended = Completer<HmTerminalEnd>();
  final writes = <String>[];
  final resizes = <(int, int)>[];
  bool closed = false;

  @override
  HmTerminalMeta get meta => HmTerminalMeta(shell: 'zsh', cwd: cwd);
  @override
  Stream<String> get output => out.stream;
  @override
  Future<HmTerminalEnd> get done => ended.future;
  @override
  void write(String data) => writes.add(data);
  @override
  void resize(int cols, int rows) => resizes.add((cols, rows));
  @override
  Future<void> close() async => closed = true;
}

class _FakeBackend implements HmTerminalBackend {
  _FakeBackend({this.cwd = '/srv/app', List<Object>? opens})
    : opens = opens ?? [];

  final String? cwd;

  /// What each successive [open] does: a session to return or an error.
  final List<Object> opens;
  final openedIn = <String>[];

  @override
  Future<String?> workingDirectory() async => cwd;

  @override
  Future<HmTerminalSession> open({
    required String cwd,
    required int cols,
    required int rows,
  }) async {
    openedIn.add(cwd);
    final next = opens.removeAt(0);
    if (next is HmTerminalSession) return next;
    throw next;
  }
}

Future<void> _pump(
  WidgetTester tester,
  HmTerminalBackend backend, {
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      // The test font's square glyphs are far wider than Nunito.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: HmTerminalPage(backend: backend),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Terminal _terminal(WidgetTester tester) =>
    tester.widget<TerminalView>(find.byType(TerminalView)).terminal;

void main() {
  testWidgets('no working directory shows the official reconnect hint', (
    tester,
  ) async {
    final backend = _FakeBackend(cwd: null);
    await _pump(tester, backend);
    expect(find.text(HmTerminalText.noCwd), findsOneWidget);
    expect(find.byType(TerminalView), findsNothing);
    expect(backend.openedIn, isEmpty);
  });

  testWidgets('a host without a terminal shows Connect a Terminal', (
    tester,
  ) async {
    await _pump(tester, _FakeBackend(opens: [const HmTerminalUnavailable()]));
    expect(find.text('Connect a Terminal'), findsOneWidget);
    expect(
      find.text('Add SSH credentials in Terminal settings first.'),
      findsOneWidget,
    );
    expect(find.byType(TerminalView), findsNothing);
  });

  testWidgets('connecting shows progress until the shell opens', (
    tester,
  ) async {
    final gate = Completer<HmTerminalSession>();
    final backend = _GatedBackend(gate.future);
    await tester.pumpWidget(
      MaterialApp(home: HmTerminalPage(backend: backend)),
    );
    await tester.pump();
    expect(find.text(HmTerminalText.connecting), findsOneWidget);
    gate.complete(_FakeSession());
    await tester.pump();
    await tester.pump();
    expect(find.byType(TerminalView), findsOneWidget);
  });

  testWidgets('a failed open shows the reason and Try Again reconnects', (
    tester,
  ) async {
    final session = _FakeSession();
    final backend = _FakeBackend(
      opens: [
        const HmTerminalFailure(
          'Terminal capacity reached; close a terminal and retry',
        ),
        session,
      ],
    );
    await _pump(tester, backend);
    expect(find.text('Connection failed'), findsOneWidget);
    expect(
      find.text('Terminal capacity reached; close a terminal and retry'),
      findsOneWidget,
    );
    await tester.tap(find.text('Try Again'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(TerminalView), findsOneWidget);
    expect(backend.openedIn, ['/srv/app', '/srv/app']);
  });

  testWidgets('connected: shows output and the folder, sends typing', (
    tester,
  ) async {
    final session = _FakeSession(cwd: '/home/kevin/project');
    final backend = _FakeBackend(cwd: '/home/kevin/project', opens: [session]);
    await _pump(tester, backend);

    expect(find.text('Terminal'), findsOneWidget);
    expect(find.text('/home/kevin/project'), findsOneWidget);
    expect(backend.openedIn, ['/home/kevin/project']);

    session.out.add('kevin@host project % ');
    await tester.pump();
    expect(
      _terminal(tester).buffer.getText(),
      contains('kevin@host project %'),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(session.writes.join(), contains('\r'));

    await tester.pumpWidget(const SizedBox());
    expect(session.closed, isTrue);
  });

  testWidgets('menu Paste sends the clipboard text to the shell', (
    tester,
  ) async {
    final session = _FakeSession();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? <String, dynamic>{'text': 'echo hi'}
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _pump(tester, _FakeBackend(opens: [session]), textScale: 0.6);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Select All'), findsOneWidget);
    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();
    expect(session.writes.join(), contains('echo hi'));
  });

  testWidgets('shell exit shows Terminal has been closed and reconnects', (
    tester,
  ) async {
    final first = _FakeSession();
    final second = _FakeSession();
    final backend = _FakeBackend(opens: [first, second]);
    await _pump(tester, backend);

    first.ended.complete(
      const HmTerminalEnd(code: hmTerminalClosedCode, reason: 'Process exited'),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Terminal has been closed'), findsOneWidget);
    expect(find.text(HmTerminalText.reconnect), findsOneWidget);

    await tester.tap(find.text('Try Again'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Terminal has been closed'), findsNothing);
    expect(backend.openedIn.length, 2);
  });

  testWidgets('a dropped socket shows Connection lost', (tester) async {
    final session = _FakeSession();
    await _pump(tester, _FakeBackend(opens: [session]));
    session.ended.complete(const HmTerminalEnd(code: 1006));
    await tester.pump();
    await tester.pump();
    expect(find.text('Connection lost'), findsOneWidget);
  });
}

class _GatedBackend implements HmTerminalBackend {
  _GatedBackend(this.session);
  final Future<HmTerminalSession> session;

  @override
  Future<String?> workingDirectory() async => '/srv/app';

  @override
  Future<HmTerminalSession> open({
    required String cwd,
    required int cols,
    required int rows,
  }) => session;
}
