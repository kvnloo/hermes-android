// Projects: conversations, repositories and worktrees grouped by project.
//
// Reads `GET /api/profiles/projects/tree?profile=<bot>` (the same tree the
// official app and Desktop read) and writes through the gateway's
// `projects.*` JSON-RPC family, scoped to the bot's profile.
import 'package:flutter/material.dart';

import '../../../core/models/project_sessions_tree.dart';
import '../../../core/models/session.dart';
import '../../../core/models/projects_tree_overview.dart';
import '../../../core/services/dashboard_api_client.dart';
import '../../../nextgen/theme/nextgen_theme.dart';
import '../../hm_bots.dart';
import '../../hm_ui.dart';
import '../../screens/hm_chat_screen.dart' show HmMenuItem, showHmMenu;
import '../../screens/hm_home.dart' show hmOpenChat;
import 'hm_work_kit.dart';

Future<void> openHmProjects(
  BuildContext context, {
  required HmBot bot,
  required HmBotsModel bots,
}) {
  final gateway = bots.gateway;
  final source = HmProjectsSource(
    profile: bot.profile,
    scope: bot.scope,
    request: (m, e, {body, query}) =>
        gateway.dashboard.apiRequest(m, e, body: body, queryParameters: query),
    rpc: gateway.call,
  );
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => HmProjectsPage(
        source: source,
        onOpenChat: (context, s) => hmOpenChat(
          context,
          bot: bot,
          bots: bots,
          sessionId: s.id,
          title: s.title,
        ),
      ),
    ),
  );
}

/// Opens one of a project's conversations.
typedef HmOpenProjectChat =
    Future<void> Function(BuildContext context, Session session);

/// The bot's projects over REST (read) and JSON-RPC (writes).
class HmProjectsSource {
  HmProjectsSource({
    required this.profile,
    required this.scope,
    required this.request,
    required this.rpc,
  });

  /// Host profile name, sent as `?profile=` so the tree covers only this bot.
  final String profile;

  /// `params['profile']` for RPCs; null keeps the gateway's own profile.
  final String? scope;
  final HmDashRequest request;
  final HmRpc rpc;

  Map<String, dynamic> _scoped(Map<String, dynamic> p) =>
      scope == null ? p : {...p, 'profile': scope};

  Future<ProjectsTreeOverview> tree() async => ProjectsTreeOverview.fromJson(
    await hmDashJson(
      request,
      'GET',
      'profiles/projects/tree',
      query: {'profile': profile, 'preview_limit': '5'},
    ),
  );

  Future<void> create({required String name, String? folder}) => rpc(
    'projects.create',
    _scoped({
      'name': name,
      if (folder != null) 'folders': [folder],
      'primary_path': ?folder,
    }),
  );

  Future<void> rename(String id, String name) =>
      rpc('projects.update', _scoped({'id': id, 'name': name}));

  Future<void> delete(String id) => rpc('projects.delete', _scoped({'id': id}));
}

class HmProjectsPage extends StatefulWidget {
  const HmProjectsPage({super.key, required this.source, this.onOpenChat});
  final HmProjectsSource source;
  final HmOpenProjectChat? onOpenChat;

  @override
  State<HmProjectsPage> createState() => _HmProjectsPageState();
}

class _HmProjectsPageState extends State<HmProjectsPage> {
  ProjectsTreeOverview? _tree;
  Object? _error;
  bool _loading = true;

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
      final tree = await widget.source.tree();
      if (!mounted) return;
      setState(() {
        _tree = tree;
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

  Future<void> _create() async {
    final made = await showHmWorkSheet<bool>(
      context,
      builder: (_) => _ProjectSheet(source: widget.source),
    );
    if (made == true) await _load();
  }

  Future<void> _open(ProjectOverviewNode p) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => HmProjectPage(
          project: p,
          source: widget.source,
          onOpenChat: widget.onOpenChat,
        ),
      ),
    );
    if (changed == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final projects = _tree?.userProjects ?? const <ProjectOverviewNode>[];
    final List<Widget> body;
    if (_loading && _tree == null) {
      body = const [HmWorkLoading()];
    } else if (_error != null) {
      final unavailable =
          _error is DashboardRequestException &&
          (_error as DashboardRequestException).statusCode == 404;
      body = [
        HmWorkEmpty(
          icon: Icons.folder_off_outlined,
          title: 'Projects unavailable',
          body: unavailable
              ? 'Connect this install to view its projects.'
              : hmWorkError(_error!),
          action: unavailable ? null : 'Try Again',
          actionIcon: Icons.refresh,
          onAction: unavailable ? null : _load,
        ),
      ];
    } else if (projects.isEmpty) {
      body = const [
        HmWorkEmpty(
          icon: Icons.create_new_folder_outlined,
          title: 'No projects yet',
          body:
              'Create a project to group conversations, repositories, and worktrees.',
        ),
      ];
    } else {
      body = [
        HmGroup(
          children: [
            for (final p in projects)
              HmRow(
                icon: Icons.folder_outlined,
                label: p.label,
                value: '${p.sessionCount}',
                subValue: p.path,
                tall: p.path != null,
                onTap: () => _open(p),
              ),
          ],
        ),
      ];
    }
    return Scaffold(
      backgroundColor: c.background,
      body: Column(
        children: [
          HmTopBar(
            leading: const HmBackButton(),
            title: 'Projects',
            trailing: [
              HmRoundButton(
                icon: Icons.add,
                label: 'New Project',
                onPressed: _create,
              ),
            ],
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(top: 12, bottom: 32),
                children: body,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Create (no [project]) or rename one project.
class _ProjectSheet extends StatefulWidget {
  const _ProjectSheet({required this.source, this.project});
  final HmProjectsSource source;
  final ProjectOverviewNode? project;

  @override
  State<_ProjectSheet> createState() => _ProjectSheetState();
}

class _ProjectSheetState extends State<_ProjectSheet> {
  late final _name = TextEditingController(text: widget.project?.label);
  final _folder = TextEditingController();
  String? _nameError;
  String? _folderError;
  String? _error;
  bool _busy = false;

  bool get _editing => widget.project != null;

  @override
  void dispose() {
    _name.dispose();
    _folder.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final folder = _folder.text.trim();
    setState(() {
      _nameError = name.isEmpty ? 'Give the project a name.' : null;
      _folderError =
          folder.isNotEmpty &&
              !folder.startsWith('/') &&
              !folder.startsWith('~/')
          ? 'Enter a folder that begins with / or ~/.'
          : null;
      _error = null;
    });
    if (_nameError != null || _folderError != null) return;
    setState(() => _busy = true);
    try {
      if (_editing) {
        await widget.source.rename(widget.project!.id, name);
      } else {
        await widget.source.create(
          name: name,
          folder: folder.isEmpty ? null : folder,
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
            _editing ? 'Edit Project' : 'New Project',
            style: HmType.screenTitle.copyWith(color: c.text),
          ),
          const SizedBox(height: 14),
          HmWorkField(
            fieldKey: const Key('project-name'),
            controller: _name,
            label: 'Name',
            hint: 'My project',
            error: _nameError,
            autofocus: true,
          ),
          if (!_editing) ...[
            HmWorkField(
              fieldKey: const Key('project-folder'),
              controller: _folder,
              label: 'Folder path',
              error: _folderError,
            ),
          ],
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
            label: _editing ? 'Save' : 'Create Project',
            trailingIcon: null,
            busy: _busy,
            onPressed: _save,
          ),
        ],
      ),
    );
  }
}

enum _ProjectAction { edit, delete }

/// One project: its repositories, worktrees and recent conversations.
class HmProjectPage extends StatefulWidget {
  const HmProjectPage({
    super.key,
    required this.project,
    required this.source,
    this.onOpenChat,
  });
  final ProjectOverviewNode project;
  final HmProjectsSource source;
  final HmOpenProjectChat? onOpenChat;

  @override
  State<HmProjectPage> createState() => _HmProjectPageState();
}

class _HmProjectPageState extends State<HmProjectPage> {
  late ProjectOverviewNode _project = widget.project;
  bool _changed = false;
  bool _busy = false;

  Future<void> _actions() async {
    final action = await showHmMenu<_ProjectAction>(
      context,
      groups: [
        [
          const HmMenuItem(
            _ProjectAction.edit,
            Icons.edit_outlined,
            'Edit Project',
          ),
        ],
        [
          const HmMenuItem(
            _ProjectAction.delete,
            Icons.delete_outline,
            'Delete Project',
            danger: true,
          ),
        ],
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _ProjectAction.edit:
        final done = await showHmWorkSheet<bool>(
          context,
          builder: (_) =>
              _ProjectSheet(source: widget.source, project: _project),
        );
        if (done == true && mounted) {
          _changed = true;
          final fresh = await widget.source.tree().catchError(
            (_) => ProjectsTreeOverview.empty,
          );
          final match = fresh.projects
              .where((p) => p.id == _project.id)
              .firstOrNull;
          if (mounted && match != null) setState(() => _project = match);
        }
      case _ProjectAction.delete:
        final ok = await hmWorkConfirm(
          context,
          title: 'Delete Project',
          body:
              'The project is removed from Projects. Its conversations and files stay on the server.',
          confirm: 'Delete Project',
          danger: true,
        );
        if (!ok || !mounted) return;
        setState(() => _busy = true);
        try {
          await widget.source.delete(_project.id);
          if (mounted) Navigator.of(context).pop(true);
        } catch (e) {
          if (!mounted) return;
          setState(() => _busy = false);
          hmWorkSnack(context, hmWorkError(e));
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final p = _project;
    final repos = p.repos;
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        backgroundColor: c.background,
        body: Column(
          children: [
            HmTopBar(
              leading: HmBackButton(
                onPressed: () => Navigator.of(context).pop(_changed),
              ),
              title: p.label,
              trailing: [
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.all(14),
                    child: HmWorkBusy(),
                  )
                else if (p.isUserOwned)
                  HmRoundButton(
                    icon: Icons.more_horiz,
                    label: 'Project actions',
                    onPressed: _actions,
                  ),
              ],
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(top: 4, bottom: 32),
                children: [
                  if (p.path != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(32, 4, 32, 0),
                      child: Text(
                        p.path!,
                        style: HmType.value.copyWith(color: c.text3),
                      ),
                    ),
                  for (final repo in repos) ..._repo(repo),
                  if (p.previewSessions.isEmpty && p.sessionCount == 0)
                    const HmWorkEmpty(
                      icon: Icons.forum_outlined,
                      body:
                          "Conversations started in this project's folder will appear here.",
                    )
                  else ...[
                    const HmSection('Recent'),
                    HmGroup(
                      children: [
                        for (final s in p.previewSessions)
                          HmRow(
                            icon: Icons.chat_bubble_outline,
                            label: s.title,
                            subValue: s.preview.isEmpty ? null : s.preview,
                            onTap: widget.onOpenChat == null
                                ? null
                                : () => widget.onOpenChat!(context, s),
                          ),
                        if (p.sessionCount > p.previewSessions.length)
                          HmRow(
                            label: 'Conversations',
                            value: '${p.sessionCount}',
                            chevron: false,
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _repo(ProjectRepo repo) => [
    HmSection(repo.label),
    HmGroup(
      children: [
        HmRow(
          icon: Icons.source_outlined,
          label: repo.path ?? repo.label,
          value: '${repo.sessionCount}',
          chevron: false,
        ),
        for (final lane in repo.lanes.where((l) => !l.isMain))
          HmRow(
            icon: lane.isKanban
                ? Icons.view_kanban_outlined
                : Icons.account_tree_outlined,
            label: lane.label,
            subValue: lane.path,
            chevron: false,
          ),
      ],
    ),
  ];
}
