// Bots: each profile a host serves is a bot. One connection (host) can hold
// many bots; one gateway socket serves them all, scoped per call.
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/models/session.dart';
import '../core/services/dashboard_api_client.dart';
import '../nextgen/data/nextgen_gateway.dart';
import 'avatar/hm_avatar.dart';

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
  HmBotsModel(this.gateway);

  final NextGenGateway gateway;
  List<HmBot> bots = const [];
  final Map<String, List<Session>> sessions = {};
  bool loading = false;
  String? error;
  bool _disposed = false;

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
      final names = [for (final m in maps) (m['name'] ?? 'default').toString()]
        ..sort();
      final list = [
        for (final m in maps)
          HmBot.fromJson(
            m,
            rank: names.indexOf((m['name'] ?? 'default').toString()),
          ),
      ];
      list.sort(
        (a, b) => a.isDefault == b.isDefault ? 0 : (a.isDefault ? -1 : 1),
      );
      bots = list;
      await Future.wait([for (final b in list) _loadSessions(b)]);
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
    } catch (_) {
      sessions[bot.profile] = sessions[bot.profile] ?? const [];
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
