import 'dart:async';

import 'connection_manager.dart';
import 'local_chat_pin_store.dart';

typedef SessionScanProgress = void Function(List<Session> sessions);

/// Coalesces readers only within the same physical authority revision.
/// Invalidating starts a new flight without replaying an older flight's rows.
///
/// With [reuseCompletedFor], the last successful read of the current revision
/// is retained for that window. Only a load that opts in with
/// `reuseCompleted: true` (a passive refresh tick) is answered from it without
/// new I/O; ordinary loads still start a fresh read. [invalidate] (an explicit
/// refresh or a local mutation) always ends reuse, and failures are never
/// retained.
class SharedSessionScan {
  final Future<List<Session>> Function(SessionScanProgress publish) read;
  final Duration? reuseCompletedFor;
  final _flights = <_SessionScanFlight>{};
  _SessionScanFlight? _current;
  var _revision = 0;
  bool _closed = false;
  bool get isClosed => _closed;
  ({int revision, List<Session> rows})? _completed;
  Timer? _completedExpiry;

  SharedSessionScan(this.read, {this.reuseCompletedFor});

  Future<List<Session>> load({
    SessionScanProgress? onProgress,
    void Function(int revision)? onRevision,
    bool reuseCompleted = false,
  }) async {
    if (isClosed) throw StateError('Session browser is closed');
    var flight = _current;
    if (flight == null || flight.revision != _revision) {
      if (_completed case final completed?
          when reuseCompleted && completed.revision == _revision) {
        onRevision?.call(completed.revision);
        return completed.rows;
      }
      flight = _SessionScanFlight(++_revision);
      final started = flight;
      _current = started;
      _flights.add(started);
      started.result =
          Future<List<Session>>.sync(
                () => read((rows) {
                  if (isClosed || !_flights.contains(started)) return;
                  started.progress = List.unmodifiable(rows);
                  for (final listener in started.listeners.toList()) {
                    listener(started.progress!);
                  }
                }),
              )
              .then((rows) {
                _retain(started.revision, rows);
                return rows;
              })
              .whenComplete(() {
                _flights.remove(started);
                if (identical(_current, started)) _current = null;
              });
    }
    try {
      // A subscriber inherits the physical read's revision, before any replay.
      // Joining an old read must never promote its cache-write authority.
      onRevision?.call(flight.revision);
      if (onProgress != null) {
        flight.listeners.add(onProgress);
        if (flight.progress case final previous?) onProgress(previous);
      }
      final rows = await flight.result;
      if (isClosed) throw StateError('Session browser is closed');
      return rows;
    } finally {
      if (onProgress != null) flight.listeners.remove(onProgress);
    }
  }

  void _retain(int revision, List<Session> rows) {
    final window = reuseCompletedFor;
    if (window == null || isClosed || revision != _revision) return;
    _completedExpiry?.cancel();
    _completed = (revision: revision, rows: rows);
    _completedExpiry = Timer(window, _dropCompleted);
  }

  void _dropCompleted() {
    _completedExpiry?.cancel();
    _completedExpiry = null;
    _completed = null;
  }

  void invalidate() {
    _revision++;
    _dropCompleted();
  }

  bool isCurrent(int revision) => !isClosed && revision == _revision;

  void close() {
    _closed = true;
    _dropCompleted();
    for (final flight in _flights) {
      flight.listeners.clear();
    }
  }
}

class _SessionScanFlight {
  final int revision;
  final listeners = <SessionScanProgress>{};
  late final Future<List<Session>> result;
  List<Session>? progress;

  _SessionScanFlight(this.revision);
}

/// Both conversation browsers observe the same unfiltered source so legacy
/// cron identities are not lost behind a source=cron request.
class SessionBrowserLoader {
  final ApiClient api;
  final Future<List<String>> Function() loadPins;
  final Future<List<Session>> Function()? sessionsLoader;
  final Future<SessionListPage> Function({required int limit, int offset})?
  readPage;
  late final _owner = SharedSessionScan(_scan);

  SessionBrowserLoader({
    required this.api,
    required this.loadPins,
    this.sessionsLoader,
    this.readPage,
  });

  Future<List<Session>> load({
    SessionScanProgress? onProgress,
    void Function(int revision)? onRevision,
  }) => _owner.load(onProgress: onProgress, onRevision: onRevision);

  bool isCurrent(int revision) => _owner.isCurrent(revision);

  void invalidate() => _owner.invalidate();
  bool get _closed => _owner.isClosed;

  Future<List<Session>> _scan(SessionScanProgress publish) async {
    final custom = sessionsLoader;
    if (custom != null) {
      final sessions = await custom();
      publish(sessions);
      return sessions;
    }
    final read = readPage ?? api.getSessionsPage;
    final first = await read(limit: 5, offset: 0);
    if (_closed) throw StateError('Session browser is closed');
    publish(first.sessions);
    const pageSize = 100;
    final all = <String, Session>{};
    var offset = 0;
    var pinBound = 0;
    var zeroNewPages = 0;
    while (!_closed) {
      final page = await read(limit: pageSize, offset: offset);
      if (_closed) throw StateError('Session browser is closed');
      var newRows = 0;
      for (final session in page.sessions) {
        if (!all.containsKey(session.id)) newRows++;
        all[session.id] = session;
      }
      publish(List.unmodifiable(all.values));
      final pinsOnPage = page.sessions
          .where((session) => session.pinned)
          .length;
      if (pinsOnPage > pinBound) pinBound = pinsOnPage;
      // Stock appends pins beyond limit and can report has_more=false when
      // pins occupy the base window. Repeated all-pin windows are not EOF.
      if (newRows == 0) {
        zeroNewPages++;
        final required = pinBound == 0 ? 1 : pinBound ~/ pageSize + 1;
        if (zeroNewPages >= required) break;
      } else {
        zeroNewPages = 0;
      }
      offset += pageSize;
    }
    if (_closed) throw StateError('Session browser is closed');
    List<String> pins;
    try {
      pins = await loadPins();
    } catch (_) {
      // Device preferences are additive, never a prerequisite for history.
      pins = const [];
    }
    if (_closed) throw StateError('Session browser is closed');
    if (pins.isNotEmpty) {
      final recovered = await loadUnlistedLocalPins(
        api,
        all.values.toList(),
        pins,
      );
      if (_closed) throw StateError('Session browser is closed');
      for (final session in recovered) {
        all[session.id] = session;
      }
    }
    return List.unmodifiable(all.values);
  }

  void close() => _owner.close();
}
