import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/features/groups/group_room_controller.dart';
import 'package:hermes_android/hm/features/groups/groups_api.dart';
import 'package:hermes_android/hm/features/groups/hm_groups.dart';

import 'groups_fakes.dart';

/// Avatars idle-animate forever, so pump a bounded stretch instead of settling.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const caps = {
  'protocol_version': 2,
  'driver': true,
  'methods': [
    'groups.capabilities',
    'groups.list',
    'groups.create',
    'groups.state',
    'groups.send',
    'groups.rename',
    'groups.log',
    'groups.disband',
    'groups.stop',
    'groups.approve',
  ],
  'max_log_limit': 500,
};

Future<HmGroupsDirectory> pumpSheet(
  WidgetTester tester,
  FakeGroupsHost h, {
  List<Object?>? popped,
}) async {
  final dir = HmGroupsDirectory(h.api);
  addTearDown(dir.dispose);
  await tester.pumpWidget(
    host(
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              final r = await showHmNewSessionSheet(
                context,
                testBots(),
                groups: dir,
              );
              popped?.add(r);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await settle(tester);
  return dir;
}

void main() {
  testWidgets('New Group: pick two bots, name it, create', (tester) async {
    final popped = <Object?>[];
    final h = FakeGroupsHost()
      ..on('groups.capabilities', caps)
      ..on('groups.list', {'rooms': [], 'next_offset': null});
    h.handlers['groups.create'] = (p) async => {
      'room': roomJson(id: p['room_id'] as String, name: p['name'] as String),
    };
    await pumpSheet(tester, h, popped: popped);
    expect(find.text('Start a new session'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('New group'));
    await settle(tester);
    expect(find.text('New Group'), findsOneWidget);

    final create = find.widgetWithText(FilledButton, 'Create group');
    expect(tester.widget<FilledButton>(create).onPressed, isNull);

    await tester.tap(find.text('Hermes'));
    await tester.pump();
    expect(tester.widget<FilledButton>(create).onPressed, isNull);
    await tester.tap(find.text('Atlas'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Research Crew');
    await tester.tap(create);
    await settle(tester);

    final p = h.paramsOf('groups.create').single;
    expect(p['name'], 'Research Crew');
    expect(p['room_id'], isNotEmpty);
    expect(p['members'], [
      {
        'member_id': 'default',
        'profile': 'default',
        'handle': 'default',
        'target': {'kind': 'local', 'profile': 'default'},
      },
      {
        'member_id': 'atlas',
        'profile': 'atlas',
        'handle': 'atlas',
        'target': {'kind': 'local', 'profile': 'atlas'},
      },
    ]);
    expect(popped.single, isA<HmNewGroupChat>());
  });

  testWidgets('without a name the group is named after its bots', (
    tester,
  ) async {
    final h = FakeGroupsHost()
      ..on('groups.capabilities', caps)
      ..on('groups.list', {'rooms': [], 'next_offset': null});
    h.handlers['groups.create'] = (p) async => {
      'room': roomJson(id: p['room_id'] as String),
    };
    await pumpSheet(tester, h);
    await tester.tap(find.bySemanticsLabel('New group'));
    await settle(tester);
    await tester.tap(find.text('Atlas'));
    await tester.tap(find.text('Nova'));
    await tester.pump();
    await tester.tap(find.text('Create group'));
    await settle(tester);
    expect(h.paramsOf('groups.create').single['name'], 'Atlas, Nova');
  });

  testWidgets('shows Checking group support… while checking', (tester) async {
    final gate = Completer<Map<String, dynamic>>();
    final h = FakeGroupsHost();
    h.handlers['groups.capabilities'] = (_) => gate.future;
    await pumpSheet(tester, h);
    await tester.tap(find.bySemanticsLabel('New group'));
    await tester.pump();
    expect(find.text(HmGroupText.checking), findsOneWidget);
    gate.complete(caps);
    h.on('groups.list', {'rooms': [], 'next_offset': null});
    await settle(tester);
    expect(find.text(HmGroupText.checking), findsNothing);
  });

  testWidgets('an older host says it does not host group rooms', (
    tester,
  ) async {
    final h = FakeGroupsHost(); // groups.capabilities unknown
    await pumpSheet(tester, h);
    await tester.tap(find.bySemanticsLabel('New group'));
    await settle(tester);
    expect(find.text(HmGroupText.unsupported), findsOneWidget);
    await tester.tap(find.text('Atlas'));
    await tester.tap(find.text('Nova'));
    await tester.pump();
    final create = find.widgetWithText(FilledButton, 'Create group');
    expect(tester.widget<FilledButton>(create).onPressed, isNull);
  });

  testWidgets('a host without a running driver says so', (tester) async {
    final h = FakeGroupsHost()
      ..on('groups.capabilities', {...caps, 'driver': false})
      ..on('groups.list', {'rooms': [], 'next_offset': null});
    await pumpSheet(tester, h);
    await tester.tap(find.bySemanticsLabel('New group'));
    await settle(tester);
    expect(find.text(HmGroupText.noDriver), findsOneWidget);
  });

  testWidgets('a plain tap still starts a one-bot chat', (tester) async {
    final popped = <Object?>[];
    final h = FakeGroupsHost();
    await pumpSheet(tester, h, popped: popped);
    await tester.tap(find.text('Atlas'));
    await settle(tester);
    expect((popped.single as HmNewBotChat).bot.profile, 'atlas');
  });

  group('settings', () {
    Future<HmGroupRoomController> pumpSettings(
      WidgetTester tester,
      FakeGroupsHost h,
      List<bool?> result,
    ) async {
      final c = HmGroupRoomController(h.api, HmGroupRoom.fromJson(roomJson()));
      addTearDown(c.dispose);
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => result.add(
                  await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) =>
                          HmGroupSettingsScreen(controller: c, bots: null),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await settle(tester);
      return c;
    }

    testWidgets('lists members and renames the group', (tester) async {
      final h = FakeGroupsHost()
        ..on('groups.state', stateJson(room: roomJson(name: 'Planners')))
        ..on('groups.log', page(const []));
      h.handlers['groups.rename'] = (p) async => {
        'room': roomJson(name: p['name'] as String),
      };
      await pumpSettings(tester, h, []);
      expect(find.text('Group chat settings'), findsOneWidget);
      expect(find.text('@atlas'), findsOneWidget);
      expect(find.text('Members · 2'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'Planners');
      await tester.tap(find.text('Save'));
      await settle(tester);

      final p = h.paramsOf('groups.rename').single;
      expect(p['name'], 'Planners');
      expect(p['room_id'], 'r1');
      expect(find.text(HmGroupText.renamed), findsOneWidget);
    });

    testWidgets('disband asks with the official words, then ends the group', (
      tester,
    ) async {
      final result = <bool?>[];
      final h = FakeGroupsHost()
        ..on('groups.disband', {
          'tombstone': {'room_id': 'r1', 'disbanded_at': 1700000100.0},
        });
      await pumpSettings(tester, h, result);
      await tester.tap(find.text(HmGroupText.disband));
      await settle(tester);
      expect(find.text(HmGroupText.disbandTitle), findsOneWidget);
      expect(find.text(HmGroupText.disbandBody), findsOneWidget);
      await tester.tap(find.text('Disband'));
      await settle(tester);
      expect(h.paramsOf('groups.disband').single['room_id'], 'r1');
      expect(result.single, isTrue);
    });

    testWidgets('a refused disband keeps the group and says why', (
      tester,
    ) async {
      final result = <bool?>[];
      final h = FakeGroupsHost(); // groups.disband refused
      await pumpSettings(tester, h, result);
      await tester.tap(find.text(HmGroupText.disband));
      await settle(tester);
      await tester.tap(find.text('Disband'));
      await settle(tester);
      expect(result, isEmpty);
      expect(find.text('Group chat settings'), findsOneWidget);
    });
  });
}
