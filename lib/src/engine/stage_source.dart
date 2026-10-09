import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:yaml/yaml.dart' as yaml;

import 'diagnostic.dart';
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
    this._submodules = const {},
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
    // A symbolic link is exported as one, as `git archive` would. A gitlink
    // has no files in this commit: an export that would hold it refuses.
    final submodules = {
      for (final path in all)
        if (entries[path] case final entry? when entry.type == 'commit') path,
    };
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
      submodules,
    );
  }

  @override
  final String description;
  final String? gitCommit;
  final Map<String, Uint8List> _files;
  final Set<String> _executable;
  final Map<String, String> _links;

  /// The commit's gitlinks: submodules, whose files it does not hold.
  final Set<String> _submodules;

  @override
  List<String> trackedFiles() => List.unmodifiable(_files.keys);

  /// The file at [path], read through any symbolic link on the way there
  /// that stays inside this commit, as reading a checkout would.
  @override
  List<int>? readBytes(String path) {
    final resolved = _resolve(_path(path));
    return resolved == null ? null : _files[resolved];
  }

  @override
  String? read(String path) {
    final bytes = readBytes(path);
    return bytes == null ? null : utf8.decode(bytes);
  }

  @override
  bool exists(String path) {
    final resolved = _resolve(_path(path));
    return resolved != null &&
        (resolved.isEmpty ||
            _files.containsKey(resolved) ||
            _files.keys.any((file) => file.startsWith('$resolved/')));
  }

  /// [path] with every symbolic link on it followed, or null when a link
  /// leads out of this commit or round in a circle.
  String? _resolve(String path) {
    var current = path;
    for (var hops = 0; hops < 40; hops++) {
      final parts = current.isEmpty ? const <String>[] : current.split('/');
      String? through;
      var rest = '';
      for (var end = 1; end <= parts.length; end++) {
        final prefix = parts.take(end).join('/');
        if (_links.containsKey(prefix)) {
          through = prefix;
          rest = parts.skip(end).join('/');
          break;
        }
      }
      if (through == null) return current;
      final target = _linkTarget(through);
      if (target == null) return null;
      current = [target, rest].where((part) => part.isNotEmpty).join('/');
    }
    return null;
  }

  /// Where the link at [link] points, as a path in this commit, or null for
  /// a target outside it.
  String? _linkTarget(String link) => _within(_parent(link), _links[link]!);

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
  /// source: that package, every other package in it, since a workspace, an
  /// override, a path dependency or an analysis options include can reach
  /// any of them, and the files directly inside each directory above
  /// [directory], such as a workspace's pubspec, analysis options and
  /// ignore rules. A package that encloses [directory], such as a workspace
  /// root, adds its `lib/` rather than everything beneath it, which is the
  /// rest of the repository. An export adds what links and analysis
  /// options includes lead to (see [export]).
  bool Function(String path) dartBuildInputs(String directory) {
    final own = _path(directory);
    final above = <String>{''};
    final parts = own.split('/');
    for (var end = 1; end < parts.length; end++) {
      above.add(parts.take(end).join('/'));
    }
    if (own.isEmpty) above.clear();
    final trees = {
      for (final package in packageDirectories.map(_path))
        if (above.contains(package))
          [package, 'lib'].where((part) => part.isNotEmpty).join('/')
        else
          package,
    };
    return (path) =>
        trees.any(
          (tree) => tree.isEmpty || path == tree || path.startsWith('$tree/'),
        ) ||
        above.contains(_parent(path));
  }

  /// Writes the files [only] selects, every file when it is null, with
  /// their modes, beneath [root]. A link it selects is written as a link,
  /// with what it leads to inside this commit, so that it resolves in the
  /// export as it does in a checkout; so is the file an analysis options
  /// file includes by a relative path. Exporting into a directory that
  /// already holds part of this source adds the rest.
  ///
  /// An export that would hold a submodule refuses before writing anything,
  /// with a [StageSourceRefusal] naming the submodule and [reader], the
  /// project built from the export: the commit records the submodule's
  /// commit and none of its files, so leaving them out would stage, and
  /// publish, an incomplete package.
  void export(String root, {bool Function(String path)? only, String? reader}) {
    final selected = _closure(only ?? (_) => true, reader);
    final modes = <String, String>{};
    for (final MapEntry(key: path, value: bytes) in _files.entries) {
      if (!selected.contains(path)) continue;
      final file = File(
        [root, ...StagePath.segments(path)].join(Platform.pathSeparator),
      );
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes);
      modes[file.path] = _executable.contains(path) ? '0755' : '0644';
    }
    setFileModes(modes);
    for (final MapEntry(key: path, value: target) in _links.entries) {
      if (!selected.contains(path)) continue;
      final link = Link(
        [root, ...StagePath.segments(path)].join(Platform.pathSeparator),
      );
      if (link.existsSync()) continue;
      link.createSync(target, recursive: true);
    }
  }

  /// The files, links and submodules [only] selects, a submodule being a
  /// directory it selects when it would select a file inside it, with
  /// everything they lead to: what a link points to (a file, another link,
  /// a submodule, or everything in a directory), and what an analysis
  /// options file includes by a relative path, as the analyzer reads it.
  /// One that holds a submodule refuses (see [export]).
  Set<String> _closure(bool Function(String path) only, String? reader) {
    final selected = <String>{};
    final options = <String>{};
    final pending = [
      for (final path in _files.keys)
        if (only(path)) path,
      for (final path in _links.keys)
        if (only(path)) path,
      for (final path in _submodules)
        if (only('$path/.')) path,
    ];
    void reach(String target) {
      // A link or a submodule on the way to the target is reached too.
      final parts = target.split('/');
      for (var end = 1; end < parts.length; end++) {
        final prefix = parts.take(end).join('/');
        if (_links.containsKey(prefix) || _submodules.contains(prefix)) {
          pending.add(prefix);
        }
      }
      if (_files.containsKey(target) ||
          _links.containsKey(target) ||
          _submodules.contains(target)) {
        pending.add(target);
        return;
      }
      final inside = target.isEmpty ? '' : '$target/';
      pending.addAll([
        for (final path in [..._files.keys, ..._links.keys, ..._submodules])
          if (path.startsWith(inside)) path,
      ]);
    }

    while (pending.isNotEmpty) {
      final path = pending.removeLast();
      if (!selected.add(path)) continue;
      if (_links.containsKey(path)) {
        if (_linkTarget(path) case final target?) reach(target);
      } else if (path.split('/').last == 'analysis_options.yaml' ||
          options.contains(path)) {
        for (final included in _includes(path)) {
          // A file the export holds anyway may have been read before this
          // said it holds options: it is read again, for its own includes.
          if (options.add(included)) selected.remove(included);
          reach(included);
        }
      }
    }
    for (final submodule in _submodules) {
      if (selected.contains(submodule)) {
        throw _withoutSubmodule(submodule, reader);
      }
    }
    return selected;
  }

  /// The files the analysis options at [path] include by a relative path,
  /// as paths in this commit. `package:` includes name a package, and every
  /// package is exported whole.
  List<String> _includes(String path) {
    final Object? include;
    try {
      final options = yaml.loadYaml(utf8.decode(_files[path]!));
      include = options is Map ? options['include'] : null;
    } on Object {
      return const [];
    }
    return [
      for (final value in include is List ? include : [include])
        if (value is String && !value.startsWith('package:'))
          if (_within(_parent(path), value) case final target?) target,
    ];
  }
}

StageSourceRefusal _withoutSubmodule(String submodule, String? reader) =>
    StageSourceRefusal(
      Diagnostic(
        code: 'RK-STAGE-003',
        message: reader == null
            ? '$submodule is a Git submodule, which a stage cannot hold'
            : '$reader would be staged without $submodule, a Git submodule',
        remedy:
            'a stage is made from this repository\'s commit, which records '
            'the submodule\'s commit and none of its files. Commit the files '
            'the build needs into this repository instead, or move the '
            'submodule out of the Dart packages; a project\'s own build reads '
            'the whole repository.',
      ),
    );

/// A stage that cannot be made from this source as committed.
final class StageSourceRefusal implements Exception {
  const StageSourceRefusal(this.diagnostic);

  final Diagnostic diagnostic;

  @override
  String toString() => '${diagnostic.message}: ${diagnostic.remedy}';
}

/// The directory holding [path], or '' at the root.
String _parent(String path) {
  final cut = path.lastIndexOf('/');
  return cut < 0 ? '' : path.substring(0, cut);
}

/// [relative], written from [directory], as a path in the commit; null when
/// it is absolute or climbs out of the commit.
String? _within(String directory, String relative) {
  if (relative.startsWith('/')) return null;
  final parts = [if (directory.isNotEmpty) ...directory.split('/')];
  for (final part in relative.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isEmpty) return null;
      parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  return parts.join('/');
}

String _path(String path) {
  final value = path
      .split('/')
      .where((part) => part.isNotEmpty && part != '.')
      .join('/');
  if (value.isNotEmpty) StagePath.require(value);
  return value;
}
