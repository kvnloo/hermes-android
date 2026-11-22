// Bots: each profile a host serves is a bot. One connection (host) can hold
// many bots; one gateway socket serves them all, scoped per call.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/models/session.dart';
import '../core/services/dashboard_api_client.dart';
import '../nextgen/data/nextgen_gateway.dart';
import 'avatar/hm_avatar.dart';
import 'features/settings/cache_store.dart';
import 'features/settings/cache_sync.dart';

@immutable
class HmBot {
  const HmBot({
    required this.profile,
    required this.isDefault,
    required this.displayName,
    required this.model,
    required this.provider,
    required this.skillCount,
    required this.character,
    this.description = '',
    this.uiMeta = const {},
  });

  /// Host profile name (`default` for the host's main profile).
  final String profile;
  final bool isDefault;
  final String displayName;
  final String model;
  final String provider;
  final int skillCount;
  final String description;
  final HmCharacterSpec character;
  final Map<String, dynamic> uiMeta;

  /// The value to send as `params['profile']`; the default profile sends none
  /// so the host keeps its own default.
  String? get scope => isDefault ? null : profile;

  /// [rank] is the profile's place among the host's profiles by name; it
  /// gives each bot without its own colour a distinct, stable tone.
  factory HmBot.fromJson(Map<String, dynamic> j, {int? rank}) {
    final name = (j['name'] ?? 'default').toString();
    final isDefault = j['is_default'] == true || name == 'default';
    final display = (j['display_name'] ?? '').toString().trim();
    final title = (j['bot_title'] ?? '').toString().trim();
    final shown = display.isNotEmpty
        ? display
        : title.isNotEmpty
        ? title
        : isDefault
        ? 'Hermes'
        : _titleCase(name);
    final meta = j['ui_meta'] is Map
        ? Map<String, dynamic>.from(j['ui_meta'] as Map)
        : <String, dynamic>{};
    return HmBot(
      profile: name,
      isDefault: isDefault,
      displayName: shown,
      model: (j['model'] ?? '').toString(),
      provider: (j['provider'] ?? '').toString(),
      skillCount: j['skill_count'] is int ? j['skill_count'] as int : 0,
      description: (j['description'] ?? '').toString(),
      character: HmCharacterSpec.fromMeta(meta, shown, rank: rank),
      uiMeta: meta,
    );
  }

  static String _titleCase(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

/// A bot's chat row on Home: the bot, plus its most recent session.
@immutable
class HmBotSummary {
  const HmBotSummary(this.bot, this.latest);
  final HmBot bot;
  final Session? latest;

  double get lastActive => latest == null
      ? 0
      : (latest!.lastActive > 0 ? latest!.lastActive : latest!.startedAt);
}

/// Loads and caches a host's bots and their sessions.
class HmBotsModel extends ChangeNotifier {
  HmBotsModel(this.gateway) {
    gateway.addListener(_onGateway);
  }

  final NextGenGateway gateway;
  List<HmBot> bots = const [];
  final Map<String, List<Session>> sessions = {};

  /// Why the last read of a bot's sessions failed, by profile; cleared by
  /// the next good read. Home's session tree shows it with a retry.
  final Map<String, String> sessionErrors = {};

  /// Whether the host holds more of a bot's sessions than [sessions] keeps.
  final Map<String, bool> sessionsHasMore = {};
  final Map<String, Future<void>> _botLoads = {};
  bool loading = false;
  String? error;
  bool _disposed = false;

  /// The REST profile rows behind [bots], kept so the socket's fuller
  /// `ui_meta` can be laid over them.
  List<Map<String, dynamic>> _rows = const [];

  /// `ui_meta` by profile from WS `profiles.list`. REST `GET /api/profiles`
  /// returns only the `hermes-bots` key, so a bot's chosen character
  /// (`ui_meta.character`) comes from the socket.
  Map<String, Map<String, dynamic>> _wsMeta = const {};
  bool _metaPending = true;
  bool _metaLoading = false;

  /// Fills an empty list from the device cache so Home has something to
  /// show before the host answers. Does nothing once bots are loaded.
  Future<void> seedFromCache(String host, {HmCacheStore? store}) async {
    if (bots.isNotEmpty) return;
    try {
      final kept = await hmCachedBots(host, store: store);
      if (_disposed || bots.isNotEmpty || kept.bots.isEmpty) return;
      bots = kept.bots;
      sessions.addAll(kept.sessions);
      _notify();
    } catch (_) {
      // Nothing kept, or unreadable: wait for the host.
    }
  }

  void _onGateway() {
    if (_metaPending && _rows.isNotEmpty && gateway.state.isConnected) {
      unawaited(_loadWsMeta());
    }
  }

  Future<void> _loadWsMeta() async {
    if (_metaLoading || !gateway.state.isConnected) return;
    _metaLoading = true;
    try {
      final res = await gateway.call('profiles.list', {
        'include_sessions': false,
      }, timeout: const Duration(seconds: 10));
      final rows = res['profiles'];
      _wsMeta = {
        for (final r in (rows is List ? rows : const []).whereType<Map>())
          if (r['ui_meta'] is Map)
            (r['name'] ?? 'default').toString(): Map<String, dynamic>.from(
              r['ui_meta'] as Map,
            ),
      };
      _metaPending = false;
      if (_disposed || _rows.isEmpty) return;
      bots = _build(_rows);
      _notify();
    } catch (_) {
      // Older host or socket down: the REST rows stand.
    } finally {
      _metaLoading = false;
    }
  }

  List<HmBot> _build(List<Map<String, dynamic>> maps) {
    final names = [for (final m in maps) (m['name'] ?? 'default').toString()]
      ..sort();
    final list = [
      for (final m in maps)
        HmBot.fromJson(
          _withWsMeta(m),
          rank: names.indexOf((m['name'] ?? 'default').toString()),
        ),
    ];
    list.sort(
      (a, b) => a.isDefault == b.isDefault ? 0 : (a.isDefault ? -1 : 1),
    );
    return list;
  }

  Map<String, dynamic> _withWsMeta(Map<String, dynamic> m) {
    final ws = _wsMeta[(m['name'] ?? 'default').toString()];
    if (ws == null) return m;
    final rest = m['ui_meta'] is Map
        ? Map<String, dynamic>.from(m['ui_meta'] as Map)
        : const <String, dynamic>{};
    return {
      ...m,
      'ui_meta': {...rest, ...ws},
    };
  }

  DashboardApiClient apiFor(HmBot bot) => bot.scope == null
      ? DashboardApiClient.withDashboard(gateway.dashboard)
      : DashboardApiClient.withDashboard(gateway.dashboard, profile: bot.scope);

  List<HmBotSummary> get summaries {
    final out = [
      for (final b in bots) HmBotSummary(b, sessions[b.profile]?.firstOrNull),
    ];
    // Most recently active first; bots with no chats keep host order after them.
    out.sort((a, b) => b.lastActive.compareTo(a.lastActive));
    return out;
  }

  HmBot? byProfile(String profile) =>
      bots.where((b) => b.profile == profile).firstOrNull;

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    error = null;
    _notify();
    try {
      final res = await gateway.dashboard.apiRequest('GET', 'profiles');
      if (res.statusCode != 200) {
        throw DashboardRequestException(
          res.statusCode,
          dashboardErrorMessage(res),
        );
      }
      final body = jsonDecode(res.body);
      final rows = (body is Map ? body['profiles'] : body) as List? ?? const [];
      final maps = [
        for (final m in rows.whereType<Map>()) Map<String, dynamic>.from(m),
      ];
      _rows = maps;
      // Each refresh re-reads the socket's ui_meta, so a new look shows.
      _metaPending = true;
      final list = _build(maps);
      bots = list;
      await Future.wait([
        for (final b in list) _loadSessions(b),
        if (gateway.state.isConnected) _loadWsMeta(),
      ]);
    } catch (e) {
      error = '$e';
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<void> _loadSessions(HmBot bot) async {
    try {
      final page = await apiFor(bot).getSessionsPage(limit: 50);
      sessions[bot.profile] = page.sessions.where((s) => !s.archived).toList();
      sessionsHasMore[bot.profile] = page.hasMore;
      sessionErrors.remove(bot.profile);
    } catch (e) {
      sessions[bot.profile] = sessions[bot.profile] ?? const [];
      sessionErrors[bot.profile] = '$e'.replaceFirst('Exception: ', '');
    }
  }

  /// Reads one bot's sessions again (a retry, or a bot the last refresh
  /// did not reach). Concurrent calls for the same bot share one request.
  Future<void> loadBotSessions(HmBot bot) =>
      _botLoads[bot.profile] ??= () async {
        try {
          await _loadSessions(bot);
        } finally {
          _botLoads.remove(bot.profile);
          _notify();
        }
      }();

  /// Whether a read of [profile]'s sessions is in flight.
  bool loadingBot(String profile) =>
      _botLoads.containsKey(profile) ||
      (loading && !sessions.containsKey(profile));

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    gateway.removeListener(_onGateway);
    super.dispose();
  }
}
