import 'diagnostic.dart';

/// A reader for the block-style YAML subset a pubspec is written in.
///
/// It reads the whole document rather than only the keys rk needs, so an
/// unfamiliar field is carried rather than rejected — refusing a package for
/// declaring `topics:` would be absurd. Fail-closed applies where it matters:
/// a key rk *interprets* must have the shape rk expects, which the typed
/// accessors enforce.
///
/// Accepted: block maps, block sequences, plain and quoted scalars, folded and
/// literal block scalars (whose content is kept opaque, since rk never reads a
/// description). Absent: flow collections, anchors, aliases, tags, multiple
/// documents, and tabs for indentation.
sealed class YamlNode {
  const YamlNode(this.line);

  /// One-based line where this node began.
  final int line;
}

class YamlScalar extends YamlNode {
  const YamlScalar(this.value, super.line);
  final String value;
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
  YamlNode? _block(int indent) {
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
      if (at < indent) break; // belongs to an enclosing block

      final body = text.trim();

      if (body.startsWith('- ') || body == '-') {
        asList ??= YamlList(line);
        if (asMap != null) {
          _fail('a block cannot mix map keys and list items', line);
          return null;
        }
        final item = body == '-' ? '' : body.substring(2).trim();

        if (item.isEmpty) {
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

      if (asList != null) break; // a key after a sequence closes it

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

      if (rest.isEmpty) {
        // A nested block, or a key with no value at all.
        final nested = _block(at + 1);
        if (_failed) return null;
        asMap.entries[key] = nested ?? YamlScalar('', line);
      } else if (rest.startsWith('>') || rest.startsWith('|')) {
        // A folded or literal scalar: kept opaque, since nothing rk reads is
        // ever written this way.
        asMap.entries[key] = YamlScalar(_blockScalar(at), line);
      } else {
        asMap.entries[key] = YamlScalar(_unquote(rest), line);
      }
    }

    return asMap ?? asList;
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
