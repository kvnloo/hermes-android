import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/annotation/annotation_compose.dart';
import 'package:hermes_android/core/annotation/annotation_voice_send.dart';

const _screen = ScreenInfo(
  id: 'chat',
  route: '/chat',
  width: 400,
  height: 800,
);

class _LostAckPort implements AnnotationSendPort {
  int reservations = 0;
  int dispatches = 0;
  int inspections = 0;

  @override
  bool get isOnline => true;

  @override
  bool get hasRunningTurn => false;

  @override
  Future<AnnotationSendReservation> reserve({
    required AnnotationSendEnvelope envelope,
    required String mode,
  }) async {
    reservations++;
    return AnnotationSendReservation(
      turnId: 'turn-$reservations',
      submitOnce: () async {
        dispatches++;
        return const AnnotationReceipt(AnnotationReceiptKind.pending);
      },
    );
  }

  @override
  Future<AnnotationReceipt> receipt(
    AnnotationPendingTurn pending, {
    required Duration timeout,
  }) async {
    inspections++;
    return const AnnotationReceipt(AnnotationReceiptKind.pending);
  }
}

AnnotationSendEnvelope _envelope({String typed = 'Explain this screenshot'}) =>
    AnnotationSendEnvelope(
      conversationId: 'chat-1',
      strokes: const [],
      segments: const [],
      screen: _screen,
      createdAt: 1000,
      typed: typed,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('SharedPreferences pending turn round-trips and clears exact receipt', () async {
    final store = PreferencesAnnotationPendingTurnStore('annotation-test');
    final pending = AnnotationPendingTurn(
      turnId: 'turn-1',
      conversationId: 'chat-1',
      fingerprint: _envelope().fingerprint,
      mode: 'queue',
    );
    expect(await store.read(), isNull);
    await store.write(pending);

    final reopened = PreferencesAnnotationPendingTurnStore('annotation-test');
    final restored = await reopened.read();
    expect(restored?.turnId, pending.turnId);
    expect(restored?.conversationId, pending.conversationId);
    expect(restored?.fingerprint, pending.fingerprint);
    expect(restored?.mode, pending.mode);
    expect(() => reopened.write(pending), throwsStateError);

    await reopened.clearIfSame(pending);
    expect(await store.read(), isNull);
  });

  test('lost acknowledgment across controller restart never resends', () async {
    final store = PreferencesAnnotationPendingTurnStore('annotation-test');
    final port = _LostAckPort();
    final original = AnnotationVoiceSendController(store: store, port: port);
    final first = await original.send(_envelope());
    expect(first.didDispatch, isTrue);
    expect(first.confirmed, isFalse);
    expect(port.dispatches, 1);
    expect(port.reservations, 1);

    // Re-create both controller and preferences adapter as after a restart.
    final recovered = AnnotationVoiceSendController(
      store: PreferencesAnnotationPendingTurnStore('annotation-test'),
      port: port,
    );
    final second = await recovered.send(_envelope());
    expect(second.didDispatch, isFalse);
    expect(second.turn.turnId, first.turn.turnId);
    expect(port.dispatches, 1);
    expect(port.reservations, 1);
    expect(port.inspections, 2);
    expect((await store.read())?.turnId, first.turn.turnId);
  });

  test('changed draft cannot bypass an uncertain saved turn', () async {
    final store = PreferencesAnnotationPendingTurnStore('annotation-test');
    final port = _LostAckPort();
    await AnnotationVoiceSendController(store: store, port: port).send(_envelope());
    final sender = AnnotationVoiceSendController(store: store, port: port);
    await expectLater(sender.send(_envelope(typed: 'changed')), throwsStateError);
    expect(port.dispatches, 1);
  });

  test('corrupt saved receipt fails closed and never reserves a turn', () async {
    SharedPreferences.setMockInitialValues({'annotation-test': '{bad-json'});
    final store = PreferencesAnnotationPendingTurnStore('annotation-test');
    await expectLater(store.read(), throwsStateError);
    final port = _LostAckPort();
    await expectLater(
      AnnotationVoiceSendController(store: store, port: port).send(_envelope()),
      throwsStateError,
    );
    expect(port.reservations, 0);
  });

  test('a different receipt cannot clear the saved turn', () async {
    final store = PreferencesAnnotationPendingTurnStore('annotation-test');
    final real = AnnotationPendingTurn(
      turnId: 'turn-1',
      conversationId: 'chat-1',
      fingerprint: _envelope().fingerprint,
      mode: 'queue',
    );
    await store.write(real);
    await expectLater(
      store.clearIfSame(AnnotationPendingTurn(
        turnId: 'other',
        conversationId: real.conversationId,
        fingerprint: real.fingerprint,
        mode: real.mode,
      )),
      throwsStateError,
    );
    expect((await store.read())?.turnId, real.turnId);
  });
}
