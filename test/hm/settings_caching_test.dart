import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/features/settings/cache_screen.dart';
import 'package:hermes_android/hm/features/settings/cache_store.dart';
import 'package:hermes_android/hm/features/settings/cache_sync.dart';
import 'package:hermes_android/hm/features/settings/settings_prefs.dart';
import 'package:hermes_android/hm/hm_bots.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings_support.dart';

Session _session(String id, double at) => Session.fromJson({
  'id': id,
  'title': 'Chat $id',
  'preview': 'hello',
  'started_at': at,
  'last_active': at,
});

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hm_cache_test');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  HmCacheStore storeWith(HmSettingsPrefs settings) =>
      HmCacheStore(root: () async => tmp, prefs: settings);

  /// Pumps the page with real file IO and lets its usage read finish.
  Future<void> pumpPage(WidgetTester tester, HmCacheStore store) async {
    phoneSize(tester);
    await tester.runAsync(() async {
      await tester.pumpWidget(hmTestApp(HmCachingScreen(store: store)));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
  }

  /// Real file IO completes outside the fake clock; alternate both until
  /// the page's chain of reads and writes is through.
  /// Lets the store's real file I/O run. With [until], keeps going (up to
  /// ~5 s) until it holds, so a loaded machine can't outrun a fixed budget.
  Future<void> settle(WidgetTester tester, {bool Function()? until}) async {
    for (var i = 0; i < (until == null ? 5 : 100); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      if (until != null && until()) return;
    }
  }

  group('Caching page', () {
    testWidgets('empty: shows the official controls and zero usage', (
      tester,
    ) async {
      final settings = await loadedSettings();
      await pumpPage(tester, storeWith(settings));

      expect(find.text('Caching'), findsOneWidget);
      expect(find.text('Cached On This Device'), findsOneWidget);
      expect(
        find.text(
          'Titles, previews and dates, so the list is there before the server answers.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Turning one off deletes what was already kept for it. Nothing is removed from the server.',
        ),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(find.text('Keep Up To: 100 chats'), 200);
      expect(find.text('Keep Up To: 100 chats'), findsOneWidget);
      expect(find.text('A good balance for daily use.'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('FILES & LINKS'), 200);
      expect(find.text('0 bytes'), findsOneWidget);
      expect(find.text('0 chats'), findsOneWidget);
      expect(
        find.text('Older items are dropped first once the limit is reached.'),
        findsOneWidget,
      );
    });

    testWidgets('loaded: usage counts what is on disk', (tester) async {
      final settings = await loadedSettings();
      final store = storeWith(settings);
      await tester.runAsync(() async {
        await store.putChatList(
          'c1',
          'default',
          bot: {'name': 'default'},
          sessions: [_session('a', 1), _session('b', 2)],
        );
        await store.putMessages('c1', 'a', [
          {'role': 'user', 'content': 'hi'},
        ]);
        await store.putFiles('c1', 'a', [
          {'url': 'https://example.com'},
          {'path': '/tmp/x.png'},
          {'path': '/tmp/y.pdf'},
        ]);
      });
      await pumpPage(tester, store);
      await tester.scrollUntilVisible(find.text('FILES & LINKS'), 200);

      expect(find.text('1 chat'), findsOneWidget);
      expect(find.text('2'), findsOneWidget); // chat list
      expect(find.text('3'), findsOneWidget); // files & links
      expect(find.text('0 bytes'), findsNothing);
      expect(find.textContaining('bytes'), findsOneWidget);
    });

    testWidgets('turning Messages off deletes them and persists', (
      tester,
    ) async {
      final settings = await loadedSettings();
      final store = storeWith(settings);
      await tester.runAsync(
        () => store.putMessages('c1', 'a', [
          {'role': 'user', 'content': 'hi'},
        ]),
      );
      await pumpPage(tester, store);

      await tester.tap(find.text('Messages').first);
      await tester.pump();
      await settle(tester);

      expect(settings.cacheMessages, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(HmSettingsPrefs.cacheMessagesKey), isFalse);
      expect(Directory('${tmp.path}/messages').existsSync(), isFalse);
      await tester.scrollUntilVisible(find.text('FILES & LINKS'), 200);
      // The usage line re-reads the cache from disk after the delete.
      await settle(
        tester,
        until: () => find.text('0 chats').evaluate().isNotEmpty,
      );
      expect(find.text('0 chats'), findsOneWidget);
    });

    testWidgets('choosing a limit persists it and shows its note', (
      tester,
    ) async {
      final settings = await loadedSettings();
      await pumpPage(tester, storeWith(settings));

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('hm-cache-limit')),
        200,
      );
      await tester.tap(find.byKey(const ValueKey('hm-cache-limit')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('25 chats').last);
      await tester.pump();
      await settle(tester);

      expect(settings.cacheLimit, HmCacheLimit.small);
      expect(find.text('Keep Up To: 25 chats'), findsOneWidget);
      expect(
        find.text(
          'Smallest footprint. Only the conversations you opened most recently can be read offline.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('error: an unreadable cache says so', (tester) async {
      final settings = await loadedSettings();
      final store = HmCacheStore(
        root: () async => throw const FileSystemException('denied'),
        prefs: settings,
      );
      await pumpPage(tester, store);
      await tester.scrollUntilVisible(
        find.text("Couldn't read what is kept on this device."),
        200,
      );
      expect(
        find.text("Couldn't read what is kept on this device."),
        findsOneWidget,
      );
    });
  });

  group('Cache store', () {
    test('keeps at most the limit, dropping the oldest', () async {
      final settings = await loadedSettings(
        values: {HmSettingsPrefs.cacheLimitKey: 'small'},
      );
      final store = storeWith(settings);
      for (var i = 0; i < 27; i++) {
        await store.putMessages('c1', 's$i', [
          {'n': i},
        ]);
        // Distinct modification times.
        await File(
          '${tmp.path}/messages/c1/s$i.json',
        ).setLastModified(DateTime(2026, 1, 1, 0, i));
      }
      await store.enforceLimit();
      final usage = await store.usage();
      expect(usage.messageChats, 25);
      expect(await store.readMessages('c1', 's0'), isNull);
      expect(await store.readMessages('c1', 's26'), [
        {'n': 26},
      ]);
    });

    test('keeps nothing for a kind that is off', () async {
      final settings = await loadedSettings(
        values: {HmSettingsPrefs.cacheChatListKey: false},
      );
      final store = storeWith(settings);
      await store.putChatList(
        'c1',
        'default',
        bot: {'name': 'default'},
        sessions: [_session('a', 1)],
      );
      expect((await store.usage()).bots, 0);
      expect(await store.readChatList('c1'), isEmpty);
    });

    test('formats sizes like the official page', () {
      expect(hmFormatBytes(181), '181 bytes');
      expect(hmFormatBytes(2048), '2.0 KB');
      expect(hmFormatBytes(5 * 1024 * 1024), '5.0 MB');
    });

    test('the chat list round-trips through the bots model', () async {
      final settings = await loadedSettings();
      final store = storeWith(settings);
      final prefs = await SharedPreferences.getInstance();
      final conn = SavedConnection(
        id: 'c1',
        label: 'Home',
        host: '10.0.0.5',
        port: 9119,
        apiKey: '',
        desktopGatewayUrl: 'http://10.0.0.5:9119',
        singleLogin: true,
        signInMethod: 'none',
      );
      expect(prefs, isNotNull);
      final bots = HmBotsModel(NextGenGateway(conn));
      final detach = hmAttachChatListCache(bots, 'c1', store: store);
      bots.bots = [
        HmBot.fromJson({'name': 'default', 'display_name': 'Hermes'}),
        HmBot.fromJson({'name': 'coder', 'model': 'm1'}),
      ];
      bots.sessions['default'] = [_session('a', 5), _session('b', 9)];
      bots.sessions['coder'] = const [];
      // A finished refresh notifies listeners.
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      bots.notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      detach();

      final cached = await hmCachedBots('c1', store: store);
      expect(cached.bots.map((b) => b.displayName), ['Hermes', 'Coder']);
      expect(cached.bots.last.model, 'm1');
      expect(cached.sessions['default']!.map((s) => s.title), [
        'Chat b',
        'Chat a',
      ]);
      bots.dispose();
    });
  });
}
