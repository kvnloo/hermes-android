import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../theme/hermes_surface.dart';

/// Dart side of `GlassWindowPlugin.kt`: whether the activity window is
/// transparent, whether the compositor can blur it right now, and the blur
/// radius it should apply.
class GlassWindowService extends ChangeNotifier {
  GlassWindowService({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel('com.hermesagent.hermes_android/glass');

  static final GlassWindowService shared = GlassWindowService();

  final MethodChannel _channel;
  HermesWindowCapabilities _capabilities = HermesWindowCapabilities.unknown;
  bool _initialized = false;

  HermesWindowCapabilities get capabilities => _capabilities;

  /// Reads the window state once; safe to call repeatedly and off Android.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'blurChanged') {
        final args = call.arguments;
        final enabled = args is Map && args['enabled'] == true;
        _update(
          HermesWindowCapabilities(
            transparent: _capabilities.transparent,
            crossWindowBlur: enabled,
          ),
        );
      }
      return null;
    });
    await _refresh();
  }

  Future<void> _refresh() async {
    try {
      final state = await _channel.invokeMapMethod<String, Object?>('state');
      if (state == null) return;
      _update(_parse(state));
    } on MissingPluginException {
      // Not Android, or a test host: stay unknown (renders Solid).
    } on PlatformException {
      // A failing bridge must never break the app; Solid is always safe.
    }
  }

  static HermesWindowCapabilities _parse(Map<String, Object?> state) {
    return HermesWindowCapabilities(
      transparent:
          state['transparent'] == true && state['showsWallpaper'] == true,
      crossWindowBlur: state['crossWindowBlurEnabled'] as bool?,
    );
  }

  void _update(HermesWindowCapabilities next) {
    if (next == _capabilities) return;
    _capabilities = next;
    notifyListeners();
  }

  /// Applies the compositor blur for the current style (0 for Solid).
  Future<void> applyStyle(HermesSurfaceStyle style) async {
    if (!_capabilities.transparent) return;
    try {
      final state = await _channel.invokeMapMethod<String, Object?>('setBlur', {
        'dp': style.isGlass ? style.effectiveBlur : 0.0,
      });
      if (state != null) _update(_parse(state));
    } on MissingPluginException {
      // Not Android.
    } on PlatformException {
      // Keep the previous blur; the tint already compensates for none.
    }
  }

  /// True when the saved surface needs a different window than the current one.
  bool needsRecreate(HermesSurfaceStyle style) =>
      style.isGlass != _capabilities.transparent;

  /// Recreates the activity so its window matches the saved surface.
  Future<bool> recreateWindow() async {
    try {
      return await _channel.invokeMethod<bool>('recreate') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @visibleForTesting
  void debugSetCapabilities(HermesWindowCapabilities value) => _update(value);
}
