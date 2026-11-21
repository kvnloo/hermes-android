// Artifacts: files and outputs the bot produced.
//
// The list mirrors the official app's Artifacts screen: back + title, a
// folder control that picks All Files / Images / Files / Links, "Search
// artifacts", then the artifacts grouped by category, newest first. Opening
// an image or file uses the fork's attachment viewer (image, PDF, text,
// video, share); a link opens in the browser.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/connection_manager.dart' show DashboardClient;
import '../../../core/services/remote_files_client.dart';
import '../../../core/utils/media_tags.dart';
import '../../../core/widgets/media_artifact_card.dart';
import '../../../nextgen/data/chat_controller.dart';
import '../../../nextgen/theme/nextgen_theme.dart';
import '../../../nextgen/ui/nextgen_scope.dart';
import '../../../nextgen/ui/scheduled_page.dart';
import '../../hm_bots.dart';
import '../../hm_ui.dart';
import '../../screens/hm_chat_screen.dart';
import '../live/hm_live.dart';
import '../terminal/hm_terminal.dart';
import '../work/hm_execution.dart';
import 'artifact_scan.dart';
import 'artifacts_data.dart';

/// [chat] is null when opened from Agent settings (all of the bot's artifacts).
Future<void> openHmArtifacts(
  BuildContext context, {
  required HmBot bot,
  required HmBotsModel bots,
  NgChatController? chat,
}) async {
  final scope = NgScope.of(context);
  final source = DashboardArtifactsSource(
    dashboard: bots.gateway.dashboard,
    profile: bot.scope,
    sessionId: chat?.storedId,
  );
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (context) => HmArtifactsScreen(
        loader: HmArtifactsLoader(source),
        // A chat that was never sent has no transcript yet.
        draftChat: chat != null && chat.storedId == null,
        showSession: chat == null,
        filesClient: (sessionId) => RemoteFilesClient(
          dashboard: DashboardClient.fromConnection(scope.connection),
          profile: bot.scope,
          sessionId: sessionId,
          maxDownloadBytes: maxAttachmentDownloadBytes,
        ),
        onOpenChat: (context, artifact) async {
          if (chat != null && chat.storedId == artifact.sessionId) {
            Navigator.of(context).pop();
            return;
          }
          await _openChat(context, bot, bots, artifact);
        },
      ),
    ),
  );
}

/// Opens the artifact's chat on top of the Artifacts screen.
Future<void> _openChat(
  BuildContext context,
  HmBot bot,
  HmBotsModel bots,
  HmArtifact artifact,
) async {
  final chat = NgChatController(
    bots.gateway,
    sessionId: artifact.sessionId,
    title: artifact.sessionTitle,
    profile: bot.scope,
  );
  unawaited(chat.open());
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (context) => HmChatScreen(
        bot: bot,
        chat: chat,
        onNewChat: () => Navigator.of(context).pop(),
        onAction: (a) => _chatAction(context, bot, bots, chat, a),
      ),
    ),
  );
  chat.dispose();
}

Future<void> _chatAction(
  BuildContext context,
  HmBot bot,
  HmBotsModel bots,
  NgChatController chat,
  HmChatAction a,
) async {
  switch (a) {
    case HmChatAction.chatSettings:
      await showHmChatSettings(context, chat);
    case HmChatAction.liveMode:
      await openHmLive(context, bot: bot, bots: bots, chat: chat);
    case HmChatAction.terminal:
      await openHmTerminal(context, bot: bot, bots: bots, chat: chat);
    case HmChatAction.execution:
      await openHmExecution(context, bot: bot, bots: bots, chat: chat);
    case HmChatAction.routines:
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => NgScheduledPage(
            onOpenSession: (_) => Navigator.of(context).pop(),
          ),
        ),
      );
    case HmChatAction.artifacts:
      await openHmArtifacts(context, bot: bot, bots: bots, chat: chat);
    case HmChatAction.archive:
      final id = chat.storedId;
      if (id == null) return;
      await bots
          .apiFor(bot)
          .setSessionArchived(sessionId: id, archived: true)
          .catchError((_) => false);
      if (context.mounted) Navigator.of(context).pop();
    case HmChatAction.delete:
      final id = chat.storedId;
      if (id == null) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete this chat?'),
          content: const Text('It is removed from the host for every device.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      await bots.apiFor(bot).deleteSession(id).catchError((_) {});
      if (context.mounted) Navigator.of(context).pop();
  }
}

enum _Filter { all, image, file, link }

extension on _Filter {
  String get label => switch (this) {
    _Filter.all => 'All Files',
    _Filter.image => 'Images',
    _Filter.file => 'Files',
    _Filter.link => 'Links',
  };
  IconData get icon => switch (this) {
    _Filter.all => Icons.folder_outlined,
    _Filter.image => Icons.image_outlined,
    _Filter.file => Icons.insert_drive_file_outlined,
    _Filter.link => Icons.link,
  };
  HmArtifactKind? get kind => switch (this) {
    _Filter.all => null,
    _Filter.image => HmArtifactKind.image,
    _Filter.file => HmArtifactKind.file,
    _Filter.link => HmArtifactKind.link,
  };
}

String _sectionLabel(HmArtifactKind k) => switch (k) {
  HmArtifactKind.image => 'Images',
  HmArtifactKind.file => 'Files',
  HmArtifactKind.link => 'Links',
};

enum _RowAction { openChat, copy, openLink }

class HmArtifactsScreen extends StatefulWidget {
  const HmArtifactsScreen({
    super.key,
    required this.loader,
    required this.filesClient,
    required this.onOpenChat,
    this.showSession = true,
    this.draftChat = false,
    this.openUrl,
  });

  final HmArtifactsLoader loader;

  /// A fresh files client for one session; the viewer closes it when done.
  final RemoteFilesDataSource Function(String sessionId) filesClient;
  final Future<void> Function(BuildContext context, HmArtifact artifact)
  onOpenChat;

  /// Show each artifact's chat title (off when the screen shows one chat).
  final bool showSession;

  /// The chat has no transcript yet, so nothing is fetched.
  final bool draftChat;

  /// Opens a link outside the app; tests replace it.
  final Future<bool> Function(Uri uri)? openUrl;

  @override
  State<HmArtifactsScreen> createState() => _HmArtifactsScreenState();
}

class _HmArtifactsScreenState extends State<HmArtifactsScreen> {
  HmArtifactsState _state = const HmArtifactsLoading();
  _Filter _filter = _Filter.all;
  final _search = TextEditingController();
  final Map<String, Future<Uint8List?>> _thumbs = {};

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    if (widget.draftChat) {
      _state = const HmArtifactsLoaded([]);
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final next = await widget.loader.load();
    if (mounted) setState(() => _state = next);
  }

  Future<void> _retry() async {
    setState(() => _state = const HmArtifactsLoading());
    await _load();
  }

  List<HmArtifact> _visible(List<HmArtifact> all) {
    final kind = _filter.kind;
    final q = _search.text.trim().toLowerCase();
    return [
      for (final a in all)
        if ((kind == null || a.kind == kind) &&
            (q.isEmpty ||
                a.label.toLowerCase().contains(q) ||
                a.value.toLowerCase().contains(q) ||
                a.sessionTitle.toLowerCase().contains(q)))
          a,
    ];
  }

  Future<void> _pickFilter() async {
    final picked = await showHmMenu<_Filter>(
      context,
      groups: [
        [for (final f in _Filter.values) HmMenuItem(f, f.icon, f.label)],
      ],
    );
    if (picked != null && mounted) setState(() => _filter = picked);
  }

  void _say(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _openLink(HmArtifact a) async {
    final uri = Uri.tryParse(a.value);
    var ok = false;
    if (uri != null) {
      try {
        ok = await (widget.openUrl ??
            (u) => launchUrl(u, mode: LaunchMode.externalApplication))(uri);
      } catch (_) {
        ok = false;
      }
    }
    if (!ok && mounted) _say('Couldn’t open the selected destination.');
  }

  Future<void> _open(HmArtifact a) async {
    if (a.kind == HmArtifactKind.link) return _openLink(a);
    if (a.value.startsWith('data:')) {
      final bytes = _dataBytes(a.value);
      if (bytes == null) return _say('Couldn’t open image');
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _DataImageViewer(title: a.label, bytes: bytes),
        ),
      );
      return;
    }
    await openMediaFilePreview(
      context: context,
      filesClient: () => widget.filesClient(a.sessionId),
      ref: MediaTagRef(path: _hostPath(a.value)),
      sourceIdentity: a.id,
    );
  }

  Future<void> _more(HmArtifact a) async {
    final c = NgColors.of(context);
    final isLink = a.kind == HmArtifactKind.link || a.isWebUrl;
    final picked = await showModalBottomSheet<_RowAction>(
      context: context,
      backgroundColor: c.sheet,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: HmGroup(
            children: [
              HmRow(
                icon: Icons.chat_bubble_outline,
                label: 'Open Chat',
                value: widget.showSession ? a.sessionTitle : null,
                onTap: () => Navigator.pop(context, _RowAction.openChat),
              ),
              HmRow(
                icon: Icons.content_copy,
                label: isLink ? 'Copy Link' : 'Copy Path',
                chevron: false,
                onTap: () => Navigator.pop(context, _RowAction.copy),
              ),
              if (isLink)
                HmRow(
                  icon: Icons.open_in_new,
                  label: 'Open in Browser',
                  chevron: false,
                  onTap: () => Navigator.pop(context, _RowAction.openLink),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || picked == null) return;
    switch (picked) {
      case _RowAction.openChat:
        await widget.onOpenChat(context, a);
      case _RowAction.copy:
        await Clipboard.setData(ClipboardData(text: a.value));
      case _RowAction.openLink:
        await _openLink(a);
    }
  }

  Future<Uint8List?> _thumb(HmArtifact a) => _thumbs.putIfAbsent(a.id, () async {
    if (a.value.startsWith('data:')) return _dataBytes(a.value);
    final client = widget.filesClient(a.sessionId);
    try {
      return (await client.download(_hostPath(a.value))).bytes;
    } catch (_) {
      return null;
    } finally {
      if (client is RemoteFilesClient) client.close();
    }
  });

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Scaffold(
      backgroundColor: c.background,
      body: Column(
        children: [
          HmTopBar(
            leading: const HmBackButton(),
            title: 'Artifacts',
            trailing: [
              HmRoundButton(
                icon: _filter.icon,
                label: _filter.label,
                onPressed: _pickFilter,
              ),
            ],
          ),
          _SearchField(controller: _search),
          Expanded(child: _body(c)),
        ],
      ),
    );
  }

  Widget _body(NgColors c) {
    switch (_state) {
      case HmArtifactsLoading():
        return Center(child: CircularProgressIndicator(color: c.accent));
      case HmArtifactsUnavailable(:final message):
        return _Notice(
          icon: Icons.cloud_off_outlined,
          title: 'Artifacts unavailable',
          body: message,
          action: TextButton(onPressed: _retry, child: const Text('Try Again')),
        );
      case HmArtifactsLoaded(:final artifacts):
        if (artifacts.isEmpty) {
          return RefreshIndicator(
            onRefresh: _load,
            child: const _Scrollable(
              child: _Notice(
                icon: Icons.inventory_2_outlined,
                title: 'No artifacts yet',
                body:
                    'Images, files, and links created in recent '
                    'conversations will collect here.',
              ),
            ),
          );
        }
        final visible = _visible(artifacts);
        if (visible.isEmpty) {
          return const _Notice(
            icon: Icons.search_off,
            title: 'No matching artifacts',
            body: 'Try a different search.',
          );
        }
        return RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              for (final kind in HmArtifactKind.values)
                if (visible.any((a) => a.kind == kind)) ...[
                  HmSection(_sectionLabel(kind)),
                  HmGroup(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    children: [
                      for (final a in visible.where((a) => a.kind == kind))
                        _ArtifactRow(
                          artifact: a,
                          showSession: widget.showSession,
                          thumb: a.kind == HmArtifactKind.image
                              ? _thumb(a)
                              : null,
                          onTap: () => _open(a),
                          onMore: () => _more(a),
                        ),
                    ],
                  ),
                ],
            ],
          ),
        );
    }
  }
}

/// `file://` refs name a host path; the files API wants the path itself.
String _hostPath(String value) {
  if (!value.toLowerCase().startsWith('file://')) return value;
  final uri = Uri.tryParse(value);
  return uri == null ? value.substring(7) : Uri.decodeComponent(uri.path);
}

Uint8List? _dataBytes(String value) {
  final comma = value.indexOf(',');
  if (comma < 0 || !value.substring(0, comma).endsWith(';base64')) return null;
  try {
    return base64Decode(value.substring(comma + 1));
  } on FormatException {
    return null;
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(HmMetrics.edge, 4, HmMetrics.edge, 8),
      child: TextField(
        controller: controller,
        style: HmType.row.copyWith(color: c.text),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search artifacts',
          hintStyle: HmType.row.copyWith(color: c.text3),
          prefixIcon: Icon(Icons.search, color: c.text3),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
                  icon: Icon(Icons.close, color: c.text3),
                  onPressed: controller.clear,
                ),
          filled: true,
          fillColor: c.well,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(28),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

class _ArtifactRow extends StatelessWidget {
  const _ArtifactRow({
    required this.artifact,
    required this.showSession,
    required this.onTap,
    required this.onMore,
    this.thumb,
  });

  final HmArtifact artifact;
  final bool showSession;
  final Future<Uint8List?>? thumb;
  final VoidCallback onTap;
  final VoidCallback onMore;

  IconData get _icon {
    if (artifact.kind == HmArtifactKind.link) return Icons.link;
    if (artifact.kind == HmArtifactKind.image) return Icons.image_outlined;
    final v = artifact.value.toLowerCase();
    if (v.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (RegExp(r'\.(mp3|m4a|wav|ogg|opus|flac)$').hasMatch(v)) {
      return Icons.audio_file_outlined;
    }
    if (RegExp(r'\.(mp4|mov|webm|mkv|avi)$').hasMatch(v)) {
      return Icons.video_file_outlined;
    }
    return Icons.description_outlined;
  }

  String _when(BuildContext context) {
    final t = DateTime.fromMillisecondsSinceEpoch(artifact.timestamp);
    final l = MaterialLocalizations.of(context);
    return '${l.formatShortMonthDay(t)}, '
        '${l.formatTimeOfDay(TimeOfDay.fromDateTime(t))}';
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final sub = artifact.kind == HmArtifactKind.link
        ? (Uri.tryParse(artifact.value)?.host ?? '')
        : '';
    final parts = [
      if (sub.isNotEmpty) sub,
      if (showSession) artifact.sessionTitle,
      _when(context),
    ];
    final icon = Icon(_icon, size: 22, color: c.text2);
    return InkWell(
      onTap: onTap,
      onLongPress: onMore,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: HmMetrics.botAvatar,
                height: HmMetrics.botAvatar,
                color: c.surface2,
                alignment: Alignment.center,
                child: thumb == null
                    ? icon
                    : FutureBuilder<Uint8List?>(
                        future: thumb,
                        builder: (context, snap) {
                          final bytes = snap.data;
                          if (bytes == null) return icon;
                          return Image.memory(
                            bytes,
                            width: HmMetrics.botAvatar,
                            height: HmMetrics.botAvatar,
                            fit: BoxFit.cover,
                            cacheWidth: 120,
                            errorBuilder: (_, _, _) => icon,
                          );
                        },
                      ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    artifact.label,
                    style: HmType.row.copyWith(color: c.text),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    parts.join(' · '),
                    style: HmType.sub.copyWith(color: c.text3),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'More',
              icon: Icon(Icons.more_vert, color: c.text3),
              onPressed: onMore,
            ),
          ],
        ),
      ),
    );
  }
}

/// Centered icon, title and line of text (empty, no match, unavailable).
class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: c.text3),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: HmType.row.copyWith(
                color: c.text,
                fontWeight: FontWeight.w600,
                fontSize: 19,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              body,
              textAlign: TextAlign.center,
              style: HmType.value.copyWith(color: c.text3),
            ),
            if (action != null) ...[const SizedBox(height: 12), action!],
          ],
        ),
      ),
    );
  }
}

/// Lets pull-to-refresh work on a screen with nothing to scroll.
class _Scrollable extends StatelessWidget {
  const _Scrollable({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: SizedBox(height: box.maxHeight, child: child),
    ),
  );
}

/// An image the bot sent inline as a data URI.
class _DataImageViewer extends StatelessWidget {
  const _DataImageViewer({required this.title, required this.bytes});
  final String title;
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Scaffold(
      backgroundColor: c.background,
      body: Column(
        children: [
          HmTopBar(leading: const HmBackButton(), title: title),
          Expanded(
            child: InteractiveViewer(
              maxScale: 6,
              child: Center(
                child: Image.memory(
                  bytes,
                  errorBuilder: (_, _, _) => Text(
                    'Couldn’t open image',
                    style: HmType.value.copyWith(color: c.text3),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
