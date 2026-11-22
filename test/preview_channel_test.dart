import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/preview_channel.dart';
import 'package:hermes_android/core/widgets/served_build_chip.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _servedSha = 'f80fe98bcbcc5d5626376c10725b79aa708ebdb7';
const _oldSha = '3cb1c089c41efd56cc3cbbed73ca871ef00a21b5';

Map<String, Object?> _run({
  String sha = _servedSha,
  String branch = 'staging',
  String status = 'completed',
  String conclusion = 'success',
  Object? number = 14,
  String url =
      'https://github.com/kvnloo/hermes-android/actions/runs/44997684778',
  String updatedAt = '2026-11-22T07:29:17Z',
}) => {
  'id': 44997684778,
  'run_number': number,
  'head_sha': sha,
  'head_branch': branch,
  'status': status,
  'conclusion': conclusion,
  'updated_at': updatedAt,
  'html_url': url,
};

String _payload(List<Map<String, Object?>> runs) =>
    jsonEncode({'total_count': runs.length, 'workflow_runs': runs});

final _now = DateTime.utc(2026, 11, 22, 7, 36, 17);

void main() {
  group('build identity', () {
    test('parses SHA and build time like Dash does', () {
      expect(parseSha(' ABCDEF1 '), 'abcdef1');
      expect(parseSha('abc'), isNull);
      expect(parseSha('not-a-sha'), isNull);
      expect(parseSha(''), isNull);
      expect(
        parseBuildTime('1763796557'),
        DateTime.fromMillisecondsSinceEpoch(1763796557000, isUtc: true),
      );
      expect(
        parseBuildTime('1763796557123'),
        DateTime.fromMillisecondsSinceEpoch(1763796557123, isUtc: true),
      );
      expect(
        parseBuildTime('2026-11-22T07:29:17Z'),
        DateTime.utc(2026, 11, 22, 7, 29, 17),
      );
      expect(parseBuildTime('2026-11-22 07:29'), isNull);
      expect(parseBuildTime(null), isNull);
    });

    test('a build without defines has no identity', () {
      expect(RunningBuild.current.sha, isNull);
      expect(RunningBuild.current.builtAt, isNull);
    });

    test('age labels', () {
      expect(servedAgeLabel(null, _now), 'age unknown');
      expect(
        servedAgeLabel(_now.add(const Duration(minutes: 5)), _now),
        'clock skew',
      );
      expect(
        servedAgeLabel(_now.subtract(const Duration(seconds: 20)), _now),
        'just served',
      );
      expect(
        servedAgeLabel(_now.subtract(const Duration(minutes: 7)), _now),
        '7m old',
      );
      expect(
        servedAgeLabel(_now.subtract(const Duration(hours: 3)), _now),
        '3h old',
      );
      expect(
        servedAgeLabel(_now.subtract(const Duration(days: 2)), _now),
        '2d old',
      );
    });
  });

  group('served build', () {
    test('reads the newest green staging run', () {
      final served = parseServedBuild(_payload([_run()]))!;
      expect(served.sha, _servedSha);
      expect(served.runNumber, 14);
      expect(served.builtAt, DateTime.utc(2026, 11, 22, 7, 29, 17));
      expect(
        served.runUrl.toString(),
        'https://github.com/kvnloo/hermes-android/actions/runs/44997684778',
      );
    });

    test('skips runs that are not green staging runs on the fork', () {
      for (final bad in [
        _run(branch: 'main'),
        _run(status: 'in_progress'),
        _run(conclusion: 'failure'),
        _run(sha: 'f80fe98'),
        _run(number: '14'),
        _run(url: 'https://evil.example/kvnloo/hermes-android/actions/runs/1'),
        _run(url: 'https://github.com/someone/hermes-android/actions/runs/1'),
        _run(url: 'http://github.com/kvnloo/hermes-android/actions/runs/1'),
        _run(url: 'https://github.com/kvnloo/hermes-android/actions/runs/1?x'),
      ]) {
        expect(parseServedBuild(_payload([bad])), isNull, reason: '$bad');
      }
      expect(
        parseServedBuild(_payload([_run(branch: 'main'), _run()]))?.sha,
        _servedSha,
      );
      expect(parseServedBuild('not json'), isNull);
      expect(parseServedBuild('[]'), isNull);
      expect(parseServedBuild('{}'), isNull);
    });

    test('queries the public runs API for staging', () {
      expect(
        PreviewChannelSource.runsUri.toString(),
        'https://api.github.com/repos/kvnloo/hermes-android/actions/workflows/'
        'play.yml/runs?branch=staging&status=success&per_page=1',
      );
    });
  });

  group('chip state', () {
    final served = parseServedBuild(_payload([_run()]))!;

    test('maps running and served builds to a state and label', () {
      const none = RunningBuild();
      expect(
        previewBuildState(running: none, served: null, fetchFailed: false),
        PreviewBuildState.checking,
      );
      expect(
        previewBuildState(running: none, served: null, fetchFailed: true),
        PreviewBuildState.unreachable,
      );
      expect(
        previewBuildState(running: none, served: served, fetchFailed: false),
        PreviewBuildState.unknown,
      );
      final current = RunningBuild(sha: _servedSha.substring(0, 7));
      expect(
        previewBuildState(running: current, served: served, fetchFailed: true),
        PreviewBuildState.current,
      );
      const old = RunningBuild(sha: _oldSha);
      expect(
        previewBuildState(running: old, served: served, fetchFailed: false),
        PreviewBuildState.newer,
      );

      String label(RunningBuild running, ServedBuild? s, bool failed) =>
          previewChipLabel(
            running: running,
            served: s,
            state: previewBuildState(
              running: running,
              served: s,
              fetchFailed: failed,
            ),
            now: _now,
          );
      expect(label(none, null, false), '? · checking');
      expect(label(old, null, true), '3cb1c08 · served ?');
      expect(label(none, served, false), 'served f80fe98 · 7m old');
      expect(label(current, served, false), 'f80fe98 · 7m old');
      expect(label(old, served, false), '3cb1c08 → f80fe98');
    });
  });

  group('PreviewChannel', () {
    late List<Uri> requests;
    late int status;
    late String body;

    MockClient client() => MockClient((request) async {
      requests.add(request.url);
      return http.Response(body, status);
    });

    setUp(() {
      requests = [];
      status = 200;
      body = _payload([_run()]);
    });

    test('defaults to stable and never fetches on stable', () async {
      SharedPreferences.setMockInitialValues({});
      final channel = PreviewChannel(
        client: client(),
        preferences: await SharedPreferences.getInstance(),
      );
      await channel.load();
      expect(channel.channel, UpdateChannel.stable);
      await channel.refresh(force: true);
      expect(requests, isEmpty);
      expect(channel.served, isNull);
    });

    test('switching to preview persists, fetches and caches', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var now = _now;
      final channel = PreviewChannel(
        client: client(),
        preferences: prefs,
        running: const RunningBuild(sha: _oldSha),
        clock: () => now,
      );
      await channel.setChannel(UpdateChannel.preview);
      expect(prefs.getString(PreviewChannel.channelKey), 'preview');
      expect(requests, [PreviewChannelSource.runsUri]);
      expect(channel.state, PreviewBuildState.newer);
      expect(channel.label(_now), '3cb1c08 → f80fe98');

      // Throttled inside a minute, fetched again after it.
      await channel.refresh();
      expect(requests, hasLength(1));
      now = now.add(PreviewChannel.minFetchInterval);
      await channel.refresh();
      expect(requests, hasLength(2));

      // A fresh process restores channel and the last served build offline.
      status = 500;
      final restarted = PreviewChannel(
        client: client(),
        preferences: prefs,
        running: const RunningBuild(sha: _oldSha),
      );
      await restarted.load();
      expect(restarted.isPreview, isTrue);
      expect(restarted.served?.sha, _servedSha);
      await restarted.refresh(force: true);
      expect(restarted.fetchFailed, isTrue);
      expect(restarted.state, PreviewBuildState.newer);

      await restarted.setChannel(UpdateChannel.stable);
      expect(prefs.getString(PreviewChannel.channelKey), 'stable');
    });

    test(
      'an unreachable or malformed answer is reported, not thrown',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        body = '{"workflow_runs": "nope"}';
        final channel = PreviewChannel(client: client(), preferences: prefs);
        await channel.setChannel(UpdateChannel.preview);
        expect(channel.state, PreviewBuildState.unreachable);
        expect(prefs.getString(PreviewChannel.servedKey), isNull);

        final throwing = PreviewChannel(
          client: MockClient((_) async => throw http.ClientException('down')),
          preferences: prefs,
        );
        await throwing.refresh(force: true);
        expect(throwing.state, PreviewBuildState.unreachable);
      },
    );

    test('hide lasts until the served build changes', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final channel = PreviewChannel(
        client: client(),
        preferences: prefs,
        running: const RunningBuild(sha: _servedSha),
      );
      await channel.setChannel(UpdateChannel.preview);
      expect(channel.state, PreviewBuildState.current);
      channel.hide();
      expect(channel.hidden, isTrue);
      body = _payload([_run(sha: 'a' * 40)]);
      await channel.refresh(force: true);
      expect(channel.state, PreviewBuildState.newer);
      expect(channel.hidden, isFalse);
    });
  });

  group('ServedBuildChipHost', () {
    Future<PreviewChannel> pumpHost(
      WidgetTester tester, {
      required RunningBuild running,
      required bool preview,
      required List<Uri> opened,
    }) async {
      SharedPreferences.setMockInitialValues({
        if (preview) PreviewChannel.channelKey: 'preview',
      });
      final prefs = await SharedPreferences.getInstance();
      final channel = PreviewChannel(
        client: MockClient((_) async => http.Response(_payload([_run()]), 200)),
        preferences: prefs,
        running: running,
      );
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => ServedBuildChipHost(
            channel: channel,
            openBuild: (url) async => opened.add(url),
            child: child!,
          ),
          home: const Scaffold(body: Text('home')),
        ),
      );
      await tester.runAsync(() => channel.refresh(force: true));
      await tester.pump();
      return channel;
    }

    testWidgets('stays out of the way on the stable channel', (tester) async {
      final opened = <Uri>[];
      await pumpHost(
        tester,
        running: const RunningBuild(sha: _oldSha),
        preview: false,
        opened: opened,
      );
      expect(find.text('home'), findsOneWidget);
      expect(find.byKey(const Key('served-build-chip')), findsNothing);
    });

    testWidgets('shows old → new and opens the served build', (tester) async {
      final opened = <Uri>[];
      final channel = await pumpHost(
        tester,
        running: const RunningBuild(sha: _oldSha),
        preview: true,
        opened: opened,
      );
      expect(find.text('3cb1c08 → f80fe98'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          'Newer preview build served: 3cb1c08 → f80fe98. Tap to open it.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('served-build-chip')));
      await tester.pump();
      expect(opened, [
        Uri.parse(
          'https://github.com/kvnloo/hermes-android/actions/runs/44997684778',
        ),
      ]);
      expect(find.byKey(const Key('served-build-chip')), findsOneWidget);

      // Switching back to stable removes the chip and its timers.
      await tester.runAsync(() => channel.setChannel(UpdateChannel.stable));
      await tester.pump();
      expect(find.byKey(const Key('served-build-chip')), findsNothing);
    });

    testWidgets('a current build hides on tap', (tester) async {
      final opened = <Uri>[];
      final channel = await pumpHost(
        tester,
        running: const RunningBuild(sha: _servedSha),
        preview: true,
        opened: opened,
      );
      expect(find.textContaining('f80fe98 · '), findsOneWidget);
      await tester.tap(find.byKey(const Key('served-build-chip')));
      await tester.pump();
      expect(opened, isEmpty);
      expect(find.byKey(const Key('served-build-chip')), findsNothing);
      await tester.runAsync(() => channel.setChannel(UpdateChannel.stable));
      await tester.pump();
    });
  });
}
