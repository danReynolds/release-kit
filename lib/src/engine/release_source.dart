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
                wrongReleaseConfig('release.toml must be a regular file'),
              ])
            : const ConfigMissing();
      }
      final parsed = ReleaseConfig.parse(text, 'release.toml', diagnostics);
      if (parsed != null) {
        final resolution = Resolution.fromManifests(
          parsed,
          await read(Manifests.pathsFor(parsed)),
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
      ? wrongReleaseConfig(error.reason)
      : Diagnostic(
          code: 'RK-SRC-003',
          message: 'the source could not be read',
          remedy:
              '${error.path}: ${error.reason}\n'
              'Make every release input a readable regular file in the '
              'repository, then run rk again.',
        );

  static Diagnostic wrongReleaseConfig(String reason) => Diagnostic(
    code: 'RK-CONF-034',
    message: 'release.toml is there and rk could not read it',
    source: const SourceLocation('release.toml', 1),
    remedy: reason,
  );
}

/// release.toml and every declared project's pubspec.yaml, Cargo.toml and
/// CHANGELOG.md, read together from one source.
///
/// A file that is there and could not be read is refused only when it is
/// asked for: a project with a pubspec never reads the Cargo.toml beside it.
final class Manifests {
  Manifests._(this._texts, this._present);

  final Map<String, String? Function()> _texts;
  final Set<String> _present;

  /// The text of the file at [path], or null when there is none.
  ///
  /// Throws [SourceUnreadable] for a file that is there and could not be
  /// read.
  String? text(String path) =>
      (_texts[path] ?? (throw ArgumentError('$path was not read')))();

  /// Whether anything is at [path], a file or a directory.
  bool exists(String path) => _present.contains(path);

  /// What resolving [config] reads: each project's directory and the
  /// manifests and changelog in it.
  static List<String> pathsFor(ReleaseConfig config) => [
    for (final unit in config.units)
      for (final project in unit.projects) ...[
        project.path,
        for (final name in const ['pubspec.yaml', 'Cargo.toml', 'CHANGELOG.md'])
          project.path == '.' ? name : '${project.path}/$name',
      ],
  ];

  /// [paths] as [tree] has them.
  static Manifests readFrom(SourceTree tree, Iterable<String> paths) {
    final texts = <String, String? Function()>{};
    final present = <String>{};
    for (final path in paths) {
      try {
        final text = tree.read(path);
        texts[path] = () => text;
        if (text != null || tree.exists(path)) present.add(path);
      } on SourceUnreadable catch (error) {
        texts[path] = () => throw error;
        present.add(path);
      }
    }
    return Manifests._(texts, present);
  }

  /// [paths] as [commit] has them, read in one batch with the directories
  /// that hold them, whose entries say which of them are regular files.
  ///
  /// A changelog may be a link to another file in the commit, which a stage
  /// reads through: it is read through too, in one more batch.
  static Future<Manifests> readAt(
    CommitFiles commit,
    Iterable<String> paths,
  ) async {
    final objects = <String, GitObject?>{};
    Future<void> fetch(Iterable<String> names) async => objects.addAll(
      await commit.read(
        {
          for (final name in names) ...[name, _parent(name)],
        }.where((name) => !objects.containsKey(name)),
      ),
    );
    final listings = <String, Map<String, String>>{};
    String? modeOf(String path) {
      if (path.isEmpty) return '040000';
      final directory = _parent(path);
      return (listings[directory] ??= switch (objects[directory]) {
        final tree? when tree.type == 'tree' => commit.modesIn(tree),
        _ => const {},
      })[path.substring(directory.isEmpty ? 0 : directory.length + 1)];
    }

    final wanted = {for (final path in paths) path: path == '.' ? '' : path};
    await fetch(wanted.values);
    final links = {
      for (final MapEntry(key: path, value: name) in wanted.entries)
        if (path.split('/').last == 'CHANGELOG.md' && modeOf(name) == '120000')
          path: _within(
            _parent(name),
            utf8.decode(objects[name]!.bytes, allowMalformed: true),
          ),
    };
    if (links.values.nonNulls.isNotEmpty) await fetch(links.values.nonNulls);

    final texts = <String, String? Function()>{};
    final present = <String>{};
    for (final MapEntry(key: path, value: at) in wanted.entries) {
      if (modeOf(at) != null) present.add(path);
      // A link out of the commit stays a link, which is refused.
      final read = links.containsKey(path) ? links[path] ?? at : at;
      final object = objects[read];
      final mode = modeOf(read);
      final refusal = switch (mode) {
        '120000' => 'symbolic link',
        '160000' => 'gitlink/submodule',
        _ => null,
      };
      texts[path] = refusal != null
          ? () => throw SourceUnreadable(
              path,
              'the committed entry is a $refusal, not a regular file',
            )
          : object == null || object.type != 'blob'
          ? () => null
          : () => _decode(path, object.bytes);
    }
    return Manifests._(texts, present);
  }

  static String _decode(String path, List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw SourceUnreadable(path, 'it is not UTF-8 text');
    }
  }
}

/// The directory holding [path], or '' at the root.
String _parent(String path) {
  final cut = path.lastIndexOf('/');
  return cut < 0 ? '' : path.substring(0, cut);
}

/// [relative], a link's target as written in [directory], as a path in the
/// commit; null when it is absolute or climbs out of the commit.
String? _within(String directory, String relative) {
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
