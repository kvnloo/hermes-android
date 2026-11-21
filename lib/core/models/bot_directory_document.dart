import 'dart:convert';

/// This fallback recognizes the identity fields in the observed bot blueprint.
class BotDirectoryDocument {
  const BotDirectoryDocument({
    required this.name,
    this.title,
    this.description,
  });

  final String name;
  final String? title;
  final String? description;

  factory BotDirectoryDocument.parse(String source) {
    final data = jsonDecode(source);
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Expected a bot object');
    }

    String? readString(String key) {
      final value = data[key];
      if (!data.containsKey(key)) return null;
      if (value is! String) throw FormatException('Expected a string for $key');
      final text = value.trim();
      return text.isEmpty ? null : text;
    }

    final name = readString('name');
    if (name == null || !_profileNamePattern.hasMatch(name)) {
      throw const FormatException('Expected a valid bot profile name');
    }
    return BotDirectoryDocument(
      name: name,
      title: readString('title'),
      description: readString('description'),
    );
  }
}

final _profileNamePattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');
