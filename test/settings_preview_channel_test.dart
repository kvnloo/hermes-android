import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/preview_channel.dart';
import 'package:hermes_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Settings switches the app to the preview channel', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final requests = <Uri>[];
    PreviewChannel.instance.debugReset(
      preferences: prefs,
      client: MockClient((request) async {
        requests.add(request.url);
        return http.Response(
          jsonEncode({
            'workflow_runs': [
              {
                'run_number': 14,
                'head_sha': 'f80fe98bcbcc5d5626376c10725b79aa708ebdb7',
                'head_branch': 'staging',
                'status': 'completed',
                'conclusion': 'success',
                'updated_at': '2026-11-22T07:29:17Z',
                'html_url':
                    'https://github.com/kvnloo/hermes-android/actions/runs/1',
              },
            ],
          }),
          200,
        );
      }),
    );
    addTearDown(PreviewChannel.instance.debugReset);

    await tester.pumpWidget(HermesApp(connManager: ConnectionManager(prefs)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('served-build-chip')), findsNothing);
    unawaited(
      Navigator.of(tester.element(find.byType(HomeScreen))).push(
        MaterialPageRoute<void>(
          builder: (_) => SettingsScreen(
            connection: SavedConnection(
              id: 'offline-dashboard',
              label: 'Offline dashboard',
              host: '127.0.0.1',
              port: 8642,
              dashboardPortOverride: 1,
              apiKey: 'test-key',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('preview-channel-switch'));
    await tester.scrollUntilVisible(
      toggle,
      300,
      scrollable: find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Preview channel'), findsOneWidget);

    await tester.tap(toggle);
    await tester.runAsync(() => PreviewChannel.instance.refresh(force: true));
    await tester.pump();
    expect(prefs.getString(PreviewChannel.channelKey), 'preview');
    expect(requests, isNotEmpty);
    expect(find.byKey(const Key('served-build-chip')), findsOneWidget);
    // A local build has no baked SHA, so it names only the served build.
    expect(find.textContaining('served f80fe98'), findsOneWidget);

    await tester.tap(toggle);
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    expect(prefs.getString(PreviewChannel.channelKey), 'stable');
    expect(find.byKey(const Key('served-build-chip')), findsNothing);
  });
}
