import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shared_ui/glide_theme.dart';

/// A device appearance preference, independent of the selected model route.
abstract final class TurboMotion {
  static const preferenceKey = GlideTheme.turboPreferenceKey;

  static final _enabled = ValueNotifier(false);
  static ValueListenable<bool> get enabled => _enabled;

  static void load(SharedPreferences prefs) {
    _enabled.value = prefs.getBool(preferenceKey) ?? false;
  }

  static Future<void> setEnabled(SharedPreferences prefs, bool enabled) async {
    _enabled.value = enabled;
    await prefs.setBool(preferenceKey, enabled);
  }

  static bool _accelerates(BuildContext context) =>
      enabled.value && !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

  static double? _factor(BuildContext context, ThemeData theme) =>
      _accelerates(context) ? theme.extension<GlideTheme>()?.turboFactor : null;

  static Duration _scaled(Duration duration, double factor) =>
      Duration(microseconds: (duration.inMicroseconds / factor).round());

  static Duration duration(BuildContext context, Duration normal) {
    context.dependOnInheritedWidgetOfExactType<TurboMotionScope>();
    final factor = _factor(context, Theme.of(context));
    return factor == null ? normal : _scaled(normal, factor);
  }

  static AnimationStyle? sheetStyle(BuildContext context) {
    final factor = _factor(context, Theme.of(context));
    if (factor == null) return null;
    // Match Flutter's unmodified Material bottom-sheet durations.
    return AnimationStyle(
      duration: _scaled(const Duration(milliseconds: 250), factor),
      reverseDuration: _scaled(const Duration(milliseconds: 200), factor),
    );
  }

  static ThemeData applyToTheme(BuildContext context, ThemeData theme) {
    final factor = _factor(context, theme);
    if (factor == null) return theme;
    final builders = theme.pageTransitionsTheme.builders;
    return theme.copyWith(
      pageTransitionsTheme: PageTransitionsTheme(
        builders: {
          for (final platform in TargetPlatform.values)
            platform: _TurboPageTransition(
              builders[platform] ?? const ZoomPageTransitionsBuilder(),
              factor,
            ),
        },
      ),
    );
  }
}

/// Lets widgets with implicit animations update their durations on toggle.
class TurboMotionScope extends InheritedNotifier<ValueNotifier<bool>> {
  TurboMotionScope({super.key, required super.child})
    : super(notifier: TurboMotion._enabled);
}

/// Changes the route clock, not the platform transition or back gesture.
class _TurboPageTransition extends PageTransitionsBuilder {
  const _TurboPageTransition(this.base, this.factor);

  final PageTransitionsBuilder base;
  final double factor;

  @override
  bool operator ==(Object other) =>
      other is _TurboPageTransition &&
      other.base == base &&
      other.factor == factor;

  @override
  int get hashCode => Object.hash(_TurboPageTransition, base, factor);

  @override
  Duration get transitionDuration =>
      TurboMotion._scaled(base.transitionDuration, factor);

  @override
  Duration get reverseTransitionDuration =>
      TurboMotion._scaled(base.reverseTransitionDuration, factor);

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      base.delegatedTransition;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => base.buildTransitions(
    route,
    context,
    animation,
    secondaryAnimation,
    child,
  );
}
