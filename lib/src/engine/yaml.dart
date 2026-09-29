import 'diagnostic.dart';

/// A reader for the block-style YAML subset a pubspec is written in.
///
/// It reads the whole document rather than only the keys rk needs, so an
/// unfamiliar field is carried rather than rejected — refusing a package for
/// declaring `topics:` would be absurd. Fail-closed applies where it matters:
/// a key rk *interprets* must have the shape rk expects, which the typed
/// accessors enforce.
///
/// Accepted: block maps, block sequences, flow sequences and mappings (`[a, b]`,
/// `{path: ../core}`, on one line or continued over several), plain and quoted
/// scalars, folded and literal block scalars (whose content is kept opaque,
/// since rk never reads a description). Absent: anchors, aliases, tags,
/// multiple documents, and tabs for indentation.
sealed class YamlNode {
  const YamlNode(this.line);

  /// One-based line where this node began.
  final int line;
}

class YamlScalar extends YamlNode {
  const YamlScalar(this.value, super.line, {this.quoted = false});
  final String value;
  final bool quoted;
}

class YamlMap extends YamlNode {
  YamlMap(super.line);
  final Map<String, YamlNode> entries = {};

  YamlNode? operator [](String key) => entries[key];
  bool has(String key) => entries.containsKey(key);
  Iterable<String> get keys => entries.keys;

  /// The scalar at [key], or null when absent or not a scalar.
  String? string(String key) {
    final node = entries[key];
    return node is YamlScalar ? node.value : null;
  }

  YamlMap? map(String key) {
    final node = entries[key];
    return node is YamlMap ? node : null;
  }

  YamlList? list(String key) {
    final node = entries[key];
    return node is YamlList ? node : null;
  }

  int lineOf(String key) => entries[key]?.line ?? line;
}

class YamlList extends YamlNode {
  YamlList(super.line);
  final List<YamlNode> items = [];

  /// The scalar items, skipping anything more structured.
  List<String> get strings =>
      items.whereType<YamlScalar>().map((s) => s.value).toList();
}

/// Parses [source] into a tree, or records why it could not.
YamlMap? parseYaml(String source, String path, Diagnostics diagnostics) {
  final parser = _Parser(source, path, diagnostics);
  return parser.run();
}

class _Parser {
  _Parser(String source, this._path, this._diagnostics)
    : _lines = source.split('\n');

  final List<String> _lines;
  final String _path;
  final Diagnostics _diagnostics;
  var _cursor = 0;
  var _failed = false;

  YamlMap? run() {
    final root = _block(0);
    if (_failed) return null;
    if (root is YamlMap) return root;
    // An empty document is a map with nothing in it.
    return YamlMap(1);
  }

  void _fail(String message, int line, {String? remedy}) {
    _failed = true;
    _diagnostics.add(
      'RK-YAML-001',
      message,
      source: SourceLocation(_path, line),
      remedy: remedy,
    );
  }

  /// Reads every entry indented at least [indent], as a map or a sequence
  /// depending on what the first meaningful line looks like.
  ///
  /// [dashIndent] is the column a block sequence may also begin at, which YAML
  /// allows to be the parent key's own column:
  ///
  ///     topics:
  ///     - security
  ///
  /// Keeping the two thresholds apart is what lets a key at the parent's column
  /// close the sequence while a key indented *into* it is refused instead of
  /// escaping to the enclosing map.
  YamlNode? _block(int indent, {int? dashIndent}) {
    final dashFrom = dashIndent ?? indent;
    YamlMap? asMap;
    YamlList? asList;

    while (_cursor < _lines.length) {
      final raw = _lines[_cursor];
      final line = _cursor + 1;
      final text = _strip(raw);
      if (text.trim().isEmpty) {
        _cursor++;
        continue;
      }

      final at = _indentOf(raw);
      if (at < 0) {
        _fail(
          'indentation must use spaces, not tabs',
          line,
          remedy: 'YAML forbids tabs for indentation',
        );
        return null;
      }

      final body = text.trim();
      final isDash = body.startsWith('- ') || body == '-';

      // Belongs to an enclosing block.
      if (at < (isDash ? dashFrom : indent)) break;

      if (isDash) {
        asList ??= YamlList(line);
        if (asMap != null) {
          _fail('a block cannot mix map keys and list items', line);
          return null;
        }
        final item = body == '-' ? '' : body.substring(2).trim();

        if (_opensFlow(item)) {
          _cursor++;
          final node = _flow(item, line);
          if (node == null) return null;
          asList.items.add(node);
        } else if (item.isEmpty) {
          _cursor++;
          final nested = _block(at + 1);
          if (_failed) return null;
          if (nested != null) asList.items.add(nested);
        } else if (_keyColon(item) >= 0) {
          // A map written on the dash line, as pub.dev's screenshots are:
          //   - description: a shot
          //     path: doc/shot.png
          // The remaining keys are indented to where the dash text starts, so
          // the line is rewritten without its dash and the whole block is read
          // as one map. Without this the first key becomes a scalar and the
          // rest are read into the *enclosing* map — which would let an
          // unrelated field overwrite the package's version.
          _lines[_cursor] = ' ' * (at + 2) + item;
          final nested = _block(at + 2);
          if (_failed) return null;
          if (nested != null) asList.items.add(nested);
        } else {
          _cursor++;
          asList.items.add(YamlScalar(_unquote(item), line));
        }
        continue;
      }

      // A key indented into a sequence's own block is neither an item nor a
      // sibling of the key that opened it. Letting it break out to the
      // enclosing map is how a stray `version:` under `topics:` becomes the
      // package's version, so it is refused where a sibling would have closed
      // the sequence by being less indented.
      if (asList != null) {
        _fail(
          'a block cannot mix list items and map keys',
          line,
          remedy: 'outdent "$body" to end the list above it',
        );
        return null;
      }

      final colon = _keyColon(body);
      if (colon < 0) {
        _fail(
          'expected "key: value"',
          line,
          remedy: 'rk reads the block-style YAML a pubspec is written in',
        );
        return null;
      }

      final key = _unquote(body.substring(0, colon).trim());
      final rest = body.substring(colon + 1).trim();
      asMap ??= YamlMap(line);

      // YAML forbids duplicate keys, and a manifest with two version: lines is
      // the fail-closed case rather than a style question.
      if (asMap.entries.containsKey(key)) {
        _fail(
          '"$key" is set more than once',
          line,
          remedy: 'the earlier value is at line ${asMap.entries[key]!.line}',
        );
        return null;
      }
      _cursor++;

      if (_opensFlow(rest)) {
        final node = _flow(rest, line);
        if (node == null) return null;
        asMap.entries[key] = node;
      } else if (rest.isEmpty) {
        // A nested block, or a key with no value at all. Its sequence may begin
        // back at this key's own column.
        final nested = _block(at + 1, dashIndent: at);
        if (_failed) return null;
        asMap.entries[key] = nested ?? YamlScalar('', line);
      } else if (rest.startsWith('>') || rest.startsWith('|')) {
        // A folded or literal scalar: kept opaque, since nothing rk reads is
        // ever written this way.
        asMap.entries[key] = YamlScalar(_blockScalar(at), line);
      } else {
        asMap.entries[key] = YamlScalar(
          _unquote(rest),
          line,
          quoted: rest.startsWith('"') || rest.startsWith("'"),
        );
      }
    }

    return asMap ?? asList;
  }

  bool _opensFlow(String value) =>
      value.startsWith('[') || value.startsWith('{');

  /// Reads the flow collection that [text] opens on [line], taking following
  /// lines while its brackets are still open.
  ///
  /// A flow collection is read into the same maps and lists as block style,
  /// never kept as an opaque scalar: `dependencies: {core: {path: ../core}}`
  /// must answer `map('dependencies')` with the path dependency rk exists to
  /// refuse, exactly as the block form does.
  YamlNode? _flow(String text, int line) {
    var source = text;
    while (_FlowReader.opensMore(source)) {
      if (_cursor >= _lines.length) {
        _fail(
          'a flow collection is not closed',
          line,
          remedy: 'close every "[" with "]" and every "{" with "}"',
        );
        return null;
      }
      source = '$source ${_strip(_lines[_cursor]).trim()}';
      _cursor++;
    }
    final reader = _FlowReader(source);
    final node = reader.read(line);
    if (node == null) {
      _fail(
        reader.error!,
        line,
        remedy: 'rk reads flow collections of plain and quoted scalars',
      );
    }
    return node;
  }

  /// Consumes the indented body of a block scalar, joined with spaces.
  String _blockScalar(int parentIndent) {
    final parts = <String>[];
    while (_cursor < _lines.length) {
      final raw = _lines[_cursor];
      if (raw.trim().isEmpty) {
        _cursor++;
        continue;
      }
      if (_indentOf(raw) <= parentIndent) break;
      parts.add(raw.trim());
      _cursor++;
    }
    return parts.join(' ');
  }

  /// The index of the colon separating a key from its value, or -1.
  ///
  /// A colon only separates when followed by a space or end of line, so a URL
  /// value on the same line does not split at `https:`.
  int _keyColon(String body) {
    var quote = '';
    for (var i = 0; i < body.length; i++) {
      final ch = body[i];
      if (quote.isNotEmpty) {
        if (ch == quote) quote = '';
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
        continue;
      }
      if (ch == ':' && (i == body.length - 1 || body[i + 1] == ' ')) return i;
    }
    return -1;
  }

  /// Removes a comment, honouring YAML's rule that `#` only begins one at the
  /// start of a line or after whitespace — so `homepage: https://x/#cli` keeps
  /// its fragment.
  String _strip(String line) {
    var quote = '';
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (quote.isNotEmpty) {
        if (ch == quote) quote = '';
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
        continue;
      }
      if (ch == '#' && (i == 0 || line[i - 1] == ' ' || line[i - 1] == '\t')) {
        return line.substring(0, i);
      }
    }
    return line;
  }

  /// Leading spaces, or -1 when the line is indented with a tab.
  int _indentOf(String line) {
    var count = 0;
    while (count < line.length) {
      final ch = line[count];
      if (ch == ' ') {
        count++;
      } else if (ch == '\t') {
        return -1;
      } else {
        break;
      }
    }
    return count;
  }

  String _unquote(String value) {
    if (value.length >= 2) {
      final first = value[0];
      if ((first == '"' || first == "'") && value.endsWith(first)) {
        return value.substring(1, value.length - 1);
      }
    }
    return value;
  }
}

/// Reads one flow collection from a single string: sequences and mappings of
/// plain or quoted scalars, nested to any depth. Anchors, aliases and tags are
/// refused, as they are in block style.
final class _FlowReader {
  _FlowReader(this._text);

  final String _text;
  var _at = 0;

  /// Why [read] returned null.
  String? error;

  /// Whether [text] opens more brackets than it closes, outside quotes.
  ///
  /// A quote opens a quoted scalar only where a scalar starts, as [read]
  /// treats it; inside a plain scalar such as `it's` it is a character.
  static bool opensMore(String text) {
    var depth = 0;
    var quote = '';
    var scalarStart = true;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (quote.isNotEmpty) {
        if (quote == '"' && ch == r'\') {
          i++;
        } else if (ch == quote) {
          quote = '';
        }
        continue;
      }
      if (ch == ' ' || ch == '\t') continue;
      final starts = scalarStart;
      scalarStart = '[{,:'.contains(ch);
      if ((ch == '"' || ch == "'") && starts) {
        quote = ch;
      } else if (ch == '[' || ch == '{') {
        depth++;
      } else if (ch == ']' || ch == '}') {
        depth--;
      }
    }
    return depth > 0;
  }

  YamlNode? read(int line) {
    final node = _node(line);
    if (node == null) return null;
    _space();
    if (_at < _text.length) {
      return _refuse(
        'unexpected "${_text.substring(_at)}" after the collection',
      );
    }
    return node;
  }

  Null _refuse(String message) {
    error ??= message;
    return null;
  }

  void _space() {
    while (_at < _text.length && (_text[_at] == ' ' || _text[_at] == '\t')) {
      _at++;
    }
  }

  YamlNode? _node(int line) {
    _space();
    if (_at >= _text.length) return _refuse('a flow collection ends early');
    switch (_text[_at]) {
      case '[':
        return _sequence(line);
      case '{':
        return _mapping(line);
      case '&' || '*' || '!':
        return _refuse('rk does not read anchors, aliases or tags');
    }
    return _scalar(line, key: false);
  }

  YamlList? _sequence(int line) {
    _at++;
    final list = YamlList(line);
    while (true) {
      _space();
      if (_at >= _text.length) return _refuse('a flow sequence is not closed');
      if (_text[_at] == ']') {
        _at++;
        return list;
      }
      final item = _node(line);
      if (item == null) return null;
      list.items.add(item);
      if (!_separator(']')) return null;
      if (_text[_at - 1] == ']') return list;
    }
  }

  YamlMap? _mapping(int line) {
    _at++;
    final map = YamlMap(line);
    while (true) {
      _space();
      if (_at >= _text.length) return _refuse('a flow mapping is not closed');
      if (_text[_at] == '}') {
        _at++;
        return map;
      }
      final key = _scalar(line, key: true);
      if (key == null) return null;
      if (key.value.isEmpty) return _refuse('a flow mapping key is empty');
      if (map.entries.containsKey(key.value)) {
        return _refuse('"${key.value}" is set more than once');
      }
      _space();
      YamlNode value = YamlScalar('', line);
      if (_at < _text.length && _text[_at] == ':') {
        _at++;
        _space();
        if (_at < _text.length && _text[_at] != ',' && _text[_at] != '}') {
          final node = _node(line);
          if (node == null) return null;
          value = node;
        }
      }
      map.entries[key.value] = value;
      if (!_separator('}')) return null;
      if (_text[_at - 1] == '}') return map;
    }
  }

  /// Consumes the "," between entries or the [close] that ends them.
  bool _separator(String close) {
    _space();
    if (_at < _text.length && (_text[_at] == ',' || _text[_at] == close)) {
      _at++;
      return true;
    }
    _refuse('expected "," or "$close"');
    return false;
  }

  YamlScalar? _scalar(int line, {required bool key}) {
    _space();
    final quote = _text[_at];
    if (quote == '"' || quote == "'") {
      final value = StringBuffer();
      _at++;
      while (true) {
        if (_at >= _text.length) {
          return _refuse('a quoted scalar is not closed');
        }
        final ch = _text[_at];
        if (quote == "'" && ch == "'") {
          // '' is a single quote inside single quotes.
          if (_at + 1 < _text.length && _text[_at + 1] == "'") {
            value.write("'");
            _at += 2;
            continue;
          }
          _at++;
          break;
        }
        if (quote == '"' && ch == r'\' && _at + 1 < _text.length) {
          value.write(_text[_at + 1]);
          _at += 2;
          continue;
        }
        if (quote == '"' && ch == '"') {
          _at++;
          break;
        }
        value.write(ch);
        _at++;
      }
      return YamlScalar(value.toString(), line, quoted: true);
    }
    final start = _at;
    while (_at < _text.length) {
      final ch = _text[_at];
      if (ch == ',' || ch == ']' || ch == '}' || ch == '[' || ch == '{') break;
      // A key ends at ": " (or ":" before the next separator), so a URL value
      // such as https://example.com keeps its colon.
      if (key &&
          ch == ':' &&
          (_at + 1 == _text.length || ' ,]}'.contains(_text[_at + 1]))) {
        break;
      }
      _at++;
    }
    final value = _text.substring(start, _at).trim();
    if (value.startsWith('&') ||
        value.startsWith('*') ||
        value.startsWith('!')) {
      return _refuse('rk does not read anchors, aliases or tags');
    }
    return YamlScalar(value, line);
  }
}
