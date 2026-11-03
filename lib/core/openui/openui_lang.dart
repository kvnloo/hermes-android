/// Pure Dart OpenUI 1.0.2 subset: literals, positional calls, assignments,
/// objects, arrays, and references. No expression evaluation or tool authority.
library;

import 'dart:convert';

enum OpenUiParseStatus { ready, incomplete, invalid }

final class OpenUiProblem {
  const OpenUiProblem(this.message, this.line, this.column);
  final String message;
  final int line;
  final int column;
  @override
  String toString() => '$line:$column: $message';
}

sealed class OpenUiValue {
  const OpenUiValue(this.line, this.column);
  final int line;
  final int column;
}

final class OpenUiString extends OpenUiValue {
  const OpenUiString(super.line, super.column, this.value);
  final String value;
}

final class OpenUiNumber extends OpenUiValue {
  const OpenUiNumber(super.line, super.column, this.value);
  final double value;
}

final class OpenUiBoolean extends OpenUiValue {
  const OpenUiBoolean(super.line, super.column, this.value);
  final bool value;
}

final class OpenUiNull extends OpenUiValue {
  const OpenUiNull(super.line, super.column);
}

final class OpenUiArray extends OpenUiValue {
  const OpenUiArray(super.line, super.column, this.items);
  final List<OpenUiValue> items;
}

final class OpenUiObject extends OpenUiValue {
  const OpenUiObject(super.line, super.column, this.fields);
  final Map<String, OpenUiValue> fields;
}

final class OpenUiCall extends OpenUiValue {
  const OpenUiCall(super.line, super.column, this.name, this.args);
  final String name;
  final List<OpenUiValue> args;
}

/// Intermediate only; ready programs have their references resolved.
final class OpenUiReference extends OpenUiValue {
  const OpenUiReference(super.line, super.column, this.name);
  final String name;
}

final class OpenUiProgram {
  const OpenUiProgram(this.assignments, this.root);
  final Map<String, OpenUiValue> assignments;
  final OpenUiValue root;
}

final class OpenUiParseResult {
  const OpenUiParseResult(this.status, {this.program, this.problem});
  final OpenUiParseStatus status;
  final OpenUiProgram? program;
  final OpenUiProblem? problem;
}

final class OpenUiLang {
  const OpenUiLang._();
  static const maxSourceBytes = 65536;

  static OpenUiParseResult parse(String source) {
    if (utf8.encode(source).length > maxSourceBytes) {
      return const OpenUiParseResult(
        OpenUiParseStatus.invalid,
        problem: OpenUiProblem('Chart board exceeds the 64 KiB limit.', 1, 1),
      );
    }
    try {
      final declarations = _Reader(_Scanner(source).scan()).read();
      if (!declarations.containsKey('root')) {
        return const OpenUiParseResult(
          OpenUiParseStatus.incomplete,
          problem: OpenUiProblem('Missing root assignment.', 1, 1),
        );
      }
      final resolved = <String, OpenUiValue>{};
      OpenUiValue resolve(OpenUiValue value, Set<String> stack) {
        switch (value) {
          case OpenUiReference():
            final name = value.name;
            if (stack.contains(name)) {
              throw _Fault('Cyclic reference: $name.', value.line, value.column);
            }
            final raw = declarations[name];
            if (raw == null) {
              throw _Fault('Unresolved reference: $name.', value.line,
                  value.column, incomplete: true);
            }
            final cached = resolved[name];
            if (cached != null) return cached;
            final result = resolve(raw, {...stack, name});
            resolved[name] = result;
            return result;
          case OpenUiArray():
            return OpenUiArray(value.line, value.column,
                List.unmodifiable(value.items.map((v) => resolve(v, stack))));
          case OpenUiObject():
            return OpenUiObject(
              value.line,
              value.column,
              Map.unmodifiable(value.fields.map(
                (key, v) => MapEntry(key, resolve(v, stack)),
              )),
            );
          case OpenUiCall():
            return OpenUiCall(value.line, value.column, value.name,
                List.unmodifiable(value.args.map((v) => resolve(v, stack))));
          default:
            return value;
        }
      }

      // Also inspect declarations not referenced by the root. They must not
      // conceal unresolved names, cycles or unsupported syntax.
      for (final declaration in declarations.entries) {
        if (!resolved.containsKey(declaration.key)) {
          resolved[declaration.key] =
              resolve(declaration.value, {declaration.key});
        }
      }
      return OpenUiParseResult(
        OpenUiParseStatus.ready,
        program: OpenUiProgram(Map.unmodifiable(resolved), resolved['root']!),
      );
    } on _Fault catch (e) {
      return OpenUiParseResult(
        e.incomplete ? OpenUiParseStatus.incomplete : OpenUiParseStatus.invalid,
        problem: OpenUiProblem(e.message, e.line, e.column),
      );
    }
  }
}

final class _Fault implements Exception {
  const _Fault(this.message, this.line, this.column,
      {this.incomplete = false});
  final String message;
  final int line;
  final int column;
  final bool incomplete;
}

enum _Kind {
  name, string, number, equal, lParen, rParen, lBracket, rBracket,
  lBrace, rBrace, comma, colon, separator, eof
}

final class _Token {
  const _Token(this.kind, this.text, this.line, this.column);
  final _Kind kind;
  final String text;
  final int line;
  final int column;
}

final class _Scanner {
  _Scanner(this.source);
  final String source;
  static final _number =
      RegExp(r'^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?');
  static final _name = RegExp(r'^[A-Za-z_][A-Za-z_0-9]*');
  int _index = 0;
  int _line = 1;
  int _column = 1;
  bool get _end => _index == source.length;
  String get _char => source[_index];

  String _advance() {
    final c = source[_index++];
    if (c == '\n') {
      _line++;
      _column = 1;
    } else {
      _column++;
    }
    return c;
  }

  List<_Token> scan() {
    final tokens = <_Token>[];
    while (!_end) {
      final line = _line;
      final col = _column;
      final c = _char;
      if (c == ' ' || c == '\t' || c == '\r') {
        _advance();
        continue;
      }
      if (c == '#' || source.startsWith('//', _index)) {
        while (!_end && _char != '\n') {
          _advance();
        }
        continue;
      }
      if (c == '"' || c == "'") {
        tokens.add(_Token(_Kind.string, _string(c, line, col), line, col));
        continue;
      }
      const punctuation = <String, _Kind>{
        '=': _Kind.equal, '(': _Kind.lParen, ')': _Kind.rParen,
        '[': _Kind.lBracket, ']': _Kind.rBracket,
        '{': _Kind.lBrace, '}': _Kind.rBrace,
        ',': _Kind.comma, ':': _Kind.colon,
        '\n': _Kind.separator, ';': _Kind.separator,
      };
      if (punctuation.containsKey(c)) {
        tokens.add(_Token(punctuation[c]!, _advance(), line, col));
        continue;
      }
      if (RegExp(r'[A-Za-z_]').hasMatch(c)) {
        final word = _name.firstMatch(source.substring(_index))!.group(0)!;
        for (var i = 0; i < word.length; i++) {
          _advance();
        }
        tokens.add(_Token(_Kind.name, word, line, col));
        continue;
      }
      if (RegExp(r'[0-9-]').hasMatch(c)) {
        final number = _number.firstMatch(source.substring(_index))?.group(0);
        if (number == null) throw _Fault('Invalid number.', line, col);
        for (var i = 0; i < number.length; i++) {
          _advance();
        }
        tokens.add(_Token(_Kind.number, number, line, col));
        continue;
      }
      throw _Fault('Unexpected character "$c".', line, col);
    }
    tokens.add(_Token(_Kind.eof, '', _line, _column));
    return tokens;
  }

  String _string(String quote, int line, int col) {
    _advance();
    final out = StringBuffer();
    while (!_end) {
      final c = _advance();
      if (c == quote) return out.toString();
      if (c == '\n') throw _Fault('Newline inside string.', line, col);
      if (c.codeUnitAt(0) != 92) {
        out.write(c);
        continue;
      }
      if (_end) {
        throw _Fault('Unterminated string.', line, col, incomplete: true);
      }
      final esc = _advance();
      switch (esc) {
        case 'n': out.write('\n');
        case 'r': out.write('\r');
        case 't': out.write('\t');
        case 'b': out.write('\b');
        case 'f': out.write('\f');
        case '"': out.write('"');
        case "'": out.write("'");
        case '/': out.write('/');
        case 'u':
          if (_index + 4 > source.length) {
            throw _Fault('Incomplete Unicode escape.', line, col,
                incomplete: true);
          }
          final hex = source.substring(_index, _index + 4);
          if (!RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(hex)) {
            throw _Fault('Invalid Unicode escape.', line, col);
          }
          for (var i = 0; i < 4; i++) {
            _advance();
          }
          out.write(String.fromCharCode(int.parse(hex, radix: 16)));
        default:
          if (esc.codeUnitAt(0) == 92) {
            out.writeCharCode(92);
          } else {
            throw _Fault('Invalid string escape.', line, col);
          }
      }
    }
    throw _Fault('Unterminated string.', line, col, incomplete: true);
  }
}

final class _Reader {
  _Reader(this.tokens);
  final List<_Token> tokens;
  int _index = 0;
  _Token get _current => tokens[_index];
  _Token _take() => tokens[_index++];

  void _lines() {
    while (_current.kind == _Kind.separator) {
      _take();
    }
  }

  _Token _expect(_Kind kind, String label) {
    _lines();
    final token = _current;
    if (token.kind == kind) return _take();
    throw _Fault('Expected $label.', token.line, token.column,
        incomplete: token.kind == _Kind.eof);
  }

  Map<String, OpenUiValue> read() {
    final result = <String, OpenUiValue>{};
    _lines();
    while (_current.kind != _Kind.eof) {
      final key = _expect(_Kind.name, 'assignment name');
      if (const ['true', 'false', 'null'].contains(key.text)) {
        throw _Fault('Literal cannot be an assignment name.',
            key.line, key.column);
      }
      _expect(_Kind.equal, '"="');
      final value = _value(0);
      if (result.containsKey(key.text)) {
        throw _Fault('Duplicate assignment: ' + key.text,
            key.line, key.column);
      }
      result[key.text] = value;
      if (_current.kind != _Kind.separator &&
          _current.kind != _Kind.eof) {
        throw _Fault('Expected a new assignment on a new line.',
            _current.line, _current.column);
      }
      _lines();
    }
    return result;
  }

  OpenUiValue _value(int depth) {
    if (depth > 80) {
      throw _Fault('Nesting limit exceeded.', _current.line, _current.column);
    }
    _lines();
    final token = _take();
    switch (token.kind) {
      case _Kind.string:
        return OpenUiString(token.line, token.column, token.text);
      case _Kind.number:
        final value = double.tryParse(token.text);
        if (value == null || !value.isFinite) {
          throw _Fault('Invalid finite number.', token.line, token.column);
        }
        return OpenUiNumber(token.line, token.column, value);
      case _Kind.name:
        if (token.text == 'true' || token.text == 'false') {
          return OpenUiBoolean(
              token.line, token.column, token.text == 'true');
        }
        if (token.text == 'null') {
          return OpenUiNull(token.line, token.column);
        }
        if (_current.kind != _Kind.lParen) {
          return OpenUiReference(token.line, token.column, token.text);
        }
        _take();
        return OpenUiCall(token.line, token.column, token.text,
            List.unmodifiable(_sequence(depth, _Kind.rParen)));
      case _Kind.lBracket:
        return OpenUiArray(token.line, token.column,
            List.unmodifiable(_sequence(depth, _Kind.rBracket)));
      case _Kind.lBrace:
        final fields = <String, OpenUiValue>{};
        _lines();
        while (_current.kind != _Kind.rBrace) {
          if (_current.kind == _Kind.eof) {
            throw _Fault('Unclosed object.', _current.line,
                _current.column, incomplete: true);
          }
          final key = _current;
          if (key.kind != _Kind.name && key.kind != _Kind.string) {
            throw _Fault('Expected object key.', key.line, key.column);
          }
          _take();
          _expect(_Kind.colon, '":"');
          if (fields.containsKey(key.text)) {
            throw _Fault('Duplicate object key: ' + key.text,
                key.line, key.column);
          }
          fields[key.text] = _value(depth + 1);
          _lines();
          if (_current.kind == _Kind.rBrace) break;
          _expect(_Kind.comma, '","');
          _lines();
        }
        _take();
        return OpenUiObject(
            token.line, token.column, Map.unmodifiable(fields));
      case _Kind.eof:
        throw _Fault('Incomplete expression.', token.line,
            token.column, incomplete: true);
      default:
        throw _Fault('Expected a literal, reference or call.',
            token.line, token.column);
    }
  }

  List<OpenUiValue> _sequence(int depth, _Kind closer) {
    final items = <OpenUiValue>[];
    _lines();
    while (_current.kind != closer) {
      if (_current.kind == _Kind.eof) {
        throw _Fault('Unclosed call or array.', _current.line,
            _current.column, incomplete: true);
      }
      items.add(_value(depth + 1));
      _lines();
      if (_current.kind == closer) break;
      _expect(_Kind.comma, '","');
      _lines();
    }
    _take();
    return items;
  }
}
