// Agent settings → Model / New Agent: the host calls and the typed shapes
// they return, parsed at the boundary. Every call is scoped to one bot's
// profile with `?profile=` (the default profile sends none), the same way
// `HmBotsModel.apiFor` scopes session reads.
//
// Wire (hermes-agent, MIT):
//   GET  /api/model/info        hermes_cli/web_routers/models.py:91
//   GET  /api/model/options     hermes_cli/web_routers/models.py:139
//   GET  /api/model/auxiliary   hermes_cli/web_routers/models.py:220
//   GET  /api/model/moa         hermes_cli/web_routers/models.py:274
//   POST /api/model/set         hermes_cli/web_routers/models.py:378
//   POST /api/profiles          hermes_cli/web_routers/profiles.py:747
//   ws   profiles.configure     tui_gateway/methods_profiles.py:386
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/connection_manager.dart';
import '../../hm_bots.dart';

/// A host refusal, carrying the host's own words when it sent any.
class HmModelApiError implements Exception {
  const HmModelApiError(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}

/// One provider + model pair.
@immutable
class HmModelChoice {
  const HmModelChoice(this.provider, this.model);
  final String provider;
  final String model;

  String get key => '$provider|$model';

  static HmModelChoice? fromKey(String key) {
    final i = key.indexOf('|');
    if (i <= 0 || i == key.length - 1) return null;
    return HmModelChoice(key.substring(0, i), key.substring(i + 1));
  }

  @override
  bool operator ==(Object other) =>
      other is HmModelChoice &&
      other.provider == provider &&
      other.model == model;

  @override
  int get hashCode => Object.hash(provider, model);
}

/// `claude-opus-5-5` → `Opus 5.5`; other ids lose only a vendor prefix.
String hmPrettyModel(String id) {
  final bare = id.contains('/') ? id.substring(id.lastIndexOf('/') + 1) : id;
  final m = RegExp(
    r'^claude-(opus|sonnet|haiku|fable|mythos)-(\d+)-(\d+)',
  ).firstMatch(bare);
  if (m != null) {
    final family = m.group(1)!;
    return '${family[0].toUpperCase()}${family.substring(1)} '
        '${m.group(2)}.${m.group(3)}';
  }
  return bare;
}

/// What the profile's main slot runs on now (`/api/model/info`).
@immutable
class HmModelInfo {
  const HmModelInfo({
    required this.model,
    required this.provider,
    this.contextLength = 0,
    this.supportsReasoning,
  });

  final String model;
  final String provider;
  final int contextLength;
  final bool? supportsReasoning;

  bool get isSet => model.isNotEmpty;

  factory HmModelInfo.fromJson(Map<String, dynamic> j) {
    final caps = j['capabilities'];
    final ctx = j['effective_context_length'];
    return HmModelInfo(
      model: (j['model'] ?? '').toString(),
      provider: (j['provider'] ?? '').toString(),
      contextLength: ctx is int ? ctx : 0,
      supportsReasoning: caps is Map && caps['supports_reasoning'] is bool
          ? caps['supports_reasoning'] as bool
          : null,
    );
  }
}

/// One provider row of the picker catalog (`/api/model/options`).
@immutable
class HmProviderModels {
  const HmProviderModels({
    required this.slug,
    required this.name,
    required this.models,
    this.isCurrent = false,
    this.warning,
  });

  final String slug;
  final String name;
  final List<String> models;
  final bool isCurrent;
  final String? warning;

  factory HmProviderModels.fromJson(Map<String, dynamic> j) {
    final slug = (j['slug'] ?? '').toString();
    final name = (j['name'] ?? '').toString().trim();
    final seen = <String>{};
    final unavailable = {
      for (final m in (j['unavailable_models'] as List? ?? const [])) '$m',
    };
    final warning = (j['warning'] ?? '').toString().trim();
    return HmProviderModels(
      slug: slug,
      name: name.isEmpty ? slug : name,
      models: [
        for (final m in (j['models'] as List? ?? const []))
          if ('$m'.isNotEmpty && !unavailable.contains('$m') && seen.add('$m'))
            '$m',
      ],
      isCurrent: j['is_current'] == true,
      warning: warning.isEmpty ? null : warning,
    );
  }
}

@immutable
class HmModelCatalog {
  const HmModelCatalog({required this.providers, this.current});
  final List<HmProviderModels> providers;
  final HmModelChoice? current;

  bool get isEmpty => providers.every((p) => p.models.isEmpty);

  factory HmModelCatalog.fromJson(Map<String, dynamic> j) {
    final provider = (j['provider'] ?? '').toString();
    final model = (j['model'] ?? '').toString();
    return HmModelCatalog(
      providers: [
        for (final r in (j['providers'] as List? ?? const []).whereType<Map>())
          HmProviderModels.fromJson(Map<String, dynamic>.from(r)),
      ].where((p) => p.slug.isNotEmpty).toList(),
      current: provider.isNotEmpty && model.isNotEmpty
          ? HmModelChoice(provider, model)
          : null,
    );
  }
}

/// One auxiliary task slot (`/api/model/auxiliary`).
@immutable
class HmAuxSlot {
  const HmAuxSlot({
    required this.task,
    required this.label,
    required this.provider,
    required this.model,
  });

  final String task;
  final String label;
  final String provider;
  final String model;

  /// Unpinned: the host routes it through the main model.
  bool get isAuto => (provider.isEmpty || provider == 'auto') && model.isEmpty;

  factory HmAuxSlot.fromJson(Map<String, dynamic> j) {
    final task = (j['task'] ?? '').toString();
    final label = (j['label'] ?? '').toString().trim();
    return HmAuxSlot(
      task: task,
      label: label.isNotEmpty ? label : _labelFor(task),
      provider: (j['provider'] ?? '').toString(),
      model: (j['model'] ?? '').toString(),
    );
  }

  /// `title_generation` → `Title generation`.
  static String _labelFor(String task) {
    final words = task.replaceAll('_', ' ').trim();
    if (words.isEmpty) return task;
    if (words == 'mcp') return 'MCP';
    return words[0].toUpperCase() + words.substring(1);
  }
}

@immutable
class HmAuxiliary {
  const HmAuxiliary({required this.tasks, this.main});
  final List<HmAuxSlot> tasks;
  final HmModelChoice? main;

  factory HmAuxiliary.fromJson(Map<String, dynamic> j) {
    final main = j['main'];
    final provider = main is Map ? (main['provider'] ?? '').toString() : '';
    final model = main is Map ? (main['model'] ?? '').toString() : '';
    return HmAuxiliary(
      tasks: [
        for (final t in (j['tasks'] as List? ?? const []).whereType<Map>())
          HmAuxSlot.fromJson(Map<String, dynamic>.from(t)),
      ].where((t) => t.task.isNotEmpty).toList(),
      main: model.isEmpty ? null : HmModelChoice(provider, model),
    );
  }
}

/// The Mixture-of-Agents slots of the default preset (`/api/model/moa`).
@immutable
class HmMoa {
  const HmMoa({required this.references, this.aggregator});
  final List<HmModelChoice> references;
  final HmModelChoice? aggregator;

  static HmModelChoice? _slot(Object? raw) {
    if (raw is! Map) return null;
    final p = (raw['provider'] ?? '').toString();
    final m = (raw['model'] ?? '').toString();
    return m.isEmpty ? null : HmModelChoice(p, m);
  }

  factory HmMoa.fromJson(Map<String, dynamic> j) => HmMoa(
    references: [
      for (final r in (j['reference_models'] as List? ?? const [])) ?_slot(r),
    ],
    aggregator: _slot(j['aggregator']),
  );
}

/// What `/api/model/set` answered.
@immutable
class HmSetResult {
  const HmSetResult({required this.ok, this.confirmMessage});
  final bool ok;

  /// The host wants a second, confirmed request (an expensive model).
  final String? confirmMessage;
  bool get needsConfirm => confirmMessage != null;
}

/// What `POST /api/profiles` answered.
@immutable
class HmCreatedProfile {
  const HmCreatedProfile({
    required this.name,
    this.modelError,
    this.warnings = const [],
  });
  final String name;
  final String? modelError;
  final List<String> warnings;
}

/// The host calls behind Model and New Agent.
class HmAgentModelApi {
  HmAgentModelApi(this.dashboard, {this.rpc});

  /// Scoped to [bots]' host; JSON-RPC rides its gateway socket.
  factory HmAgentModelApi.of(HmBotsModel bots) =>
      HmAgentModelApi(bots.gateway.dashboard, rpc: bots.gateway.call);

  final DashboardClient dashboard;
  final Future<Map<String, dynamic>> Function(
    String method,
    Map<String, dynamic> params,
  )?
  rpc;

  static Map<String, String>? _scope(String? profile) =>
      profile == null ? null : {'profile': profile};

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final http.Response res;
    try {
      res = await dashboard.apiRequest(
        method,
        path,
        queryParameters: query,
        body: body,
        timeout: timeout,
      );
    } on TimeoutException {
      throw const HmModelApiError('The server did not answer in time.');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw HmModelApiError(hmHostMessage(res), status: res.statusCode);
    }
    final text = res.body.trim();
    if (text.isEmpty) return const {};
    final decoded = jsonDecode(text);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
  }

  Future<HmModelInfo> info(String? profile) async => HmModelInfo.fromJson(
    await _json('GET', 'model/info', query: _scope(profile)),
  );

  Future<HmModelCatalog> options(
    String? profile, {
    bool refresh = false,
  }) async => HmModelCatalog.fromJson(
    await _json(
      'GET',
      'model/options',
      query: {...?_scope(profile), if (refresh) 'refresh': 'true'},
      // A cold catalog can wait on models.dev for ~15 s.
      timeout: const Duration(seconds: 60),
    ),
  );

  Future<HmAuxiliary> auxiliary(String? profile) async => HmAuxiliary.fromJson(
    await _json('GET', 'model/auxiliary', query: _scope(profile)),
  );

  Future<HmMoa> moa(String? profile) async =>
      HmMoa.fromJson(await _json('GET', 'model/moa', query: _scope(profile)));

  /// Assigns [choice] to the main slot, or to auxiliary [task]. A null
  /// [choice] on an auxiliary task puts it back on `auto`.
  Future<HmSetResult> setModel(
    String? profile, {
    required HmModelChoice? choice,
    String scope = 'main',
    String task = '',
    bool confirmExpensive = false,
  }) async {
    final j = await _json(
      'POST',
      'model/set',
      query: _scope(profile),
      body: {
        'scope': scope,
        'provider': choice?.provider ?? 'auto',
        'model': choice?.model ?? '',
        if (task.isNotEmpty) 'task': task,
        if (confirmExpensive) 'confirm_expensive_model': true,
      },
      timeout: const Duration(seconds: 60),
    );
    if (j['confirm_required'] == true) {
      final msg = (j['confirm_message'] ?? '').toString().trim();
      return HmSetResult(ok: false, confirmMessage: msg);
    }
    return HmSetResult(ok: j['ok'] != false);
  }

  /// Creates a profile. The host validates the name and answers 400 with
  /// its own reason (invalid, reserved, already exists).
  Future<HmCreatedProfile> createProfile({
    required String name,
    String? description,
    String? soul,
    HmModelChoice? model,
    String? cloneFrom,
  }) async {
    final j = await _json(
      'POST',
      'profiles',
      body: {
        'name': name,
        if (description != null && description.trim().isNotEmpty)
          'description': description.trim(),
        if (soul != null && soul.trim().isNotEmpty) 'soul': soul,
        if (model != null) ...{
          'provider': model.provider,
          'model': model.model,
        },
        if (cloneFrom != null && cloneFrom.isNotEmpty) 'clone_from': cloneFrom,
      },
      timeout: const Duration(seconds: 90),
    );
    final err = (j['model_error'] ?? '').toString().trim();
    return HmCreatedProfile(
      name: (j['name'] ?? name).toString(),
      modelError: err.isEmpty ? null : err,
      warnings: [
        for (final w in (j['warnings'] as List? ?? const []))
          if ('$w'.trim().isNotEmpty) '$w'.trim(),
      ],
    );
  }

  /// Stores the bot's look in `ui_meta.character`. False when the host
  /// did not apply it (or there is no live socket).
  Future<bool> setCharacter(String profile, Map<String, Object?> meta) async {
    final call = rpc;
    if (call == null) return false;
    try {
      final r = await call('profiles.configure', {
        'name': profile,
        'ui_meta': {'character': meta},
      });
      final applied = r['applied'];
      return applied is Map && applied['ui_meta'] == true;
    } catch (_) {
      return false;
    }
  }
}

/// The host's own reason for a refusal: FastAPI's `detail` (a string, or a
/// list of validation errors), else the status.
String hmHostMessage(http.Response res) {
  try {
    final decoded = jsonDecode(res.body);
    if (decoded is Map) {
      final detail =
          decoded['detail'] ?? decoded['error'] ?? decoded['message'];
      if (detail is String && detail.trim().isNotEmpty) return detail.trim();
      if (detail is List) {
        final parts = [
          for (final d in detail)
            if (d is Map && d['msg'] is String) (d['msg'] as String).trim(),
        ].where((s) => s.isNotEmpty);
        if (parts.isNotEmpty) return parts.join('\n');
      }
      if (detail is Map) {
        final inner = detail['message'] ?? detail['detail'];
        if (inner is String && inner.trim().isNotEmpty) return inner.trim();
      }
    }
  } catch (_) {
    // Not JSON.
  }
  return 'HTTP ${res.statusCode}';
}

/// Starred models, kept on this phone.
class HmModelFavourites {
  static const _key = 'hm.model_favourites';

  static Future<List<HmModelChoice>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return [
      for (final k in prefs.getStringList(_key) ?? const <String>[])
        ?HmModelChoice.fromKey(k),
    ];
  }

  static Future<List<HmModelChoice>> toggle(HmModelChoice choice) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = [...?prefs.getStringList(_key)];
    if (!keys.remove(choice.key)) keys.add(choice.key);
    await prefs.setStringList(_key, keys);
    return [for (final k in keys) ?HmModelChoice.fromKey(k)];
  }
}
