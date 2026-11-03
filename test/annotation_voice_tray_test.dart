import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/annotation/annotation_compose.dart';
import 'package:hermes_android/core/annotation/annotation_voice_send.dart';
import 'package:hermes_android/core/widgets/annotation_voice_tray.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/fake_voice_composer_adapter.dart';

class _MemoryStore implements AnnotationPendingTurnStore {
  AnnotationPendingTurn? pending;
  @override
  Future<AnnotationPendingTurn?> read() async => pending;
  @override
  Future<void> write(AnnotationPendingTurn turn) async => pending = turn;
  @override
  Future<void> clearIfSame(AnnotationPendingTurn turn) async {
    if (pending?.turnId == turn.turnId) pending = null;
  }
}

class _ImmediatePort implements AnnotationSendPort {
  int sent = 0;
  @override
  bool get isOnline => true;
  @override
  bool get hasRunningTurn => false;
  @override
  Future<AnnotationSendReservation> reserve({
    required AnnotationSendEnvelope envelope,
    required String mode,
  }) async => AnnotationSendReservation(
    turnId: 'real-turn',
    submitOnce: () async {
      sent++;
      return const AnnotationReceipt(
        AnnotationReceiptKind.finalReply,
        reply: 'It is done.',
      );
    },
  );
  @override
  Future<AnnotationReceipt> receipt(
    AnnotationPendingTurn pending, {
    required Duration timeout,
  }) => Future.value(
    const AnnotationReceipt(
      AnnotationReceiptKind.finalReply,
      reply: 'It is done.',
    ),
  );
}

const _screen = ScreenInfo(
  id: 'chat',
  route: '/chat',
  width: 400,
  height: 800,
);

void main() {
  testWidgets('typed annotation sends once and speaks only with hands-free on', (
    tester,
  ) async {
    final port = _ImmediatePort();
    final store = _MemoryStore();
    final fakeVoice = FakeVoiceComposerAdapter();
    var confirmed = 0;
    var spoken = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AnnotationVoiceTray(
            conversationId: 'test-chat',
            screen: _screen,
            currentStrokes: () => <Stroke>[],
            sender: AnnotationVoiceSendController(store: store, port: port),
            beforeRecording: () async {},
            onConfirmed: (submitted, receipt) async {
              confirmed++;
            },
            handsFreeSpeechEnabled: () => true,
            speakReply: (reply) async {
              expect(reply, 'It is done.');
              spoken++;
            },
            voiceAdapter: fakeVoice,
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('annotation-typed-note')),
      'Please explain this screen',
    );
    await tester.tap(find.byKey(const Key('annotation-voice-send')));
    await tester.pump();
    await tester.pump();

    expect(port.sent, 1);
    expect(confirmed, 1);
    expect(spoken, 1);
    expect(store.pending, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hold-to-talk records a segment and aligns with a stroke', (
    tester,
  ) async {
    final fakeVoice = FakeVoiceComposerAdapter(
      finalTranscriptOnStop: 'draw over this',
    );
    var now = 1000;
    final strokes = <Stroke>[
      const Stroke(
        id: 4,
        tool: 'pen',
        color: 'accent',
        pointer: 'stylus',
        points: [StrokePoint(x: .4, y: .5, p: .5, t: 1500)],
        startedAt: 1500,
        endedAt: 1500,
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AnnotationVoiceTray(
            conversationId: 'test-chat',
            screen: _screen,
            currentStrokes: () => strokes,
            sender: AnnotationVoiceSendController(
              store: _MemoryStore(),
              port: _ImmediatePort(),
            ),
            beforeRecording: () async {},
            onConfirmed: (_, __) async {},
            handsFreeSpeechEnabled: () => false,
            speakReply: (_) async {},
            voiceAdapter: fakeVoice,
            clock: () => now,
          ),
        ),
      ),
    );

    final target = find.byKey(const Key('annotation-hold-to-talk'));
    final gesture = await tester.startGesture(tester.getCenter(target));
    await tester.pump(const Duration(milliseconds: 650));
    now = 2000;
    await gesture.up();
    await tester.pump();
    await tester.pump();

    expect(fakeVoice.listenCount, 1);
    expect(fakeVoice.stopCount, 1);
    expect(
      find.textContaining('⟦stroke 4⟧'),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });
}
