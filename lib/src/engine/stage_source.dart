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
    this.gitCommit,
  );

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
    final entries = {
      for (final entry in git?.trackedEntries() ?? <GitTreeEntry>[])
        entry.path: entry,
    };
    final paths = [...(git?.trackedFiles() ?? source.trackedFiles())]..sort();
    for (final path in paths) {
      StagePath.require(path);
      final entry = entries[path];
      if (entry != null && !entry.isRegularFile) {
        throw StateError(
          'tracked source $path is a ${entry.unsupportedKind}; release '
          'staging accepts only regular Git files (100644 or 100755)',
        );
      }
    }
    // A non-Git snapshot must own its complete inventory and bytes before the
    // first asynchronous boundary, just as ordinary source production does.
    final batched = git == null ? null : await git.readBytesBatch(paths);
    final files = <String, Uint8List>{};
    for (final path in paths) {
      final bytes = git == null ? source.readBytes(path) : batched![path];
      if (bytes == null) {
        throw StateError('tracked source disappeared while staging: $path');
      }
      files[path] = Uint8List.fromList(bytes).asUnmodifiableView();
    }
    return StageSourceSnapshot._(
      source.description,
      Map.unmodifiable(files),
      {
        for (final path in paths)
          if (entries[path]?.executable == true) path,
      },
      git?.commit,
    );
  }

  @override
  final String description;
  final String? gitCommit;
  final Map<String, Uint8List> _files;
  final Set<String> _executable;

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

  /// Writes every file, with its mode, beneath the empty directory [root].
  void export(String root) {
    final modes = <String, String>{};
    for (final MapEntry(key: path, value: bytes) in _files.entries) {
      final file = File(
        [root, ...StagePath.segments(path)].join(Platform.pathSeparator),
      );
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes);
      modes[file.path] = _executable.contains(path) ? '0755' : '0644';
    }
    setFileModes(modes);
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
