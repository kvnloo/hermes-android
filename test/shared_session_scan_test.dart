import 'dart:async';

// flutter_test supplies this deterministic microtask clock via its SDK.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/session_browser_loader.dart';

Session _row(String title) => Session.fromJson({'id': 'same', 'title': title});

void main() {
  test(
    'physical revisions are inherited, never allocated by subscribers',
    () async {
      final completions = <Completer<List<Session>>>[];
      final scan = SharedSessionScan((publish) {
        publish([_row('Progress')]);
        final completion = Completer<List<Session>>();
        completions.add(completion);
        return completion.future;
      });
      addTearDown(scan.close);
      final revisions = <int>[];
      final first = scan.load(onRevision: revisions.add);
      final joined = scan.load(
        onRevision: revisions.add,
        onProgress: (_) {
          expect(revisions, hasLength(2));
          expect(scan.isCurrent(revisions.last), isTrue);
        },
      );
      expect(revisions.first, revisions.last);
      expect(completions, hasLength(1));
      completions.first.complete([_row('Complete')]);
      await Future.wait([first, joined]);
      final next = scan.load(onRevision: revisions.add);
      expect(revisions.last, greaterThan(revisions.first));
      expect(scan.isCurrent(revisions.first), isFalse);
      scan.invalidate();
      expect(scan.isCurrent(revisions.last), isFalse);
      final fresh = scan.load(onRevision: revisions.add);
      final freshJoined = scan.load(onRevision: revisions.add);
      expect(revisions[3], revisions[4]);
      expect(completions, hasLength(3));
      completions.last.complete([_row('Fresh')]);
      await Future.wait([fresh, freshJoined]);
      completions[1].complete([_row('Obsolete')]);
      await next;
      expect(scan.isCurrent(revisions.last), isTrue);
      scan.close();
      expect(scan.isCurrent(revisions.last), isFalse);
    },
  );

  test(
    'invalidated flights cannot replay into, publish to, or clear a new flight',
    () async {
      final completions = <Completer<List<Session>>>[];
      final publishers = <SessionScanProgress>[];
      final scan = SharedSessionScan((publish) {
        publishers.add(publish);
        final result = Completer<List<Session>>();
        completions.add(result);
        return result.future;
      });
      addTearDown(scan.close);
      final oldSeen = <String>[];
      final newSeen = <String>[];
      final first = scan.load(
        onProgress: (rows) => oldSeen.add(rows.single.title),
      );
      publishers.single([_row('Before rename')]);
      scan.invalidate();
      final second = scan.load(
        onProgress: (rows) => newSeen.add(rows.single.title),
      );
      expect(completions, hasLength(2));
      expect(newSeen, isEmpty);
      completions.first.complete([_row('Before rename')]);
      await first;
      publishers.first([_row('Late callback')]);
      expect(oldSeen, ['Before rename']);
      expect(newSeen, isEmpty);
      final third = scan.load();
      expect(
        completions,
        hasLength(2),
        reason: 'old completion must not clear the newer shared flight',
      );
      publishers.last([_row('After rename')]);
      completions.last.complete([_row('After rename')]);
      expect((await second).single.title, 'After rename');
      expect((await third).single.title, 'After rename');
      expect(newSeen, ['After rename']);
    },
  );

  test(
    'failure of an old flight does not cancel or replace its successor',
    () async {
      final old = Completer<List<Session>>();
      final current = Completer<List<Session>>();
      var calls = 0;
      final scan = SharedSessionScan(
        (_) => ++calls == 1 ? old.future : current.future,
      );
      addTearDown(scan.close);
      final failed = expectLater(scan.load(), throwsStateError);
      scan.invalidate();
      final fresh = scan.load();
      old.completeError(StateError('old authority failed'));
      await failed;
      final joined = scan.load();
      expect(calls, 2);
      current.complete([_row('Fresh')]);
      expect((await fresh).single.title, 'Fresh');
      expect((await joined).single.title, 'Fresh');
    },
  );

  test('a synchronous reader error releases its flight for Retry', () async {
    var calls = 0;
    final scan = SharedSessionScan((_) {
      if (++calls == 1) throw StateError('reader setup failed');
      return Future.value([_row('Recovered')]);
    });
    addTearDown(scan.close);
    await expectLater(scan.load(), throwsStateError);
    expect((await scan.load()).single.title, 'Recovered');
    expect(calls, 2);
  });

  test(
    'synchronous progress is replayed once and settled callbacks are rejected',
    () async {
      late SessionScanProgress emit;
      final scan = SharedSessionScan((publish) {
        emit = publish;
        publish([_row('Immediate')]);
        return Future.value([_row('Immediate')]);
      });
      addTearDown(scan.close);
      final seen = <String>[];
      await scan.load(onProgress: (rows) => seen.add(rows.single.title));
      emit([_row('After settlement')]);
      expect(seen, ['Immediate']);
    },
  );

  test(
    'close rejects in-flight results, callbacks and subsequent loads',
    () async {
      final held = Completer<List<Session>>();
      late SessionScanProgress emit;
      final scan = SharedSessionScan((publish) {
        emit = publish;
        return held.future;
      });
      final seen = <List<Session>>[];
      final rejected = expectLater(
        scan.load(onProgress: seen.add),
        throwsStateError,
      );
      scan.close();
      emit([_row('Too late')]);
      held.complete([_row('Too late')]);
      await rejected;
      expect(seen, isEmpty);
      await expectLater(scan.load(), throwsStateError);
    },
  );

  group('recent completed scan reuse (#149)', () {
    test('only an opted-in load reuses a completed scan inside its window', () {
      fakeAsync((async) {
        var reads = 0;
        final scan = SharedSessionScan((_) async {
          reads++;
          return [_row('Read $reads')];
        }, reuseCompletedFor: const Duration(minutes: 5));
        List<Session>? rows;
        scan.load().then((value) => rows = value);
        async.flushMicrotasks();
        expect(reads, 1);
        expect(rows!.single.title, 'Read 1');

        scan.load(reuseCompleted: true).then((value) => rows = value);
        async.flushMicrotasks();
        expect(reads, 1, reason: 'a passive tick must not repeat the scan');
        expect(rows!.single.title, 'Read 1');

        // Mounts and foreground loads do not opt in and still read fresh rows.
        scan.load().then((value) => rows = value);
        async.flushMicrotasks();
        expect(reads, 2);
        expect(rows!.single.title, 'Read 2');

        async.elapse(const Duration(minutes: 4, seconds: 59));
        scan.load(reuseCompleted: true).then((value) => rows = value);
        async.flushMicrotasks();
        expect(reads, 2);
        expect(rows!.single.title, 'Read 2');

        async.elapse(const Duration(minutes: 5));
        scan.load(reuseCompleted: true).then((value) => rows = value);
        async.flushMicrotasks();
        expect(reads, 3, reason: 'an expired window reads fresh rows');
        expect(rows!.single.title, 'Read 3');
        scan.close();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('invalidation, failures and an unset window never reuse rows', () {
      fakeAsync((async) {
        var reads = 0;
        var fail = false;
        final scan = SharedSessionScan((_) async {
          reads++;
          if (fail) throw StateError('offline');
          return [_row('Read $reads')];
        }, reuseCompletedFor: const Duration(minutes: 5));
        scan.load();
        async.flushMicrotasks();
        expect(reads, 1);

        // A local archive/rename mutation or explicit refresh invalidates.
        scan.invalidate();
        scan.load(reuseCompleted: true);
        async.flushMicrotasks();
        expect(reads, 2);

        fail = true;
        Object? error;
        scan.load().catchError((Object e) {
          error = e;
          return <Session>[];
        });
        async.flushMicrotasks();
        expect(reads, 3);
        expect(error, isA<StateError>());
        fail = false;
        List<Session>? rows;
        scan.load(reuseCompleted: true).then((value) => rows = value);
        async.flushMicrotasks();
        expect(reads, 4, reason: 'a failed read leaves nothing to reuse');
        expect(rows!.single.title, 'Read 4');
        scan.close();
        expect(async.pendingTimers, isEmpty);

        var plainReads = 0;
        final plain = SharedSessionScan((_) async {
          plainReads++;
          return [_row('Plain')];
        });
        plain.load();
        async.flushMicrotasks();
        plain.load(reuseCompleted: true);
        async.flushMicrotasks();
        expect(plainReads, 2);
        plain.close();
      });
    });

    test('a read that finishes after invalidation is not retained', () {
      fakeAsync((async) {
        final completions = <Completer<List<Session>>>[];
        final scan = SharedSessionScan((_) {
          final completion = Completer<List<Session>>();
          completions.add(completion);
          return completion.future;
        }, reuseCompletedFor: const Duration(minutes: 5));
        scan.load();
        scan.invalidate();
        completions.single.complete([_row('Stale')]);
        async.flushMicrotasks();
        List<Session>? rows;
        scan.load(reuseCompleted: true).then((value) => rows = value);
        async.flushMicrotasks();
        expect(completions, hasLength(2));
        completions.last.complete([_row('Fresh')]);
        async.flushMicrotasks();
        expect(rows!.single.title, 'Fresh');
        scan.close();
      });
    });
  });
}
