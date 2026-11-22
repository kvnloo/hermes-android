import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/bot_directory_document.dart';

enum AndroidEntryDestination {
  newChat,
  liveVoice,
  sessions,
  botImport,
  routines,
}

AndroidEntryDestination? androidEntryDestination(Object? action) =>
    switch (action) {
      'com.hermesagent.hermes_android.action.QUICK_CHAT' =>
        AndroidEntryDestination.newChat,
      'com.hermesagent.hermes_android.action.LIVE_VOICE' =>
        AndroidEntryDestination.liveVoice,
      'com.hermesagent.hermes_android.action.SESSIONS' =>
        AndroidEntryDestination.sessions,
      'com.hermesagent.hermes_android.action.ROUTINES' =>
        AndroidEntryDestination.routines,
      'botDirectory' => AndroidEntryDestination.botImport,
      _ => null,
    };

/// Bridges Android launcher actions into the Flutter navigation lifecycle.
class AndroidLaunchIntentService {
  static const channelName = 'com.hermesagent.hermes_android/launch';
  static const _quickChatAction = 'quickChat';

  final MethodChannel _channel;
  final ValueNotifier<bool> pendingQuickChat = ValueNotifier(false);
  final pendingDestination = ValueNotifier<AndroidEntryDestination?>(null);
  BotDirectoryDocument? pendingBotDocument;
  bool _initialized = false;

  AndroidLaunchIntentService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleMethodCall);
    try {
      _publish(await _channel.invokeMethod<Object?>('getInitialLaunchAction'));
    } on MissingPluginException {
      // Non-Android builds do not provide launcher shortcuts.
    } on PlatformException {
      // A launcher failure must never prevent the app from opening normally.
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method != 'launchAction') return;
    _publish(call.arguments);
  }

  void _publish(Object? raw) {
    final action = raw is Map ? raw['action'] : raw;
    final document = raw is Map ? raw['document'] : null;
    if (action == 'botDirectory') {
      pendingBotDocument = null;
      if (document is String) {
        try {
          pendingBotDocument = BotDirectoryDocument.parse(document);
        } on FormatException {
          // A malformed or unreadable document still opens the import screen.
        }
      }
    }
    if (action == _quickChatAction) {
      pendingQuickChat.value = true;
    } else if (androidEntryDestination(action) case final destination?) {
      pendingDestination.value = destination;
    }
  }

  bool takePendingQuickChat() {
    final pending = pendingQuickChat.value;
    if (pending) pendingQuickChat.value = false;
    return pending;
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    pendingQuickChat.dispose();
    pendingDestination.dispose();
  }
}
