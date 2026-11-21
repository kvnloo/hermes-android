import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The Android bridge reports the window actually in use on this launch.
class GlassWindowService extends ChangeNotifier {
  GlassWindowService({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel('com.hermesagent.hermes_android/glass');

  static final shared = GlassWindowService();

  final MethodChannel _channel;
  bool _available = false;
  bool _transparent = false;
  bool _blurred = false;

  bool get available => _available;
  bool get transparent => _transparent;
  bool get blurred => _blurred;

  Future<void> init() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'blurChanged' && _transparent) {
        final args = call.arguments;
        _blurred = args is Map && args['enabled'] == true;
        notifyListeners();
      }
    });
    Map<String, Object?>? state;
    try {
      state = await _channel.invokeMapMethod<String, Object?>('state');
    } on MissingPluginException {
      // Other platforms have no wallpaper window.
    } on PlatformException {
      // Without native confirmation the theme resolves to Solid.
    }
    _available = state != null;
    _transparent =
        state?['transparent'] == true && state?['showsWallpaper'] == true;
    _blurred = _transparent && state?['crossWindowBlurEnabled'] == true;
    notifyListeners();
  }

  Future<bool> recreateWindow() async {
    try {
      return await _channel.invokeMethod<bool>('recreate') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
