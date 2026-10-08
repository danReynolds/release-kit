import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'file_mode.dart';
import 'source_tree.dart';
import 'stage.dart';

/// The source a stage is built from, read once per run and held in memory.
///
/// A Git-backed tree reads committed bytes and modes; any other tree is the
/// caller's snapshot for this invocation. Producers never build in the stage
/// or the working tree: each exports this snapshot into a directory of its
/// own.
final class StageSourceSnapshot implements SourceTree {
  StageSourceSnapshot._(
    this.description,
    this._files,
    this._executable,
    this.gitCommit, [
    this._links = const {},
  ]);

  static Future<StageSourceSnapshot> capture(
    SourceTree source, {
    String? commit,
  }) async {
    if (source is StageSourceSnapshot) {
      if (commit != null &&
          source.gitCommit != null &&
          commit != source.gitCommit) {
        throw StateError('source capture names a different Git commit');
      }
      return source;
    }
    final GitCommitSourceTree? git;
    if (source is GitSourceTree) {
      if (commit == null) {
        throw StateError('committed source capture requires a commit');
      }
      git = GitCommitSourceTree(source.root, commit);
    } else if (source is GitCommitSourceTree) {
      if (commit != null && commit != source.commit) {
        throw StateError('source capture names a different Git commit');
      }
      git = source;
    } else {
      git = null;
    }
    if (git == null) return _capture(source, null);
    // Every unit a run stages from one commit shares its one read.
    final key = git.description;
    final read = _committed[key] ??= _capture(source, git);
    try {
      return await read;
    } on Object {
      if (identical(_committed[key], read)) _committed.remove(key);
      rethrow;
    }
  }

  static final Map<String, Future<StageSourceSnapshot>> _committed = {};

  static Future<StageSourceSnapshot> _capture(
    SourceTree source,
    GitCommitSourceTree? git,
  ) async {
    final entries = {
      for (final entry in git?.trackedEntries() ?? <GitTreeEntry>[])
        entry.path: entry,
    };
    final all = [...(git?.trackedFiles() ?? source.trackedFiles())]..sort();
    // A symbolic link is exported as one, as `git archive` would; a gitlink
    // has no bytes in this commit and is left out, as `git archive` does.
    final links = [
      for (final path in all)
        if (entries[path] case final entry? when entry.mode == '120000') path,
    ];
    final paths = [
      for (final path in all)
        if (entries[path] == null || entries[path]!.isRegularFile) path,
    ];
    for (final path in [...paths, ...links]) {
      StagePath.require(path);
    }
    // A non-Git snapshot must own its complete inventory and bytes before the
    // first asynchronous boundary, just as ordinary source production does.
    final batched = git == null
        ? null
        : await git.readBytesBatch([...paths, ...links]);
    final files = <String, Uint8List>{};
    for (final path in paths) {
      final bytes = git == null ? source.readBytes(path) : batched![path];
      if (bytes == null) {
        throw StateError('tracked source disappeared while staging: $path');
      }
      files[path] = (bytes is Uint8List ? bytes : Uint8List.fromList(bytes))
          .asUnmodifiableView();
    }
    return StageSourceSnapshot._(
      source.description,
      Map.unmodifiable(files),
      {
        for (final path in paths)
          if (entries[path]?.executable == true) path,
      },
      git?.commit,
      {for (final path in links) path: utf8.decode(batched![path]!)},
    );
  }

  @override
  final String description;
  final String? gitCommit;
  final Map<String, Uint8List> _files;
  final Set<String> _executable;
  final Map<String, String> _links;

  @override
  List<String> trackedFiles() => List.unmodifiable(_files.keys);
  @override
  List<int>? readBytes(String path) => _files[_path(path)];
  @override
  String? read(String path) {
    final bytes = readBytes(path);
    return bytes == null ? null : utf8.decode(bytes);
  }

  @override
  bool exists(String path) {
    final normalized = _path(path);
    return normalized.isEmpty ||
        _files.containsKey(normalized) ||
        _files.keys.any((file) => file.startsWith('$normalized/'));
  }

  /// The directories that hold a `pubspec.yaml`: this source's Dart
  /// packages.
  Set<String> get packageDirectories => {
    for (final path in _files.keys)
      if (path == 'pubspec.yaml' || path.endsWith('/pubspec.yaml'))
        path == 'pubspec.yaml'
            ? '.'
            : path.substring(0, path.length - '/pubspec.yaml'.length),
  };

  /// The files a Dart build of the package at [directory] reads from this
  /// source: the package itself, the [packages] it takes from here (their
  /// directories), every `pubspec.yaml`, which is how Pub and rk find a
  /// workspace and its members, and the files directly inside each
  /// directory above the package, such as analysis options and ignore
  /// rules. Nothing else in the repository reaches the build.
  static bool Function(String path) dartBuildInputs(
    String directory, {
    Iterable<String> packages = const [],
  }) {
    final trees = {directory, ...packages}.map(_path).toSet();
    final above = <String>{''};
    final parts = _path(directory).split('/');
    for (var end = 1; end < parts.length; end++) {
      above.add(parts.take(end).join('/'));
    }
    return (path) {
      if (trees.any(
        (tree) => tree.isEmpty || path == tree || path.startsWith('$tree/'),
      )) {
        return true;
      }
      if (path == 'pubspec.yaml' || path.endsWith('/pubspec.yaml')) {
        return true;
      }
      final cut = path.lastIndexOf('/');
      return above.contains(cut < 0 ? '' : path.substring(0, cut));
    };
  }

  /// Writes the files [only] selects, every file when it is null, with
  /// their modes, beneath [root]. Exporting into a directory that already
  /// holds part of this source adds the rest.
  void export(String root, {bool Function(String path)? only}) {
    final modes = <String, String>{};
    for (final MapEntry(key: path, value: bytes) in _files.entries) {
      if (only != null && !only(path)) continue;
      final file = File(
        [root, ...StagePath.segments(path)].join(Platform.pathSeparator),
      );
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes);
      modes[file.path] = _executable.contains(path) ? '0755' : '0644';
    }
    setFileModes(modes);
    for (final MapEntry(key: path, value: target) in _links.entries) {
      if (only != null && !only(path)) continue;
      final link = Link(
        [root, ...StagePath.segments(path)].join(Platform.pathSeparator),
      );
      if (link.existsSync()) continue;
      link.createSync(target, recursive: true);
    }
  }
}

String _path(String path) {
  final value = path
      .split('/')
      .where((part) => part.isNotEmpty && part != '.')
      .join('/');
  if (value.isNotEmpty) StagePath.require(value);
  return value;
}
