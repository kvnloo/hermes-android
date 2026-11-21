import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/glass_window_service.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/nextgen/theme/ng_theme_spec.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final look = NextGenLook.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    addTearDown(() async {
      SharedPreferences.setMockInitialValues({});
      NextGenPreferences.load(await SharedPreferences.getInstance());
    });
  });

  for (final brightness in Brightness.values) {
    for (final preset in ngThemePresets) {
      test('${preset.id}/${brightness.name} Glass keeps AA contrast', () {
        look
          ..themeId = preset.id
          ..surface = NgSurface.glass;
        final theme = nextGenTheme(
          brightness,
          look,
          transparentWindow: true,
          blurredWindow: true,
        );
        final c = theme.extension<NgColors>()!;
        expect(theme.scaffoldBackgroundColor.a, 0);
        expect(c.glassScene!.a, lessThan(1));
        expect(c.surface.a, lessThan(1));
        expect(theme.dialogTheme.backgroundColor!.a, greaterThanOrEqualTo(.97));
        for (final wallpaper in [Colors.black, Colors.white, Colors.grey]) {
          final scene = Color.alphaBlend(c.glassScene!, wallpaper);
          final panel = Color.alphaBlend(c.surface, scene);
          for (final color in [c.text, c.text2, c.text3, c.textMuted]) {
            expect(contrastRatio(color, scene), greaterThanOrEqualTo(4.5));
            expect(contrastRatio(color, panel), greaterThanOrEqualTo(4.5));
          }
        }
      });
    }
  }

  test('Glass is gated on the active window and boosts tint without blur', () {
    final defaultTheme = nextGenTheme(Brightness.dark, look);
    look.surface = NgSurface.glass;
    final opaque = nextGenTheme(Brightness.dark, look);
    expect(
      opaque.scaffoldBackgroundColor,
      defaultTheme.scaffoldBackgroundColor,
    );
    expect(
      opaque.extension<NgColors>()!.surface,
      defaultTheme.extension<NgColors>()!.surface,
    );
    expect(opaque.extension<NgColors>()!.glassScene, isNull);

    final blurred = nextGenTheme(
      Brightness.dark,
      look,
      transparentWindow: true,
      blurredWindow: true,
    );
    final sharp = nextGenTheme(Brightness.dark, look, transparentWindow: true);
    expect(
      sharp.extension<NgColors>()!.glassScene!.a,
      greaterThan(blurred.extension<NgColors>()!.glassScene!.a),
    );
  });

  test('custom colours resolve safely and theme JSON stays portable', () async {
    final prefs = await SharedPreferences.getInstance();
    final spec = await NextGenPreferences.importTheme(prefs, '''
      {"name":"Mixed","dark":{"background":"#8C8C8C","text":"#EEEEEE",
      "textMuted":"#77777730"}}
    ''');
    look.surface = NgSurface.glass;
    final c = nextGenTheme(
      Brightness.dark,
      look,
      transparentWindow: true,
    ).extension<NgColors>()!;
    for (final wallpaper in [Colors.black, Colors.white]) {
      final scene = Color.alphaBlend(c.glassScene!, wallpaper);
      expect(contrastRatio(c.text, scene), greaterThanOrEqualTo(4.5));
      expect(contrastRatio(c.textMuted, scene), greaterThanOrEqualTo(4.5));
    }
    expect(NgThemeSpec.parse(spec.encode()).dark, spec.dark);
    expect(spec.toJson(), isNot(contains('surface')));
    expect(
      () => NgThemeSpec.parse('{"name":"Bad","dark":{"unknown":"#000000"}}'),
      throwsFormatException,
    );
  });

  test(
    'persist before relaunch and roll back if the bridge rejects it',
    () async {
      final prefs = await SharedPreferences.getInstance();
      NextGenPreferences.load(prefs);
      expect(look.surface, NgSurface.solid);
      const channel = MethodChannel('test/glass');
      final service = GlassWindowService(channel: channel);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var acceptsRelaunch = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'state') {
          return {'transparent': true, 'showsWallpaper': false};
        }
        expect(call.method, 'recreate');
        expect(prefs.get(NextGenPreferences.surfaceKey), 'glass');
        return acceptsRelaunch;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        channel.setMethodCallHandler(null);
        service.dispose();
      });
      await service.init();
      expect(service.transparent, isFalse);
      expect(
        await NextGenPreferences.setSurface(
          prefs,
          NgSurface.glass,
          window: service,
        ),
        isFalse,
      );
      expect(prefs.get(NextGenPreferences.surfaceKey), 'solid');
      acceptsRelaunch = true;
      expect(
        await NextGenPreferences.setSurface(
          prefs,
          NgSurface.glass,
          window: service,
        ),
        isTrue,
      );
      look.surface = NgSurface.solid;
      NextGenPreferences.load(prefs);
      expect(look.surface, NgSurface.glass);
      await prefs.setInt(NextGenPreferences.surfaceKey, 7);
      NextGenPreferences.load(prefs);
      expect(look.surface, NgSurface.solid);
    },
  );
}
