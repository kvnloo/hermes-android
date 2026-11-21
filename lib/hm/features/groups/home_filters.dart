// Home's Filters menu: View, Sort, Recent sessions, Show, Agents, Include —
// the official home filter rows — and the rule that applies them to the list
// of bots and group chats.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../nextgen/theme/nextgen_theme.dart';
import '../../hm_bots.dart';
import '../../hm_ui.dart';
import 'groups_api.dart';

enum HmHomeSort { recent, name }

enum HmRecentWindow { day, threeDays, week }

enum HmHomeShow { all, unread }

@immutable
class HmHomeFilters {
  const HmHomeFilters({
    this.sort = HmHomeSort.recent,
    this.window = HmRecentWindow.day,
    this.show = HmHomeShow.all,
    this.hidden = const {},
    this.includeGroups = true,
    this.includeHidden = false,
  });

  final HmHomeSort sort;
  final HmRecentWindow window;
  final HmHomeShow show;

  /// Profiles of the agents the user hid.
  final Set<String> hidden;
  final bool includeGroups;
  final bool includeHidden;

  static const defaults = HmHomeFilters();

  bool get isDefault =>
      sort == defaults.sort &&
      window == defaults.window &&
      show == defaults.show &&
      hidden.isEmpty &&
      includeGroups == defaults.includeGroups &&
      includeHidden == defaults.includeHidden;

  HmHomeFilters copyWith({
    HmHomeSort? sort,
    HmRecentWindow? window,
    HmHomeShow? show,
    Set<String>? hidden,
    bool? includeGroups,
    bool? includeHidden,
  }) => HmHomeFilters(
    sort: sort ?? this.sort,
    window: window ?? this.window,
    show: show ?? this.show,
    hidden: hidden ?? this.hidden,
    includeGroups: includeGroups ?? this.includeGroups,
    includeHidden: includeHidden ?? this.includeHidden,
  );

  Duration get windowLength => switch (window) {
    HmRecentWindow.day => const Duration(days: 1),
    HmRecentWindow.threeDays => const Duration(days: 3),
    HmRecentWindow.week => const Duration(days: 7),
  };

  Map<String, dynamic> toJson() => {
    'sort': sort.name,
    'window': window.name,
    'show': show.name,
    'hidden': hidden.toList()..sort(),
    'include_groups': includeGroups,
    'include_hidden': includeHidden,
  };

  factory HmHomeFilters.fromJson(Map<String, dynamic> j) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.where((v) => v.name == name).firstOrNull ?? fallback;
    return HmHomeFilters(
      sort: pick(HmHomeSort.values, j['sort'], HmHomeSort.recent),
      window: pick(HmRecentWindow.values, j['window'], HmRecentWindow.day),
      show: pick(HmHomeShow.values, j['show'], HmHomeShow.all),
      hidden: {for (final h in (j['hidden'] as List? ?? const [])) '$h'},
      includeGroups: j['include_groups'] != false,
      includeHidden: j['include_hidden'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HmHomeFilters &&
      jsonEncode(toJson()) == jsonEncode(other.toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// The filters, kept on the device across launches.
class HmHomeFilterStore extends ValueNotifier<HmHomeFilters> {
  HmHomeFilterStore() : super(HmHomeFilters.defaults);

  static const _key = 'hm.home.filters.v1';

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return;
      final j = jsonDecode(raw);
      if (j is Map) {
        value = HmHomeFilters.fromJson(Map<String, dynamic>.from(j));
      }
    } catch (_) {
      // Unreadable saved filters fall back to the defaults.
    }
  }

  Future<void> set(HmHomeFilters next) async {
    value = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(next.toJson()));
    } catch (_) {}
  }
}

/// One Home row: a bot (with its latest chat in the window) or a group chat.
@immutable
sealed class HmHomeItem {
  const HmHomeItem();
  double get lastActive;
  String get name;
}

final class HmHomeBotItem extends HmHomeItem {
  const HmHomeBotItem(this.summary, {required this.recent});
  final HmBotSummary summary;

  /// The latest chat falls inside the Recent sessions window.
  final bool recent;
  @override
  double get lastActive => summary.lastActive;
  @override
  String get name => summary.bot.displayName;
}

final class HmHomeGroupItem extends HmHomeItem {
  const HmHomeGroupItem(this.room);
  final HmGroupRoom room;
  @override
  double get lastActive => room.updatedAt;
  @override
  String get name => room.name;
}

/// The result of applying filters: the rows, and why there are none.
@immutable
class HmHomeView {
  const HmHomeView(this.items, {this.allHidden = false});
  final List<HmHomeItem> items;

  /// Every agent is hidden (the official hint names the switch to flip).
  final bool allHidden;
}

/// Applies [f] to the host's bots and rooms. [query] is the search text.
HmHomeView applyHmHomeFilters(
  HmHomeFilters f, {
  required List<HmBotSummary> bots,
  required List<HmGroupRoom> rooms,
  required DateTime now,
  String query = '',
  Map<String, List<double>> unreadActivity = const {},
}) {
  final since = now.subtract(f.windowLength).millisecondsSinceEpoch / 1000;
  final q = query.trim().toLowerCase();
  final items = <HmHomeItem>[];
  final visibleBots = [
    for (final s in bots)
      if (f.includeHidden || !f.hidden.contains(s.bot.profile)) s,
  ];
  for (final s in visibleBots) {
    final recent = s.latest != null && s.lastActive >= since;
    if (f.show == HmHomeShow.unread) {
      final unread = (unreadActivity[s.bot.profile] ?? const <double>[]).any(
        (t) => t >= since,
      );
      if (!unread) continue;
    }
    if (q.isNotEmpty &&
        !s.bot.displayName.toLowerCase().contains(q) &&
        !(s.latest?.title.toLowerCase().contains(q) ?? false)) {
      continue;
    }
    items.add(HmHomeBotItem(s, recent: recent));
  }
  // Group chats carry no unread marker, so "Unread" leaves them out.
  if (f.includeGroups && f.show == HmHomeShow.all) {
    for (final r in rooms) {
      if (q.isNotEmpty && !r.name.toLowerCase().contains(q)) continue;
      items.add(HmHomeGroupItem(r));
    }
  }
  switch (f.sort) {
    case HmHomeSort.recent:
      items.sort((a, b) => b.lastActive.compareTo(a.lastActive));
    case HmHomeSort.name:
      items.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
  }
  return HmHomeView(items, allHidden: bots.isNotEmpty && visibleBots.isEmpty);
}

/// Unread chats' activity times per bot profile, for "Show: Unread".
Map<String, List<double>> hmUnreadActivity(HmBotsModel bots) => {
  for (final e in bots.sessions.entries)
    e.key: [
      for (final s in e.value)
        if (s.unread) (s.lastActive > 0 ? s.lastActive : s.startedAt),
    ],
};

// ── The menu ────────────────────────────────────────────────────────────────

const hmFilterEmpty = 'No agents match these filters.';
const hmAllHidden =
    'All agents are hidden. Turn on Hidden agents under Include in the filter menu.';
const hmResetFilters = 'Reset filters';

String _sortLabel(HmHomeSort s) => switch (s) {
  HmHomeSort.recent => 'Recent activity',
  HmHomeSort.name => 'Name',
};

String _windowLabel(HmRecentWindow w) => switch (w) {
  HmRecentWindow.day => 'Last day',
  HmRecentWindow.threeDays => 'Last 3 days',
  HmRecentWindow.week => 'Last week',
};

String _showLabel(HmHomeShow s) => switch (s) {
  HmHomeShow.all => 'All',
  HmHomeShow.unread => 'Unread',
};

String _agentsLabel(HmHomeFilters f, List<HmBot> bots) {
  final shown = bots.where((b) => !f.hidden.contains(b.profile)).length;
  if (shown == bots.length) return 'All';
  return '$shown of ${bots.length}';
}

String _includeLabel(HmHomeFilters f) {
  final parts = [
    if (f.includeGroups) 'Group chats',
    if (f.includeHidden) 'Hidden agents',
  ];
  return parts.isEmpty ? 'None' : parts.join(', ');
}

enum _Page { main, view, sort, window, show, agents, include }

/// Opens the Filters menu under [anchor] (the Filters button's context).
Future<void> showHmFilterMenu(
  BuildContext anchor, {
  required HmHomeFilterStore store,
  required List<HmBot> bots,
}) {
  final box = anchor.findRenderObject() as RenderBox?;
  final top = box == null
      ? 96.0
      : box.localToGlobal(Offset(0, box.size.height)).dy + 8;
  return showGeneralDialog<void>(
    context: anchor,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(anchor).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 140),
    transitionBuilder: (context, a, _, child) => FadeTransition(
      opacity: a,
      child: ScaleTransition(
        alignment: Alignment.topRight,
        scale: Tween(begin: 0.92, end: 1.0).animate(a),
        child: child,
      ),
    ),
    pageBuilder: (context, _, _) =>
        _FilterMenu(top: top, store: store, bots: bots),
  );
}

class _FilterMenu extends StatefulWidget {
  const _FilterMenu({
    required this.top,
    required this.store,
    required this.bots,
  });
  final double top;
  final HmHomeFilterStore store;
  final List<HmBot> bots;

  @override
  State<_FilterMenu> createState() => _FilterMenuState();
}

class _FilterMenuState extends State<_FilterMenu> {
  _Page page = _Page.main;

  HmHomeFilters get f => widget.store.value;

  void _set(HmHomeFilters next) {
    widget.store.set(next);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Stack(
      children: [
        Positioned(
          top: widget.top,
          right: HmMetrics.edge + 56,
          left: 64,
          child: Align(
            alignment: Alignment.topRight,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Material(
                color: c.surface,
                elevation: 6,
                shadowColor: c.text.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(HmMetrics.groupRadius),
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 120),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: page == _Page.main ? _main(c) : _sub(c),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _main(NgColors c) => [
    _MenuRow(
      icon: Icons.format_list_bulleted,
      title: 'View',
      subtitle: 'By agent',
      onTap: () => setState(() => page = _Page.view),
    ),
    _MenuRow(
      icon: Icons.swap_vert,
      title: 'Sort',
      subtitle: _sortLabel(f.sort),
      onTap: () => setState(() => page = _Page.sort),
    ),
    _MenuRow(
      icon: Icons.history,
      title: 'Recent sessions',
      subtitle: _windowLabel(f.window),
      onTap: () => setState(() => page = _Page.window),
    ),
    Divider(height: 9, indent: 20, endIndent: 20, color: c.stroke),
    _MenuRow(
      icon: Icons.inbox_outlined,
      title: 'Show',
      subtitle: _showLabel(f.show),
      onTap: () => setState(() => page = _Page.show),
    ),
    _MenuRow(
      icon: Icons.people_outline,
      title: 'Agents',
      subtitle: _agentsLabel(f, widget.bots),
      onTap: () => setState(() => page = _Page.agents),
    ),
    _MenuRow(
      icon: Icons.layers_outlined,
      title: 'Include',
      subtitle: _includeLabel(f),
      onTap: () => setState(() => page = _Page.include),
    ),
    if (!f.isDefault) ...[
      Divider(height: 9, indent: 20, endIndent: 20, color: c.stroke),
      _MenuRow(
        icon: Icons.restart_alt,
        title: hmResetFilters,
        onTap: () => _set(HmHomeFilters.defaults),
      ),
    ],
  ];

  List<Widget> _sub(NgColors c) {
    Widget back(String title) => _MenuRow(
      icon: Icons.arrow_back,
      title: title,
      bold: true,
      onTap: () => setState(() => page = _Page.main),
    );
    Widget radio<T>(String label, T value, T current, HmHomeFilters next) =>
        _MenuRow(
          title: label,
          checked: value == current,
          onTap: () {
            _set(next);
            setState(() => page = _Page.main);
          },
        );
    return switch (page) {
      _Page.view => [
        back('View'),
        _MenuRow(
          title: 'By agent',
          checked: true,
          onTap: () => setState(() => page = _Page.main),
        ),
      ],
      _Page.sort => [
        back('Sort'),
        for (final s in HmHomeSort.values)
          radio(_sortLabel(s), s, f.sort, f.copyWith(sort: s)),
      ],
      _Page.window => [
        back('Recent sessions'),
        for (final w in HmRecentWindow.values)
          radio(_windowLabel(w), w, f.window, f.copyWith(window: w)),
      ],
      _Page.show => [
        back('Show'),
        for (final s in HmHomeShow.values)
          radio(_showLabel(s), s, f.show, f.copyWith(show: s)),
      ],
      _Page.agents => [
        back('Agents'),
        for (final b in widget.bots)
          _MenuRow(
            title: b.displayName,
            checked: !f.hidden.contains(b.profile),
            checkbox: true,
            onTap: () {
              final hidden = {...f.hidden};
              if (!hidden.remove(b.profile)) hidden.add(b.profile);
              _set(f.copyWith(hidden: hidden));
            },
          ),
      ],
      _Page.include => [
        back('Include'),
        _MenuRow(
          title: 'Group chats',
          checked: f.includeGroups,
          checkbox: true,
          onTap: () => _set(f.copyWith(includeGroups: !f.includeGroups)),
        ),
        _MenuRow(
          title: 'Hidden agents',
          checked: f.includeHidden,
          checkbox: true,
          onTap: () => _set(f.copyWith(includeHidden: !f.includeHidden)),
        ),
      ],
      _Page.main => const [],
    };
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.title,
    required this.onTap,
    this.icon,
    this.subtitle,
    this.checked,
    this.checkbox = false,
    this.bold = false,
  });

  final IconData? icon;
  final String title;
  final String? subtitle;
  final bool? checked;
  final bool checkbox;
  final bool bold;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final mark = checked == null
        ? null
        : checkbox
        ? (checked! ? Icons.check_box : Icons.check_box_outline_blank)
        : (checked! ? Icons.check : null);
    return Semantics(
      selected: checked,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 24, color: c.text),
                const SizedBox(width: 20),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: HmType.row.copyWith(
                        color: c.text,
                        fontWeight: bold ? FontWeight.w600 : null,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: HmType.value.copyWith(color: c.text3),
                      ),
                  ],
                ),
              ),
              if (mark != null)
                Icon(mark, size: 22, color: c.accent)
              else if (subtitle != null)
                Icon(Icons.chevron_right, size: 20, color: c.text3),
            ],
          ),
        ),
      ),
    );
  }
}
