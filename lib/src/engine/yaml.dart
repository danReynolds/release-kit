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
/// `{path: ../core}`, continued over several lines), plain scalars (wrapped
/// over more-indented lines too) and quoted scalars, each written after its
/// key or on the lines below it, folded and literal block scalars (whose content is kept
/// opaque, since rk never reads a description), and one leading `---`.
/// Refused: anchors, aliases, tags, multiple documents, and tabs for
/// indentation.
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
    // One document, which may open with its marker.
    while (_cursor < _lines.length && _strip(_lines[_cursor]).trim().isEmpty) {
      _cursor++;
    }
    if (_cursor < _lines.length && _strip(_lines[_cursor]).trim() == '---') {
      _cursor++;
    }
    final root = _block(0);
    if (_failed) return null;
    // An empty document is a map with nothing in it.
    if (root == null) return YamlMap(1);
    if (root is YamlMap) return root;
    // Read as an empty map, a list would declare nothing where Pub refuses.
    _fail(
      'the document is not a map of keys',
      root.line,
      remedy: 'a pubspec and its overrides file are maps of keys',
    );
    return null;
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

      // A flow collection on its own line is the whole value of the key
      // above it, as `{path: ../core}` is under `core:`. Read as a key, it
      // would hide that path dependency.
      if (!isDash && _opensFlow(body)) {
        if (asMap != null || asList != null) {
          _fail(
            'a flow collection cannot follow other entries of a block',
            line,
            remedy: 'give "$body" its own key',
          );
          return null;
        }
        _cursor++;
        final node = _flow(raw.substring(at), line);
        if (node == null) return null;
        _endOfValue(indent, line);
        return _failed ? null : node;
      }

      if (isDash) {
        asList ??= YamlList(line);
        if (asMap != null) {
          _fail('a block cannot mix map keys and list items', line);
          return null;
        }
        final item = body == '-' ? '' : body.substring(2).trim();
        if (_hasProperty(item, line)) return null;

        if (_opensFlow(item)) {
          _cursor++;
          final node = _flow(raw.substring(raw.indexOf(item, at + 1)), line);
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
          asList.items.add(_scalar(item, at, line));
          if (_failed) return null;
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
      // A scalar on the lines below its key, as wrapped descriptions and
      // paths often are, is that key's whole value.
      if (colon < 0 && indent > 0 && asMap == null && !isDash) {
        _cursor++;
        final node = _scalar(body, indent - 1, line);
        return _failed ? null : node;
      }
      if (colon < 0) {
        _fail(
          'expected "key: value"',
          line,
          remedy: 'rk reads the block-style YAML a pubspec is written in',
        );
        return null;
      }

      final written = body.substring(0, colon).trim();
      if (written.startsWith('?') || _hasProperty(written, line)) {
        if (!_failed) {
          _fail(
            'rk does not read complex keys',
            line,
            remedy: 'write "$written" as a plain or quoted key',
          );
        }
        return null;
      }
      final key = _unquote(written);
      final rest = body.substring(colon + 1).trim();
      if (_hasProperty(rest, line)) return null;
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
        final node = _flow(raw.substring(raw.indexOf(rest, at + colon)), line);
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
        asMap.entries[key] = _scalar(rest, at, line);
        if (_failed) return null;
      }
    }

    return asMap ?? asList;
  }

  /// A scalar written after a key or dash indented [indent]. A plain scalar
  /// continues over following lines indented further, joined with spaces, as
  /// wrapped descriptions are written; such a line cannot be a key, which
  /// YAML also refuses inside a plain scalar.
  YamlScalar _scalar(String value, int indent, int line) {
    final quoted = value.startsWith('"') || value.startsWith("'");
    if (quoted) return YamlScalar(_unquote(value), line, quoted: true);
    // Folded as YAML folds: a line break is a space, and each blank line
    // between two lines is a newline.
    final folded = StringBuffer(value);
    var blanks = 0;
    var next = _cursor;
    while (next < _lines.length) {
      final raw = _lines[next];
      if (raw.trim().isEmpty) {
        blanks++;
        next++;
        continue;
      }
      final text = _strip(raw).trim();
      if (text.isEmpty || _indentOf(raw) <= indent) break;
      if (_keyColon(text) >= 0 || text.startsWith('- ') || text == '-') {
        _fail(
          'a key or list item is indented under the scalar on line $line',
          next + 1,
          remedy: 'outdent it, or quote the scalar if it is one value',
        );
        return YamlScalar(value, line);
      }
      folded
        ..write(blanks == 0 ? ' ' : '\n' * blanks)
        ..write(text);
      blanks = 0;
      _cursor = ++next;
    }
    return YamlScalar(folded.toString(), line);
  }

  /// Refuses what [value] would need an anchor, alias or tag to mean.
  bool _hasProperty(String value, int line) {
    if (!value.startsWith('&') &&
        !value.startsWith('*') &&
        !value.startsWith('!')) {
      return false;
    }
    _fail(
      'rk does not read anchors, aliases or tags',
      line,
      remedy: 'write "$value" out in full',
    );
    return true;
  }

  /// Requires the next meaningful line to leave the block indented [indent]:
  /// a flow collection written below its key is that key's whole value.
  void _endOfValue(int indent, int line) {
    for (var next = _cursor; next < _lines.length; next++) {
      final raw = _lines[next];
      if (_strip(raw).trim().isEmpty) continue;
      if (_indentOf(raw) >= indent) {
        _fail(
          'a flow collection is the whole value of its key',
          next + 1,
          remedy: 'end the block that the collection on line $line opens',
        );
      }
      return;
    }
  }

  bool _opensFlow(String value) =>
      value.startsWith('[') || value.startsWith('{');

  /// Reads the flow collection that [raw] (the line from its opening
  /// bracket) begins on [line], taking following lines while a bracket or
  /// quoted scalar is still open.
  ///
  /// One scan carries quotes, comments and brackets across the lines, so a
  /// `#` or bracket inside a quoted scalar never closes the collection early
  /// or keeps it open.
  ///
  /// A flow collection is read into the same maps and lists as block style,
  /// never kept as an opaque scalar: `dependencies: {core: {path: ../core}}`
  /// must answer `map('dependencies')` with the path dependency rk exists to
  /// refuse, exactly as the block form does.
  YamlNode? _flow(String raw, int line) {
    final scan = _Scan();
    final source = StringBuffer(_uncomment(raw, scan));
    while (scan.depth > 0 || scan.quote.isNotEmpty) {
      if (_cursor >= _lines.length) {
        _fail(
          'a flow collection is not closed',
          line,
          remedy: 'close every "[" with "]" and every "{" with "}"',
        );
        return null;
      }
      source
        ..write(' ')
        ..write(_uncomment(_lines[_cursor].trimLeft(), scan));
      _cursor++;
    }
    final reader = _FlowReader(source.toString().trim());
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
  String _strip(String line) => _uncomment(line, _Scan());

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

/// Where a scan of YAML text stands: inside a quoted scalar or not, how many
/// flow brackets are open, and whether a scalar may start next.
final class _Scan {
  var quote = '';
  var depth = 0;
  var scalarStart = true;
}

/// [line] without its comment, advancing [scan] across it.
///
/// A quote opens a quoted scalar only where a scalar starts, so the one in
/// `it's` is a character; inside double quotes a backslash escapes, inside
/// single quotes `''` does. A `#` begins a comment only outside quotes, at the
/// start of the line or after whitespace. Brackets count only in flow context:
/// one that opens a value, or any inside a collection already open.
String _uncomment(String line, _Scan scan) {
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (scan.quote == '"') {
      if (ch == r'\') {
        i++;
      } else if (ch == '"') {
        scan.quote = '';
      }
      continue;
    }
    if (scan.quote == "'") {
      if (ch == "'") {
        if (i + 1 < line.length && line[i + 1] == "'") {
          i++;
        } else {
          scan.quote = '';
        }
      }
      continue;
    }
    if (ch == ' ' || ch == '\t') continue;
    if (ch == '#' && (i == 0 || line[i - 1] == ' ' || line[i - 1] == '\t')) {
      return line.substring(0, i);
    }
    final starts = scan.scalarStart;
    final spaced =
        i + 1 == line.length || line[i + 1] == ' ' || line[i + 1] == '\t';
    scan.scalarStart = false;
    if ((ch == '"' || ch == "'") && starts) {
      scan.quote = ch;
    } else if ((ch == '[' || ch == '{') && (starts || scan.depth > 0)) {
      scan.depth++;
      scan.scalarStart = true;
    } else if ((ch == ']' || ch == '}') && scan.depth > 0) {
      scan.depth--;
    } else if (ch == ',' && scan.depth > 0) {
      scan.scalarStart = true;
    } else if (ch == ':' && (spaced || scan.depth > 0)) {
      scan.scalarStart = true;
    } else if ((ch == '-' || ch == '?') && spaced && scan.depth == 0) {
      scan.scalarStart = true;
    }
  }
  return line;
}
