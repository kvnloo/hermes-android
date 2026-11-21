// Where artifacts come from: the bot's recent sessions (or one chat), each
// transcript scanned once and kept in a small on-device index that is
// reused until the session's last activity changes.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/connection_manager.dart' show DashboardClient;
import '../../../core/services/dashboard_api_client.dart';
import 'artifact_scan.dart';

/// A session as the artifact scan needs it.
@immutable
class HmArtifactSession {
  const HmArtifactSession({
    required this.id,
    required this.title,
    required this.lastActive,
  });
  final String id;
  final String title;

  /// Seconds since the epoch; the index fingerprint.
  final double lastActive;
}

/// One page of a session's messages, oldest first.
@immutable
class HmArtifactMessagePage {
  const HmArtifactMessagePage(this.messages, {required this.limit});
  final List<Map<String, dynamic>> messages;
  final int limit;
}

abstract class HmArtifactsSource {
  /// Identifies the host + bot (+ chat) the index belongs to.
  String get owner;

  Future<List<HmArtifactSession>> sessions();

  Future<HmArtifactMessagePage> messages(
    String sessionId, {
    required int offset,
    required int limit,
  });
}

/// Recent sessions the desktop also scans.
const hmArtifactSessionLimit = 30;
const hmArtifactPageSize = 100;

/// Never walk more than this many pages of one transcript.
const _maxPages = 20;

String _title(Map<String, dynamic> s) {
  final title = (s['title'] ?? '').toString().trim();
  if (title.isNotEmpty) return title;
  final preview = (s['preview'] ?? '').toString().trim();
  return preview.isNotEmpty ? preview : 'Untitled session';
}

double _lastActive(Map<String, dynamic> s) {
  for (final k in const ['last_active', 'started_at']) {
    final v = s[k];
    if (v is num && v > 0) return v.toDouble();
  }
  return 0;
}

/// Reads a bot's sessions from its dashboard: `GET /api/sessions`,
/// `GET /api/sessions/{id}` and `GET /api/sessions/{id}/messages`.
class DashboardArtifactsSource implements HmArtifactsSource {
  DashboardArtifactsSource({
    required this.dashboard,
    required this.profile,
    this.sessionId,
  });

  final DashboardClient dashboard;
  final String? profile;

  /// Set when the screen shows one chat's artifacts.
  final String? sessionId;

  Map<String, String> get _scope => {
    if (profile != null && profile!.isNotEmpty) 'profile': profile!,
  };

  @override
  String get owner =>
      '${dashboard.baseUrl}|${profile ?? 'default'}'
      '${sessionId == null ? '' : '|$sessionId'}';

  Future<Map<String, dynamic>> _get(
    String path,
    Map<String, String> query,
  ) async {
    final res = await dashboard.apiRequest(
      'GET',
      path,
      queryParameters: {..._scope, ...query},
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw DashboardRequestException(
        res.statusCode,
        dashboardErrorMessage(res),
      );
    }
    final body = jsonDecode(res.body);
    if (body is! Map) throw const FormatException('Unexpected response');
    return Map<String, dynamic>.from(body);
  }

  @override
  Future<List<HmArtifactSession>> sessions() async {
    final id = sessionId;
    if (id != null) {
      final data = await _get('sessions/${Uri.encodeComponent(id)}', const {});
      final nested = data['session'];
      final row = nested is Map ? Map<String, dynamic>.from(nested) : data;
      return [
        HmArtifactSession(
          id: id,
          title: _title(row),
          lastActive: _lastActive(row),
        ),
      ];
    }
    final data = await _get('sessions', {
      'limit': '$hmArtifactSessionLimit',
      'offset': '0',
      'order': 'recent',
      'archived': 'exclude',
    });
    return [
      for (final row in (data['sessions'] as List? ?? const []).whereType<Map>())
        if (row['id'] != null)
          HmArtifactSession(
            id: row['id'].toString(),
            title: _title(Map<String, dynamic>.from(row)),
            lastActive: _lastActive(Map<String, dynamic>.from(row)),
          ),
    ];
  }

  @override
  Future<HmArtifactMessagePage> messages(
    String sessionId, {
    required int offset,
    required int limit,
  }) async {
    final data = await _get(
      'sessions/${Uri.encodeComponent(sessionId)}/messages',
      {
        'limit': '$limit',
        'offset': '$offset',
        'order': 'oldest',
        'include_compacted': 'true',
        'inline_images': 'false',
      },
    );
    final list = data['messages'];
    final pagination = data['pagination'];
    return HmArtifactMessagePage(
      [
        for (final m in (list is List ? list : const []).whereType<Map>())
          Map<String, dynamic>.from(m),
      ],
      // Older hosts ignore paging and send the whole transcript at once.
      limit: pagination is Map && pagination['limit'] is int
          ? pagination['limit'] as int
          : 0,
    );
  }
}

/// The on-device artifact index, one record per owner.
abstract class HmArtifactIndexStore {
  Future<String?> read(String owner);
  Future<void> write(String owner, String data);
}

class PrefsArtifactIndexStore implements HmArtifactIndexStore {
  const PrefsArtifactIndexStore();
  static const _prefix = 'hm.artifact-index.v1.';

  @override
  Future<String?> read(String owner) async =>
      (await SharedPreferences.getInstance()).getString('$_prefix$owner');

  @override
  Future<void> write(String owner, String data) async {
    await (await SharedPreferences.getInstance()).setString(
      '$_prefix$owner',
      data,
    );
  }
}

/// The largest index kept on the device.
const hmArtifactIndexMaxChars = 1500000;

sealed class HmArtifactsState {
  const HmArtifactsState();
}

class HmArtifactsLoading extends HmArtifactsState {
  const HmArtifactsLoading();
}

class HmArtifactsUnavailable extends HmArtifactsState {
  const HmArtifactsUnavailable(this.message);
  final String message;
}

class HmArtifactsLoaded extends HmArtifactsState {
  const HmArtifactsLoaded(this.artifacts, {this.skipped = 0});

  /// Newest first. Empty means the bot has produced none yet.
  final List<HmArtifact> artifacts;

  /// Sessions that could not be read this time.
  final int skipped;
}

/// Loads artifacts for one owner, reusing the index for unchanged sessions.
class HmArtifactsLoader {
  HmArtifactsLoader(this.source, {HmArtifactIndexStore? store})
    : store = store ?? const PrefsArtifactIndexStore();

  final HmArtifactsSource source;
  final HmArtifactIndexStore store;

  /// Set when the index could not be saved this time.
  String? indexProblem;

  Future<HmArtifactsState> load() async {
    final List<HmArtifactSession> sessions;
    try {
      sessions = await source.sessions();
    } catch (e) {
      return HmArtifactsUnavailable(_describe(e));
    }
    if (sessions.isEmpty) return const HmArtifactsLoaded([]);

    final index = await _readIndex();
    final next = <String, Map<String, dynamic>>{};
    final out = <HmArtifact>[];
    var failed = 0;
    Object? lastError;
    for (final s in sessions) {
      final cached = index[s.id];
      if (cached != null &&
          s.lastActive > 0 &&
          cached['la'] == s.lastActive &&
          cached['t'] == s.title &&
          cached['a'] is List) {
        final items = [
          for (final j in cached['a'] as List) ?HmArtifact.fromJson(j),
        ];
        out.addAll(items);
        next[s.id] = cached;
        continue;
      }
      try {
        final items = await _scan(s);
        out.addAll(items);
        next[s.id] = {
          'la': s.lastActive,
          't': s.title,
          'a': [for (final a in items) a.toJson()],
        };
      } catch (e) {
        failed++;
        lastError = e;
      }
    }
    if (failed == sessions.length) {
      return HmArtifactsUnavailable(_describe(lastError));
    }
    await _writeIndex(next);
    out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return HmArtifactsLoaded(out, skipped: failed);
  }

  Future<List<HmArtifact>> _scan(HmArtifactSession s) async {
    final found = <String, HmArtifact>{};
    var offset = 0;
    for (var page = 0; page < _maxPages; page++) {
      final p = await source.messages(
        s.id,
        offset: offset,
        limit: hmArtifactPageSize,
      );
      for (final a in scanArtifacts(
        sessionId: s.id,
        sessionTitle: s.title,
        messages: p.messages,
        sessionLastActive: s.lastActive,
      )) {
        found.putIfAbsent(a.id, () => a);
      }
      if (p.limit <= 0 || p.messages.isEmpty || p.messages.length < p.limit) {
        break;
      }
      offset += p.messages.length;
    }
    return found.values.toList();
  }

  Future<Map<String, Map<String, dynamic>>> _readIndex() async {
    try {
      final raw = await store.read(source.owner);
      if (raw == null) return {};
      final j = jsonDecode(raw);
      if (j is! Map || j['owner'] != source.owner || j['sessions'] is! Map) {
        return {};
      }
      return {
        for (final e in (j['sessions'] as Map).entries)
          if (e.value is Map)
            '${e.key}': Map<String, dynamic>.from(e.value as Map),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeIndex(Map<String, Map<String, dynamic>> sessions) async {
    indexProblem = null;
    final data = jsonEncode({'owner': source.owner, 'sessions': sessions});
    if (data.length > hmArtifactIndexMaxChars) {
      indexProblem = 'The artifact index is too large to keep.';
      return;
    }
    try {
      await store.write(source.owner, data);
    } catch (_) {
      indexProblem = 'Couldn’t keep the artifact index.';
    }
  }

  static String _describe(Object? e) {
    if (e is DashboardRequestException) return e.message;
    if (e is DashboardUnsupportedException) return '$e';
    final s = '$e';
    return s.startsWith('Exception: ') ? s.substring(11) : s;
  }
}
