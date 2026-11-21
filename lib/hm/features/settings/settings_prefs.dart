// Device settings behind Settings → Security, Caching and Chat. One
// observable store, read synchronously after [HmSettingsPrefs.load] and
// written through to SharedPreferences. Every setter reports whether the
// write stuck, so a screen can say "Couldn't save…" and roll back.
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How long the app may sit in the background before it asks again.
enum HmLockGrace {
  immediately(Duration.zero, 'Immediately', 'Immediately'),
  oneMinute(Duration(minutes: 1), 'After 1 minute', '1 min'),
  fiveMinutes(Duration(minutes: 5), 'After 5 minutes', '5 min'),
  fifteenMinutes(Duration(minutes: 15), 'After 15 minutes', '15 min'),
  oneHour(Duration(hours: 1), 'After 1 hour', '1 hour');

  const HmLockGrace(this.duration, this.label, this.short);
  final Duration duration;
  final String label;
  final String short;
}

/// How many chats the device keeps before dropping the oldest.
enum HmCacheLimit {
  small(
    25,
    'Smallest footprint. Only the conversations you opened most recently can be read offline.',
  ),
  balanced(100, 'A good balance for daily use.'),
  large(500, 'Keeps almost everything. Uses the most space on this device.');

  const HmCacheLimit(this.chats, this.description);
  final int chats;
  final String description;
  String get label => '$chats chats';
}

/// How messages are drawn in every conversation.
enum HmChatStyle {
  standard('Standard'),
  bubbles('Bubbles');

  const HmChatStyle(this.label);
  final String label;
}

class HmSettingsPrefs extends ChangeNotifier {
  HmSettingsPrefs();

  /// The app's store. Tests may build their own.
  static final HmSettingsPrefs instance = HmSettingsPrefs();

  static const lockEnabledKey = 'hm_lock_enabled';
  static const lockGraceKey = 'hm_lock_grace';
  static const cacheChatListKey = 'hm_cache_chat_list';
  static const cacheMessagesKey = 'hm_cache_messages';
  static const cacheFilesKey = 'hm_cache_files';
  static const cacheLimitKey = 'hm_cache_limit';
  static const chatStyleKey = 'hm_chat_style';
  static const dismissKeyboardKey = 'hm_chat_dismiss_keyboard';
  static const showToolsKey = 'hm_chat_show_tools';
  static const showDeviceActionsKey = 'hm_chat_show_device_actions';
  static const showThinkingKey = 'hm_chat_show_thinking';
  static const foldFinishedKey = 'hm_chat_fold_finished';

  SharedPreferences? _prefs;
  bool get isLoaded => _prefs != null;

  // Security
  bool lockEnabled = false;
  HmLockGrace lockGrace = HmLockGrace.immediately;

  // Caching
  bool cacheChatList = true;
  bool cacheMessages = true;
  bool cacheFiles = true;
  HmCacheLimit cacheLimit = HmCacheLimit.balanced;

  /// Whether anything at all is kept on this device.
  bool get cachingOn => cacheChatList || cacheMessages || cacheFiles;

  // Chat
  HmChatStyle chatStyle = HmChatStyle.standard;
  bool dismissKeyboardAfterSend = false;
  bool showToolCalls = true;
  bool showDeviceActions = true;
  bool showThinking = false;
  bool foldFinishedTurns = true;

  /// Reads every setting. Synchronous: [prefs] is already loaded.
  void load(SharedPreferences prefs) {
    _read(prefs);
    notifyListeners();
  }

  void _read(SharedPreferences prefs) {
    _prefs = prefs;
    lockEnabled = prefs.getBool(lockEnabledKey) ?? false;
    lockGrace = _byName(
      HmLockGrace.values,
      prefs.getString(lockGraceKey),
      HmLockGrace.immediately,
    );
    cacheChatList = prefs.getBool(cacheChatListKey) ?? true;
    cacheMessages = prefs.getBool(cacheMessagesKey) ?? true;
    cacheFiles = prefs.getBool(cacheFilesKey) ?? true;
    cacheLimit = _byName(
      HmCacheLimit.values,
      prefs.getString(cacheLimitKey),
      HmCacheLimit.balanced,
    );
    chatStyle = _byName(
      HmChatStyle.values,
      prefs.getString(chatStyleKey),
      HmChatStyle.standard,
    );
    dismissKeyboardAfterSend = prefs.getBool(dismissKeyboardKey) ?? false;
    showToolCalls = prefs.getBool(showToolsKey) ?? true;
    showDeviceActions = prefs.getBool(showDeviceActionsKey) ?? true;
    showThinking = prefs.getBool(showThinkingKey) ?? false;
    foldFinishedTurns = prefs.getBool(foldFinishedKey) ?? true;
  }

  /// Loads from [prefs] unless something already did. Safe during build:
  /// it doesn't notify.
  void ensureLoaded(SharedPreferences prefs) {
    if (!isLoaded) _read(prefs);
  }

  static T _byName<T extends Enum>(List<T> values, String? name, T fallback) =>
      values.where((v) => v.name == name).firstOrNull ?? fallback;

  /// Applies [apply], persists with [write]; on a failed write restores
  /// [undo] and returns false.
  Future<bool> _save(
    void Function() apply,
    void Function() undo,
    Future<bool> Function(SharedPreferences p) write,
  ) async {
    apply();
    notifyListeners();
    final p = _prefs;
    var ok = false;
    if (p != null) {
      try {
        ok = await write(p);
      } catch (_) {
        ok = false;
      }
    }
    if (!ok) {
      undo();
      notifyListeners();
    }
    return ok;
  }

  Future<bool> _bool(
    bool current,
    bool next,
    String key,
    void Function(bool v) set,
  ) => _save(() => set(next), () => set(current), (p) => p.setBool(key, next));

  Future<bool> setLockEnabled(bool v) =>
      _bool(lockEnabled, v, lockEnabledKey, (x) => lockEnabled = x);

  Future<bool> setLockGrace(HmLockGrace v) {
    final old = lockGrace;
    return _save(
      () => lockGrace = v,
      () => lockGrace = old,
      (p) => p.setString(lockGraceKey, v.name),
    );
  }

  Future<bool> setCacheChatList(bool v) =>
      _bool(cacheChatList, v, cacheChatListKey, (x) => cacheChatList = x);

  Future<bool> setCacheMessages(bool v) =>
      _bool(cacheMessages, v, cacheMessagesKey, (x) => cacheMessages = x);

  Future<bool> setCacheFiles(bool v) =>
      _bool(cacheFiles, v, cacheFilesKey, (x) => cacheFiles = x);

  Future<bool> setCacheLimit(HmCacheLimit v) {
    final old = cacheLimit;
    return _save(
      () => cacheLimit = v,
      () => cacheLimit = old,
      (p) => p.setString(cacheLimitKey, v.name),
    );
  }

  Future<bool> setChatStyle(HmChatStyle v) {
    final old = chatStyle;
    return _save(
      () => chatStyle = v,
      () => chatStyle = old,
      (p) => p.setString(chatStyleKey, v.name),
    );
  }

  Future<bool> setDismissKeyboardAfterSend(bool v) => _bool(
    dismissKeyboardAfterSend,
    v,
    dismissKeyboardKey,
    (x) => dismissKeyboardAfterSend = x,
  );

  Future<bool> setShowToolCalls(bool v) =>
      _bool(showToolCalls, v, showToolsKey, (x) => showToolCalls = x);

  Future<bool> setShowDeviceActions(bool v) => _bool(
    showDeviceActions,
    v,
    showDeviceActionsKey,
    (x) => showDeviceActions = x,
  );

  Future<bool> setShowThinking(bool v) =>
      _bool(showThinking, v, showThinkingKey, (x) => showThinking = x);

  Future<bool> setFoldFinishedTurns(bool v) => _bool(
    foldFinishedTurns,
    v,
    foldFinishedKey,
    (x) => foldFinishedTurns = x,
  );
}
