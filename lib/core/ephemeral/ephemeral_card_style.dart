import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum EphemeralCardStyle { appTheme, serviceNative }

/// A device preference shared by chat, live and the gallery.
final ephemeralCardStyle = ValueNotifier(EphemeralCardStyle.appTheme);

abstract final class EphemeralCardPreferences {
  static const key = 'ephemeral_card_style';

  static void load(SharedPreferences prefs) {
    ephemeralCardStyle.value =
        prefs.get(key) == EphemeralCardStyle.serviceNative.name
        ? EphemeralCardStyle.serviceNative
        : EphemeralCardStyle.appTheme;
  }

  static Future<void> set(
    SharedPreferences prefs,
    EphemeralCardStyle style,
  ) async {
    ephemeralCardStyle.value = style;
    await prefs.setString(key, style.name);
  }
}
