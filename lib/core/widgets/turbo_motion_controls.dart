import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../services/turbo_motion.dart';

class TurboMotionSwitch extends StatelessWidget {
  const TurboMotionSwitch({super.key, required this.preferences});

  final SharedPreferences preferences;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: TurboMotion.enabled,
    builder: (context, enabled, _) => SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(context.l10n.turbo_motion),
      subtitle: Text(context.l10n.turbo_motion_description),
      value: enabled,
      onChanged: (value) => TurboMotion.setEnabled(preferences, value),
    ),
  );
}

/// A text badge, not just a color, so Turbo is recognizable at a glance.
class TurboMotionBadge extends StatelessWidget {
  const TurboMotionBadge({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: TurboMotion.enabled,
    builder: (context, enabled, _) {
      if (!enabled) return const SizedBox.shrink();
      final theme = Theme.of(context);
      return Container(
        key: const ValueKey('turbo-motion-badge'),
        margin: const EdgeInsetsDirectional.only(end: 4),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          context.l10n.turbo_section,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
      );
    },
  );
}
