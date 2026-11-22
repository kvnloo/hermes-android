// Live Mode lanes (HA-035): extra agents attached to the current thread's
// live call, each shown as an orb orbiting the bot's orb, each able to take
// the next spoken turn. Same meaning as Dash's z0live lanes (DA-024/DA-077):
// a fast lane, a large lane and a council lane, each with a status (working,
// idle, error), what it is doing now, and what it last handed back.
//
// The Hermes gateway has no multi-lane RPC (its session API is session.*,
// prompt.submit and model.options), so lanes run behind the [LiveLanes] seam
// and the only driver today is [FixtureLiveLanes]: scripted lanes that answer
// locally and can replay Dash's broker lane records. Production builds attach
// no lanes unless built with --dart-define=HERMES_LIVE_LANES_FIXTURE=true.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Builds with this define offer the fixture lanes on every Live call.
const bool kLiveLanesFixture = bool.fromEnvironment(
  'HERMES_LIVE_LANES_FIXTURE',
);

enum LiveLaneStatus { working, idle, error }

/// What a lane last handed back to the thread.
@immutable
class LiveLaneHandoff {
  const LiveLaneHandoff({
    required this.summary,
    required this.result,
    required this.at,
  });
  final String summary;
  final String result;
  final DateTime at;
}

/// A lane the call could attach.
@immutable
class LiveLaneOption {
  const LiveLaneOption({required this.id, required this.name, this.model});
  final String id;
  final String name;
  final String? model;
}

/// One attached lane.
@immutable
class LiveLane {
  const LiveLane({
    required this.id,
    required this.name,
    required this.status,
    required this.since,
    this.model,
    this.step,
    this.handoff,
  });

  final String id;
  final String name;
  final String? model;
  final LiveLaneStatus status;

  /// What the lane is doing now (working), or its last error (error).
  final String? step;

  /// When the current status began.
  final DateTime since;
  final LiveLaneHandoff? handoff;

  LiveLane copyWith({
    String? name,
    String? model,
    LiveLaneStatus? status,
    String? step,
    bool clearStep = false,
    DateTime? since,
    LiveLaneHandoff? handoff,
  }) => LiveLane(
    id: id,
    name: name ?? this.name,
    model: model ?? this.model,
    status: status ?? this.status,
    step: clearStep ? null : (step ?? this.step),
    since: since ?? this.since,
    handoff: handoff ?? this.handoff,
  );
}

// ── Lane records (Dash's broker format) ─────────────────────────────────────

/// At most this many lanes attach to one call (as in Dash).
const int kLiveLanesMax = 8;

final RegExp _laneId = RegExp(r'^[A-Za-z0-9][\w.:-]{0,63}$');

String? _clip(Object? value, int max) {
  if (value is! String) return null;
  final flat = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return null;
  return flat.length > max ? '${flat.substring(0, max - 1)}…' : flat;
}

DateTime? _time(Object? ts) {
  if (ts is num) {
    return DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
  }
  if (ts is String) return DateTime.tryParse(ts);
  return null;
}

/// Applies one lane record to [lanes] and returns the new list (oldest
/// attachment first). Records:
///   {"type":"lane_attached","ts":…,"data":{"lane":"fast","name":"Fast","model":"…"}}
///   {"type":"lane_step","ts":…,"data":{"lane":"fast","step":"Reading the diff"}}
///   {"type":"lane_handoff","ts":…,"data":{"lane":"fast","summary":"…","result":"…"}}
///   {"type":"lane_error","ts":…,"data":{"lane":"fast","message":"Rate limited"}}
///   {"type":"lane_detached","ts":…,"data":{"lane":"fast"}}
/// Anything else, or a malformed record, leaves [lanes] as is. A step or
/// handoff for a lane that never attached attaches it under its id.
List<LiveLane> applyLiveLaneRecord(List<LiveLane> lanes, Object? record) {
  if (record is! Map) return lanes;
  final type = record['type'];
  final at = _time(record['ts']);
  final data = record['data'] is Map ? record['data'] as Map : const {};
  final id = data['lane'];
  if (type is! String || !type.startsWith('lane_') || at == null) return lanes;
  if (id is! String || !_laneId.hasMatch(id)) return lanes;
  if (type == 'lane_detached') return [...lanes.where((l) => l.id != id)];
  final index = lanes.indexWhere((l) => l.id == id);
  if (index < 0 && lanes.length >= kLiveLanesMax) return lanes;
  final base = index >= 0
      ? lanes[index]
      : LiveLane(id: id, name: id, status: LiveLaneStatus.idle, since: at);
  final LiveLane next;
  switch (type) {
    case 'lane_attached':
      next = base.copyWith(
        name: _clip(data['name'], 40),
        model: _clip(data['model'], 80),
      );
    case 'lane_step':
      final step = _clip(data['step'], 160);
      if (step == null) return lanes;
      final same = base.status == LiveLaneStatus.working && base.step == step;
      next = base.copyWith(
        status: LiveLaneStatus.working,
        step: step,
        since: same ? base.since : at,
      );
    case 'lane_handoff':
      final raw = data['result'];
      final result = raw is String ? raw.trim() : '';
      final summary =
          _clip(data['summary'], 280) ??
          (result.isEmpty ? null : _clip(result, 280));
      if (summary == null) return lanes;
      next = base.copyWith(
        status: LiveLaneStatus.idle,
        clearStep: true,
        since: at,
        handoff: LiveLaneHandoff(
          summary: summary,
          result: result.isEmpty ? summary : result,
          at: at,
        ),
      );
    case 'lane_error':
      next = base.copyWith(
        status: LiveLaneStatus.error,
        step: _clip(data['message'], 160) ?? 'Lane failed',
        since: at,
      );
    default:
      return lanes;
  }
  return index >= 0
      ? [for (var i = 0; i < lanes.length; i++) i == index ? next : lanes[i]]
      : [...lanes, next];
}

/// Folds a JSONL tail of lane records (other lines are skipped).
List<LiveLane> foldLiveLanes(String jsonl, [List<LiveLane> from = const []]) {
  var lanes = from;
  for (final row in const LineSplitter().convert(jsonl)) {
    if (row.trim().isEmpty) continue;
    try {
      lanes = applyLiveLaneRecord(lanes, jsonDecode(row));
    } on FormatException {
      continue;
    }
  }
  return lanes;
}

/// What one lane orb says under its name.
String liveLaneNow(LiveLane lane) => switch (lane.status) {
  LiveLaneStatus.working => lane.step ?? 'Working',
  LiveLaneStatus.error => 'Failed · ${lane.step ?? 'no detail'}',
  LiveLaneStatus.idle =>
    lane.handoff != null ? 'Idle · handed back' : 'Idle · attached',
};

/// One line for all lanes: counts, then the lane that changed last.
String liveLaneSummary(List<LiveLane> lanes) {
  if (lanes.isEmpty) return 'No lanes attached';
  final working = lanes.where((l) => l.status == LiveLaneStatus.working).length;
  final failed = lanes.where((l) => l.status == LiveLaneStatus.error).length;
  final parts = [
    '${lanes.length} lane${lanes.length == 1 ? '' : 's'}',
    working > 0 ? '$working working' : 'all idle',
    if (failed > 0) '$failed failed',
  ];
  final latest = lanes.reduce((a, b) => b.since.isAfter(a.since) ? b : a);
  parts.add(switch (latest.status) {
    LiveLaneStatus.working => '${latest.name}: ${latest.step ?? 'working'}',
    LiveLaneStatus.error => '${latest.name} failed',
    LiveLaneStatus.idle =>
      latest.handoff != null
          ? '${latest.name} handed back'
          : '${latest.name} attached',
  });
  return parts.join(' · ');
}

// ── Seam ────────────────────────────────────────────────────────────────────

/// The lanes attached to one thread's live call.
abstract interface class LiveLanes implements Listenable {
  /// The lanes this host can attach, in orbit order.
  List<LiveLaneOption> get options;

  /// The attached lanes, oldest attachment first.
  List<LiveLane> get lanes;

  Future<void> attach(String id);
  Future<void> detach(String id);

  /// Runs one turn on lane [id] and returns what it handed back.
  Future<String> ask(String id, String text);

  void dispose();
}

/// The standard fast / large / council set.
const List<LiveLaneOption> kStandardLiveLanes = [
  LiveLaneOption(id: 'fast', name: 'Fast', model: 'fixture · fast'),
  LiveLaneOption(id: 'large', name: 'Large', model: 'fixture · large'),
  LiveLaneOption(id: 'council', name: 'Council', model: 'fixture · 3 seats'),
];

/// Scripted lanes, no host: each turn steps, waits its [latency], then hands
/// back a reply from [reply]. Every change goes through the same lane
/// records Dash's broker writes, so [replay] can feed it a real tail.
class FixtureLiveLanes extends ChangeNotifier implements LiveLanes {
  FixtureLiveLanes({
    this.options = kStandardLiveLanes,
    Map<String, Duration>? latency,
    String Function(String lane, String text)? reply,
    DateTime Function()? clock,
    List<String> attached = const [],
  }) : latency =
           latency ??
           const {
             'fast': Duration(milliseconds: 600),
             'large': Duration(seconds: 2),
             'council': Duration(seconds: 3),
           },
       reply = reply ?? _fixtureReply,
       _clock = clock ?? DateTime.now {
    for (final id in attached) {
      _attachNow(id);
    }
  }

  @override
  final List<LiveLaneOption> options;
  final Map<String, Duration> latency;
  final String Function(String lane, String text) reply;
  final DateTime Function() _clock;

  List<LiveLane> _lanes = const [];
  final Map<String, int> _turns = {};
  bool _disposed = false;

  /// Every turn routed to a lane, in order: (lane, text).
  final List<(String, String)> asked = [];

  @override
  List<LiveLane> get lanes => List.unmodifiable(_lanes);

  bool isAttached(String id) => _lanes.any((l) => l.id == id);

  void _record(
    String type,
    String lane, [
    Map<String, Object?> data = const {},
  ]) {
    if (_disposed) return;
    _lanes = applyLiveLaneRecord(_lanes, {
      'type': type,
      'ts': _clock().millisecondsSinceEpoch / 1000,
      'data': {'lane': lane, ...data},
    });
    notifyListeners();
  }

  void _attachNow(String id) {
    final option = options.where((o) => o.id == id).firstOrNull;
    _record('lane_attached', id, {
      'name': option?.name ?? id,
      if (option?.model != null) 'model': option!.model,
    });
  }

  /// Applies a JSONL tail of Dash lane records.
  void replay(String jsonl) {
    if (_disposed) return;
    _lanes = foldLiveLanes(jsonl, _lanes);
    notifyListeners();
  }

  @override
  Future<void> attach(String id) async {
    if (!isAttached(id)) _attachNow(id);
  }

  @override
  Future<void> detach(String id) async {
    _turns[id] = (_turns[id] ?? 0) + 1;
    if (isAttached(id)) _record('lane_detached', id);
  }

  @override
  Future<String> ask(String id, String text) async {
    if (!isAttached(id)) throw StateError('Lane $id is not attached.');
    asked.add((id, text));
    final turn = _turns[id] = (_turns[id] ?? 0) + 1;
    final said = _clip(text, 60) ?? '';
    _record('lane_step', id, {
      'step': id == 'council' ? 'Polling 3 seats' : 'Working on “$said”',
    });
    await Future<void>.delayed(latency[id] ?? const Duration(seconds: 1));
    if (_disposed || _turns[id] != turn || !isAttached(id)) return '';
    final answer = reply(id, text);
    _record('lane_handoff', id, {'summary': answer, 'result': answer});
    return answer;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

String _fixtureReply(String lane, String text) {
  final said = _clip(text, 60) ?? '';
  return switch (lane) {
    'fast' => 'Quick take on “$said”: yes, go ahead.',
    'large' =>
      'Considered answer on “$said”: it holds up; check the edge cases first.',
    'council' =>
      'Council, 2 of 3 agree on “$said”: go ahead; one seat wants tests first.',
    _ => 'Lane $lane on “$said”: done.',
  };
}
