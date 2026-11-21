import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/bot_directory_document.dart';

void main() {
  test('parses a bot blueprint with a name, title and description', () {
    final bot = BotDirectoryDocument.parse(
      '{"name":"writer","title":" Writer ","description":"Edits drafts."}',
    );
    expect(bot.name, 'writer');
    expect(bot.title, 'Writer');
    expect(bot.description, 'Edits drafts.');
    expect(BotDirectoryDocument.parse('{"name":"writer"}').title, isNull);
  });

  test('rejects a missing or invalid profile name', () {
    for (final input in [
      '{"title":"Writer"}',
      '{"name":""}',
      '{"name":"a/b"}',
    ]) {
      expect(() => BotDirectoryDocument.parse(input), throwsFormatException);
    }
  });

  test('rejects wrong field types and invalid JSON', () {
    for (final input in [
      '[]',
      '{"name":2}',
      '{"name":"writer","title":true}',
      '{"name":"writer","description":null}',
      '{',
    ]) {
      expect(() => BotDirectoryDocument.parse(input), throwsFormatException);
    }
  });
}
