import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/theme_preference.dart';
import 'package:hermes_android/core/theme/hermes_surface.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _glassWindow = HermesWindowCapabilities(
  transparent: true,
  crossWindowBlur: true,
);

void main() {
  group('glass tint keeps text readable', () {
    for (final brightness in Brightness.values) {
      for (final palette in HermesPalette.values) {
        test('${brightness.name}/${palette.name}', () {
          final tokens = HermesTokens.forBrightness(
            brightness,
            palette: palette,
          );
          for (final preset in HermesGlassPreset.values) {
            final surface = HermesSurface.resolve(
              HermesSurfaceStyle(mode: HermesSurfaceMode.glass, preset: preset),
              tokens,
              window: _glassWindow,
            );
            final scene = surface.scene;
            // Secondary text on a mid-tone region of any blurred wallpaper.
            final mid = Color.alphaBlend(scene, const Color(0xFF808080));
            expect(
              contrastRatio(tokens.muted, mid),
              greaterThanOrEqualTo(4.5),
              reason: '${preset.name} muted text over mid grey',
            );
            if (preset != HermesGlassPreset.clear) {
              // Body text survives the worst highlight in the wallpaper.
              final worst = Color.alphaBlend(
                scene,
                brightness == Brightness.dark ? Colors.white : Colors.black,
              );
              expect(
                contrastRatio(tokens.onSurface, worst),
                greaterThanOrEqualTo(4.5),
                reason: '${preset.name} body text over worst wallpaper',
              );
            }
          }
        });
      }
    }

    test('a custom tint below the floor is clamped up to it', () {
      final tokens = HermesTokens.dark();
      final surface = HermesSurface.resolve(
        const HermesSurfaceStyle(mode: HermesSurfaceMode.glass, tint: 0),
        tokens,
        window: _glassWindow,
      );
      expect(surface.tint, HermesSurface.tintFloor(tokens));
    });

    test('battery saver (no compositor blur) raises the tint', () {
      final tokens = HermesTokens.dark();
      const style = HermesSurfaceStyle(mode: HermesSurfaceMode.glass);
      final blurred = HermesSurface.resolve(
        style,
        tokens,
        window: _glassWindow,
      );
      final sharp = HermesSurface.resolve(
        style,
        tokens,
        window: const HermesWindowCapabilities(
          transparent: true,
          crossWindowBlur: false,
        ),
      );
      expect(sharp.tint, greaterThan(blurred.tint));
      expect(sharp.blurDp, 0);
      expect(blurred.blurDp, HermesGlassPreset.clear.blur);
    });
  });

  test('glass never renders over an opaque window', () {
    final tokens = HermesTokens.dark();
    final surface = HermesSurface.resolve(
      const HermesSurfaceStyle(
        mode: HermesSurfaceMode.glass,
        quietChrome: true,
      ),
      tokens,
    );
    expect(surface.glass, isFalse);
    expect(surface.scene, tokens.surface);
    // Quiet chrome is a Solid personalization too.
    expect(surface.quietChrome, isTrue);
  });

  group('hermesTheme', () {
    test('Solid is unchanged by default', () {
      final theme = hermesTheme(Brightness.dark);
      expect(theme.extension<HermesSurface>()!.glass, isFalse);
      expect(theme.scaffoldBackgroundColor, HermesTokens.dark().surface);
      expect(
        theme.navigationBarTheme.labelBehavior,
        NavigationDestinationLabelBehavior.alwaysShow,
      );
    });

    test('Glass makes routes transparent and modals near-opaque', () {
      final theme = hermesTheme(
        Brightness.dark,
        surface: const HermesSurfaceStyle(mode: HermesSurfaceMode.glass),
        window: _glassWindow,
      );
      final surface = theme.extension<HermesSurface>()!;
      expect(surface.glass, isTrue);
      expect(theme.scaffoldBackgroundColor.a, 0);
      expect(theme.dialogTheme.backgroundColor!.a, greaterThanOrEqualTo(0.9));
      expect(
        theme.bottomSheetTheme.modalBackgroundColor!.a,
        greaterThanOrEqualTo(0.9),
      );
      // Raised panels brighten the wallpaper rather than darkening it.
      final raised = theme.extension<HermesTokens>()!.raised;
      expect(raised.r, greaterThan(0.9));
      expect(raised.a, lessThan(0.5));
    });

    test('quiet chrome hides navigation labels and card outlines', () {
      final theme = hermesTheme(
        Brightness.light,
        surface: const HermesSurfaceStyle(quietChrome: true),
      );
      expect(
        theme.navigationBarTheme.labelBehavior,
        NavigationDestinationLabelBehavior.alwaysHide,
      );
      final shape = theme.cardTheme.shape! as RoundedRectangleBorder;
      expect(shape.side, BorderSide.none);
    });
  });

  group('ThemePreferenceStore surface', () {
    test('round-trips every field', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = ThemePreferenceStore(prefs);
      const style = HermesSurfaceStyle(
        mode: HermesSurfaceMode.glass,
        preset: HermesGlassPreset.deep,
        tint: 0.7,
        blur: 40,
        material: HermesMaterial.slate,
        quietChrome: true,
        liquidChrome: false,
      );
      await store.saveSurface(style);
      expect(store.readSurface(), style);
      // The native window reads the effective blur for its first frame.
      expect(prefs.getDouble(ThemePreferenceStore.nativeBlurKey), 40);
    });

    test('damaged backup values fall back field by field', () async {
      SharedPreferences.setMockInitialValues({
        ThemePreferenceStore.surfaceKey: 'hologram',
        ThemePreferenceStore.presetKey: 7,
        ThemePreferenceStore.tintKey: 'dark',
        ThemePreferenceStore.blurKey: 9000.0,
        ThemePreferenceStore.materialKey: 'water',
        ThemePreferenceStore.quietChromeKey: 'yes',
      });
      final prefs = await SharedPreferences.getInstance();
      final style = ThemePreferenceStore(prefs).readSurface();
      expect(style.mode, HermesSurfaceMode.solid);
      expect(style.preset, HermesGlassPreset.clear);
      expect(style.tint, isNull);
      expect(style.blur, HermesSurfaceStyle.maxBlur);
      expect(style.material, HermesMaterial.water);
      expect(style.quietChrome, isFalse);
      expect(style.liquidChrome, isTrue);
    });

    test('a preset clears custom tint and blur', () {
      const custom = HermesSurfaceStyle(tint: 0.5, blur: 10);
      final next = custom.copyWith(
        preset: HermesGlassPreset.clear,
        clearCustom: true,
      );
      expect(next.tint, isNull);
      expect(next.blur, isNull);
      expect(next.effectiveBlur, HermesGlassPreset.clear.blur);
    });
  });
}
