import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/features/artifacts/artifact_scan.dart';

List<HmArtifact> scan(List<Map<String, dynamic>> messages) => scanArtifacts(
  sessionId: 's1',
  sessionTitle: 'Chart work',
  messages: messages,
  now: () => 42,
);

void main() {
  test('assistant text yields images, files and links', () {
    final found = scan([
      {
        'role': 'assistant',
        'content':
            'Here is the chart ![chart](/tmp/out/chart.png), the report '
            '/home/bot/report.pdf and the docs https://example.com/guide.',
        'timestamp': 1700000000,
      },
    ]);
    expect(
      {for (final a in found) a.value: a.kind},
      {
        '/tmp/out/chart.png': HmArtifactKind.image,
        '/home/bot/report.pdf': HmArtifactKind.file,
        'https://example.com/guide': HmArtifactKind.link,
      },
    );
    expect(found.first.timestamp, 1700000000 * 1000);
    expect(found.first.label, 'chart.png');
    expect(found.first.sessionTitle, 'Chart work');
  });

  test('MEDIA tags count even without a known extension', () {
    final found = scan([
      {'role': 'assistant', 'content': 'MEDIA:/srv/out/build-output'},
    ]);
    expect(found.single.value, '/srv/out/build-output');
    expect(found.single.kind, HmArtifactKind.file);
    expect(found.single.timestamp, 42);
  });

  test('producer tool payload keys are read; user text is not', () {
    final found = scan([
      {'role': 'user', 'content': 'see /tmp/mine.png'},
      {
        'role': 'tool',
        'tool_name': 'image_generate',
        'content': jsonEncode({
          'result': {'image_path': '/tmp/gen/cat.webp'},
        }),
      },
      {
        'role': 'tool',
        'tool_name': 'read_file',
        'content': jsonEncode({'path': '/etc/hosts.txt'}),
      },
    ]);
    expect(found.map((a) => a.value), ['/tmp/gen/cat.webp']);
  });

  test('terminal output skips pip downloads and dedupes', () {
    final found = scan([
      {
        'role': 'tool',
        'tool_name': 'terminal',
        'content': jsonEncode({
          'output':
              'Downloading https://files.pythonhosted.org/packages/a/b/x-1.0-py3-none-any.whl\n'
              'wrote /work/data.csv\nwrote /work/data.csv',
        }),
      },
    ]);
    expect(found.map((a) => a.value), ['/work/data.csv']);
  });

  test('index round trip keeps every field', () {
    final a = scan([
      {'role': 'assistant', 'content': 'https://example.com/a.png'},
    ]).single;
    expect(HmArtifact.fromJson(jsonDecode(jsonEncode(a.toJson()))), a);
  });
}
