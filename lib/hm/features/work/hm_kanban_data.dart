// Kanban wire shapes and calls: the dashboard's kanban plugin API
// (`plugins/kanban/dashboard/plugin_api.py`, mounted at /api/plugins/kanban).
import 'hm_work_kit.dart';

/// The workflow's status columns, left to right, with their labels
/// (`hermes_cli/kanban_workflow.py::DEFAULT_WORKFLOW`).
const hmKanbanColumns = <String, String>{
  'triage': 'Triage',
  'todo': 'Todo',
  'scheduled': 'Scheduled',
  'ready': 'Ready',
  'running': 'Running',
  'blocked': 'Blocked',
  'review': 'Review',
  'done': 'Done',
  'archived': 'Archived',
};

/// Columns a person may move a task into (the workflow's drag targets).
const hmKanbanMoveTargets = ['triage', 'todo', 'ready', 'blocked', 'done'];

String hmKanbanLabel(String status) =>
    hmKanbanColumns[status] ??
    (status.isEmpty ? status : status[0].toUpperCase() + status.substring(1));

String? _str(Object? v) {
  if (v == null) return null;
  final s = '$v'.trim();
  return s.isEmpty ? null : s;
}

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

class HmKanbanBoardRow {
  const HmKanbanBoardRow({
    required this.slug,
    required this.name,
    this.total = 0,
    this.isCurrent = false,
    this.archived = false,
  });

  final String slug;
  final String name;
  final int total;
  final bool isCurrent;
  final bool archived;

  bool get isDefault => slug == 'default';

  static HmKanbanBoardRow? parse(Object? raw) {
    if (raw is! Map) return null;
    final slug = _str(raw['slug']);
    if (slug == null) return null;
    return HmKanbanBoardRow(
      slug: slug,
      name: _str(raw['name']) ?? slug,
      total: _int(raw['total']),
      isCurrent: raw['is_current'] == true,
      archived: raw['archived'] == true,
    );
  }
}

class HmKanbanBoards {
  const HmKanbanBoards(this.boards, this.current);
  final List<HmKanbanBoardRow> boards;
  final String? current;

  factory HmKanbanBoards.fromJson(Map<String, dynamic> j) {
    final raw = j['boards'];
    final boards = [
      if (raw is List)
        for (final b in raw) ?HmKanbanBoardRow.parse(b),
    ].where((b) => !b.archived).toList(growable: false);
    return HmKanbanBoards(boards, _str(j['current']));
  }

  /// The board to open first: the host's active one, else the first.
  HmKanbanBoardRow? get initial =>
      boards.where((b) => b.slug == current).firstOrNull ??
      boards.where((b) => b.isCurrent).firstOrNull ??
      boards.firstOrNull;
}

class HmKanbanTask {
  const HmKanbanTask({
    required this.id,
    required this.title,
    required this.status,
    this.body,
    this.assignee,
    this.priority = 0,
    this.latestSummary,
    this.commentCount = 0,
    this.childrenDone,
    this.childrenTotal,
  });

  final String id;
  final String title;
  final String status;
  final String? body;
  final String? assignee;
  final int priority;
  final String? latestSummary;
  final int commentCount;
  final int? childrenDone;
  final int? childrenTotal;

  static HmKanbanTask? parse(Object? raw) {
    if (raw is! Map) return null;
    final id = _str(raw['id']);
    if (id == null) return null;
    final progress = raw['progress'];
    return HmKanbanTask(
      id: id,
      title: _str(raw['title']) ?? id,
      status: _str(raw['status']) ?? 'todo',
      body: _str(raw['body']),
      assignee: _str(raw['assignee']),
      priority: _int(raw['priority']),
      latestSummary: _str(raw['latest_summary']),
      commentCount: _int(raw['comment_count']),
      childrenDone: progress is Map ? _int(progress['done']) : null,
      childrenTotal: progress is Map ? _int(progress['total']) : null,
    );
  }

  bool matches(String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    return title.toLowerCase().contains(q) ||
        (body?.toLowerCase().contains(q) ?? false) ||
        (assignee?.toLowerCase().contains(q) ?? false) ||
        id.toLowerCase().contains(q);
  }
}

class HmKanbanColumn {
  const HmKanbanColumn(this.name, this.tasks);
  final String name;
  final List<HmKanbanTask> tasks;
  String get label => hmKanbanLabel(name);
}

class HmKanbanBoard {
  const HmKanbanBoard(this.columns);
  final List<HmKanbanColumn> columns;

  int get total => columns.fold(0, (n, c) => n + c.tasks.length);

  factory HmKanbanBoard.fromJson(Map<String, dynamic> j) {
    final raw = j['columns'];
    return HmKanbanBoard([
      if (raw is List)
        for (final c in raw.whereType<Map>())
          HmKanbanColumn(_str(c['name']) ?? 'todo', [
            if (c['tasks'] is List)
              for (final t in c['tasks'] as List) ?HmKanbanTask.parse(t),
          ]),
    ]);
  }
}

class HmKanbanComment {
  const HmKanbanComment(this.author, this.body, this.createdAt);
  final String author;
  final String body;
  final int createdAt;
}

class HmKanbanTaskDetail {
  const HmKanbanTaskDetail(this.task, this.comments);
  final HmKanbanTask task;
  final List<HmKanbanComment> comments;

  static HmKanbanTaskDetail? fromJson(Map<String, dynamic> j) {
    final task = HmKanbanTask.parse(j['task']);
    if (task == null) return null;
    final raw = j['comments'];
    return HmKanbanTaskDetail(task, [
      if (raw is List)
        for (final c in raw.whereType<Map>())
          if (_str(c['body']) != null)
            HmKanbanComment(
              _str(c['author']) ?? '',
              _str(c['body'])!,
              _int(c['created_at']),
            ),
    ]);
  }
}

/// Lowercase alphanumerics and hyphens, as board slugs must be.
String hmKanbanSlug(String name) {
  final s = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final cut = s.length > 64 ? s.substring(0, 64) : s;
  return cut.isEmpty ? 'board' : cut;
}

/// The kanban plugin's REST surface (host-wide, not per profile).
class HmKanbanSource {
  HmKanbanSource(this.request);
  final HmDashRequest request;

  static const _base = 'plugins/kanban';
  static String _id(String id) => Uri.encodeComponent(id);

  Future<HmKanbanBoards> boards() async => HmKanbanBoards.fromJson(
    await hmDashJson(request, 'GET', '$_base/boards'),
  );

  Future<HmKanbanBoard> board(String slug, {bool archived = false}) async =>
      HmKanbanBoard.fromJson(
        await hmDashJson(
          request,
          'GET',
          '$_base/board',
          query: {'board': slug, if (archived) 'include_archived': 'true'},
        ),
      );

  Future<HmKanbanTaskDetail?> task(String slug, String id) async =>
      HmKanbanTaskDetail.fromJson(
        await hmDashJson(
          request,
          'GET',
          '$_base/tasks/${_id(id)}',
          query: {'board': slug},
        ),
      );

  Future<void> createTask(String slug, {required String title, String? body}) =>
      hmDashJson(
        request,
        'POST',
        '$_base/tasks',
        query: {'board': slug},
        body: {'title': title, 'body': ?body},
      );

  Future<void> updateTask(
    String slug,
    String id, {
    String? status,
    String? title,
    String? body,
  }) => hmDashJson(
    request,
    'PATCH',
    '$_base/tasks/${_id(id)}',
    query: {'board': slug},
    body: {'status': ?status, 'title': ?title, 'body': ?body},
  );

  Future<void> deleteTask(String slug, String id) => hmDashJson(
    request,
    'DELETE',
    '$_base/tasks/${_id(id)}',
    query: {'board': slug},
  );

  Future<String> createBoard(String name) async {
    final res = await hmDashJson(
      request,
      'POST',
      '$_base/boards',
      body: {'slug': hmKanbanSlug(name), 'name': name},
    );
    final board = res['board'];
    return (board is Map ? _str(board['slug']) : null) ?? hmKanbanSlug(name);
  }

  /// Archives (never hard-deletes) a board.
  Future<void> archiveBoard(String slug) =>
      hmDashJson(request, 'DELETE', '$_base/boards/${_id(slug)}');
}
