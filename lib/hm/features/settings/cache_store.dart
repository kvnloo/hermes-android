// What Hermes keeps on this device so screens show before the server
// answers: each host's bots and chat list, whole conversations, and the
// files and links found in recent chats. One JSON file per bot / chat under
// the app's support directory. The Caching page reads its usage here and
// turning a kind off deletes what was kept for it; nothing on the server is
// touched.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/models/session.dart';
import 'settings_prefs.dart';

/// The three kinds of thing the device can keep.
enum HmCacheKind {
  chatList('chat_list'),
  messages('messages'),
  files('files');

  const HmCacheKind(this.dir);
  final String dir;
}

/// What the Usage card shows.
@immutable
class HmCacheUsage {
  const HmCacheUsage({
    required this.bytes,
    required this.bots,
    required this.chatList,
    required this.messageChats,
    required this.files,
  });

  static const empty = HmCacheUsage(
    bytes: 0,
    bots: 0,
    chatList: 0,
    messageChats: 0,
    files: 0,
  );

  final int bytes;
  final int bots;
  final int chatList;
  final int messageChats;
  final int files;
}

/// "181 bytes", "12.4 KB", "3.1 MB".
String hmFormatBytes(int bytes) {
  if (bytes < 1024) return bytes == 1 ? '1 byte' : '$bytes bytes';
  const units = ['KB', 'MB', 'GB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}

class HmCacheStore {
  HmCacheStore({
    Future<Directory> Function()? root,
    HmSettingsPrefs? prefs,
  }) : _rootFn = root ?? _defaultRoot,
       prefs = prefs ?? HmSettingsPrefs.instance;

  static final HmCacheStore instance = HmCacheStore();

  final Future<Directory> Function() _rootFn;
  final HmSettingsPrefs prefs;
  Directory? _root;

  static Future<Directory> _defaultRoot() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/hm_cache');

  Future<Directory> _dir(HmCacheKind kind, [String? host]) async {
    final root = _root ??= await _rootFn();
    final path = host == null
        ? '${root.path}/${kind.dir}'
        : '${root.path}/${kind.dir}/${_safe(host)}';
    return Directory(path);
  }

  /// File-name-safe form of an id.
  static String _safe(String id) =>
      id.isEmpty ? '_' : id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  bool _enabled(HmCacheKind kind) => switch (kind) {
    HmCacheKind.chatList => prefs.cacheChatList,
    HmCacheKind.messages => prefs.cacheMessages,
    HmCacheKind.files => prefs.cacheFiles,
  };

  Future<void> _write(File f, Object json) async {
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(f.path);
  }

  Future<Map<String, dynamic>?> _read(File f) async {
    try {
      if (!await f.exists()) return null;
      final v = jsonDecode(await f.readAsString());
      return v is Map ? Map<String, dynamic>.from(v) : null;
    } catch (_) {
      return null;
    }
  }

  // ---- Chat list ---------------------------------------------------------

  /// Keeps [bot]'s profile row and its newest chats (up to the limit).
  Future<void> putChatList(
    String host,
    String profile, {
    required Map<String, dynamic> bot,
    required List<Session> sessions,
  }) async {
    if (!_enabled(HmCacheKind.chatList)) return;
    final sorted = [...sessions]
      ..sort((a, b) => b.lastActive.compareTo(a.lastActive));
    final kept = sorted.take(prefs.cacheLimit.chats);
    final dir = await _dir(HmCacheKind.chatList, host);
    await _write(File('${dir.path}/${_safe(profile)}.json'), {
      'bot': bot,
      'sessions': [for (final s in kept) sessionToJson(s)],
    });
  }

  /// Every kept bot on [host] with its chats, newest first.
  Future<List<({Map<String, dynamic> bot, List<Session> sessions})>>
  readChatList(String host) async {
    if (!_enabled(HmCacheKind.chatList)) return const [];
    final dir = await _dir(HmCacheKind.chatList, host);
    if (!await dir.exists()) return const [];
    final out = <({Map<String, dynamic> bot, List<Session> sessions})>[];
    await for (final f in dir.list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      final j = await _read(f);
      if (j == null || j['bot'] is! Map) continue;
      final rows = j['sessions'] is List ? j['sessions'] as List : const [];
      out.add((
        bot: Map<String, dynamic>.from(j['bot'] as Map),
        sessions: [
          for (final r in rows.whereType<Map>())
            Session.fromJson(Map<String, dynamic>.from(r)),
        ],
      ));
    }
    return out;
  }

  /// The fields the chat list shows: titles, previews and dates.
  static Map<String, dynamic> sessionToJson(Session s) => {
    'id': s.id,
    'title': s.title,
    'model': s.model,
    'source': s.source,
    'message_count': s.messageCount,
    'preview': s.preview,
    'started_at': s.startedAt,
    'ended_at': ?s.endedAt,
    'last_active': s.lastActive,
    'pinned': s.pinned,
    'archived': s.archived,
  };

  // ---- Messages ----------------------------------------------------------

  /// Keeps one conversation's rows, then drops the least recently kept
  /// chats beyond the limit.
  Future<void> putMessages(
    String host,
    String sessionId,
    List<Map<String, dynamic>> rows,
  ) async {
    if (!_enabled(HmCacheKind.messages)) return;
    final dir = await _dir(HmCacheKind.messages, host);
    await _write(File('${dir.path}/${_safe(sessionId)}.json'), {
      'session_id': sessionId,
      'rows': rows,
    });
    await _trim(HmCacheKind.messages);
  }

  Future<List<Map<String, dynamic>>?> readMessages(
    String host,
    String sessionId,
  ) async {
    if (!_enabled(HmCacheKind.messages)) return null;
    final dir = await _dir(HmCacheKind.messages, host);
    final j = await _read(File('${dir.path}/${_safe(sessionId)}.json'));
    final rows = j?['rows'];
    if (rows is! List) return null;
    return [
      for (final r in rows.whereType<Map>()) Map<String, dynamic>.from(r),
    ];
  }

  // ---- Files & links -----------------------------------------------------

  /// Keeps the files, images and links found in one chat.
  Future<void> putFiles(
    String host,
    String sessionId,
    List<Map<String, dynamic>> items,
  ) async {
    if (!_enabled(HmCacheKind.files)) return;
    final dir = await _dir(HmCacheKind.files, host);
    await _write(File('${dir.path}/${_safe(sessionId)}.json'), {
      'session_id': sessionId,
      'items': items,
    });
    await _trim(HmCacheKind.files);
  }

  Future<List<Map<String, dynamic>>> readFiles(String host) async {
    if (!_enabled(HmCacheKind.files)) return const [];
    final dir = await _dir(HmCacheKind.files, host);
    if (!await dir.exists()) return const [];
    final out = <Map<String, dynamic>>[];
    await for (final f in dir.list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      final items = (await _read(f))?['items'];
      if (items is List) {
        out.addAll([
          for (final i in items.whereType<Map>()) Map<String, dynamic>.from(i),
        ]);
      }
    }
    return out;
  }

  // ---- Limit, usage, clearing -------------------------------------------

  /// Older items are dropped first once the limit is reached.
  Future<void> enforceLimit() async {
    await _trim(HmCacheKind.messages);
    await _trim(HmCacheKind.files);
    final dir = await _dir(HmCacheKind.chatList);
    for (final f in await _files(dir)) {
      final j = await _read(f);
      final rows = j?['sessions'];
      if (j == null || rows is! List || rows.length <= prefs.cacheLimit.chats) {
        continue;
      }
      j['sessions'] = rows.take(prefs.cacheLimit.chats).toList();
      await _write(f, j);
    }
  }

  Future<void> _trim(HmCacheKind kind) async {
    final files = await _files(await _dir(kind));
    final limit = prefs.cacheLimit.chats;
    if (files.length <= limit) return;
    final stamped = [for (final f in files) (f, await f.lastModified())]
      ..sort((a, b) => b.$2.compareTo(a.$2));
    for (final (f, _) in stamped.skip(limit)) {
      try {
        await f.delete();
      } on FileSystemException {
        // Already gone.
      }
    }
  }

  Future<List<File>> _files(Directory dir) async {
    if (!await dir.exists()) return const [];
    return [
      await for (final e in dir.list(recursive: true))
        if (e is File && e.path.endsWith('.json')) e,
    ];
  }

  /// Turning one off deletes what was already kept for it.
  Future<void> clear(HmCacheKind kind) async {
    final dir = await _dir(kind);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<HmCacheUsage> usage() async {
    var bytes = 0;
    var bots = 0;
    var chats = 0;
    var messageChats = 0;
    var files = 0;
    for (final kind in HmCacheKind.values) {
      for (final f in await _files(await _dir(kind))) {
        bytes += await f.length();
        final j = await _read(f);
        switch (kind) {
          case HmCacheKind.chatList:
            bots++;
            final s = j?['sessions'];
            if (s is List) chats += s.length;
          case HmCacheKind.messages:
            messageChats++;
          case HmCacheKind.files:
            final i = j?['items'];
            if (i is List) files += i.length;
        }
      }
    }
    return HmCacheUsage(
      bytes: bytes,
      bots: bots,
      chatList: chats,
      messageChats: messageChats,
      files: files,
    );
  }
}
