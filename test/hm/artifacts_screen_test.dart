import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/remote_files_client.dart';
import 'package:hermes_android/hm/features/artifacts/artifacts_data.dart';
import 'package:hermes_android/hm/features/artifacts/hm_artifacts.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

class MemoryIndex implements HmArtifactIndexStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String owner) async => data[owner];
  @override
  Future<void> write(String owner, String value) async => data[owner] = value;
}

class FakeSource implements HmArtifactsSource {
  FakeSource(this.rows);
  List<Map<String, dynamic>> rows;
  Completer<void>? gate;
  Object? error;
  int sessionCalls = 0;

  @override
  String get owner => 'test';

  @override
  Future<List<HmArtifactSession>> sessions() async {
    sessionCalls++;
    await gate?.future;
    if (error != null) throw error!;
    if (rows.isEmpty) return const [];
    return const [
      HmArtifactSession(id: 's1', title: 'Quarterly report', lastActive: 0),
    ];
  }

  @override
  Future<HmArtifactMessagePage> messages(
    String sessionId, {
    required int offset,
    required int limit,
  }) async => HmArtifactMessagePage(rows, limit: 0);
}

class FakeFiles implements RemoteFilesDataSource {
  FakeFiles(this.log);
  final List<String> log;
  @override
  Future<RemoteFileDownload> download(String path) async {
    log.add(path);
    if (path.endsWith('.png')) throw Exception('no thumbnail in tests');
    return RemoteFileDownload(filename: 'report.txt', bytes: 'hello'.codeUnits);
  }

  @override
  Future<RemoteDirectory> defaultDirectory() => throw UnimplementedError();
  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) =>
      throw UnimplementedError();
  @override
  Future<RemoteTextPreview> readText(String path) => throw UnimplementedError();
}

const produced = [
  {
    'role': 'assistant',
    'content':
        'Chart: ![c](/tmp/chart.png). Report: /home/bot/report.txt. '
        'Source: https://example.com/data',
    'timestamp': 1700000000,
  },
];

void main() {
  late FakeSource source;
  late List<String> downloads;
  late List<Uri> opened;
  late List<String> chats;
  late bool openOk;

  setUp(() {
    source = FakeSource([...produced]);
    downloads = [];
    opened = [];
    chats = [];
    openOk = true;
  });

  Future<void> pump(WidgetTester tester, {bool draft = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HmArtifactsScreen(
          loader: HmArtifactsLoader(source, store: MemoryIndex()),
          draftChat: draft,
          filesClient: (_) => FakeFiles(downloads),
          onOpenChat: (_, a) async => chats.add(a.sessionId),
          openUrl: (u) async {
            opened.add(u);
            return openOk;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('loading then the list grouped by category', (tester) async {
    source.gate = Completer<void>();
    await pump(tester);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Artifacts'), findsOneWidget);
    expect(find.text('Search artifacts'), findsOneWidget);

    source.gate!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Images'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Links'), findsOneWidget);
    expect(find.text('chart.png'), findsOneWidget);
    expect(find.text('report.txt'), findsOneWidget);
    expect(find.text('data'), findsOneWidget);
    expect(find.textContaining('Quarterly report'), findsWidgets);
  });

  testWidgets('empty shows the official empty state', (tester) async {
    source.rows = [];
    await pump(tester);
    expect(find.text('No artifacts yet'), findsOneWidget);
    expect(
      find.text(
        'Images, files, and links created in recent conversations will '
        'collect here.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a chat never sent shows empty without asking the host', (
    tester,
  ) async {
    await pump(tester, draft: true);
    expect(find.text('No artifacts yet'), findsOneWidget);
    expect(source.sessionCalls, 0);
  });

  testWidgets('host error is "Artifacts unavailable"; Try Again reloads', (
    tester,
  ) async {
    source.error = Exception('Profile not found');
    await pump(tester);
    expect(find.text('Artifacts unavailable'), findsOneWidget);
    expect(find.text('Profile not found'), findsOneWidget);

    source.error = null;
    await tester.tap(find.text('Try Again'));
    await tester.pump();
    await tester.pump();
    expect(find.text('chart.png'), findsOneWidget);
    expect(source.sessionCalls, 2);
  });

  testWidgets('the folder menu filters to one category', (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip('All Files'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Links').last);
    await tester.pumpAndSettle();
    expect(find.text('data'), findsOneWidget);
    expect(find.text('chart.png'), findsNothing);
    expect(find.text('report.txt'), findsNothing);
    expect(find.byTooltip('Links'), findsOneWidget);
  });

  testWidgets('search narrows and reports no match', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'chart');
    await tester.pump();
    expect(find.text('chart.png'), findsOneWidget);
    expect(find.text('report.txt'), findsNothing);
    expect(find.text('data'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();
    expect(find.text('No matching artifacts'), findsOneWidget);
    expect(find.text('Try a different search.'), findsOneWidget);
  });

  testWidgets('tapping a link opens it; a failure says so', (tester) async {
    await pump(tester);
    await tester.tap(find.text('data'));
    await tester.pump();
    expect(opened, [Uri.parse('https://example.com/data')]);

    openOk = false;
    await tester.tap(find.text('data'));
    await tester.pump();
    expect(
      find.text('Couldn’t open the selected destination.'),
      findsOneWidget,
    );
  });

  testWidgets('tapping a file fetches it from the host for the viewer', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('report.txt'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(downloads, contains('/home/bot/report.txt'));
  });

  testWidgets('row menu copies the path and opens the chat', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await pump(tester);
    final more = find.byTooltip('More');
    await tester.tap(more.at(1)); // the Files row
    await tester.pumpAndSettle();
    expect(find.text('Copy Path'), findsOneWidget);
    await tester.tap(find.text('Copy Path'));
    await tester.pumpAndSettle();
    expect(copied, '/home/bot/report.txt');

    await tester.tap(more.at(2)); // the Links row
    await tester.pumpAndSettle();
    expect(find.text('Copy Link'), findsOneWidget);
    expect(find.text('Open in Browser'), findsOneWidget);
    await tester.tap(find.text('Open Chat'));
    await tester.pumpAndSettle();
    expect(chats, ['s1']);
  });
}
