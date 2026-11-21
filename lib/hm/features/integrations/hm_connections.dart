// Connections: the hosted services (Nous connectors) the bot's profile can
// use, and the accounts connected to them. Connect opens the service's
// sign-in in the browser; it ends at hermes://connections/done (registered
// in the manifest), which brings the app back, and the resume wakes the
// host's operation so the row settles at once. The poll stays as fallback
// for a return that skips the link. Touch and hold an account to
// disconnect it.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../nextgen/theme/nextgen_theme.dart';
import '../../hm_bots.dart';
import '../../hm_ui.dart';
import 'integrations_api.dart';
import 'integrations_kit.dart';

Future<void> openHmConnections(
  BuildContext context, {
  required HmBot bot,
  required HmBotsModel bots,
}) => hmPushPage(context, HmConnectionsPage(api: hmIntegrationsFor(bot, bots)));

const _needsNous = {'CONNECTORS_UNAVAILABLE', 'NEEDS_NOUS_AUTH'};

class HmConnectionsPage extends StatefulWidget {
  const HmConnectionsPage({
    super.key,
    required this.api,
    this.pollEvery = const Duration(seconds: 3),
  });

  final HmIntegrationsApi api;
  final Duration pollEvery;

  @override
  State<HmConnectionsPage> createState() => _HmConnectionsPageState();
}

class _HmConnectionsPageState extends State<HmConnectionsPage>
    with WidgetsBindingObserver {
  HmLoad<HmConnectionsData> _load = const HmLoad.loading();
  String _query = '';
  String? _category; // null = All
  final Set<String> _busy = {};

  /// Connector slug → open operation id, while its sign-in is in the browser.
  final Map<String, String> _waiting = {};
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waiting.isNotEmpty) {
      // Back from the browser: have the host read the accounts now.
      for (final op in _waiting.values.toSet()) {
        unawaited(widget.api.wakeOperation(op).catchError((_) {}));
      }
      unawaited(_checkWaiting());
    }
  }

  Future<void> _refresh() async {
    setState(() => _load = _load.data == null ? const HmLoad.loading() : _load);
    try {
      final data = await widget.api.loadConnections();
      if (mounted) setState(() => _load = HmLoad.loaded(data));
    } catch (e) {
      if (mounted) setState(() => _load = HmLoad.failed(hmAsError(e)));
    }
  }

  Future<void> _connect(HmConnector c, {required bool reconnect}) async {
    setState(() => _busy.add(c.slug));
    try {
      final op = await widget.api.connect(c.slug, reconnect: reconnect);
      final target = op.target(c.slug);
      if (target?.state == 'connected') {
        _settled(c.slug, 'connected');
        return;
      }
      final url = target?.connectUrl;
      if (url == null || url.isEmpty) {
        if (mounted) {
          hmToast(
            context,
            target?.state == 'failed'
                ? 'The account was not connected. Please try again.'
                : 'The server did not return a sign-in link.',
          );
        }
        setState(() => _busy.remove(c.slug));
        return;
      }
      _waiting[c.slug] = op.opId;
      final opened = await widget.api.transport.openExternal(Uri.parse(url));
      if (!opened) {
        _waiting.remove(c.slug);
        if (mounted) {
          hmToast(
            context,
            "The sign-in page couldn't load. Check the connection and try again.",
          );
          setState(() => _busy.remove(c.slug));
        }
        return;
      }
      _poll ??= Timer.periodic(widget.pollEvery, (_) => _checkWaiting());
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        hmToast(context, _connectError(hmAsError(e)));
        setState(() => _busy.remove(c.slug));
      }
    }
  }

  bool _checking = false;
  Future<void> _checkWaiting() async {
    if (_checking || _waiting.isEmpty) return;
    _checking = true;
    try {
      for (final entry in Map.of(_waiting).entries) {
        try {
          final op = await widget.api.operationStatus(entry.value);
          final state = op.target(entry.key)?.state ?? '';
          const terminal = {
            'connected',
            'failed',
            'expired',
            'skipped',
            'not_connected',
          };
          if (op.settled || terminal.contains(state)) {
            _settled(entry.key, state);
          }
        } on HmIntegrationsError catch (e) {
          if (e.reason == 'UNKNOWN_OPERATION') _settled(entry.key, '');
        }
      }
    } finally {
      _checking = false;
    }
  }

  void _settled(String slug, String state) {
    _waiting.remove(slug);
    if (_waiting.isEmpty) {
      _poll?.cancel();
      _poll = null;
    }
    if (!mounted) return;
    setState(() => _busy.remove(slug));
    hmToast(
      context,
      switch (state) {
        'connected' => 'Account connected.',
        'expired' =>
          'Sign-in timed out. Check the account status below, or connect again.',
        _ => 'The account was not connected. Please try again.',
      },
    );
    _refresh();
  }

  String _connectError(HmIntegrationsError e) {
    if (e.failure == HmFailure.unsupported) {
      return 'This server does not support Connected Accounts. Update to a Hermes build that includes this feature, then refresh.';
    }
    if (_needsNous.contains(e.reason)) {
      return 'Make sure this Hermes instance is signed in to Nous and connectors are enabled for the account, then refresh.';
    }
    return e.message.isEmpty
        ? 'The account was not connected. Please try again.'
        : e.message;
  }

  @override
  Widget build(BuildContext context) {
    return HmIntegrationsFrame(title: 'Connections', body: _body(context));
  }

  Widget _body(BuildContext context) {
    final load = _load;
    if (load.loading && load.data == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = load.error;
    if (error != null) {
      if (error.failure == HmFailure.unsupported) {
        return HmCenteredState(
          icon: Icons.system_update_alt,
          title: 'Update Hermes to connect accounts',
          body:
              'This server does not support Connected Accounts. Update to a Hermes build that includes this feature, then refresh.',
          actionLabel: 'Try Again',
          onAction: _refresh,
        );
      }
      return HmCenteredState(
        icon: Icons.cloud_off_outlined,
        title: 'No services available',
        body: _needsNous.contains(error.reason)
            ? 'Make sure this Hermes instance is signed in to Nous and connectors are enabled for the account, then refresh.'
            : 'Check your connection, then try again.',
        actionLabel: 'Try Again',
        onAction: _refresh,
      );
    }
    final data = load.data!;
    if (!data.available) {
      return HmCenteredState(
        icon: Icons.link_off,
        title: 'No services available',
        body:
            'Sign in to Nous on this Hermes instance, then refresh to see available services.',
        actionLabel: 'Try Again',
        onAction: _refresh,
      );
    }
    if (data.catalog.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          children: const [
            SizedBox(height: 120),
            HmCenteredState(
              icon: Icons.apps_outlined,
              title: 'No services available',
              body: 'Services available to your Nous account will appear here.',
            ),
          ],
        ),
      );
    }

    final q = _query.trim().toLowerCase();
    final shown = data.catalog.where((c) {
      if (_category != null && c.category != _category) return false;
      if (q.isEmpty) return true;
      return c.name.toLowerCase().contains(q) ||
          c.description.toLowerCase().contains(q) ||
          c.category.toLowerCase().contains(q);
    }).toList();
    final byCategory = <String, List<HmConnector>>{};
    for (final c in shown) {
      byCategory.putIfAbsent(c.category, () => []).add(c);
    }
    final connectedCount = data.accounts.length;

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 32),
        children: [
          HmSearchField(
            hint: 'Search services',
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: HmMetrics.edge),
              children: [
                HmChip(
                  label: 'All',
                  selected: _category == null,
                  onTap: () => setState(() => _category = null),
                ),
                for (final cat in data.categories) ...[
                  const SizedBox(width: 8),
                  HmChip(
                    label: cat,
                    selected: _category == cat,
                    onTap: () => setState(() => _category = cat),
                  ),
                ],
              ],
            ),
          ),
          if (connectedCount > 0 || data.accountsFailed) ...[
            const SizedBox(height: 20),
            HmGroup(
              children: [
                HmRow(
                  icon: Icons.manage_accounts_outlined,
                  label: 'Show connected accounts',
                  value: data.accountsFailed ? null : '$connectedCount',
                  onTap: () async {
                    await hmPushPage(
                      context,
                      HmConnectedAccountsPage(
                        api: widget.api,
                        catalog: data.catalog,
                      ),
                    );
                    _refresh();
                  },
                ),
              ],
            ),
          ],
          if (shown.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 80),
              child: HmCenteredState(
                icon: Icons.search_off,
                title: 'No matching services',
                body: 'Services available to your Nous account will appear here.',
              ),
            ),
          for (final entry in byCategory.entries) ...[
            HmListHeading(entry.key.isEmpty ? 'Other' : entry.key),
            for (final c in entry.value)
              _ServiceRow(
                connector: c,
                state: data.states[c.slug],
                busy: _busy.contains(c.slug),
                waiting: _waiting.containsKey(c.slug),
                onConnect: (reconnect) => _connect(c, reconnect: reconnect),
              ),
          ],
          const HmFootnote(
            'Connect services through the Nous account signed in on this Hermes instance. Your agents can use them while Hermes Agent is closed.',
          ),
        ],
      ),
    );
  }
}

class _ServiceRow extends StatelessWidget {
  const _ServiceRow({
    required this.connector,
    required this.state,
    required this.busy,
    required this.waiting,
    required this.onConnect,
  });

  final HmConnector connector;
  final HmConnectorState? state;
  final bool busy;
  final bool waiting;
  final ValueChanged<bool> onConnect;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final st = state;
    final attention = st?.needsAttention ?? false;
    final connected = (st?.connected ?? false) && !attention;
    final note = waiting
        ? 'Waiting for sign-in…'
        : attention
        ? 'Needs attention'
        : st?.status == 'pending'
        ? 'Sign-in pending'
        : null;
    Widget trailing;
    if (connected && !busy) {
      trailing = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, size: 18, color: c.success),
            const SizedBox(width: 6),
            Text('Connected', style: HmType.value.copyWith(color: c.success)),
          ],
        ),
      );
    } else {
      trailing = HmPillButton(
        label: 'Connect',
        semanticLabel: 'Connect ${connector.name}',
        busy: busy,
        onPressed: () => onConnect(attention || st?.status == 'pending'),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HmMetrics.edge,
        vertical: 12,
      ),
      child: Row(
        children: [
          HmLetterTile(connector.name),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  connector.name,
                  style: HmType.row.copyWith(color: c.text, fontSize: 18),
                ),
                if (connector.description.isNotEmpty)
                  Text(
                    connector.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: HmType.value.copyWith(color: c.text3),
                  ),
                if (note != null)
                  Text(
                    note,
                    style: HmType.caption.copyWith(
                      color: attention ? c.warning : c.text2,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing,
        ],
      ),
    );
  }
}

/// The hosted accounts; touch and hold one to disconnect it.
class HmConnectedAccountsPage extends StatefulWidget {
  const HmConnectedAccountsPage({
    super.key,
    required this.api,
    this.catalog = const [],
  });
  final HmIntegrationsApi api;
  final List<HmConnector> catalog;

  @override
  State<HmConnectedAccountsPage> createState() =>
      _HmConnectedAccountsPageState();
}

class _HmConnectedAccountsPageState extends State<HmConnectedAccountsPage> {
  HmLoad<List<HmConnectorAccount>> _load = const HmLoad.loading();
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final rows = await widget.api.loadAccounts();
      if (mounted) setState(() => _load = HmLoad.loaded(rows));
    } catch (e) {
      if (mounted) setState(() => _load = HmLoad.failed(hmAsError(e)));
    }
  }

  String _serviceName(String slug) =>
      widget.catalog.where((c) => c.slug == slug).firstOrNull?.name ?? slug;

  Future<void> _disconnect(HmConnectorAccount a) async {
    final ok = await hmConfirm(
      context,
      title: 'Disconnect this account?',
      body: 'Disconnecting affects every agent using it.',
      confirmLabel: 'Disconnect',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy.add(a.connectionId));
    try {
      await widget.api.removeAccount(a.connectionId);
      if (!mounted) return;
      hmToast(context, 'Account disconnected.');
      await _refresh();
    } catch (e) {
      if (mounted) hmToast(context, hmAsError(e).message);
    } finally {
      if (mounted) setState(() => _busy.remove(a.connectionId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final load = _load;
    Widget body;
    if (load.loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (load.error != null) {
      body = HmCenteredState(
        icon: Icons.cloud_off_outlined,
        title: 'Accounts could not be loaded',
        body: 'Check your connection, then try again.',
        actionLabel: 'Try Again',
        onAction: () {
          setState(() => _load = const HmLoad.loading());
          _refresh();
        },
      );
    } else if (load.data!.isEmpty) {
      body = const HmCenteredState(
        icon: Icons.link,
        title: 'No connected services',
        body: 'Services you connect will appear here.',
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        children: [
          HmGroup(
            children: [
              for (final a in load.data!)
                GestureDetector(
                  onLongPress: _busy.contains(a.connectionId)
                      ? null
                      : () => _disconnect(a),
                  child: HmRow(
                    leading: HmLetterTile(_serviceName(a.connector)),
                    label: a.alias?.isNotEmpty == true ? a.alias! : a.label,
                    value: _serviceName(a.connector),
                    subValue: a.status == 'active' ? null : a.status,
                    tall: true,
                    chevron: false,
                    trailing: _busy.contains(a.connectionId)
                        ? const Padding(
                            padding: EdgeInsets.only(left: 12),
                            child: HmRowSpinner(),
                          )
                        : null,
                  ),
                ),
            ],
          ),
          const HmFootnote(
            'Touch and hold an account to disconnect it. Disconnecting affects every agent using it.',
          ),
        ],
      );
    }
    return HmIntegrationsFrame(title: 'Connected Accounts', body: body);
  }
}
