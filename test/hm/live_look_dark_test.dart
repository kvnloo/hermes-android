// The Live call is an immersive dark surface in every app theme (official
// shots/official-s25/live-01.png), drawn from the active theme's dark scheme.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/avatar/hm_avatar.dart';
import 'package:hermes_android/hm/avatar/hm_avatar_state.dart';
import 'package:hermes_android/hm/features/live/hm_live.dart';
import 'package:hermes_android/hm/features/live/live_strings.dart';
import 'package:hermes_android/hm/hm_bots.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/nextgen/theme/ng_theme_spec.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'live_fakes.dart';

final _bot = HmBot.fromJson({
  'name': 'poteto',
  'display_name': 'poteto',
  'model': 'm',
  'provider': 'p',
});

Future<void> _openLight(WidgetTester tester, LiveRig rig) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (_, child) =>
          HmLiveScope(background: FakeLiveBackground(), child: child!),
      theme: nextGenTheme(Brightness.light, NextGenLook.instance),
      themeMode: ThemeMode.light,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => presentHmLive(
                context,
                host: HmLiveScope.of(context),
                bot: _bot,
                create: rig.build,
              ),
              child: const Text('chat'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('chat'));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

NgColors _dark() => NgColors.build(
  Brightness.dark,
  NextGenLook.instance.accent,
  NextGenLook.instance.pureBlack,
  NextGenLook.instance.glow,
  NextGenLook.instance.theme,
);

NgColors _light() => NgColors.build(
  Brightness.light,
  NextGenLook.instance.accent,
  NextGenLook.instance.pureBlack,
  NextGenLook.instance.glow,
  NextGenLook.instance.theme,
);

Color? _scaffoldColor(WidgetTester tester) => tester
    .widget<Scaffold>(
      find.descendant(
        of: find.byType(HmLiveScreen),
        matching: find.byType(Scaffold),
      ),
    )
    .backgroundColor;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NextGenLook.instance
      ..themeMode = ThemeMode.light
      ..themeId = ngThemePresets.first.id
      ..avatarStyle = HmAvatarStyle.syn;
  });

  for (final preset in ngThemePresets.take(3)) {
    testWidgets(
      'light app theme "${preset.id}": call paints its dark surface',
      (tester) async {
        NextGenLook.instance.themeId = preset.id;
        await _openLight(tester, LiveRig());

        final dark = _dark();
        expect(_scaffoldColor(tester), dark.background);
        expect(_scaffoldColor(tester), isNot(_light().background));

        final status = tester.widget<Text>(
          find.byKey(const ValueKey('live-status')),
        );
        expect(status.data, LiveText.listening);
        expect(status.style?.color, dark.text);

        // Light status-bar icons on the dark call.
        final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
          find
              .descendant(
                of: find.byType(HmLiveScreen),
                matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
              )
              .first,
        );
        expect(region.value.statusBarIconBrightness, Brightness.light);
      },
    );
  }

  testWidgets('pill, transcript and buttons use the dark scheme', (
    tester,
  ) async {
    final rig = LiveRig();
    await _openLight(tester, rig);
    final dark = _dark();

    // Translucent dark pill, bot name in light text.
    final pill = tester.widget<Container>(
      find.byKey(const ValueKey('live-pill')),
    );
    final fill = (pill.decoration! as BoxDecoration).color!;
    expect(fill.a, lessThan(1));
    expect(fill.withValues(alpha: 1), dark.surface3);
    expect(tester.widget<Text>(find.text('poteto')).style?.color, dark.text);

    // The orb is small relative to the screen.
    final width = tester.getSize(find.byType(HmLiveScreen)).width;
    final orb = tester.getSize(
      find.descendant(
        of: find.byKey(const ValueKey('live-orb')),
        matching: find.byType(HmAvatar),
      ),
    );
    expect(orb.width, lessThanOrEqualTo(width * 0.25));

    rig.ear.hear('is it going to rain today');
    rig.brain.reply('No rain until Friday.');
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final you = tester.widget<Text>(find.text('is it going to rain today'));
    expect(you.style?.fontStyle, FontStyle.italic);
    expect(you.style?.color, dark.text3);
    final bot = tester.widget<Text>(find.text('No rain until Friday.'));
    expect(bot.style?.color, dark.text);
    expect(
      tester.widget<Text>(find.text(LiveText.you)).style?.color,
      dark.textMuted,
    );

    // Dark-filled round buttons with light icons, close together.
    final mic = tester.widget<Icon>(find.byIcon(Icons.mic_rounded));
    expect(mic.color, dark.text);
    final micBox = tester.getRect(find.bySemanticsLabel(LiveText.mute));
    final endBox = tester.getRect(find.bySemanticsLabel(LiveText.end));
    expect(endBox.left - micBox.right, lessThanOrEqualTo(24));
    expect(micBox.center.dx, closeTo(width / 2, 1));

    // Closing still works.
    await tester.tap(find.bySemanticsLabel(LiveText.end));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(HmLiveScreen), findsNothing);
  });
}
