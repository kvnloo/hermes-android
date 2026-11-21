// Keeps the chat-list cache in step with a host's bots: every time the bots
// model settles with fresh data it is written down, and [hmCachedBots]
// gives a cold start something to show before `GET /api/profiles` answers.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/models/session.dart';
import '../../hm_bots.dart';
import 'cache_store.dart';

/// The profile row [HmBot.fromJson] reads back.
Map<String, dynamic> hmBotToJson(HmBot b) => {
  'name': b.profile,
  'is_default': b.isDefault,
  'display_name': b.displayName,
  'model': b.model,
  'provider': b.provider,
  'skill_count': b.skillCount,
  'description': b.description,
  'ui_meta': b.uiMeta,
};

/// Writes [bots]'s chat list to [store] whenever a refresh finishes without
/// error. Returns the detach callback.
VoidCallback hmAttachChatListCache(
  HmBotsModel bots,
  String host, {
  HmCacheStore? store,
}) {
  final s = store ?? HmCacheStore.instance;
  void write() {
    if (bots.loading || bots.error != null || bots.bots.isEmpty) return;
    for (final b in bots.bots) {
      unawaited(
        s
            .putChatList(
              host,
              b.profile,
              bot: hmBotToJson(b),
              sessions: bots.sessions[b.profile] ?? const [],
            )
            .catchError((Object _) {}),
      );
    }
  }

  bots.addListener(write);
  return () => bots.removeListener(write);
}

/// The kept bots and chats for [host], ready to seed [HmBotsModel] before
/// its first refresh lands. Empty when nothing is kept.
Future<({List<HmBot> bots, Map<String, List<Session>> sessions})>
hmCachedBots(String host, {HmCacheStore? store}) async {
  final rows = await (store ?? HmCacheStore.instance).readChatList(host);
  final names = [for (final r in rows) (r.bot['name'] ?? 'default').toString()]
    ..sort();
  final bots = <HmBot>[];
  final sessions = <String, List<Session>>{};
  for (final r in rows) {
    final bot = HmBot.fromJson(
      r.bot,
      rank: names.indexOf((r.bot['name'] ?? 'default').toString()),
    );
    bots.add(bot);
    sessions[bot.profile] = r.sessions;
  }
  bots.sort((a, b) => a.isDefault == b.isDefault ? 0 : (a.isDefault ? -1 : 1));
  return (bots: bots, sessions: sessions);
}
