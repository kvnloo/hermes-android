// Shared pieces of the Work screens (Projects, Kanban, Execution): the
// transports they call through, and the centred empty / error states.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../core/services/dashboard_api_client.dart';
import '../../../core/services/turbo_motion.dart';
import '../../../nextgen/theme/nextgen_theme.dart';
import '../../hm_ui.dart';

/// One dashboard REST request (`/api/<endpoint>`). The real one is
/// `DashboardClient.apiRequest`; tests pass a fake that records calls.
typedef HmDashRequest =
    Future<http.Response> Function(
      String method,
      String endpoint, {
      Object? body,
      Map<String, String>? query,
    });

/// One `/api/ws` JSON-RPC call returning its `result`.
typedef HmRpc =
    Future<Map<String, dynamic>> Function(
      String method,
      Map<String, dynamic> params,
    );

/// Sends [method] [endpoint] and decodes a JSON object, throwing
/// [DashboardRequestException] on any non-2xx status.
Future<Map<String, dynamic>> hmDashJson(
  HmDashRequest request,
  String method,
  String endpoint, {
  Object? body,
  Map<String, String>? query,
}) async {
  final res = await request(method, endpoint, body: body, query: query);
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw DashboardRequestException(res.statusCode, dashboardErrorMessage(res));
  }
  if (res.body.trim().isEmpty) return const {};
  final decoded = jsonDecode(res.body);
  return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
}

/// The readable reason behind a failure, without exception class names.
String hmWorkError(Object e) {
  final s = e.toString().trim();
  for (final prefix in ['Exception: ', 'Bad state: ', 'StateError: ']) {
    if (s.startsWith(prefix)) return s.substring(prefix.length);
  }
  return s;
}

/// Shows [text] in a snackbar, replacing any one already up.
void hmWorkSnack(BuildContext context, String text) {
  final m = ScaffoldMessenger.maybeOf(context);
  m?.hideCurrentSnackBar();
  m?.showSnackBar(SnackBar(content: Text(text)));
}

/// Centred icon, title, body and an optional pill action (No projects yet,
/// A Clear Board, No Execution Activity…).
class HmWorkEmpty extends StatelessWidget {
  const HmWorkEmpty({
    super.key,
    required this.icon,
    this.title,
    required this.body,
    this.action,
    this.actionIcon = Icons.add,
    this.onAction,
  });

  final IconData icon;
  final String? title;
  final String body;
  final String? action;
  final IconData actionIcon;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: c.text3),
          const SizedBox(height: 16),
          if (title != null) ...[
            Text(
              title!,
              textAlign: TextAlign.center,
              style: HmType.row.copyWith(
                color: c.text,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
          ],
          Text(
            body,
            textAlign: TextAlign.center,
            style: HmType.value.copyWith(color: c.text3, fontSize: 16),
          ),
          if (action != null && onAction != null) ...[
            const SizedBox(height: 22),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: c.accentSoft,
                foregroundColor: c.accentText,
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
              ),
              onPressed: onAction,
              icon: Icon(actionIcon),
              label: Text(action!, style: HmType.pill.copyWith(fontSize: 17)),
            ),
          ],
        ],
      ),
    );
  }
}

/// A centred spinner for a screen's first load.
class HmWorkLoading extends StatelessWidget {
  const HmWorkLoading({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(48),
    child: Center(
      child: CircularProgressIndicator(color: NgColors.of(context).accent),
    ),
  );
}

/// A small spinner shown in place of a row's action while it runs.
class HmWorkBusy extends StatelessWidget {
  const HmWorkBusy({super.key});

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 20,
    child: CircularProgressIndicator(
      strokeWidth: 2.2,
      color: NgColors.of(context).accent,
    ),
  );
}

/// A rounded bottom sheet in the hm style.
Future<T?> showHmWorkSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  final c = NgColors.of(context);
  return showModalBottomSheet<T>(
    context: context,
    sheetAnimationStyle: TurboMotion.sheetStyle(context),
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: c.sheet,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (sheet) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(sheet).viewInsets.bottom),
      child: builder(sheet),
    ),
  );
}

/// A confirm dialog; resolves true when [confirm] is tapped.
Future<bool> hmWorkConfirm(
  BuildContext context, {
  required String title,
  String? body,
  required String confirm,
  bool danger = false,
}) async {
  final c = NgColors.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      backgroundColor: c.sheet,
      title: Text(title),
      content: body == null ? null : Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d, false),
          child: Text(MaterialLocalizations.of(d).cancelButtonLabel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(d, true),
          style: TextButton.styleFrom(
            foregroundColor: danger ? c.danger : c.accent,
          ),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return ok == true;
}

/// A text field styled like the hm search/input wells.
class HmWorkField extends StatelessWidget {
  const HmWorkField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.error,
    this.maxLines = 1,
    this.autofocus = false,
    this.fieldKey,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? error;
  final int maxLines;
  final bool autofocus;
  final Key? fieldKey;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        key: fieldKey,
        controller: controller,
        autofocus: autofocus,
        minLines: 1,
        maxLines: maxLines,
        style: HmType.value.copyWith(color: c.text, fontSize: 16),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          errorText: error,
          filled: true,
          fillColor: c.input,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}
