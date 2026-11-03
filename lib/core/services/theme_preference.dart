import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/hermes_surface.dart';
import '../theme/hermes_theme.dart';

/// Device-wide appearance preferences, independent of gateway profiles.
class ThemePreferenceStore {
  ThemePreferenceStore(this._preferences);

  static const paletteKey = 'theme_palette';
  static const modeKey = 'theme_mode';
  static const surfaceKey = 'theme_surface';
  static const presetKey = 'theme_glass_preset';
  static const tintKey = 'theme_glass_tint';
  static const blurKey = 'theme_glass_blur';

  /// Effective blur for the native window's first frame (read by Kotlin).
  static const nativeBlurKey = 'theme_glass_blur_dp';
  static const materialKey = 'theme_material';
  static const quietChromeKey = 'theme_quiet_chrome';
  static const liquidChromeKey = 'theme_liquid_chrome';
  static final _writes = Expando<_ThemeWriteQueue>();

  final SharedPreferences _preferences;

  /// Unknown IDs and incorrectly typed backup values are read non-destructively.
  HermesPalette readPalette() {
    final value = _preferences.get(paletteKey);
    return HermesPalette.values.firstWhere(
      (palette) => palette.name == value,
      orElse: () => HermesPalette.gold,
    );
  }

  ThemeMode readMode() {
    return switch (_preferences.get(modeKey)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  /// Unknown names and wrongly typed backup values fall back per field.
  HermesSurfaceStyle readSurface() {
    T byName<T extends Enum>(List<T> values, String key, T fallback) {
      final value = _preferences.get(key);
      return values.firstWhere((v) => v.name == value, orElse: () => fallback);
    }

    double? number(String key) => switch (_preferences.get(key)) {
      final num value when value.isFinite => value.toDouble(),
      _ => null,
    };

    bool flag(String key, bool fallback) => switch (_preferences.get(key)) {
      final bool value => value,
      _ => fallback,
    };

    return HermesSurfaceStyle(
      mode: byName(
        HermesSurfaceMode.values,
        surfaceKey,
        HermesSurfaceMode.solid,
      ),
      preset: byName(
        HermesGlassPreset.values,
        presetKey,
        HermesGlassPreset.frost,
      ),
      tint: number(tintKey)?.clamp(0, 1).toDouble(),
      blur: number(blurKey)?.clamp(0, HermesSurfaceStyle.maxBlur).toDouble(),
      material: byName(HermesMaterial.values, materialKey, HermesMaterial.none),
      quietChrome: flag(quietChromeKey, false),
      liquidChrome: flag(liquidChromeKey, true),
    );
  }

  /// Saves every surface field in order; a failed field rolls back only itself.
  Future<void> saveSurface(HermesSurfaceStyle style) async {
    await _save(surfaceKey, style.mode.name);
    await _save(presetKey, style.preset.name);
    await _saveNumber(tintKey, style.tint);
    await _saveNumber(blurKey, style.blur);
    await _saveNumber(nativeBlurKey, style.effectiveBlur.roundToDouble());
    await _save(materialKey, style.material.name);
    await _saveBool(quietChromeKey, style.quietChrome);
    await _saveBool(liquidChromeKey, style.liquidChrome);
  }

  Future<void> _saveNumber(String key, double? value) => _transact(
    key,
    () => value == null
        ? _preferences.remove(key)
        : _preferences.setDouble(key, value),
  );

  Future<void> _saveBool(String key, bool value) =>
      _transact(key, () => _preferences.setBool(key, value));

  Future<void> savePalette(HermesPalette palette) =>
      _save(paletteKey, palette.name);

  Future<void> saveMode(ThemeMode mode) => _save(modeKey, mode.name);

  Future<void> _save(String key, String value) =>
      _transact(key, () => _preferences.setString(key, value));

  Future<void> _transact(String key, Future<bool> Function() write) {
    final queue = _writes[_preferences] ??= _ThemeWriteQueue();
    return queue.enqueue(() async {
      // Capture the baseline when this transaction starts, not when queued:
      // a failed older selection must never undo a newer confirmed selection.
      final previous = _preferences.get(key);
      try {
        if (!await write()) {
          throw StateError('Could not persist $key');
        }
      } catch (_) {
        // Legacy SharedPreferences changes its cache before awaiting storage.
        // These setters also restore that cache synchronously if storage is
        // still unavailable. Surface the original failure, not the rollback.
        try {
          await _restore(key, previous);
        } catch (_) {
          // The original save remains a failure; never announce it as saved.
        }
        rethrow;
      }
    });
  }

  Future<bool> _restore(String key, Object? value) => switch (value) {
    null => _preferences.remove(key),
    String value => _preferences.setString(key, value),
    bool value => _preferences.setBool(key, value),
    int value => _preferences.setInt(key, value),
    double value => _preferences.setDouble(key, value),
    List value => _preferences.setStringList(key, value.cast<String>()),
    _ => throw StateError('Unsupported preference value for $key'),
  };
}

/// Shared across short-lived stores for the same preferences instance.
class _ThemeWriteQueue {
  Future<void> _tail = Future<void>.value();

  Future<void> enqueue(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
