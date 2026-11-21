// The Live Mode screen as a user sees it, with the call driven by fakes.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/avatar/hm_avatar.dart';
import 'package:hermes_android/hm/avatar/hm_avatar_state.dart';
import 'package:hermes_android/hm/features/live/hm_live.dart';
import 'package:hermes_android/hm/features/live/live_strings.dart';
import 'package:hermes_android/hm/features/live/live_transport.dart';
import 'package:hermes_android/hm/hm_bots.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'live_fakes.dart';

final _bot = HmBot.fromJson({
  'name': 'poteto',
  'display_name': 'poteto',
  'model': 'm',
  'provider': 'p',
});

/// Pumps a home page with a button that opens the call, then opens it.
Future<void> _open(WidgetTester tester, LiveRig rig) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: nextGenTheme(Brightness.dark, NextGenLook.instance),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => HmLiveScreen(bot: _bot, create: rig.build),
                ),
              ),
              child: const Text('chat'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('chat'));
  await _frames(tester);
}

/// The avatars animate forever, so step frames instead of settling.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _status(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('live-status'))).data!;

HmAvatarState _orbState(WidgetTester tester) => tester
    .widgetList<HmAvatar>(find.byType(HmAvatar))
    .firstWhere((a) => a.size == 180)
    .state;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NextGenLook.instance
      ..themeMode = ThemeMode.dark
      ..avatarStyle = HmAvatarStyle.syn;
  });

  testWidgets('empty call: bot pill, listening status, no transcript', (
    tester,
  ) async {
    final rig = LiveRig();
    await _open(tester, rig);
    expect(find.text('poteto'), findsOneWidget);
    expect(_status(tester), LiveText.listening);
    expect(_orbState(tester), HmAvatarState.listening);
    expect(find.text(LiveText.you), findsNothing);
    expect(find.bySemanticsLabel(LiveText.mute), findsOneWidget);
    expect(find.bySemanticsLabel(LiveText.end), findsOneWidget);
  });

  testWidgets('loaded call: transcript with speaker labels, Working…', (
    tester,
  ) async {
    final rig = LiveRig();
    await _open(tester, rig);

    rig.ear.hearPartial('is it going to rain');
    await _frames(tester);
    expect(find.text(LiveText.you), findsOneWidget);
    expect(find.text('is it going to rain'), findsOneWidget);

    rig.ear.hear('is it going to rain today');
    await _frames(tester);
    expect(_status(tester), LiveText.working);
    expect(_orbState(tester), HmAvatarState.thinking);
    final said = tester.widget<Text>(find.text('is it going to rain today'));
    expect(said.style?.fontStyle, FontStyle.italic);

    rig.brain.reply('No rain until Friday.');
    await _frames(tester);
    expect(_status(tester), LiveText.speaking);
    expect(_orbState(tester), HmAvatarState.speaking);
    expect(find.text('No rain until Friday.'), findsOneWidget);
    // The bot's line is labelled with its name (pill + label).
    expect(find.text('poteto'), findsNWidgets(2));
    expect(rig.voice.spoken, ['No rain until Friday.']);

    rig.voice.finish();
    await _frames(tester);
    expect(_status(tester), LiveText.listening);
  });

  testWidgets('tapping the orb while it speaks interrupts', (tester) async {
    final rig = LiveRig();
    await _open(tester, rig);
    rig.ear.hear('read me the news');
    rig.brain.reply('Here are the headlines…');
    await _frames(tester);
    expect(rig.voice.playing, isTrue);

    await tester.tap(
      find.byWidgetPredicate((w) => w is HmAvatar && w.size == 180),
    );
    await _frames(tester);
    expect(rig.voice.stops, 1);
    expect(_status(tester), LiveText.listening);
  });

  testWidgets('mic button mutes and unmutes', (tester) async {
    final rig = LiveRig();
    await _open(tester, rig);
    await tester.tap(find.bySemanticsLabel(LiveText.mute));
    await _frames(tester);
    expect(_status(tester), LiveText.muted);
    expect(find.byIcon(Icons.mic_off_rounded), findsOneWidget);
    expect(rig.ear.stops, 1);

    await tester.tap(find.bySemanticsLabel(LiveText.unmute));
    await _frames(tester);
    expect(_status(tester), LiveText.listening);
  });

  testWidgets('close ends the call and returns to the chat', (tester) async {
    final rig = LiveRig();
    await _open(tester, rig);
    rig.ear.hear('one more thing');
    await _frames(tester);

    await tester.tap(find.bySemanticsLabel(LiveText.end));
    await _frames(tester);
    expect(find.byType(HmLiveScreen), findsNothing);
    expect(find.text('chat'), findsOneWidget);
    expect(rig.ear.stops, greaterThanOrEqualTo(1));
    expect(rig.voice.stops, greaterThanOrEqualTo(1));
  });

  testWidgets('mic permission denied shows the official text', (tester) async {
    final rig = LiveRig(ear: FakeEar(access: LiveMicAccess.denied));
    await _open(tester, rig);
    expect(_status(tester), LiveText.micOff);
    expect(_orbState(tester), HmAvatarState.error);
    // Close still works; mute does not.
    await tester.tap(find.bySemanticsLabel(LiveText.mute));
    await _frames(tester);
    expect(_status(tester), LiveText.micOff);
    await tester.tap(find.bySemanticsLabel(LiveText.end));
    await _frames(tester);
    expect(find.byType(HmLiveScreen), findsNothing);
  });

  testWidgets('a host without voice routes shows the official text', (
    tester,
  ) async {
    final rig = LiveRig(host: FakeHost(statusError: const LiveNoVoiceApi()));
    await _open(tester, rig);
    expect(_status(tester), LiveText.noVoiceApi);
    expect(rig.ear.listens, 0);
  });

  testWidgets('system back ends the call', (tester) async {
    final rig = LiveRig();
    await _open(tester, rig);
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    await nav.maybePop();
    await _frames(tester);
    expect(find.byType(HmLiveScreen), findsNothing);
    expect(rig.ear.stops, greaterThanOrEqualTo(1));
  });
}
