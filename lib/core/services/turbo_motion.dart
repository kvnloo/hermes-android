import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A device appearance preference, independent of the selected model route.
abstract final class TurboMotion {
  static const preferenceKey = 'turbo_motion_enabled';
  static const durationFactor = 0.55;

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

  static Duration _scaled(Duration duration) => duration * durationFactor;

  static Duration duration(BuildContext context, Duration normal) {
    context.dependOnInheritedWidgetOfExactType<TurboMotionScope>();
    return _accelerates(context) ? _scaled(normal) : normal;
  }

  static AnimationStyle? sheetStyle(BuildContext context) {
    if (!_accelerates(context)) return null;
    // Match Flutter's unmodified Material bottom-sheet durations.
    return AnimationStyle(
      duration: _scaled(const Duration(milliseconds: 250)),
      reverseDuration: _scaled(const Duration(milliseconds: 200)),
    );
  }

  static ThemeData applyToTheme(BuildContext context, ThemeData theme) {
    if (!_accelerates(context)) return theme;
    final builders = theme.pageTransitionsTheme.builders;
    return theme.copyWith(
      pageTransitionsTheme: PageTransitionsTheme(
        builders: {
          for (final platform in TargetPlatform.values)
            platform: _TurboPageTransition(
              builders[platform] ?? const ZoomPageTransitionsBuilder(),
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
  const _TurboPageTransition(this.base);

  final PageTransitionsBuilder base;

  @override
  bool operator ==(Object other) =>
      other is _TurboPageTransition && other.base == base;

  @override
  int get hashCode => Object.hash(_TurboPageTransition, base);

  @override
  Duration get transitionDuration =>
      TurboMotion._scaled(base.transitionDuration);

  @override
  Duration get reverseTransitionDuration =>
      TurboMotion._scaled(base.reverseTransitionDuration);

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
