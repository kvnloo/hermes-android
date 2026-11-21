// Terminal over SSH: the phone signs in to the instance's server with the
// Terminal Connection saved for it, opens a shell in a PTY sized to the
// xterm view and changes into the chat's working directory.
//
// The SSH client sits behind [HmSshConnector] so the screen and its tests
// never touch the network; [DartSsh2Connector] is the real one.
//
// Mosh is not offered: it needs mosh-server's UDP protocol (SSP with
// AES-OCB and its own state sync), which no Dart package provides, so the
// settings page shows it as not supported.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'ssh_config.dart';
import 'terminal_transport.dart';

/// Where an SSH sign-in goes.
class HmSshTarget {
  const HmSshTarget({
    required this.host,
    required this.port,
    required this.username,
    this.password,
    this.identities = const [],
  });

  final String host;
  final int port;
  final String username;
  final String? password;
  final List<SSHIdentity> identities;
}

/// Asked once per connection with the server's key type and `SHA256:…`
/// fingerprint; true accepts it.
typedef HmSshHostKeyCheck =
    Future<bool> Function(String type, String fingerprint);

enum HmSshErrorKind {
  unreachable,
  refused,
  timedOut,
  authRejected,
  hostKeyRejected,
  slowStart,
  noShell,
  closed,
}

/// A failed SSH step, by kind, so the backend can pick official wording.
class HmSshError implements Exception {
  const HmSshError(this.kind);
  final HmSshErrorKind kind;
  @override
  String toString() => 'HmSshError($kind)';
}

/// One open interactive shell.
abstract class HmSshShell {
  /// Shell output (stdout and stderr) as raw bytes.
  Stream<Uint8List> get output;

  /// Completes when the channel closes.
  Future<void> get done;

  /// Exit status, when the shell reported one.
  int? get exitCode;

  void write(Uint8List data);

  /// Sends an SSH `window-change` for the new size.
  void resize(int cols, int rows);

  Future<void> close();
}

/// Opens SSH shells.
abstract class HmSshConnector {
  /// Signs in and opens a shell with a PTY of [cols]×[rows]. Throws
  /// [HmSshError].
  Future<HmSshShell> open(
    HmSshTarget target, {
    required HmSshHostKeyCheck verifyHostKey,
    required int cols,
    required int rows,
  });
}

/// The real connector (dartssh2).
class DartSsh2Connector implements HmSshConnector {
  const DartSsh2Connector({
    this.connectTimeout = const Duration(seconds: 15),
    this.startTimeout = const Duration(seconds: 25),
  });

  final Duration connectTimeout;
  final Duration startTimeout;

  @override
  Future<HmSshShell> open(
    HmSshTarget target, {
    required HmSshHostKeyCheck verifyHostKey,
    required int cols,
    required int rows,
  }) async {
    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(
        target.host,
        target.port,
        timeout: connectTimeout,
      );
    } on TimeoutException {
      throw const HmSshError(HmSshErrorKind.timedOut);
    } on SocketException catch (e) {
      throw HmSshError(_socketKind(e));
    } catch (_) {
      throw const HmSshError(HmSshErrorKind.unreachable);
    }
    var hostKeyRefused = false;
    final password = target.password;
    final client = SSHClient(
      socket,
      username: target.username,
      identities: target.identities.isEmpty ? null : target.identities,
      onPasswordRequest: password == null ? null : () => password,
      // Many servers ask for the password through keyboard-interactive.
      onUserInfoRequest: password == null
          ? null
          : (request) => [for (final _ in request.prompts) password],
      onVerifyHostKey: (type, fingerprint) async {
        final ok = await verifyHostKey(
          type,
          utf8.decode(fingerprint, allowMalformed: true),
        );
        if (!ok) hostKeyRefused = true;
        return ok;
      },
      handshakeTimeout: connectTimeout,
    );
    try {
      await client.authenticated;
    } catch (e) {
      client.close();
      if (hostKeyRefused || e is SSHHostkeyError) {
        throw const HmSshError(HmSshErrorKind.hostKeyRejected);
      }
      if (e is SSHAuthFailError) {
        throw const HmSshError(HmSshErrorKind.authRejected);
      }
      if (e is SSHAuthAbortError && e.reason is SSHHostkeyError) {
        throw const HmSshError(HmSshErrorKind.hostKeyRejected);
      }
      if (e is SSHAuthAbortError && e.message.contains('timed out')) {
        throw const HmSshError(HmSshErrorKind.timedOut);
      }
      throw const HmSshError(HmSshErrorKind.closed);
    }
    final SSHSession session;
    try {
      session = await client
          .shell(
            pty: SSHPtyConfig(width: cols, height: rows),
          )
          .timeout(startTimeout);
    } on TimeoutException {
      client.close();
      throw const HmSshError(HmSshErrorKind.slowStart);
    } on SSHChannelRequestError {
      client.close();
      throw const HmSshError(HmSshErrorKind.noShell);
    } on SSHChannelOpenError {
      client.close();
      throw const HmSshError(HmSshErrorKind.noShell);
    } catch (_) {
      client.close();
      throw const HmSshError(HmSshErrorKind.closed);
    }
    return _DartSsh2Shell(client, session);
  }

  static HmSshErrorKind _socketKind(SocketException e) {
    final code = e.osError?.errorCode;
    final text = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
    // ECONNREFUSED: 111 on Linux/Android, 61 on Darwin.
    if (code == 111 || code == 61 || text.contains('refused')) {
      return HmSshErrorKind.refused;
    }
    if (code == 110 || code == 60 || text.contains('timed out')) {
      return HmSshErrorKind.timedOut;
    }
    return HmSshErrorKind.unreachable;
  }
}

class _DartSsh2Shell implements HmSshShell {
  _DartSsh2Shell(this._client, this._session) {
    var open = 2;
    void closeOne() {
      if (--open == 0) unawaited(_out.close());
    }

    void add(Uint8List data) {
      if (!_out.isClosed) _out.add(data);
    }

    _session.stdout.listen(add, onDone: closeOne, onError: (_) {});
    _session.stderr.listen(add, onDone: closeOne, onError: (_) {});
    unawaited(
      Future.any([_session.done, _client.done])
          .whenComplete(() {
            if (!_done.isCompleted) _done.complete();
          })
          .catchError((_) {}),
    );
  }

  final SSHClient _client;
  final SSHSession _session;
  final _out = StreamController<Uint8List>();
  final _done = Completer<void>();

  @override
  Stream<Uint8List> get output => _out.stream;

  @override
  Future<void> get done => _done.future;

  @override
  int? get exitCode => _session.exitCode;

  @override
  void write(Uint8List data) {
    if (!_done.isCompleted) _session.write(data);
  }

  @override
  void resize(int cols, int rows) {
    if (!_done.isCompleted && cols > 0 && rows > 0) {
      _session.resizeTerminal(cols, rows);
    }
  }

  @override
  Future<void> close() async {
    _session.close();
    _client.close();
    if (!_done.isCompleted) _done.complete();
  }
}

/// Shows the trust prompt for a first-seen server; true trusts it.
typedef HmSshTrustPrompt =
    Future<bool> Function(String host, String type, String fingerprint);

/// The command that moves a fresh shell into [cwd]. Single-quoted for
/// POSIX shells; a folder that isn't there leaves the shell in home, as the
/// official app does.
String hmSshCdCommand(String cwd) {
  final quoted = "'${cwd.replaceAll("'", r"'\''")}'";
  return 'cd $quoted && clear\r';
}

/// Terminal over SSH with the instance's saved Terminal Connection. With
/// none saved, [fallback] (the host's own terminal) is tried; without one
/// either, the screen shows Connect a Terminal.
class SshTerminalBackend implements HmTerminalBackend {
  SshTerminalBackend({
    required this.connectionId,
    required this.store,
    required this.connector,
    required this.trustPrompt,
    required this.cwdLookup,
    this.fallback,
  });

  final String connectionId;
  final HmSshStore store;
  final HmSshConnector connector;
  final HmSshTrustPrompt trustPrompt;
  final Future<String?> Function() cwdLookup;
  final HmTerminalBackend? fallback;

  @override
  Future<String?> workingDirectory() => cwdLookup();

  @override
  Future<HmTerminalSession> open({
    required String cwd,
    required int cols,
    required int rows,
  }) async {
    HmSshConfig? config;
    try {
      config = await store.load(connectionId);
    } on HmSshStoreError catch (e) {
      throw HmTerminalFailure(e.message);
    }
    if (config == null) {
      final other = fallback;
      if (other == null) throw const HmTerminalUnavailable();
      return other.open(cwd: cwd, cols: cols, rows: rows);
    }
    var identities = const <SSHIdentity>[];
    if (config.usesKey) {
      try {
        identities = hmSshParseKey(
          config.privateKey!,
          passphrase: config.passphrase,
        );
      } on HmSshKeyError catch (e) {
        throw HmTerminalFailure(e.message);
      }
    }
    var changed = false;
    var declined = false;
    final saved = config;
    Future<bool> verify(String type, String fingerprint) async {
      final known = saved.hostKeyFingerprint;
      if (known != null) {
        final same =
            known == fingerprint && (saved.hostKeyType ?? type) == type;
        if (!same) changed = true;
        return same;
      }
      final ok = await trustPrompt(saved.host, type, fingerprint);
      if (!ok) {
        declined = true;
        return false;
      }
      await store.save(connectionId, saved.trusting(type, fingerprint));
      return true;
    }

    final HmSshShell shell;
    try {
      shell = await connector.open(
        HmSshTarget(
          host: config.host,
          port: config.port,
          username: config.username,
          password: config.usesKey ? null : config.password,
          identities: identities,
        ),
        verifyHostKey: verify,
        cols: cols,
        rows: rows,
      );
    } on HmSshError catch (e) {
      throw HmTerminalFailure(
        changed
            ? HmSshText.hostKeyChanged
            : declined
            ? HmSshText.trustBody
            : _message(e.kind, usesKey: saved.usesKey),
      );
    } on HmSshStoreError catch (e) {
      throw HmTerminalFailure(e.message);
    }
    final session = _SshTerminalSession(shell, cwd);
    shell.write(Uint8List.fromList(utf8.encode(hmSshCdCommand(cwd))));
    return session;
  }

  static String _message(HmSshErrorKind kind, {required bool usesKey}) =>
      switch (kind) {
        HmSshErrorKind.unreachable => HmSshText.unreachable,
        HmSshErrorKind.refused => HmSshText.refused,
        HmSshErrorKind.timedOut => HmSshText.timedOut,
        HmSshErrorKind.authRejected =>
          usesKey ? HmSshText.keyRejected : HmSshText.passwordRejected,
        HmSshErrorKind.hostKeyRejected => HmSshText.hostKeyChanged,
        HmSshErrorKind.slowStart => HmSshText.slowStart,
        HmSshErrorKind.noShell => HmSshText.noShell,
        HmSshErrorKind.closed => HmSshText.serverClosed,
      };
}

class _SshTerminalSession implements HmTerminalSession {
  _SshTerminalSession(this._shell, String cwd)
    : meta = HmTerminalMeta(cwd: cwd) {
    _sub = _shell.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          (text) {
            if (!_out.isClosed) _out.add(text);
          },
          onDone: _finish,
          onError: (_) => _finish(),
        );
    unawaited(_shell.done.whenComplete(_finish).catchError((_) {}));
  }

  final HmSshShell _shell;
  late final StreamSubscription<String> _sub;
  final _out = StreamController<String>();
  final _done = Completer<HmTerminalEnd>();

  @override
  final HmTerminalMeta meta;

  @override
  Stream<String> get output => _out.stream;

  @override
  Future<HmTerminalEnd> get done => _done.future;

  void _finish() {
    if (_done.isCompleted) return;
    _done.complete(
      HmTerminalEnd(
        code: _shell.exitCode,
        closedByHost: _shell.exitCode != null,
      ),
    );
    unawaited(_out.close());
  }

  @override
  void write(String data) {
    if (!_done.isCompleted && data.isNotEmpty) {
      _shell.write(Uint8List.fromList(utf8.encode(data)));
    }
  }

  @override
  void resize(int cols, int rows) {
    if (!_done.isCompleted) _shell.resize(cols, rows);
  }

  @override
  Future<void> close() async {
    await _shell.close();
    await _sub.cancel();
    _finish();
  }
}
