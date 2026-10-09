import 'dart:convert';

import 'config.dart';
import 'diagnostic.dart';
import 'git.dart';
import 'resolve.dart';
import 'source_tree.dart';
import 'tools.dart';

/// Where a command reads release.toml and the pubspecs, and the Git facts it
/// reads them with. Status, plan, stage and release all start here, and read
/// the configuration once.
///
/// A clean repository's configuration is read at its HEAD commit: those are
/// the bytes a stage is built from, whatever the working tree does meanwhile —
/// even a skip-worktree edit Git does not report. Anything else is read from
/// the working tree as it is: uncommitted changes, a repository with no
/// commit yet, or a directory outside Git. Status and plan work there; stage
/// and release refuse it before any work ([GitState.stagingProblem]).
final class ReleaseSource {
  ReleaseSource._({
    required this.root,
    required this.git,
    required this.inRepository,
    required this.tree,
    required this.tools,
  });

  /// The source containing [directory].
  static Future<ReleaseSource> open(
    String directory, {
    Tools tools = const SystemTools(),
  }) async {
    final gitRoot = WorkingTree.findRoot(directory);
    if (gitRoot == null) {
      return ReleaseSource._(
        root: directory,
        git: GitState.none(directory),
        inRepository: false,
        tree: WorkingTree(directory, git: false),
        tools: tools,
      );
    }
    final git = await GitState.read(gitRoot, tools: tools);
    return ReleaseSource._(
      root: gitRoot,
      git: git,
      inRepository: true,
      tree: WorkingTree(gitRoot, git: true),
      tools: tools,
    );
  }

  /// The repository root, or the directory itself outside Git.
  final String root;

  final GitState git;

  /// Whether [root] is a Git repository at all.
  final bool inRepository;

  /// The repository's files as they are. Staging reads the commit itself.
  final SourceTree tree;

  final Tools tools;

  /// Parses release.toml and resolves it: at HEAD when the repository is
  /// clean, in two batches (the root tree and release.toml, then each
  /// project's directory and the files in it), and from [tree] otherwise.
  Future<ConfigRead> readConfig() {
    if (git.isClean && git.hasCommit) {
      final commit = CommitFiles(root, git.head, tools: tools);
      return configFrom((paths) => Manifests.readAt(commit, paths));
    }
    return configIn(tree);
  }

  /// release.toml in [tree], parsed and resolved; [releasing] as
  /// [Resolution.fromManifests] takes it.
  static Future<ConfigRead> configIn(
    SourceTree tree, {
    bool releasing = true,
  }) => configFrom(
    (paths) async => Manifests.readFrom(tree, paths),
    releasing: releasing,
  );

  /// release.toml, parsed and resolved against the manifests it declares,
  /// each read through [read].
  static Future<ConfigRead> configFrom(
    Future<Manifests> Function(List<String> paths) read, {
    bool releasing = true,
  }) async {
    final diagnostics = Diagnostics();
    try {
      final config = await read(const ['release.toml']);
      final text = config.text('release.toml');
      if (text == null) {
        return config.exists('release.toml')
            ? ConfigProblems([
                _wrongReleaseConfig('release.toml must be a regular file'),
              ])
            : const ConfigMissing();
      }
      final parsed = ReleaseConfig.parse(text, 'release.toml', diagnostics);
      if (parsed != null) {
        final resolution = Resolution.fromManifests(
          parsed,
          await read(Manifests.pathsFor(parsed, releasing: releasing)),
          diagnostics,
          releasing: releasing,
        );
        if (resolution != null && diagnostics.isEmpty) {
          return ConfigResolved(resolution);
        }
      }
    } on SourceUnreadable catch (error) {
      diagnostics.report(unreadable(error));
    }
    return ConfigProblems(diagnostics.found);
  }

  /// What a release input that is there and could not be read is.
  static Diagnostic unreadable(SourceUnreadable error) =>
      error.path == 'release.toml'
      ? _wrongReleaseConfig(error.reason)
      : Diagnostic(
          code: 'RK-SRC-003',
          message: 'the source could not be read',
          remedy:
              '${error.path}: ${error.reason}\n'
              'Make every release input a readable regular file in the '
              'repository, then run rk again.',
        );

  static Diagnostic _wrongReleaseConfig(String reason) => Diagnostic(
    code: 'RK-SRC-003',
    message: 'release.toml is there and rk could not read it',
    source: const SourceLocation('release.toml', 1),
    remedy: reason,
  );
}

/// release.toml and every declared project's pubspec.yaml, Cargo.toml and
/// CHANGELOG.md, read together from one source.
///
/// A file that is there and could not be read is refused only when its
/// text is asked for: a project with a pubspec never reads the Cargo.toml
/// beside it, and a changelog is checked on its own unit.
final class Manifests {
  Manifests._(this._read, this._present);

  final Map<String, SourceText> _read;
  final Set<String> _present;

  /// The file at [path] as it was read.
  SourceText read(String path) =>
      _read[path] ?? (throw ArgumentError('$path was not read'));

  /// The text of the file at [path], or null when there is none.
  ///
  /// Throws [SourceUnreadable] for a file that is there and could not be
  /// read.
  String? text(String path) {
    final (:text, :unreadable) = read(path);
    if (unreadable != null) throw SourceUnreadable(path, unreadable);
    return text;
  }

  /// Whether anything is at [path], a file or a directory.
  bool exists(String path) => _present.contains(path);

  /// What resolving [config] reads: each project's directory and the
  /// manifests in it, with its changelog when [releasing].
  static List<String> pathsFor(ReleaseConfig config, {bool releasing = true}) =>
      [
        for (final unit in config.units)
          for (final project in unit.projects) ...[
            project.path,
            for (final name in [
              'pubspec.yaml',
              'Cargo.toml',
              if (releasing) 'CHANGELOG.md',
            ])
              project.path == '.' ? name : '${project.path}/$name',
          ],
      ];

  /// [paths] as [tree] has them.
  static Manifests readFrom(SourceTree tree, Iterable<String> paths) {
    final read = <String, SourceText>{};
    final present = <String>{};
    for (final path in paths) {
      try {
        final text = tree.read(path);
        read[path] = (text: text, unreadable: null);
        if (text != null || tree.exists(path)) present.add(path);
      } on SourceUnreadable catch (error) {
        read[path] = (text: null, unreadable: error.reason);
        present.add(path);
      }
    }
    return Manifests._(read, present);
  }

  /// [paths] as [commit] has them, read in one batch with the directories
  /// that hold them, whose entries say which of them are regular files.
  ///
  /// A changelog may be a symbolic link, which a stage reads through link by
  /// link ([followLinks]): so does this, from the commit's links.
  static Future<Manifests> readAt(
    CommitFiles commit,
    Iterable<String> paths,
  ) async {
    final wanted = {for (final path in paths) path: path == '.' ? '' : path};
    final objects = await commit.read({
      for (final name in wanted.values) ...[name, parentOf(name)],
    });
    final listings = <String, Map<String, String>>{};
    String? modeOf(String path) {
      if (path.isEmpty) return '040000';
      final directory = parentOf(path);
      return (listings[directory] ??= switch (objects[directory]) {
        final tree? when tree.type == 'tree' => commit.modesIn(tree),
        _ => const {},
      })[path.substring(directory.isEmpty ? 0 : directory.length + 1)];
    }

    final linked = await _readThrough(commit, [
      for (final MapEntry(key: path, value: at) in wanted.entries)
        if (path.split('/').last == 'CHANGELOG.md' && modeOf(at) == '120000')
          at,
    ]);
    final read = <String, SourceText>{};
    final present = <String>{};
    for (final MapEntry(key: path, value: at) in wanted.entries) {
      final mode = modeOf(at);
      if (mode != null) present.add(path);
      final object = linked.containsKey(at) ? linked[at] : objects[at];
      final refusal = switch (mode) {
        _ when linked.containsKey(at) =>
          object == null
              ? 'it is a symbolic link to no file in the commit'
              : null,
        '120000' =>
          'the committed entry is a symbolic link, not a regular file',
        '160000' =>
          'the committed entry is a gitlink/submodule, not a regular file',
        _ => null,
      };
      read[path] = switch ((refusal, object)) {
        (final reason?, _) => (text: null, unreadable: reason),
        (_, final file?) when file.type == 'blob' => _decode(file.bytes),
        _ => (text: null, unreadable: null),
      };
    }
    return Manifests._(read, present);
  }

  /// What each of [links], symbolic links in [commit], leads to through
  /// every link on the way: the regular file it reads as, or null.
  static Future<Map<String, GitObject?>> _readThrough(
    CommitFiles commit,
    List<String> links,
  ) async {
    if (links.isEmpty) return const {};
    final entries = {
      for (final entry in await commit.entries) entry.path: entry,
    };
    final all = [
      for (final entry in entries.values)
        if (entry.mode == '120000') entry.path,
    ];
    final held = await commit.read(all);
    final targets = {
      for (final link in all)
        link: utf8.decode(held[link]!.bytes, allowMalformed: true),
    };
    final files = {
      for (final link in links)
        if (followLinks(link, targets) case final file?
            when entries[file]?.isRegularFile ?? false)
          link: file,
    };
    final read = await commit.read(files.values);
    return {for (final link in links) link: read[files[link]]};
  }

  static SourceText _decode(List<int> bytes) {
    try {
      return (text: utf8.decode(bytes), unreadable: null);
    } on FormatException {
      return (text: null, unreadable: 'it is not UTF-8 text');
    }
  }
}

/// What reading release.toml found.
sealed class ConfigRead {
  const ConfigRead();
}

/// No release.toml: a repository that does not use rk, which is an answer
/// rather than a failure.
final class ConfigMissing extends ConfigRead {
  const ConfigMissing();
}

final class ConfigProblems extends ConfigRead {
  const ConfigProblems(this.problems);

  final List<Diagnostic> problems;
}

final class ConfigResolved extends ConfigRead {
  const ConfigResolved(this.resolution);

  final Resolution resolution;
}
