// Fakes for the groups lane's tests: a scripted `groups.*` host.
import 'package:flutter/material.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:hermes_android/hm/features/groups/groups_api.dart';
import 'package:hermes_android/hm/hm_bots.dart';

class FakeGroupsHost {
  final calls = <(String, Map<String, dynamic>)>[];
  final handlers =
      <String, Future<Map<String, dynamic>> Function(Map<String, dynamic>)>{};
  int _ids = 0;

  HmGroupsApi get api => HmGroupsApi((method, params) async {
    calls.add((method, Map<String, dynamic>.from(params)));
    final h = handlers[method];
    if (h == null) {
      throw JsonRpcError(method, 'unknown method: $method', code: -32601);
    }
    return h(params);
  }, newId: () => 'id-${++_ids}');

  List<Map<String, dynamic>> paramsOf(String method) => [
    for (final c in calls)
      if (c.$1 == method) c.$2,
  ];

  void on(String method, Map<String, dynamic> result) =>
      handlers[method] = (_) async => result;
}

Map<String, dynamic> roomJson({
  String id = 'r1',
  String name = 'Research Crew',
  List<String> profiles = const ['default', 'atlas'],
  double updatedAt = 1700000000,
}) => {
  'room_id': id,
  'name': name,
  'members': [
    for (final p in profiles)
      {
        'member_id': p,
        'profile': p,
        'handle': p,
        'target': {'kind': 'local', 'profile': p},
      },
  ],
  'authority_gateway_id': 'gw1',
  'authority_epoch': 1,
  'revision': 1,
  'created_at': updatedAt,
  'updated_at': updatedAt,
  'latest_seq': 0,
};

Map<String, dynamic> event(
  int seq,
  String kind, {
  String? text,
  String member = '',
  Map<String, dynamic>? payload,
}) => {
  'room_id': 'r1',
  'seq': seq,
  'event_id': 'e$seq',
  'kind': kind,
  'actor': kind == 'message.user'
      ? {'kind': 'user', 'id': 'u'}
      : kind == 'message.member'
      ? {'kind': 'member', 'id': member, 'profile': member}
      : {'kind': 'gateway', 'id': 'gw1'},
  'authority_epoch': 1,
  'payload':
      payload ?? {'text': ?text, if (member.isNotEmpty) 'member_id': member},
  'created_at': 1700000000 + seq,
};

Map<String, dynamic> page(
  List<Map<String, dynamic>> events, {
  int? since,
  int epoch = 1,
}) {
  final last = events.isEmpty ? (since ?? 0) : events.last['seq'] as int;
  return {
    'events': events,
    'cursor': last,
    'latest_seq': last,
    'has_more': false,
    'authority': {'gateway_id': 'gw1', 'epoch': epoch},
  };
}

Map<String, dynamic> stateJson({
  Map<String, dynamic>? room,
  bool working = false,
  List<Map<String, dynamic>> activity = const [],
  List<Map<String, dynamic>> pending = const [],
}) => {
  'room': room ?? roomJson(),
  'change_events': true,
  'driver_status': {
    'running': true,
    'working': working,
    'member_activity': activity,
    'pending_actions': pending,
  },
};

List<HmBot> testBots() => [
  HmBot.fromJson({'name': 'default', 'is_default': true}, rank: 0),
  HmBot.fromJson({'name': 'atlas'}, rank: 1),
  HmBot.fromJson({'name': 'nova'}, rank: 2),
];

Widget host(Widget child) => MaterialApp(home: child);
