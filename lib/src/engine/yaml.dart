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
    : _lines = source
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n')
          .split('\n');

  final List<String> _lines;
  final String _path;
  final Diagnostics _diagnostics;
  var _cursor = 0;
  var _failed = false;

  YamlMap? run() {
    // One document, which may open with its marker.
    while (_cursor < _lines.length &&
        _strip(_lines[_cursor]).yamlTrim().isEmpty) {
      _cursor++;
    }
    if (_cursor < _lines.length &&
        _strip(_lines[_cursor]).yamlTrim() == '---') {
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
      if (text.yamlTrim().isEmpty) {
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

      // A line ending inside a double-quoted scalar keeps a space or tab a
      // backslash escapes there: it is content.
      final ending = _Scan();
      _uncomment(raw, ending);
      final body = _trimFolded(
        text.yamlTrimLeft(),
        double: ending.quote == '"',
      );
      final isDash =
          body == '-' || body.startsWith('- ') || body.startsWith('-\t');

      // Belongs to an enclosing block.
      if (at < (isDash ? dashFrom : indent)) break;

      // What only anchors, aliases, tags, complex keys or a block scalar
      // below its key could mean is refused rather than read as text: read
      // as text, `resolution:` above `  !!str workspace` would hide a
      // workspace member.
      if (!isDash && _unreadable(body, line)) return null;

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
        final node = _flow(raw.substring(at), line, indent - 1);
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
        final item = body.substring(1).yamlTrimLeft();
        if (_unreadable(item, line)) return null;
        if (item == '-' || item.startsWith('- ') || item.startsWith('-\t')) {
          _fail(
            'rk does not read a sequence nested on its item\'s line',
            line,
            remedy: 'write the inner sequence on the lines below the dash',
          );
          return null;
        }

        if (_opensFlow(item)) {
          _cursor++;
          final node = _flow(
            raw.substring(raw.indexOf(item, at + 1)),
            line,
            at,
          );
          if (node == null) return null;
          asList.items.add(node);
        } else if (item.isEmpty) {
          _cursor++;
          final nested = _block(at + 1);
          if (_failed) return null;
          // A bare dash is an item with no value.
          asList.items.add(nested ?? YamlScalar('', line));
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
        if (body.startsWith('|') || body.startsWith('>')) {
          _fail(
            'rk does not read a block scalar header below its key',
            line,
            remedy: 'put "${body[0]}" after the key\'s colon',
          );
          return null;
        }
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

      final written = body.substring(0, colon).yamlTrim();
      final key = _key(written, line);
      if (key == null) return null;
      final rest = body.substring(colon + 1).yamlTrimLeft();
      if (_unreadable(rest, line)) return null;
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
        final node = _flow(
          raw.substring(raw.indexOf(rest, at + colon)),
          line,
          at,
        );
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

  /// A scalar written after a key or dash indented [indent].
  ///
  /// A plain scalar continues over following lines indented further, as
  /// wrapped descriptions are written; such a line cannot be a key, which
  /// YAML also refuses inside a plain scalar. A quoted scalar continues until
  /// its quote closes. Both are folded as YAML folds them, and a quoted one
  /// is decoded: `''` in single quotes, escapes in double quotes.
  YamlScalar _scalar(String value, int indent, int line) {
    if (value.startsWith('"') || value.startsWith("'")) {
      return _quotedScalar(value, indent, line);
    }
    final folded = StringBuffer(value);
    var blanks = 0;
    var next = _cursor;
    while (next < _lines.length) {
      final raw = _lines[next];
      if (raw.yamlTrim().isEmpty) {
        blanks++;
        next++;
        continue;
      }
      // The line continues a plain scalar, so a quote on it is a character
      // and cannot hide a comment.
      final text = _uncomment(raw, _Scan()..scalarStart = false).yamlTrim();
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

  /// The quoted scalar that [value] opens on [line], continued over the
  /// lines below until its quote closes, each indented past [indent].
  YamlScalar _quotedScalar(String value, int indent, int line) {
    final double = value.startsWith('"');
    final scan = _Scan();
    final folded = StringBuffer(
      _trimFolded(_uncomment(value, scan), double: double),
    );
    var blanks = 0;
    var next = _cursor;
    while (scan.quote.isNotEmpty) {
      if (next >= _lines.length) {
        _fail(
          'the quoted scalar on line $line is not closed',
          line,
          remedy: 'close its quote',
        );
        return YamlScalar(value, line);
      }
      final raw = _lines[next++];
      if (raw.yamlTrim().isEmpty) {
        blanks++;
        continue;
      }
      if (_indentOf(raw) <= indent) {
        _fail(
          'the quoted scalar on line $line is not closed within its block',
          next,
          remedy: 'close its quote, or indent its continuation lines',
        );
        return YamlScalar(value, line);
      }
      final text = _trimFolded(
        _uncomment(raw.yamlTrimLeft(), scan),
        double: double,
      );
      final current = folded.toString();
      if (blanks > 0) {
        folded.write('\n' * blanks);
      } else if (double && _escapesLineBreak(current)) {
        // An escaped line break joins the lines without a space.
        folded
          ..clear()
          ..write(current.substring(0, current.length - 1));
      } else {
        folded.write(' ');
      }
      folded.write(text);
      blanks = 0;
    }
    _cursor = next;
    final decoded = _decodeQuoted(folded.toString());
    if (decoded == null) {
      _fail(
        'rk cannot read the quoted scalar on line $line',
        line,
        remedy:
            'end it at its closing quote, and use only the escapes YAML '
            'defines',
      );
      return YamlScalar(value, line);
    }
    return YamlScalar(decoded, line, quoted: true);
  }

  /// Whether [text] ends in a backslash that escapes the line break after
  /// it: an odd run of them.
  bool _escapesLineBreak(String text) {
    var count = 0;
    for (var i = text.length - 1; i >= 0 && text[i] == r'\'; i--) {
      count++;
    }
    return count.isOdd;
  }

  /// The key [written] on [line] names, decoded when quoted; null, with the
  /// reason recorded, for a complex key or one an anchor or tag qualifies.
  String? _key(String written, int line) {
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
    if (!written.startsWith('"') && !written.startsWith("'")) return written;
    final decoded = _decodeQuoted(written);
    if (decoded == null) {
      _fail(
        'rk cannot read the quoted key "$written"',
        line,
        remedy: 'use only the escapes YAML defines',
      );
    }
    return decoded;
  }

  /// Refuses a value that only an anchor, alias, tag, complex key or block
  /// scalar header below its key could mean, recording why.
  bool _unreadable(String value, int line) {
    if (_hasProperty(value, line)) return true;
    if (value == '?' || value.startsWith('? ') || value.startsWith('?\t')) {
      _fail(
        'rk does not read complex keys',
        line,
        remedy: 'write the key plainly, before its colon',
      );
      return true;
    }
    return false;
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
      if (_strip(raw).yamlTrim().isEmpty) continue;
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
  ///
  /// Each following line is indented past [owner], the column of the key or
  /// dash the collection belongs to, unless it only closes brackets. A line
  /// that is not cannot belong to the collection in YAML, and taking it
  /// would swallow the keys after it.
  YamlNode? _flow(String raw, int line, int owner) {
    final scan = _Scan();
    var source = _uncomment(raw, scan);
    var blanks = 0;
    while (scan.depth > 0 || scan.quote.isNotEmpty) {
      if (_cursor >= _lines.length) {
        _fail(
          'a flow collection is not closed',
          line,
          remedy: 'close every "[" with "]" and every "{" with "}"',
        );
        return null;
      }
      final next = _lines[_cursor];
      final trimmed = next.yamlTrimLeft();
      if (trimmed.isEmpty) {
        blanks++;
        _cursor++;
        continue;
      }
      if (_indentOf(next) <= owner &&
          !(scan.quote.isEmpty &&
              (trimmed.startsWith(']') ||
                  trimmed.startsWith('}') ||
                  trimmed.startsWith('#')))) {
        _fail(
          'line ${_cursor + 1} is not indented past the key of the flow '
          'collection on line $line',
          _cursor + 1,
          remedy: 'close the collection, or indent its lines',
        );
        return null;
      }
      final quote = scan.quote;
      if (quote.isEmpty) {
        // A plain scalar the line continues folds a blank line to a newline,
        // as a quoted one does; between entries it is only space.
        final continues =
            !scan.scalarStart &&
            !scan.afterJson &&
            !',]}#'.contains(trimmed[0]) &&
            !(trimmed[0] == ':' &&
                (trimmed.length == 1 || ' \t,]}'.contains(trimmed[1])));
        source = continues && blanks > 0
            ? '${source.yamlTrimRight()}${'\n' * blanks}'
            : '${source.yamlTrimRight()} ';
      } else {
        source = _trimFolded(source, double: quote == '"');
        if (blanks > 0) {
          source = '$source${'\n' * blanks}';
        } else if (quote == '"' && _escapesLineBreak(source)) {
          source = source.substring(0, source.length - 1);
        } else {
          source = '$source ';
        }
      }
      source += _uncomment(trimmed, scan);
      blanks = 0;
      _cursor++;
    }
    final reader = _FlowReader(source.yamlTrim());
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
      if (raw.yamlTrim().isEmpty) {
        _cursor++;
        continue;
      }
      if (_indentOf(raw) <= parentIndent) break;
      parts.add(raw.yamlTrim());
      _cursor++;
    }
    return parts.join(' ');
  }

  /// The index of the colon separating a key from its value, or -1.
  ///
  /// A colon only separates when followed by whitespace or the end of the
  /// line, so a URL value on the same line does not split at `https:`. A
  /// quoted key is skipped whole; a quote later in a plain key is a character.
  int _keyColon(String body) {
    var i = 0;
    if (body.startsWith('"') || body.startsWith("'")) {
      final end = _quoteEnd(body);
      if (end < 0) return -1;
      i = end;
    }
    for (; i < body.length; i++) {
      if (body[i] == ':' &&
          (i + 1 == body.length || body[i + 1] == ' ' || body[i + 1] == '\t')) {
        return i;
      }
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
      case '?' || '-' when _indicator():
        return _refuse('rk does not read "${_text[_at]}" entries in a flow');
    }
    return _scalar(line, key: false);
  }

  /// Whether the character at the cursor is an indicator: followed by
  /// whitespace or the end, as `? key` and `- item` are.
  bool _indicator() =>
      _at + 1 == _text.length || ' \t'.contains(_text[_at + 1]);

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
      _space();
      // `[a: b]` holds a one-pair map, which rk does not read.
      if (item is YamlScalar &&
          _at < _text.length &&
          _text[_at] == ':' &&
          (item.quoted ||
              _at + 1 == _text.length ||
              ' \t,]'.contains(_text[_at + 1]))) {
        return _refuse('rk does not read a key: value pair in a sequence');
      }
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
      if ((_text[_at] == '?' || _text[_at] == '-') && _indicator()) {
        return _refuse('rk does not read "${_text[_at]}" entries in a flow');
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
        if (quote == '"' && ch == r'\') {
          final escape = _escape(_text, _at);
          if (escape == null) {
            return _refuse(
              'rk does not read the escape at "${_text.substring(_at)}"',
            );
          }
          value.write(escape.$1);
          _at += escape.$2;
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
      // A plain scalar ends at ": " (or ":" before the next separator), so a
      // URL such as https://example.com keeps its colon while `[a: ]` holds
      // the key a.
      if (ch == ':' &&
          (_at + 1 == _text.length || ' \t,]}'.contains(_text[_at + 1]))) {
        break;
      }
      _at++;
    }
    final value = _text.substring(start, _at).yamlTrim();
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

  /// Just after a quoted scalar or a closing bracket: in a flow, a colon
  /// there begins a value even without the space a plain key needs.
  var afterJson = false;
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
        scan.afterJson = true;
      }
      continue;
    }
    if (scan.quote == "'") {
      if (ch == "'") {
        if (i + 1 < line.length && line[i + 1] == "'") {
          i++;
        } else {
          scan.quote = '';
          scan.afterJson = true;
        }
      }
      continue;
    }
    if (ch == ' ' || ch == '\t') continue;
    if (ch == '#' && (i == 0 || line[i - 1] == ' ' || line[i - 1] == '\t')) {
      return line.substring(0, i);
    }
    final starts = scan.scalarStart;
    final json = scan.afterJson;
    final spaced =
        i + 1 == line.length || line[i + 1] == ' ' || line[i + 1] == '\t';
    scan.scalarStart = false;
    scan.afterJson = false;
    if ((ch == '"' || ch == "'") && starts) {
      scan.quote = ch;
    } else if ((ch == '[' || ch == '{') && (starts || scan.depth > 0)) {
      scan.depth++;
      scan.scalarStart = true;
    } else if ((ch == ']' || ch == '}') && scan.depth > 0) {
      scan.depth--;
      scan.afterJson = true;
    } else if (ch == ',' && scan.depth > 0) {
      scan.scalarStart = true;
    } else if (ch == ':' && (spaced || (scan.depth > 0 && json))) {
      scan.scalarStart = true;
    } else if (ch == '?' && spaced && starts) {
      scan.scalarStart = true;
    } else if (ch == '-' && spaced && starts && scan.depth == 0) {
      scan.scalarStart = true;
    }
  }
  return line;
}

/// The index just past the closing quote of the quoted scalar [text] opens,
/// or -1 when it does not close.
int _quoteEnd(String text) {
  final quote = text[0];
  for (var i = 1; i < text.length; i++) {
    final ch = text[i];
    if (quote == '"' && ch == r'\') {
      i++;
    } else if (ch == quote) {
      if (quote == "'" && i + 1 < text.length && text[i + 1] == "'") {
        i++;
      } else {
        return i + 1;
      }
    }
  }
  return -1;
}

/// The value of [text], exactly one quoted scalar and nothing after it but
/// whitespace, decoded as YAML decodes it; null for anything else, or for an
/// escape YAML does not define.
String? _decodeQuoted(String text) {
  if (text.isEmpty || (text[0] != '"' && text[0] != "'")) return null;
  final end = _quoteEnd(text);
  if (end < 0 || text.substring(end).yamlTrim().isNotEmpty) return null;
  final inner = text.substring(1, end - 1);
  if (text[0] == "'") return inner.replaceAll("''", "'");
  final value = StringBuffer();
  for (var i = 0; i < inner.length; i++) {
    if (inner[i] != r'\') {
      value.write(inner[i]);
      continue;
    }
    final escape = _escape(inner, i);
    if (escape == null) return null;
    value.write(escape.$1);
    i += escape.$2 - 1;
  }
  return value.toString();
}

/// Double-quoted escapes YAML defines, by the character after the backslash.
final _simpleEscapes = <String, int>{
  '0': 0,
  'a': 7,
  'b': 8,
  't': 9,
  String.fromCharCode(9): 9,
  'n': 10,
  'v': 11,
  'f': 12,
  'r': 13,
  'e': 27,
  ' ': 32,
  '"': 34,
  '/': 47,
  r'\': 92,
  'N': 0x85,
  '_': 0xA0,
  'L': 0x2028,
  'P': 0x2029,
};

/// What the escape whose backslash is at [text][at] stands for, and how many
/// characters it spans; null for one YAML does not define.
(String, int)? _escape(String text, int at) {
  if (at + 1 >= text.length) return null;
  final kind = text[at + 1];
  final simple = _simpleEscapes[kind];
  if (simple != null) return (String.fromCharCode(simple), 2);
  final width = switch (kind) {
    'x' => 2,
    'u' => 4,
    'U' => 8,
    _ => 0,
  };
  if (width == 0 || at + 2 + width > text.length) return null;
  final hex = text.substring(at + 2, at + 2 + width);
  if (!RegExp(r'^[0-9A-Fa-f]+$').hasMatch(hex)) return null;
  final code = int.parse(hex, radix: 16);
  if (code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) return null;
  return (String.fromCharCode(code), 2 + width);
}

/// [text] without the spaces and tabs that end it, keeping one a backslash
/// escapes when [double] quotes it: that one is content, and the line break
/// after it folds as usual.
String _trimFolded(String text, {required bool double}) {
  var end = text.length;
  while (end > 0 && (text[end - 1] == ' ' || text[end - 1] == '\t')) {
    if (double) {
      var slashes = 0;
      for (var i = end - 2; i >= 0 && text[i] == r'\'; i--) {
        slashes++;
      }
      if (slashes.isOdd) break;
    }
    end--;
  }
  return text.substring(0, end);
}

/// YAML's white space is spaces and tabs. [String.trim] also takes Unicode
/// spaces, which YAML reads as content.
extension on String {
  String yamlTrim() => yamlTrimLeft().yamlTrimRight();

  String yamlTrimLeft() {
    var start = 0;
    while (start < length && (this[start] == ' ' || this[start] == '\t')) {
      start++;
    }
    return substring(start);
  }

  String yamlTrimRight() {
    var end = length;
    while (end > 0 && (this[end - 1] == ' ' || this[end - 1] == '\t')) {
      end--;
    }
    return substring(0, end);
  }
}
