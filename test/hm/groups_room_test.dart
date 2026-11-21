import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/features/groups/group_room_controller.dart';
import 'package:hermes_android/hm/features/groups/groups_api.dart';
import 'package:hermes_android/hm/features/groups/hm_groups.dart';

import 'groups_fakes.dart';

Future<HmGroupRoomController> pumpRoom(
  WidgetTester tester,
  FakeGroupsHost host_,
) async {
  final controller = HmGroupRoomController(
    host_.api,
    HmGroupRoom.fromJson(roomJson()),
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    host(HmGroupRoomScreen(controller: controller, bots: null)),
  );
  await controller.load();
  await tester.pump();
  return controller;
}

void main() {
  testWidgets('loaded room labels each reply with its bot', (tester) async {
    final h = FakeGroupsHost()
      ..on('groups.state', stateJson())
      ..on(
        'groups.log',
        page([
          event(1, 'room.created', payload: const {}),
          event(2, 'message.user', text: 'Compare the two plans'),
          event(
            3,
            'message.member',
            text: 'Plan A is cheaper.',
            member: 'atlas',
          ),
          event(
            4,
            'message.member',
            text: 'Plan B ships sooner.',
            member: 'default',
          ),
        ]),
      );
    await pumpRoom(tester, h);

    expect(find.text('Research Crew'), findsOneWidget);
    expect(find.text('Compare the two plans'), findsOneWidget);
    expect(find.text('Plan A is cheaper.'), findsOneWidget);
    expect(find.text('atlas'), findsOneWidget);
    expect(find.text('Hermes'), findsOneWidget);
    expect(h.paramsOf('groups.log').single['since_seq'], 0);
  });

  testWidgets('empty room shows the group and its members', (tester) async {
    final h = FakeGroupsHost()
      ..on('groups.state', stateJson())
      ..on('groups.log', page(const []));
    await pumpRoom(tester, h);
    expect(find.text('Group Chat'), findsOneWidget);
    expect(find.text('Hermes, atlas'), findsOneWidget);
  });

  testWidgets('a log gap shows the official error and Reload replays', (
    tester,
  ) async {
    var gap = true;
    final h = FakeGroupsHost()..on('groups.state', stateJson());
    h.handlers['groups.log'] = (_) async => gap
        ? page([
            event(1, 'message.user', text: 'hi'),
            event(3, 'message.user', text: 'skipped'),
          ])
        : page([event(1, 'message.user', text: 'hi')]);
    await pumpRoom(tester, h);
    expect(find.text(HmGroupText.gap), findsOneWidget);
    expect(find.text('skipped'), findsNothing);

    gap = false;
    await tester.tap(find.text('Reload'));
    await tester.pump();
    await tester.pump();
    expect(find.text(HmGroupText.gap), findsNothing);
    expect(find.text('hi'), findsOneWidget);
    expect(h.paramsOf('groups.log').last['since_seq'], 0);
  });

  testWidgets('a changed seq or epoch is a conflict', (tester) async {
    final h = FakeGroupsHost()..on('groups.state', stateJson());
    h.on('groups.log', page([event(1, 'message.user', text: 'hi')]));
    final c = await pumpRoom(tester, h);
    expect(c.phase, HmRoomPhase.loaded);

    h.on('groups.log', page(const [], since: 1, epoch: 2));
    await c.sync();
    await tester.pump();
    expect(find.text(HmGroupText.authorityChanged), findsOneWidget);
  });

  testWidgets('host failure shows the error state', (tester) async {
    final h = FakeGroupsHost(); // no groups.state handler → refused
    await pumpRoom(tester, h);
    expect(find.text('Reload'), findsOneWidget);
    expect(find.textContaining('unknown method'), findsOneWidget);
  });

  testWidgets('send posts the typed text with a retry key', (tester) async {
    final h = FakeGroupsHost()..on('groups.state', stateJson());
    var events = <Map<String, dynamic>>[];
    h.handlers['groups.log'] = (p) async {
      final since = p['since_seq'] as int;
      return page(
        events.where((e) => (e['seq'] as int) > since).toList(),
        since: since,
      );
    };
    h.handlers['groups.send'] = (p) async {
      final e = event(1, 'message.user', text: 'Hello team');
      events = [e];
      return {'event': e, 'accepted': true, 'driver_started': true};
    };
    await pumpRoom(tester, h);

    await tester.enterText(find.byType(TextField), 'Hello team');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Send'));
    await tester.pump();
    await tester.pump();

    final sent = h.paramsOf('groups.send').single;
    expect(sent['room_id'], 'r1');
    expect(sent['payload'], {'text': 'Hello team', 'thread_id': 'id-1'});
    expect(sent['event_id'], 'id-1');
    expect(find.text('Hello team'), findsOneWidget);
  });

  testWidgets('a refused send stays with Retry and resends the same id', (
    tester,
  ) async {
    final h = FakeGroupsHost()
      ..on('groups.state', stateJson())
      ..on('groups.log', page(const []));
    await pumpRoom(tester, h);

    await tester.enterText(find.byType(TextField), 'Ping');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Send'));
    await tester.pump();
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    final sends = h.paramsOf('groups.send');
    expect(sends, hasLength(2));
    expect(sends[1]['event_id'], sends[0]['event_id']);
  });

  testWidgets('while a bot works, Stop cancels the room', (tester) async {
    final h = FakeGroupsHost()
      ..on(
        'groups.state',
        stateJson(
          working: true,
          activity: [
            {'member_id': 'atlas', 'status': 'running'},
          ],
        ),
      )
      ..on('groups.log', page(const []))
      ..on('groups.stop', {'cancelled': 1});
    await pumpRoom(tester, h);
    expect(find.text('atlas · Working…'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Stop'));
    await tester.pump();
    expect(h.paramsOf('groups.stop').single['room_id'], 'r1');
  });

  testWidgets('a pending approval answers groups.approve', (tester) async {
    final h = FakeGroupsHost()
      ..on(
        'groups.state',
        stateJson(
          working: true,
          pending: [
            {
              'kind': 'approval',
              'member_id': 'atlas',
              'task_id': 't1',
              'execution_generation': 2,
              'request_id': 'q1',
              'description': 'rm -rf build',
            },
          ],
        ),
      )
      ..on('groups.log', page(const []))
      ..on('groups.approve', {'approved': true});
    await pumpRoom(tester, h);
    expect(find.text('rm -rf build'), findsOneWidget);
    await tester.tap(find.text('Allow once'));
    await tester.pump();
    final p = h.paramsOf('groups.approve').single;
    expect(p['choice'], 'once');
    expect(p['request_id'], 'q1');
    expect(p['execution_generation'], 2);
  });
}
