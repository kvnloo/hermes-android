// Finds the images, files and links a bot produced in one session's
// transcript. The host has no artifact API: Hermes Desktop
// (apps/desktop/src/app/artifacts/artifact-utils.ts, MIT) derives them from
// session messages with these rules, and the official Android app ships the
// same patterns, so a bot's artifacts read the same on every client.
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/utils/media_tags.dart';

enum HmArtifactKind { image, file, link }

/// One produced image, file or link, found in a session's messages.
@immutable
class HmArtifact {
  const HmArtifact({
    required this.kind,
    required this.value,
    required this.sessionId,
    required this.sessionTitle,
    required this.timestamp,
  });

  final HmArtifactKind kind;

  /// The host path, URL or data URI as the bot wrote it.
  final String value;
  final String sessionId;
  final String sessionTitle;

  /// Milliseconds since the epoch.
  final int timestamp;

  String get id => '$sessionId:$value';

  /// The file name or the URL's last path segment.
  String get label {
    if (value.startsWith('data:')) return 'image';
    final uri = Uri.tryParse(value);
    if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
      final last = uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
      return last ?? value;
    }
    final parts = value.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty);
    return parts.lastOrNull ?? value;
  }

  bool get isWebUrl =>
      value.startsWith('http://') || value.startsWith('https://');

  Map<String, dynamic> toJson() => {
    'k': kind.name,
    'v': value,
    's': sessionId,
    't': sessionTitle,
    'ts': timestamp,
  };

  static HmArtifact? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = HmArtifactKind.values
        .where((k) => k.name == j['k'])
        .firstOrNull;
    final value = j['v'];
    final session = j['s'];
    if (kind == null || value is! String || session is! String) return null;
    return HmArtifact(
      kind: kind,
      value: value,
      sessionId: session,
      sessionTitle: (j['t'] ?? '').toString(),
      timestamp: j['ts'] is int ? j['ts'] as int : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HmArtifact &&
      other.id == id &&
      other.kind == kind &&
      other.timestamp == timestamp &&
      other.sessionTitle == sessionTitle;

  @override
  int get hashCode => Object.hash(id, kind, timestamp, sessionTitle);
}

final _markdownImage = RegExp(r'!\[([^\]]*)\]\(([^)\s]+)\)');
final _markdownLink = RegExp(r'\[([^\]]+)\]\(([^)\s]+)\)');
final _url = RegExp(r'''https?://[^\s<>"')`]+''');
final _path = RegExp(
  r'''(^|[\s("'`])((?:/|~[\\/]|\.\.?[\\/]|\\\\)[^\s"'`<>]+(?:\.[a-z0-9]{1,8})?)''',
  caseSensitive: false,
);
final _windowsPath = RegExp(
  r'''(^|[\s("'`])([A-Za-z]:[\\/][^\s"'`<>]+(?:\.[a-z0-9]{1,8})?)''',
  caseSensitive: false,
);
final _imageExt = RegExp(
  r'\.(?:png|jpe?g|gif|webp|svg|bmp)(?:\?.*)?$',
  caseSensitive: false,
);
final _fileExt = RegExp(
  r'\.(?:png|jpe?g|gif|webp|svg|bmp|pdf|txt|json|md|csv|xlsx?|docx?|pptx?|html|zip|tar|gz|avi|flac|m4a|mkv|mp3|ogg|opus|wav|webm|mp4|mov)(?:\?.*)?$',
  caseSensitive: false,
);
final _filePath = RegExp(
  r'^(?:file:|/|[~.][\\/]|\.\.[\\/]|[a-z]:[\\/]|\\\\)',
  caseSensitive: false,
);
final _producerTool = RegExp(
  r'(?:^|_)(?:creat(?:e|ion)|download|export|generat(?:e|ion)|render|save|speech|tts|write)(?:_|$)',
  caseSensitive: false,
);
final _strongKey = RegExp(
  r'^(?:artifact_(?:file|image|path|url)|files?_(?:created|modified|written)|generated_(?:file|image|path|url)|media_tag|output_(?:file|path|url)|result_(?:file|path|url)|saved_to|screenshot_path)$',
  caseSensitive: false,
);
final _producerKey = RegExp(
  r'^(?:artifact(?:s|_(?:file|image|path|url))?|attachment(?:s|_(?:file|image|path|url))?|download(?:s|_(?:file|path|url))?|(?:audio|image|video)(?:_(?:file|path|url))?|file_path|local_path|media(?:_(?:file|path|url))?|path)$',
  caseSensitive: false,
);
final _shellOutputKey = RegExp(r'^(?:output|stdout|path)$', caseSensitive: false);
final _screenshotPath = RegExp(
  r'Screenshot path:\s*([^\r\n<>]+)',
  caseSensitive: false,
);
final _pipCacheDir = RegExp(
  r'/(?:\.cache/pip|library/caches/pip|appdata/local/pip/cache)/',
);
final _wheel = RegExp(r'\.whl(?:\.metadata)?$');
final _packageIndexDist = RegExp(
  r'/packages/.+\.(?:tar\.gz|tar\.bz2|zip|egg)(?:\.metadata)?$',
);
final _index = RegExp(r'^\d+$');

const _maxUnixSeconds = 10000000000;

typedef _Push = void Function(String value, {bool explicit});

bool _isFilePath(String v) => _filePath.hasMatch(v);

String _pathForFiltering(String value) {
  if (RegExp(r'^(?:https?|file)://', caseSensitive: false).hasMatch(value)) {
    final uri = Uri.tryParse(value);
    if (uri != null) {
      try {
        return Uri.decodeComponent(uri.path).toLowerCase();
      } on ArgumentError {
        // fall through
      }
    }
  }
  return value.replaceAll(r'\', '/').toLowerCase();
}

bool _isPythonPackageDownload(String value) {
  final path = _pathForFiltering(value);
  return _pipCacheDir.hasMatch(path) ||
      _wheel.hasMatch(path) ||
      (RegExp(r'^https?://', caseSensitive: false).hasMatch(value) &&
          _packageIndexDist.hasMatch(path));
}

bool _looksLikeArtifact(String value, {bool explicit = false}) {
  if (!explicit && _isPythonPackageDownload(value)) return false;
  if (RegExp(r'^(?:https?://|data:image/)').hasMatch(value)) return true;
  final pathOrUrl =
      value.startsWith('http://') ||
      value.startsWith('https://') ||
      value.startsWith('data:image/') ||
      _isFilePath(value);
  if (!pathOrUrl) return false;
  if (explicit) return true;
  return _imageExt.hasMatch(value) || _fileExt.hasMatch(value);
}

HmArtifactKind _kindOf(String value) {
  if (value.startsWith('data:image/') || _imageExt.hasMatch(value)) {
    return HmArtifactKind.image;
  }
  if (_isFilePath(value)) return HmArtifactKind.file;
  return HmArtifactKind.link;
}

String _normalize(String value) {
  var t = value.trim();
  for (var i = 0; i < 3; i++) {
    if (t.length >= 2) {
      final q = t[0];
      if ((q == '"' || q == "'" || q == '`') && t.endsWith(q)) {
        t = t.substring(1, t.length - 1).trim();
        continue;
      }
    }
    break;
  }
  return t
      .replaceFirst(RegExp(r'[`*]+$'), '')
      .replaceFirst(RegExp(r'[),.;]+$'), '');
}

/// Chat renders file refs as `[label](#media:<encoded path>)`.
String _decodeMediaHref(String value) {
  if (!value.startsWith('#media:')) return value;
  try {
    return Uri.decodeComponent(value.substring('#media:'.length));
  } on ArgumentError {
    return value;
  }
}

void _collectMedia(String text, _Push push) {
  for (final ref in extractMediaTagRefs(text)) {
    push(ref.path, explicit: true);
  }
}

void _collectFromText(String text, _Push push) {
  _collectMedia(text, push);
  for (final m in _markdownImage.allMatches(text)) {
    push(m.group(2) ?? '');
  }
  for (final m in _markdownLink.allMatches(text)) {
    if (m.start > 0 && text[m.start - 1] == '!') continue;
    final value = _decodeMediaHref(m.group(2) ?? '');
    if (_looksLikeArtifact(value)) push(value);
  }
  for (final m in _url.allMatches(text)) {
    final value = m.group(0) ?? '';
    if (_looksLikeArtifact(value)) push(value);
  }
  for (final m in _path.allMatches(text)) {
    push(m.group(2) ?? '');
  }
  for (final m in _windowsPath.allMatches(text)) {
    push(m.group(2) ?? '');
  }
}

String _messageText(Map<String, dynamic> m) {
  for (final key in const ['content', 'text', 'context']) {
    final v = m[key];
    if (v is String && v.trim().isNotEmpty) return v;
  }
  return '';
}

Object? _parseJson(String value) {
  if (value.trim().isEmpty) return null;
  try {
    return jsonDecode(value);
  } on FormatException {
    return null;
  }
}

String? _untrustedToolPayload(String value) {
  final trimmed = value.trim();
  final open = RegExp(r'^<untrusted_tool_result\b[^>]*>\s*').firstMatch(trimmed);
  if (open == null) return null;
  final close = trimmed.lastIndexOf('</untrusted_tool_result>');
  if (close <= open.end) return null;
  final wrapped = trimmed.substring(open.end, close).trim();
  final start = wrapped.indexOf('\n\n');
  return (start == -1 ? wrapped : wrapped.substring(start + 2)).trim();
}

void _collectStrings(
  Object? value,
  String keyPath,
  void Function(String value, String keyPath) collector,
) {
  if (value is String) {
    collector(value, keyPath);
  } else if (value is List) {
    for (var i = 0; i < value.length; i++) {
      _collectStrings(value[i], '$keyPath.$i', collector);
    }
  } else if (value is Map) {
    for (final e in value.entries) {
      final k = '${e.key}';
      _collectStrings(e.value, keyPath.isEmpty ? k : '$keyPath.$k', collector);
    }
  }
}

List<String> _segments(String keyPath) => keyPath
    .split('.')
    .where((s) => s.isNotEmpty && !_index.hasMatch(s))
    .toList();

void _collectFromMessage(Map<String, dynamic> m, _Push push) {
  final role = m['role'];
  final text = _messageText(m);
  if (role == 'assistant') {
    if (text.isNotEmpty) _collectFromText(text, push);
    return;
  }
  if (role != 'tool') return;

  final name = ((m['tool_name'] ?? m['name'] ?? '') as Object)
      .toString()
      .trim()
      .toLowerCase();
  final producer = _producerTool.hasMatch(name) || name.startsWith('bfl_flux3_');
  final terminal = name == 'terminal';

  final payloads = <Object?>[];
  for (final candidate in [text, _untrustedToolPayload(text)]) {
    if (candidate == null) continue;
    final parsed = _parseJson(candidate);
    if (parsed != null) payloads.add(parsed);
  }

  // A JSON result is read key by key below; scanning its raw text too would
  // run paths and URLs together across escaped newlines.
  final rawIsJson = payloads.isNotEmpty;
  if (text.isNotEmpty && !rawIsJson && (producer || terminal)) {
    _collectFromText(text, push);
  }
  if (name == 'browser_vision' && text.isNotEmpty) {
    for (final s in _screenshotPath.allMatches(text)) {
      push(s.group(1) ?? '');
    }
  }
  final content = m['content'];
  if (content is Map) {
    payloads.add(content['_multimodal'] == true ? content['meta'] : content);
  } else if (content is List) {
    payloads.add(content);
  }

  for (final parsed in payloads) {
    if (parsed == null) continue;
    _collectStrings(parsed, 'tool_result', (value, keyPath) {
      final segments = _segments(keyPath);
      final shellOutput =
          terminal && segments.any((s) => _shellOutputKey.hasMatch(s));
      final explicitKey = segments.any(
        (s) =>
            _strongKey.hasMatch(s) || (producer && _producerKey.hasMatch(s)),
      );
      if (!shellOutput && !explicitKey) return;
      if (shellOutput) {
        if (value.isNotEmpty) _collectFromText(value, push);
        return;
      }
      _collectMedia(value, push);
      final normalized = _normalize(_decodeMediaHref(value));
      if (normalized.isNotEmpty && _looksLikeArtifact(normalized)) {
        push(normalized);
      }
    });
  }
}

int? _ms(Object? t) {
  final n = t is num ? t : (t is String ? num.tryParse(t) : null);
  if (n == null || !n.isFinite || n <= 0) return null;
  return n < _maxUnixSeconds ? (n * 1000).round() : n.round();
}

/// Artifacts in [messages] (one page of a session), first occurrence wins.
List<HmArtifact> scanArtifacts({
  required String sessionId,
  required String sessionTitle,
  required List<Map<String, dynamic>> messages,
  double sessionLastActive = 0,
  int Function()? now,
}) {
  final found = <String, HmArtifact>{};
  for (final m in messages) {
    final role = m['role'];
    if (role != 'assistant' && role != 'tool') continue;
    _collectFromMessage(m, (candidate, {bool explicit = false}) {
      final value = _normalize(_decodeMediaHref(candidate));
      if (value.isEmpty || !_looksLikeArtifact(value, explicit: explicit)) {
        return;
      }
      final key = '$sessionId:$value';
      if (found.containsKey(key)) return;
      found[key] = HmArtifact(
        kind: _kindOf(value),
        value: value,
        sessionId: sessionId,
        sessionTitle: sessionTitle,
        timestamp:
            _ms(m['timestamp']) ??
            _ms(sessionLastActive) ??
            (now ?? () => DateTime.now().millisecondsSinceEpoch)(),
      );
    });
  }
  return found.values.toList();
}
