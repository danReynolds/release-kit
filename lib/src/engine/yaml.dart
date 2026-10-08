import 'package:yaml/yaml.dart' as yaml;

import 'diagnostic.dart';

/// A pubspec, or another YAML document rk reads, as Pub reads it: parsed by
/// `package:yaml`, then kept as the text rk interprets.
///
/// A scalar keeps what was written: rk types nothing, its accessors do, so a
/// version written `1.10` stays `1.10` rather than becoming a number. Every
/// node remembers the line it began on, and a map the line each key was
/// written on, so a diagnostic can point at it.
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
  final Map<String, int> _keyLines = {};

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

  /// The line [key] was written on.
  int lineOf(String key) => _keyLines[key] ?? line;
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
  final yaml.YamlNode document;
  try {
    document = yaml.loadYamlNode(source);
  } on yaml.YamlException catch (error) {
    diagnostics.add(
      'RK-YAML-001',
      error.message,
      source: SourceLocation(path, (error.span?.start.line ?? 0) + 1),
    );
    return null;
  }
  // An empty document is a map with nothing in it.
  if (document case yaml.YamlScalar(value: null)) return YamlMap(1);
  final root = _read(document);
  if (root is YamlMap) return root;
  // Read as an empty map, a list would declare nothing where Pub refuses.
  diagnostics.add(
    'RK-YAML-001',
    'the document is not a map of keys',
    source: SourceLocation(path, root.line),
    remedy: 'a pubspec and its overrides file are maps of keys',
  );
  return null;
}

YamlNode _read(yaml.YamlNode node) {
  final line = node.span.start.line + 1;
  switch (node) {
    case yaml.YamlMap():
      final map = YamlMap(line);
      for (final MapEntry(:key, :value) in node.nodes.entries) {
        final name = key is yaml.YamlNode ? _text(key) : '$key';
        map.entries[name] = _read(value);
        map._keyLines[name] = key is yaml.YamlNode
            ? key.span.start.line + 1
            : line;
      }
      return map;
    case yaml.YamlList():
      return YamlList(line)..items.addAll(node.nodes.map(_read));
    case yaml.YamlScalar():
      return YamlScalar(
        _text(node),
        line,
        quoted:
            node.style == yaml.ScalarStyle.SINGLE_QUOTED ||
            node.style == yaml.ScalarStyle.DOUBLE_QUOTED,
      );
    default:
      throw StateError('unknown YAML node ${node.runtimeType}');
  }
}

/// A scalar as rk keeps it: a string as YAML reads it (unquoted, folded),
/// anything else as written, and nothing as the empty string.
String _text(yaml.YamlNode node) => switch (node) {
  yaml.YamlScalar(:final String value) => value,
  yaml.YamlScalar(value: null) => '',
  _ => node.span.text,
};
