// Terminal transport: a shell on the Hermes host, opened in the chat's
// working directory.
//
// Hermes serves interactive host shells on `/api/host-terminal`
// (hermes_cli/web_routers/webapp.py `host_terminal_ws`). Each dial needs a
// one-use ticket from `POST /api/webapp/socket-ticket?socket=host-terminal`;
// a host whose surface does not offer host shells answers that mint 404, which
// is the "no terminal connection" state. Frames (web_host_terminal_sessions.py):
// the first text frame is `\0HERMES_TERMINAL_META:{json}`; then shell output as
// binary or text; client keystrokes go up as text and a resize as
// `\x1b[RESIZE:<cols>;<rows>]` (web_server_chat.py `_RESIZE_RE`).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/models/client_certificate.dart';
import '../../../core/services/dashboard_api_client.dart';
import '../../../core/services/hermes_sign_in.dart';
import '../../../core/services/tls_client_factory.dart';

/// Prefix of the host's metadata frames (web_host_terminal.py `META_PREFIX`).
const hmTerminalMetaPrefix = '\u0000HERMES_TERMINAL_META:';

/// Close code the host uses when the shell exits or the terminal expired
/// (pty_session.py `WS_CLOSE_PROCESS_EXITED`).
const hmTerminalClosedCode = 4410;

/// The host offers no terminal for this connection.
class HmTerminalUnavailable implements Exception {
  const HmTerminalUnavailable();
}

/// Opening the terminal failed; [message] is safe to show.
class HmTerminalFailure implements Exception {
  const HmTerminalFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What the host reports about an opened terminal.
class HmTerminalMeta {
  const HmTerminalMeta({this.shell, this.cwd, this.terminalId});

  final String? shell;
  final String? cwd;
  final String? terminalId;

  /// Parses one meta frame; null when it isn't one.
  static Map<String, dynamic>? frame(String text) {
    if (!text.startsWith(hmTerminalMetaPrefix)) return null;
    try {
      final decoded = jsonDecode(text.substring(hmTerminalMetaPrefix.length));
      return decoded is Map<String, dynamic> ? decoded : const {};
    } on FormatException {
      return const {};
    }
  }

  factory HmTerminalMeta.fromJson(Map<String, dynamic> json) {
    String? s(String k) {
      final v = json[k];
      return v is String && v.trim().isNotEmpty ? v : null;
    }

    return HmTerminalMeta(
      shell: s('shell'),
      cwd: s('cwd'),
      terminalId: s('terminalId'),
    );
  }
}

/// How a terminal session ended.
class HmTerminalEnd {
  const HmTerminalEnd({this.code, this.reason, this.closedByHost = false});

  final int? code;
  final String? reason;

  /// The shell exited or the host closed the terminal on purpose.
  final bool closedByHost;

  bool get shellClosed => closedByHost || code == hmTerminalClosedCode;
}

/// One live terminal.
abstract class HmTerminalSession {
  HmTerminalMeta get meta;

  /// Shell output, already decoded.
  Stream<String> get output;

  /// Completes once when the session ends for any reason.
  Future<HmTerminalEnd> get done;

  void write(String data);
  void resize(int cols, int rows);
  Future<void> close();
}

/// Where a chat's terminal comes from.
abstract class HmTerminalBackend {
  /// The chat's working directory, or null when it isn't known yet.
  Future<String?> workingDirectory();

  /// Opens a shell in [cwd]. Throws [HmTerminalUnavailable] or
  /// [HmTerminalFailure].
  Future<HmTerminalSession> open({
    required String cwd,
    required int cols,
    required int rows,
  });
}

typedef HmApiRequest =
    Future<http.Response> Function(
      String method,
      String endpoint, {
      Map<String, String>? queryParameters,
    });

typedef HmSocketConnect = WebSocketChannel Function(Uri uri);

/// Dials a host-terminal socket with the connection's sign-in headers and
/// client certificate, like the chat socket (ws_client.dart).
WebSocketChannel hmHostTerminalSocket(
  Uri uri, {
  ClientCertificateConfig? clientCertificate,
}) {
  final headers = HermesSignInVault.instance.accessHeadersFor(uri);
  return IOWebSocketChannel.connect(
    uri,
    headers: headers.isEmpty ? null : headers,
    customClient: clientCertificate == null
        ? null
        : const TlsClientFactory().createHttpClient(clientCertificate),
  );
}

/// The Hermes host's own terminal over the dashboard connection.
class HostTerminalBackend implements HmTerminalBackend {
  HostTerminalBackend({
    required this.baseUrl,
    required this.request,
    required this.connect,
    this.profile,
    this.storedSessionId,
    this.requestedCwd,
    this.openTimeout = const Duration(seconds: 20),
  });

  final String baseUrl;
  final HmApiRequest request;
  final HmSocketConnect connect;
  final String? profile;
  final String? storedSessionId;
  final String? requestedCwd;
  final Duration openTimeout;

  /// Host terminal ids by chat, so reopening Terminal reattaches to the
  /// shell the host keeps for a while instead of starting another one.
  static final Map<String, String> _attached = {};

  @visibleForTesting
  static void forgetAttachments() => _attached.clear();

  Map<String, String> get _profileQuery => {'profile': ?profile};

  @override
  Future<String?> workingDirectory() async {
    final requested = requestedCwd?.trim();
    if (requested != null && requested.isNotEmpty) return requested;
    final id = storedSessionId?.trim();
    if (id == null || id.isEmpty) return null;
    final res = await request(
      'GET',
      'sessions/${Uri.encodeComponent(id)}',
      queryParameters: _profileQuery,
    );
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw HmTerminalFailure(dashboardErrorMessage(res));
    }
    final body = jsonDecode(res.body);
    final row = body is Map && body['session'] is Map ? body['session'] : body;
    final cwd = row is Map ? row['cwd'] : null;
    return cwd is String && cwd.trim().isNotEmpty ? cwd.trim() : null;
  }

  Future<String> _mintTicket() async {
    final res = await request(
      'POST',
      'webapp/socket-ticket',
      queryParameters: {'socket': 'host-terminal'},
    );
    // 404: this surface mints no host-terminal tickets; 400: an older host
    // that doesn't know the socket.
    if (res.statusCode == 404 || res.statusCode == 400) {
      throw const HmTerminalUnavailable();
    }
    if (res.statusCode != 200) {
      throw HmTerminalFailure(dashboardErrorMessage(res));
    }
    final body = jsonDecode(res.body);
    final ticket = body is Map ? body['ticket'] : null;
    if (ticket is! String || ticket.trim().isEmpty) {
      throw const HmTerminalFailure('Hermes did not return a terminal ticket.');
    }
    return ticket.trim();
  }

  Uri socketUri({
    required String ticket,
    required String cwd,
    required int cols,
    required int rows,
    String? attach,
  }) {
    final base = baseUrl
        .replaceFirst(RegExp('^http://'), 'ws://')
        .replaceFirst(RegExp('^https://'), 'wss://');
    return Uri.parse('$base/api/host-terminal').replace(
      queryParameters: {
        'ticket': ticket,
        'cwd': cwd,
        'cols': '$cols',
        'rows': '$rows',
        'attach': ?attach,
        ..._profileQuery,
      },
    );
  }

  @override
  Future<HmTerminalSession> open({
    required String cwd,
    required int cols,
    required int rows,
  }) async {
    final key = '${profile ?? ''}\u0000${storedSessionId ?? cwd}';
    final attach = _attached[key];
    try {
      final session = await _dial(cwd, cols, rows, attach);
      final id = session.meta.terminalId;
      if (id != null) _attached[key] = id;
      return session;
    } on _Expired {
      _attached.remove(key);
      if (attach == null) {
        throw const HmTerminalFailure('Terminal has been closed');
      }
      // The kept shell is gone; start a fresh one.
      final session = await _dial(cwd, cols, rows, null);
      final id = session.meta.terminalId;
      if (id != null) _attached[key] = id;
      return session;
    }
  }

  Future<_HostTerminalSession> _dial(
    String cwd,
    int cols,
    int rows,
    String? attach,
  ) async {
    final ticket = await _mintTicket();
    final channel = connect(
      socketUri(
        ticket: ticket,
        cwd: cwd,
        cols: cols,
        rows: rows,
        attach: attach,
      ),
    );
    try {
      await channel.ready.timeout(openTimeout);
    } catch (_) {
      unawaited(channel.sink.close().catchError((_) {}));
      throw const HmTerminalFailure('Connection failed');
    }
    final session = _HostTerminalSession(channel);
    final opened = await Future.any<Object>([
      session._ready.future,
      session.done,
    ]).timeout(openTimeout, onTimeout: () => const _Timeout());
    if (opened is HmTerminalMeta) return session;
    if (opened is _Timeout) {
      await session.close();
      throw const HmTerminalFailure('Connection timed out.');
    }
    final end = opened as HmTerminalEnd;
    if (end.code == 4403 || end.code == 4404) {
      throw const HmTerminalUnavailable();
    }
    if (end.code == hmTerminalClosedCode) throw const _Expired();
    final said = _plain(session._early.toString());
    throw HmTerminalFailure(
      (end.reason?.trim().isNotEmpty ?? false)
          ? end.reason!.trim()
          : said.isNotEmpty
          ? said
          : 'Connection closed.',
    );
  }

  static String _plain(String ansi) => ansi
      .replaceAll(RegExp(r'\x1b\[[0-9;?]*[A-Za-z]'), '')
      .replaceAll(RegExp(r'[\r\n]+'), ' ')
      .trim();
}

class _Expired implements Exception {
  const _Expired();
}

class _Timeout {
  const _Timeout();
}

class _Emit implements Sink<String> {
  _Emit(this._add);
  final void Function(String) _add;
  @override
  void add(String data) => _add(data);
  @override
  void close() {}
}

class _HostTerminalSession implements HmTerminalSession {
  _HostTerminalSession(this._channel) {
    _bytes = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(_Emit(_emit));
    _sub = _channel.stream.listen(
      _onFrame,
      onError: (_) => _finish(),
      onDone: _finish,
    );
  }

  final WebSocketChannel _channel;
  late final StreamSubscription<dynamic> _sub;
  late final ByteConversionSink _bytes;
  final _out = StreamController<String>();
  final _done = Completer<HmTerminalEnd>();
  final _ready = Completer<HmTerminalMeta>();

  /// Text the host sent before its meta frame (a start-up failure notice).
  final _early = StringBuffer();
  bool _closedByHost = false;
  HmTerminalMeta _meta = const HmTerminalMeta();

  @override
  HmTerminalMeta get meta => _meta;

  @override
  Stream<String> get output => _out.stream;

  @override
  Future<HmTerminalEnd> get done => _done.future;

  void _emit(String text) {
    if (text.isEmpty || _out.isClosed) return;
    if (!_ready.isCompleted) _early.write(text);
    _out.add(text);
  }

  void _onFrame(dynamic message) {
    if (message is String) {
      final meta = HmTerminalMeta.frame(message);
      if (meta == null) {
        _emit(message);
      } else if (meta['closed'] == true) {
        _closedByHost = true;
      } else {
        _meta = HmTerminalMeta.fromJson(meta);
        if (!_ready.isCompleted) _ready.complete(_meta);
      }
    } else if (message is List<int>) {
      _bytes.add(message);
    }
  }

  void _finish() {
    if (_done.isCompleted) return;
    _done.complete(
      HmTerminalEnd(
        code: _channel.closeCode,
        reason: _channel.closeReason,
        closedByHost: _closedByHost,
      ),
    );
    unawaited(_out.close());
  }

  bool get _open => !_done.isCompleted;

  @override
  void write(String data) {
    if (_open && data.isNotEmpty) _channel.sink.add(data);
  }

  @override
  void resize(int cols, int rows) {
    if (_open && cols > 0 && rows > 0) {
      _channel.sink.add('\x1b[RESIZE:$cols;$rows]');
    }
  }

  @override
  Future<void> close() async {
    await _channel.sink.close(1000).catchError((_) {});
    await _sub.cancel();
    _finish();
  }
}
