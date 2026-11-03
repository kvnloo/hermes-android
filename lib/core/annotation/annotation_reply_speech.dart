import 'dart:async';

import '../services/normal_gateway_application_session.dart';

/// Observes only the exact submitted Hermes turn. Voice replies are spoken
/// through the existing ChatScreen read-aloud callback (and its flutter_tts
/// speaker), never through a second TTS instance or chat replay.
class AnnotationFinalReplyObserver {
  AnnotationFinalReplyObserver({
    required this.chat,
    required this.speechEnabled,
    required this.speakReply,
  });

  final NormalGatewayChatOwner chat;
  final bool Function() speechEnabled;
  final Future<void> Function(String text) speakReply;
  final Map<String, Object> _subscriptions = {};
  final Set<String> _completed = {};
  bool _disposed = false;

  void watch(String turnId) {
    if (_disposed || turnId.isEmpty ||
        _subscriptions.containsKey(turnId) ||
        _completed.contains(turnId)) {
      return;
    }
    // Install before inspecting snapshot, so even a synchronous completion is
    // either observed here or seen in the immediate read below.
    void inspect(NormalGatewayChatSnapshot snapshot) {
      if (_disposed || snapshot.turnId != turnId) return;
      final terminal = snapshot.terminal;
      if (terminal == null || terminal.turnId != turnId) return;
      _completed.add(turnId);
      final token = _subscriptions.remove(turnId);
      if (token != null) chat.unsubscribe(token);
      final speech = terminal.publicFinalText?.trim() ?? '';
      if (terminal.completed == true &&
          speech.isNotEmpty &&
          speechEnabled()) {
        unawaited(speakReply(speech).catchError((Object _) {}));
      }
    }

    final token = chat.subscribe(inspect);
    _subscriptions[turnId] = token;
    inspect(chat.snapshot);
  }

  void dispose() {
    _disposed = true;
    for (final token in _subscriptions.values) {
      chat.unsubscribe(token);
    }
    _subscriptions.clear();
  }
}
