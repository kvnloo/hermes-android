// Terminal: a shell in this chat's working directory — over SSH with the
// instance's Terminal Connection, else the host's own terminal when it
// offers one, else the Connect a Terminal state that links to the settings.
import 'package:flutter/material.dart';

import '../../../nextgen/data/chat_controller.dart';
import '../../hm_bots.dart';
import 'ssh_config.dart';
import 'ssh_transport.dart';
import 'terminal_connection_page.dart';
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
  final connection = gateway.connection;
  final certificate = connection.clientCertificate;
  final host = HostTerminalBackend(
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
    liveCwd: () => chat.cwd,
  );
  final navigator = Navigator.of(context);
  final defaultHost = hmTerminalDefaultHost(
    connection.singleLoginUrl,
    connection.host,
  );
  final backend = HmHomeFallbackBackend(
    SshTerminalBackend(
      connectionId: connection.id,
      store: HmSshStore.instance,
      connector: const DartSsh2Connector(),
      trustPrompt: (host, type, fingerprint) => hmConfirmSshHost(
        navigator.context,
        host: host,
        type: type,
        fingerprint: fingerprint,
      ),
      cwdLookup: host.workingDirectory,
      fallback: host,
    ),
  );
  return navigator.push(
    MaterialPageRoute<void>(
      builder: (_) => HmTerminalPage(
        backend: backend,
        onOpenSettings: (ctx) => openHmTerminalConnection(
          ctx,
          connectionId: connection.id,
          defaultHost: defaultHost,
        ),
      ),
    ),
  );
}

/// Opens the shell in the home folder when the chat's folder is unknown,
/// as the official app does, instead of stopping at "Connect or refresh".
///
/// A stored chat often has no folder to give: nothing attached this app
/// session (no `session.info.cwd`), and the host's session row keeps no
/// `cwd` for chats it created without one (messaging sessions, a remote or
/// sandbox terminal backend). A failed lookup is not worth losing the shell
/// over either; the shell's own connect reports a real host problem.
class HmHomeFallbackBackend implements HmTerminalBackend {
  HmHomeFallbackBackend(this.inner);

  final HmTerminalBackend inner;

  /// The folder to open in; '' is the home folder.
  @override
  Future<String?> workingDirectory() async {
    try {
      return await inner.workingDirectory() ?? '';
    } catch (_) {
      return '';
    }
  }

  @override
  Future<HmTerminalSession> open({
    required String cwd,
    required int cols,
    required int rows,
  }) => inner.open(cwd: cwd, cols: cols, rows: rows);
}

/// The instance's host name, offered as the SSH host: the dashboard
/// address's host for single-login installs, else the saved host.
String hmTerminalDefaultHost(String? dashboardUrl, String host) {
  final fromUrl = Uri.tryParse(dashboardUrl ?? '')?.host ?? '';
  return fromUrl.isNotEmpty ? fromUrl : host;
}
