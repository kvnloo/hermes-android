import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/features/work/hm_kanban.dart';
import 'package:hermes_android/hm/features/work/hm_kanban_data.dart';

import 'work_fakes.dart';

const _boards = 'GET plugins/kanban/boards';
const _board = 'GET plugins/kanban/board';

Map<String, dynamic> _boardList([List<Map<String, dynamic>>? extra]) => {
  'boards': [
    {'slug': 'default', 'name': 'Default', 'total': 2, 'is_current': true},
    ...?extra,
  ],
  'current': 'default',
};

Map<String, dynamic> _columns(Map<String, List<Map<String, dynamic>>> by) => {
  'columns': [
    for (final name in hmKanbanColumns.keys.where((k) => k != 'archived'))
      {'name': name, 'tasks': by[name] ?? const []},
  ],
};

Map<String, dynamic> _task(String id, String title, String status) => {
  'id': id,
  'title': title,
  'status': status,
  'assignee': 'atlas',
  'priority': 0,
};

void main() {
  late FakeDashboard dash;

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      workHost(HmKanbanPage(source: HmKanbanSource(dash.call))),
    );
    await tester.pumpAndSettle();
  }

  setUp(() => dash = FakeDashboard());

  testWidgets('an empty board is A Clear Board, titled by the board', (
    tester,
  ) async {
    dash.on(_boards, 200, _boardList());
    dash.on(_board, 200, _columns({}));
    await open(tester);

    expect(find.text('Default'), findsOneWidget);
    expect(find.text('Search tasks'), findsOneWidget);
    expect(find.text('A Clear Board'), findsOneWidget);
    expect(
      find.text(
        'Capture the next piece of work, then let Hermes help move it forward.',
      ),
      findsOneWidget,
    );
    expect(find.text('Add First Task'), findsOneWidget);
    expect(dash.where('GET', 'plugins/kanban/board').single.query, {
      'board': 'default',
    });
  });

  testWidgets('tasks group by column and search narrows them', (tester) async {
    dash.on(_boards, 200, _boardList());
    dash.on(
      _board,
      200,
      _columns({
        'todo': [_task('t1', 'Write the changelog', 'todo')],
        'done': [_task('t2', 'Fix login', 'done')],
      }),
    );
    await open(tester);

    expect(find.text('Todo · 1'), findsOneWidget);
    expect(find.text('Done · 1'), findsOneWidget);
    expect(find.text('Write the changelog'), findsOneWidget);
    expect(find.text('Fix login'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'login');
    await tester.pumpAndSettle();
    expect(find.text('Write the changelog'), findsNothing);
    expect(find.text('Fix login'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'nothing matches');
    await tester.pumpAndSettle();
    expect(find.text('No tasks'), findsOneWidget);
  });

  testWidgets('a host without the plugin says Kanban isn\'t available', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Kanban Isn’t Available'), findsOneWidget);
    expect(find.text("Kanban isn't available on this server."), findsOneWidget);
  });

  testWidgets('a failing check offers Try Again', (tester) async {
    dash.on(_boards, 500, {'detail': 'boom'});
    await open(tester);
    expect(find.text('Couldn’t Check Kanban'), findsOneWidget);

    dash.on(_boards, 200, _boardList());
    dash.on(_board, 200, _columns({}));
    await tester.tap(find.text('Try Again'));
    await tester.pumpAndSettle();
    expect(find.text('A Clear Board'), findsOneWidget);
  });

  testWidgets('no boards offers Create Board', (tester) async {
    dash.on(_boards, 200, {'boards': [], 'current': null});
    await open(tester);
    expect(find.text('No Boards Yet'), findsOneWidget);
    expect(
      find.text('Create a board to start shaping work into a clear flow.'),
      findsOneWidget,
    );
    dash.on('POST plugins/kanban/boards', 200, {
      'board': {'slug': 'launch-plan'},
    });
    await tester.tap(find.text('Create Board'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('board-name')), 'Launch Plan');
    dash.on(
      _boards,
      200,
      _boardList([
        {'slug': 'launch-plan', 'name': 'Launch Plan', 'total': 0},
      ]),
    );
    dash.on(_board, 200, _columns({}));
    await tester.tap(find.widgetWithText(FilledButton, 'Create Board').last);
    await tester.pumpAndSettle();

    expect(dash.where('POST', 'plugins/kanban/boards').single.body, {
      'slug': 'launch-plan',
      'name': 'Launch Plan',
    });
    expect(find.text('Launch Plan'), findsOneWidget);
    expect(dash.where('GET', 'plugins/kanban/board').last.query, {
      'board': 'launch-plan',
    });
  });

  testWidgets('Add First Task posts the task to this board', (tester) async {
    dash.on(_boards, 200, _boardList());
    dash.on(_board, 200, _columns({}));
    dash.on('POST plugins/kanban/tasks', 200, {
      'task': _task('t9', 'Ship it', 'todo'),
    });
    await open(tester);

    await tester.tap(find.text('Add First Task'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('task-title')), 'Ship it');
    await tester.enterText(find.byKey(const Key('task-body')), 'Tag 1.0');
    dash.on(
      _board,
      200,
      _columns({
        'todo': [_task('t9', 'Ship it', 'todo')],
      }),
    );
    await tester.tap(find.text('Add Task'));
    await tester.pumpAndSettle();

    final post = dash.where('POST', 'plugins/kanban/tasks').single;
    expect(post.query, {'board': 'default'});
    expect(post.body, {'title': 'Ship it', 'body': 'Tag 1.0'});
    expect(find.text('Task added'), findsOneWidget);
    expect(find.text('Todo · 1'), findsOneWidget);
  });

  testWidgets('a task opens its details and moves to another column', (
    tester,
  ) async {
    dash.on(_boards, 200, _boardList());
    dash.on(
      _board,
      200,
      _columns({
        'todo': [_task('t1', 'Write the changelog', 'todo')],
      }),
    );
    dash.on('GET plugins/kanban/tasks/t1', 200, {
      'task': {
        ..._task('t1', 'Write the changelog', 'todo'),
        'body': 'Cover 1.0',
      },
      'comments': [
        {'author': 'kevin', 'body': 'Keep it short', 'created_at': 1},
      ],
    });
    dash.on('PATCH plugins/kanban/tasks/t1', 200, {
      'task': _task('t1', 'Write the changelog', 'done'),
    });
    await open(tester);

    await tester.tap(find.text('Write the changelog'));
    await tester.pumpAndSettle();
    expect(find.text('Cover 1.0'), findsOneWidget);
    expect(find.text('Keep it short'), findsOneWidget);
    expect(find.text('Move to'), findsOneWidget);

    await tester.tap(find.text('Move to'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done').last);
    await tester.pumpAndSettle();

    final patch = dash.where('PATCH', 'plugins/kanban/tasks/t1').single;
    expect(patch.body, {'status': 'done'});
    expect(patch.query, {'board': 'default'});
    expect(find.text('Task updated'), findsOneWidget);
  });

  testWidgets('a refused move shows the host\'s reason', (tester) async {
    dash.on(_boards, 200, _boardList());
    dash.on(
      _board,
      200,
      _columns({
        'todo': [_task('t1', 'Write the changelog', 'todo')],
      }),
    );
    dash.on('GET plugins/kanban/tasks/t1', 200, {
      'task': _task('t1', 'Write the changelog', 'todo'),
    });
    dash.on('PATCH plugins/kanban/tasks/t1', 409, {
      'detail': "Cannot move to 'ready': blocked by parent(s) not done",
    });
    await open(tester);
    await tester.tap(find.text('Write the changelog'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ready'));
    await tester.pumpAndSettle();
    expect(
      find.text("Cannot move to 'ready': blocked by parent(s) not done"),
      findsOneWidget,
    );
  });

  testWidgets('Delete Task confirms, deletes and returns to the board', (
    tester,
  ) async {
    dash.on(_boards, 200, _boardList());
    dash.on(
      _board,
      200,
      _columns({
        'todo': [_task('t1', 'Write the changelog', 'todo')],
      }),
    );
    dash.on('GET plugins/kanban/tasks/t1', 200, {
      'task': _task('t1', 'Write the changelog', 'todo'),
    });
    dash.on('DELETE plugins/kanban/tasks/t1', 200, {'deleted': true});
    await open(tester);
    await tester.tap(find.text('Write the changelog'));
    await tester.pumpAndSettle();

    dash.on(_board, 200, _columns({}));
    await tester.tap(find.bySemanticsLabel('Task actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete Task'));
    await tester.pumpAndSettle();
    expect(find.text('Delete this task?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Delete Task'));
    await tester.pumpAndSettle();

    expect(dash.where('DELETE', 'plugins/kanban/tasks/t1'), hasLength(1));
    expect(find.text('Task deleted'), findsOneWidget);
    expect(find.text('A Clear Board'), findsOneWidget);
  });

  testWidgets('the board switcher opens another board', (tester) async {
    dash.on(
      _boards,
      200,
      _boardList([
        {'slug': 'ops', 'name': 'Ops', 'total': 1},
      ]),
    );
    dash.routes[_board] = (FakeCall c) => (
      200,
      c.query?['board'] == 'ops'
          ? _columns({
              'ready': [_task('o1', 'Rotate keys', 'ready')],
            })
          : _columns({}),
    );
    await open(tester);

    await tester.tap(find.text('Default'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ops'));
    await tester.pumpAndSettle();
    expect(find.text('Rotate keys'), findsOneWidget);
    expect(find.text('Ready · 1'), findsOneWidget);
  });
}
