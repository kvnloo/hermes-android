import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/markdown_code_block.dart';

import 'support/l10n_test_utils.dart';

void main() {
  test('plain, dart, and json fences retain main parsing semantics', () {
    final cases = <(String, String?, String)>[
      ('Before ```\nplain\n``` After', null, 'plain\n'),
      ('Before ```dart\nvoid main() {}\n``` After', 'dart', 'void main() {}\n'),
      ('Before ```json\n{"ok":true}\n``` After', 'json', '{"ok":true}\n'),
    ];

    for (final (markdown, language, code) in cases) {
      final parts = splitMarkdownCodeBlocks(markdown);
      expect(parts, hasLength(3), reason: markdown);
      expect(parts.first, 'Before ');
      expect(parts.last, ' After');
      expect(parts[1], isA<MarkdownCodeBlock>());
      final block = parts[1] as MarkdownCodeBlock;
      expect(block.language, language);
      expect(block.code, code);
    }
  });

  test('a spaced info string remains untouched markdown as on main', () {
    const markdown =
        'Before\n```dart title=main.dart\nvoid main() {}\n```\nAfter';
    expect(splitMarkdownCodeBlocks(markdown), <Object>[markdown]);
  });

  test('ordinary fences keep main first-inline-closer behavior', () {
    const markdown = 'Before ```json\n{"s":"```"}\n``` After';
    final parts = splitMarkdownCodeBlocks(markdown);
    expect(parts, hasLength(3));
    expect((parts[1] as MarkdownCodeBlock).code, '{"s":"');
    expect(parts.last, '"}\n``` After');
  });

  test('OpenUI uses its own complete closing line and resumes plain fences', () {
    const markdown = 'Before\n```openui-v2\n'
        'root = Board("x ``` y", "", [])\n```\n'
        'Between\n```dart\nvoid main() {}\n```\nAfter';
    final blocks = splitMarkdownCodeBlocks(markdown)
        .whereType<MarkdownCodeBlock>()
        .toList();
    expect(blocks, hasLength(2));
    expect(blocks.first.language, 'openui-v2');
    expect(blocks.first.code, 'root = Board("x ``` y", "", [])\n');
    expect(blocks.last.language, 'dart');
    expect(blocks.last.code, 'void main() {}\n');
  });

  test('an incomplete OpenUI fence never renders an early inline closer', () {
    const markdown = 'Before\n```openui-v2\n'
        'root = Board("x ``` y", "", [])';
    expect(splitMarkdownCodeBlocks(markdown), <Object>[markdown]);
  });

  testWidgets('ordinary Dart code retains chrome, controls and source',
      (tester) async {
    final block = splitMarkdownCodeBlocks('```dart\nvoid main() {}\n```')
        .whereType<MarkdownCodeBlock>()
        .single;
    await tester.pumpWidget(
      testAppWithL10n(Scaffold(body: Center(child: block))),
    );
    await tester.pump();
    expect(find.byKey(const Key('markdown-code-block')), findsOneWidget);
    expect(find.byKey(const Key('openui-board')), findsNothing);
    expect(find.text('dart'), findsOneWidget);
    expect(find.byIcon(Icons.wrap_text), findsOneWidget);
    expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
    final text = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(text.textSpan?.toPlainText(), 'void main() {}\n');
    await tester.tap(find.byIcon(Icons.wrap_text));
    await tester.pump();
    expect(find.byIcon(Icons.swap_horiz), findsOneWidget);
  });
}
