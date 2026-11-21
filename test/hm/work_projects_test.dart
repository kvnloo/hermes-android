import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/features/work/hm_projects.dart';

import 'work_fakes.dart';

const _tree = 'GET profiles/projects/tree';

Map<String, dynamic> _project(
  String id,
  String label, {
  bool auto = false,
  bool home = false,
  int sessions = 0,
}) => {
  'id': id,
  'label': label,
  'path': '/srv/$id',
  'isAuto': auto,
  'isNoProject': home,
  'sessionCount': sessions,
  'repos': [
    {
      'id': 'r-$id',
      'label': '$id-repo',
      'path': '/srv/$id',
      'sessionCount': sessions,
      'groups': [
        {'id': 'main', 'label': 'main', 'isMain': true},
        {'id': 'wt', 'label': 'feature-x', 'path': '/srv/$id-wt'},
      ],
    },
  ],
  'previewSessions': [
    if (sessions > 0)
      {'id': 's1', 'title': 'Plan the launch', 'started_at': 1.0},
  ],
  'sessionIds': [if (sessions > 0) 's1'],
};

void main() {
  late FakeDashboard dash;
  late FakeRpc rpc;

  HmProjectsSource source() => HmProjectsSource(
    profile: 'atlas',
    scope: 'atlas',
    request: dash.call,
    rpc: rpc.call,
  );

  setUp(() {
    dash = FakeDashboard();
    rpc = FakeRpc();
  });

  testWidgets('lists only the bot\'s own projects, scoped to its profile', (
    tester,
  ) async {
    dash.on(_tree, 200, {
      'projects': [
        _project('p_1', 'Atlas', sessions: 4),
        _project('auto', 'scratch', auto: true),
        _project('__no_project__', 'Home', home: true),
      ],
    });
    await tester.pumpWidget(workHost(HmProjectsPage(source: source())));
    await tester.pumpAndSettle();

    expect(find.text('Projects'), findsOneWidget);
    expect(find.text('Atlas'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.text('scratch'), findsNothing);
    expect(find.text('Home'), findsNothing);
    expect(dash.calls.single.query?['profile'], 'atlas');
  });

  testWidgets('empty tree shows the official empty state', (tester) async {
    dash.on(_tree, 200, {'projects': []});
    await tester.pumpWidget(workHost(HmProjectsPage(source: source())));
    await tester.pumpAndSettle();

    expect(find.text('No projects yet'), findsOneWidget);
    expect(
      find.text(
        'Create a project to group conversations, repositories, and worktrees.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a host without the route says projects are unavailable', (
    tester,
  ) async {
    await tester.pumpWidget(workHost(HmProjectsPage(source: source())));
    await tester.pumpAndSettle();

    expect(find.text('Projects unavailable'), findsOneWidget);
    expect(
      find.text('Connect this install to view its projects.'),
      findsOneWidget,
    );
  });

  testWidgets('a failing read offers Try Again, which reloads', (tester) async {
    dash.on(_tree, 500, {'detail': 'database is locked'});
    await tester.pumpWidget(workHost(HmProjectsPage(source: source())));
    await tester.pumpAndSettle();
    expect(find.text('database is locked'), findsOneWidget);

    dash.on(_tree, 200, {
      'projects': [_project('p_1', 'Atlas')],
    });
    await tester.tap(find.text('Try Again'));
    await tester.pumpAndSettle();
    expect(find.text('Atlas'), findsOneWidget);
  });

  testWidgets('New Project validates, then creates over projects.create', (
    tester,
  ) async {
    dash.on(_tree, 200, {'projects': []});
    rpc.answers['projects.create'] = <String, dynamic>{
      'project': {'id': 'p_2'},
    };
    await tester.pumpWidget(workHost(HmProjectsPage(source: source())));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('New Project'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create Project'));
    await tester.pumpAndSettle();
    expect(find.text('Give the project a name.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('project-name')), 'Docs');
    await tester.enterText(find.byKey(const Key('project-folder')), 'srv');
    await tester.tap(find.text('Create Project'));
    await tester.pumpAndSettle();
    expect(
      find.text('Enter a folder that begins with / or ~/.'),
      findsOneWidget,
    );
    expect(rpc.calls, isEmpty);

    dash.on(_tree, 200, {
      'projects': [_project('p_2', 'Docs')],
    });
    await tester.enterText(
      find.byKey(const Key('project-folder')),
      '/srv/docs',
    );
    await tester.tap(find.text('Create Project'));
    await tester.pumpAndSettle();

    expect(rpc.paramsOf('projects.create').single, {
      'name': 'Docs',
      'folders': ['/srv/docs'],
      'primary_path': '/srv/docs',
      'profile': 'atlas',
    });
    expect(find.text('Docs'), findsOneWidget);
  });

  testWidgets('a project shows its worktrees and recent chats; delete works', (
    tester,
  ) async {
    dash.on(_tree, 200, {
      'projects': [_project('p_1', 'Atlas', sessions: 4)],
    });
    rpc.answers['projects.delete'] = <String, dynamic>{'projects': []};
    await tester.pumpWidget(workHost(HmProjectsPage(source: source())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Atlas'));
    await tester.pumpAndSettle();
    expect(find.text('feature-x'), findsOneWidget);
    expect(find.text('Plan the launch'), findsOneWidget);

    dash.on(_tree, 200, {'projects': []});
    await tester.tap(find.bySemanticsLabel('Project actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete Project'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'The project is removed from Projects. Its conversations and files stay on the server.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(TextButton, 'Delete Project'));
    await tester.pumpAndSettle();

    expect(rpc.paramsOf('projects.delete').single, {
      'id': 'p_1',
      'profile': 'atlas',
    });
    expect(find.text('No projects yet'), findsOneWidget);
  });

  testWidgets('an empty project says where its chats will come from', (
    tester,
  ) async {
    dash.on(_tree, 200, {
      'projects': [_project('p_1', 'Atlas')],
    });
    await tester.pumpWidget(workHost(HmProjectsPage(source: source())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        "Conversations started in this project's folder will appear here.",
      ),
      findsOneWidget,
    );
  });
}
