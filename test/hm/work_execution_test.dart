import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/hm/features/work/hm_execution.dart';
import 'package:hermes_android/nextgen/data/chat_controller.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/nextgen/data/session_control.dart';

import 'work_fakes.dart';

SavedConnection _conn() => SavedConnection(
  id: 'c1',
  label: 'Home',
  host: '10.0.0.5',
  port: 9119,
  apiKey: '',
  desktopGatewayUrl: 'http://10.0.0.5:9119',
  singleLogin: true,
  signInMethod: 'none',
);

Map<String, dynamic> _proc(
  String id,
  String command, {
  String status = 'running',
}) => {
  'session_id': id,
  'command': command,
  'status': status,
  'uptime_seconds': 125,
  'output_tail': 'listening on :8080',
};

void main() {
  late NextGenGateway gateway;
  late NgChatController chat;
  late FakeRpc rpc;

  setUp(() {
    gateway = NextGenGateway(_conn());
    chat = NgChatController(gateway, sessionId: 'stored', profile: 'atlas')
      ..runtimeId = 'rt';
    rpc = FakeRpc()
      ..answers['process.list'] = <String, dynamic>{'processes': []}
      ..answers['delegation.status'] = <String, dynamic>{'paused': false};
  });

  tearDown(() {
    chat.dispose();
    gateway.dispose();
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      workHost(
        HmExecutionPage(
          chat: chat,
          source: HmExecutionSource(rpc: rpc.call, scope: 'atlas'),
          poll: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('nothing running shows the official empty state', (tester) async {
    await open(tester);
    expect(find.text('Execution'), findsOneWidget);
    expect(find.text('No Execution Activity'), findsOneWidget);
    expect(
      find.text(
        'Goals, tasks, subagents, and terminal processes will appear here.',
      ),
      findsOneWidget,
    );
    expect(rpc.paramsOf('process.list').single, {
      'session_id': 'rt',
      'profile': 'atlas',
    });
  });

  testWidgets('a chat with no live session is empty without asking', (
    tester,
  ) async {
    chat.runtimeId = null;
    await open(tester);
    expect(find.text('No Execution Activity'), findsOneWidget);
    expect(rpc.calls, isEmpty);
  });

  testWidgets('a failing process read offers Try Again', (tester) async {
    rpc.answers['process.list'] = StateError(
      'Not connected to the gateway yet.',
    );
    await open(tester);
    expect(find.text('Not connected to the gateway yet.'), findsOneWidget);

    rpc.answers['process.list'] = <String, dynamic>{
      'processes': [_proc('proc_1', 'npm run dev')],
    };
    await tester.tap(find.text('Try Again'));
    await tester.pumpAndSettle();
    expect(find.text('npm run dev'), findsOneWidget);
  });

  testWidgets('goal, plan, subagents and processes all show', (tester) async {
    chat.control = NgSessionControl.parse({
      'goal': {
        'title': 'Ship the release',
        'status': 'active',
        'turns_used': 4,
        'max_turns': 20,
        'subgoals': ['Tests pass'],
      },
    });
    chat.todos = NgTodoList.parse({
      'revision': 1,
      'todos': [
        {'id': '1', 'content': 'Build', 'status': 'completed'},
        {'id': '2', 'content': 'Test', 'status': 'in_progress'},
      ],
    });
    chat.subagents.add(NgSubagent('a1', goal: 'Review the diff'));
    rpc.answers['process.list'] = <String, dynamic>{
      'processes': [_proc('proc_1', 'npm run dev')],
    };
    await open(tester);

    expect(find.text('Ship the release'), findsOneWidget);
    expect(find.text('4/20'), findsOneWidget);
    expect(find.text('Tests pass'), findsOneWidget);
    expect(find.text('Task progress · 1/2'), findsOneWidget);
    expect(find.text('Test'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Review the diff'), 200);
    expect(find.text('Review the diff'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('npm run dev'), 200);
    expect(find.text('npm run dev'), findsOneWidget);
    expect(find.text('Pause New Subagents'), findsOneWidget);
  });

  testWidgets('Stop background process kills that process', (tester) async {
    var killed = false;
    rpc.answers['process.list'] = (Map<String, dynamic> _) => <String, dynamic>{
      'processes': [
        _proc('proc_1', 'npm run dev', status: killed ? 'exited' : 'running'),
      ],
    };
    rpc.answers['process.kill'] = (Map<String, dynamic> _) {
      killed = true;
      return <String, dynamic>{'status': 'killed'};
    };
    await open(tester);

    await tester.tap(find.byTooltip('Stop background process'));
    await tester.pumpAndSettle();
    expect(rpc.paramsOf('process.kill').single, {
      'session_id': 'rt',
      'process_id': 'proc_1',
      'profile': 'atlas',
    });
    expect(find.text('Stopped 1 background process.'), findsOneWidget);
    expect(find.byTooltip('Stop background process'), findsNothing);
  });

  testWidgets('a refused kill says it could not stop the process', (
    tester,
  ) async {
    rpc.answers['process.list'] = <String, dynamic>{
      'processes': [_proc('proc_1', 'npm run dev')],
    };
    rpc.answers['process.kill'] = <String, dynamic>{
      'status': 'error',
      'error': 'permission denied',
    };
    await open(tester);
    await tester.tap(find.byTooltip('Stop background process'));
    await tester.pumpAndSettle();
    expect(find.text('Could not stop the process'), findsOneWidget);
  });

  testWidgets('a process opens its output', (tester) async {
    rpc.answers['process.list'] = <String, dynamic>{
      'processes': [_proc('proc_1', 'npm run dev')],
    };
    await open(tester);
    await tester.tap(find.text('npm run dev'));
    await tester.pumpAndSettle();
    expect(find.text('Background process'), findsOneWidget);
    expect(find.text('listening on :8080'), findsOneWidget);
  });

  testWidgets('Pause goes out as session.control and confirms', (tester) async {
    chat.control = NgSessionControl.parse({
      'goal': {'title': 'Ship the release', 'status': 'active'},
    });
    rpc.answers['session.control'] = <String, dynamic>{
      'control': {
        'goal': {'title': 'Ship the release', 'status': 'paused'},
      },
    };
    await open(tester);
    await tester.tap(find.text('Pause'));
    await tester.pumpAndSettle();

    expect(rpc.paramsOf('session.control').single, {
      'session_id': 'rt',
      'action': 'goal.pause',
      'profile': 'atlas',
    });
    expect(find.text('Goal paused.'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
  });

  testWidgets('Clear Goal asks first; a failure says so', (tester) async {
    chat.control = NgSessionControl.parse({
      'goal': {'title': 'Ship the release', 'status': 'active'},
    });
    rpc.answers['session.control'] = StateError('nope');
    await open(tester);
    await tester.tap(find.text('Clear Goal'));
    await tester.pumpAndSettle();
    expect(find.text('Clear the goal?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Clear Goal'));
    await tester.pumpAndSettle();
    expect(rpc.paramsOf('session.control').single['action'], 'goal.clear');
    expect(find.text('Could not clear the goal.'), findsOneWidget);
  });

  testWidgets('a live subagent can be stopped and guided', (tester) async {
    chat.subagents.add(NgSubagent('a1', goal: 'Review the diff'));
    rpc.answers['subagent.interrupt'] = <String, dynamic>{'found': true};
    rpc.answers['subagent.steer'] = <String, dynamic>{'status': 'queued'};
    await open(tester);

    await tester.tap(find.byTooltip('Stop current task'));
    await tester.pumpAndSettle();
    expect(rpc.paramsOf('subagent.interrupt').single, {
      'session_id': 'rt',
      'subagent_id': 'a1',
      'profile': 'atlas',
    });

    await tester.tap(find.text('Review the diff'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send guidance…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('guidance')), 'Check tests');
    await tester.tap(find.text('Send message'));
    await tester.pumpAndSettle();
    expect(rpc.paramsOf('subagent.steer').single['text'], 'Check tests');
    expect(find.text('Guidance sent'), findsOneWidget);
  });

  testWidgets('Pause New Subagents toggles delegation', (tester) async {
    chat.subagents.add(NgSubagent('a1', goal: 'Review the diff'));
    rpc.answers['delegation.pause'] = <String, dynamic>{'paused': true};
    await open(tester);
    await tester.tap(find.text('Pause New Subagents'));
    await tester.pumpAndSettle();
    expect(rpc.paramsOf('delegation.pause').single['paused'], true);
    expect(find.text('New subagents paused'), findsOneWidget);
    expect(find.text('Resume Subagents'), findsOneWidget);
  });
}
