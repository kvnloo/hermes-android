// Haptic vocabulary ported from Dash (kvnloo/dash app/src/haptics.ts): one
// light tap per press, a selection tick, and distinct success/error pulses
// for outcomes. Android honours the system "touch feedback" setting.
import 'package:flutter/services.dart';

abstract final class NgHaptics {
  static void tap() => HapticFeedback.lightImpact();
  static void select() => HapticFeedback.selectionClick();
  static void success() => HapticFeedback.mediumImpact();
  static void error() => HapticFeedback.heavyImpact();
}
