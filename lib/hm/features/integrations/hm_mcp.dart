// MCP: the bot's MCP servers. Each has its switch; tap one to test it (lists
// its tools), sign in with OAuth, or remove it. The grid button opens the
// host's official catalog; the plus button adds a server by URL or command.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../nextgen/theme/nextgen_theme.dart';
import '../../hm_bots.dart';
import '../../hm_ui.dart';
import 'integrations_api.dart';
import 'integrations_kit.dart';

Future<void> openHmMcp(
  BuildContext context, {
  required HmBot bot,
  required HmBotsModel bots,
}) => hmPushPage(context, HmMcpPage(api: hmIntegrationsFor(bot, bots)));

const _mcpForbidden =
    'Hermes denied permission to manage MCP servers. Check server access settings.';
const _mcpTooOld =
    'This Hermes version does not support MCP management. Update Hermes and try again.';

/// Words for a failed change: the host's own reason when it gave one.
String _mcpFailure(HmIntegrationsError e, String fallback) =>
    e.failure == HmFailure.forbidden
    ? _mcpForbidden
    : e.message.isEmpty
    ? fallback
    : e.message;

/// Words for a failed read of [what]: a missing route means an older Hermes.
String _mcpReadFailure(HmIntegrationsError e, String fallback) =>
    switch (e.failure) {
      HmFailure.forbidden => _mcpForbidden,
      HmFailure.unsupported => _mcpTooOld,
      _ => fallback,
    };

class HmMcpPage extends StatefulWidget {
  const HmMcpPage({super.key, required this.api});
  final HmIntegrationsApi api;

  @override
  State<HmMcpPage> createState() => _HmMcpPageState();
}

class _HmMcpPageState extends State<HmMcpPage> {
  HmLoad<List<HmMcpServer>> _load = const HmLoad.loading();
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final rows = await widget.api.loadMcpServers();
      if (mounted) setState(() => _load = HmLoad.loaded(rows));
    } catch (e) {
      if (mounted) setState(() => _load = HmLoad.failed(hmAsError(e)));
    }
  }

  Future<void> _toggle(HmMcpServer s, bool on) async {
    setState(() => _busy.add(s.name));
    try {
      await widget.api.setMcpEnabled(s.name, on);
      final rows = _load.data ?? const <HmMcpServer>[];
      if (mounted) {
        setState(
          () => _load = HmLoad.loaded([
            for (final r in rows) r.name == s.name ? r.withEnabled(on) : r,
          ]),
        );
      }
    } catch (e) {
      if (mounted) {
        hmToast(
          context,
          _mcpFailure(hmAsError(e), 'The MCP server could not be saved.'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(s.name));
    }
  }

  Future<void> _after(Future<bool?> pushed) async {
    if (await pushed == true && mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return HmIntegrationsFrame(
      title: 'MCP',
      trailing: [
        HmButtonPair(
          children: [
            HmPairItem(
              Icons.grid_view_outlined,
              'Catalog',
              () => _after(
                hmPushPage<bool>(context, HmMcpCatalogPage(api: widget.api)),
              ),
            ),
            HmPairItem(
              Icons.add,
              'Add Server',
              () => _after(
                hmPushPage<bool>(context, HmAddMcpServerPage(api: widget.api)),
              ),
            ),
          ],
        ),
      ],
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final c = NgColors.of(context);
    final load = _load;
    if (load.loading) return const Center(child: CircularProgressIndicator());
    final error = load.error;
    if (error != null) {
      return HmCenteredState(
        icon: Icons.power_off_outlined,
        title: 'MCP unavailable',
        body: _mcpReadFailure(error, 'MCP servers could not be loaded.'),
        actionLabel: 'Try Again',
        onAction: () {
          setState(() => _load = const HmLoad.loading());
          _refresh();
        },
      );
    }
    final rows = load.data!;
    if (rows.isEmpty) {
      return const HmCenteredState(
        icon: Icons.power_outlined,
        title: 'No MCP servers',
        body: 'Install one from the catalog, or add your own with the plus button.',
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const HmSection('MCP servers'),
          HmGroup(
            children: [
              for (final s in rows)
                InkWell(
                  onTap: () => _after(
                    hmPushPage<bool>(
                      context,
                      HmMcpServerPage(api: widget.api, server: s),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                    child: Row(
                      children: [
                        Icon(
                          s.transport == 'stdio'
                              ? Icons.terminal
                              : Icons.cloud_outlined,
                          color: c.text2,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s.name,
                                style: HmType.row.copyWith(color: c.text),
                              ),
                              Text(
                                s.target,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: HmType.caption.copyWith(color: c.text3),
                              ),
                              if (s.fromPlugin)
                                Text(
                                  s.plugin!,
                                  style: HmType.caption.copyWith(
                                    color: c.textMuted,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: 60,
                          child: Center(
                            child: _busy.contains(s.name)
                                ? const HmRowSpinner()
                                : Semantics(
                                    label: s.name,
                                    child: Switch(
                                      value: s.enabled,
                                      onChanged: s.fromPlugin
                                          ? null
                                          : (on) => _toggle(s, on),
                                      activeThumbColor: c.onAccent,
                                      activeTrackColor: c.accent,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const HmFootnote(
            'Enabling and disabling take effect when the gateway next starts.',
          ),
        ],
      ),
    );
  }
}

/// One server: what it runs, its tools (by testing it), OAuth and Remove.
class HmMcpServerPage extends StatefulWidget {
  const HmMcpServerPage({
    super.key,
    required this.api,
    required this.server,
    this.pollEvery = const Duration(seconds: 2),
  });
  final HmIntegrationsApi api;
  final HmMcpServer server;
  final Duration pollEvery;

  @override
  State<HmMcpServerPage> createState() => _HmMcpServerPageState();
}

class _HmMcpServerPageState extends State<HmMcpServerPage> {
  HmMcpProbe? _probe;
  bool _probing = false;
  bool _removing = false;
  HmOAuthFlow? _flow;
  bool _signingIn = false;
  Timer? _poll;

  HmMcpServer get s => widget.server;

  @override
  void dispose() {
    _poll?.cancel();
    final flow = _flow;
    if (flow != null && !flow.done) {
      unawaited(widget.api.cancelMcpOAuth(flow.flowId).catchError((_) {}));
    }
    super.dispose();
  }

  Future<void> _test() async {
    setState(() => _probing = true);
    try {
      final probe = await widget.api.testMcp(s.name);
      if (mounted) setState(() => _probe = probe);
    } catch (e) {
      if (mounted) {
        setState(
          () => _probe = HmMcpProbe(
            ok: false,
            tools: const [],
            error: hmAsError(e).message,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  Future<void> _signIn() async {
    setState(() => _signingIn = true);
    try {
      final flow = await widget.api.startMcpOAuth(s.name);
      _flow = flow;
      final url = flow.authorizationUrl;
      if (flow.status == 'error' || url == null) {
        _finishOAuth(flow);
        return;
      }
      await widget.api.transport.openExternal(Uri.parse(url));
      _poll = Timer.periodic(widget.pollEvery, (_) => _checkFlow());
    } catch (e) {
      if (mounted) {
        hmToast(context, hmAsError(e).message);
        setState(() => _signingIn = false);
      }
    }
  }

  bool _checking = false;
  Future<void> _checkFlow() async {
    final flow = _flow;
    if (flow == null || _checking) return;
    _checking = true;
    try {
      final next = await widget.api.mcpOAuthFlow(flow.flowId);
      _flow = next;
      if (next.done) _finishOAuth(next);
    } on HmIntegrationsError catch (e) {
      _finishOAuth(
        HmOAuthFlow(flowId: flow.flowId, status: 'error', error: e.message),
      );
    } finally {
      _checking = false;
    }
  }

  void _finishOAuth(HmOAuthFlow flow) {
    _poll?.cancel();
    _poll = null;
    if (!mounted) return;
    setState(() => _signingIn = false);
    if (flow.status == 'approved') {
      hmToast(context, 'Connection established');
      _test();
    } else {
      hmToast(
        context,
        flow.error?.isNotEmpty == true
            ? flow.error!
            : flow.authorizationUrl == null
            ? 'The server did not return a sign-in link.'
            : 'Sign-in failed.',
      );
    }
  }

  Future<void> _remove() async {
    final ok = await hmConfirm(
      context,
      title: 'Remove this MCP server?',
      body: s.name,
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _removing = true);
    try {
      await widget.api.removeMcp(s.name);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        hmToast(
          context,
          _mcpFailure(hmAsError(e), 'The MCP server could not be saved.'),
        );
        setState(() => _removing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final probe = _probe;
    return HmPage(
      title: s.name,
      children: [
        HmGroup(
          children: [
            HmRow(
              label: s.transport == 'stdio' ? 'Command' : 'URL',
              value: s.target,
              chevron: false,
            ),
            if (s.auth != null)
              HmRow(label: 'Auth', value: s.auth, chevron: false),
            HmRow(
              label: 'Enabled',
              value: s.enabled ? 'On' : 'Off',
              chevron: false,
            ),
          ],
        ),
        const HmSection('Available Tools'),
        HmGroup(
          children: [
            if (probe == null)
              _Note('Not probed yet. Test connects, lists what it offers, and disconnects.')
            else if (!probe.ok)
              _Note(probe.error ?? 'Connection failed', color: c.danger)
            else if (probe.tools.isEmpty)
              const _Note('Connected, and the server offers no tools.')
            else
              for (final t in probe.tools)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.name, style: HmType.value.copyWith(color: c.text)),
                      if (t.description.isNotEmpty)
                        Text(
                          t.description,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: HmType.caption.copyWith(color: c.text3),
                        ),
                    ],
                  ),
                ),
            HmRow(
              icon: Icons.travel_explore,
              label: 'Discover Tools',
              chevron: false,
              onTap: _probing ? null : _test,
              trailing: _probing ? const HmRowSpinner() : null,
            ),
          ],
        ),
        if (s.canOAuth && !s.fromPlugin) ...[
          const SizedBox(height: HmMetrics.groupGap),
          HmGroup(
            children: [
              HmRow(
                icon: Icons.login,
                label: _signingIn ? 'Waiting for sign-in…' : 'Sign In With OAuth',
                chevron: false,
                onTap: _signingIn ? null : _signIn,
                trailing: _signingIn ? const HmRowSpinner() : null,
              ),
            ],
          ),
        ],
        if (!s.fromPlugin) ...[
          const SizedBox(height: HmMetrics.groupGap),
          HmGroup(
            children: [
              HmRow(
                icon: Icons.delete_outline,
                label: 'Remove Server',
                danger: true,
                chevron: false,
                onTap: _removing ? null : _remove,
                trailing: _removing ? const HmRowSpinner() : null,
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Text(text, style: HmType.value.copyWith(color: color ?? c.text3)),
    );
  }
}

/// The host's Nous-approved MCP catalog.
class HmMcpCatalogPage extends StatefulWidget {
  const HmMcpCatalogPage({super.key, required this.api});
  final HmIntegrationsApi api;

  @override
  State<HmMcpCatalogPage> createState() => _HmMcpCatalogPageState();
}

class _HmMcpCatalogPageState extends State<HmMcpCatalogPage> {
  HmLoad<List<HmMcpCatalogEntry>> _load = const HmLoad.loading();
  final Set<String> _busy = {};
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final rows = await widget.api.loadMcpCatalog();
      if (mounted) setState(() => _load = HmLoad.loaded(rows));
    } catch (e) {
      if (mounted) setState(() => _load = HmLoad.failed(hmAsError(e)));
    }
  }

  Future<void> _install(HmMcpCatalogEntry e) async {
    var env = <String, String>{};
    if (e.requiredEnv.isNotEmpty) {
      final given = await showModalBottomSheet<Map<String, String>>(
        context: context,
        isScrollControlled: true,
        backgroundColor: NgColors.of(context).sheet,
        builder: (_) => _EnvSheet(entry: e),
      );
      if (given == null || !mounted) return;
      env = given;
    }
    setState(() => _busy.add(e.name));
    try {
      await widget.api.installMcpCatalog(e.name, env);
      _changed = true;
      if (!mounted) return;
      hmToast(context, 'MCP server added');
      await _refresh();
    } catch (err) {
      if (mounted) {
        hmToast(
          context,
          _mcpFailure(hmAsError(err), 'The MCP server could not be added.'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(e.name));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final load = _load;
    Widget body;
    if (load.loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (load.error != null) {
      body = HmCenteredState(
        icon: Icons.cloud_off_outlined,
        title: 'MCP catalog unavailable',
        body: _mcpReadFailure(
          load.error!,
          'Check your connection, then try again.',
        ),
        actionLabel: 'Try Again',
        onAction: () {
          setState(() => _load = const HmLoad.loading());
          _refresh();
        },
      );
    } else if (load.data!.isEmpty) {
      body = const HmCenteredState(
        icon: Icons.grid_off_outlined,
        title: 'No catalog',
        body: 'This install ships no MCP catalog.',
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const HmFootnote(
            'Browse Nous-approved MCP servers and install them with one tap.',
          ),
          for (final e in load.data!)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HmMetrics.edge,
                vertical: 10,
              ),
              child: Row(
                children: [
                  HmLetterTile(e.name),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(e.name, style: HmType.row.copyWith(color: c.text)),
                        if (e.description.isNotEmpty)
                          Text(
                            e.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: HmType.value.copyWith(color: c.text3),
                          ),
                        if (e.target.isNotEmpty)
                          Text(
                            e.target,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HmType.caption.copyWith(
                              color: c.textMuted,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (e.installed && !_busy.contains(e.name))
                    Text(
                      'Installed',
                      style: HmType.value.copyWith(color: c.success),
                    )
                  else
                    HmPillButton(
                      label: 'Install',
                      semanticLabel: 'Install ${e.name}',
                      busy: _busy.contains(e.name),
                      onPressed: () => _install(e),
                    ),
                ],
              ),
            ),
        ],
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: HmIntegrationsFrame(title: 'Official Catalog', body: body),
    );
  }
}

class _EnvSheet extends StatefulWidget {
  const _EnvSheet({required this.entry});
  final HmMcpCatalogEntry entry;

  @override
  State<_EnvSheet> createState() => _EnvSheetState();
}

class _EnvSheetState extends State<_EnvSheet> {
  late final Map<String, TextEditingController> _fields = {
    for (final f in widget.entry.requiredEnv) f.name: TextEditingController(),
  };

  @override
  void initState() {
    super.initState();
    for (final f in _fields.values) {
      f.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final f in _fields.values) {
      f.dispose();
    }
    super.dispose();
  }

  bool get _ready => widget.entry.requiredEnv.every(
    (f) => !f.required || _fields[f.name]!.text.trim().isNotEmpty,
  );

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
                child: Text(
                  widget.entry.name,
                  style: HmType.screenTitle.copyWith(color: c.text),
                ),
              ),
              const HmFootnote(
                "This server needs the following before it will run. They are written to this profile's .env.",
              ),
              for (final f in widget.entry.requiredEnv)
                HmField(
                  controller: _fields[f.name]!,
                  label: f.name,
                  hint: f.prompt.isEmpty ? null : f.prompt,
                  obscure: true,
                ),
              HmPrimaryButton(
                label: 'Install',
                trailingIcon: null,
                onPressed: _ready
                    ? () => Navigator.of(context).pop({
                        for (final e in _fields.entries)
                          if (e.value.text.trim().isNotEmpty)
                            e.key: e.value.text.trim(),
                      })
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Add a server by URL (remote) or command (stdio).
class HmAddMcpServerPage extends StatefulWidget {
  const HmAddMcpServerPage({super.key, required this.api});
  final HmIntegrationsApi api;

  @override
  State<HmAddMcpServerPage> createState() => _HmAddMcpServerPageState();
}

class _HmAddMcpServerPageState extends State<HmAddMcpServerPage> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _command = TextEditingController();
  final _args = TextEditingController();
  bool _stdio = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final f in [_name, _url, _command]) {
      f.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final f in [_name, _url, _command, _args]) {
      f.dispose();
    }
    super.dispose();
  }

  bool get _ready =>
      _name.text.trim().isNotEmpty &&
      (_stdio ? _command.text.trim().isNotEmpty : _url.text.trim().isNotEmpty);

  Future<void> _save() async {
    if (_stdio && _command.text.trim().isEmpty) {
      setState(() => _error = 'A command is required for a stdio server.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.addMcp(
        name: _name.text.trim(),
        url: _stdio ? null : _url.text.trim(),
        command: _stdio ? _command.text.trim() : null,
        args: _stdio
            ? _args.text.trim().split(RegExp(r'\s+')).where((a) => a.isNotEmpty).toList()
            : const [],
      );
      if (!mounted) return;
      hmToast(context, 'MCP server added');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _mcpFailure(hmAsError(e), 'The MCP server could not be added.');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return HmPage(
      title: 'Add MCP Server',
      bottom: SafeArea(
        top: false,
        child: HmPrimaryButton(
          label: 'Add Server',
          busy: _busy,
          trailingIcon: null,
          onPressed: _ready ? _save : null,
        ),
      ),
      children: [
        HmField(controller: _name, label: 'Name'),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HmMetrics.edge,
            vertical: 8,
          ),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('URL')),
              ButtonSegment(value: true, label: Text('Command')),
            ],
            selected: {_stdio},
            onSelectionChanged: (v) => setState(() => _stdio = v.first),
          ),
        ),
        if (_stdio) ...[
          HmField(controller: _command, label: 'Command', hint: 'npx'),
          HmField(
            controller: _args,
            label: 'Arguments',
            hint: '-y @modelcontextprotocol/server-filesystem /tmp',
          ),
        ] else
          HmField(
            controller: _url,
            label: 'URL',
            hint: 'https://example.com/mcp',
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(_error!, style: HmType.value.copyWith(color: c.danger)),
          ),
      ],
    );
  }
}
