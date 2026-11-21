// Terminal: a shell on the host, in this chat's working directory.
import 'package:flutter/material.dart';

import '../../../nextgen/data/chat_controller.dart';
import '../../hm_bots.dart';
import 'terminal_page.dart';
import 'terminal_transport.dart';

Future<void> openHmTerminal(
  BuildContext context, {
  required HmBot bot,
  required HmBotsModel bots,
  required NgChatController chat,
}) {
  final gateway = bots.gateway;
  final dashboard = gateway.dashboard;
  final certificate = gateway.connection.clientCertificate;
  final backend = HostTerminalBackend(
    baseUrl: dashboard.baseUrl,
    request: (method, endpoint, {queryParameters}) => dashboard.apiRequest(
      method,
      endpoint,
      queryParameters: queryParameters,
    ),
    connect: (uri) => hmHostTerminalSocket(uri, clientCertificate: certificate),
    profile: bot.scope,
    storedSessionId: chat.storedId,
    requestedCwd: chat.workingDirectory,
  );
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => HmTerminalPage(backend: backend)),
  );
}
