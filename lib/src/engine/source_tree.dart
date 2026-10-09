import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'timings.dart';
import 'tools.dart';

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

/// The repository's files as they are on disk.
///
/// In Git ([git]) its files are those `git ls-files` lists, so untracked
/// material is invisible, and a read follows a symbolic link as the checkout
/// does. Outside Git, as for status, plan and init in a directory and for
/// the projects `rk use` installs from, the directory is walked, and a path
/// through a symbolic link is refused.
final class WorkingTree implements SourceTree {
  WorkingTree(this.root, {required this.git});

  final String root;
  final bool git;

  @override
  String get description => root;

  String _resolve(String path) {
    final parts = path
        .split('/')
        .where((part) => part.isNotEmpty && part != '.')
        .join('/');
    if (path.startsWith('/') ||
        parts.isNotEmpty && relativeSegments(parts) == null) {
      throw ArgumentError('path escapes the repository: $path');
    }
    var resolved = root;
    for (final part in parts.isEmpty ? const <String>[] : parts.split('/')) {
      resolved = '$resolved/$part';
      if (!git &&
          FileSystemEntity.typeSync(resolved, followLinks: false) ==
              FileSystemEntityType.link) {
        throw SourceUnreadable(
          path,
          'the path component "$part" is a symbolic link',
        );
      }
    }
    return resolved;
  }

  @override
  String? read(String path) {
    final bytes = readBytes(path);
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw SourceUnreadable(path, 'it is not UTF-8 text');
    }
  }

  @override
  List<int>? readBytes(String path) {
    final file = File(_resolve(path));
    final type = FileSystemEntity.typeSync(file.path, followLinks: git);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      // In Git a directory holds no file here, as the index would say.
      // Outside Git nothing says what it is, so it is refused.
      if (git) return null;
      throw SourceUnreadable(path, 'the path is not a regular file');
    }
    try {
      return file.readAsBytesSync();
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
  List<String> trackedFiles() => _tracked ??= git ? _listed() : _walked();

  List<String> _listed() {
    final result = timedRunSync('git', const [
      'ls-files',
      '-z',
    ], workingDirectory: root);
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
    return (result.stdout as String)
        .split('\u0000')
        .where((p) => p.isNotEmpty)
        .toList();
  }

  List<String> _walked() {
    final files = <String>[];
    for (final entity in Directory(
      root,
    ).listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = entity.path
          .substring(
            root.endsWith(Platform.pathSeparator)
                ? root.length
                : root.length + 1,
          )
          .split(Platform.pathSeparator)
          .join('/');
      if (relative == '.rk' || relative.startsWith('.rk/')) continue;
      if (relative == '.git' || relative.startsWith('.git/')) continue;
      files.add(relative);
    }
    return files..sort();
  }

  /// The repository root containing [start], or null when there is none.
  static String? findRoot(String start) {
    final result = timedRunSync('git', const [
      'rev-parse',
      '--show-toplevel',
    ], workingDirectory: start);
    if (result.exitCode != 0) return null;
    return (result.stdout as String).trim();
  }
}

/// An object in a commit: its type (`blob`, `tree`, `commit`) and its bytes.
typedef GitObject = ({String type, Uint8List bytes});

/// One immutable commit's files, read through [tools], never the worktree's.
///
/// Reading a whole commit, as a stage does, or a few release inputs, as
/// status and plan do, is one `git cat-file --batch` either way. One
/// `git show` per file is a process per file: 2.44s for this repository's
/// 165 files, against 0.065s batched.
final class CommitFiles {
  CommitFiles(this.root, this.commit, {this.tools = const SystemTools()});

  final String root;

  /// The commit's full object id.
  final String commit;
  final Tools tools;

  /// Every tracked entry with its mode (`git ls-tree -r -z`), read once.
  late final Future<List<GitTreeEntry>> entries = _listEntries();

  Future<List<GitTreeEntry>> _listEntries() async {
    final listed = await tools.run('git', [
      'ls-tree',
      '-r',
      '-z',
      commit,
    ], workingDirectory: root);
    if (!listed.ok) {
      throw SourceUnreadable(
        'the source tree at $commit',
        listed.stderr.trim(),
      );
    }
    return [
      for (final record in listed.stdout.split('\u0000'))
        if (record.isNotEmpty) _entry(record),
    ];
  }

  GitTreeEntry _entry(String record) {
    final tab = record.indexOf('\t');
    final metadata = record.substring(0, tab < 0 ? 0 : tab).split(' ');
    if (tab < 0 || metadata.length != 3) {
      throw SourceUnreadable(
        'the source tree at $commit',
        'git returned a malformed tree entry',
      );
    }
    return GitTreeEntry(
      path: record.substring(tab + 1),
      mode: metadata[0],
      type: metadata[1],
    );
  }

  /// The object at each path (`<commit>:<path>`; '' is the root tree), in
  /// one `git cat-file --batch`, or null where the commit has none. A path
  /// that contains a newline, which the protocol cannot carry, is read
  /// alone, and must be there.
  Future<Map<String, GitObject?>> read(Iterable<String> paths) async {
    final found = <String, GitObject?>{};
    final batched = <String>[];
    for (final path in paths) {
      // Git ends the whole batch at a path that climbs out of the commit.
      if (path.split('/').contains('..')) {
        throw ArgumentError('path escapes the commit: $path');
      }
      if (path.contains('\n')) {
        found[path] = await _readAlone(path);
      } else {
        batched.add(path);
      }
    }
    if (batched.isEmpty) return found;
    final answer = await tools.run(
      'git',
      const ['cat-file', '--batch'],
      workingDirectory: root,
      stdin: utf8.encode(batched.map((path) => '$commit:$path\n').join()),
    );
    if (!answer.ok) {
      throw SourceUnreadable('the commit $commit', answer.stderr.trim());
    }
    // In the order asked, each answer is `<name> missing`, or
    // `<oid> <type> <size>` followed by exactly size bytes and a newline.
    final out = answer.bytes;
    var at = 0;
    for (final path in batched) {
      final end = out.indexOf(0x0a, at);
      final header = end < 0
          ? ''
          : utf8.decode(out.sublist(at, end), allowMalformed: true);
      final fields = header.split(' ');
      final size = int.tryParse(fields.last);
      if (header.endsWith(' missing')) {
        found[path] = null;
        at = end + 1;
      } else if (fields.length != 3 ||
          size == null ||
          end + 1 + size > out.length) {
        throw SourceUnreadable(path, 'git cat-file answered "$header"');
      } else {
        found[path] = (
          type: fields[1],
          bytes: Uint8List.sublistView(out, end + 1, end + 1 + size),
        );
        at = end + 2 + size;
      }
    }
    return found;
  }

  Future<GitObject> _readAlone(String path) async {
    final name = '$commit:$path';
    final type = await tools.run('git', [
      'cat-file',
      '-t',
      name,
    ], workingDirectory: root);
    final content = type.ok
        ? await tools.run('git', [
            'cat-file',
            type.stdout.trim(),
            name,
          ], workingDirectory: root)
        : type;
    if (!content.ok) throw SourceUnreadable(path, content.stderr.trim());
    return (type: type.stdout.trim(), bytes: content.bytes);
  }

  /// The entries of [tree], a tree object read from this commit, by name,
  /// with their modes as `git ls-tree` writes them.
  Map<String, String> modesIn(GitObject tree) {
    // Each entry is `<mode> <name>\0` and the raw object id, as wide as the
    // commit's: 20 bytes for SHA-1, 32 for SHA-256.
    final bytes = tree.bytes;
    final modes = <String, String>{};
    var at = 0;
    while (at < bytes.length) {
      final space = bytes.indexOf(0x20, at);
      final end = space < 0 ? -1 : bytes.indexOf(0x00, space);
      if (end < 0) break;
      modes[utf8.decode(bytes.sublist(space + 1, end), allowMalformed: true)] =
          ascii.decode(bytes.sublist(at, space)).padLeft(6, '0');
      at = end + 1 + commit.length ~/ 2;
    }
    return modes;
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

/// A file as a source holds it: its text, null when there is none, or why
/// one that is there could not be read.
typedef SourceText = ({String? text, SourceUnreadable? error});

/// [path], in a commit whose symbolic links hold [links], with every link on
/// the way to it followed, as a checkout reads it: a stage reads its source
/// this way, and status and release its changelogs. Null when a link leads
/// out of the commit, or round in a circle.
String? followLinks(String path, Map<String, String> links) {
  var current = path;
  for (var hops = 0; hops < 40; hops++) {
    final parts = current.isEmpty ? const <String>[] : current.split('/');
    var end = 1;
    while (end <= parts.length &&
        !links.containsKey(parts.take(end).join('/'))) {
      end++;
    }
    if (end > parts.length) return current;
    final link = parts.take(end).join('/');
    final target = withinCommit(parentOf(link), links[link]!);
    if (target == null) return null;
    current = [
      target,
      ...parts.skip(end),
    ].where((part) => part.isNotEmpty).join('/');
  }
  return null;
}

/// [relative], written from [directory], as a path in the commit; null when
/// it is absolute or climbs out of the commit.
String? withinCommit(String directory, String relative) {
  if (relative.startsWith('/')) return null;
  final parts = [if (directory.isNotEmpty) ...directory.split('/')];
  for (final part in relative.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part != '..') {
      parts.add(part);
    } else if (parts.isEmpty) {
      return null;
    } else {
      parts.removeLast();
    }
  }
  return parts.join('/');
}

/// The directory holding [path], or '' at the root.
String parentOf(String path) {
  final cut = path.lastIndexOf('/');
  return cut < 0 ? '' : path.substring(0, cut);
}

/// The segments of [path] when it names a place inside a directory: relative,
/// with no empty, `.` or `..` segment, or NUL. rk runs on POSIX, where a
/// backslash or a colon is part of a name.
List<String>? relativeSegments(String path) {
  final parts = path.split('/');
  if (path.contains('\u0000') ||
      parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
    return null;
  }
  return parts;
}
