import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/hm/features/artifacts/artifacts_data.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class MemoryIndex implements HmArtifactIndexStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String owner) async => data[owner];
  @override
  Future<void> write(String owner, String value) async => data[owner] = value;
}

void main() {
  late List<Uri> requests;
  late double lastActive;
  late bool failSessions;

  http.Response handle(http.Request req) {
    requests.add(req.url);
    final path = req.url.path;
    if (path == '/api/sessions') {
      if (failSessions) {
        return http.Response(jsonEncode({'detail': 'Profile not found'}), 404);
      }
      return http.Response(
        jsonEncode({
          'sessions': [
            {'id': 'a', 'title': 'Charts', 'last_active': lastActive},
          ],
        }),
        200,
      );
    }
    if (path == '/api/sessions/a') {
      return http.Response(
        jsonEncode({'id': 'a', 'title': 'Charts', 'last_active': lastActive}),
        200,
      );
    }
    if (path == '/api/sessions/a/messages') {
      return http.Response(
        jsonEncode({
          'messages': [
            {'role': 'assistant', 'content': 'Saved /tmp/plot.png'},
          ],
          'pagination': {'limit': 100, 'offset': 0},
        }),
        200,
      );
    }
    return http.Response('{}', 404);
  }

  DashboardArtifactsSource source({String? sessionId}) =>
      DashboardArtifactsSource(
        dashboard: DashboardClient(
          host: 'host.test',
          proxied: true,
          httpClient: MockClient((r) async => handle(r)),
        ),
        profile: 'atlas',
        sessionId: sessionId,
      );

  setUp(() {
    requests = [];
    lastActive = 1700000000;
    failSessions = false;
  });

  test('all-artifacts reads recent sessions then each transcript', () async {
    final state = await HmArtifactsLoader(source(), store: MemoryIndex())
        .load();
    expect((state as HmArtifactsLoaded).artifacts.single.value, '/tmp/plot.png');
    expect(requests.first.path, '/api/sessions');
    expect(requests.first.queryParameters, {
      'profile': 'atlas',
      'limit': '30',
      'offset': '0',
      'order': 'recent',
      'archived': 'exclude',
    });
    expect(requests[1].path, '/api/sessions/a/messages');
    expect(requests[1].queryParameters['order'], 'oldest');
    expect(requests[1].queryParameters['profile'], 'atlas');
    expect(requests[1].queryParameters['inline_images'], 'false');
  });

  test('a chat reads only its own session', () async {
    await HmArtifactsLoader(source(sessionId: 'a'), store: MemoryIndex())
        .load();
    expect(requests.map((u) => u.path), [
      '/api/sessions/a',
      '/api/sessions/a/messages',
    ]);
  });

  test('the index skips unchanged sessions and rescans changed ones', () async {
    final index = MemoryIndex();
    await HmArtifactsLoader(source(), store: index).load();
    requests.clear();
    final again = await HmArtifactsLoader(source(), store: index).load();
    expect((again as HmArtifactsLoaded).artifacts, hasLength(1));
    expect(requests.map((u) => u.path), ['/api/sessions']);

    requests.clear();
    lastActive = 1700000100;
    await HmArtifactsLoader(source(), store: index).load();
    expect(requests.map((u) => u.path), contains('/api/sessions/a/messages'));
  });

  test('a host refusal is the unavailable state with its words', () async {
    failSessions = true;
    final state = await HmArtifactsLoader(source(), store: MemoryIndex())
        .load();
    expect((state as HmArtifactsUnavailable).message, 'Profile not found');
  });
}
