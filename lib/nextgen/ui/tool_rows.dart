// The reply's tool activity, shared by the chat and the live call: a folding
// header (spinner while a tool runs) over one row per tool call.
import 'package:flutter/material.dart';

import '../data/chat_controller.dart';
import '../nextgen_l10n.dart';
import '../theme/nextgen_theme.dart';
import 'widgets.dart';

/// The folded header's words: the running tool and its detail, else what
/// was used.
String ngToolsLabel(List<NgTool> tools) {
  final running = tools.where((t) => t.running).lastOrNull;
  if (running != null) {
    return '${running.name}${running.detail == null ? '' : ' · ${running.detail}'}';
  }
  return tools.length == 1
      ? ngL.ng_used(tools.first.name)
      : ngL.ng_used_tools(tools.length);
}

/// A tappable header that folds its [child] away: the reply's Thinking and
/// Tools sections, and the live call's work rows.
class NgDisclosure extends StatelessWidget {
  const NgDisclosure({
    super.key,
    required this.icon,
    required this.label,
    required this.open,
    required this.onTap,
    required this.child,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final bool open;
  final bool busy;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(NgRadii.sm),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (busy)
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        color: c.accent,
                      ),
                    )
                  else
                    Icon(icon, size: 16, color: c.text3),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NgType.label.copyWith(color: c.text3),
                    ),
                  ),
                  Icon(
                    open ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: c.text3,
                  ),
                ],
              ),
            ),
          ),
          if (open)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(NgRadii.md),
                border: Border.all(color: c.stroke),
              ),
              child: child,
            ),
        ],
      ),
    );
  }
}

/// One tool call: status icon, name, a one-line detail or result, time and
/// duration; tap to show its input and output.
class NgToolRow extends StatefulWidget {
  const NgToolRow({super.key, required this.tool});
  final NgTool tool;

  @override
  State<NgToolRow> createState() => _NgToolRowState();
}

class _NgToolRowState extends State<NgToolRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final t = widget.tool;
    final detail = t.summary ?? t.detail;
    final hasBody =
        (t.input?.isNotEmpty ?? false) || (t.output?.isNotEmpty ?? false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: hasBody ? () => setState(() => _open = !_open) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(
                  t.running
                      ? Icons.more_horiz
                      : t.failed
                      ? Icons.error_outline
                      : Icons.check,
                  size: 15,
                  color: t.failed ? c.danger : c.text3,
                ),
                const SizedBox(width: 8),
                Flexible(
                  flex: 2,
                  child: Text(
                    t.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NgType.label.copyWith(color: c.text2),
                  ),
                ),
                if (detail != null && detail.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 3,
                    child: Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NgType.caption.copyWith(color: c.text3),
                    ),
                  ),
                ] else
                  const Spacer(),
                if (t.startedAt != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      ngStamp(context, t.startedAt!, seconds: true),
                      key: const ValueKey('ng-tool-time'),
                      style: NgType.caption.copyWith(color: c.textMuted),
                    ),
                  ),
                if (t.durationSeconds != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(
                      '${t.durationSeconds!.toStringAsFixed(1)}s',
                      style: NgType.caption.copyWith(color: c.textMuted),
                    ),
                  )
                else if (t.startedAt != null &&
                    t.finishedAt != null &&
                    t.finishedAt!.isAfter(t.startedAt!))
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(
                      '${(t.finishedAt!.difference(t.startedAt!).inMilliseconds / 1000).toStringAsFixed(1)}s',
                      style: NgType.caption.copyWith(color: c.textMuted),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (_open) ...[
          if (t.input?.isNotEmpty ?? false) _codeBlock(c, t.input!),
          if (t.output?.isNotEmpty ?? false) _codeBlock(c, t.output!),
        ],
      ],
    );
  }

  Widget _codeBlock(NgColors c, String text) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 6),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: c.well,
      borderRadius: BorderRadius.circular(NgRadii.sm),
    ),
    child: SelectableText(
      text.length > 4000 ? '${text.substring(0, 4000)}…' : text,
      style: NgType.code.copyWith(color: c.text2, fontSize: 11.5),
    ),
  );
}
