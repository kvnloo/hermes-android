// Home: the host's bots and group chats, most recently active first (or as
// the Filters menu orders them). A bot opens its latest chat, a group opens
// its room; the compose button starts a new session or a new group.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/session.dart';
import '../../core/services/android_launch_intent_service.dart';
import '../../core/services/android_share_intent_service.dart';
import '../../nextgen/data/chat_controller.dart';
import '../../nextgen/data/nextgen_gateway.dart';
import '../../nextgen/theme/nextgen_theme.dart';
import '../../nextgen/ui/nextgen_scope.dart';
import '../../nextgen/ui/scheduled_page.dart';
import '../features/artifacts/hm_artifacts.dart';
import '../features/council/hm_council.dart';
import '../features/groups/hm_groups.dart';
import '../features/groups/home_filters.dart';
import '../features/live/hm_live.dart';
import '../features/settings/cache_sync.dart';
import '../features/settings/app_lock.dart';
import '../features/terminal/hm_terminal.dart';
import '../features/work/hm_execution.dart';
import '../hm_bots.dart';
import '../avatar/hm_avatar.dart';
import '../avatar/hm_avatar_state.dart';
import '../hm_ui.dart';
import 'hm_agent_screen.dart';
import 'hm_chat_screen.dart';
import 'hm_bot_import.dart';
import 'hm_settings_screen.dart';

/// Opens one of [bot]'s chats as Home does: the stored chat [sessionId]
/// (its transcript loads at once), or a new chat when null. The chat menu
/// works in full (Live, Terminal, Execution, Artifacts, Archive, Delete), and
/// [bots] is refreshed when a new chat is stored and when the chat closes.
/// Any feature screen can call this to open a chat row.
Future<void> hmOpenChat(
  BuildContext context, {
  required HmBot bot,
  required HmBotsModel bots,
  String? sessionId,
  String title = '',
  bool live = false,
  AndroidSharePayload? sharedDraft,
}) async {
  final chat = NgChatController(
    bots.gateway,
    sessionId: sessionId,
    title: title,
    profile: bot.scope,
    onCreated: (_) => bots.refresh(),
  );
  if (sessionId != null) unawaited(chat.open());
  if (live) {
    await openHmLive(context, bot: bot, bots: bots, chat: chat);
  } else {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (route) => HmChatScreen(
          bot: bot,
          chat: chat,
          sharedDraft: sharedDraft,
          onNewChat: () {
            Navigator.of(route).pop();
            // The caller's context outlives this route.
            if (context.mounted) {
              unawaited(hmOpenChat(context, bot: bot, bots: bots));
            }
          },
          onOpenBot: () => hmOpenAgent(route, bot, bots),
          onAction: (a) => hmChatAction(route, bot, bots, chat, a),
        ),
      ),
    );
  }
  chat.dispose();
  unawaited(bots.refresh());
}

/// Agent settings for [bot].
Future<void> hmOpenAgent(BuildContext context, HmBot bot, HmBotsModel bots) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HmAgentScreen(bot: bot, bots: bots),
      ),
    );

/// Runs one chat-menu action for [chat].
Future<void> hmChatAction(
  BuildContext context,
  HmBot bot,
  HmBotsModel bots,
  NgChatController chat,
  HmChatAction a,
) async {
  switch (a) {
    case HmChatAction.chatSettings:
      await showHmChatSettings(context, chat);
    case HmChatAction.archive:
      final id = chat.storedId;
      if (id == null) return;
      await bots
          .apiFor(bot)
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
          content: const Text('It is removed from the host for every device.'),
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
      await bots.apiFor(bot).deleteSession(id).catchError((_) {});
      if (context.mounted) Navigator.of(context).pop();
    case HmChatAction.liveMode:
      await openHmLive(context, bot: bot, bots: bots, chat: chat);
    case HmChatAction.terminal:
      await openHmTerminal(context, bot: bot, bots: bots, chat: chat);
    case HmChatAction.execution:
      await openHmExecution(context, bot: bot, bots: bots, chat: chat);
    case HmChatAction.routines:
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => NgScheduledPage(
            onOpenSession: (_) => Navigator.of(context).pop(),
          ),
        ),
      );
    case HmChatAction.artifacts:
      await openHmArtifacts(context, bot: bot, bots: bots, chat: chat);
    case HmChatAction.council:
      await openHmCouncil(context);
  }
}

class HmHome extends StatefulWidget {
  const HmHome({super.key, this.launchIntents, this.shareIntents});

  final AndroidLaunchIntentService? launchIntents;
  final AndroidShareIntentService? shareIntents;

  @override
  State<HmHome> createState() => _HmHomeState();
}

class _HmHomeState extends State<HmHome> with WidgetsBindingObserver {
  HmBotsModel? _bots;
  VoidCallback? _detachCache;
  HmGroupsDirectory? _groups;
  final _filters = HmHomeFilterStore();
  final _groupChanges = StreamController<List<String>?>.broadcast();
  NextGenGateway? _gateway;
  StreamSubscription<dynamic>? _changes;
  Timer? _debounce;
  Timer? _groupDebounce;
  String _query = '';
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_filters.load());
    widget.launchIntents?.pendingDestination.addListener(_scheduleEntry);
    widget.launchIntents?.pendingQuickChat.addListener(_scheduleEntry);
    widget.shareIntents?.pendingShare.addListener(_scheduleEntry);
    HmAppLock.instance.addListener(_scheduleEntry);
    _scheduleEntry();
  }

  bool _entryScheduled = false;

  void _scheduleEntry() {
    if (_entryScheduled) return;
    _entryScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _entryScheduled = false;
      if (mounted && !HmAppLock.instance.locked) _openEntry();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _openEntry() {
    final intents = widget.launchIntents;
    final bots = _bots;
    if (bots == null) return;
    final destination =
        intents?.pendingDestination.value ??
        (intents?.pendingQuickChat.value == true
            ? AndroidEntryDestination.newChat
            : null);
    final shared = widget.shareIntents?.takePendingShare();
    if (destination == null && shared == null) return;
    final document = intents?.pendingBotDocument;
    if (intents != null) {
      intents.pendingBotDocument = null;
      intents.pendingDestination.value = null;
      intents.takePendingQuickChat();
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
    if (shared == null && destination == AndroidEntryDestination.sessions) {
      return;
    }
    if (shared == null && destination == AndroidEntryDestination.routines) {
      unawaited(
        Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (route) => NgScheduledPage(
              onOpenSession: (_) => Navigator.of(route).pop(),
            ),
          ),
        ),
      );
      return;
    }
    if (shared == null && destination == AndroidEntryDestination.botImport) {
      unawaited(() async {
        final bot = await Navigator.of(context).push<HmBot>(
          MaterialPageRoute(
            builder: (_) => HmBotImport(document: document, bots: bots),
          ),
        );
        if (bot != null && mounted) {
          await hmOpenChat(context, bot: bot, bots: bots);
        }
      }());
      return;
    }

    final profile = bots.gateway.profile ?? 'default';
    final bot = bots.byProfile(profile) ?? HmBot.fromJson({'name': profile});
    unawaited(
      hmOpenChat(
        context,
        bot: bot,
        bots: bots,
        live:
            shared == null && destination == AndroidEntryDestination.liveVoice,
        sharedDraft: shared,
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final gateway = NgScope.of(context).gateway;
    if (!identical(gateway, _gateway)) {
      _gateway = gateway;
      _detachCache?.call();
      _bots?.dispose();
      final bots = _bots = HmBotsModel(gateway);
      // A cold start shows the kept chat list until the host answers.
      unawaited(bots.seedFromCache(gateway.connection.id));
      unawaited(bots.refresh());
      _detachCache = hmAttachChatListCache(bots, gateway.connection.id);
      _groups?.dispose();
      _groups = HmGroupsDirectory(hmGroupsApiFor(gateway))..refresh();
      _changes?.cancel();
      _changes = gateway.events.listen((e) {
        if (e.type == 'groups.changed') {
          final ids = e.data['room_ids'];
          _groupChanges.add(ids is List ? [for (final i in ids) '$i'] : null);
          _groupDebounce?.cancel();
          _groupDebounce = Timer(
            const Duration(seconds: 1),
            () => _groups?.refresh(),
          );
          return;
        }
        if (e.type != 'sessions.changed' && e.type != 'session.title') return;
        _debounce?.cancel();
        _debounce = Timer(const Duration(seconds: 2), () => _bots?.refresh());
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_bots?.refresh());
      unawaited(_groups?.refresh());
    }
  }

  @override
  void dispose() {
    widget.launchIntents?.pendingDestination.removeListener(_scheduleEntry);
    widget.launchIntents?.pendingQuickChat.removeListener(_scheduleEntry);
    widget.shareIntents?.pendingShare.removeListener(_scheduleEntry);
    HmAppLock.instance.removeListener(_scheduleEntry);
    WidgetsBinding.instance.removeObserver(this);
    _changes?.cancel();
    _debounce?.cancel();
    _groupDebounce?.cancel();
    _groupChanges.close();
    _detachCache?.call();
    _bots?.dispose();
    _groups?.dispose();
    _filters.dispose();
    super.dispose();
  }

  Future<void> _openChat(HmBot bot, {Session? session}) => hmOpenChat(
    context,
    bot: bot,
    bots: _bots!,
    sessionId: session?.id,
    title: session?.title ?? '',
  );

  Future<void> _openAgent(HmBot bot) => hmOpenAgent(context, bot, _bots!);

  Future<void> _newSession() async {
    final bots = _bots;
    final groups = _groups;
    if (bots == null || groups == null) return;
    final picked = await showHmNewSessionSheet(
      context,
      bots.bots,
      groups: groups,
    );
    if (!mounted) return;
    switch (picked) {
      case HmNewBotChat(:final bot):
        await _openChat(bot);
      case HmNewGroupChat(:final room):
        await _openGroup(room);
      case null:
        break;
    }
  }

  Future<void> _openGroup(HmGroupRoom room) async {
    final groups = _groups;
    if (groups == null) return;
    await openHmGroup(
      context,
      room: room,
      api: groups.api,
      bots: _bots,
      changes: _groupChanges.stream,
      directory: groups,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final bots = _bots!;
    final groups = _groups!;
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
                Builder(
                  builder: (anchor) => HmRoundButton(
                    icon: Icons.filter_list,
                    label: 'Filters',
                    onPressed: () => showHmFilterMenu(
                      anchor,
                      store: _filters,
                      bots: bots.bots,
                    ),
                  ),
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
              listenable: Listenable.merge([
                bots,
                groups,
                _filters,
                NgScope.of(context).gateway,
              ]),
              builder: (context, _) {
                final view = applyHmHomeFilters(
                  _filters.value,
                  bots: bots.summaries,
                  rooms: groups.rooms,
                  now: DateTime.now(),
                  query: _query,
                  unreadActivity: hmUnreadActivity(bots),
                );
                final rows = view.items;
                if (bots.loading && bots.bots.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (bots.error != null && bots.bots.isEmpty) {
                  return _message(c, bots.error!);
                }
                if (rows.isEmpty && bots.bots.isNotEmpty) {
                  return _message(
                    c,
                    view.allHidden ? hmAllHidden : hmFilterEmpty,
                    action: _filters.value.isDefault
                        ? null
                        : TextButton(
                            onPressed: () =>
                                _filters.set(HmHomeFilters.defaults),
                            child: const Text(hmResetFilters),
                          ),
                  );
                }
                return RefreshIndicator(
                  onRefresh: () =>
                      Future.wait([bots.refresh(), groups.refresh()]),
                  child: ListView.builder(
                    padding: const EdgeInsets.only(top: 4, bottom: 96),
                    itemCount: rows.length,
                    itemBuilder: (context, i) => switch (rows[i]) {
                      HmHomeBotItem(:final summary, :final recent) => _BotRow(
                        summary: summary,
                        showLatest: recent,
                        onTap: () =>
                            _openChat(summary.bot, session: summary.latest),
                        onLongPress: () => _openAgent(summary.bot),
                      ),
                      HmHomeGroupItem(:final room) => HmGroupRow(
                        room: room,
                        bots: bots,
                        when: _BotRow._when(room.updatedAt),
                        onTap: () => _openGroup(room),
                      ),
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _message(NgColors c, String text, {Widget? action}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: HmType.body.copyWith(color: c.text3),
          ),
          if (action != null) ...[const SizedBox(height: 8), action],
        ],
      ),
    ),
  );

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
  const _BotRow({
    required this.summary,
    required this.onTap,
    this.onLongPress,
    this.showLatest = true,
  });

  final HmBotSummary summary;

  /// The latest chat is inside the Recent sessions window.
  final bool showLatest;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final latest = showLatest ? summary.latest : null;
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
              HmAvatar(
                spec: summary.bot.character,
                size: HmMetrics.botAvatar,
                state: (latest?.isActive ?? false)
                    ? HmAvatarState.thinking
                    : HmAvatarState.idle,
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
    if (d.inDays < 7) {
      return const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][t.weekday -
          1];
    }
    return '${t.month}/${t.day}/${t.year % 100}';
  }
}
