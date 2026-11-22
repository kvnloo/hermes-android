// Home's session tree: each bot row expands to its sessions, newest first,
// with "Show all (N)" for the full list and "+ New session" to start one.
// Sessions come from the rows HmBotsModel already reads per profile, so a
// collapsed bot costs nothing extra; a bot with no rows yet (or a failed
// read) is read once when it is expanded.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/models/session.dart';
import '../../../core/services/dashboard_api_client.dart';
import '../../../core/utils/session_sources.dart';
import '../../../nextgen/theme/nextgen_theme.dart';
import '../../../nextgen/ui/nextgen_scope.dart';
import '../../../nextgen/ui/sessions_sidebar.dart';
import '../../hm_bots.dart';
import '../../hm_ui.dart';

/// How many sessions an expanded bot lists before "Show all".
const hmTreeVisible = 5;

const hmTreeEmpty = 'No sessions yet';
const hmTreeLoading = 'Loading sessions…';
const hmTreeNewSession = 'New session';
const hmTreeRetry = 'Retry';

/// A bot's sessions as the tree lists them: chats only (no archived rows,
/// scheduler runs or empty cron shells), most recently active first.
List<Session> hmBotSessionRows(Iterable<Session> rows) {
  final out = [
    for (final s in rows)
      if (!s.archived && !isMachineSession(s) && !s.isUntitledCronShell) s,
  ];
  out.sort((a, b) => hmSessionTime(b).compareTo(hmSessionTime(a)));
  return out;
}

/// Last activity of [s] in epoch seconds.
double hmSessionTime(Session s) =>
    s.lastActive > 0 ? s.lastActive : s.startedAt;

/// A session's row label: its title, else its first user line.
String hmSessionLabel(Session s) {
  // A row without a title parses as 'Untitled'; its first line says more.
  final title = s.title.trim();
  if (title.isNotEmpty && title != 'Untitled') return title;
  final preview = s.preview.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (preview.isNotEmpty) return preview;
  return title.isNotEmpty ? title : hmTreeNewSession;
}

/// Home's short relative time: now, 5m, 3:04 PM, Mon, 11/2/26.
String hmWhen(double seconds, {DateTime? now}) {
  final t = DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
  final at = now ?? DateTime.now();
  final d = at.difference(t);
  if (d.inMinutes < 1) return 'now';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (at.year == t.year && at.month == t.month && at.day == t.day) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }
  if (d.inDays < 7) {
    return const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][t.weekday -
        1];
  }
  return '${t.month}/${t.day}/${t.year % 100}';
}

/// Which bots are expanded on Home, per host, kept across launches like the
/// Filters menu.
class HmExpandedBots extends ChangeNotifier {
  static const key = 'hm.home.expanded.v1';

  String _host = '';
  Map<String, Set<String>> _all = {};
  bool _disposed = false;

  Set<String> get profiles => _all[_host] ?? const {};

  bool isExpanded(String profile) => profiles.contains(profile);

  /// Reads the saved state and selects [host]'s set.
  Future<void> load(String host) async {
    _host = host;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw != null) {
        final j = jsonDecode(raw);
        if (j is Map) {
          _all = {
            for (final e in j.entries)
              if (e.value is List) '${e.key}': {for (final p in e.value) '$p'},
          };
        }
      }
    } catch (_) {
      // Unreadable: everything starts collapsed.
    }
    if (!_disposed) notifyListeners();
  }

  /// Flips [profile]; returns whether it is now expanded.
  bool toggle(String profile) {
    final set = {...profiles};
    final open = set.add(profile) || !set.remove(profile);
    _all = {..._all, _host: set};
    notifyListeners();
    unawaited(_save());
    return open;
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        key,
        jsonEncode({
          for (final e in _all.entries)
            if (e.value.isNotEmpty) e.key: e.value.toList()..sort(),
        }),
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Reads [bot]'s sessions when it is expanded and none are held yet, or the
/// last read failed. Rows already held (from the Home refresh or the device
/// cache) are used as they are: no request.
void hmEnsureBotSessions(HmBotsModel bots, HmBot bot) {
  final p = bot.profile;
  if (bots.loadingBot(p)) return;
  if (bots.sessions.containsKey(p) && !bots.sessionErrors.containsKey(p)) {
    return;
  }
  unawaited(bots.loadBotSessions(bot));
}

/// The expand control at the end of a bot row.
class HmTreeChevron extends StatelessWidget {
  const HmTreeChevron({
    super.key,
    required this.expanded,
    required this.onPressed,
    required this.botName,
  });

  final bool expanded;
  final VoidCallback onPressed;
  final String botName;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return IconButton(
      tooltip: expanded ? 'Hide $botName sessions' : 'Show $botName sessions',
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
      icon: AnimatedRotation(
        turns: expanded ? 0.5 : 0,
        duration: const Duration(milliseconds: 150),
        child: Icon(Icons.expand_more, color: c.text3),
      ),
    );
  }
}

/// The sessions under an expanded bot row.
class HmBotSessionTree extends StatelessWidget {
  const HmBotSessionTree({
    super.key,
    required this.bot,
    required this.bots,
    required this.onOpen,
    required this.onShowAll,
    this.onNewSession,
    this.matches,
  });

  final HmBot bot;
  final HmBotsModel bots;
  final ValueChanged<Session> onOpen;
  final VoidCallback onShowAll;

  /// Null hides the "+ New session" row (search results).
  final VoidCallback? onNewSession;

  /// While searching: the matching sessions to list instead of all of them.
  final List<Session>? matches;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final p = bot.profile;
    final held = bots.sessions[p];
    final rows = matches ?? hmBotSessionRows(held ?? const []);
    final error = bots.sessionErrors[p];
    final more = matches == null && (bots.sessionsHasMore[p] ?? false);
    final children = <Widget>[
      if (rows.isEmpty && matches == null)
        if (held == null || bots.loadingBot(p))
          _note(
            c,
            hmTreeLoading,
            leading: SizedBox.square(
              dimension: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: c.text3,
              ),
            ),
          )
        else if (error != null)
          _ErrorRow(
            message: error,
            onRetry: () => unawaited(bots.loadBotSessions(bot)),
          )
        else
          _note(c, hmTreeEmpty),
      for (final s in rows.take(hmTreeVisible))
        HmSessionRow(session: s, onTap: () => onOpen(s)),
      if (rows.length > hmTreeVisible || more)
        _ActionRow(
          key: ValueKey('hm-tree-show-all-$p'),
          label: 'Show all (${rows.length}${more ? '+' : ''})',
          onTap: onShowAll,
        ),
      if (onNewSession != null)
        _ActionRow(
          key: ValueKey('hm-tree-new-$p'),
          icon: Icons.add,
          label: hmTreeNewSession,
          onTap: onNewSession!,
        ),
    ];
    // A guide line under the avatar ties the rows to their bot.
    return Padding(
      key: ValueKey('hm-tree-$p'),
      padding: const EdgeInsets.only(
        left: HmMetrics.edge + HmMetrics.botAvatar / 2,
        bottom: 6,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: c.stroke)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }

  Widget _note(NgColors c, String text, {Widget? leading}) => Padding(
    padding: const EdgeInsets.fromLTRB(_indent, 8, HmMetrics.edge, 8),
    child: Row(
      children: [
        if (leading != null) ...[leading, const SizedBox(width: 8)],
        Expanded(
          child: Text(text, style: HmType.value.copyWith(color: c.text3)),
        ),
      ],
    ),
  );
}

/// Left inset of tree rows from the guide line: lines their text up with
/// the bot name.
const double _indent = HmMetrics.botAvatar / 2 + 12;

/// One session: state dot, title (or first line), relative time.
class HmSessionRow extends StatelessWidget {
  const HmSessionRow({
    super.key,
    required this.session,
    required this.onTap,
    this.indent = _indent,
    this.now,
  });

  final Session session;
  final VoidCallback onTap;
  final double indent;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final s = session;
    final running = s.isActive;
    final dot = running
        ? c.success
        : s.unread
        ? c.accent
        : null;
    final t = hmSessionTime(s);
    return Semantics(
      label: [
        hmSessionLabel(s),
        if (running) 'running',
        if (s.unread) 'unread',
      ].join(', '),
      button: true,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('hm-session-${s.id}'),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(indent - 14, 9, HmMetrics.edge, 9),
          child: Row(
            children: [
              SizedBox(
                width: 14,
                child: dot == null
                    ? null
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: dot,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
              ),
              Expanded(
                child: Text(
                  hmSessionLabel(s),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HmType.value.copyWith(
                    color: s.unread ? c.text : c.text2,
                    fontWeight: s.unread ? FontWeight.w700 : null,
                  ),
                ),
              ),
              if (t > 0) ...[
                const SizedBox(width: 8),
                Text(
                  hmWhen(t, now: now),
                  style: HmType.caption.copyWith(color: c.text3),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
  });

  final String label;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          icon == null ? _indent : _indent - 4,
          9,
          HmMetrics.edge,
          9,
        ),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: c.accentText),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: HmType.value.copyWith(
                color: c.accentText,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(_indent, 4, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              "Couldn't load sessions: $message",
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: HmType.value.copyWith(color: c.danger),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text(hmTreeRetry)),
        ],
      ),
    );
  }
}

/// "Show all": every session of one bot, through the same session list
/// model as the chat drawer, scoped to the bot's profile. Search and paging
/// are the drawer's.
class HmBotSessionsScreen extends StatefulWidget {
  const HmBotSessionsScreen({
    super.key,
    required this.bot,
    required this.api,
    required this.onOpen,
    required this.onNewSession,
  });

  final HmBot bot;
  final DashboardApiClient api;

  /// Opens a chat; the list reads again when it resolves.
  final Future<void> Function(BuildContext context, Session session) onOpen;
  final Future<void> Function(BuildContext context) onNewSession;

  @override
  State<HmBotSessionsScreen> createState() => _HmBotSessionsScreenState();
}

class _HmBotSessionsScreenState extends State<HmBotSessionsScreen> {
  NgSessionsModel? _model;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 400) _model?.loadMore();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_model == null) {
      final model = _model = NgSessionsModel(
        NgScope.of(context),
        apiOverride: widget.api,
      );
      unawaited(model.refresh());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _model?.dispose();
    super.dispose();
  }

  Future<void> _open(Session s) async {
    await widget.onOpen(context, s);
    if (mounted) unawaited(_model?.refresh());
  }

  Future<void> _new() async {
    await widget.onNewSession(context);
    if (mounted) unawaited(_model?.refresh());
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final model = _model!;
    return Scaffold(
      backgroundColor: c.background,
      body: Column(
        children: [
          HmTopBar(
            leading: const HmBackButton(),
            title: widget.bot.displayName,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HmMetrics.edge,
              0,
              HmMetrics.edge,
              8,
            ),
            child: TextField(
              key: const Key('hm-bot-sessions-search'),
              onChanged: model.search,
              style: HmType.row.copyWith(color: c.text),
              decoration: InputDecoration(
                hintText: 'Search sessions',
                isDense: true,
                filled: true,
                fillColor: c.surface2,
                prefixIcon: Icon(Icons.search, color: c.text3, size: 20),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: model,
              builder: (context, _) {
                final rows = model.sessions
                    .where((s) => !isCronSession(s) && !s.archived)
                    .toList();
                return RefreshIndicator(
                  onRefresh: model.refresh,
                  child: ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.only(bottom: 32),
                    children: [
                      _ActionRow(
                        key: const Key('hm-bot-sessions-new'),
                        icon: Icons.add,
                        label: hmTreeNewSession,
                        onTap: _new,
                      ),
                      if (model.error != null && rows.isEmpty)
                        _ErrorRow(
                          message: model.error!,
                          onRetry: () => unawaited(model.refresh()),
                        )
                      else if (rows.isEmpty && model.loading)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (rows.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            model.query.isEmpty
                                ? hmTreeEmpty
                                : 'No sessions match.',
                            textAlign: TextAlign.center,
                            style: HmType.value.copyWith(color: c.text3),
                          ),
                        ),
                      for (final s in rows)
                        HmSessionRow(
                          session: s,
                          indent: HmMetrics.edge + 14,
                          onTap: () => _open(s),
                        ),
                      if (model.hasMore && model.query.isEmpty)
                        Center(
                          child: TextButton(
                            onPressed: model.loading ? null : model.loadMore,
                            child: const Text('Load more'),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
