// Kanban: the host's boards and tasks (the dashboard's kanban plugin).
//
// One board at a time, titled by its name with a switcher; tasks grouped
// by status column, searchable; a task opens its details, where it can be
// moved, edited or deleted. Boards are host-wide, so every bot of a host
// sees the same ones.
import 'package:flutter/material.dart';

import '../../../core/services/dashboard_api_client.dart';
import '../../../nextgen/theme/nextgen_theme.dart';
import '../../hm_bots.dart';
import '../../hm_ui.dart';
import '../../screens/hm_chat_screen.dart' show HmMenuItem, showHmMenu;
import 'hm_kanban_data.dart';
import 'hm_work_kit.dart';

Future<void> openHmKanban(
  BuildContext context, {
  required HmBot bot,
  required HmBotsModel bots,
}) {
  final dashboard = bots.gateway.dashboard;
  final source = HmKanbanSource(
    (m, e, {body, query}) =>
        dashboard.apiRequest(m, e, body: body, queryParameters: query),
  );
  return Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => HmKanbanPage(source: source)));
}

class HmKanbanPage extends StatefulWidget {
  const HmKanbanPage({super.key, required this.source});
  final HmKanbanSource source;

  @override
  State<HmKanbanPage> createState() => _HmKanbanPageState();
}

enum _BoardAction { create, archive }

class _HmKanbanPageState extends State<HmKanbanPage> {
  HmKanbanBoards? _boards;
  HmKanbanBoardRow? _selected;
  HmKanbanBoard? _board;
  Object? _error;
  bool _loading = true;
  bool _showArchived = false;
  final _search = TextEditingController();

  HmKanbanSource get _src => widget.source;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Reloads the board list and the open board ([slug] picks another).
  Future<void> _load({String? slug}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final boards = await _src.boards();
      final want = slug ?? _selected?.slug;
      final selected =
          boards.boards.where((b) => b.slug == want).firstOrNull ??
          boards.initial;
      final board = selected == null
          ? null
          : await _src.board(selected.slug, archived: _showArchived);
      if (!mounted) return;
      setState(() {
        _boards = boards;
        _selected = selected;
        _board = board;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// Reloads only the open board after a write; says so when that fails.
  Future<void> _reloadAfterSave() async {
    final slug = _selected?.slug;
    if (slug == null) return;
    try {
      final board = await _src.board(slug, archived: _showArchived);
      if (mounted) setState(() => _board = board);
    } catch (_) {
      if (mounted) {
        hmWorkSnack(
          context,
          'Saved, but the latest board couldn’t be loaded. Pull to refresh.',
        );
      }
    }
  }

  Future<void> _addTask() async {
    final slug = _selected?.slug;
    if (slug == null) return;
    final added = await showHmWorkSheet<bool>(
      context,
      builder: (_) => _TaskSheet(source: _src, board: slug),
    );
    if (added != true || !mounted) return;
    hmWorkSnack(context, 'Task added');
    await _reloadAfterSave();
  }

  Future<void> _openTask(HmKanbanTask task) async {
    final slug = _selected?.slug;
    if (slug == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            HmKanbanTaskPage(source: _src, board: slug, taskId: task.id),
      ),
    );
    if (changed == true) await _reloadAfterSave();
  }

  Future<void> _chooseBoard() async {
    final boards = _boards?.boards ?? const <HmKanbanBoardRow>[];
    final picked = await showHmWorkSheet<String>(
      context,
      builder: (sheet) {
        final c = NgColors.of(sheet);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                child: Text(
                  'Choose board',
                  style: HmType.screenTitle.copyWith(color: c.text),
                ),
              ),
              for (final b in boards)
                HmRow(
                  icon: b.slug == _selected?.slug
                      ? Icons.check
                      : Icons.view_kanban_outlined,
                  label: b.name,
                  value: '${b.total}',
                  chevron: false,
                  onTap: () => Navigator.pop(sheet, b.slug),
                ),
              HmRow(
                icon: Icons.add,
                label: 'New Board',
                chevron: false,
                onTap: () => Navigator.pop(sheet, ''),
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
    if (!mounted || picked == null) return;
    if (picked.isEmpty) {
      await _createBoard();
    } else if (picked != _selected?.slug) {
      await _load(slug: picked);
    }
  }

  Future<void> _createBoard() async {
    final slug = await showHmWorkSheet<String>(
      context,
      builder: (_) => _BoardSheet(source: _src),
    );
    if (slug != null && mounted) await _load(slug: slug);
  }

  Future<void> _boardActions() async {
    final board = _selected;
    final action = await showHmMenu<_BoardAction>(
      context,
      groups: [
        [const HmMenuItem(_BoardAction.create, Icons.add, 'New Board')],
        if (board != null && !board.isDefault)
          [
            const HmMenuItem(
              _BoardAction.archive,
              Icons.archive_outlined,
              'Archive Board',
              danger: true,
            ),
          ],
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _BoardAction.create:
        await _createBoard();
      case _BoardAction.archive:
        final ok = await hmWorkConfirm(
          context,
          title: 'Archive this board?',
          body:
              'Tasks stay in Hermes, but this board disappears from the active board list.',
          confirm: 'Archive Board',
          danger: true,
        );
        if (!ok || !mounted || board == null) return;
        try {
          await _src.archiveBoard(board.slug);
          _selected = null;
          await _load();
        } catch (e) {
          if (mounted) hmWorkSnack(context, hmWorkError(e));
        }
    }
  }

  Future<void> _filter() async {
    final next = await showHmWorkSheet<bool>(
      context,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: HmSwitchRow(
            icon: Icons.archive_outlined,
            label: 'Show Archived',
            value: _showArchived,
            onChanged: (v) => Navigator.pop(sheet, v),
          ),
        ),
      ),
    );
    if (next == null || next == _showArchived || !mounted) return;
    setState(() => _showArchived = next);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final hasBoard = _board != null && _selected != null;
    return Scaffold(
      backgroundColor: c.background,
      floatingActionButton: hasBoard
          ? FloatingActionButton(
              tooltip: 'New Task',
              backgroundColor: c.accentSoft,
              foregroundColor: c.accentText,
              shape: const CircleBorder(),
              onPressed: _addTask,
              child: const Icon(Icons.add),
            )
          : null,
      body: Column(
        children: [
          HmTopBar(
            leading: const HmBackButton(),
            center: hasBoard ? _boardTitle(c) : null,
            title: hasBoard ? null : 'Kanban',
            trailing: [if (hasBoard) _actionsPill(c)],
          ),
          if (hasBoard) _searchField(c),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(top: 8, bottom: 96),
                children: _body(c),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _boardTitle(NgColors c) => Semantics(
    button: true,
    label: 'Choose board',
    child: InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: _chooseBoard,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                _selected!.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HmType.screenTitle.copyWith(color: c.text),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: c.surface2,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.expand_more, size: 20, color: c.text3),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _actionsPill(NgColors c) => Container(
    height: HmMetrics.roundButton,
    decoration: BoxDecoration(
      color: c.surface,
      borderRadius: BorderRadius.circular(HmMetrics.roundButton / 2),
      boxShadow: hmShadow(c),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: _showArchived
              ? 'Filter tasks, filters applied'
              : 'Filter tasks',
          icon: Icon(
            Icons.filter_list,
            color: _showArchived ? c.accent : c.text,
          ),
          onPressed: _filter,
        ),
        IconButton(
          tooltip: 'Board actions',
          icon: Icon(Icons.more_horiz, color: c.text),
          onPressed: _boardActions,
        ),
      ],
    ),
  );

  Widget _searchField(NgColors c) => Padding(
    padding: const EdgeInsets.fromLTRB(HmMetrics.edge, 4, HmMetrics.edge, 4),
    child: TextField(
      controller: _search,
      style: HmType.value.copyWith(color: c.text, fontSize: 17),
      decoration: InputDecoration(
        hintText: 'Search tasks',
        prefixIcon: Icon(Icons.search, color: c.text3),
        filled: true,
        fillColor: c.input,
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(30),
          borderSide: BorderSide.none,
        ),
      ),
    ),
  );

  List<Widget> _body(NgColors c) {
    if (_loading && _board == null && _boards == null) {
      return const [HmWorkLoading()];
    }
    if (_error != null) {
      final e = _error;
      if (e is DashboardRequestException && e.statusCode == 404) {
        return const [
          HmWorkEmpty(
            icon: Icons.extension_off_outlined,
            title: 'Kanban Isn’t Available',
            body: "Kanban isn't available on this server.",
          ),
        ];
      }
      return [
        HmWorkEmpty(
          icon: Icons.cloud_off_outlined,
          title: 'Couldn’t Check Kanban',
          body:
              'Hermes Agent couldn’t verify the active Kanban plugin. Check the connection, then try again.',
          action: 'Try Again',
          actionIcon: Icons.refresh,
          onAction: _load,
        ),
      ];
    }
    if (_selected == null || _board == null) {
      return [
        HmWorkEmpty(
          icon: Icons.view_kanban_outlined,
          title: 'No Boards Yet',
          body: 'Create a board to start shaping work into a clear flow.',
          action: 'Create Board',
          onAction: _createBoard,
        ),
      ];
    }
    final board = _board!;
    if (board.total == 0) {
      return [
        const SizedBox(height: 120),
        HmWorkEmpty(
          icon: Icons.auto_awesome,
          title: 'A Clear Board',
          body:
              'Capture the next piece of work, then let Hermes help move it forward.',
          action: 'Add First Task',
          onAction: _addTask,
        ),
      ];
    }
    final q = _search.text.trim();
    final columns = [
      for (final col in board.columns)
        (col, col.tasks.where((t) => t.matches(q)).toList()),
    ].where((e) => e.$2.isNotEmpty).toList();
    if (columns.isEmpty) {
      return const [HmWorkEmpty(icon: Icons.search_off, body: 'No tasks')];
    }
    return [
      for (final (col, tasks) in columns) ...[
        HmSection('${col.label} · ${tasks.length}'),
        HmGroup(children: [for (final t in tasks) _taskRow(t)]),
      ],
    ];
  }

  Widget _taskRow(HmKanbanTask t) {
    final meta = [
      ?t.assignee,
      if (t.childrenTotal != null) '${t.childrenDone}/${t.childrenTotal}',
    ].join(' · ');
    return Semantics(
      hint: 'Open task details',
      child: HmRow(
        label: t.title,
        subValue: meta.isEmpty ? null : meta,
        tall: meta.isNotEmpty,
        onTap: () => _openTask(t),
      ),
    );
  }
}

/// New Task (no [task]) or Edit Task.
class _TaskSheet extends StatefulWidget {
  const _TaskSheet({required this.source, required this.board, this.task});
  final HmKanbanSource source;
  final String board;
  final HmKanbanTask? task;

  @override
  State<_TaskSheet> createState() => _TaskSheetState();
}

class _TaskSheetState extends State<_TaskSheet> {
  late final _title = TextEditingController(text: widget.task?.title);
  late final _body = TextEditingController(text: widget.task?.body);
  String? _titleError;
  String? _error;
  bool _busy = false;

  bool get _editing => widget.task != null;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    final body = _body.text.trim();
    setState(() {
      _titleError = title.isEmpty ? '' : null;
      _error = null;
    });
    if (title.isEmpty) return;
    setState(() => _busy = true);
    try {
      if (_editing) {
        await widget.source.updateTask(
          widget.board,
          widget.task!.id,
          title: title,
          body: body,
        );
      } else {
        await widget.source.createTask(
          widget.board,
          title: title,
          body: body.isEmpty ? null : body,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = hmWorkError(e);
        });
      }
    }
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
            _editing ? 'Edit Task' : 'New Task',
            style: HmType.screenTitle.copyWith(color: c.text),
          ),
          const SizedBox(height: 14),
          HmWorkField(
            fieldKey: const Key('task-title'),
            controller: _title,
            label: 'Title',
            hint: 'Ship the onboarding redesign',
            error: _titleError,
            autofocus: !_editing,
          ),
          HmWorkField(
            fieldKey: const Key('task-body'),
            controller: _body,
            label: 'Description',
            maxLines: 6,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _error!,
                style: HmType.value.copyWith(color: c.danger),
              ),
            ),
          const SizedBox(height: 8),
          HmPrimaryButton(
            label: _editing ? 'Edit Task' : 'Add Task',
            trailingIcon: null,
            busy: _busy,
            onPressed: _save,
          ),
        ],
      ),
    );
  }
}

class _BoardSheet extends StatefulWidget {
  const _BoardSheet({required this.source});
  final HmKanbanSource source;

  @override
  State<_BoardSheet> createState() => _BoardSheetState();
}

class _BoardSheetState extends State<_BoardSheet> {
  final _name = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final slug = await widget.source.createBoard(name);
      if (mounted) Navigator.of(context).pop(slug);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = hmWorkError(e);
        });
      }
    }
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
          Text('New Board', style: HmType.screenTitle.copyWith(color: c.text)),
          const SizedBox(height: 14),
          HmWorkField(
            fieldKey: const Key('board-name'),
            controller: _name,
            label: 'Board name',
            autofocus: true,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _error!,
                style: HmType.value.copyWith(color: c.danger),
              ),
            ),
          const SizedBox(height: 8),
          HmPrimaryButton(
            label: 'Create Board',
            trailingIcon: null,
            busy: _busy,
            onPressed: _save,
          ),
        ],
      ),
    );
  }
}

enum _TaskAction { edit, delete }

/// One task: status (Move to), assignee, description, latest result and
/// comments.
class HmKanbanTaskPage extends StatefulWidget {
  const HmKanbanTaskPage({
    super.key,
    required this.source,
    required this.board,
    required this.taskId,
  });

  final HmKanbanSource source;
  final String board;
  final String taskId;

  @override
  State<HmKanbanTaskPage> createState() => _HmKanbanTaskPageState();
}

class _HmKanbanTaskPageState extends State<HmKanbanTaskPage> {
  HmKanbanTaskDetail? _detail;
  Object? _error;
  bool _loading = true;
  bool _changed = false;
  bool _moving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await widget.source.task(widget.board, widget.taskId);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _close() => Navigator.of(context).pop(_changed);

  Future<void> _move() async {
    final task = _detail?.task;
    if (task == null) return;
    final to = await showHmWorkSheet<String>(
      context,
      builder: (sheet) {
        final c = NgColors.of(sheet);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                child: Text(
                  'Move to',
                  style: HmType.screenTitle.copyWith(color: c.text),
                ),
              ),
              for (final s in hmKanbanMoveTargets)
                if (s != task.status)
                  HmRow(
                    label: hmKanbanLabel(s),
                    chevron: false,
                    onTap: () => Navigator.pop(sheet, s),
                  ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
    if (to == null || !mounted) return;
    setState(() => _moving = true);
    try {
      await widget.source.updateTask(widget.board, task.id, status: to);
      _changed = true;
      if (!mounted) return;
      hmWorkSnack(context, 'Task updated');
      await _load();
    } catch (e) {
      if (mounted) hmWorkSnack(context, hmWorkError(e));
    } finally {
      if (mounted) setState(() => _moving = false);
    }
  }

  Future<void> _actions() async {
    final task = _detail?.task;
    if (task == null) return;
    final action = await showHmMenu<_TaskAction>(
      context,
      groups: [
        [const HmMenuItem(_TaskAction.edit, Icons.edit_outlined, 'Edit Task')],
        [
          const HmMenuItem(
            _TaskAction.delete,
            Icons.delete_outline,
            'Delete Task',
            danger: true,
          ),
        ],
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _TaskAction.edit:
        final saved = await showHmWorkSheet<bool>(
          context,
          builder: (_) => _TaskSheet(
            source: widget.source,
            board: widget.board,
            task: task,
          ),
        );
        if (saved == true && mounted) {
          _changed = true;
          hmWorkSnack(context, 'Task updated');
          await _load();
        }
      case _TaskAction.delete:
        final ok = await hmWorkConfirm(
          context,
          title: 'Delete this task?',
          confirm: 'Delete Task',
          danger: true,
        );
        if (!ok || !mounted) return;
        try {
          await widget.source.deleteTask(widget.board, task.id);
          if (!mounted) return;
          hmWorkSnack(context, 'Task deleted');
          _changed = true;
          _close();
        } catch (e) {
          if (mounted) hmWorkSnack(context, hmWorkError(e));
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final d = _detail;
    final List<Widget> body;
    if (_loading && d == null) {
      body = const [HmWorkLoading()];
    } else if (_error != null || d == null) {
      final gone =
          d == null &&
          (_error == null ||
              (_error is DashboardRequestException &&
                  (_error as DashboardRequestException).statusCode == 404));
      body = [
        HmWorkEmpty(
          icon: Icons.error_outline,
          title: 'Task Unavailable',
          body: gone ? widget.taskId : hmWorkError(_error!),
          action: gone ? null : 'Try Again',
          actionIcon: Icons.refresh,
          onAction: gone ? null : _load,
        ),
      ];
    } else {
      final t = d.task;
      body = [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 4, 32, 8),
          child: Text(t.title, style: HmType.display.copyWith(color: c.text)),
        ),
        HmGroup(
          children: [
            HmRow(
              icon: Icons.view_column_outlined,
              label: 'Move to',
              value: hmKanbanLabel(t.status),
              trailing: _moving
                  ? const Padding(
                      padding: EdgeInsets.only(left: 12),
                      child: HmWorkBusy(),
                    )
                  : null,
              onTap: _moving ? null : _move,
            ),
            if (t.assignee != null)
              HmRow(
                icon: Icons.person_outline,
                label: 'Assignee',
                value: t.assignee,
                chevron: false,
              ),
            if (t.childrenTotal != null)
              HmRow(
                icon: Icons.account_tree_outlined,
                label: 'Task progress',
                value: '${t.childrenDone}/${t.childrenTotal}',
                chevron: false,
              ),
          ],
        ),
        if (t.body != null) _textBlock(c, t.body!),
        if (t.latestSummary != null) _textBlock(c, t.latestSummary!),
        if (d.comments.isNotEmpty) ...[
          const HmSection('Comments'),
          HmGroup(
            children: [
              for (final cm in d.comments)
                HmRow(
                  label: cm.body,
                  subValue: cm.author.isEmpty ? null : cm.author,
                  tall: true,
                  chevron: false,
                ),
            ],
          ),
        ],
      ];
    }
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: c.background,
        body: Column(
          children: [
            HmTopBar(
              leading: HmBackButton(onPressed: _close),
              trailing: [
                if (d != null)
                  HmRoundButton(
                    icon: Icons.more_horiz,
                    label: 'Task actions',
                    onPressed: _actions,
                  ),
              ],
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(top: 8, bottom: 32),
                  children: body,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _textBlock(NgColors c, String text) => Container(
    margin: const EdgeInsets.fromLTRB(HmMetrics.edge, 16, HmMetrics.edge, 0),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: c.surface,
      borderRadius: BorderRadius.circular(HmMetrics.groupRadius),
      border: Border.all(color: c.stroke),
    ),
    child: SelectableText(text, style: HmType.body.copyWith(color: c.text)),
  );
}
