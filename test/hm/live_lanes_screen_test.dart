// Live Mode with lanes (HA-035) as a user sees it: attached fast / large /
// council lanes orbit the bot's orb, a tap on one routes the next turn to
// it, the sheet attaches and detaches them. Driven by fakes and the fixture.
import 'dart:math' as math;
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/avatar/hm_avatar.dart';
import 'package:hermes_android/hm/avatar/hm_avatar_state.dart';
import 'package:hermes_android/hm/features/live/hm_live.dart';
import 'package:hermes_android/hm/features/live/live_lanes.dart';
import 'package:hermes_android/hm/features/live/live_strings.dart';
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

Future<void> _open(WidgetTester tester, LiveRig rig) async {
  // An S25-sized portrait screen.
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2.8125;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: nextGenTheme(Brightness.dark, NextGenLook.instance),
      home: HmLiveScreen(bot: _bot, create: rig.build),
    ),
  );
  await _frames(tester);
}

/// The avatars animate forever, so step frames instead of settling.
Future<void> _frames(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder _lane(String id) => find.byKey(ValueKey('live-lane-$id'));

final _center = find.descendant(
  of: find.byKey(const ValueKey('live-orb')),
  matching: find.byType(HmAvatar),
);

String? _text(WidgetTester tester, String key) {
  final f = find.byKey(ValueKey(key));
  return f.evaluate().isEmpty ? null : tester.widget<Text>(f).data;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NextGenLook.instance
      ..themeMode = ThemeMode.dark
      ..avatarStyle = HmAvatarStyle.syn;
  });

  testWidgets('without lanes the call looks as before', (tester) async {
    await _open(tester, LiveRig());
    expect(find.byKey(const ValueKey('live-orbit')), findsNothing);
    expect(find.byKey(const ValueKey('live-lanes-button')), findsNothing);
    expect(find.bySemanticsLabel(LiveText.lanes), findsNothing);
    expect(_center, findsOneWidget);
  });

  testWidgets('attached lanes orbit the bot\'s orb', (tester) async {
    final lanes = FixtureLiveLanes(attached: ['fast', 'large', 'council']);
    await _open(tester, LiveRig(lanes: lanes));

    expect(find.byKey(const ValueKey('live-orbit')), findsOneWidget);
    for (final id in ['fast', 'large', 'council']) {
      expect(_lane(id), findsOneWidget);
    }
    expect(find.text('Fast'), findsOneWidget);
    expect(find.text('Large'), findsOneWidget);
    expect(find.text('Council'), findsOneWidget);
    expect(
      _text(tester, 'live-lanes-summary'),
      startsWith('3 lanes · all idle'),
    );

    // Each lane orb sits on one circle around the bot's orb, apart.
    final center = tester.getCenter(_center);
    Offset orbOf(String id) => tester.getCenter(
      find.descendant(of: _lane(id), matching: find.byType(Icon)),
    );
    final at = {
      for (final id in ['fast', 'large', 'council']) id: orbOf(id),
    };
    final radii = at.values.map((p) => (p - center).distance).toList();
    for (final r in radii) {
      expect(r, closeTo(radii.first, 1.0));
      expect(r, greaterThan(tester.getSize(_center).width / 2));
    }
    double angle(Offset p) => math.atan2(p.dy - center.dy, p.dx - center.dx);
    final gaps = [
      (angle(at['large']!) - angle(at['fast']!)) % (2 * math.pi),
      (angle(at['council']!) - angle(at['large']!)) % (2 * math.pi),
    ];
    for (final g in gaps) {
      expect(g, closeTo(2 * math.pi / 3, 0.01));
    }

    // And they orbit: ten seconds on, every lane has moved round.
    await tester.pump(const Duration(seconds: 10));
    final moved = orbOf('fast');
    expect((moved - at['fast']!).distance, greaterThan(20));
    expect((moved - center).distance, closeTo(radii.first, 1.0));
  });

  testWidgets('lanes hold still when the system turns animations off', (
    tester,
  ) async {
    final lanes = FixtureLiveLanes(attached: ['fast']);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _open(tester, LiveRig(lanes: lanes));
    final before = tester.getCenter(_lane('fast'));
    await tester.pump(const Duration(seconds: 10));
    expect(tester.getCenter(_lane('fast')), before);
  });

  testWidgets('tapping a lane orb routes the next turn to it', (tester) async {
    final lanes = FixtureLiveLanes(attached: ['fast', 'large', 'council']);
    final rig = LiveRig(lanes: lanes);
    await _open(tester, rig);
    expect(_text(tester, 'live-route'), isNull);

    await tester.tap(_lane('fast'));
    await _frames(tester);
    expect(_text(tester, 'live-route'), LiveText.toLane('Fast'));
    expect(
      tester.getSemantics(_lane('fast')).flagsCollection.isSelected,
      Tristate.isTrue,
    );

    rig.ear.hear('should I ship it');
    await _frames(tester, 2);
    expect(lanes.asked, [('fast', 'should I ship it')]);
    expect(rig.brain.asked, isEmpty);
    expect(
      find.descendant(
        of: _lane('fast'),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(_text(tester, 'live-lanes-summary'), contains('1 working'));
    expect(find.text(LiveText.youToLane('Fast')), findsOneWidget);

    await _frames(tester, 6);
    expect(
      find.text('Quick take on “should I ship it”: yes, go ahead.'),
      findsOneWidget,
    );
    expect(find.text(LiveText.laneSpeaker('Fast')), findsOneWidget);
    expect(rig.voice.spoken.single, startsWith('Quick take'));
    rig.voice.finish();
    await _frames(tester);

    // Another lane takes the next turn.
    await tester.tap(_lane('council'));
    await _frames(tester);
    expect(_text(tester, 'live-route'), LiveText.toLane('Council'));
    rig.ear.hear('vote on it');
    await _frames(tester, 32);
    expect(lanes.asked.last, ('council', 'vote on it'));
    expect(find.text(LiveText.laneSpeaker('Council')), findsOneWidget);
    rig.voice.finish();
    await _frames(tester);

    // The bot's orb brings the turns back to the bot.
    await tester.tap(find.byKey(const ValueKey('live-orb')));
    await _frames(tester);
    expect(_text(tester, 'live-route'), isNull);
    rig.ear.hear('thanks');
    await _frames(tester);
    expect(rig.brain.asked, ['thanks']);
    expect(lanes.asked, hasLength(2));
  });

  testWidgets('the lanes sheet attaches and detaches lanes', (tester) async {
    final lanes = FixtureLiveLanes();
    final rig = LiveRig(lanes: lanes);
    await _open(tester, rig);
    expect(_lane('fast'), findsNothing);
    expect(_text(tester, 'live-lanes-summary'), isNull);

    await tester.tap(find.byKey(const ValueKey('live-lanes-button')));
    await _frames(tester);
    expect(find.text(LiveText.lanesTitle), findsOneWidget);
    expect(find.textContaining(LiveText.lanesFixture), findsOneWidget);
    for (final id in ['fast', 'large', 'council']) {
      await tester.tap(find.byKey(ValueKey('live-lane-toggle-$id')));
      await _frames(tester, 2);
    }
    expect(lanes.lanes.map((l) => l.id), ['fast', 'large', 'council']);

    await tester.tap(find.byKey(const ValueKey('live-lane-toggle-large')));
    await _frames(tester, 2);
    expect(lanes.lanes.map((l) => l.id), ['fast', 'council']);

    // Close the sheet: the orbit shows what is attached.
    await tester.tapAt(const Offset(20, 40));
    await _frames(tester);
    expect(find.text(LiveText.lanesTitle), findsNothing);
    expect(_lane('fast'), findsOneWidget);
    expect(_lane('large'), findsNothing);
    expect(_lane('council'), findsOneWidget);
    expect(
      _text(tester, 'live-lanes-summary'),
      startsWith('2 lanes · all idle'),
    );
  });

  testWidgets('detaching the lane being talked to routes back to the bot', (
    tester,
  ) async {
    final lanes = FixtureLiveLanes(attached: ['fast', 'large']);
    await _open(tester, LiveRig(lanes: lanes));
    await tester.tap(_lane('large'));
    await _frames(tester);
    expect(_text(tester, 'live-route'), LiveText.toLane('Large'));
    await lanes.detach('large');
    await _frames(tester);
    expect(_lane('large'), findsNothing);
    expect(_text(tester, 'live-route'), isNull);
  });

  testWidgets('a lane error shows on its orb', (tester) async {
    final lanes = FixtureLiveLanes(attached: ['fast']);
    await _open(tester, LiveRig(lanes: lanes));
    lanes.replay(
      '{"type":"lane_error","ts":${DateTime.now().millisecondsSinceEpoch / 1000},'
      '"data":{"lane":"fast","message":"Rate limited"}}',
    );
    await _frames(tester);
    expect(
      find.bySemanticsLabel(
        '${LiveText.laneSpeaker('Fast')}, '
        'Failed · Rate limited',
      ),
      findsOneWidget,
    );
    expect(_text(tester, 'live-lanes-summary'), contains('1 failed'));
  });
}
