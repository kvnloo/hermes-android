// Pieces the Security, Caching and Chat pages share: a titled card, a
// two-line toggle tile and the grey footnote under a card's rows. Colours
// come from NgColors only.
import 'package:flutter/material.dart';

import '../../../nextgen/theme/nextgen_theme.dart';
import '../../hm_ui.dart';

/// A rounded card: optional heading (with an icon, or plain grey), rows,
/// and a footnote.
class HmSettingsCard extends StatelessWidget {
  const HmSettingsCard({
    super.key,
    this.icon,
    this.title,
    required this.children,
    this.footnote,
  });

  final IconData? icon;
  final String? title;
  final List<Widget> children;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: HmMetrics.edge),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: HmMetrics.edge),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(HmMetrics.groupRadius),
          border: Border.all(color: c.stroke),
          boxShadow: hmShadow(c),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 22, color: c.text),
                      const SizedBox(width: 14),
                    ],
                    Expanded(
                      child: Text(
                        title!,
                        style: icon != null
                            ? HmType.row.copyWith(color: c.text)
                            : HmType.value.copyWith(color: c.text3),
                      ),
                    ),
                  ],
                ),
              ),
            ...children,
            if (footnote != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  footnote!,
                  style: HmType.caption.copyWith(color: c.text3),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A title, a description under it and a switch on the right.
class HmToggleTile extends StatelessWidget {
  const HmToggleTile({
    super.key,
    this.icon,
    required this.title,
    this.description,
    required this.value,
    this.onChanged,
  });

  final IconData? icon;
  final String title;
  final String? description;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final enabled = onChanged != null;
    final ink = enabled ? c.text : c.text3;
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: enabled ? () => onChanged!(!value) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 24, color: c.text2),
                const SizedBox(width: 18),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: HmType.row.copyWith(color: ink)),
                    if (description != null)
                      Text(
                        description!,
                        style: HmType.value.copyWith(color: c.text3),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Switch(
                value: value,
                onChanged: onChanged,
                activeThumbColor: c.onAccent,
                activeTrackColor: c.accent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A radio-style choice row: label, optional description, a check when on.
class HmChoiceTile extends StatelessWidget {
  const HmChoiceTile({
    super.key,
    required this.label,
    this.description,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String? description;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: HmType.row.copyWith(color: c.text)),
                    if (description != null)
                      Text(
                        description!,
                        style: HmType.caption.copyWith(color: c.text3),
                      ),
                  ],
                ),
              ),
              Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                color: selected ? c.accent : c.text3,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void hmSettingsToast(BuildContext context, String text) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}
