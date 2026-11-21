// Terminal Connection: the SSH details one instance's Terminal signs in
// with, kept per install in the device's encrypted store (the same
// Keystore-backed store the connection credentials use), never in
// SharedPreferences. The trusted host key lives with them, so removing the
// connection also forgets the server's fingerprint.
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../../../core/services/connection_manager.dart'
    show CredentialStore, FlutterSecureCredentialStore;

/// Official strings (out/ui-text.txt) for the SSH side of Terminal.
abstract final class HmSshText {
  static const terminal = 'Terminal';
  static const terminalNote =
      'Open a terminal in each chat’s working folder. Your dashboard connection stays as configured.';
  static const title = 'Terminal Connection';
  static const addSshOrMosh = 'Add SSH or Mosh';
  static const protocol = 'Terminal Protocol';
  static const ssh = 'SSH';
  static const mosh = 'Mosh';
  static const moshNote =
      'Mosh keeps your terminal session through network changes and brief interruptions. Install mosh-server on your server and allow its UDP ports through the firewall. Sign-in uses your SSH credentials.';
  static const notSupported = 'Not supported';
  static const host = 'SSH host';
  static const port = 'SSH port';
  static const username = 'SSH username';
  static const authentication = 'SSH authentication';
  static const password = 'SSH password';
  static const privateKey = 'Private Key';
  static const privateKeyField = 'Private key';
  static const keyPassphrase = 'Key passphrase';
  static const addKeyHint =
      'Add a private key: paste it or import the key file.';
  static const importKeyFile = 'Import Key File';
  static const keyPasted = 'Private key pasted';
  static const keyImported = 'Private key imported';
  static const keySaved = 'Saved private key';
  static const replaceKey = 'Replace Key';
  static const clearKey = 'Clear Key';
  static const encryptedKeyNote =
      'This key is encrypted. Its passphrase is kept encrypted on this device with it.';
  static const storageNote =
      'Credentials are stored encrypted on this device. You’ll verify the server’s fingerprint on the first connection.';
  static const save = 'Save Changes';
  static const remove = 'Remove Terminal Connection';
  static const loading = 'Loading SSH connection…';

  // Validation.
  static const needHostUserPort =
      'Enter an SSH host, username and valid ports.';
  static const needSecret = 'Choose an SSH password or private key.';
  static const passphraseNeedsKey = 'A key passphrase requires a private key.';
  static const readFailed =
      'The terminal settings could not be read. Try again.';
  static const saveFailed =
      'The terminal settings could not be saved. Try again.';

  // Key problems.
  static const keyTooBig = 'The SSH private key must be at most 64 KB.';
  static const keyPutty =
      'This PuTTY key (.ppk) could not be opened. In PuTTYgen, choose Conversions › Export OpenSSH key and use that file.';
  static const keySshCom =
      'SSH.COM (SSH2) keys can’t be used. Use an Ed25519, ECDSA or RSA key.';
  static const keyDsa =
      'DSA and Ed448 keys can’t be used. Use an Ed25519, ECDSA or RSA key.';
  static const keyPublic =
      'This is a public key. Use the private key instead — the file without “.pub”, starting with “-----BEGIN”.';
  static const keyUnreadable =
      'This isn’t a private key Hermes Agent can read. Paste the whole key, including its “-----BEGIN … PRIVATE KEY-----” and “-----END … PRIVATE KEY-----” lines.';
  static const keyFileUnreadable =
      'This file isn’t a private key Hermes Agent can read. Import the key file itself, not a document containing it.';
  static const keyDamaged =
      'The private key is incomplete or damaged. Paste or import the whole key again, including its BEGIN and END lines.';
  static const keyNeedsPassphrase =
      'This private key is encrypted. Enter its passphrase.';
  static const keyWrongPassphrase =
      'The passphrase doesn’t unlock this private key.';

  // Host key (trust on first use).
  static const trustTitle = 'Trust this SSH server?';
  static const trustBody =
      "Verify this server's SSH identity before connecting.";
  static const trustAction = 'Trust and Connect';
  static const hostKeyChanged =
      "This server's SSH identity has changed. Check its host key before connecting again.";

  // Connecting.
  static const passwordRejected =
      'The SSH server didn’t accept this username and password.';

  /// No official line for a refused key exists in the strings; this follows
  /// the password line's wording.
  static const keyRejected = 'The SSH server didn’t accept this private key.';
  static const unreachable = 'Could not reach the server.';
  static const refused = 'The server refused the connection.';
  static const timedOut =
      'Connection timed out. Check the address and try again.';
  static const slowStart =
      'The SSH terminal took too long to start. Check the connection and try again.';
  static const serverClosed = 'The SSH server closed the connection.';
  static const noShell =
      'The server could not start an interactive terminal in the chat’s folder.';
  static const sessionClosed =
      'The SSH connection closed. Reconnect to open a new terminal.';
}

/// One instance's Terminal Connection.
class HmSshConfig {
  const HmSshConfig({
    required this.host,
    this.port = 22,
    required this.username,
    this.password,
    this.privateKey,
    this.passphrase,
    this.hostKeyType,
    this.hostKeyFingerprint,
  });

  final String host;
  final int port;
  final String username;
  final String? password;

  /// OpenSSH / PEM private key text.
  final String? privateKey;
  final String? passphrase;

  /// The server key trusted on first connection (`SHA256:…`).
  final String? hostKeyType;
  final String? hostKeyFingerprint;

  bool get usesKey => privateKey != null && privateKey!.trim().isNotEmpty;

  HmSshConfig trusting(String type, String fingerprint) => HmSshConfig(
    host: host,
    port: port,
    username: username,
    password: password,
    privateKey: privateKey,
    passphrase: passphrase,
    hostKeyType: type,
    hostKeyFingerprint: fingerprint,
  );

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'username': username,
    'password': ?password,
    'privateKey': ?privateKey,
    'passphrase': ?passphrase,
    'hostKeyType': ?hostKeyType,
    'hostKeyFingerprint': ?hostKeyFingerprint,
  };

  /// Null when [json] isn't a usable connection.
  static HmSshConfig? fromJson(Object? json) {
    if (json is! Map) return null;
    String? s(String k) {
      final v = json[k];
      return v is String && v.isNotEmpty ? v : null;
    }

    final host = s('host');
    final user = s('username');
    final port = json['port'];
    if (host == null || user == null || port is! int) return null;
    return HmSshConfig(
      host: host,
      port: port,
      username: user,
      password: s('password'),
      privateKey: s('privateKey'),
      passphrase: s('passphrase'),
      hostKeyType: s('hostKeyType'),
      hostKeyFingerprint: s('hostKeyFingerprint'),
    );
  }
}

/// The settings could not be read or written; [message] is official text.
class HmSshStoreError implements Exception {
  const HmSshStoreError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Reads and writes Terminal Connections in the encrypted credential store.
class HmSshStore {
  HmSshStore({CredentialStore? store})
    : _store = store ?? FlutterSecureCredentialStore();

  /// Shared production store.
  static final HmSshStore instance = HmSshStore();

  final CredentialStore _store;

  static String keyFor(String connectionId) =>
      'hm_terminal_ssh.v1.$connectionId';

  Future<HmSshConfig?> load(String connectionId) async {
    final String? raw;
    try {
      raw = await _store.read(keyFor(connectionId));
    } catch (_) {
      throw const HmSshStoreError(HmSshText.readFailed);
    }
    if (raw == null || raw.isEmpty) return null;
    try {
      return HmSshConfig.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  Future<void> save(String connectionId, HmSshConfig config) async {
    try {
      await _store.write(keyFor(connectionId), jsonEncode(config.toJson()));
    } catch (_) {
      throw const HmSshStoreError(HmSshText.saveFailed);
    }
  }

  Future<void> remove(String connectionId) async {
    try {
      await _store.delete(keyFor(connectionId));
    } catch (_) {
      throw const HmSshStoreError(HmSshText.saveFailed);
    }
  }
}

/// A private key that can't be used; [message] is official text.
class HmSshKeyError implements Exception {
  const HmSshKeyError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Largest private key accepted (official limit).
const hmSshMaxKeyBytes = 64 * 1024;

/// Whether [text] is an encrypted private key (false when unreadable).
bool hmSshKeyIsEncrypted(String text) {
  try {
    return SSHKeyPair.isEncryptedPem(text.trim());
  } catch (_) {
    return false;
  }
}

/// Decodes [text] into key pairs or throws [HmSshKeyError] with the official
/// reason. [fromFile] picks the import wording for unreadable input.
List<SSHKeyPair> hmSshParseKey(
  String text, {
  String? passphrase,
  bool fromFile = false,
}) {
  final key = text.trim();
  if (utf8.encode(key).length > hmSshMaxKeyBytes) {
    throw const HmSshKeyError(HmSshText.keyTooBig);
  }
  if (key.startsWith('PuTTY-User-Key-File')) {
    throw const HmSshKeyError(HmSshText.keyPutty);
  }
  if (key.contains('BEGIN SSH2 ENCRYPTED PRIVATE KEY') ||
      key.startsWith('---- BEGIN SSH2')) {
    throw const HmSshKeyError(HmSshText.keySshCom);
  }
  if (RegExp(r'^(ssh-|ecdsa-|sk-)\S+\s+[A-Za-z0-9+/=]+').hasMatch(key) ||
      key.contains('PUBLIC KEY-----')) {
    throw const HmSshKeyError(HmSshText.keyPublic);
  }
  if (key.contains('BEGIN DSA PRIVATE KEY')) {
    throw const HmSshKeyError(HmSshText.keyDsa);
  }
  if (!key.contains('-----BEGIN') || !key.contains('PRIVATE KEY-----')) {
    throw HmSshKeyError(
      fromFile ? HmSshText.keyFileUnreadable : HmSshText.keyUnreadable,
    );
  }
  if (!key.contains('-----END')) {
    throw const HmSshKeyError(HmSshText.keyDamaged);
  }
  final bool encrypted;
  try {
    encrypted = SSHKeyPair.isEncryptedPem(key);
  } on UnsupportedError {
    throw HmSshKeyError(
      fromFile ? HmSshText.keyFileUnreadable : HmSshText.keyUnreadable,
    );
  } catch (_) {
    throw const HmSshKeyError(HmSshText.keyDamaged);
  }
  final phrase = passphrase?.isEmpty ?? true ? null : passphrase;
  if (encrypted && phrase == null) {
    throw const HmSshKeyError(HmSshText.keyNeedsPassphrase);
  }
  final List<SSHKeyPair> pairs;
  try {
    pairs = SSHKeyPair.fromPem(key, encrypted ? phrase : null);
  } catch (_) {
    throw HmSshKeyError(
      encrypted ? HmSshText.keyWrongPassphrase : HmSshText.keyDamaged,
    );
  }
  if (pairs.isEmpty) throw const HmSshKeyError(HmSshText.keyDamaged);
  if (pairs.any((p) => p.type == 'ssh-dss' || p.type == 'ssh-ed448')) {
    throw const HmSshKeyError(HmSshText.keyDsa);
  }
  return pairs;
}
