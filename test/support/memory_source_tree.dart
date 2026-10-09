import 'dart:convert';

import 'package:rk/src/engine/source_tree.dart';

/// A repository held in memory: each file's path and text.
class MemorySourceTree implements SourceTree {
  MemorySourceTree(this.files, {this.description = 'memory'});

  final Map<String, String> files;

  @override
  final String description;

  @override
  String? read(String path) => files[_normalize(path)];

  @override
  List<int>? readBytes(String path) {
    final text = read(path);
    return text == null ? null : utf8.encode(text);
  }

  @override
  bool exists(String path) {
    final target = _normalize(path);
    if (files.containsKey(target)) return true;
    final prefix = '$target/';
    return files.keys.any((p) => p.startsWith(prefix));
  }

  @override
  List<String> trackedFiles() => files.keys.toList();
}

String _normalize(String path) =>
    path.split('/').where((part) => part.isNotEmpty && part != '.').join('/');
