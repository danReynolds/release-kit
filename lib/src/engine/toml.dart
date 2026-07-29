import 'diagnostic.dart';

/// A parser for exactly the TOML subset `release.toml` uses, and nothing more.
///
/// Writing the parser narrowly rather than filtering a general one is the
/// point: a construct the schema does not allow has no representation here, so
/// it fails by construction rather than by a validation pass that has to
/// remember to reject it. The accepted grammar is:
///
/// * comments (`# ...`) and blank lines
/// * bare keys matching `[A-Za-z0-9_-]+`
/// * values: basic strings (`"..."`), non-negative integers, and arrays of
///   basic strings, optionally spread over lines with a trailing comma
/// * tables (`[a.b]`) and array-of-table headers (`[[a.b]]`)
///
/// Deliberately absent: inline tables, multi-line or literal strings, floats,
/// booleans, dates, exponents, underscores in numbers, dotted keys, quoted
/// keys, and nested arrays.
class TomlDocument {
  TomlDocument._(this.root);

  /// The parsed tree: [TomlTable] and [TomlArray] nodes with String, int, and
  /// `List<String>` leaves.
  final TomlTable root;

  static TomlDocument? parse(
    String source,
    String path,
    Diagnostics diagnostics,
  ) {
    final parser = _Parser(source, path, diagnostics);
    final root = parser.run();
    return root == null ? null : TomlDocument._(root);
  }
}

/// A table, remembering where each key was written so a later problem can
/// point a reader at the line that caused it.
class TomlTable {
  TomlTable(this.location);

  final SourceLocation location;
  final Map<String, Object> values = {};
  final Map<String, SourceLocation> keyLocations = {};

  Object? operator [](String key) => values[key];
  bool has(String key) => values.containsKey(key);
  Iterable<String> get keys => values.keys;

  SourceLocation locationOf(String key) => keyLocations[key] ?? location;
}

/// An array of tables, as produced by `[[a.b]]` headers.
class TomlArray {
  TomlArray(this.location);

  final SourceLocation location;
  final List<TomlTable> tables = [];
}

class _Parser {
  _Parser(this._source, this._path, this._diagnostics);

  final String _source;
  final String _path;
  final Diagnostics _diagnostics;

  late TomlTable _root;
  late TomlTable _current;
  late List<String> _lines;

  /// Zero-based cursor into [_lines]. A multi-line value advances it past the
  /// lines it consumed, so the driving loop must read it rather than own it.
  var _cursor = 0;
  var _failed = false;

  /// One-based line number of the line being parsed, for diagnostics.
  int get _line => _cursor + 1;

  static final _bareKey = RegExp(r'^[A-Za-z0-9_-]+$');

  TomlTable? run() {
    _root = TomlTable(SourceLocation(_path, 1));
    _current = _root;

    _lines = _source.split('\n');
    for (_cursor = 0; _cursor < _lines.length; _cursor++) {
      final text = _stripComment(_lines[_cursor]).trim();
      if (text.isEmpty) continue;

      if (text.startsWith('[[')) {
        _arrayHeader(text);
      } else if (text.startsWith('[')) {
        _tableHeader(text);
      } else {
        _assignment(text);
      }
    }
    return _failed ? null : _root;
  }

  /// Removes a trailing comment, respecting quotes so a `#` inside a string
  /// survives.
  String _stripComment(String line) {
    var inString = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        // A quote escaped with a backslash does not end the string.
        if (i > 0 && line[i - 1] == r'\') continue;
        inString = !inString;
      } else if (ch == '#' && !inString) {
        return line.substring(0, i);
      }
    }
    return line;
  }

  void _fail(String message, {String? remedy}) {
    _failed = true;
    _diagnostics.add(
      'RK-TOML-001',
      message,
      source: SourceLocation(_path, _line),
      remedy: remedy,
    );
  }

  void _tableHeader(String text) {
    if (!text.endsWith(']')) {
      _fail('unterminated table header');
      return;
    }
    final path = _headerPath(text.substring(1, text.length - 1));
    if (path == null) return;
    final table = _descend(path, createArray: false);
    if (table != null) _current = table;
  }

  void _arrayHeader(String text) {
    if (!text.endsWith(']]')) {
      _fail('unterminated array-of-tables header');
      return;
    }
    final path = _headerPath(text.substring(2, text.length - 2));
    if (path == null) return;
    final table = _descend(path, createArray: true);
    if (table != null) _current = table;
  }

  List<String>? _headerPath(String inner) {
    final path = inner.split('.').map((s) => s.trim()).toList();
    if (path.isEmpty || path.any((s) => !_bareKey.hasMatch(s))) {
      _fail(
        'table names must be dot-separated bare keys',
        remedy: 'use letters, digits, hyphens and underscores, as in '
            '[release.cli]',
      );
      return null;
    }
    return path;
  }

  /// Walks or creates the tables named by [path], appending a new element when
  /// the final segment names an array of tables.
  TomlTable? _descend(List<String> path, {required bool createArray}) {
    var table = _root;
    for (var i = 0; i < path.length; i++) {
      final key = path[i];
      final last = i == path.length - 1;
      final existing = table.values[key];

      if (last && createArray) {
        final array = switch (existing) {
          null => TomlArray(SourceLocation(_path, _line)),
          TomlArray a => a,
          _ => null,
        };
        if (array == null) {
          _fail('"$key" is already defined as something other than a list');
          return null;
        }
        table.values[key] = array;
        table.keyLocations.putIfAbsent(
          key,
          () => SourceLocation(_path, _line),
        );
        final element = TomlTable(SourceLocation(_path, _line));
        array.tables.add(element);
        return element;
      }

      switch (existing) {
        case null:
          final child = TomlTable(SourceLocation(_path, _line));
          table.values[key] = child;
          table.keyLocations.putIfAbsent(
            key,
            () => SourceLocation(_path, _line),
          );
          table = child;
        case TomlTable child:
          if (last && !createArray && child.values.isNotEmpty) {
            _fail('table "${path.join('.')}" is defined more than once');
            return null;
          }
          table = child;
        case TomlArray array:
          // Later headers extend the most recent element, so
          // [[release.framework.project]] followed by [release.framework.x]
          // resolves against the element just opened.
          if (array.tables.isEmpty) {
            _fail('"$key" has no entries to extend');
            return null;
          }
          table = array.tables.last;
        default:
          _fail('"$key" is a value, not a table');
          return null;
      }
    }
    return table;
  }

  void _assignment(String text) {
    final equals = text.indexOf('=');
    if (equals < 0) {
      _fail(
        'expected a key = value assignment',
        remedy: 'every line is a comment, a table header, or an assignment',
      );
      return;
    }
    final key = text.substring(0, equals).trim();
    if (!_bareKey.hasMatch(key)) {
      _fail(
        'keys must be bare: "$key"',
        remedy: 'use letters, digits, hyphens and underscores, unquoted',
      );
      return;
    }
    if (_current.has(key)) {
      _fail('"$key" is assigned more than once in this table');
      return;
    }

    final raw = text.substring(equals + 1).trim();
    final value = _value(raw);
    if (value == null) return;
    _current.values[key] = value;
    _current.keyLocations[key] = SourceLocation(_path, _line);
  }

  Object? _value(String raw) {
    if (raw.isEmpty) {
      _fail('missing value');
      return null;
    }
    if (raw.startsWith('[')) return _array(raw);
    if (raw.startsWith('"')) return _string(raw);
    return _integer(raw);
  }

  String? _string(String raw) {
    if (raw.length < 2 || !raw.endsWith('"')) {
      _fail('unterminated string');
      return null;
    }
    final body = raw.substring(1, raw.length - 1);
    if (body.contains('"')) {
      _fail('a string may not contain an unescaped quote');
      return null;
    }
    if (body.contains(r'\')) {
      _fail(
        'escape sequences are not part of this schema',
        remedy: 'values here are plain text: paths, names and patterns',
      );
      return null;
    }
    return body;
  }

  int? _integer(String raw) {
    final value = int.tryParse(raw);
    if (value == null || value < 0 || raw != value.toString()) {
      _fail(
        'expected a string, a non-negative integer, or a list: "$raw"',
        remedy: 'quote text values, as in path = "packages/keybay"',
      );
      return null;
    }
    return value;
  }

  /// Arrays may span lines, so following lines are consumed until the closing
  /// bracket, and the cursor is left on the last line consumed.
  List<String>? _array(String raw) {
    final buffer = StringBuffer(raw);
    var index = _cursor;
    while (!_isBalanced(buffer.toString())) {
      index++;
      if (index >= _lines.length) {
        _fail('unterminated list');
        return null;
      }
      buffer.write(' ');
      buffer.write(_stripComment(_lines[index]).trim());
    }
    // The driving loop increments past this line, so stop on the last one
    // consumed rather than the one after it.
    _cursor = index;

    final text = buffer.toString().trim();
    final inner = text.substring(1, text.length - 1).trim();
    if (inner.isEmpty) return const [];

    final items = <String>[];
    for (final part in inner.split(',')) {
      final item = part.trim();
      if (item.isEmpty) continue; // a trailing comma is fine
      if (!item.startsWith('"')) {
        _fail(
          'lists hold quoted strings: "$item"',
          remedy: 'as in publish = ["pub.dev", "github-release"]',
        );
        return null;
      }
      final value = _string(item);
      if (value == null) return null;
      items.add(value);
    }
    return items;
  }

  bool _isBalanced(String text) {
    var depth = 0;
    var inString = false;
    for (final ch in text.split('')) {
      if (ch == '"') inString = !inString;
      if (inString) continue;
      if (ch == '[') depth++;
      if (ch == ']') depth--;
    }
    return depth == 0 && text.contains(']');
  }
}
