// Tool/command progress in the live call's transcript (HA-038): while the
// agent works on a request, its tool calls show as the chat's own tool rows,
// folded by default with a spinner and the running command, then "Used …"
// with a one-line result; tapping opens the rows, tapping a row its output.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/features/live/hm_live.dart';
import 'package:hermes_android/hm/features/live/live_controller.dart';
import 'package:hermes_android/hm/features/live/live_transport.dart';
import 'package:hermes_android/hm/hm_bots.dart';
import 'package:hermes_android/nextgen/data/chat_controller.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/nextgen/ui/tool_rows.dart';

import 'live_fakes.dart';

final _bot = HmBot.fromJson({
  'name': 'teknium',
  'display_name': 'teknium',
  'model': 'm',
  'provider': 'p',
});

Future<void> _open(WidgetTester tester, LiveRig rig) async {
  // A phone-sized call (S25: 1080x2340 at 3x), so the transcript has room.
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: nextGenTheme(Brightness.dark, NextGenLook.instance),
      home: HmLiveScreen(bot: _bot, create: rig.build),
    ),
  );
  await _frames(tester);
}

/// The avatars animate forever, so step frames instead of settling.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Map<String, Object?> _delta(bool user, String text) => {
  'type': user
      ? 'session.input_transcript.delta'
      : 'session.output_transcript.delta',
  'delta': text,
};

/// The running chat turn reports [tools] on its reply.
void _work(LiveRig rig, List<NgTool> tools, {String text = ''}) {
  rig.brain.shown.add(
    LiveLine(key: 'reply', fromUser: false, text: text, tools: tools),
  );
  rig.brain.notifyListeners();
}

Finder get _spinner => find.descendant(
  of: find.byKey(const ValueKey('live-work')),
  matching: find.byType(CircularProgressIndicator),
);

void main() {
  testWidgets(
    'GPT-Live: a delegated turn shows its commands as progress rows',
    (tester) async {
      final rig = LiveRig(
        host: FakeHost(mode: 'gpt-live', available: true),
        peer: FakePeer(),
      );
      await _open(tester, rig);
      final peer = rig.peer!;
      peer.event(_delta(true, 'What is running right now?'));
      peer.event({
        'type': 'session.delegation.created',
        'delegation': {'id': 'd1', 'type': 'delegation', 'target': 'client'},
      });
      peer.event(_delta(false, "Sure, I'll look into that."));
      await _frames(tester);
      // No tool yet: no work row.
      expect(find.byType(LiveWork), findsNothing);

      final tool = NgTool(
        id: 't1',
        name: 'terminal',
        detail: 'kubectl get pods -A',
        running: true,
        input: 'kubectl get pods -A',
      );
      _work(rig, [tool]);
      await _frames(tester);

      // Running: the command with a spinner, folded.
      expect(find.text('terminal · kubectl get pods -A'), findsOneWidget);
      expect(_spinner, findsOneWidget);
      expect(find.byType(NgToolRow), findsNothing);
      // It sits between the request and the voice's acknowledgement.
      final asked = tester.getTopLeft(find.text('What is running right now?'));
      final work = tester.getTopLeft(find.byType(LiveWork));
      final ack = tester.getTopLeft(find.text("Sure, I'll look into that."));
      expect(asked.dy, lessThan(work.dy));
      expect(work.dy, lessThan(ack.dy));

      // Tap: the rows open.
      await tester.tap(find.text('terminal · kubectl get pods -A'));
      await _frames(tester);
      expect(find.byType(NgToolRow), findsOneWidget);

      // Done: a check, "Used terminal" and the one-line result.
      tool
        ..running = false
        ..summary = '3 pods running'
        ..output = 'NAME   READY\napi    1/1';
      rig.brain.notifyListeners();
      await _frames(tester);
      expect(_spinner, findsNothing);
      expect(find.text('Used terminal'), findsOneWidget);
      expect(find.text('3 pods running'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);

      // Tap the row: its output.
      expect(find.textContaining('api    1/1'), findsNothing);
      await tester.tap(find.text('3 pods running'));
      await _frames(tester);
      expect(find.textContaining('api    1/1'), findsOneWidget);

      // Fold again.
      await tester.tap(find.text('Used terminal'));
      await _frames(tester);
      expect(find.byType(NgToolRow), findsNothing);
    },
  );

  testWidgets('several tools fold into one "Used N tools" row', (tester) async {
    final rig = LiveRig(
      host: FakeHost(mode: 'gpt-live', available: true),
      peer: FakePeer(),
    );
    await _open(tester, rig);
    rig.peer!.event(_delta(true, 'go to my home screen'));
    rig.peer!.event({
      'type': 'session.delegation.created',
      'delegation': {'id': 'd1', 'type': 'delegation', 'target': 'client'},
    });
    await _frames(tester);
    _work(rig, [
      NgTool(id: 'a', name: 'adb', detail: 'input keyevent HOME'),
      NgTool(id: 'b', name: 'uiautomator', detail: 'dump', failed: true),
    ]);
    await _frames(tester);
    expect(find.text('Used 2 tools'), findsOneWidget);
    await tester.tap(find.text('Used 2 tools'));
    await _frames(tester);
    expect(find.byType(NgToolRow), findsNWidgets(2));
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });

  testWidgets('chained loop: the reply shows its tool rows above its text', (
    tester,
  ) async {
    final rig = LiveRig();
    await _open(tester, rig);
    rig.ear.hear('check the build');
    await _frames(tester);
    _work(rig, [
      NgTool(id: 'a', name: 'terminal', detail: 'make test', running: true),
    ]);
    await _frames(tester);
    expect(find.text('terminal · make test'), findsOneWidget);
    expect(_spinner, findsOneWidget);
  });

  test('the controller places work rows where the turn started', () async {
    final rig = LiveRig(
      host: FakeHost(mode: 'gpt-live', available: true),
      peer: FakePeer(),
    );
    final live = rig.build();
    await live.start();
    rig.peer!.event(_delta(true, 'first'));
    rig.peer!.event({
      'type': 'session.delegation.created',
      'delegation': {'id': 'd1', 'type': 'delegation', 'target': 'client'},
    });
    await Future<void>.delayed(Duration.zero);
    rig.peer!.event(_delta(false, 'On it.'));
    _work(rig, [NgTool(id: 'a', name: 'terminal', running: true)]);
    expect(live.lines.map((l) => (l.work, l.text)), [
      (false, 'first'),
      (true, ''),
      (false, 'On it.'),
    ]);
    expect(live.lines[1].tools.single.name, 'terminal');
    // The voice talking after the work row starts a new line, not a merge.
    expect(live.phase, isNot(LivePhase.failed));
    await live.end();
  });
}
