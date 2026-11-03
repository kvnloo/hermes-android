import 'dart:async';

import '../services/normal_gateway_application_session.dart';

/// Observes only the exact submitted Hermes turn. Speech uses the owning
/// ChatScreen's existing read-aloud callback and flutter_tts instance.
class AnnotationFinalReplyObserver {
  factory AnnotationFinalReplyObserver({
    required NormalGatewayChatOwner chat,
    required bool Function() speechEnabled,
    required Future<void> Function(String text) speakReply,
  }) => AnnotationFinalReplyObserver.fromCallbacks(
    snapshot: () => chat.snapshot,
    subscribe: chat.subscribe,
    unsubscribe: chat.unsubscribe,
    speechEnabled: speechEnabled,
    speakReply: speakReply,
  );

  /// Narrow observation seam for testing the real terminal contract without a
  /// WebSocket, a second Gateway owner, or a second speech service.
  AnnotationFinalReplyObserver.fromCallbacks({
    required NormalGatewayChatSnapshot Function() snapshot,
    required Object Function(void Function(NormalGatewayChatSnapshot)) subscribe,
    required void Function(Object) unsubscribe,
    required this.speechEnabled,
    required this.speakReply,
  }) : _snapshot = snapshot,
       _subscribe = subscribe,
       _unsubscribe = unsubscribe;

  final NormalGatewayChatSnapshot Function() _snapshot;
  final Object Function(void Function(NormalGatewayChatSnapshot)) _subscribe;
  final void Function(Object) _unsubscribe;
  final bool Function() speechEnabled;
  final Future<void> Function(String text) speakReply;
  final Map<String, Object> _subscriptions = {};
  final Set<String> _completed = {};
  bool _disposed = false;

  void watch(String turnId) {
    if (_disposed ||
        turnId.isEmpty ||
        _subscriptions.containsKey(turnId) ||
        _completed.contains(turnId)) {
      return;
    }

    // Subscribe before inspecting so terminal events between registration and
    // the first snapshot read cannot be lost.
    void inspect(NormalGatewayChatSnapshot snapshot) {
      if (_disposed || snapshot.turnId != turnId) return;
      final terminal = snapshot.terminal;
      if (terminal == null || terminal.turnId != turnId) return;
      _completed.add(turnId);
      final token = _subscriptions.remove(turnId);
      if (token != null) _unsubscribe(token);
      final speech = terminal.publicFinalText?.trim() ?? '';
      if (terminal.completed == true &&
          speech.isNotEmpty &&
          speechEnabled()) {
        unawaited(speakReply(speech).catchError((Object _) {}));
      }
    }

    final token = _subscribe(inspect);
    // subscribe may call back synchronously before returning its token.
    if (_completed.contains(turnId)) {
      _unsubscribe(token);
    } else {
      _subscriptions[turnId] = token;
      inspect(_snapshot());
    }
  }

  void dispose() {
    _disposed = true;
    for (final token in _subscriptions.values) {
      _unsubscribe(token);
    }
    _subscriptions.clear();
  }
}
