// Group chats on the host: `/api/ws` JSON-RPC `groups.*` (hermes-agent
// tui_gateway/methods_groups.py). Typed shapes are parsed here, at the wire
// boundary, so the screens never read raw maps.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../core/services/ws_client.dart';

/// One JSON-RPC call: method and params in, `result` out. Throws
/// [JsonRpcError] when the host refuses, anything else when the call is lost.
typedef HmGroupsRpc =
    Future<Map<String, dynamic>> Function(
      String method,
      Map<String, dynamic> params,
    );

/// The official app's words for each group failure.
abstract final class HmGroupText {
  static const checking = 'Checking group support…';
  static const connectFirst = 'Connect this server before creating a group.';
  static const unsupported =
      'This Hermes install does not host group rooms. Update the gateway, or pick a single agent to chat with.';
  static const uncheckable =
      'Whether this Hermes install hosts group rooms could not be checked.';
  static const noDriver =
      'This install needs a running group driver with text support.';
  static const couldNotOpen = "Couldn't open the group";
  static const gap = 'Group log has a gap. Reload the room history.';
  static const conflictSeq =
      'Conflicting group event sequence. Reload the room history.';
  static const conflictId =
      'Conflicting group event ID. Reload the room history.';
  static const authorityChanged =
      'Group authority changed. Reload the room history.';
  static const outsidePage =
      'Hermes returned events outside the requested group log page.';
  static const badCursor = 'Hermes returned an invalid group log cursor.';
  static const otherGroup = 'Hermes returned a different group.';
  static const sendTimedOut =
      'Send timed out. Retry the same group and message to check its outcome.';
  static const driverNotStarted =
      'Message saved, but the group driver did not start.';
  static const notSent = 'Message not sent';
  static const stopGone = 'The group is no longer available to stop.';
  static const changeGone = 'This group is no longer available to change.';
  static const approvalRefused =
      'The group did not accept the approval response.';
  static const approvalTimedOut =
      'The approval response timed out. Refresh the group to check its activity.';
  static const giveName = 'Give this group a name.';
  static const renamed = 'Group conversation renamed';
  static const deleted = 'Group conversation deleted';
  static const disbandTitle = 'Disband group?';
  static const disbandBody =
      'Ends the group for every member. This cannot be undone.';
  static const disband = 'Disband group';
  static const membersMustBeLocal =
      'Group members must belong to this install.';
  static const directoryTimedOut = 'Group directory timed out.';
}

/// What `groups.capabilities` says this host can do.
@immutable
class HmGroupCapabilities {
  const HmGroupCapabilities({
    required this.driver,
    required this.methods,
    required this.maxLogLimit,
  });

  /// True when the host's room worker is running (rooms can answer).
  final bool driver;
  final Set<String> methods;
  final int maxLogLimit;

  bool offers(String method) => methods.contains(method);

  /// Groups work here: rooms can be created and their worker runs.
  bool get canCreate => offers('groups.create') && driver;

  factory HmGroupCapabilities.fromJson(Map<String, dynamic> j) =>
      HmGroupCapabilities(
        driver: j['driver'] == true,
        methods: {
          for (final m in (j['methods'] as List? ?? const [])) m.toString(),
        },
        maxLogLimit: j['max_log_limit'] is int
            ? j['max_log_limit'] as int
            : 500,
      );
}

/// One seat in a room: a bot (host profile) under a mention handle.
@immutable
class HmGroupMember {
  const HmGroupMember({
    required this.memberId,
    required this.profile,
    required this.handle,
    this.displayName = '',
  });

  final String memberId;
  final String profile;
  final String handle;
  final String displayName;

  Map<String, dynamic> toJson() => {
    'member_id': memberId,
    'profile': profile,
    'handle': handle,
    'target': {'kind': 'local', 'profile': profile},
    if (displayName.isNotEmpty) 'display_name': displayName,
  };

  factory HmGroupMember.fromJson(Map<String, dynamic> j) {
    final profile = (j['profile'] ?? '').toString();
    return HmGroupMember(
      memberId: (j['member_id'] ?? profile).toString(),
      profile: profile,
      handle: (j['handle'] ?? profile).toString(),
      displayName: (j['display_name'] ?? '').toString(),
    );
  }
}

/// A hosted room as `groups.list` / `groups.state` / `groups.create` return it.
@immutable
class HmGroupRoom {
  const HmGroupRoom({
    required this.roomId,
    required this.name,
    required this.members,
    required this.authorityGatewayId,
    required this.authorityEpoch,
    required this.updatedAt,
    this.latestSeq,
    this.disbanded = false,
  });

  final String roomId;
  final String name;
  final List<HmGroupMember> members;
  final String authorityGatewayId;
  final int authorityEpoch;

  /// Seconds since the epoch.
  final double updatedAt;
  final int? latestSeq;
  final bool disbanded;

  HmGroupRoom copyWith({String? name}) => HmGroupRoom(
    roomId: roomId,
    name: name ?? this.name,
    members: members,
    authorityGatewayId: authorityGatewayId,
    authorityEpoch: authorityEpoch,
    updatedAt: updatedAt,
    latestSeq: latestSeq,
    disbanded: disbanded,
  );

  factory HmGroupRoom.fromJson(Map<String, dynamic> j) {
    final id = (j['room_id'] ?? '').toString();
    if (id.isEmpty) {
      throw const HmGroupFailure(
        'The group directory returned an empty room ID.',
      );
    }
    return HmGroupRoom(
      roomId: id,
      name: (j['name'] ?? '').toString(),
      members: [
        for (final m in (j['members'] as List? ?? const []).whereType<Map>())
          HmGroupMember.fromJson(Map<String, dynamic>.from(m)),
      ],
      authorityGatewayId: (j['authority_gateway_id'] ?? '').toString(),
      authorityEpoch: _int(j['authority_epoch']) ?? 1,
      updatedAt: _double(j['updated_at']),
      latestSeq: _int(j['latest_seq']),
      disbanded: j['disbanded_at'] != null,
    );
  }
}

/// One room-log entry. [seq] is the room's own, contiguous from 1.
@immutable
class HmGroupEvent {
  const HmGroupEvent({
    required this.seq,
    required this.eventId,
    required this.kind,
    required this.actorKind,
    required this.actorId,
    required this.payload,
    required this.createdAt,
    this.actorName = '',
    this.actorProfile = '',
  });

  final int seq;
  final String eventId;
  final String kind;
  final String actorKind;
  final String actorId;
  final String actorName;
  final String actorProfile;
  final Map<String, dynamic> payload;
  final double createdAt;

  String get text => (payload['text'] ?? '').toString();

  /// The member a member event or turn outcome belongs to.
  String get memberId =>
      (payload['member_id'] ?? (actorKind == 'member' ? actorId : ''))
          .toString();

  factory HmGroupEvent.fromJson(Map<String, dynamic> j) {
    final seq = _int(j['seq']);
    if (seq == null || seq < 1) {
      throw const HmGroupFailure(HmGroupText.badCursor);
    }
    final actor = j['actor'] is Map
        ? Map<String, dynamic>.from(j['actor'] as Map)
        : const <String, dynamic>{};
    return HmGroupEvent(
      seq: seq,
      eventId: (j['event_id'] ?? '').toString(),
      kind: (j['kind'] ?? '').toString(),
      actorKind: (actor['kind'] ?? '').toString(),
      actorId: (actor['id'] ?? '').toString(),
      actorName: (actor['display_name'] ?? '').toString(),
      actorProfile: (actor['profile'] ?? '').toString(),
      payload: j['payload'] is Map
          ? Map<String, dynamic>.from(j['payload'] as Map)
          : const {},
      createdAt: _double(j['created_at']),
    );
  }
}

/// One `groups.log` page.
@immutable
class HmGroupLogPage {
  const HmGroupLogPage({
    required this.events,
    required this.cursor,
    required this.latestSeq,
    required this.hasMore,
    required this.authorityEpoch,
  });

  final List<HmGroupEvent> events;
  final int cursor;
  final int latestSeq;
  final bool hasMore;
  final int? authorityEpoch;

  factory HmGroupLogPage.fromJson(Map<String, dynamic> j) {
    final authority = j['authority'] is Map ? j['authority'] as Map : const {};
    final cursor = _int(j['cursor']);
    final latest = _int(j['latest_seq']);
    if (cursor == null || latest == null || cursor > latest) {
      throw const HmGroupFailure(HmGroupText.badCursor);
    }
    return HmGroupLogPage(
      events: [
        for (final e in (j['events'] as List? ?? const []).whereType<Map>())
          HmGroupEvent.fromJson(Map<String, dynamic>.from(e)),
      ],
      cursor: cursor,
      latestSeq: latest,
      hasMore: j['has_more'] == true,
      authorityEpoch: _int(authority['epoch']),
    );
  }
}

/// A member's live turn, from `groups.state.driver_status.member_activity`.
@immutable
class HmGroupActivity {
  const HmGroupActivity({required this.memberId, required this.status});
  final String memberId;
  final String status;
}

/// An approval a member is waiting on, from `driver_status.pending_actions`.
@immutable
class HmGroupApproval {
  const HmGroupApproval({
    required this.memberId,
    required this.taskId,
    required this.executionGeneration,
    required this.requestId,
    required this.description,
  });

  final String memberId;
  final String taskId;
  final int executionGeneration;
  final String requestId;
  final String description;

  static HmGroupApproval? tryParse(Map<String, dynamic> j) {
    final requestId = (j['request_id'] ?? '').toString();
    final taskId = (j['task_id'] ?? '').toString();
    if (requestId.isEmpty || taskId.isEmpty) return null;
    final kind = (j['kind'] ?? 'approval').toString();
    if (kind != 'approval') return null;
    final described = [j['description'], j['command'], j['title'], j['text']]
        .map((v) => (v ?? '').toString().trim())
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');
    return HmGroupApproval(
      memberId: (j['member_id'] ?? '').toString(),
      taskId: taskId,
      executionGeneration: _int(j['execution_generation']) ?? 0,
      requestId: requestId,
      description: described,
    );
  }
}

/// `groups.state`: the room and, for a live room, its driver status.
@immutable
class HmGroupState {
  const HmGroupState({
    required this.room,
    required this.working,
    required this.activity,
    required this.approvals,
    this.lastError,
  });

  final HmGroupRoom room;
  final bool working;
  final List<HmGroupActivity> activity;
  final List<HmGroupApproval> approvals;
  final String? lastError;

  factory HmGroupState.fromJson(Map<String, dynamic> j) {
    final roomJson = j['room'];
    if (roomJson is! Map) throw const HmGroupFailure(HmGroupText.couldNotOpen);
    final status = j['driver_status'] is Map
        ? Map<String, dynamic>.from(j['driver_status'] as Map)
        : const <String, dynamic>{};
    final activity = [
      for (final a
          in (status['member_activity'] as List? ?? const []).whereType<Map>())
        HmGroupActivity(
          memberId: (a['member_id'] ?? '').toString(),
          status: (a['status'] ?? '').toString(),
        ),
    ];
    final lastError = status['last_error'];
    return HmGroupState(
      room: HmGroupRoom.fromJson(Map<String, dynamic>.from(roomJson)),
      working: status['working'] == true || activity.isNotEmpty,
      activity: activity,
      approvals: [
        for (final a
            in (status['pending_actions'] as List? ?? const [])
                .whereType<Map>())
          ?HmGroupApproval.tryParse(Map<String, dynamic>.from(a)),
      ],
      lastError: lastError is String && lastError.trim().isNotEmpty
          ? lastError.trim()
          : (lastError is Map ? (lastError['message'] ?? '').toString() : null),
    );
  }
}

/// A failure already worded for the user.
class HmGroupFailure implements Exception {
  const HmGroupFailure(this.message, {this.admitted});
  final String message;

  /// False when the host proved nothing of the request was kept.
  final bool? admitted;

  @override
  String toString() => message;
}

/// The `groups.*` surface the screens use.
class HmGroupsApi {
  HmGroupsApi(this.rpc, {String Function()? newId})
    : _newId = newId ?? _randomId;

  final HmGroupsRpc rpc;
  final String Function() _newId;

  String newId() => _newId();

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic> params,
  ) async {
    try {
      return await rpc(method, params);
    } on JsonRpcError catch (e) {
      throw HmGroupFailure(
        e.message.trim().isEmpty ? HmGroupText.couldNotOpen : e.message,
        admitted: e.data['admitted'] == false ? false : null,
      );
    }
  }

  /// `groups.capabilities`, worded: unsupported host, uncheckable, or the caps.
  Future<HmGroupCapabilities> capabilities() async {
    try {
      final caps = HmGroupCapabilities.fromJson(
        await rpc('groups.capabilities', const {}),
      );
      if (!caps.offers('groups.create') || !caps.offers('groups.log')) {
        throw const HmGroupFailure(HmGroupText.unsupported);
      }
      return caps;
    } on HmGroupFailure {
      rethrow;
    } on JsonRpcError catch (e) {
      // -32601: the host has no such method (an older gateway).
      if (e.code == -32601 || e.message.contains('unknown method')) {
        throw const HmGroupFailure(HmGroupText.unsupported);
      }
      throw const HmGroupFailure(HmGroupText.uncheckable);
    } on StateError {
      throw const HmGroupFailure(HmGroupText.connectFirst);
    } catch (_) {
      throw const HmGroupFailure(HmGroupText.uncheckable);
    }
  }

  /// Every live room, all pages.
  Future<List<HmGroupRoom>> list() async {
    final rooms = <HmGroupRoom>[];
    var offset = 0;
    for (var page = 0; page < 20; page++) {
      final r = await _call('groups.list', {'limit': 100, 'offset': offset});
      rooms.addAll([
        for (final m in (r['rooms'] as List? ?? const []).whereType<Map>())
          HmGroupRoom.fromJson(Map<String, dynamic>.from(m)),
      ]);
      final next = r['next_offset'];
      if (next == null) break;
      if (next is! int || next <= offset) {
        throw const HmGroupFailure(
          'The group directory returned an invalid next page.',
        );
      }
      offset = next;
    }
    return rooms;
  }

  Future<HmGroupRoom> create({
    required String roomId,
    required String name,
    required List<HmGroupMember> members,
  }) async {
    final r = await _call('groups.create', {
      'room_id': roomId,
      'name': name,
      'members': [for (final m in members) m.toJson()],
    });
    final room = r['room'];
    if (room is! Map) throw const HmGroupFailure(HmGroupText.otherGroup);
    final parsed = HmGroupRoom.fromJson(Map<String, dynamic>.from(room));
    if (parsed.roomId != roomId) {
      throw const HmGroupFailure('Hermes created a different group.');
    }
    return parsed;
  }

  Future<HmGroupState> state(String roomId) async {
    final s = HmGroupState.fromJson(
      await _call('groups.state', {'room_id': roomId}),
    );
    if (s.room.roomId != roomId) {
      throw const HmGroupFailure(HmGroupText.otherGroup);
    }
    return s;
  }

  Future<HmGroupLogPage> log(
    String roomId, {
    required int sinceSeq,
    int limit = 200,
  }) async => HmGroupLogPage.fromJson(
    await _call('groups.log', {
      'room_id': roomId,
      'since_seq': sinceSeq,
      'limit': limit,
    }),
  );

  /// Sends one user message. [eventId] is the retry key: resending the same
  /// id never posts twice. Returns the committed event.
  Future<({HmGroupEvent? event, bool driverStarted})> send(
    String roomId, {
    required String eventId,
    required String text,
  }) async {
    final Map<String, dynamic> r;
    try {
      r = await _call('groups.send', {
        'room_id': roomId,
        'event_id': eventId,
        'payload': {'text': text, 'thread_id': eventId},
      });
    } on TimeoutException {
      throw const HmGroupFailure(HmGroupText.sendTimedOut);
    }
    final e = r['event'];
    return (
      event: e is Map
          ? HmGroupEvent.fromJson(Map<String, dynamic>.from(e))
          : null,
      driverStarted: r['driver_started'] != false,
    );
  }

  Future<HmGroupRoom> rename(String roomId, String name) async {
    final r = await _call('groups.rename', {
      'room_id': roomId,
      'event_id': newId(),
      'name': name,
    });
    final room = r['room'];
    if (room is! Map) throw const HmGroupFailure(HmGroupText.changeGone);
    return HmGroupRoom.fromJson(Map<String, dynamic>.from(room));
  }

  Future<int> stop(String roomId) async {
    final r = await _call('groups.stop', {
      'room_id': roomId,
      'cancel_id': newId(),
    });
    return _int(r['cancelled']) ?? 0;
  }

  Future<void> approve(
    String roomId,
    HmGroupApproval a, {
    required bool allow,
  }) async {
    try {
      await _call('groups.approve', {
        'room_id': roomId,
        'member_id': a.memberId,
        'task_id': a.taskId,
        'execution_generation': a.executionGeneration,
        'request_id': a.requestId,
        'choice': allow ? 'once' : 'deny',
      });
    } on TimeoutException {
      throw const HmGroupFailure(HmGroupText.approvalTimedOut);
    } on HmGroupFailure {
      throw const HmGroupFailure(HmGroupText.approvalRefused);
    }
  }

  /// True only when the host returns this room's tombstone.
  Future<bool> disband(String roomId) async {
    final r = await _call('groups.disband', {
      'room_id': roomId,
      'cancel_id': newId(),
    });
    final t = r['tombstone'];
    return t is Map && t['room_id'] == roomId && t['disbanded_at'] is num;
  }
}

String _randomId() => const Uuid().v4();

int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : null);
double _double(Object? v) => v is num ? v.toDouble() : 0;
