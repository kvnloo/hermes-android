import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/screens/workspace_screen.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/core/utils/home_turn_signals.dart';
import 'package:hermes_android/core/widgets/activity_pane.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> activitySessionRow(int index) => {
  'id': 'session-' + index.toString(),
  'title': 'Session ' + index.toString(),
  'source': 'gateway',
  'message_count': 1,
  // Old rows make the bounded Activity preview examine all three pages.
  'started_at': 1700000000 - index,
  'archived': false,
};

http.Response activePage(List<Map<String, Object?>> rows) =>
    http.Response(jsonEncode({'data': rows, 'has_more': false}), 200);

Future<void> mountActivity(
  WidgetTester tester, {
  required http.Client active,
  required http.Client archive,
}) async {
  tester.view.physicalSize = const Size(600, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: hermesTheme(Brightness.dark),
      home: WorkspaceScreen(
        connection: SavedConnection(
          id: 'activity-tick',
          label: 'Test',
          host: 'example.invalid',
          port: 8642,
          apiKey: 'test',
          dashboardProxied: true,
        ),
        testSessionsHttpClient: active,
        testArchivedSessionsHttpClient: archive,
        turnSignalsLoader: (_) async => HomeTurnSignals.empty,
        sessionsRefreshInterval: const Duration(seconds: 10),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
}

Future<void> checkPassiveTickScan(
  WidgetTester tester, {
  required bool inbox,
}) async {
  final pageOffsets = <int>[];
  var scanActivityPages = false;
  await mountActivity(
    tester,
    active: MockClient((request) async {
      final params = request.url.queryParameters;
      if (scanActivityPages && params['limit'] == '100') {
        final offset = int.parse(params['offset'] ?? '0');
        pageOffsets.add(offset);
        return activePage(
          List.generate(100, (index) => activitySessionRow(offset + index)),
        );
      }
      // Let the initial Chats mount finish before selecting Activity/Inbox.
      return activePage([activitySessionRow(0)]);
    }),
    archive: MockClient(
      (_) async => http.Response(jsonEncode({'sessions': [], 'total': 0}), 200),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
  scanActivityPages = true;

  if (inbox) {
    await tester.tap(find.byIcon(Icons.inbox_outlined));
  } else {
    await tester.tap(find.text('Activity').last);
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.byType(ActivityPane), findsOneWidget);
  expect(
    pageOffsets,
    [0, 100, 200],
    reason: 'opening the destination reads the full bounded Activity preview',
  );

  final pagesOnOpen = pageOffsets.length;
  for (var tick = 0; tick < 3; tick++) {
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
  }
  expect(
    pageOffsets.length,
    pagesOnOpen,
    reason: 'three passive ticks must reuse the completed metadata scan',
  );

  // A user refresh must bypass the tick-only reuse, even inside five minutes.
  final refresh = tester.state<ActivityPaneState>(
    find.byType(ActivityPane),
  ).refresh();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
  await refresh;
  expect(
    pageOffsets.skip(pagesOnOpen).toList(),
    [0, 100, 200],
    reason: 'explicit refresh must fetch all three pages again',
  );

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'Activity ticks reuse the metadata scan; manual refresh is fresh',
    (tester) async {
      await checkPassiveTickScan(tester, inbox: false);
    },
  );

  testWidgets(
    'Inbox ticks reuse the metadata scan; manual refresh is fresh',
    (tester) async {
      await checkPassiveTickScan(tester, inbox: true);
    },
  );
}
