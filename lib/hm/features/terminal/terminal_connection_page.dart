// Instance settings → Terminal → Terminal Connection: the SSH server, user
// and password or private key this instance's Terminal signs in with.
// Wording follows the official app's strings.
import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../nextgen/theme/nextgen_theme.dart';
import '../../hm_ui.dart';
import 'ssh_config.dart';

/// Trust on first use: shows the server's key fingerprint and asks before
/// the first connection. True trusts it.
Future<bool> hmConfirmSshHost(
  BuildContext context, {
  required String host,
  required String type,
  required String fingerprint,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (d) {
      final c = NgColors.of(d);
      return AlertDialog(
        backgroundColor: c.sheet,
        title: const Text(HmSshText.trustTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              HmSshText.trustBody,
              style: HmType.body.copyWith(color: c.text2),
            ),
            const SizedBox(height: 12),
            Text(host, style: HmType.row.copyWith(color: c.text)),
            const SizedBox(height: 4),
            Text(type, style: HmType.sub.copyWith(color: c.text3)),
            const SizedBox(height: 4),
            SelectableText(
              fingerprint,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: c.text,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: Text(MaterialLocalizations.of(d).cancelButtonLabel),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: c.accentText),
            onPressed: () => Navigator.pop(d, true),
            child: const Text(HmSshText.trustAction),
          ),
        ],
      );
    },
  );
  return ok == true;
}

/// Picks a key file and returns its text; null when cancelled.
typedef HmKeyFilePicker = Future<String?> Function();

Future<String?> hmPickKeyFile() async {
  final result = await FilePicker.platform.pickFiles(withData: true);
  final file = result?.files.singleOrNull;
  final bytes = file?.bytes;
  if (bytes == null) return null;
  if (bytes.length > hmSshMaxKeyBytes) {
    throw const HmSshKeyError(HmSshText.keyTooBig);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw const HmSshKeyError(HmSshText.keyFileUnreadable);
  }
}

/// Opens Terminal Connection for one instance. Resolves true when the
/// connection was saved or removed.
Future<bool> openHmTerminalConnection(
  BuildContext context, {
  required String connectionId,
  required String defaultHost,
  HmSshStore? store,
}) async {
  final changed = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => HmTerminalConnectionPage(
        connectionId: connectionId,
        defaultHost: defaultHost,
        store: store ?? HmSshStore.instance,
      ),
    ),
  );
  return changed == true;
}

enum _Auth { password, key }

enum _KeySource { saved, pasted, imported }

class HmTerminalConnectionPage extends StatefulWidget {
  const HmTerminalConnectionPage({
    super.key,
    required this.connectionId,
    required this.defaultHost,
    required this.store,
    this.pickKeyFile = hmPickKeyFile,
  });

  final String connectionId;

  /// The instance's own host name, offered as the SSH host.
  final String defaultHost;
  final HmSshStore store;
  final HmKeyFilePicker pickKeyFile;

  @override
  State<HmTerminalConnectionPage> createState() =>
      _HmTerminalConnectionPageState();
}

class _HmTerminalConnectionPageState extends State<HmTerminalConnectionPage> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _key = TextEditingController();
  final _passphrase = TextEditingController();

  bool _loading = true;
  String? _loadError;
  bool _busy = false;
  String? _error;
  HmSshConfig? _saved;
  _Auth _auth = _Auth.password;

  /// The saved key, kept out of the text field; null once cleared.
  String? _savedKey;
  _KeySource? _keySource;

  @override
  void initState() {
    super.initState();
    _key.addListener(_onKeyEdit);
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final c in [_host, _port, _user, _password, _key, _passphrase]) {
      c.dispose();
    }
    super.dispose();
  }

  void _onKeyEdit() {
    if (_key.text.trim().isNotEmpty && _keySource != _KeySource.imported) {
      _keySource = _KeySource.pasted;
    }
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final saved = await widget.store.load(widget.connectionId);
      if (!mounted) return;
      _saved = saved;
      _host.text = saved?.host ?? widget.defaultHost;
      _port.text = '${saved?.port ?? 22}';
      _user.text = saved?.username ?? '';
      _password.text = saved?.password ?? '';
      _passphrase.text = saved?.passphrase ?? '';
      _savedKey = saved?.privateKey;
      _keySource = _savedKey == null ? null : _KeySource.saved;
      _auth = saved?.usesKey ?? false ? _Auth.key : _Auth.password;
      setState(() => _loading = false);
    } on HmSshStoreError catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = e.message;
        });
      }
    }
  }

  String? get _keyText {
    final typed = _key.text.trim();
    if (typed.isNotEmpty) return typed;
    return _savedKey;
  }

  /// Checks the form; returns the config to save, or sets [_error].
  HmSshConfig? _validate() {
    final host = _host.text.trim();
    final user = _user.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (host.isEmpty ||
        host.contains(RegExp(r'\s')) ||
        user.isEmpty ||
        port == null ||
        port < 1 ||
        port > 65535) {
      _error = HmSshText.needHostUserPort;
      return null;
    }
    String? password;
    String? key;
    String? passphrase;
    if (_auth == _Auth.password) {
      password = _password.text;
      if (password.isEmpty) {
        _error = HmSshText.needSecret;
        return null;
      }
    } else {
      key = _keyText;
      passphrase = _passphrase.text.isEmpty ? null : _passphrase.text;
      if (key == null || key.isEmpty) {
        _error = passphrase != null
            ? HmSshText.passphraseNeedsKey
            : HmSshText.needSecret;
        return null;
      }
      try {
        hmSshParseKey(
          key,
          passphrase: passphrase,
          fromFile: _keySource == _KeySource.imported,
        );
      } on HmSshKeyError catch (e) {
        _error = e.message;
        return null;
      }
      if (!hmSshKeyIsEncrypted(key)) passphrase = null;
    }
    // A different server must be verified again.
    final saved = _saved;
    final sameServer =
        saved != null && saved.host == host && saved.port == port;
    return HmSshConfig(
      host: host,
      port: port,
      username: user,
      password: password,
      privateKey: key,
      passphrase: passphrase,
      hostKeyType: sameServer ? saved.hostKeyType : null,
      hostKeyFingerprint: sameServer ? saved.hostKeyFingerprint : null,
    );
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    setState(() => _error = null);
    final config = _validate();
    if (config == null) return setState(() {});
    setState(() => _busy = true);
    try {
      await widget.store.save(widget.connectionId, config);
      if (mounted) Navigator.of(context).pop(true);
    } on HmSshStoreError catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  Future<void> _remove() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.store.remove(widget.connectionId);
      if (mounted) Navigator.of(context).pop(true);
    } on HmSshStoreError catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  Future<void> _import() async {
    try {
      final text = await widget.pickKeyFile();
      if (text == null || !mounted) return;
      _keySource = _KeySource.imported;
      _key.text = text.trim();
      setState(() => _error = null);
    } on HmSshKeyError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = HmSshText.keyFileUnreadable);
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    _keySource = _KeySource.pasted;
    _key.text = text;
  }

  void _clearKey() {
    setState(() {
      _savedKey = null;
      _keySource = null;
      _key.clear();
      _passphrase.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    if (_loading || _loadError != null) {
      return HmPage(
        title: HmSshText.title,
        children: [
          const SizedBox(height: 80),
          Center(
            child: _loading
                ? Column(
                    children: [
                      SizedBox.square(
                        dimension: 28,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.6,
                          color: c.accent,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        HmSshText.loading,
                        style: HmType.value.copyWith(color: c.text2),
                      ),
                    ],
                  )
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      children: [
                        Text(
                          _loadError!,
                          textAlign: TextAlign.center,
                          style: HmType.value.copyWith(color: c.text2),
                        ),
                        const SizedBox(height: 16),
                        TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: c.accentText,
                          ),
                          onPressed: _load,
                          child: const Text('Try Again', style: HmType.pill),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      );
    }
    final keyText = _keyText;
    final encrypted =
        _auth == _Auth.key && keyText != null && hmSshKeyIsEncrypted(keyText);
    return HmPage(
      title: HmSshText.title,
      bottom: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
        child: HmPrimaryButton(
          label: HmSshText.save,
          trailingIcon: null,
          busy: _busy,
          onPressed: _save,
        ),
      ),
      children: [
        const HmSection(HmSshText.protocol),
        HmGroup(
          children: [
            HmRow(
              label: HmSshText.ssh,
              chevron: false,
              trailing: Icon(Icons.check, color: c.accent),
            ),
            HmRow(
              label: HmSshText.mosh,
              value: HmSshText.notSupported,
              chevron: false,
            ),
          ],
        ),
        _Note(c: c, text: HmSshText.moshNote),
        const HmSection(HmSshText.ssh),
        HmGroup(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          children: [
            _Field(
              c: c,
              label: HmSshText.host,
              controller: _host,
              keyboard: TextInputType.url,
            ),
            _Field(
              c: c,
              label: HmSshText.port,
              controller: _port,
              keyboard: TextInputType.number,
            ),
            _Field(c: c, label: HmSshText.username, controller: _user),
          ],
        ),
        const HmSection(HmSshText.authentication),
        HmGroup(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          children: [
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<_Auth>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                  selectedBackgroundColor: c.accentSoft,
                  selectedForegroundColor: c.text,
                  foregroundColor: c.text2,
                  side: BorderSide(color: c.stroke),
                ),
                segments: const [
                  ButtonSegment(
                    value: _Auth.password,
                    label: Text(HmSshText.password),
                  ),
                  ButtonSegment(
                    value: _Auth.key,
                    label: Text(HmSshText.privateKey),
                  ),
                ],
                selected: {_auth},
                onSelectionChanged: (s) => setState(() {
                  _auth = s.first;
                  _error = null;
                }),
              ),
            ),
            if (_auth == _Auth.password)
              _Field(
                c: c,
                label: HmSshText.password,
                controller: _password,
                obscure: true,
              )
            else
              ..._keyFields(c, encrypted),
          ],
        ),
        _Note(c: c, text: HmSshText.storageNote),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 12, 32, 0),
            child: Text(_error!, style: HmType.sub.copyWith(color: c.danger)),
          ),
        if (_saved != null) ...[
          const SizedBox(height: HmMetrics.groupGap),
          HmGroup(
            children: [
              HmRow(
                icon: Icons.delete_outline,
                label: HmSshText.remove,
                danger: true,
                chevron: false,
                onTap: _busy ? null : _remove,
              ),
            ],
          ),
        ],
      ],
    );
  }

  List<Widget> _keyFields(NgColors c, bool encrypted) {
    final status = switch (_keySource) {
      _KeySource.saved when _key.text.trim().isEmpty => HmSshText.keySaved,
      _KeySource.imported => HmSshText.keyImported,
      _KeySource.pasted || _KeySource.saved => HmSshText.keyPasted,
      null => null,
    };
    final hasKey = _keyText != null;
    return [
      if (status != null)
        HmRow(
          icon: Icons.key,
          label: status,
          chevron: false,
          trailing: TextButton(
            style: TextButton.styleFrom(foregroundColor: c.danger),
            onPressed: _clearKey,
            child: const Text(HmSshText.clearKey, style: HmType.pill),
          ),
        )
      else
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            HmSshText.addKeyHint,
            style: HmType.sub.copyWith(color: c.text2),
          ),
        ),
      if (!hasKey || _keySource != _KeySource.saved) ...[
        _Field(
          c: c,
          label: HmSshText.privateKeyField,
          controller: _key,
          maxLines: 6,
          mono: true,
          suffix: IconButton(
            tooltip: MaterialLocalizations.of(context).pasteButtonLabel,
            icon: Icon(Icons.content_paste, color: c.text3),
            onPressed: _paste,
          ),
        ),
      ],
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: c.accentText),
          onPressed: _import,
          icon: const Icon(Icons.file_open_outlined),
          label: Text(
            hasKey ? HmSshText.replaceKey : HmSshText.importKeyFile,
            style: HmType.pill,
          ),
        ),
      ),
      if (encrypted || _passphrase.text.isNotEmpty)
        _Field(
          c: c,
          label: HmSshText.keyPassphrase,
          controller: _passphrase,
          obscure: true,
        ),
      if (encrypted)
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Text(
            HmSshText.encryptedKeyNote,
            style: HmType.sub.copyWith(color: c.text3),
          ),
        ),
    ];
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.c, required this.text});
  final NgColors c;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(32, 10, 32, 0),
    child: Text(
      text,
      style: HmType.caption.copyWith(
        color: c.text3,
        fontStyle: FontStyle.italic,
      ),
    ),
  );
}

/// Label above a filled well, like the official instance form.
class _Field extends StatelessWidget {
  const _Field({
    required this.c,
    required this.label,
    required this.controller,
    this.keyboard,
    this.obscure = false,
    this.maxLines = 1,
    this.mono = false,
    this.suffix,
  });

  final NgColors c;
  final String label;
  final TextEditingController controller;
  final TextInputType? keyboard;
  final bool obscure;
  final int maxLines;
  final bool mono;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: HmType.sub.copyWith(color: c.text2)),
        const SizedBox(height: 6),
        Semantics(
          label: label,
          child: TextField(
            key: ValueKey('hm-ssh-field:$label'),
            controller: controller,
            keyboardType: maxLines > 1 ? TextInputType.multiline : keyboard,
            obscureText: obscure,
            autocorrect: false,
            enableSuggestions: false,
            minLines: 1,
            maxLines: obscure ? 1 : maxLines,
            style:
                (mono
                        ? const TextStyle(fontFamily: 'monospace', fontSize: 12)
                        : HmType.value.copyWith(fontSize: 16))
                    .copyWith(color: c.text),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: c.input,
              suffixIcon: suffix,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 14,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: c.stroke),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: c.stroke),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: c.accent),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// One instance to list in the Terminal settings section.
class HmTerminalInstance {
  const HmTerminalInstance({
    required this.id,
    required this.label,
    required this.defaultHost,
  });

  final String id;
  final String label;
  final String defaultHost;
}

/// Instance settings → "Terminal": a Terminal Connection row per instance
/// and the official note under it.
class HmTerminalSettingsSection extends StatelessWidget {
  const HmTerminalSettingsSection({
    super.key,
    required this.instances,
    this.store,
  });

  final List<HmTerminalInstance> instances;
  final HmSshStore? store;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    if (instances.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const HmSection(HmSshText.terminal),
        HmGroup(
          children: [
            for (final i in instances)
              HmTerminalConnectionRow(
                key: ValueKey('terminal-${i.id}'),
                connectionId: i.id,
                label: instances.length == 1 ? HmSshText.title : i.label,
                defaultHost: i.defaultHost,
                store: store,
              ),
          ],
        ),
        _Note(c: c, text: HmSshText.terminalNote),
      ],
    );
  }
}

/// Instance settings row: Terminal Connection and what it's set to.
class HmTerminalConnectionRow extends StatefulWidget {
  const HmTerminalConnectionRow({
    super.key,
    required this.connectionId,
    required this.label,
    required this.defaultHost,
    this.store,
  });

  final String connectionId;

  /// Row label (the instance's name when several are listed).
  final String label;
  final String defaultHost;
  final HmSshStore? store;

  @override
  State<HmTerminalConnectionRow> createState() =>
      _HmTerminalConnectionRowState();
}

class _HmTerminalConnectionRowState extends State<HmTerminalConnectionRow> {
  String? _value;

  HmSshStore get _store => widget.store ?? HmSshStore.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    String value;
    try {
      final config = await _store.load(widget.connectionId);
      value = config == null
          ? HmSshText.addSshOrMosh
          : '${config.username}@${config.host}';
    } on HmSshStoreError {
      value = HmSshText.addSshOrMosh;
    }
    if (mounted) setState(() => _value = value);
  }

  @override
  Widget build(BuildContext context) => HmRow(
    icon: Icons.terminal,
    label: widget.label,
    value: _value,
    tall: true,
    onTap: () async {
      final changed = await openHmTerminalConnection(
        context,
        connectionId: widget.connectionId,
        defaultHost: widget.defaultHost,
        store: _store,
      );
      if (changed) await _refresh();
    },
  );
}
