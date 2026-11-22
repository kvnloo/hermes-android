import 'dart:convert';

import '../../../core/models/session.dart';
import '../../../core/services/dashboard_api_client.dart';
import 'council_run.dart';

/// A dedicated council row in the bot's existing Hermes session tree.
bool isCouncilSession(Session session) => session.source == 'council';

/// Fetches the saved snapshot for this exact stored ID. The writer puts the
/// full Glide v1 JSON in the latest assistant message of the council session.
Future<CouncilRun?> loadCouncilSession(
  DashboardApiClient api,
  String sessionId,
) async {
  final messages = await api.getMessages(sessionId, limit: 1, latest: true);
  final message = messages.firstOrNull;
  if (message == null || message['role'] != 'assistant') return null;
  final content = message['content'];
  if (content is! String || content.length > 65536) {
    throw const FormatException('Invalid council snapshot content');
  }
  return parseCouncilRun(jsonDecode(content));
}
