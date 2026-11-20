// Home: the host's bots, most recently active first. A bot opens its latest
// chat; the compose button starts a new session with any bot.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/session.dart';
import '../../nextgen/data/chat_controller.dart';
import '../../nextgen/data/nextgen_gateway.dart';
import '../../nextgen/theme/nextgen_theme.dart';
import '../../nextgen/ui/nextgen_scope.dart';
import '../hm_bots.dart';
import '../hm_character.dart';
import '../hm_ui.dart';
import 'hm_agent_screen.dart';
import 'hm_chat_screen.dart';
import 'hm_settings_screen.dart';

class HmHome extends StatefulWidget {
  const HmHome({super.key});

  @override
  State<HmHome> createState() => _HmHomeState();
}

class _HmHomeState extends State<HmHome> with WidgetsBindingObserver {
  HmBotsModel? _bots;
  NextGenGateway? _gateway;
  StreamSubscription<dynamic>? _changes;
  Timer? _debounce;
  String _query = '';
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final gateway = NgScope.of(context).gateway;
    if (!identical(gateway, _gateway)) {
      _gateway = gateway;
      _bots?.dispose();
      _bots = HmBotsModel(gateway)..refresh();
      _changes?.cancel();
      _changes = gateway.events.listen((e) {
        if (e.type != 'sessions.changed' && e.type != 'session.title') return;
        _debounce?.cancel();
        _debounce = Timer(const Duration(seconds: 2), () => _bots?.refresh());
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_bots?.refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _changes?.cancel();
    _debounce?.cancel();
    _bots?.dispose();
    super.dispose();
  }

  Future<void> _openChat(HmBot bot, {Session? session}) async {
    final gateway = NgScope.of(context).gateway;
    final chat = NgChatController(
      gateway,
      sessionId: session?.id,
      title: session?.title ?? '',
      profile: bot.scope,
      onCreated: (_) => _bots?.refresh(),
    );
    if (session != null) unawaited(chat.open());
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => HmChatScreen(
          bot: bot,
          chat: chat,
          onNewChat: () {
            Navigator.of(context).pop();
            unawaited(_openChat(bot));
          },
          onOpenBot: () => _openAgent(bot),
          onAction: (a) => _chatAction(context, bot, chat, a),
        ),
      ),
    );
    chat.dispose();
    unawaited(_bots?.refresh());
  }

  Future<void> _chatAction(
    BuildContext context,
    HmBot bot,
    NgChatController chat,
    HmChatAction a,
  ) async {
    switch (a) {
      case HmChatAction.chatSettings:
        await showHmChatSettings(context, chat);
      case HmChatAction.archive:
        final id = chat.storedId;
        if (id == null) return;
        await _bots
            ?.apiFor(bot)
            .setSessionArchived(sessionId: id, archived: true)
            .catchError((_) => false);
        if (context.mounted) Navigator.of(context).pop();
      case HmChatAction.delete:
        final id = chat.storedId;
        if (id == null) {
          if (context.mounted) Navigator.of(context).pop();
          return;
        }
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete this chat?'),
            content: const Text(
              'It is removed from the host for every device.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (ok != true) return;
        await _bots?.apiFor(bot).deleteSession(id).catchError((_) {});
        if (context.mounted) Navigator.of(context).pop();
      default:
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('${a.name} is coming next')));
        }
    }
  }

  Future<void> _openAgent(HmBot bot) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => HmAgentScreen(bot: bot, bots: _bots!),
    ),
  );

  Future<void> _newSession() async {
    final bots = _bots;
    if (bots == null) return;
    final bot = await showHmNewSessionSheet(context, bots.bots);
    if (bot != null && mounted) await _openChat(bot);
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final bots = _bots!;
    return Scaffold(
      backgroundColor: c.background,
      floatingActionButton: SizedBox.square(
        dimension: HmMetrics.fab,
        child: FloatingActionButton(
          heroTag: 'hm-new-session',
          tooltip: 'New Session',
          backgroundColor: c.surface,
          foregroundColor: c.text,
          shape: const CircleBorder(),
          elevation: 3,
          onPressed: _newSession,
          child: const Icon(Icons.edit),
        ),
      ),
      body: Column(
        children: [
          HmTopBar(
            leading: HmRoundButton(
              icon: Icons.settings_outlined,
              label: 'Settings',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => HmSettingsScreen(bots: bots),
                ),
              ),
            ),
            center: _searching ? _searchField(c) : null,
            trailing: [
              if (!_searching)
                HmRoundButton(
                  icon: Icons.filter_list,
                  label: 'Filters',
                  onPressed: () {},
                ),
              HmRoundButton(
                icon: _searching ? Icons.close : Icons.search,
                label: _searching ? 'Close search' : 'Search',
                onPressed: () => setState(() {
                  _searching = !_searching;
                  _query = '';
                }),
              ),
            ],
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: Listenable.merge([bots, NgScope.of(context).gateway]),
              builder: (context, _) {
                final rows = bots.summaries
                    .where(
                      (s) =>
                          _query.isEmpty ||
                          s.bot.displayName.toLowerCase().contains(
                            _query.toLowerCase(),
                          ) ||
                          (s.latest?.title.toLowerCase().contains(
                                _query.toLowerCase(),
                              ) ??
                              false),
                    )
                    .toList();
                if (bots.loading && rows.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (bots.error != null && rows.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        bots.error!,
                        textAlign: TextAlign.center,
                        style: HmType.body.copyWith(color: c.text3),
                      ),
                    ),
                  );
                }
                return RefreshIndicator(
                  onRefresh: bots.refresh,
                  child: ListView.builder(
                    padding: const EdgeInsets.only(top: 4, bottom: 96),
                    itemCount: rows.length,
                    itemBuilder: (context, i) => _BotRow(
                      summary: rows[i],
                      onTap: () =>
                          _openChat(rows[i].bot, session: rows[i].latest),
                      onLongPress: () => _openAgent(rows[i].bot),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchField(NgColors c) => Padding(
    padding: const EdgeInsets.only(left: 64, right: 56),
    child: TextField(
      autofocus: true,
      onChanged: (v) => setState(() => _query = v),
      style: HmType.row.copyWith(color: c.text),
      decoration: InputDecoration(
        hintText: 'Search',
        isDense: true,
        filled: true,
        fillColor: c.surface2,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
      ),
    ),
  );
}

class _BotRow extends StatelessWidget {
  const _BotRow({required this.summary, required this.onTap, this.onLongPress});

  final HmBotSummary summary;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final latest = summary.latest;
    final preview = latest == null
        ? ''
        : (latest.title.trim().isNotEmpty
              ? latest.title.trim()
              : latest.preview.trim());
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: HmMetrics.botRowHeight),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HmMetrics.edge,
            vertical: 10,
          ),
          child: Row(
            children: [
              HmCharacter(
                spec: summary.bot.character,
                size: HmMetrics.botAvatar,
                working: latest?.isActive ?? false,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            summary.bot.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HmType.row.copyWith(
                              color: c.text,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (latest != null)
                          Text(
                            _when(summary.lastActive),
                            style: HmType.caption.copyWith(color: c.text3),
                          ),
                      ],
                    ),
                    if (preview.isNotEmpty)
                      Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HmType.value.copyWith(color: c.text3),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _when(double seconds) {
    final t = DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
    final now = DateTime.now();
    final d = now.difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (now.year == t.year && now.month == t.month && now.day == t.day) {
      final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
      return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
    }
    if (d.inDays < 7)
      return const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][t.weekday -
          1];
    return '${t.month}/${t.day}/${t.year % 100}';
  }
}

/// "Start a new session": pick a bot (or start a group).
Future<HmBot?> showHmNewSessionSheet(BuildContext context, List<HmBot> bots) {
  final c = NgColors.of(context);
  return showModalBottomSheet<HmBot>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: c.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.92,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HmMetrics.edge,
              8,
              HmMetrics.edge,
              8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Start a new session',
                    style: HmType.screenTitle.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                HmRoundButton(
                  icon: Icons.group_outlined,
                  label: 'New group',
                  onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Groups are coming next')),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final b in bots)
                  InkWell(
                    onTap: () => Navigator.of(context).pop(b),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: HmMetrics.edge,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          HmCharacter(spec: b.character, size: 52),
                          const SizedBox(width: 16),
                          Text(
                            b.displayName,
                            style: HmType.row.copyWith(
                              color: c.text,
                              fontSize: 19,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
