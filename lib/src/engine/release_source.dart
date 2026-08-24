import 'config.dart';
import 'diagnostic.dart';
import 'git.dart';
import 'resolve.dart';
import 'source_tree.dart';

/// The source identity selected for one status or release scope.
///
/// A clean Git repository stays commit-bound. A dirty repository may instead
/// use its current working tree only when none of the selected units needs a
/// Git identity; that mode is an unbound, single-invocation byte snapshot.
final class ReleaseSource {
  const ReleaseSource._({
    required this.resolution,
    required this.tree,
    required this.binding,
    required this.repository,
    this.warning,
  });

  /// [repository] is the state already read for this invocation. Reading
  /// it again here asked git the same eleven questions twice per run.
  static ReleaseSource? select({
    required SourceTree tree,
    required GitState git,
    required GitState repository,
    required Resolution resolution,
    required String? only,
    required Diagnostics diagnostics,
  }) {
    if (!git.isBound) {
      final frozen = _freeze(tree, diagnostics);
      if (frozen == null) return null;
      final frozenResolution = _resolve(frozen, diagnostics);
      if (frozenResolution == null) return null;
      if (!_validateUnboundTargets(frozenResolution, only, diagnostics)) {
        return null;
      }
      return ReleaseSource._(
        resolution: frozenResolution,
        tree: frozen,
        binding: git,
        repository: git,
      );
    }

    if (repository.worktreeStatusError != null) {
      // The command will surface RK-GIT-008 before any stage or public act.
      // Retain the preliminary model because rk cannot safely decide whether
      // the worktree is a clean commit or a snapshot candidate.
      return ReleaseSource._(
        resolution: resolution,
        tree: tree,
        binding: repository,
        repository: repository,
      );
    }

    if (repository.isClean) {
      final committed = GitCommitSourceTree(repository.root, repository.head);
      final committedResolution = _resolve(committed, diagnostics);
      if (committedResolution == null) return null;
      return ReleaseSource._(
        resolution: committedResolution,
        tree: GitSourceTree(repository.root),
        binding: repository,
        repository: repository,
      );
    }

    final frozen = _freeze(
      GitWorktreeSourceTree(repository.root),
      diagnostics,
    );
    if (frozen == null) return null;
    final frozenResolution = _resolve(frozen, diagnostics);
    if (frozenResolution == null) return null;
    final selected = _selected(frozenResolution, only).toList();
    final needsGit =
        selected.isEmpty || selected.any((unit) => unit.requiresGit);
    return ReleaseSource._(
      resolution: frozenResolution,
      tree: frozen,
      binding: needsGit ? repository : GitState.unbound(repository.root),
      repository: repository,
      warning: needsGit ? null : repository.uncommittedSnapshotWarning(),
    );
  }

  static FrozenSourceTree? _freeze(
    SourceTree source,
    Diagnostics diagnostics,
  ) {
    try {
      return FrozenSourceTree.capture(source);
    } on SourceUnreadable catch (error) {
      diagnostics.add(
        'RK-SRC-003',
        'the source snapshot could not be frozen',
        remedy: '${error.path}: ${error.reason}\n'
            'Stop concurrent edits, then run rk again.',
      );
      return null;
    }
  }

  static Resolution? _resolve(
    SourceTree source,
    Diagnostics diagnostics,
  ) {
    try {
      final configSource = source.read('release.toml');
      if (configSource == null) {
        diagnostics.add(
          'RK-SRC-003',
          'release.toml disappeared while the source snapshot was frozen',
          remedy: 'Restore the file, then run rk again.',
        );
        return null;
      }
      final config = ReleaseConfig.parse(
        configSource,
        'release.toml',
        diagnostics,
      );
      return config == null
          ? null
          : Resolution.resolve(config, source, diagnostics);
    } on SourceUnreadable catch (error) {
      diagnostics.add(
        'RK-SRC-003',
        'the selected source could not be read',
        remedy: '${error.path}: ${error.reason}\n'
            'Make every release input a regular repository file, then run '
            'rk again.',
      );
      return null;
    }
  }

  static bool _validateUnboundTargets(
    Resolution resolution,
    String? only,
    Diagnostics diagnostics,
  ) {
    var valid = true;
    for (final unit in _selected(resolution, only)) {
      final requiringGit = <String>{
        for (final target in unit.publish)
          if (target.requiresGit) target.configName,
        for (final project in unit.projects)
          for (final target in project.publish)
            if (target.requiresGit) target.configName,
      }.toList()
        ..sort();
      if (requiringGit.isEmpty) continue;
      valid = false;
      diagnostics.add(
        'RK-SRC-001',
        '${unit.name} selects targets that require Git',
        remedy: 'initialize a Git repository, or remove '
            '${requiringGit.join(', ')} from this unit',
      );
    }
    return valid;
  }

  static Iterable<ResolvedUnit> _selected(
    Resolution resolution,
    String? only,
  ) =>
      only == null
          ? resolution.units
          : resolution.units.where((unit) => unit.name == only);

  /// The release model parsed from [tree]. For dirty source, both are the
  /// same immutable capture rather than observations made at different times.
  final Resolution resolution;

  final SourceTree tree;

  /// The identity used by stages and public comparisons.
  final GitState binding;

  /// The surrounding repository, retained for honest status metadata.
  final GitState repository;

  /// Nonblocking disclosure when current working-tree bytes are captured.
  final Diagnostic? warning;
}
