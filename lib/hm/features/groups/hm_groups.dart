// Group chats: several bots in one hosted room. The new-session sheet's
// group mode creates one; Home lists them; the room shows each bot's replies
// under its name; settings rename it, list its members and disband it.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../nextgen/data/nextgen_gateway.dart';
import '../../../nextgen/theme/nextgen_theme.dart';
import '../../avatar/hm_avatar.dart';
import '../../avatar/hm_avatar_state.dart';
import '../../hm_bots.dart';
import '../../hm_ui.dart';
import 'group_room_controller.dart';
import 'groups_api.dart';

export 'groups_api.dart' show HmGroupsApi, HmGroupRoom;

/// The groups API on [gateway]'s `/api/ws` socket.
HmGroupsApi hmGroupsApiFor(NextGenGateway gateway) =>
    HmGroupsApi((method, params) async {
      final phase = gateway.state.phase;
      if (phase == NgConnectionPhase.failed ||
          phase == NgConnectionPhase.sessionExpired) {
        throw StateError('not connected');
      }
      await gateway.connected();
      return gateway.call(method, params);
    });

// ── Directory: capability check + room list, for Home ──────────────────────

enum HmGroupsPhase { checking, ready, unavailable }

class HmGroupsDirectory extends ChangeNotifier {
  HmGroupsDirectory(this.api);

  final HmGroupsApi api;
  HmGroupsPhase phase = HmGroupsPhase.checking;

  /// Why groups can't be used here, in the official words.
  String? problem;
  HmGroupCapabilities? caps;
  List<HmGroupRoom> rooms = const [];
  bool _busy = false;
  bool _disposed = false;

  bool get canCreate =>
      phase == HmGroupsPhase.ready && (caps?.canCreate ?? false);

  Future<void> refresh() async {
    if (_busy) return;
    _busy = true;
    try {
      final c = await api.capabilities();
      caps = c;
      if (!c.driver) {
        problem = HmGroupText.noDriver;
      } else {
        problem = null;
      }
      rooms = await api.list();
      phase = HmGroupsPhase.ready;
    } on HmGroupFailure catch (e) {
      if (caps == null) {
        phase = HmGroupsPhase.unavailable;
        rooms = const [];
      }
      problem = e.message;
    } catch (_) {
      if (caps == null) phase = HmGroupsPhase.unavailable;
      problem = HmGroupText.uncheckable;
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  void forget(String roomId) {
    rooms = [
      for (final r in rooms)
        if (r.roomId != roomId) r,
    ];
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

// ── Shared bits ─────────────────────────────────────────────────────────────

HmCharacterSpec hmMemberSpec(HmGroupMember m, HmBotsModel? bots) =>
    bots?.byProfile(m.profile)?.character ??
    HmCharacterSpec.forName(hmMemberName(m, bots));

String hmMemberName(HmGroupMember m, HmBotsModel? bots) {
  final bot = bots?.byProfile(m.profile);
  if (bot != null) return bot.displayName;
  if (m.displayName.isNotEmpty) return m.displayName;
  return m.profile == 'default' ? 'Hermes' : m.handle;
}

/// Overlapping member avatars (up to three).
class HmGroupAvatarStack extends StatelessWidget {
  const HmGroupAvatarStack({
    super.key,
    required this.members,
    required this.bots,
    this.size = HmMetrics.botAvatar,
    this.thinking = const {},
  });

  final List<HmGroupMember> members;
  final HmBotsModel? bots;
  final double size;
  final Set<String> thinking;

  @override
  Widget build(BuildContext context) {
    final shown = members.take(3).toList();
    final small = shown.length <= 1 ? size : size * 0.66;
    final step = shown.length <= 1 ? 0.0 : (size - small) / (shown.length - 1);
    return SizedBox.square(
      dimension: size,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: step * i,
              top: shown.length == 2 ? step * i : (i == 1 ? 0 : size - small),
              child: HmAvatar(
                spec: hmMemberSpec(shown[i], bots),
                size: small,
                state: thinking.contains(shown[i].memberId)
                    ? HmAvatarState.thinking
                    : HmAvatarState.idle,
              ),
            ),
        ],
      ),
    );
  }
}

// ── New session / New Group sheet ──────────────────────────────────────────

/// What the new-session sheet picked: one bot, or a group it created.
sealed class HmNewSessionResult {
  const HmNewSessionResult();
}

final class HmNewBotChat extends HmNewSessionResult {
  const HmNewBotChat(this.bot);
  final HmBot bot;
}

final class HmNewGroupChat extends HmNewSessionResult {
  const HmNewGroupChat(this.room);
  final HmGroupRoom room;
}

/// "Start a new session": pick a bot, or switch to New Group and pick 2–6.
Future<HmNewSessionResult?> showHmNewSessionSheet(
  BuildContext context,
  List<HmBot> bots, {
  required HmGroupsDirectory groups,
}) {
  final c = NgColors.of(context);
  return showModalBottomSheet<HmNewSessionResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: c.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.92,
      child: HmNewSessionPanel(bots: bots, groups: groups),
    ),
  );
}

class HmNewSessionPanel extends StatefulWidget {
  const HmNewSessionPanel({
    super.key,
    required this.bots,
    required this.groups,
  });

  final List<HmBot> bots;
  final HmGroupsDirectory groups;

  @override
  State<HmNewSessionPanel> createState() => _HmNewSessionPanelState();
}

class _HmNewSessionPanelState extends State<HmNewSessionPanel> {
  bool group = false;
  final picked = <String>{};
  final name = TextEditingController();
  bool creating = false;
  String? error;

  /// One room id per draft, so a retried create opens the same group.
  String? _roomId;

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  void _toggleGroup() {
    setState(() {
      group = !group;
      error = null;
    });
    if (group && widget.groups.phase != HmGroupsPhase.ready) {
      unawaited(widget.groups.refresh());
    }
  }

  String _defaultName(List<HmBot> members) =>
      members.map((b) => b.displayName).join(', ');

  Future<void> _create() async {
    final members = [
      for (final b in widget.bots)
        if (picked.contains(b.profile)) b,
    ];
    if (members.length < 2) return;
    setState(() {
      creating = true;
      error = null;
    });
    final api = widget.groups.api;
    _roomId ??= api.newId();
    final typed = name.text.trim();
    try {
      final room = await api.create(
        roomId: _roomId!,
        name: typed.isEmpty ? _defaultName(members) : typed,
        members: [
          for (final b in members)
            HmGroupMember(
              memberId: b.profile,
              profile: b.profile,
              handle: _handle(b.profile),
            ),
        ],
      );
      unawaited(widget.groups.refresh());
      if (mounted) Navigator.of(context).pop(HmNewGroupChat(room));
    } on HmGroupFailure catch (e) {
      if (e.message.contains('different state') ||
          e.message.contains('disbanded room')) {
        _roomId = null;
      }
      setState(() => error = e.message);
    } catch (_) {
      setState(() => error = HmGroupText.couldNotOpen);
    } finally {
      if (mounted) setState(() => creating = false);
    }
  }

  static String _handle(String profile) {
    final h = profile
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return h.isEmpty ? 'bot' : (h == 'all' || h == 'everyone' ? '$h-bot' : h);
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return ListenableBuilder(
      listenable: widget.groups,
      builder: (context, _) {
        final dir = widget.groups;
        final blocked = group && !dir.canCreate;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HmMetrics.edge + 4,
                8,
                HmMetrics.edge,
                8,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      group ? 'New Group' : 'Start a new session',
                      style: HmType.screenTitle.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _GroupToggle(selected: group, onPressed: _toggleGroup),
                ],
              ),
            ),
            if (group && dir.phase == HmGroupsPhase.checking)
              _Note(text: HmGroupText.checking, busy: true)
            else if (group && dir.problem != null && !dir.canCreate)
              _Note(text: dir.problem!),
            Expanded(
              child: ListView(
                children: [
                  for (final b in widget.bots)
                    InkWell(
                      onTap: !group
                          ? () => Navigator.of(context).pop(HmNewBotChat(b))
                          : blocked
                          ? null
                          : () => setState(() {
                              if (!picked.remove(b.profile) &&
                                  picked.length < 6) {
                                picked.add(b.profile);
                              }
                            }),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: HmMetrics.edge,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            HmAvatar(spec: b.character, size: 52),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Text(
                                b.displayName,
                                style: HmType.row.copyWith(
                                  color: c.text,
                                  fontSize: 19,
                                ),
                              ),
                            ),
                            if (group)
                              Semantics(
                                checked: picked.contains(b.profile),
                                child: Icon(
                                  picked.contains(b.profile)
                                      ? Icons.check_circle
                                      : Icons.radio_button_unchecked,
                                  color: picked.contains(b.profile)
                                      ? c.accent
                                      : c.text3,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (group) ...[
              if (error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    HmMetrics.edge + 4,
                    0,
                    HmMetrics.edge,
                    8,
                  ),
                  child: Text(
                    error!,
                    style: HmType.body.copyWith(color: c.danger),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  HmMetrics.edge,
                  0,
                  HmMetrics.edge,
                  4,
                ),
                child: TextField(
                  controller: name,
                  enabled: !blocked,
                  maxLength: 200,
                  style: HmType.row.copyWith(color: c.text),
                  decoration: InputDecoration(
                    hintText: 'Group name (optional)',
                    counterText: '',
                    filled: true,
                    fillColor: c.input,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: c.stroke),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: c.stroke),
                    ),
                  ),
                ),
              ),
              SafeArea(
                top: false,
                child: HmPrimaryButton(
                  label: 'Create group',
                  trailingIcon: null,
                  busy: creating,
                  onPressed: !blocked && picked.length >= 2 ? _create : null,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _GroupToggle extends StatelessWidget {
  const _GroupToggle({required this.selected, required this.onPressed});
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: 'New group',
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: HmMetrics.roundButton,
        child: Material(
          color: c.surface,
          shape: const CircleBorder(),
          elevation: 3,
          shadowColor: c.text.withValues(alpha: 0.35),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Icon(
              selected ? Icons.group : Icons.group_outlined,
              size: 24,
              color: selected ? c.accent : c.text,
            ),
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text, this.busy = false});
  final String text;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HmMetrics.edge + 4,
        4,
        HmMetrics.edge,
        8,
      ),
      child: Row(
        children: [
          if (busy) ...[
            SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: c.text3),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(text, style: HmType.body.copyWith(color: c.text3)),
          ),
        ],
      ),
    );
  }
}

// ── Home row ────────────────────────────────────────────────────────────────

class HmGroupRow extends StatelessWidget {
  const HmGroupRow({
    super.key,
    required this.room,
    required this.bots,
    required this.onTap,
    required this.when,
  });

  final HmGroupRoom room;
  final HmBotsModel? bots;
  final VoidCallback onTap;
  final String when;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final names = room.members.map((m) => hmMemberName(m, bots)).join(', ');
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: HmMetrics.botRowHeight),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HmMetrics.edge,
            vertical: 10,
          ),
          child: Row(
            children: [
              HmGroupAvatarStack(members: room.members, bots: bots),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            room.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HmType.row.copyWith(
                              color: c.text,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          when,
                          style: HmType.caption.copyWith(color: c.text3),
                        ),
                      ],
                    ),
                    Text(
                      names,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HmType.value.copyWith(color: c.text3),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Room ────────────────────────────────────────────────────────────────────

/// Opens [room]; returns when the user leaves it. [changes] carries the
/// host's `groups.changed` pushes (room ids, or null for "everything").
Future<void> openHmGroup(
  BuildContext context, {
  required HmGroupRoom room,
  required HmGroupsApi api,
  required HmBotsModel? bots,
  Stream<List<String>?>? changes,
  HmGroupsDirectory? directory,
}) async {
  final controller = HmGroupRoomController(api, room);
  unawaited(controller.load());
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => HmGroupRoomScreen(
        controller: controller,
        bots: bots,
        changes: changes,
        directory: directory,
      ),
    ),
  );
  controller.dispose();
  unawaited(directory?.refresh());
}

class HmGroupRoomScreen extends StatefulWidget {
  const HmGroupRoomScreen({
    super.key,
    required this.controller,
    required this.bots,
    this.changes,
    this.directory,
    this.pollEvery = const Duration(seconds: 5),
  });

  final HmGroupRoomController controller;
  final HmBotsModel? bots;
  final Stream<List<String>?>? changes;
  final HmGroupsDirectory? directory;
  final Duration pollEvery;

  @override
  State<HmGroupRoomScreen> createState() => _HmGroupRoomScreenState();
}

class _HmGroupRoomScreenState extends State<HmGroupRoomScreen> {
  final input = TextEditingController();
  StreamSubscription<List<String>?>? _sub;
  Timer? _poll;

  HmGroupRoomController get room => widget.controller;

  @override
  void initState() {
    super.initState();
    _sub = widget.changes?.listen((ids) {
      if (ids == null || ids.contains(room.room.roomId)) {
        unawaited(room.sync());
      }
    });
    room.addListener(_onRoom);
  }

  void _onRoom() {
    // A backstop poll only while a member is answering.
    if (room.working && _poll == null) {
      _poll = Timer.periodic(widget.pollEvery, (_) => room.sync());
    } else if (!room.working && _poll != null) {
      _poll!.cancel();
      _poll = null;
    }
    final notice = room.notice;
    if (notice != null && mounted) {
      room.notice = null;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(notice)));
    }
  }

  @override
  void dispose() {
    room.removeListener(_onRoom);
    _sub?.cancel();
    _poll?.cancel();
    input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = input.text.trim();
    if (text.isEmpty) return;
    input.clear();
    // A failed send stays on screen with Retry and Edit.
    await room.send(text);
  }

  Future<void> _openSettings() async {
    final left = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            HmGroupSettingsScreen(controller: room, bots: widget.bots),
      ),
    );
    if (left == true && mounted) {
      widget.directory?.forget(room.room.roomId);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return ListenableBuilder(
      listenable: room,
      builder: (context, _) {
        final thinking = {for (final a in room.activity) a.memberId};
        return Scaffold(
          backgroundColor: c.background,
          body: Column(
            children: [
              HmTopBar(
                leading: const HmBackButton(),
                center: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 64),
                  child: InkWell(
                    onTap: _openSettings,
                    borderRadius: BorderRadius.circular(999),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        HmGroupAvatarStack(
                          members: room.members,
                          bots: widget.bots,
                          size: 32,
                          thinking: thinking,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            room.room.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HmType.row.copyWith(
                              color: c.text,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                trailing: [
                  HmRoundButton(
                    icon: Icons.more_horiz,
                    label: 'Group chat settings',
                    onPressed: _openSettings,
                  ),
                ],
              ),
              Expanded(child: _body(c, thinking)),
              for (final a in room.approvals)
                _ApprovalCard(
                  approval: a,
                  who: room.memberById(a.memberId) == null
                      ? a.memberId
                      : hmMemberName(room.memberById(a.memberId)!, widget.bots),
                  onAnswer: (allow) => room.approve(a, allow: allow),
                ),
              _Composer(
                controller: input,
                hint: 'Message ${room.room.name}…',
                working: room.working,
                enabled: room.phase != HmRoomPhase.error,
                onSend: _send,
                onStop: room.stop,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _body(NgColors c, Set<String> thinking) {
    if (room.phase == HmRoomPhase.loading && room.log.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (room.phase == HmRoomPhase.error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                room.error ?? HmGroupText.couldNotOpen,
                textAlign: TextAlign.center,
                style: HmType.body.copyWith(color: c.text3),
              ),
              const SizedBox(height: 12),
              TextButton(onPressed: room.load, child: const Text('Reload')),
            ],
          ),
        ),
      );
    }
    final rows = <Widget>[];
    for (final e in room.log) {
      final w = _eventRow(c, e);
      if (w != null) rows.add(w);
    }
    final p = room.pending;
    if (p != null) {
      rows.add(
        _Bubble(
          text: p.text,
          mine: true,
          faded: p.status == HmSendStatus.sending,
          footer: p.status == HmSendStatus.failed
              ? _Failed(
                  error: p.error ?? HmGroupText.notSent,
                  onRetry: () => room.send(p.text, retry: true),
                  onEdit: () {
                    final words = room.discardPending();
                    if (words != null) input.text = words;
                  },
                )
              : null,
        ),
      );
    }
    for (final a in room.activity) {
      final m = room.memberById(a.memberId);
      if (m == null) continue;
      rows.add(_Typing(member: m, bots: widget.bots));
    }
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              HmGroupAvatarStack(
                members: room.members,
                bots: widget.bots,
                size: 72,
              ),
              const SizedBox(height: 12),
              Text(
                'Group Chat',
                style: HmType.screenTitle.copyWith(color: c.text),
              ),
              const SizedBox(height: 4),
              Text(
                room.members
                    .map((m) => hmMemberName(m, widget.bots))
                    .join(', '),
                textAlign: TextAlign.center,
                style: HmType.body.copyWith(color: c.text3),
              ),
            ],
          ),
        ),
      );
    }
    return ListView(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(HmMetrics.edge, 8, HmMetrics.edge, 8),
      children: rows.reversed.toList(),
    );
  }

  Widget? _eventRow(NgColors c, HmGroupEvent e) {
    switch (e.kind) {
      case 'message.user':
        return _Bubble(text: e.text, mine: true);
      case 'message.member':
        final m = room.memberById(e.memberId);
        final name = m != null
            ? hmMemberName(m, widget.bots)
            : (e.actorName.isNotEmpty ? e.actorName : e.memberId);
        return _Bubble(
          text: e.text,
          mine: false,
          name: name,
          avatar: HmAvatar(
            spec: m != null
                ? hmMemberSpec(m, widget.bots)
                : HmCharacterSpec.forName(name),
            size: 28,
          ),
        );
      case 'turn.failed':
        final m = room.memberById(e.memberId);
        final who = m == null ? e.memberId : hmMemberName(m, widget.bots);
        final why = (e.payload['error'] ?? '').toString();
        return _SystemLine('$who: $why', danger: true);
      case 'room.renamed':
        return _SystemLine(
          '${HmGroupText.renamed}: ${(e.payload['name'] ?? '').toString()}',
        );
      default:
        return null;
    }
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.text,
    required this.mine,
    this.name,
    this.avatar,
    this.faded = false,
    this.footer,
  });

  final String text;
  final bool mine;
  final String? name;
  final Widget? avatar;
  final bool faded;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.78,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: mine ? c.userBubble : c.surface,
        borderRadius: BorderRadius.circular(20),
        border: mine ? null : Border.all(color: c.stroke),
      ),
      child: SelectableText(
        text,
        style: HmType.body.copyWith(color: mine ? c.onUserBubble : c.text),
      ),
    );
    return Opacity(
      opacity: faded ? 0.6 : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: mine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            if (name != null)
              Padding(
                padding: const EdgeInsets.only(left: 36, bottom: 2),
                child: Text(
                  name!,
                  style: HmType.caption.copyWith(
                    color: c.text2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (avatar != null) ...[avatar!, const SizedBox(width: 8)],
                Flexible(child: bubble),
              ],
            ),
            ?footer,
          ],
        ),
      ),
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({
    required this.error,
    required this.onRetry,
    required this.onEdit,
  });
  final String error;
  final VoidCallback onRetry;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            error,
            textAlign: TextAlign.end,
            style: HmType.caption.copyWith(color: c.danger),
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(onPressed: onEdit, child: const Text('Edit')),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ],
    );
  }
}

class _SystemLine extends StatelessWidget {
  const _SystemLine(this.text, {this.danger = false});
  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: HmType.caption.copyWith(color: danger ? c.danger : c.text3),
      ),
    );
  }
}

class _Typing extends StatelessWidget {
  const _Typing({required this.member, required this.bots});
  final HmGroupMember member;
  final HmBotsModel? bots;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          HmAvatar(
            spec: hmMemberSpec(member, bots),
            size: 28,
            state: HmAvatarState.thinking,
          ),
          const SizedBox(width: 8),
          Text(
            '${hmMemberName(member, bots)} · Working…',
            style: HmType.caption.copyWith(color: c.text3),
          ),
        ],
      ),
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({
    required this.approval,
    required this.who,
    required this.onAnswer,
  });
  final HmGroupApproval approval;
  final String who;
  final ValueChanged<bool> onAnswer;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return HmGroup(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              who,
              style: HmType.row.copyWith(
                color: c.text,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (approval.description.isNotEmpty)
              Text(
                approval.description,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: HmType.body.copyWith(color: c.text2),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => onAnswer(false),
                  child: const Text('Deny'),
                ),
                TextButton(
                  onPressed: () => onAnswer(true),
                  child: const Text('Allow once'),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.hint,
    required this.working,
    required this.enabled,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final String hint;
  final bool working;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          HmMetrics.edge,
          6,
          HmMetrics.edge,
          10,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                minLines: 1,
                maxLines: 6,
                textInputAction: TextInputAction.newline,
                style: HmType.row.copyWith(color: c.text),
                decoration: InputDecoration(
                  hintText: hint,
                  filled: true,
                  fillColor: c.input,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(26),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, v, _) {
                // Stop while a member answers and nothing new is typed.
                if (working && v.text.trim().isEmpty) {
                  return HmRoundButton(
                    icon: Icons.stop,
                    label: 'Stop',
                    filled: true,
                    onPressed: onStop,
                  );
                }
                return HmRoundButton(
                  icon: Icons.arrow_upward,
                  label: 'Send',
                  filled: true,
                  onPressed: enabled && v.text.trim().isNotEmpty
                      ? onSend
                      : null,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ── Settings ────────────────────────────────────────────────────────────────

/// Group chat settings. Pops `true` when the group was disbanded.
class HmGroupSettingsScreen extends StatelessWidget {
  const HmGroupSettingsScreen({
    super.key,
    required this.controller,
    required this.bots,
  });

  final HmGroupRoomController controller;
  final HmBotsModel? bots;

  Future<void> _rename(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: controller.room.name),
    );
    if (name == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await controller.rename(name);
      messenger.showSnackBar(
        const SnackBar(content: Text(HmGroupText.renamed)),
      );
    } on HmGroupFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text(HmGroupText.changeGone)),
      );
    }
  }

  Future<void> _disband(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(HmGroupText.disbandTitle),
        content: const Text(HmGroupText.disbandBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              'Disband',
              style: TextStyle(color: NgColors.of(context).danger),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    try {
      final ended = await controller.disband();
      if (!ended) {
        messenger.showSnackBar(
          const SnackBar(content: Text(HmGroupText.changeGone)),
        );
        return;
      }
      messenger.showSnackBar(
        const SnackBar(content: Text(HmGroupText.deleted)),
      );
      nav.pop(true);
    } on HmGroupFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text(HmGroupText.changeGone)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => HmPage(
        title: 'Group chat settings',
        children: [
          Center(
            child: HmGroupAvatarStack(
              members: controller.members,
              bots: bots,
              size: 72,
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              controller.room.name,
              style: HmType.screenTitle.copyWith(color: c.text),
            ),
          ),
          const HmSection('Group name'),
          HmGroup(
            children: [
              HmRow(
                icon: Icons.edit_outlined,
                label: controller.room.name,
                onTap: () => _rename(context),
              ),
            ],
          ),
          HmSection('Members · ${controller.members.length}'),
          HmGroup(
            children: [
              for (final m in controller.members)
                HmRow(
                  leading: HmAvatar(spec: hmMemberSpec(m, bots), size: 32),
                  label: hmMemberName(m, bots),
                  value: '@${m.handle}',
                  chevron: false,
                ),
            ],
          ),
          const SizedBox(height: HmMetrics.groupGap),
          HmGroup(
            children: [
              HmRow(
                icon: Icons.group_remove_outlined,
                label: HmGroupText.disband,
                danger: true,
                chevron: false,
                onTap: () => _disband(context),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});
  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Group name'),
    content: TextField(
      controller: field,
      autofocus: true,
      maxLength: 200,
      decoration: const InputDecoration(hintText: 'Group name'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, field.text),
        child: Text(MaterialLocalizations.of(context).saveButtonLabel),
      ),
    ],
  );
}
