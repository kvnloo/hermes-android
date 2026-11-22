// Fakes for the SSH terminal tests: an in-memory encrypted store and an SSH
// connector that never touches the network.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show CredentialStore;
import 'package:hermes_android/hm/features/terminal/ssh_config.dart';
import 'package:hermes_android/hm/features/terminal/ssh_transport.dart';

class MemCredentialStore implements CredentialStore {
  final values = <String, String>{};
  bool failRead = false;
  bool failWrite = false;

  @override
  String? readCached(String key) => values[key];

  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('keystore');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('keystore');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failWrite) throw StateError('keystore');
    values.remove(key);
  }

  Map<String, dynamic>? saved(String connectionId) {
    final raw = values[HmSshStore.keyFor(connectionId)];
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }
}

class FakeShell implements HmSshShell {
  final out = StreamController<Uint8List>();
  final ended = Completer<void>();
  final writes = <String>[];
  final resizes = <(int, int)>[];
  bool closed = false;
  @override
  int? exitCode;

  void emit(String text) => out.add(Uint8List.fromList(utf8.encode(text)));

  @override
  Stream<Uint8List> get output => out.stream;
  @override
  Future<void> get done => ended.future;
  @override
  void write(Uint8List data) => writes.add(utf8.decode(data));
  @override
  void resize(int cols, int rows) => resizes.add((cols, rows));
  @override
  Future<void> close() async {
    closed = true;
    if (!ended.isCompleted) ended.complete();
  }
}

/// One scripted connection attempt.
class FakeDial {
  FakeDial.shell(
    this.shell, {
    this.hostKeyType = 'ssh-ed25519',
    this.fingerprint = 'SHA256:serverkeyA',
  }) : error = null;
  FakeDial.fail(
    this.error, {
    this.hostKeyType = 'ssh-ed25519',
    this.fingerprint = 'SHA256:serverkeyA',
  }) : shell = null;

  final FakeShell? shell;
  final HmSshErrorKind? error;
  final String hostKeyType;
  final String fingerprint;
}

class FakeConnector implements HmSshConnector {
  FakeConnector(this.dials, {this.handshakeBudget});

  final List<FakeDial> dials;

  /// Like dartssh2's handshake timeout: a host-key check that takes longer
  /// than this drops the connection, as a real server's does.
  final Duration? handshakeBudget;
  final targets = <HmSshTarget>[];
  final sizes = <(int, int)>[];

  @override
  Future<HmSshShell> open(
    HmSshTarget target, {
    required HmSshHostKeyCheck verifyHostKey,
    required int cols,
    required int rows,
  }) async {
    targets.add(target);
    sizes.add((cols, rows));
    final dial = dials.removeAt(0);
    // Like the real client: the host key is checked before sign-in.
    final check = verifyHostKey(dial.hostKeyType, dial.fingerprint);
    final budget = handshakeBudget;
    final trusted = budget == null
        ? await check
        : await check.timeout(
            budget,
            onTimeout: () => throw const HmSshError(HmSshErrorKind.closed),
          );
    if (!trusted) throw const HmSshError(HmSshErrorKind.hostKeyRejected);
    if (dial.error != null) throw HmSshError(dial.error!);
    return dial.shell!;
  }
}

/// A throwaway OpenSSH ed25519 key, made here so no key is checked in.
String testOpenSshKey({String? passphrase}) {
  final seed = Uint8List.fromList(List.generate(32, (i) => i + 1));
  final pub = Uint8List.fromList(List.generate(32, (i) => 200 - i));
  final pair = OpenSSHEd25519KeyPair(
    pub,
    Uint8List.fromList([...seed, ...pub]),
    'test',
  );
  return pair.toPem(passphrase: passphrase, rounds: 2);
}
