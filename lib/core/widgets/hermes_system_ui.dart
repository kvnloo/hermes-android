import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/hermes_surface.dart';
import '../theme/hermes_theme.dart';
import 'hermes_glass_backdrop.dart';

/// Own the pixels behind button navigation instead of relying on Android's
/// scrim, whose icon tint can follow the OS rather than the app's forced mode.
class HermesSystemUi extends StatelessWidget {
  const HermesSystemUi({required this.child, this.cinema = false, super.key});

  final Widget child;
  final bool cinema;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final paintsNavigation =
        defaultTargetPlatform == TargetPlatform.android &&
        media.viewPadding.bottom > 0 &&
        media.systemGestureInsets.left == 0 &&
        media.systemGestureInsets.right == 0;
    var style = hermesSystemUiStyle(
      HermesTokens.of(context),
      navigationBrightness: media.platformBrightness,
    ).copyWith(systemNavigationBarContrastEnforced: !paintsNavigation);
    final surface = HermesSurface.of(context);
    if (surface.glass) {
      // The glass scene owns the pixels behind gesture or button navigation.
      style = style.copyWith(
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
      );
    }
    if (cinema) {
      style = style.copyWith(
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      );
    }
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: style,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (surface.glass) HermesGlassBackdrop(surface: surface),
          child,
          if (paintsNavigation && !surface.glass)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: media.viewPadding.bottom,
              child: IgnorePointer(
                child: ColoredBox(
                  key: const Key('hermes_system_navigation_surface'),
                  color: style.systemNavigationBarColor!,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
