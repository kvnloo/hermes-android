import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/hm/features/groups/groups_api.dart';
import 'package:hermes_android/hm/features/groups/home_filters.dart';
import 'package:hermes_android/hm/hm_bots.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'groups_fakes.dart';

final now = DateTime.utc(2026, 11, 20, 12);
double ago(Duration d) => now.subtract(d).millisecondsSinceEpoch / 1000;

Session session(String id, double at, {bool unread = false}) =>
    Session.fromJson({
      'id': id,
      'title': 'chat $id',
      'started_at': at,
      'last_active': at,
      'unread': unread,
    });

List<HmBotSummary> summaries() {
  final b = testBots();
  return [
    HmBotSummary(b[0], session('a', ago(const Duration(hours: 2)))),
    HmBotSummary(b[1], session('b', ago(const Duration(days: 2)))),
    HmBotSummary(b[2], null),
  ];
}

final rooms = [
  HmGroupRoom.fromJson(
    roomJson(name: 'Crew', updatedAt: ago(const Duration(hours: 1))),
  ),
];

List<String> names(HmHomeView v) => [for (final i in v.items) i.name];

void main() {
  test('defaults: bots and group chats by recent activity', () {
    final v = applyHmHomeFilters(
      HmHomeFilters.defaults,
      bots: summaries(),
      rooms: rooms,
      now: now,
    );
    expect(names(v), ['Crew', 'Hermes', 'Atlas', 'Nova']);
    // Atlas's chat is two days old: outside "Last day", so no preview.
    final atlas = v.items[2] as HmHomeBotItem;
    expect(atlas.recent, isFalse);
  });

  test('Recent sessions widens what counts as recent', () {
    final v = applyHmHomeFilters(
      const HmHomeFilters(window: HmRecentWindow.threeDays),
      bots: summaries(),
      rooms: rooms,
      now: now,
    );
    expect((v.items[2] as HmHomeBotItem).recent, isTrue);
  });

  test('Sort by name, without group chats', () {
    final v = applyHmHomeFilters(
      const HmHomeFilters(sort: HmHomeSort.name, includeGroups: false),
      bots: summaries(),
      rooms: rooms,
      now: now,
    );
    expect(names(v), ['Atlas', 'Hermes', 'Nova']);
  });

  test('hidden agents leave unless Include has Hidden agents', () {
    const f = HmHomeFilters(hidden: {'atlas'});
    expect(
      names(
        applyHmHomeFilters(f, bots: summaries(), rooms: const [], now: now),
      ),
      ['Hermes', 'Nova'],
    );
    expect(
      names(
        applyHmHomeFilters(
          f.copyWith(includeHidden: true),
          bots: summaries(),
          rooms: const [],
          now: now,
        ),
      ),
      ['Hermes', 'Atlas', 'Nova'],
    );
    final all = applyHmHomeFilters(
      const HmHomeFilters(hidden: {'default', 'atlas', 'nova'}),
      bots: summaries(),
      rooms: const [],
      now: now,
    );
    expect(all.items, isEmpty);
    expect(all.allHidden, isTrue);
  });

  test('Show Unread keeps bots with an unread chat in the window', () {
    final v = applyHmHomeFilters(
      const HmHomeFilters(show: HmHomeShow.unread),
      bots: summaries(),
      rooms: rooms,
      now: now,
      unreadActivity: {
        'atlas': [ago(const Duration(hours: 3))],
        'nova': [ago(const Duration(days: 5))],
      },
    );
    expect(names(v), ['Atlas']);
  });

  test('search matches bot, chat title and group name', () {
    final v = applyHmHomeFilters(
      HmHomeFilters.defaults,
      bots: summaries(),
      rooms: rooms,
      now: now,
      query: 'cre',
    );
    expect(names(v), ['Crew']);
  });

  testWidgets('the Filters menu shows the official rows and applies Sort', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = HmHomeFilterStore();
    addTearDown(store.dispose);
    await tester.pumpWidget(
      host(
        Scaffold(
          body: Builder(
            builder: (anchor) => TextButton(
              onPressed: () =>
                  showHmFilterMenu(anchor, store: store, bots: testBots()),
              child: const Text('Filters'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    for (final t in [
      'View',
      'By agent',
      'Sort',
      'Recent activity',
      'Recent sessions',
      'Last day',
      'Show',
      'All',
      'Agents',
      'Include',
      'Group chats',
    ]) {
      expect(find.text(t), findsWidgets, reason: t);
    }

    await tester.tap(find.text('Sort'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name'));
    await tester.pumpAndSettle();
    expect(store.value.sort, HmHomeSort.name);
    expect(find.text('Name'), findsOneWidget); // the Sort row's value
    expect(find.text('Reset filters'), findsOneWidget);

    await tester.tap(find.text('Include'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Group chats'));
    await tester.pumpAndSettle();
    expect(store.value.includeGroups, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('hm.home.filters.v1'), contains('"sort":"name"'));
  });

  test('saved filters come back on the next launch', () async {
    SharedPreferences.setMockInitialValues({
      'hm.home.filters.v1':
          '{"sort":"name","window":"week","show":"all","hidden":["atlas"],'
          '"include_groups":false,"include_hidden":false}',
    });
    final store = HmHomeFilterStore();
    await store.load();
    expect(store.value.sort, HmHomeSort.name);
    expect(store.value.window, HmRecentWindow.week);
    expect(store.value.hidden, {'atlas'});
    expect(store.value.includeGroups, isFalse);
  });
}
