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

/// One entry in an immutable Git tree, including the metadata that makes the
/// entry more than its blob bytes.
///
/// Release staging accepts only ordinary blobs. Keeping the mode and object
/// type here prevents an executable, symlink, or gitlink from being silently
/// materialized as a default-mode regular file while the receipt still claims
/// to represent the original Git tree.
class GitTreeEntry {
  const GitTreeEntry({
    required this.path,
    required this.mode,
    required this.type,
  });

  final String path;
  final String mode;
  final String type;

  bool get isRegularFile =>
      type == 'blob' && (mode == '100644' || mode == '100755');

  bool get executable => mode == '100755';

  String get unsupportedKind => switch ((mode, type)) {
        ('120000', 'blob') => 'symbolic link',
        ('160000', 'commit') => 'gitlink/submodule',
        _ => '$type with mode $mode',
      };
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

  /// Files and bytes from one immutable commit, bypassing the worktree and
  /// index. Release staging uses these after it captures HEAD and its tree so
  /// a concurrent edit cannot be trusted under the old tree identity.
  List<GitTreeEntry> trackedEntriesAt(String commit) {
    final result = Process.runSync(
      'git',
      ['ls-tree', '-r', '-z', commit],
      workingDirectory: root,
    );
    if (result.exitCode != 0) {
      throw SourceUnreadable(
        'the source tree at $commit',
        (result.stderr as String).trim(),
      );
    }
    final entries = <GitTreeEntry>[];
    for (final record in (result.stdout as String)
        .split('\u0000')
        .where((r) => r.isNotEmpty)) {
      final separator = record.indexOf('\t');
      if (separator <= 0 || separator == record.length - 1) {
        throw SourceUnreadable(
          'the source tree at $commit',
          'git returned a malformed tree entry',
        );
      }
      final metadata = record.substring(0, separator).split(' ');
      final path = record.substring(separator + 1);
      if (metadata.length != 3 ||
          !RegExp(r'^[0-7]{6}$').hasMatch(metadata[0]) ||
          !RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$').hasMatch(metadata[2])) {
        throw SourceUnreadable(
          'the source tree at $commit',
          'git returned malformed mode, type, or object metadata for $path',
        );
      }
      _resolve(path);
      entries.add(GitTreeEntry(
        path: path,
        mode: metadata[0],
        type: metadata[1],
      ));
    }
    return entries;
  }

  List<String> trackedFilesAt(String commit) =>
      trackedEntriesAt(commit).map((entry) => entry.path).toList();

  List<int> readBytesAt(String commit, String path) {
    _resolve(path); // validates that [path] cannot escape the repository.
    final result = Process.runSync(
      'git',
      ['show', '$commit:$path'],
      workingDirectory: root,
      stdoutEncoding: null,
    );
    if (result.exitCode != 0) {
      throw SourceUnreadable(path, '${result.stderr}'.trim());
    }
    return List<int>.from(result.stdout as List<int>);
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

/// A repository-shaped directory with no Git identity.
///
/// Configuration supplies the roots worth staging. Discovery is deliberately
/// handled by Dart workspace membership in `rk init`; this class never
/// guesses release units by recursively searching unrelated directories.
class FileSystemSourceTree implements SourceTree {
  FileSystemSourceTree(this.root, {Iterable<String> roots = const ['.']})
      : roots = List.unmodifiable(roots);

  final String root;
  final List<String> roots;

  @override
  String get description => root;

  String _resolve(String path) {
    final parts =
        path.split('/').where((part) => part.isNotEmpty && part != '.');
    if (path.startsWith('/') ||
        path.startsWith('\\') ||
        path.contains('\\') ||
        path.contains('\u0000') ||
        RegExp(r'^[A-Za-z]:').hasMatch(path) ||
        parts.contains('..')) {
      throw ArgumentError('path escapes the source directory: $path');
    }
    return [root, ...parts].join('/');
  }

  @override
  String? read(String path) {
    final bytes = readBytes(path);
    return bytes == null ? null : utf8.decode(bytes);
  }

  @override
  List<int>? readBytes(String path) {
    final file = File(_resolve(path));
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw SourceUnreadable(path, 'the path is not a regular file');
    }
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

  @override
  List<String> trackedFiles() {
    final files = <String>{};
    for (final declared in roots) {
      final normalized = declared == '.' ? '' : declared;
      final full = _resolve(normalized);
      final type = FileSystemEntity.typeSync(full, followLinks: false);
      if (type == FileSystemEntityType.file) {
        files.add(normalized);
        continue;
      }
      if (type != FileSystemEntityType.directory) continue;
      for (final entity in Directory(full).listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final relative = entity.path
            .substring(root.endsWith(Platform.pathSeparator)
                ? root.length
                : root.length + 1)
            .split(Platform.pathSeparator)
            .join('/');
        if (relative == '.rk' || relative.startsWith('.rk/')) continue;
        if (relative == '.git' || relative.startsWith('.git/')) continue;
        files.add(relative);
      }
    }
    final ordered = files.toList()..sort();
    return ordered;
  }
}

/// The current, non-ignored files in a Git working tree.
///
/// Used only when a dirty repository releases targets whose identity does not
/// depend on Git. Tracked edits and untracked files are included; ignored
/// build output and `.git` metadata are not. The resulting release is bound to
/// the stage's byte snapshot, never to HEAD.
class GitWorktreeSourceTree extends FileSystemSourceTree {
  GitWorktreeSourceTree(super.root);

  @override
  List<String> trackedFiles() {
    final result = Process.runSync(
      'git',
      const [
        'ls-files',
        '--cached',
        '--others',
        '--exclude-standard',
        '-z',
      ],
      workingDirectory: root,
    );
    if (result.exitCode != 0) {
      throw SourceUnreadable(
        'the Git working-tree file list',
        (result.stderr as String).trim(),
      );
    }
    final files = <String>[];
    for (final path in (result.stdout as String)
        .split('\u0000')
        .where((path) => path.isNotEmpty)
        .where((path) => path != '.rk' && !path.startsWith('.rk/'))) {
      final type = FileSystemEntity.typeSync('$root/$path', followLinks: false);
      // A deleted tracked path remains in the index but is intentionally
      // absent from this working-tree snapshot.
      if (type == FileSystemEntityType.notFound) continue;
      if (type != FileSystemEntityType.file) {
        throw SourceUnreadable(
          path,
          'the worktree entry is not a regular file',
        );
      }
      files.add(path);
    }
    files.sort();
    return List.unmodifiable(files);
  }
}

/// An immutable, internally consistent copy of a [SourceTree].
///
/// Dirty releases resolve and stage from this same copy. Capturing reads the
/// inventory and every byte twice, refusing a source that moves while it is
/// being frozen; a reviewed package coordinate can therefore never publish
/// later working-tree bytes.
final class FrozenSourceTree implements SourceTree {
  FrozenSourceTree._(this._files, this.description);

  factory FrozenSourceTree.capture(SourceTree source) {
    final before = source.trackedFiles().toSet();
    final captured = <String, List<int>>{};
    for (final path in before.toList()..sort()) {
      final bytes = source.readBytes(path);
      if (bytes == null) {
        throw SourceUnreadable(path, 'the file disappeared while freezing');
      }
      captured[path] = List<int>.unmodifiable(bytes);
    }

    final after = source.trackedFiles().toSet();
    if (!before.containsAll(after) || !after.containsAll(before)) {
      throw SourceUnreadable(
        'the working-tree file list',
        'files changed while the source snapshot was being frozen',
      );
    }
    for (final path in after.toList()..sort()) {
      final bytes = source.readBytes(path);
      if (bytes == null || !_sameBytes(captured[path]!, bytes)) {
        throw SourceUnreadable(
          path,
          'the file changed while the source snapshot was being frozen',
        );
      }
    }
    return FrozenSourceTree._(
      Map<String, List<int>>.unmodifiable(captured),
      source.description,
    );
  }

  final Map<String, List<int>> _files;

  @override
  final String description;

  @override
  String? read(String path) {
    final bytes = readBytes(path);
    return bytes == null ? null : utf8.decode(bytes);
  }

  @override
  List<int>? readBytes(String path) => _files[_normalizeSourcePath(path)];

  @override
  bool exists(String path) {
    final target = _normalizeSourcePath(path);
    if (_files.containsKey(target)) return true;
    final prefix = '$target/';
    return _files.keys.any((candidate) => candidate.startsWith(prefix));
  }

  @override
  List<String> trackedFiles() => List<String>.unmodifiable(_files.keys);
}

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

String _normalizeSourcePath(String path) =>
    path.split('/').where((part) => part.isNotEmpty && part != '.').join('/');

/// One immutable Git commit exposed through the synchronous [SourceTree]
/// contract.
///
/// Status uses this when no local release stage exists. A dirty worktree is a
/// problem to report, but it must not make an exact published package look
/// different from the committed source the target version names.
class GitCommitSourceTree implements SourceTree {
  GitCommitSourceTree(String root, this.commit)
      : _repository = GitSourceTree(root);

  final GitSourceTree _repository;
  final String commit;
  List<String>? _tracked;

  @override
  String get description => '${_repository.root}@$commit';

  String _path(String path) {
    final parts =
        path.split('/').where((part) => part.isNotEmpty && part != '.');
    if (parts.contains('..')) {
      throw ArgumentError('path escapes the committed source: $path');
    }
    return parts.join('/');
  }

  @override
  List<String> trackedFiles() =>
      _tracked ??= _repository.trackedFilesAt(commit);

  @override
  bool exists(String path) {
    final target = _path(path);
    if (target.isEmpty) return true;
    if (trackedFiles().contains(target)) return true;
    final prefix = '$target/';
    return trackedFiles().any((candidate) => candidate.startsWith(prefix));
  }

  @override
  List<int>? readBytes(String path) {
    final target = _path(path);
    if (!trackedFiles().contains(target)) return null;
    return _repository.readBytesAt(commit, target);
  }

  @override
  String? read(String path) {
    final bytes = readBytes(path);
    return bytes == null ? null : utf8.decode(bytes);
  }
}

/// A read-only source snapshot materialized beneath a release stage.
///
/// Unlike [GitSourceTree], this directory deliberately has no `.git`
/// metadata. Its inventory is the regular-file tree copied from Git before
/// producers ran, so pub.dev comparison and changelog extraction can keep
/// using the [SourceTree] contract without falling back to the mutable
/// worktree.
class SnapshotSourceTree implements SourceTree {
  SnapshotSourceTree(this.root);

  final String root;

  @override
  String get description => root;

  String _resolve(String path) {
    final parts =
        path.split('/').where((part) => part.isNotEmpty && part != '.');
    if (parts.contains('..')) {
      throw ArgumentError('path escapes the source snapshot: $path');
    }
    return [root, ...parts].join('/');
  }

  @override
  String? read(String path) {
    final bytes = readBytes(path);
    return bytes == null ? null : utf8.decode(bytes);
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

  @override
  List<String> trackedFiles() {
    final directory = Directory(root);
    if (!directory.existsSync()) return const [];
    final files = <String>[];
    for (final entity
        in directory.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      files.add(
        entity.path
            .substring(directory.path.length + 1)
            .split(Platform.pathSeparator)
            .join('/'),
      );
    }
    files.sort();
    return files;
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
  String? read(String path) => files[_normalizeSourcePath(path)];

  @override
  List<int>? readBytes(String path) {
    final text = read(path);
    return text == null ? null : utf8.encode(text);
  }

  @override
  bool exists(String path) {
    final target = _normalizeSourcePath(path);
    if (files.containsKey(target)) return true;
    final prefix = '$target/';
    return files.keys.any((p) => p.startsWith(prefix));
  }

  @override
  List<String> trackedFiles() => files.keys.toList();
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
