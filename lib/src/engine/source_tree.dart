import 'dart:io';

/// Read access to the repository being released.
///
/// An interface rather than a path so the engine stays testable without a
/// filesystem, and so a later executor — a CI runner reading a checkout it did
/// not create — can supply its own without touching anything above it.
abstract class SourceTree {
  /// Repository-relative paths only; `..` never escapes.
  String? read(String path);

  bool exists(String path);

  /// Files tracked by the repository, relative to its root.
  ///
  /// Tracked rather than present: a scan of the filesystem would discover
  /// build output, vendored copies, and stray worktrees.
  List<String> trackedFiles();

  /// A human-facing label for the repository root.
  String get description;
}

/// A repository on disk, listing files through git so untracked material is
/// invisible.
class GitSourceTree implements SourceTree {
  GitSourceTree(this.root);

  final String root;

  @override
  String get description => root;

  String _resolve(String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty && p != '.');
    if (parts.contains('..')) {
      throw ArgumentError('path escapes the repository: $path');
    }
    return [root, ...parts].join('/');
  }

  @override
  String? read(String path) {
    final file = File(_resolve(path));
    if (!file.existsSync()) return null;
    try {
      return file.readAsStringSync();
    } on FileSystemException catch (error) {
      // Not null: null means "there is nothing here", and a file rk is not
      // allowed to open is not a file that does not exist. Collapsing the two
      // would answer "no release.toml — run rk init" for a release.toml that
      // is sitting right there.
      throw SourceUnreadable(path, error.osError?.message ?? '$error');
    }
  }

  @override
  bool exists(String path) {
    final full = _resolve(path);
    return File(full).existsSync() || Directory(full).existsSync();
  }

  List<String>? _tracked;

  @override
  List<String> trackedFiles() {
    if (_tracked != null) return _tracked!;
    final result = Process.runSync(
      'git',
      const ['ls-files', '-z'],
      workingDirectory: root,
    );
    if (result.exitCode != 0) return _tracked = const [];
    final out = result.stdout as String;
    return _tracked = out.split('\u0000').where((p) => p.isNotEmpty).toList();
  }

  /// The repository root containing [start], or null when there is none.
  static String? findRoot(String start) {
    final result = Process.runSync(
      'git',
      const ['rev-parse', '--show-toplevel'],
      workingDirectory: start,
    );
    if (result.exitCode != 0) return null;
    return (result.stdout as String).trim();
  }
}

/// An in-memory tree, for tests and for rendering a repository rk has read
/// from somewhere other than a working copy.
class MemorySourceTree implements SourceTree {
  MemorySourceTree(this.files, {this.description = 'memory'});

  final Map<String, String> files;

  @override
  final String description;

  @override
  String? read(String path) => files[_normalize(path)];

  @override
  bool exists(String path) {
    final target = _normalize(path);
    if (files.containsKey(target)) return true;
    final prefix = '$target/';
    return files.keys.any((p) => p.startsWith(prefix));
  }

  @override
  List<String> trackedFiles() => files.keys.toList();

  static String _normalize(String path) =>
      path.split('/').where((p) => p.isNotEmpty && p != '.').join('/');
}

/// A file that is there and that rk could not read.
///
/// Distinct from absence on purpose: the two call for opposite responses, and
/// telling an operator to create a file they already have is the kind of
/// answer that costs them an afternoon.
class SourceUnreadable implements Exception {
  SourceUnreadable(this.path, this.reason);

  final String path;
  final String reason;

  @override
  String toString() => '$path could not be read: $reason';
}
