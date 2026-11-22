// The Hermes-style design system: floating round buttons, rounded setting
// groups, rows with a trailing value, and Nunito type. Metrics follow the
// official app's layout (measured in dp from its accessibility tree); every
// colour comes from [NgColors], so the theme engine restyles all of it.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../nextgen/theme/nextgen_theme.dart';

abstract final class HmMetrics {
  static const edge = 16.0; // screen margin
  static const roundButton = 48.0;
  static const fab = 56.0;
  static const headerTop = 8.0; // below the status bar
  static const groupRadius = 24.0;
  static const groupPad = 12.0;
  static const groupGap = 24.0;
  static const rowHeight = 48.0;
  static const tallRowHeight = 52.0;
  static const botRowHeight = 60.0;
  static const botAvatar = 40.0;
}

abstract final class HmType {
  static const family = 'Nunito';
  static const screenTitle = TextStyle(
    fontFamily: family,
    fontSize: 22,
    fontWeight: FontWeight.w700,
    height: 1.25,
  );
  static const display = TextStyle(
    fontFamily: family,
    fontSize: 24,
    fontWeight: FontWeight.w800,
    height: 1.2,
  );
  static const row = TextStyle(
    fontFamily: family,
    fontSize: 17,
    fontWeight: FontWeight.w500,
    height: 1.35,
  );
  static const value = TextStyle(
    fontFamily: family,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    height: 1.35,
  );
  static const sub = TextStyle(
    fontFamily: family,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.3,
  );
  static const section = TextStyle(
    fontFamily: family,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    height: 1.35,
  );
  static const body = TextStyle(
    fontFamily: family,
    fontSize: 17,
    fontWeight: FontWeight.w400,
    height: 1.45,
  );
  static const caption = TextStyle(
    fontFamily: family,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.3,
  );
  static const pill = TextStyle(
    fontFamily: family,
    fontSize: 15,
    fontWeight: FontWeight.w700,
    height: 1.3,
  );
}

/// Soft shadow under floating controls and groups.
List<BoxShadow> hmShadow(NgColors c) => [
  BoxShadow(
    color: c.floatingShadow,
    blurRadius: 12,
    offset: const Offset(0, 3),
  ),
];

/// A 48dp floating circular control (back, settings, search, more…).
class HmRoundButton extends StatelessWidget {
  const HmRoundButton({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.size = HmMetrics.roundButton,
    this.filled = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final double size;

  /// Accent-filled (the composer's mic/send).
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final bg = filled ? c.accentSoft : c.surface;
    final fg = filled ? c.accentText : c.text;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: SizedBox.square(
          dimension: size,
          child: Material(
            color: bg,
            shape: const CircleBorder(),
            elevation: filled ? 0 : 3,
            shadowColor: c.controlShadow,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed == null
                  ? null
                  : () {
                      HapticFeedback.selectionClick();
                      onPressed!();
                    },
              child: Icon(icon, size: size * 0.5, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}

/// Top bar of floating round buttons: leading control, an optional title
/// next to it, and trailing controls.
class HmTopBar extends StatelessWidget {
  const HmTopBar({
    super.key,
    this.leading,
    this.title,
    this.center,
    this.trailing = const [],
  });

  final Widget? leading;
  final String? title;
  final Widget? center;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          HmMetrics.edge,
          HmMetrics.headerTop,
          HmMetrics.edge,
          HmMetrics.headerTop,
        ),
        child: SizedBox(
          height: HmMetrics.roundButton,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (center != null) Center(child: center),
              Row(
                children: [
                  ?leading,
                  if (title != null)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Text(
                          title!,
                          style: HmType.screenTitle.copyWith(color: c.text),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  for (var i = 0; i < trailing.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    trailing[i],
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The back control every pushed screen leads with.
class HmBackButton extends StatelessWidget {
  const HmBackButton({super.key, this.onPressed});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => HmRoundButton(
    icon: Icons.arrow_back,
    label: MaterialLocalizations.of(context).backButtonTooltip,
    onPressed: onPressed ?? () => Navigator.of(context).maybePop(),
  );
}

/// A rounded card holding rows separated by inset dividers.
class HmGroup extends StatelessWidget {
  const HmGroup({super.key, required this.children, this.padding});

  final List<Widget> children;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          Divider(
            height: 1,
            thickness: 1,
            indent: 16,
            endIndent: 16,
            color: c.stroke,
          ),
        );
      }
      rows.add(children[i]);
    }
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: HmMetrics.edge),
      padding:
          padding ?? const EdgeInsets.symmetric(vertical: HmMetrics.groupPad),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(HmMetrics.groupRadius),
        border: Border.all(color: c.stroke),
        boxShadow: hmShadow(c),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: rows),
    );
  }
}

/// Small grey heading above a group.
class HmSection extends StatelessWidget {
  const HmSection(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, HmMetrics.groupGap, 32, 10),
      child: Text(text, style: HmType.section.copyWith(color: c.text3)),
    );
  }
}

/// One settings row: icon, label, optional trailing value (and sub-value),
/// and a chevron when it opens something.
class HmRow extends StatelessWidget {
  const HmRow({
    super.key,
    this.icon,
    this.leading,
    required this.label,
    this.value,
    this.subValue,
    this.onTap,
    this.trailing,
    this.tall = false,
    this.danger = false,
    this.chevron = true,
  });

  final IconData? icon;

  /// Drawn in place of [icon] (a live avatar preview, say).
  final Widget? leading;
  final String label;
  final String? value;
  final String? subValue;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool tall;
  final bool danger;
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final ink = danger ? c.danger : c.text;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: tall ? HmMetrics.tallRowHeight : HmMetrics.rowHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: 14),
              ] else if (icon != null) ...[
                Icon(icon, size: 24, color: ink),
                const SizedBox(width: 18),
              ],
              Expanded(
                child: Text(
                  label,
                  style: HmType.row.copyWith(color: ink),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (value != null || subValue != null)
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (value != null)
                        Text(
                          value!,
                          style: HmType.value.copyWith(color: c.text3),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (subValue != null)
                        Text(
                          subValue!,
                          style: HmType.sub.copyWith(color: c.textMuted),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ?trailing,
              if (chevron && onTap != null && trailing == null) ...[
                const SizedBox(width: 8),
                Icon(Icons.chevron_right, size: 22, color: c.text3),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A row with a switch (Remember password, Security…).
class HmSwitchRow extends StatelessWidget {
  const HmSwitchRow({
    super.key,
    this.icon,
    required this.label,
    required this.value,
    this.onChanged,
    this.subtitle,
  });

  final IconData? icon;
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return HmRow(
      icon: icon,
      label: label,
      tall: subtitle != null,
      chevron: false,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeThumbColor: c.onAccent,
        activeTrackColor: c.accent,
      ),
    );
  }
}

/// Full-screen page scaffold with the floating top bar and a scrolling body.
class HmPage extends StatelessWidget {
  const HmPage({
    super.key,
    required this.title,
    required this.children,
    this.trailing = const [],
    this.bottom,
  });

  final String title;
  final List<Widget> children;
  final List<Widget> trailing;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Scaffold(
      backgroundColor: c.background,
      body: Column(
        children: [
          HmTopBar(
            leading: const HmBackButton(),
            title: title,
            trailing: trailing,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 12, bottom: 32),
              children: children,
            ),
          ),
          ?bottom,
        ],
      ),
    );
  }
}

/// Accent pill CTA pinned under content (Connect →).
class HmPrimaryButton extends StatelessWidget {
  const HmPrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.busy = false,
    this.trailingIcon = Icons.arrow_forward,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final IconData? trailingIcon;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final enabled = onPressed != null && !busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
      child: SizedBox(
        height: 52,
        width: double.infinity,
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: c.accent,
            foregroundColor: c.onAccent,
            disabledBackgroundColor: c.accent.withValues(alpha: 0.45),
            disabledForegroundColor: c.onAccent.withValues(alpha: 0.8),
            shape: const StadiumBorder(),
            elevation: 2,
          ),
          onPressed: enabled ? onPressed : null,
          child: busy
              ? SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: c.onAccent,
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: HmType.row.copyWith(
                        fontWeight: FontWeight.w600,
                        color: c.onAccent,
                      ),
                    ),
                    if (trailingIcon != null) ...[
                      const SizedBox(width: 8),
                      Icon(trailingIcon, size: 20),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}
