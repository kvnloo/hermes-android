// Integrations data: the bot's hosted connectors (Connections), agent plugins
// and MCP servers. Every call is scoped to the bot's profile. Shapes follow
// Hermes's own routes and contracts:
//   connectors.*  tui_gateway/methods_connectors*.py, contracts/connectors.py
//   plugins       hermes_cli/web_routers/dashboard_ui.py
//   MCP           hermes_cli/web_routers/mcp.py
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/dashboard_api_client.dart';
import '../../../core/services/ws_client.dart';
import '../../../nextgen/data/nextgen_gateway.dart';

/// Why an integrations call failed, in the terms the screens word it.
enum HmFailure {
  /// 403: the host refused this user.
  forbidden,

  /// 404 on a list route / JSON-RPC method not found: the host is too old.
  unsupported,

  /// The host could not be reached or answered with a server error.
  unavailable,

  /// The host understood and said no (4xx with a reason).
  rejected,
}

class HmIntegrationsError implements Exception {
  const HmIntegrationsError(this.failure, this.message, {this.reason, this.status});

  final HmFailure failure;

  /// The host's own words (FastAPI `detail`, JSON-RPC `message`).
  final String message;

  /// JSON-RPC `error.data.reason` (connector refusals), when given.
  final String? reason;
  final int? status;

  factory HmIntegrationsError.fromStatus(int status, String message) =>
      HmIntegrationsError(
        status == 403
            ? HmFailure.forbidden
            : status == 404
            ? HmFailure.unsupported
            : status >= 500
            ? HmFailure.unavailable
            : HmFailure.rejected,
        message,
        status: status,
      );

  factory HmIntegrationsError.fromRpc(JsonRpcError e) => HmIntegrationsError(
    e.code == -32601
        ? HmFailure.unsupported
        : e.code == 4031 || (e.code ?? 0) >= 5000
        ? HmFailure.unavailable
        : HmFailure.rejected,
    e.message,
    reason: e.reason,
  );

  @override
  String toString() => message;
}

/// The two wires a bot's integrations ride: dashboard REST and `/api/ws`.
abstract class HmIntegrationsTransport {
  Future<Map<String, dynamic>> rpc(String method, Map<String, dynamic> params);

  /// One REST call under `/api/`; returns the decoded JSON body or throws
  /// [HmIntegrationsError] for a non-2xx answer.
  Future<Object?> rest(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  });

  /// Opens a sign-in link in the browser.
  Future<bool> openExternal(Uri url);
}

class HmGatewayTransport implements HmIntegrationsTransport {
  HmGatewayTransport(this.gateway);
  final NextGenGateway gateway;

  static const _rpcTimeout = Duration(seconds: 45);

  @override
  Future<Map<String, dynamic>> rpc(
    String method,
    Map<String, dynamic> params,
  ) async {
    try {
      await gateway.connected();
      return await gateway.call(method, params, timeout: _rpcTimeout);
    } on JsonRpcError catch (e) {
      throw HmIntegrationsError.fromRpc(e);
    } on StateError catch (e) {
      throw HmIntegrationsError(HmFailure.unavailable, e.message);
    }
  }

  @override
  Future<Object?> rest(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final res = await gateway.dashboard.apiRequest(
      method,
      path,
      body: body,
      queryParameters: query,
      timeout: const Duration(seconds: 60),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw HmIntegrationsError.fromStatus(
        res.statusCode,
        dashboardErrorMessage(res),
      );
    }
    if (res.body.trim().isEmpty) return null;
    try {
      return jsonDecode(res.body);
    } on FormatException {
      throw const HmIntegrationsError(
        HmFailure.unavailable,
        'Hermes sent a response Hermes Agent couldn\'t read.',
      );
    }
  }

  @override
  Future<bool> openExternal(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);
}

// ---------------------------------------------------------------- models

String _s(Object? v) => v == null ? '' : '$v';
Map<String, dynamic> _m(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _rows(Object? v) => [
  if (v is List)
    for (final r in v)
      if (r is Map) Map<String, dynamic>.from(r),
];

/// One service in the hosted connector catalog (`ConnectorCatalogRow`).
@immutable
class HmConnector {
  const HmConnector({
    required this.slug,
    required this.name,
    required this.description,
    required this.category,
  });
  final String slug;
  final String name;
  final String description;
  final String category;

  factory HmConnector.fromJson(Map<String, dynamic> j) => HmConnector(
    slug: _s(j['slug']),
    name: _s(j['name']).isEmpty ? _s(j['slug']) : _s(j['name']),
    description: _s(j['description']),
    category: _s(j['category']),
  );
}

/// The account owner's connection state for one connector (`ConnectorRow`).
@immutable
class HmConnectorState {
  const HmConnectorState({
    required this.connector,
    required this.connected,
    this.status,
  });
  final String connector;
  final bool connected;

  /// pending | active | failed | expired | revoked | inactive
  final String? status;

  bool get needsAttention =>
      status == 'failed' || status == 'expired' || status == 'revoked';

  factory HmConnectorState.fromJson(Map<String, dynamic> j) => HmConnectorState(
    connector: _s(j['connector']),
    connected: j['connected'] == true,
    status: j['connection_status'] is String
        ? j['connection_status'] as String
        : null,
  );
}

/// One hosted account (`ConnectorAccountRow`).
@immutable
class HmConnectorAccount {
  const HmConnectorAccount({
    required this.connectionId,
    required this.connector,
    required this.status,
    required this.label,
    this.alias,
    this.disabled = false,
  });
  final String connectionId;
  final String connector;
  final String status;
  final String label;
  final String? alias;
  final bool disabled;

  factory HmConnectorAccount.fromJson(Map<String, dynamic> j) =>
      HmConnectorAccount(
        connectionId: _s(j['connection_id']),
        connector: _s(j['connector']),
        status: _s(j['status']),
        label: _s(j['label']),
        alias: j['alias'] is String ? j['alias'] as String : null,
        disabled: j['disabled'] == true,
      );
}

/// Everything the Connections screen shows.
@immutable
class HmConnectionsData {
  const HmConnectionsData({
    required this.available,
    required this.catalog,
    required this.states,
    required this.accounts,
    this.accountsFailed = false,
  });

  /// False when the host has connectors switched off or no Nous sign-in.
  final bool available;
  final List<HmConnector> catalog;
  final Map<String, HmConnectorState> states;
  final List<HmConnectorAccount> accounts;
  final bool accountsFailed;

  List<String> get categories {
    final seen = <String>[];
    for (final c in catalog) {
      if (c.category.isNotEmpty && !seen.contains(c.category)) {
        seen.add(c.category);
      }
    }
    return seen;
  }
}

/// One row of an open connection operation (`ConnectionOperationTarget`).
@immutable
class HmConnectTarget {
  const HmConnectTarget({
    required this.name,
    required this.state,
    this.connectUrl,
    this.detail,
  });
  final String name;

  /// pending | initiated | connected | skipped | failed | expired | not_connected
  final String state;
  final String? connectUrl;
  final String? detail;

  factory HmConnectTarget.fromJson(Map<String, dynamic> j) => HmConnectTarget(
    name: _s(j['name']),
    state: _s(j['state']),
    connectUrl: j['connect_url'] is String ? j['connect_url'] as String : null,
    detail: j['detail'] is String ? j['detail'] as String : null,
  );
}

@immutable
class HmConnectOperation {
  const HmConnectOperation({
    required this.opId,
    required this.settled,
    required this.targets,
  });
  final String opId;
  final bool settled;
  final List<HmConnectTarget> targets;

  HmConnectTarget? target(String name) =>
      targets.where((t) => t.name == name).firstOrNull;

  factory HmConnectOperation.fromJson(Map<String, dynamic> j) =>
      HmConnectOperation(
        opId: _s(j['op_id']),
        settled: j['settled'] == true,
        targets: [for (final t in _rows(j['targets'])) HmConnectTarget.fromJson(t)],
      );
}

/// One agent plugin from `GET /api/dashboard/plugins/hub`.
@immutable
class HmPlugin {
  const HmPlugin({
    required this.name,
    required this.version,
    required this.description,
    required this.source,
    required this.status,
    this.authRequired = false,
    this.authCommand = '',
    this.canRemove = false,
    this.canUpdate = false,
    this.removedReason,
  });
  final String name;
  final String version;
  final String description;

  /// bundled | user | git | project | entrypoint …
  final String source;

  /// enabled | disabled | inactive
  final String status;
  final bool authRequired;
  final String authCommand;
  final bool canRemove;
  final bool canUpdate;
  final String? removedReason;

  bool get enabled => status == 'enabled';

  HmPlugin withStatus(String next) => HmPlugin(
    name: name,
    version: version,
    description: description,
    source: source,
    status: next,
    authRequired: authRequired,
    authCommand: authCommand,
    canRemove: canRemove,
    canUpdate: canUpdate,
    removedReason: removedReason,
  );

  /// "1.0.0 · bundled", as the official list prints it.
  String get meta => [
    if (version.isNotEmpty) version,
    if (source.isNotEmpty) source,
  ].join(' · ');

  factory HmPlugin.fromJson(Map<String, dynamic> j) => HmPlugin(
    name: _s(j['name']),
    version: _s(j['version']),
    description: _s(j['description']).trim(),
    source: _s(j['source']),
    status: _s(j['runtime_status']),
    authRequired: j['auth_required'] == true,
    authCommand: _s(j['auth_command']),
    canRemove: j['can_remove'] == true,
    canUpdate: j['can_update_git'] == true,
    removedReason: j['removed_reason'] is String
        ? j['removed_reason'] as String
        : null,
  );
}

/// One configured MCP server (`_mcp_server_summary`).
@immutable
class HmMcpServer {
  const HmMcpServer({
    required this.name,
    required this.transport,
    required this.enabled,
    this.url,
    this.command,
    this.args = const [],
    this.auth,
    this.tools,
    this.plugin,
  });
  final String name;

  /// http | stdio | unknown
  final String transport;
  final bool enabled;
  final String? url;
  final String? command;
  final List<String> args;

  /// oauth | header | none | null
  final String? auth;

  /// Enabled tool names, or null for all.
  final List<String>? tools;

  /// The plugin that provides it; such servers cannot be changed here.
  final String? plugin;

  bool get fromPlugin => plugin != null;
  bool get canOAuth => url != null && (auth == null || auth == 'oauth');

  /// What it runs or contacts.
  String get target => url ??
      [?command, ...args].join(' ');

  HmMcpServer withEnabled(bool next) => HmMcpServer(
    name: name,
    transport: transport,
    enabled: next,
    url: url,
    command: command,
    args: args,
    auth: auth,
    tools: tools,
    plugin: plugin,
  );

  factory HmMcpServer.fromJson(Map<String, dynamic> j) => HmMcpServer(
    name: _s(j['name']),
    transport: _s(j['transport']),
    enabled: j['enabled'] != false,
    url: j['url'] is String ? j['url'] as String : null,
    command: j['command'] is String ? j['command'] as String : null,
    args: [if (j['args'] is List) for (final a in j['args'] as List) '$a'],
    auth: j['auth'] is String ? j['auth'] as String : null,
    tools: j['tools'] is List
        ? [for (final t in j['tools'] as List) '$t']
        : null,
    plugin: j['plugin'] is String ? j['plugin'] as String : null,
  );
}

@immutable
class HmMcpTool {
  const HmMcpTool(this.name, this.description);
  final String name;
  final String description;
}

/// `POST /api/mcp/servers/{name}/test`.
@immutable
class HmMcpProbe {
  const HmMcpProbe({required this.ok, required this.tools, this.error});
  final bool ok;
  final List<HmMcpTool> tools;
  final String? error;

  factory HmMcpProbe.fromJson(Map<String, dynamic> j) => HmMcpProbe(
    ok: j['ok'] == true,
    error: j['error'] is String ? j['error'] as String : null,
    tools: [
      for (final t in _rows(j['tools']))
        HmMcpTool(_s(t['name']), _s(t['description'])),
    ],
  );
}

@immutable
class HmMcpEnvField {
  const HmMcpEnvField(this.name, this.prompt, this.required);
  final String name;
  final String prompt;
  final bool required;
}

/// One entry of `GET /api/mcp/catalog`.
@immutable
class HmMcpCatalogEntry {
  const HmMcpCatalogEntry({
    required this.name,
    required this.description,
    required this.transport,
    required this.installed,
    required this.requiredEnv,
    this.url,
    this.command,
    this.args = const [],
  });
  final String name;
  final String description;
  final String transport;
  final bool installed;
  final List<HmMcpEnvField> requiredEnv;
  final String? url;
  final String? command;
  final List<String> args;

  String get target => url ??
      [?command, ...args].join(' ');

  factory HmMcpCatalogEntry.fromJson(Map<String, dynamic> j) =>
      HmMcpCatalogEntry(
        name: _s(j['name']),
        description: _s(j['description']),
        transport: _s(j['transport']),
        installed: j['installed'] == true,
        url: j['url'] is String ? j['url'] as String : null,
        command: j['command'] is String ? j['command'] as String : null,
        args: [if (j['args'] is List) for (final a in j['args'] as List) '$a'],
        requiredEnv: [
          for (final e in _rows(j['required_env']))
            HmMcpEnvField(
              _s(e['name']),
              _s(e['prompt']),
              e['required'] != false,
            ),
        ],
      );
}

/// `DashboardOAuthFlow.snapshot()`.
@immutable
class HmOAuthFlow {
  const HmOAuthFlow({
    required this.flowId,
    required this.status,
    this.authorizationUrl,
    this.error,
  });
  final String flowId;

  /// starting | authorization_required | approved | error
  final String status;
  final String? authorizationUrl;
  final String? error;

  bool get done => status == 'approved' || status == 'error';

  factory HmOAuthFlow.fromJson(Map<String, dynamic> j) => HmOAuthFlow(
    flowId: _s(j['flow_id']),
    status: _s(j['status']),
    authorizationUrl: j['authorization_url'] is String
        ? j['authorization_url'] as String
        : null,
    error: j['error'] is String ? j['error'] as String : null,
  );
}

// ---------------------------------------------------------------- client

/// One bot's integrations, every call scoped to its profile.
class HmIntegrationsApi {
  HmIntegrationsApi(this.transport, {this.profile});

  final HmIntegrationsTransport transport;

  /// The bot's profile; null for the host's default profile.
  final String? profile;

  Map<String, String> get _query => {'profile': ?profile};
  Map<String, dynamic> _rpcParams([Map<String, dynamic> more = const {}]) => {
    'profile': ?profile,
    ...more,
  };

  static const _account = {'type': 'account'};

  Future<Map<String, dynamic>> _get(String path) async =>
      _m(await transport.rest('GET', path, query: _query));

  Future<Object?> _send(String method, String path, [Object? body]) =>
      transport.rest(method, path, query: _query, body: body);

  // Connections ------------------------------------------------------------

  Future<HmConnectionsData> loadConnections() async {
    final list = await transport.rpc(
      'connectors.list',
      _rpcParams({'owner': _account}),
    );
    final available = list['available'] == true;
    if (!available) {
      return const HmConnectionsData(
        available: false,
        catalog: [],
        states: {},
        accounts: [],
      );
    }
    final catalog = await transport.rpc('connectors.catalog', _rpcParams());
    var accounts = const <HmConnectorAccount>[];
    var accountsFailed = false;
    try {
      accounts = await loadAccounts();
    } on HmIntegrationsError {
      accountsFailed = true;
    }
    return HmConnectionsData(
      available: true,
      catalog: [
        for (final c in _rows(catalog['connectors'])) HmConnector.fromJson(c),
      ],
      states: {
        for (final r in _rows(list['connectors']))
          _s(r['connector']): HmConnectorState.fromJson(r),
      },
      accounts: accounts,
      accountsFailed: accountsFailed,
    );
  }

  /// The hosted accounts this profile's Nous member owns (retired ones left out).
  Future<List<HmConnectorAccount>> loadAccounts() async {
    final res = await transport.rpc('connectors.accounts', _rpcParams());
    return [
      for (final a in _rows(res['accounts'])) HmConnectorAccount.fromJson(a),
    ].where((a) => !a.disabled).toList();
  }

  Future<HmConnectOperation> connect(String slug, {bool reconnect = false}) async =>
      HmConnectOperation.fromJson(
        await transport.rpc(
          'connectors.connect',
          _rpcParams({
            'owner': _account,
            'connectors': [slug],
            'reconnect': reconnect,
          }),
        ),
      );

  Future<HmConnectOperation> operationStatus(String opId) async =>
      HmConnectOperation.fromJson(
        await transport.rpc(
          'connectors.operation.status',
          _rpcParams({'owner': _account, 'op_id': opId}),
        ),
      );

  Future<void> wakeOperation(String opId) => transport.rpc(
    'connectors.operation.wake',
    _rpcParams({'owner': _account, 'op_id': opId}),
  );

  Future<void> removeAccount(String connectionId) => transport.rpc(
    'connectors.accounts.remove',
    _rpcParams({'connection_id': connectionId}),
  );

  // Plugins ----------------------------------------------------------------

  Future<List<HmPlugin>> loadPlugins() async {
    final hub = await _get('dashboard/plugins/hub');
    final list = [for (final p in _rows(hub['plugins'])) HmPlugin.fromJson(p)]
      ..sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  Future<void> setPluginEnabled(String name, bool enabled) => _send(
    'POST',
    'dashboard/agent-plugins/${_path(name)}/${enabled ? 'enable' : 'disable'}',
  );

  /// Installs from a Git URL, `owner/repo` or a Hub identifier.
  Future<Map<String, dynamic>> installPlugin(String identifier) async => _m(
    await _send('POST', 'dashboard/agent-plugins/install', {
      'identifier': identifier,
      'enable': true,
    }),
  );

  Future<void> removePlugin(String name) =>
      _send('DELETE', 'dashboard/agent-plugins/${_path(name)}');

  // MCP --------------------------------------------------------------------

  Future<List<HmMcpServer>> loadMcpServers() async {
    final res = await _get('mcp/servers');
    return [for (final s in _rows(res['servers'])) HmMcpServer.fromJson(s)];
  }

  Future<void> setMcpEnabled(String name, bool enabled) => _send(
    'PUT',
    'mcp/servers/${Uri.encodeComponent(name)}/enabled',
    {'enabled': enabled, 'profile': ?profile},
  );

  Future<void> removeMcp(String name) =>
      _send('DELETE', 'mcp/servers/${Uri.encodeComponent(name)}');

  Future<HmMcpProbe> testMcp(String name) async => HmMcpProbe.fromJson(
    _m(await _send('POST', 'mcp/servers/${Uri.encodeComponent(name)}/test')),
  );

  Future<void> addMcp({
    required String name,
    String? url,
    String? command,
    List<String> args = const [],
  }) => _send('POST', 'mcp/servers', {
    'name': name,
    'url': ?url,
    'command': ?command,
    if (command != null) 'args': args,
    'profile': ?profile,
  });

  Future<List<HmMcpCatalogEntry>> loadMcpCatalog() async {
    final res = await _get('mcp/catalog');
    return [
      for (final e in _rows(res['entries'])) HmMcpCatalogEntry.fromJson(e),
    ];
  }

  /// Returns true when the host installs it in the background (git clone).
  Future<bool> installMcpCatalog(String name, Map<String, String> env) async {
    final res = _m(
      await _send('POST', 'mcp/catalog/install', {
        'name': name,
        'env': env,
        'enable': true,
        'profile': ?profile,
      }),
    );
    return res['background'] == true;
  }

  Future<HmOAuthFlow> startMcpOAuth(String name) async => HmOAuthFlow.fromJson(
    _m(await _send('POST', 'mcp/servers/${Uri.encodeComponent(name)}/auth')),
  );

  Future<HmOAuthFlow> mcpOAuthFlow(String flowId) async => HmOAuthFlow.fromJson(
    _m(
      await transport.rest(
        'GET',
        'mcp/oauth/flows/${Uri.encodeComponent(flowId)}',
      ),
    ),
  );

  Future<void> cancelMcpOAuth(String flowId) => transport.rest(
    'DELETE',
    'mcp/oauth/flows/${Uri.encodeComponent(flowId)}',
  );

  static String _path(String name) =>
      name.split('/').map(Uri.encodeComponent).join('/');
}
