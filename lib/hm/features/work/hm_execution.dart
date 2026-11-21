// Execution: goals, tasks, subagents and terminal processes of this chat.
//
// The goal, plan (todos) and subagents come from the chat's own live state
// (`NgChatController`: `session.control.*`, `todo.updated`, `subagent.*`);
// background processes are polled with `process.list`. Actions go out as
// `/api/ws` JSON-RPC on the chat's live session.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../nextgen/data/chat_controller.dart';
import '../../../nextgen/data/session_control.dart';
import '../../../nextgen/theme/nextgen_theme.dart';
import '../../hm_bots.dart';
import '../../hm_ui.dart';
import 'hm_work_kit.dart';

Future<void> openHmExecution(
  BuildContext context, {
  required HmBot bot,
  required HmBotsModel bots,
  required NgChatController chat,
}) {
  final source = HmExecutionSource(
    rpc: chat.gateway.call,
    scope: chat.profile ?? bot.scope,
  );
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => HmExecutionPage(chat: chat, source: source),
    ),
  );
}

/// One background process the session owns (`process.list` row).
class HmProcess {
  const HmProcess({
    required this.id,
    required this.command,
    required this.status,
    this.uptimeSeconds,
    this.output = '',
    this.exitCode,
  });

  final String id;
  final String command;
  final String status;
  final int? uptimeSeconds;
  final String output;
  final int? exitCode;

  bool get running => status == 'running';

  static HmProcess? parse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['session_id']?.toString().trim() ?? '';
    if (id.isEmpty) return null;
    final tail = raw['output_tail']?.toString() ?? '';
    return HmProcess(
      id: id,
      command: raw['command']?.toString().trim() ?? '',
      status: raw['status']?.toString() ?? 'running',
      uptimeSeconds: raw['uptime_seconds'] is num
          ? (raw['uptime_seconds'] as num).toInt()
          : null,
      output: tail.isNotEmpty ? tail : raw['output_preview']?.toString() ?? '',
      exitCode: raw['exit_code'] is num
          ? (raw['exit_code'] as num).toInt()
          : null,
    );
  }
}

/// The JSON-RPC calls behind the Execution screen.
class HmExecutionSource {
  HmExecutionSource({required this.rpc, this.scope});
  final HmRpc rpc;

  /// `params['profile']`; null keeps the gateway's own profile.
  final String? scope;

  Future<Map<String, dynamic>> _call(String m, Map<String, dynamic> p) =>
      rpc(m, scope == null ? p : {...p, 'profile': scope});

  Future<List<HmProcess>> processes(String sessionId) async {
    final r = await _call('process.list', {'session_id': sessionId});
    final rows = r['processes'];
    return [
      if (rows is List)
        for (final p in rows) ?HmProcess.parse(p),
    ];
  }

  /// Kills one process; throws when the host could not.
  Future<void> kill(String sessionId, String processId) async {
    final r = await _call('process.kill', {
      'session_id': sessionId,
      'process_id': processId,
    });
    final status = r['status']?.toString();
    if (status == 'error' || status == 'not_found') {
      throw StateError(r['error']?.toString() ?? 'Could not stop the process');
    }
  }

  Future<bool> spawnPaused() async =>
      (await _call('delegation.status', {}))['paused'] == true;

  Future<bool> setSpawnPaused(bool paused) async =>
      (await _call('delegation.pause', {'paused': paused}))['paused'] == true;

  Future<void> interrupt(String sessionId, String subagentId) async {
    final r = await _call('subagent.interrupt', {
      'session_id': sessionId,
      'subagent_id': subagentId,
    });
    if (r['found'] != true) {
      throw StateError('Could not interrupt the subagent');
    }
  }

  Future<void> steer(String sessionId, String subagentId, String text) async {
    final r = await _call('subagent.steer', {
      'session_id': sessionId,
      'subagent_id': subagentId,
      'text': text,
    });
    if (r['status'] != 'queued') {
      throw StateError('Could not send guidance to the subagent');
    }
  }

  Future<Map<String, dynamic>> control(
    String sessionId,
    NgControlAction action,
  ) => _call('session.control', {
    'session_id': sessionId,
    'action': action.wire,
  });
}

class HmExecutionPage extends StatefulWidget {
  const HmExecutionPage({
    super.key,
    required this.chat,
    required this.source,
    this.poll = const Duration(seconds: 5),
  });

  final NgChatController chat;
  final HmExecutionSource source;
  final Duration poll;

  @override
  State<HmExecutionPage> createState() => _HmExecutionPageState();
}

class _HmExecutionPageState extends State<HmExecutionPage> {
  List<HmProcess>? _processes;
  Object? _processError;
  bool? _spawnPaused;
  bool _spawnBusy = false;
  NgControlAction? _goalBusy;

  /// The snapshot a control action answered with, until the chat's own
  /// state moves past it.
  NgSessionControl? _control;
  NgSessionControl? _controlBase;

  /// Ids of processes / subagents with an action in flight.
  final Set<String> _busy = {};
  Timer? _timer;

  NgChatController get _chat => widget.chat;
  String? get _session => _chat.runtimeId;

  @override
  void initState() {
    super.initState();
    _chat.addListener(_onChat);
    if (_session != null) {
      unawaited(_chat.refreshControl());
      unawaited(_chat.refreshSubagents());
      unawaited(_loadProcesses());
      unawaited(_loadSpawn());
      _timer = Timer.periodic(widget.poll, (_) => _loadProcesses());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _chat.removeListener(_onChat);
    super.dispose();
  }

  void _onChat() {
    if (mounted) setState(() {});
  }

  NgSessionControl? get _shownControl =>
      _control != null && identical(_chat.control, _controlBase)
      ? _control
      : _chat.control;

  Future<void> _loadProcesses() async {
    final id = _session;
    if (id == null) return;
    try {
      final list = await widget.source.processes(id);
      if (!mounted) return;
      setState(() {
        _processes = list;
        _processError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _processError = e;
      });
    }
  }

  Future<void> _loadSpawn() async {
    try {
      final paused = await widget.source.spawnPaused();
      if (mounted) setState(() => _spawnPaused = paused);
    } catch (_) {
      // An older host has no delegation controls; the toggle stays hidden.
    }
  }

  Future<void> _stopProcess(HmProcess p) async {
    final id = _session;
    if (id == null || _busy.contains(p.id)) return;
    setState(() => _busy.add(p.id));
    try {
      await widget.source.kill(id, p.id);
      if (mounted) hmWorkSnack(context, 'Stopped 1 background process.');
      await _loadProcesses();
    } catch (_) {
      if (mounted) hmWorkSnack(context, 'Could not stop the process');
    } finally {
      if (mounted) setState(() => _busy.remove(p.id));
    }
  }

  Future<void> _toggleSpawn() async {
    final paused = _spawnPaused;
    if (paused == null || _spawnBusy) return;
    if (_session == null) {
      hmWorkSnack(
        context,
        'Reconnect this conversation to control its subagents.',
      );
      return;
    }
    setState(() => _spawnBusy = true);
    try {
      final now = await widget.source.setSpawnPaused(!paused);
      if (!mounted) return;
      setState(() => _spawnPaused = now);
      hmWorkSnack(context, now ? 'New subagents paused' : 'Subagents resumed');
    } catch (_) {
      if (mounted) {
        hmWorkSnack(
          context,
          paused
              ? 'Could not resume subagents'
              : 'Could not pause new subagents',
        );
      }
    } finally {
      if (mounted) setState(() => _spawnBusy = false);
    }
  }

  Future<void> _interrupt(NgSubagent a) async {
    final id = _session;
    if (id == null) {
      hmWorkSnack(
        context,
        'Reconnect this conversation to control its subagents.',
      );
      return;
    }
    if (_busy.contains(a.id)) return;
    setState(() => _busy.add(a.id));
    try {
      await widget.source.interrupt(id, a.id);
    } catch (_) {
      if (mounted) hmWorkSnack(context, 'Could not interrupt the subagent');
    } finally {
      if (mounted) setState(() => _busy.remove(a.id));
    }
  }

  Future<void> _guide(NgSubagent a) async {
    final id = _session;
    if (id == null) {
      hmWorkSnack(
        context,
        'Reconnect this conversation to control its subagents.',
      );
      return;
    }
    final text = await showHmWorkSheet<String>(
      context,
      builder: (_) => const _GuidanceSheet(),
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    setState(() => _busy.add(a.id));
    try {
      await widget.source.steer(id, a.id, text.trim());
      if (mounted) hmWorkSnack(context, 'Guidance sent');
    } catch (_) {
      if (mounted) {
        hmWorkSnack(context, 'Could not send guidance to the subagent');
      }
    } finally {
      if (mounted) setState(() => _busy.remove(a.id));
    }
  }

  Future<void> _goal(NgControlAction action) async {
    final id = _session;
    if (id == null) {
      hmWorkSnack(context, 'Reconnect this conversation to change its goal.');
      return;
    }
    if (_goalBusy != null) return;
    if (action == NgControlAction.goalClear) {
      final ok = await hmWorkConfirm(
        context,
        title: 'Clear the goal?',
        confirm: 'Clear Goal',
        danger: true,
      );
      if (!ok || !mounted) return;
    }
    final (done, failed) = switch (action) {
      NgControlAction.goalPause => (
        'Goal paused.',
        'Could not pause the goal.',
      ),
      NgControlAction.goalResume => (
        'Goal resumed.',
        'Could not resume the goal.',
      ),
      _ => ('Goal cleared.', 'Could not clear the goal.'),
    };
    setState(() => _goalBusy = action);
    try {
      final result = await widget.source.control(id, action);
      if (!mounted) return;
      if (result.containsKey('control')) {
        _controlBase = _chat.control;
        _control =
            NgSessionControl.parse(result['control']) ??
            const NgSessionControl();
      }
      // A resumed goal's kickoff goes out as the next prompt.
      final dispatch = result['dispatch'];
      if (dispatch is Map && dispatch['type'] == 'send') {
        final message = dispatch['message']?.toString().trim() ?? '';
        if (message.isNotEmpty) {
          if (_chat.running) {
            _chat.enqueue(message);
          } else {
            unawaited(_chat.send(message));
          }
        }
      }
      hmWorkSnack(context, done);
    } catch (_) {
      if (mounted) hmWorkSnack(context, failed);
    } finally {
      if (mounted) setState(() => _goalBusy = null);
    }
  }

  void _showOutput(HmProcess p) {
    showHmWorkSheet<void>(
      context,
      builder: (sheet) {
        final c = NgColors.of(sheet);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Background process',
                  style: HmType.screenTitle.copyWith(color: c.text),
                ),
                const SizedBox(height: 6),
                Text(
                  p.command,
                  style: HmType.value.copyWith(
                    color: c.text2,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(sheet).size.height * 0.5,
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: c.well,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: SingleChildScrollView(
                      reverse: true,
                      child: SelectableText(
                        p.output,
                        style: HmType.caption.copyWith(
                          color: c.text,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                ),
                if (p.running) ...[
                  const SizedBox(height: 8),
                  HmPrimaryButton(
                    label: 'Stop background process',
                    trailingIcon: null,
                    onPressed: () {
                      Navigator.pop(sheet);
                      _stopProcess(p);
                    },
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  void _showSubagent(NgSubagent a) {
    showHmWorkSheet<void>(
      context,
      builder: (sheet) {
        final c = NgColors.of(sheet);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  a.goal.isEmpty ? 'Subagent run' : a.goal,
                  style: HmType.row.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  [
                    _subagentStatus(a.status),
                    ?a.model,
                    if (a.toolCount != null) '${a.toolCount} tools',
                  ].join(' · '),
                  style: HmType.value.copyWith(color: c.text3),
                ),
                if (a.summary != null || a.activity.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(sheet).size.height * 0.4,
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        a.summary ?? a.activity.join('\n'),
                        style: HmType.caption.copyWith(color: c.text2),
                      ),
                    ),
                  ),
                ],
                if (a.status.live) ...[
                  const SizedBox(height: 8),
                  HmRow(
                    icon: Icons.chat_outlined,
                    label: 'Send guidance…',
                    chevron: false,
                    onTap: () {
                      Navigator.pop(sheet);
                      _guide(a);
                    },
                  ),
                  HmRow(
                    icon: Icons.stop_circle_outlined,
                    label: 'Stop current task',
                    danger: true,
                    chevron: false,
                    onTap: () {
                      Navigator.pop(sheet);
                      _interrupt(a);
                    },
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final goal = _shownControl?.goal;
    final todos = _chat.todos;
    final agents = _chat.subagents.reversed.toList();
    final procs = _processes ?? const <HmProcess>[];
    final hasTodos = todos != null && todos.items.isNotEmpty;
    final nothing =
        goal == null && !hasTodos && agents.isEmpty && procs.isEmpty;
    final children = <Widget>[];

    if (nothing) {
      if (_session != null && _processes == null && _processError == null) {
        children.add(const HmWorkLoading());
      } else if (_processError != null && _processes == null) {
        children.add(
          HmWorkEmpty(
            icon: Icons.cloud_off_outlined,
            body: hmWorkError(_processError!),
            action: 'Try Again',
            actionIcon: Icons.refresh,
            onAction: _loadProcesses,
          ),
        );
      } else {
        children.add(
          const HmWorkEmpty(
            icon: Icons.bolt_outlined,
            title: 'No Execution Activity',
            body:
                'Goals, tasks, subagents, and terminal processes will appear here.',
          ),
        );
      }
    } else {
      if (goal != null) children.addAll(_goalSection(c, goal));
      if (hasTodos) children.addAll(_todoSection(c, todos));
      if (agents.isNotEmpty) children.addAll(_subagentSection(c, agents));
      if (procs.isNotEmpty) children.addAll(_processSection(c, procs));
    }

    return Scaffold(
      backgroundColor: c.background,
      body: Column(
        children: [
          const HmTopBar(leading: HmBackButton(), title: 'Execution'),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                await Future.wait([
                  _loadProcesses(),
                  _chat.refreshSubagents(),
                  _chat.refreshControl(),
                ]);
              },
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(top: 4, bottom: 32),
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _goalSection(NgColors c, NgGoal goal) {
    final phase = goal.phase;
    final canPause =
        phase == NgGoalPhase.active || phase == NgGoalPhase.waiting;
    final canResume =
        phase == NgGoalPhase.paused || phase == NgGoalPhase.blocked;
    final turns = goal.maxTurns > 0
        ? '${goal.turnsUsed}/${goal.maxTurns}'
        : '${goal.turnsUsed}';
    Widget action(
      NgControlAction a,
      IconData icon,
      String label, {
      bool danger = false,
    }) => HmRow(
      icon: icon,
      label: label,
      danger: danger,
      chevron: false,
      trailing: _goalBusy == a ? const HmWorkBusy() : null,
      onTap: _goalBusy == null ? () => _goal(a) : null,
    );
    return [
      const HmSection('Goal'),
      HmGroup(
        children: [
          HmRow(
            icon: Icons.flag_outlined,
            label: goal.title,
            value: _goalPhase(phase),
            subValue: turns,
            tall: true,
            chevron: false,
          ),
          for (final s in goal.subgoals)
            HmRow(
              icon: Icons.subdirectory_arrow_right,
              label: s,
              chevron: false,
            ),
          if (goal.pausedReason != null && phase == NgGoalPhase.paused)
            HmRow(label: goal.pausedReason!, chevron: false),
        ],
      ),
      const HmSection('Goal controls'),
      HmGroup(
        children: [
          if (canPause) action(NgControlAction.goalPause, Icons.pause, 'Pause'),
          if (canResume)
            action(NgControlAction.goalResume, Icons.play_arrow, 'Resume'),
          action(
            NgControlAction.goalClear,
            Icons.clear,
            'Clear Goal',
            danger: true,
          ),
        ],
      ),
    ];
  }

  List<Widget> _todoSection(NgColors c, NgTodoList todos) => [
    HmSection('Task progress · ${todos.done}/${todos.total}'),
    HmGroup(
      children: [
        for (final (item, depth) in todos.tree())
          Padding(
            padding: EdgeInsets.only(left: depth * 20.0),
            child: HmRow(
              icon: switch (item.status) {
                NgTodoStatus.completed => Icons.check_circle,
                NgTodoStatus.inProgress => Icons.timelapse,
                NgTodoStatus.cancelled => Icons.cancel_outlined,
                NgTodoStatus.pending => Icons.radio_button_unchecked,
              },
              label: item.content,
              value: item.status == NgTodoStatus.inProgress
                  ? 'In Progress'
                  : null,
              chevron: false,
            ),
          ),
      ],
    ),
  ];

  List<Widget> _subagentSection(NgColors c, List<NgSubagent> agents) => [
    const HmSection('Subagents'),
    HmGroup(
      children: [
        for (final a in agents)
          HmRow(
            icon: switch (a.status) {
              NgSubagentStatus.done => Icons.check_circle_outline,
              NgSubagentStatus.failed => Icons.error_outline,
              NgSubagentStatus.interrupted => Icons.stop_circle_outlined,
              _ => Icons.smart_toy_outlined,
            },
            label: a.goal.isEmpty ? 'Subagent run' : a.goal,
            subValue: a.status.live
                ? (a.current ?? _subagentStatus(a.status))
                : _subagentStatus(a.status),
            tall: true,
            onTap: () => _showSubagent(a),
            trailing: !a.status.live
                ? null
                : _busy.contains(a.id)
                ? const Padding(
                    padding: EdgeInsets.only(left: 12),
                    child: HmWorkBusy(),
                  )
                : IconButton(
                    tooltip: 'Stop current task',
                    icon: Icon(Icons.stop_circle_outlined, color: c.danger),
                    onPressed: () => _interrupt(a),
                  ),
          ),
        if (_spawnPaused != null)
          HmRow(
            icon: _spawnPaused! ? Icons.play_arrow : Icons.pause,
            label: _spawnPaused! ? 'Resume Subagents' : 'Pause New Subagents',
            chevron: false,
            trailing: _spawnBusy ? const HmWorkBusy() : null,
            onTap: _spawnBusy ? null : _toggleSpawn,
          ),
      ],
    ),
  ];

  List<Widget> _processSection(NgColors c, List<HmProcess> procs) => [
    const HmSection('Processes'),
    HmGroup(
      children: [
        for (final p in procs)
          HmRow(
            icon: Icons.terminal,
            label: p.command.isEmpty ? p.id : p.command,
            subValue: [
              p.running ? 'Running' : p.status,
              if (p.uptimeSeconds != null) _uptime(p.uptimeSeconds!),
              if (p.exitCode != null) 'exit ${p.exitCode}',
            ].join(' · '),
            tall: true,
            onTap: () => _showOutput(p),
            trailing: !p.running
                ? null
                : _busy.contains(p.id)
                ? const Padding(
                    padding: EdgeInsets.only(left: 12),
                    child: HmWorkBusy(),
                  )
                : IconButton(
                    tooltip: 'Stop background process',
                    icon: Icon(Icons.stop_circle_outlined, color: c.danger),
                    onPressed: () => _stopProcess(p),
                  ),
          ),
      ],
    ),
  ];
}

String _goalPhase(NgGoalPhase p) => switch (p) {
  NgGoalPhase.active => 'Active',
  NgGoalPhase.paused => 'Paused',
  NgGoalPhase.waiting => 'Waiting',
  NgGoalPhase.blocked => 'Blocked',
  NgGoalPhase.done => 'Done',
};

String _subagentStatus(NgSubagentStatus s) => switch (s) {
  NgSubagentStatus.queued => 'Queued',
  NgSubagentStatus.running => 'Running',
  NgSubagentStatus.done => 'Done',
  NgSubagentStatus.failed => 'Failed',
  NgSubagentStatus.interrupted => 'Interrupted',
};

String _uptime(int s) {
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m';
  return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
}

class _GuidanceSheet extends StatefulWidget {
  const _GuidanceSheet();

  @override
  State<_GuidanceSheet> createState() => _GuidanceSheetState();
}

class _GuidanceSheetState extends State<_GuidanceSheet> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Send guidance to the subagent',
            style: HmType.screenTitle.copyWith(color: c.text),
          ),
          const SizedBox(height: 14),
          HmWorkField(
            fieldKey: const Key('guidance'),
            controller: _text,
            label: 'Send guidance…',
            maxLines: 5,
            autofocus: true,
          ),
          const SizedBox(height: 8),
          HmPrimaryButton(
            label: 'Send message',
            trailingIcon: null,
            onPressed: () => Navigator.pop(context, _text.text),
          ),
        ],
      ),
    );
  }
}
