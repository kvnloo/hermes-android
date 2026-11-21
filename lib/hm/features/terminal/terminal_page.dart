// The Terminal screen: the chat's shell, or the state that explains why
// there isn't one yet. Wording follows the official app's strings.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../../nextgen/theme/nextgen_theme.dart';
import '../../hm_ui.dart';
import '../../screens/hm_chat_screen.dart' show HmMenuItem, showHmMenu;
import 'terminal_transport.dart';

/// Official strings (out/ui-text.txt).
abstract final class HmTerminalText {
  static const title = 'Terminal';
  static const noCwd =
      'Connect or refresh this chat to load its working directory, then open Terminal again.';
  static const connectTitle = 'Connect a Terminal';
  static const connectBody = 'Add SSH credentials in Terminal settings first.';
  static const connecting = 'Connecting to Hermes…';
  static const failed = 'Connection failed';
  static const closed = 'Terminal has been closed';
  static const lost = 'Connection lost';
  static const reconnect =
      'Reconnect to open a new shell in this chat’s folder.';
  static const tryAgain = 'Try Again';
  static const copy = 'Copy';
  static const paste = 'Paste';
  static const selectAll = 'Select All';
  static const showKeyboard = 'Show Keyboard';
  static const hideKeyboard = 'Hide Keyboard';
  static const workingDirectory = 'Working directory';
  static const addSshOrMosh = 'Add SSH or Mosh';
  static const connectionSettings = 'Terminal Connection';
}

enum HmTerminalPhase {
  loading,
  noCwd,
  unavailable,
  connecting,
  connected,
  ended,
  failed,
}

enum _Action { copy, paste, selectAll, keyboard }

class HmTerminalPage extends StatefulWidget {
  const HmTerminalPage({super.key, required this.backend, this.onOpenSettings});

  final HmTerminalBackend backend;

  /// Opens this instance's Terminal Connection; resolves true when it
  /// changed, and the terminal connects again.
  final Future<bool> Function(BuildContext context)? onOpenSettings;

  @override
  State<HmTerminalPage> createState() => _HmTerminalPageState();
}

class _HmTerminalPageState extends State<HmTerminalPage> {
  HmTerminalPhase _phase = HmTerminalPhase.loading;
  String? _cwd;
  String? _error;
  HmTerminalEnd? _end;
  HmTerminalSession? _session;
  StreamSubscription<String>? _output;
  Terminal _terminal = Terminal(maxLines: 10000);
  final _controller = TerminalController();
  final _focus = FocusNode();
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
    unawaited(_start());
  }

  @override
  void dispose() {
    _disposed = true;
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _controller.dispose();
    unawaited(_output?.cancel());
    unawaited(_session?.close());
    super.dispose();
  }

  void _onFocus() {
    if (!_disposed) setState(() {});
  }

  void _set(HmTerminalPhase phase, {String? error}) {
    if (_disposed) return;
    setState(() {
      _phase = phase;
      _error = error;
    });
  }

  Future<void> _start() async {
    _set(HmTerminalPhase.loading);
    try {
      _cwd = await widget.backend.workingDirectory();
    } on HmTerminalFailure catch (e) {
      return _set(HmTerminalPhase.failed, error: e.message);
    } catch (_) {
      return _set(HmTerminalPhase.failed, error: HmTerminalText.failed);
    }
    final cwd = _cwd;
    if (cwd == null) return _set(HmTerminalPhase.noCwd);
    await _connect(cwd);
  }

  Future<void> _connect(String cwd) async {
    _set(HmTerminalPhase.connecting);
    final terminal = Terminal(maxLines: 10000);
    final HmTerminalSession session;
    try {
      session = await widget.backend.open(
        cwd: cwd,
        cols: terminal.viewWidth,
        rows: terminal.viewHeight,
      );
    } on HmTerminalUnavailable {
      return _set(HmTerminalPhase.unavailable);
    } on HmTerminalFailure catch (e) {
      return _set(HmTerminalPhase.failed, error: e.message);
    } catch (_) {
      return _set(HmTerminalPhase.failed, error: HmTerminalText.failed);
    }
    if (_disposed) {
      unawaited(session.close());
      return;
    }
    terminal
      ..onOutput = session.write
      ..onResize = (cols, rows, _, _) => session.resize(cols, rows);
    await _output?.cancel();
    _output = session.output.listen(terminal.write);
    _session = session;
    _terminal = terminal;
    _end = null;
    unawaited(
      session.done.then((end) {
        if (_disposed || !identical(_session, session)) return;
        _end = end;
        _set(HmTerminalPhase.ended);
      }),
    );
    _set(HmTerminalPhase.connected);
  }

  Future<void> _openSettings() async {
    final open = widget.onOpenSettings;
    if (open == null) return;
    final changed = await open(context);
    if (changed && !_disposed) _retry();
  }

  void _retry() {
    final cwd = _cwd;
    unawaited(cwd == null ? _start() : _connect(cwd));
  }

  Future<void> _menu() async {
    final keyboardUp = _focus.hasFocus;
    final picked = await showHmMenu<_Action>(
      context,
      groups: [
        const [
          HmMenuItem(_Action.copy, Icons.content_copy, HmTerminalText.copy),
          HmMenuItem(_Action.paste, Icons.content_paste, HmTerminalText.paste),
          HmMenuItem(
            _Action.selectAll,
            Icons.select_all,
            HmTerminalText.selectAll,
          ),
        ],
        [
          HmMenuItem(
            _Action.keyboard,
            keyboardUp ? Icons.keyboard_hide : Icons.keyboard,
            keyboardUp
                ? HmTerminalText.hideKeyboard
                : HmTerminalText.showKeyboard,
          ),
        ],
      ],
    );
    if (picked == null || _disposed) return;
    switch (picked) {
      case _Action.copy:
        final range = _controller.selection;
        final text = range == null ? '' : _terminal.buffer.getText(range);
        if (text.isNotEmpty) {
          await Clipboard.setData(ClipboardData(text: text));
        }
        _controller.clearSelection();
      case _Action.paste:
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        final text = data?.text;
        if (text != null && text.isNotEmpty) _terminal.paste(text);
      case _Action.selectAll:
        final buffer = _terminal.buffer;
        _controller.setSelection(
          buffer.createAnchor(0, 0),
          buffer.createAnchor(buffer.viewWidth, buffer.height - 1),
        );
      case _Action.keyboard:
        if (keyboardUp) {
          _focus.unfocus();
        } else {
          _focus.requestFocus();
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final live =
        _phase == HmTerminalPhase.connected || _phase == HmTerminalPhase.ended;
    return Scaffold(
      backgroundColor: c.background,
      body: Column(
        children: [
          HmTopBar(
            leading: const HmBackButton(),
            title: HmTerminalText.title,
            trailing: [
              if (live)
                HmRoundButton(
                  icon: Icons.more_horiz,
                  label: MaterialLocalizations.of(context).moreButtonTooltip,
                  onPressed: _menu,
                ),
            ],
          ),
          Expanded(child: live ? _live(c) : _state(c)),
        ],
      ),
    );
  }

  Widget _state(NgColors c) => switch (_phase) {
    HmTerminalPhase.loading || HmTerminalPhase.connecting => _Busy(c: c),
    HmTerminalPhase.noCwd => _Notice(
      c: c,
      icon: Icons.folder_off_outlined,
      body: HmTerminalText.noCwd,
    ),
    HmTerminalPhase.unavailable => _Notice(
      c: c,
      icon: Icons.terminal,
      title: HmTerminalText.connectTitle,
      body: HmTerminalText.connectBody,
      action: widget.onOpenSettings == null
          ? null
          : HmTerminalText.addSshOrMosh,
      onAction: _openSettings,
    ),
    _ => _Notice(
      c: c,
      icon: Icons.error_outline,
      title: HmTerminalText.failed,
      body: _error == null || _error == HmTerminalText.failed ? null : _error,
      action: HmTerminalText.tryAgain,
      onAction: _retry,
      secondary: widget.onOpenSettings == null
          ? null
          : HmTerminalText.connectionSettings,
      onSecondary: _openSettings,
    ),
  };

  Widget _live(NgColors c) {
    final cwd = _session?.meta.cwd ?? _cwd ?? '';
    final end = _end;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HmMetrics.edge + 4,
            0,
            HmMetrics.edge + 4,
            6,
          ),
          child: Semantics(
            label: HmTerminalText.workingDirectory,
            value: cwd,
            excludeSemantics: true,
            child: Row(
              children: [
                Icon(Icons.folder_outlined, size: 16, color: c.text3),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    cwd,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HmType.caption.copyWith(color: c.text3),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: c.well,
              borderRadius: BorderRadius.circular(16),
            ),
            clipBehavior: Clip.antiAlias,
            child: TerminalView(
              _terminal,
              controller: _controller,
              focusNode: _focus,
              autofocus: true,
              readOnly: end != null,
              theme: hmTerminalTheme(c),
              textStyle: const TerminalStyle(fontSize: 13),
              padding: const EdgeInsets.all(8),
              keyboardType: TextInputType.visiblePassword,
              keyboardAppearance: c.background.computeLuminance() > 0.5
                  ? Brightness.light
                  : Brightness.dark,
              deleteDetection: true,
            ),
          ),
        ),
        if (end != null)
          _EndBanner(
            c: c,
            title: end.shellClosed
                ? HmTerminalText.closed
                : HmTerminalText.lost,
            onRetry: _retry,
          ),
        SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
      ],
    );
  }
}

/// ANSI palette from the active theme tokens, so presets restyle the shell.
TerminalTheme hmTerminalTheme(NgColors c) {
  Color mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;
  Color bright(Color x) => mix(x, c.text, 0.25);
  final magenta = mix(c.danger, c.accent, 0.5);
  final cyan = mix(c.success, c.accent, 0.5);
  return TerminalTheme(
    cursor: c.accent,
    selection: c.accentSoft,
    foreground: c.text,
    background: c.well,
    black: c.textMuted,
    red: c.danger,
    green: c.success,
    yellow: c.warning,
    blue: c.accent,
    magenta: magenta,
    cyan: cyan,
    white: c.text2,
    brightBlack: c.text3,
    brightRed: bright(c.danger),
    brightGreen: bright(c.success),
    brightYellow: bright(c.warning),
    brightBlue: bright(c.accent),
    brightMagenta: bright(magenta),
    brightCyan: bright(cyan),
    brightWhite: c.text,
    searchHitBackground: c.warningSoft,
    searchHitBackgroundCurrent: c.warning,
    searchHitForeground: c.text,
  );
}

class _Busy extends StatelessWidget {
  const _Busy({required this.c});
  final NgColors c;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: 28,
          child: CircularProgressIndicator(strokeWidth: 2.6, color: c.accent),
        ),
        const SizedBox(height: 16),
        Text(
          HmTerminalText.connecting,
          style: HmType.value.copyWith(color: c.text2),
        ),
      ],
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.c,
    required this.icon,
    this.title,
    this.body,
    this.action,
    this.onAction,
    this.secondary,
    this.onSecondary,
  });

  final NgColors c;
  final IconData icon;
  final String? title;
  final String? body;
  final String? action;
  final VoidCallback? onAction;
  final String? secondary;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: c.text3),
          if (title != null) ...[
            const SizedBox(height: 16),
            Text(
              title!,
              textAlign: TextAlign.center,
              style: HmType.screenTitle.copyWith(color: c.text),
            ),
          ],
          if (body != null) ...[
            const SizedBox(height: 8),
            Text(
              body!,
              textAlign: TextAlign.center,
              style: HmType.value.copyWith(color: c.text2),
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: 20),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: c.accent,
                foregroundColor: c.onAccent,
                shape: const StadiumBorder(),
              ),
              onPressed: onAction,
              child: Text(action!, style: HmType.pill),
            ),
          ],
          if (secondary != null) ...[
            const SizedBox(height: 8),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: c.accentText),
              onPressed: onSecondary,
              child: Text(secondary!, style: HmType.pill),
            ),
          ],
        ],
      ),
    ),
  );
}

class _EndBanner extends StatelessWidget {
  const _EndBanner({required this.c, required this.title, this.onRetry});

  final NgColors c;
  final String title;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
    padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
    decoration: BoxDecoration(
      color: c.surface,
      borderRadius: BorderRadius.circular(HmMetrics.groupRadius),
      boxShadow: hmShadow(c),
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: HmType.row.copyWith(color: c.text)),
              const SizedBox(height: 2),
              Text(
                HmTerminalText.reconnect,
                style: HmType.sub.copyWith(color: c.text2),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: c.accentText),
          onPressed: onRetry,
          child: Text(HmTerminalText.tryAgain, style: HmType.pill),
        ),
      ],
    ),
  );
}
