// Small pieces the Connections, Plugins and MCP screens share: the page
// frame, centred empty/error states, confirm dialogs, pills and chips.
import 'package:flutter/material.dart';

import '../../../nextgen/theme/nextgen_theme.dart';
import '../../hm_bots.dart';
import '../../hm_ui.dart';
import 'integrations_api.dart';

/// The scoped client for [bot].
HmIntegrationsApi hmIntegrationsFor(HmBot bot, HmBotsModel bots) =>
    HmIntegrationsApi(HmGatewayTransport(bots.gateway), profile: bot.scope);

Future<T?> hmPushPage<T>(BuildContext context, Widget page) =>
    Navigator.of(context).push(MaterialPageRoute<T>(builder: (_) => page));

/// Loading → loaded or failed, for one screen's data.
@immutable
class HmLoad<T> {
  const HmLoad.loading() : data = null, error = null, loading = true;
  const HmLoad.loaded(T this.data) : error = null, loading = false;
  const HmLoad.failed(HmIntegrationsError this.error)
    : data = null,
      loading = false;

  final T? data;
  final HmIntegrationsError? error;
  final bool loading;
}

HmIntegrationsError hmAsError(Object e) => e is HmIntegrationsError
    ? e
    : HmIntegrationsError(HmFailure.unavailable, '$e');

void hmToast(BuildContext context, String message) {
  final m = ScaffoldMessenger.maybeOf(context);
  m?.hideCurrentSnackBar();
  m?.showSnackBar(SnackBar(content: Text(message)));
}

/// Page frame: floating top bar plus a body that may be a list or a centred
/// state.
class HmIntegrationsFrame extends StatelessWidget {
  const HmIntegrationsFrame({
    super.key,
    required this.title,
    required this.body,
    this.trailing = const [],
  });

  final String title;
  final Widget body;
  final List<Widget> trailing;

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
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// Two controls in one floating pill (MCP's Catalog + Add Server).
class HmButtonPair extends StatelessWidget {
  const HmButtonPair({super.key, required this.children});
  final List<HmPairItem> children;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Material(
      color: c.surface,
      shape: const StadiumBorder(),
      elevation: 3,
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: HmMetrics.roundButton,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in children)
              Semantics(
                button: true,
                label: item.label,
                excludeSemantics: true,
                child: Tooltip(
                  message: item.label,
                  child: InkWell(
                    onTap: item.onPressed,
                    child: SizedBox(
                      width: 60,
                      height: HmMetrics.roundButton,
                      child: Icon(item.icon, size: 24, color: c.text),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class HmPairItem {
  const HmPairItem(this.icon, this.label, this.onPressed);
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
}

/// A centred icon, title and line of help (empty and unavailable states).
class HmCenteredState extends StatelessWidget {
  const HmCenteredState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: c.text3),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: HmType.row.copyWith(
                color: c.text,
                fontSize: 19,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: HmType.value.copyWith(color: c.text3),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              HmPillButton(label: actionLabel!, onPressed: onAction),
            ],
          ],
        ),
      ),
    );
  }
}

/// Outlined stadium button ("Connect", "Try Again", "Install").
class HmPillButton extends StatelessWidget {
  const HmPillButton({
    super.key,
    required this.label,
    this.onPressed,
    this.busy = false,
    this.semanticLabel,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final child = busy
        ? SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: c.text2),
          )
        : Text(label, style: HmType.value.copyWith(color: c.text));
    return Semantics(
      container: true,
      button: true,
      label: semanticLabel ?? label,
      excludeSemantics: semanticLabel != null,
      child: Material(
        color: c.surface,
        shape: StadiumBorder(side: BorderSide(color: c.stroke)),
        elevation: 1.5,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: busy ? null : onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 92, minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: Center(widthFactor: 1, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// A filter chip (All / Commerce / …).
class HmChip extends StatelessWidget {
  const HmChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? c.accentSoft : c.surface,
        shape: StadiumBorder(
          side: BorderSide(color: selected ? c.accent : c.stroke),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            child: Text(
              label,
              style: HmType.value.copyWith(
                color: selected ? c.accentText : c.text,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The rounded search well ("Search services").
class HmSearchField extends StatelessWidget {
  const HmSearchField({super.key, required this.hint, required this.onChanged});
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HmMetrics.edge),
      child: Semantics(
        label: hint,
        textField: true,
        child: TextField(
          onChanged: onChanged,
          style: HmType.row.copyWith(color: c.text),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: HmType.row.copyWith(color: c.text3),
            prefixIcon: Icon(Icons.search, color: c.text2),
            filled: true,
            fillColor: c.well,
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(30),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );
  }
}

/// Initial-letter tile standing in for a service's logo.
class HmLetterTile extends StatelessWidget {
  const HmLetterTile(this.name, {super.key});
  final String name;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final letter = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    return Container(
      width: 48,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        letter,
        style: HmType.row.copyWith(color: c.text2, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Large section heading inside a list ("This Device", "Commerce").
class HmListHeading extends StatelessWidget {
  const HmListHeading(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(HmMetrics.edge, 24, HmMetrics.edge, 8),
      child: Text(
        text,
        style: HmType.screenTitle.copyWith(color: c.text, fontSize: 20),
      ),
    );
  }
}

/// Grey help text under a list.
class HmFootnote extends StatelessWidget {
  const HmFootnote(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 16, 32, 8),
      child: Text(text, style: HmType.caption.copyWith(color: c.text3)),
    );
  }
}

/// Asks before a change; resolves true only on [confirmLabel].
Future<bool> hmConfirm(
  BuildContext context, {
  required String title,
  String? body,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final c = NgColors.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: c.sheet,
      title: Text(title, style: HmType.row.copyWith(color: c.text)),
      content: body == null
          ? null
          : Text(body, style: HmType.value.copyWith(color: c.text2)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: TextButton.styleFrom(
            foregroundColor: destructive ? c.danger : c.accentText,
          ),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Small spinner for a row that is busy.
class HmRowSpinner extends StatelessWidget {
  const HmRowSpinner({super.key});

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return SizedBox.square(
      dimension: 22,
      child: CircularProgressIndicator(strokeWidth: 2.4, color: c.text2),
    );
  }
}

/// Text input styled for the sheets.
class HmField extends StatelessWidget {
  const HmField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.obscure = false,
  });
  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HmMetrics.edge,
        vertical: 6,
      ),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        autocorrect: false,
        style: HmType.row.copyWith(color: c.text),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: HmType.value.copyWith(color: c.text2),
          hintStyle: HmType.value.copyWith(color: c.text3),
          filled: true,
          fillColor: c.input,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: c.stroke),
          ),
        ),
      ),
    );
  }
}
