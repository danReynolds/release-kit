import 'config.dart';
import 'diagnostic.dart';
import 'git.dart';
import 'resolve.dart';
import 'source_tree.dart';

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
  });

  /// The source containing [directory].
  static Future<ReleaseSource> open(String directory) async {
    final gitRoot = GitSourceTree.findRoot(directory);
    if (gitRoot == null) {
      return ReleaseSource._(
        root: directory,
        git: GitState.none(directory),
        inRepository: false,
        tree: FileSystemSourceTree(directory),
      );
    }
    final git = await GitState.read(gitRoot);
    return ReleaseSource._(
      root: gitRoot,
      git: git,
      inRepository: true,
      tree: GitSourceTree(gitRoot),
    );
  }

  /// The repository root, or the directory itself outside Git.
  final String root;

  final GitState git;

  /// Whether [root] is a Git repository at all.
  final bool inRepository;

  /// The repository's files as they are. Staging reads the commit itself.
  final SourceTree tree;

  /// Parses release.toml and resolves it: at HEAD when the repository is
  /// clean, from [tree] otherwise.
  ConfigRead readConfig() {
    final tree = git.isClean && git.hasCommit
        ? GitCommitSourceTree(root, git.head)
        : this.tree;
    final String? text;
    try {
      text = tree.read('release.toml');
    } on SourceUnreadable catch (error) {
      return ConfigProblems([_unreadable(error)]);
    }
    if (text == null) {
      return tree.exists('release.toml')
          ? ConfigProblems([
              wrongReleaseConfig('release.toml must be a regular file'),
            ])
          : const ConfigMissing();
    }
    final diagnostics = Diagnostics();
    try {
      final config = ReleaseConfig.parse(text, 'release.toml', diagnostics);
      final resolution = config == null
          ? null
          : Resolution.resolve(config, tree, diagnostics);
      if (resolution != null && diagnostics.isEmpty) {
        return ConfigResolved(resolution);
      }
    } on SourceUnreadable catch (error) {
      diagnostics.report(_unreadable(error));
    }
    return ConfigProblems(diagnostics.found);
  }

  static Diagnostic _unreadable(SourceUnreadable error) =>
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
