import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/annotation/annotation_compose.dart';
import 'package:hermes_android/core/annotation/annotation_voice_send.dart';

class MemoryPendingStore implements AnnotationPendingTurnStore {
  AnnotationPendingTurn? pending;
  int writes = 0;
  int clears = 0;
  bool failWrite = false;

  @override
  Future<AnnotationPendingTurn?> read() async => pending;

  @override
  Future<void> write(AnnotationPendingTurn value) async {
    writes++;
    if (failWrite) throw StateError('durable write unavailable');
    if (pending != null) throw StateError('already occupied');
    pending = value;
  }

  @override
  Future<void> clearIfSame(AnnotationPendingTurn value) async {
    if (pending?.turnId != value.turnId) {
      throw StateError('different turn');
    }
    pending = null;
    clears++;
  }
}

class FakeAnnotationPort implements AnnotationSendPort {
  bool online = true;
  bool running = false;
  int reserves = 0;
  int submits = 0;
  String? lastMode;
  Completer<AnnotationReceipt> observation = Completer<AnnotationReceipt>();
  AnnotationReceipt submissionResult =
      const AnnotationReceipt(AnnotationReceiptKind.pending);

  @override
  bool get isOnline => online;
  @override
  bool get hasRunningTurn => running;

  @override
  Future<AnnotationSendReservation> reserve({
    required AnnotationSendEnvelope envelope,
    required String mode,
  }) async {
    lastMode = mode;
    reserves++;
    return AnnotationSendReservation(
      turnId: 'transport-turn-$reserves',
      submitOnce: () async {
        submits++;
        return submissionResult;
      },
    );
  }

  @override
  Future<AnnotationReceipt> receipt(
    AnnotationPendingTurn pending, {
    required Duration timeout,
  }) => observation.future;
}

const screen = ScreenInfo(
  id: 'chat',
  route: '/chat',
  width: 400,
  height: 800,
);
Stroke stroke(int time, {int id = 1, double x = 0.4}) => Stroke(
  id: id,
  tool: 'pen',
  color: 'accent',
  pointer: 'stylus',
  points: <StrokePoint>[
    StrokePoint(x: x, y: 0.5, p: 0.5, t: time),
    StrokePoint(x: x + 0.1, y: 0.6, p: 0.5, t: time + 50),
  ],
  startedAt: time,
  endedAt: time + 50,
);
Segment segment(int time, {String text = 'move this'}) => Segment(
  id: 'mic-$time',
  text: text,
  start: time - 25,
  end: time + 100,
  source: 'mic',
);

AnnotationSendEnvelope draft({
  String conversation = 'conversation-one',
  int time = 1000,
  double x = 0.4,
  String spoken = 'move this',
}) => AnnotationSendEnvelope(
  conversationId: conversation,
  strokes: <Stroke>[stroke(time, x: x)],
  segments: <Segment>[segment(time, text: spoken)],
  screen: screen,
  createdAt: 1700000000000,
);

void main() {
  test('one exact turn and duplicate attempts never dispatch twice', () async {
    final store = MemoryPendingStore();
    final port = FakeAnnotationPort();
    final sender = AnnotationVoiceSendController(store: store, port: port);
    final envelope = draft();

    final first = sender.send(envelope);
    await Future<void>.delayed(Duration.zero);
    expect(port.reserves, 1);
    expect(port.submits, 1);
    expect(store.pending?.turnId, 'transport-turn-1');
    await expectLater(sender.send(envelope), throwsStateError);

    port.observation.complete(
      const AnnotationReceipt(AnnotationReceiptKind.accepted),
    );
    final result = await first;
    expect(result.confirmed, isTrue);
    expect(result.didDispatch, isTrue);
    expect(result.turn.mode, 'queue');

    final same = await sender.send(envelope);
    expect(same.didDispatch, isFalse);
    expect(same.turn.turnId, result.turn.turnId);
    expect(port.reserves, 1);
    expect(port.submits, 1);
    expect(store.writes, 1);
    await sender.drawingCleared(result.turn);
    expect(store.pending, isNull);
    expect(store.clears, 1);
  });

  test('changed drawing or transcript during pending blocks a new turn', () async {
    final store = MemoryPendingStore();
    final port = FakeAnnotationPort()
      ..observation.complete(
        const AnnotationReceipt(AnnotationReceiptKind.pending),
      );
    final sender = AnnotationVoiceSendController(store: store, port: port);
    final first = draft();
    expect((await sender.send(first)).confirmed, isFalse);

    await expectLater(sender.send(draft(x: 0.3)), throwsStateError);
    await expectLater(
      sender.send(draft(spoken: 'move the other one')),
      throwsStateError,
    );
    expect(store.pending?.fingerprint, first.fingerprint);
    expect(port.reserves, 1);
    expect(port.submits, 1);
    expect(first.strokes.single.points.first.x, 0.4);
  });

  test('offline before admission preserves annotation without write or send', () async {
    final store = MemoryPendingStore();
    final port = FakeAnnotationPort()..online = false;
    final sender = AnnotationVoiceSendController(store: store, port: port);
    final envelope = draft();
    await expectLater(sender.send(envelope), throwsStateError);
    expect(port.reserves, 0);
    expect(port.submits, 0);
    expect(store.writes, 0);
    expect(store.pending, isNull);
    expect(envelope.strokes.single.id, 1);
    expect(envelope.segments.single.text, 'move this');
  });

  test('failed receipt is retained and retry inspects, never resends', () async {
    final store = MemoryPendingStore();
    final port = FakeAnnotationPort()
      ..observation.complete(
        const AnnotationReceipt(AnnotationReceiptKind.failed),
      );
    final sender = AnnotationVoiceSendController(store: store, port: port);
    final envelope = draft();

    final failed = await sender.send(envelope);
    expect(failed.receipt.kind, AnnotationReceiptKind.failed);
    expect(store.pending?.turnId, failed.turn.turnId);
    final observed = await sender.send(envelope);
    expect(observed.didDispatch, isFalse);
    expect(observed.receipt.kind, AnnotationReceiptKind.failed);
    expect(port.submits, 1);
    expect(store.clears, 0);
  });

  test('missing receipt times out without clearing drawing or ID', () async {
    final store = MemoryPendingStore();
    final port = FakeAnnotationPort();
    final sender = AnnotationVoiceSendController(
      store: store,
      port: port,
      receiptTimeout: const Duration(milliseconds: 5),
    );
    final envelope = draft();
    final timedOut = await sender.send(envelope);
    expect(timedOut.receipt.kind, AnnotationReceiptKind.pending);
    expect(store.pending?.turnId, timedOut.turn.turnId);
    expect(port.submits, 1);
  });

  test('running turn steers through one existing transport identity', () async {
    final store = MemoryPendingStore();
    final port = FakeAnnotationPort()
      ..running = true
      ..submissionResult =
          const AnnotationReceipt(AnnotationReceiptKind.accepted);
    final sender = AnnotationVoiceSendController(store: store, port: port);
    final result = await sender.send(draft());
    expect(result.confirmed, isTrue);
    expect(result.turn.mode, 'steer');
    expect(port.lastMode, 'steer');
    expect(port.submits, 1);
  });

  test('durable write failure never invokes transport submission', () async {
    final store = MemoryPendingStore()..failWrite = true;
    final port = FakeAnnotationPort();
    final sender = AnnotationVoiceSendController(store: store, port: port);
    await expectLater(sender.send(draft()), throwsStateError);
    expect(port.reserves, 1);
    expect(port.submits, 0);
  });

  test('pending conversation ownership prevents cross-chat resends', () async {
    final store = MemoryPendingStore();
    final port = FakeAnnotationPort()
      ..observation.complete(
        const AnnotationReceipt(AnnotationReceiptKind.pending),
      );
    final sender = AnnotationVoiceSendController(store: store, port: port);
    await sender.send(draft());
    await expectLater(
      sender.send(draft(conversation: 'other-conversation')),
      throwsStateError,
    );
    expect(port.submits, 1);
  });

  test('fingerprint is stable across createdAt and catches timestamp changes', () {
    final first = draft();
    final rewrapped = AnnotationSendEnvelope(
      conversationId: first.conversationId,
      strokes: first.strokes,
      segments: first.segments,
      screen: first.screen,
      createdAt: 1700000005000,
    );
    expect(first.fingerprint, rewrapped.fingerprint);
    expect(first.fingerprint.length, 64);
    expect(first.fingerprint, isNot(draft(time: 1001).fingerprint));
    expect(first.document['schema'], 'dash.annotation.v1');
    expect(first.text, contains('⟦stroke 1⟧'));
  });
}
