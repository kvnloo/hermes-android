// Plugins: the agent plugins installed on the bot's host, each with its
// switch; tap one for its details (and Remove when the host lets it go);
// the plus button installs one from a Git repository or Hub identifier.
import 'package:flutter/material.dart';

import '../../../nextgen/theme/nextgen_theme.dart';
import '../../hm_bots.dart';
import '../../hm_ui.dart';
import 'integrations_api.dart';
import 'integrations_kit.dart';

Future<void> openHmPlugins(
  BuildContext context, {
  required HmBot bot,
  required HmBotsModel bots,
}) => hmPushPage(context, HmPluginsPage(api: hmIntegrationsFor(bot, bots)));

const _restartNote =
    'Enabling and disabling take effect when the gateway next starts.';

const _pluginsForbidden =
    'Hermes denied permission to manage plugins. Check server access settings.';

/// Words for a failed change: the host's own reason when it gave one.
String _pluginsFailure(HmIntegrationsError e) => e.failure == HmFailure.forbidden
    ? _pluginsForbidden
    : e.message.isEmpty
    ? 'Hermes did not save the plugin settings.'
    : e.message;

enum _Filter { all, enabled, disabled }

class HmPluginsPage extends StatefulWidget {
  const HmPluginsPage({super.key, required this.api});
  final HmIntegrationsApi api;

  @override
  State<HmPluginsPage> createState() => _HmPluginsPageState();
}

class _HmPluginsPageState extends State<HmPluginsPage> {
  HmLoad<List<HmPlugin>> _load = const HmLoad.loading();
  final Set<String> _busy = {};
  _Filter _filter = _Filter.all;
  bool _bulk = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final rows = await widget.api.loadPlugins();
      if (mounted) setState(() => _load = HmLoad.loaded(rows));
    } catch (e) {
      if (mounted) setState(() => _load = HmLoad.failed(hmAsError(e)));
    }
  }

  void _replace(HmPlugin next) {
    final rows = _load.data;
    if (rows == null) return;
    setState(
      () => _load = HmLoad.loaded([
        for (final p in rows) p.name == next.name ? next : p,
      ]),
    );
  }

  Future<bool> _toggle(HmPlugin p, bool on) async {
    setState(() => _busy.add(p.name));
    try {
      await widget.api.setPluginEnabled(p.name, on);
      _replace(p.withStatus(on ? 'enabled' : 'disabled'));
      return true;
    } catch (e) {
      if (mounted) hmToast(context, _pluginsFailure(hmAsError(e)));
      return false;
    } finally {
      if (mounted) setState(() => _busy.remove(p.name));
    }
  }

  Future<void> _setAll(bool on) async {
    final ok = await hmConfirm(
      context,
      title: on ? 'Enable installed plugins?' : 'Disable installed plugins?',
      body: _restartNote,
      confirmLabel: on ? 'Enable All' : 'Disable All',
    );
    if (!ok || !mounted) return;
    final todo = [
      for (final p in _load.data ?? const <HmPlugin>[])
        if (p.enabled != on) p,
    ];
    setState(() => _bulk = true);
    for (final p in todo) {
      if (!mounted) return;
      if (!await _toggle(p, on)) break;
    }
    if (mounted) setState(() => _bulk = false);
  }

  Future<void> _install() async {
    final installed = await hmPushPage<bool>(
      context,
      HmInstallPluginPage(api: widget.api),
    );
    if (installed == true) _refresh();
  }

  Future<void> _open(HmPlugin p) async {
    await hmPushPage(
      context,
      HmPluginDetailsPage(
        api: widget.api,
        plugin: p,
        onToggle: (on) => _toggle(p, on),
      ),
    );
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return HmIntegrationsFrame(
      title: 'Plugins',
      trailing: [
        HmRoundButton(
          icon: Icons.add,
          label: 'Install Plugin',
          onPressed: _install,
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
        icon: Icons.extension_off_outlined,
        title: 'Plugins unavailable',
        body: switch (error.failure) {
          HmFailure.forbidden => _pluginsForbidden,
          HmFailure.unsupported =>
            'This Hermes version does not support managing plugins from Hermes Agent. Update Hermes and try again.',
          _ =>
            'Plugins could not be reached. Check your server connection and try again.',
        },
        actionLabel: 'Try Again',
        onAction: () {
          setState(() => _load = const HmLoad.loading());
          _refresh();
        },
      );
    }
    final all = load.data!;
    if (all.isEmpty) {
      return const HmCenteredState(
        icon: Icons.extension_outlined,
        title: 'No plugins installed',
        body:
            'Install a Hermes Agent plugin or one from a Git repository with the plus button.',
      );
    }
    final enabledCount = all.where((p) => p.enabled).length;
    final shown = switch (_filter) {
      _Filter.all => all,
      _Filter.enabled => all.where((p) => p.enabled).toList(),
      _Filter.disabled => all.where((p) => !p.enabled).toList(),
    };
    final rows = <Widget>[
      Row(
        children: [
          Expanded(
            child: PopupMenuButton<bool>(
              tooltip: 'Enable or disable all, or restart the plugin gateways',
              enabled: !_bulk,
              onSelected: _setAll,
              itemBuilder: (_) => const [
                PopupMenuItem(value: true, child: Text('Enable All')),
                PopupMenuItem(value: false, child: Text('Disable All')),
              ],
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                child: Row(
                  children: [
                    _bulk
                        ? const HmRowSpinner()
                        : Icon(Icons.tune, color: c.text),
                    const SizedBox(width: 14),
                    Text('Installed', style: HmType.row.copyWith(color: c.text)),
                  ],
                ),
              ),
            ),
          ),
          Text('${all.length}', style: HmType.value.copyWith(color: c.text3)),
          PopupMenuButton<_Filter>(
            tooltip: 'Show',
            onSelected: (f) => setState(() => _filter = f),
            itemBuilder: (_) => const [
              PopupMenuItem(value: _Filter.all, child: Text('All')),
              PopupMenuItem(value: _Filter.enabled, child: Text('Enabled')),
              PopupMenuItem(value: _Filter.disabled, child: Text('Disabled')),
            ],
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$enabledCount enabled',
                    style: HmType.value.copyWith(color: c.text2),
                  ),
                  Icon(Icons.unfold_more, size: 18, color: c.text2),
                ],
              ),
            ),
          ),
        ],
      ),
      for (final p in shown)
        _PluginRow(
          plugin: p,
          busy: _busy.contains(p.name),
          onTap: () => _open(p),
          onToggle: _bulk ? null : (on) => _toggle(p, on),
        ),
    ];
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        children: [
          HmGroup(children: rows),
          const HmFootnote(_restartNote),
        ],
      ),
    );
  }
}

class _SetupBadge extends StatelessWidget {
  const _SetupBadge();

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.warning),
      ),
      child: Text(
        'SETUP NEEDED',
        style: HmType.caption.copyWith(color: c.warning, letterSpacing: 1.2),
      ),
    );
  }
}

class _PluginRow extends StatelessWidget {
  const _PluginRow({
    required this.plugin,
    required this.busy,
    required this.onTap,
    required this.onToggle,
  });

  final HmPlugin plugin;
  final bool busy;
  final VoidCallback onTap;
  final ValueChanged<bool>? onToggle;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        plugin.name,
                        style: HmType.row.copyWith(color: c.text, fontSize: 18),
                      ),
                      if (plugin.authRequired) const _SetupBadge(),
                    ],
                  ),
                  if (plugin.description.isNotEmpty)
                    Text(
                      plugin.description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: HmType.value.copyWith(color: c.text3),
                    ),
                  if (plugin.meta.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        plugin.meta,
                        style: HmType.caption.copyWith(color: c.textMuted),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 60,
              child: Center(
                child: busy
                    ? const HmRowSpinner()
                    : Semantics(
                        label: plugin.name,
                        child: Switch(
                          value: plugin.enabled,
                          onChanged: onToggle,
                          activeThumbColor: c.onAccent,
                          activeTrackColor: c.accent,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One plugin: what it is, its switch, setup it needs, and Remove.
class HmPluginDetailsPage extends StatefulWidget {
  const HmPluginDetailsPage({
    super.key,
    required this.api,
    required this.plugin,
    required this.onToggle,
  });
  final HmIntegrationsApi api;
  final HmPlugin plugin;

  /// Flips the switch through the list, so both screens agree.
  final Future<bool> Function(bool on) onToggle;

  @override
  State<HmPluginDetailsPage> createState() => _HmPluginDetailsPageState();
}

class _HmPluginDetailsPageState extends State<HmPluginDetailsPage> {
  late HmPlugin _p = widget.plugin;
  bool _busy = false;

  Future<void> _toggle(bool on) async {
    setState(() => _busy = true);
    final ok = await widget.onToggle(on);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _p = _p.withStatus(on ? 'enabled' : 'disabled');
    });
  }

  Future<void> _remove() async {
    final ok = await hmConfirm(
      context,
      title: 'Remove this plugin?',
      body: 'The plugin is deleted from this Hermes installation.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.removePlugin(_p.name);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        hmToast(context, _pluginsFailure(hmAsError(e)));
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return HmPage(
      title: 'Plugin Details',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
          child: Wrap(
            spacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(_p.name, style: HmType.display.copyWith(color: c.text)),
              if (_p.authRequired) const _SetupBadge(),
            ],
          ),
        ),
        if (_p.description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
            child: Text(
              _p.description,
              style: HmType.value.copyWith(color: c.text2),
            ),
          ),
        const SizedBox(height: 20),
        HmGroup(
          children: [
            HmRow(
              label: 'Enabled',
              chevron: false,
              trailing: _busy
                  ? const HmRowSpinner()
                  : Switch(
                      value: _p.enabled,
                      onChanged: _toggle,
                      activeThumbColor: c.onAccent,
                      activeTrackColor: c.accent,
                    ),
            ),
          ],
        ),
        const HmFootnote('Makes the plugin available to new sessions.'),
        if (_p.authRequired) ...[
          const HmSection('Setup needed'),
          HmGroup(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'This plugin needs authentication before it can work.',
                      style: HmType.value.copyWith(color: c.text),
                    ),
                    if (_p.authCommand.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      SelectableText(
                        _p.authCommand,
                        style: HmType.value.copyWith(
                          color: c.text2,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
        HmSection('Details'),
        HmGroup(
          children: [
            if (_p.version.isNotEmpty)
              HmRow(label: 'Version', value: _p.version, chevron: false),
            HmRow(label: 'Source', value: _p.source, chevron: false),
            HmRow(label: 'Status', value: _p.status, chevron: false),
          ],
        ),
        if (_p.removedReason != null) HmFootnote(_p.removedReason!),
        if (_p.canRemove) ...[
          const SizedBox(height: HmMetrics.groupGap),
          HmGroup(
            children: [
              HmRow(
                icon: Icons.delete_outline,
                label: 'Remove',
                danger: true,
                chevron: false,
                onTap: _busy ? null : _remove,
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Install a plugin from a Git URL, `owner/repo`, or a Hub identifier.
class HmInstallPluginPage extends StatefulWidget {
  const HmInstallPluginPage({super.key, required this.api});
  final HmIntegrationsApi api;

  @override
  State<HmInstallPluginPage> createState() => _HmInstallPluginPageState();
}

class _HmInstallPluginPageState extends State<HmInstallPluginPage> {
  final _id = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _id.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _id.dispose();
    super.dispose();
  }

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await widget.api.installPlugin(_id.text.trim());
      if (!mounted) return;
      if (res['ok'] == false || res['consent_required'] == true) {
        setState(() {
          _busy = false;
          _error = res['error'] is String
              ? res['error'] as String
              : 'Plugin installation failed.';
        });
        return;
      }
      hmToast(
        context,
        'Plugin installed. Restart the Hermes dashboard and agent gateways, then Check Setup.',
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      final err = hmAsError(e);
      setState(() {
        _busy = false;
        _error = err.failure == HmFailure.forbidden
            ? _pluginsFailure(err)
            : err.message.isEmpty
            ? 'Plugin installation failed.'
            : err.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return HmPage(
      title: 'Install Plugin',
      bottom: SafeArea(
        top: false,
        child: HmPrimaryButton(
          label: 'Install',
          busy: _busy,
          trailingIcon: null,
          onPressed: _id.text.trim().isEmpty ? null : _install,
        ),
      ),
      children: [
        const HmFootnote(
          'Install the plugin, then restart the Hermes dashboard and agent gateways to load it.',
        ),
        HmField(
          controller: _id,
          label: 'Git repository or Hub identifier',
          hint: 'owner/repo',
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(
              _error!,
              style: HmType.value.copyWith(color: c.danger),
            ),
          ),
      ],
    );
  }
}
