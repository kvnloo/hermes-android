import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/annotation/annotation_reply_speech.dart';
import 'package:hermes_android/core/services/desktop_gateway_client.dart';
import 'package:hermes_android/core/services/normal_gateway_application_session.dart';

NormalGatewayChatSnapshot _snapshot({
  String? turnId,
  NormalGatewayTurnTerminal? terminal,
}) => NormalGatewayChatSnapshot(
  turnId: turnId,
  terminal: terminal,
  storedSessionId: 'chat-1',
  phase: terminal == null
      ? NormalGatewayTurnPhase.running
      : NormalGatewayTurnPhase.completed,
  wireEmitted: true,
  rowFloor: null,
  displayRows: const [],
  historyRows: const [],
  tools: const [],
  subagents: const [],
  pendingInput: const [],
  inputUpdates: const [],
  auxiliaryEvents: const [],
  status: null,
  error: null,
  rejectedDraft: null,
  connectionState: DesktopConnectionState.connected,
);

class _ReplySource {
  NormalGatewayChatSnapshot current = _snapshot();
  final Map<Object, void Function(NormalGatewayChatSnapshot)> listeners = {};
  int unsubscribes = 0;
  bool synchronousOnSubscribe = false;

  Object subscribe(void Function(NormalGatewayChatSnapshot) listen) {
    final token = Object();
    listeners[token] = listen;
    if (synchronousOnSubscribe) listen(current);
    return token;
  }

  void unsubscribe(Object token) {
    if (listeners.remove(token) != null) unsubscribes++;
  }

  void emit(NormalGatewayChatSnapshot next) {
    current = next;
    for (final listener in List.of(listeners.values)) {
      listener(next);
    }
  }
}

NormalGatewayTurnTerminal _terminal(
  String id, {
  bool? completed = true,
  String? text = 'Read this.',
}) => NormalGatewayTurnTerminal(
  turnId: id,
  completed: completed,
  publicFinalText: text,
);

void main() {
  test('late final text for the exact turn is read once and unsubscribed', () {
    final source = _ReplySource();
    final spoken = <String>[];
    final observer = AnnotationFinalReplyObserver.fromCallbacks(
      snapshot: () => source.current,
      subscribe: source.subscribe,
      unsubscribe: source.unsubscribe,
      speechEnabled: () => true,
      speakReply: (text) async { spoken.add(text); },
    );
    observer.watch('turn-1');
    source.emit(_snapshot(turnId: 'other', terminal: _terminal('other')));
    source.emit(_snapshot(turnId: 'turn-1', terminal: _terminal('other')));
    expect(spoken, isEmpty);

    source.emit(_snapshot(turnId: 'turn-1', terminal: _terminal('turn-1')));
    source.emit(_snapshot(turnId: 'turn-1', terminal: _terminal('turn-1')));
    observer.watch('turn-1');
    expect(spoken, ['Read this.']);
    expect(source.listeners, isEmpty);
    expect(source.unsubscribes, 1);
    observer.dispose();
  });

  test('already terminal response is delivered without race', () {
    final source = _ReplySource()
      ..current = _snapshot(turnId: 'turn-2', terminal: _terminal('turn-2'))
      ..synchronousOnSubscribe = true;
    final spoken = <String>[];
    final observer = AnnotationFinalReplyObserver.fromCallbacks(
      snapshot: () => source.current,
      subscribe: source.subscribe,
      unsubscribe: source.unsubscribe,
      speechEnabled: () => true,
      speakReply: (text) async { spoken.add(text); },
    );
    observer.watch('turn-2');
    expect(spoken, ['Read this.']);
    expect(source.unsubscribes, 1);
    expect(source.listeners, isEmpty);
    observer.dispose();
  });

  test('disabled speech, failed or empty terminal never speaks', () {
    final source = _ReplySource();
    final spoken = <String>[];
    var enabled = false;
    final observer = AnnotationFinalReplyObserver.fromCallbacks(
      snapshot: () => source.current,
      subscribe: source.subscribe,
      unsubscribe: source.unsubscribe,
      speechEnabled: () => enabled,
      speakReply: (text) async { spoken.add(text); },
    );
    observer.watch('disabled');
    source.emit(_snapshot(turnId: 'disabled', terminal: _terminal('disabled')));
    enabled = true;
    observer.watch('failed');
    source.emit(_snapshot(turnId: 'failed',
      terminal: _terminal('failed', completed: false)));
    observer.watch('empty');
    source.emit(_snapshot(turnId: 'empty',
      terminal: _terminal('empty', text: '  ')));
    expect(spoken, isEmpty);
    observer.dispose();
  });

  test('dispose revokes subscription, no later reply leaks to speech', () {
    final source = _ReplySource();
    final spoken = <String>[];
    final observer = AnnotationFinalReplyObserver.fromCallbacks(
      snapshot: () => source.current,
      subscribe: source.subscribe,
      unsubscribe: source.unsubscribe,
      speechEnabled: () => true,
      speakReply: (text) async { spoken.add(text); },
    );
    observer.watch('turn-3');
    observer.dispose();
    source.emit(_snapshot(turnId: 'turn-3', terminal: _terminal('turn-3')));
    observer.watch('turn-4');
    expect(spoken, isEmpty);
    expect(source.listeners, isEmpty);
  });
}
