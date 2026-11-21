// One open group room: members, the ordered log (contiguous room sequence
// numbers), live member activity and the one pending send. A page that skips,
// rewrites or moves the log puts the room in an error state worded as the
// official app words it; Reload replays the log from the start.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'groups_api.dart';

enum HmRoomPhase { loading, loaded, error }

enum HmSendStatus { sending, failed }

/// The message the user sent that the room has not confirmed yet.
@immutable
class HmPendingSend {
  const HmPendingSend({
    required this.eventId,
    required this.text,
    required this.status,
    this.error,
  });

  final String eventId;
  final String text;
  final HmSendStatus status;
  final String? error;
}

class HmGroupRoomController extends ChangeNotifier {
  HmGroupRoomController(this.api, HmGroupRoom room) : _room = room;

  final HmGroupsApi api;

  HmGroupRoom _room;
  HmGroupRoom get room => _room;
  List<HmGroupMember> get members => _room.members;

  HmRoomPhase phase = HmRoomPhase.loading;

  /// The room-level failure (log gap, conflict, authority change, load error).
  String? error;

  /// A one-off notice from the last action (stop, approve, driver).
  String? notice;

  final List<HmGroupEvent> _log = [];
  List<HmGroupEvent> get log => List.unmodifiable(_log);
  int get cursor => _log.isEmpty ? 0 : _log.last.seq;
  int? _epoch;

  HmPendingSend? pending;
  bool working = false;
  List<HmGroupActivity> activity = const [];
  List<HmGroupApproval> approvals = const [];
  String? driverError;
  bool _disposed = false;
  bool _syncing = false;
  bool _again = false;

  HmGroupMember? memberById(String id) =>
      members.where((m) => m.memberId == id).firstOrNull;

  /// Loads state and the whole log from the start.
  Future<void> load() async {
    _log.clear();
    _epoch = null;
    error = null;
    phase = HmRoomPhase.loading;
    _notify();
    await sync();
  }

  /// Reads `groups.state` and the log delta after [cursor]. Coalesces calls.
  Future<void> sync() async {
    if (_syncing) {
      _again = true;
      return;
    }
    _syncing = true;
    try {
      do {
        _again = false;
        await _syncOnce();
      } while (_again && !_disposed);
    } finally {
      _syncing = false;
    }
  }

  Future<void> _syncOnce() async {
    try {
      final state = await api.state(_room.roomId);
      _applyState(state);
      for (var pages = 0; pages < 50; pages++) {
        final since = cursor;
        final page = await api.log(_room.roomId, sinceSeq: since);
        _applyPage(page, since);
        if (!page.hasMore) break;
      }
      phase = HmRoomPhase.loaded;
      error = null;
    } on HmGroupFailure catch (e) {
      error = e.message;
      phase = HmRoomPhase.error;
    } catch (_) {
      error = HmGroupText.couldNotOpen;
      phase = HmRoomPhase.error;
    }
    _notify();
  }

  void _applyState(HmGroupState s) {
    _room = s.room;
    working = s.working;
    activity = s.activity;
    approvals = s.approvals;
    driverError = s.lastError;
  }

  /// Merges one page after [since]: events must start at since+1 and run
  /// contiguous; a known seq must keep its event id; the epoch must hold.
  void _applyPage(HmGroupLogPage page, int since) {
    final epoch = page.authorityEpoch;
    if (_epoch != null && epoch != null && epoch != _epoch) {
      throw const HmGroupFailure(HmGroupText.authorityChanged);
    }
    _epoch = epoch ?? _epoch;
    var expected = since + 1;
    for (final e in page.events) {
      if (e.seq <= since) {
        final known = _log.where((k) => k.seq == e.seq).firstOrNull;
        if (known != null && known.eventId != e.eventId) {
          throw const HmGroupFailure(HmGroupText.conflictSeq);
        }
        throw const HmGroupFailure(HmGroupText.outsidePage);
      }
      if (e.seq != expected) throw const HmGroupFailure(HmGroupText.gap);
      if (_log.any((k) => k.eventId == e.eventId)) {
        throw const HmGroupFailure(HmGroupText.conflictId);
      }
      _log.add(e);
      expected++;
    }
    final last = page.events.isEmpty ? since : page.events.last.seq;
    if (page.cursor != last) throw const HmGroupFailure(HmGroupText.badCursor);
  }

  /// Sends [text]. A retry of a failed send reuses its event id, so the host
  /// never posts it twice.
  Future<void> send(String text, {bool retry = false}) async {
    final body = retry ? (pending?.text ?? text) : text.trim();
    if (body.isEmpty) return;
    final id = retry && pending != null ? pending!.eventId : api.newId();
    pending = HmPendingSend(
      eventId: id,
      text: body,
      status: HmSendStatus.sending,
    );
    notice = null;
    _notify();
    try {
      final r = await api.send(_room.roomId, eventId: id, text: body);
      if (!r.driverStarted) notice = HmGroupText.driverNotStarted;
      working = true;
      await sync();
      // Committed: the log now shows it (or will on the next change).
      pending = null;
    } on HmGroupFailure catch (e) {
      if (e.admitted == false) {
        // Nothing was kept: hand the words back for editing.
        pending = HmPendingSend(
          eventId: id,
          text: body,
          status: HmSendStatus.failed,
          error: '${HmGroupText.notSent}: ${e.message}',
        );
      } else {
        pending = HmPendingSend(
          eventId: id,
          text: body,
          status: HmSendStatus.failed,
          error: e.message,
        );
      }
    } catch (_) {
      pending = HmPendingSend(
        eventId: id,
        text: body,
        status: HmSendStatus.failed,
        error: HmGroupText.sendTimedOut,
      );
    }
    _notify();
  }

  /// Drops the failed message (the composer takes its words back).
  String? discardPending() {
    final words = pending?.text;
    pending = null;
    _notify();
    return words;
  }

  Future<void> stop() async {
    try {
      await api.stop(_room.roomId);
      working = false;
      activity = const [];
    } on HmGroupFailure {
      notice = HmGroupText.stopGone;
    } catch (_) {
      notice = HmGroupText.stopGone;
    }
    _notify();
    unawaited(sync());
  }

  Future<void> approve(HmGroupApproval a, {required bool allow}) async {
    try {
      await api.approve(_room.roomId, a, allow: allow);
      approvals = [
        for (final x in approvals)
          if (x.requestId != a.requestId) x,
      ];
    } on HmGroupFailure catch (e) {
      notice = e.message;
    } catch (_) {
      notice = HmGroupText.approvalTimedOut;
    }
    _notify();
    unawaited(sync());
  }

  Future<void> rename(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const HmGroupFailure(HmGroupText.giveName);
    final room = await api.rename(_room.roomId, trimmed);
    _room = _room.copyWith(name: room.name);
    _notify();
    unawaited(sync());
  }

  Future<bool> disband() => api.disband(_room.roomId);

  void clearNotice() {
    notice = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
