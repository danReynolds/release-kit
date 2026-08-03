import 'dart:convert';
import 'dart:io';

/// Read access to the repository being released.
///
/// An interface rather than a path so the engine stays testable without a
/// filesystem, and so a later executor — a CI runner reading a checkout it did
/// not create — can supply its own without touching anything above it.
abstract class SourceTree {
  /// Repository-relative paths only; `..` never escapes.
  String? read(String path);

  /// The same file as bytes, for content that is compared rather than parsed.
  ///
  /// Comparison is byte-equality or it is nothing: routed through text
  /// decoding, two files differing only in what UTF-8 decoding erases would
  /// read as the same, and the point of comparing is to catch what a glance
  /// does not.
  List<int>? readBytes(String path);

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
  List<int>? readBytes(String path) {
    final file = File(_resolve(path));
    if (!file.existsSync()) return null;
    try {
      return file.readAsBytesSync();
    } on FileSystemException catch (error) {
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
    if (result.exitCode != 0) {
      // Not an empty list: an empty list is a real answer — "this repository
      // tracks nothing" — and callers act on it as one. init would propose
      // nothing and say so; a comparison would call every file untracked. A
      // listing that failed answered nothing.
      throw SourceUnreadable(
        'the repository file list',
        (result.stderr as String).trim(),
      );
    }
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

  static String _normalize(String path) =>
      path.split('/').where((p) => p.isNotEmpty && p != '.').join('/');
}

/// The repository as it stood at a ref — a tag, a commit — read from git's
/// object store rather than the working copy.
///
/// This is what lets `rk verify` answer for a release made months ago from a
/// worktree that has long since moved on: the comparison runs against what
/// the tag names, not whatever is on disk today. Reads are `git show` and
/// `git ls-tree`, so nothing here can see uncommitted state, and nothing
/// needs the working copy to be clean.
class GitTreeAtRef implements SourceTree {
  GitTreeAtRef._(this.root, this.ref, this.commit);

  /// The tree at [ref], or null when the ref does not resolve to a commit.
  ///
  /// Resolved up front so a typo in a tag name is one clear refusal rather
  /// than a cascade of per-file "not found"s reading as an empty release.
  static GitTreeAtRef? at(String root, String ref) {
    final resolved = Process.runSync(
      'git',
      ['rev-parse', '--verify', '--quiet', '$ref^{commit}'],
      workingDirectory: root,
    );
    if (resolved.exitCode != 0) return null;
    return GitTreeAtRef._(root, ref, (resolved.stdout as String).trim());
  }

  final String root;
  final String ref;

  /// The commit [ref] peels to — the provenance a verification binds to.
  final String commit;

  @override
  String get description => '$root@$ref';

  String _inside(String path) {
    final parts =
        path.split('/').where((p) => p.isNotEmpty && p != '.').toList();
    if (parts.contains('..')) {
      throw ArgumentError('path escapes the repository: $path');
    }
    return parts.join('/');
  }

  @override
  String? read(String path) {
    final bytes = readBytes(path);
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  @override
  List<int>? readBytes(String path) {
    final result = Process.runSync(
      'git',
      ['show', '$commit:${_inside(path)}'],
      workingDirectory: root,
      stdoutEncoding: null,
    );
    if (result.exitCode != 0) return null;
    return result.stdout as List<int>;
  }

  @override
  bool exists(String path) => readBytes(path) != null || _isDirectory(path);

  bool _isDirectory(String path) {
    final result = Process.runSync(
      'git',
      ['ls-tree', '-d', '--name-only', commit, _inside(path)],
      workingDirectory: root,
    );
    return result.exitCode == 0 && (result.stdout as String).trim().isNotEmpty;
  }

  List<String>? _tracked;

  @override
  List<String> trackedFiles() {
    if (_tracked != null) return _tracked!;
    final result = Process.runSync(
      'git',
      ['ls-tree', '-r', '--name-only', '-z', commit],
      workingDirectory: root,
    );
    if (result.exitCode != 0) {
      // The commit was verified at construction, so a listing that fails now
      // is the object store misbehaving — an answer verify must not read as
      // "this release contained no files".
      throw SourceUnreadable(
        'the file list at $ref',
        (result.stderr as String).trim(),
      );
    }
    final out = result.stdout as String;
    return _tracked =
        out.split(String.fromCharCode(0)).where((p) => p.isNotEmpty).toList();
  }
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
