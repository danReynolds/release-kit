/// Where a built-in release target may be selected in `release.toml`.
enum TargetScope { unit, project }

/// The small, closed target vocabulary understood by this build of rk.
///
/// This is configuration metadata, not a plugin interface. Keeping spelling
/// and scope together lets the parser reject misplaced targets without each
/// target implementation inventing another copy of the rules.
enum PublishTarget {
  gitTag('git-tag', 'gitTag', TargetScope.unit),
  pubDev('pub.dev', 'pubDev', TargetScope.project),
  githubRelease('github-release', 'githubRelease', TargetScope.unit),
  homebrew('homebrew', 'homebrew', TargetScope.project);

  const PublishTarget(this.configName, this.wireName, this.scope);

  final String configName;
  final String wireName;
  final TargetScope scope;

  /// Other built-in targets that give this destination its public identity
  /// or inputs. The parser owns diagnostics; the target vocabulary owns the
  /// dependency graph so adding an adapter cannot leave a second copy stale.
  Set<PublishTarget> get prerequisites => switch (this) {
        PublishTarget.githubRelease => const {PublishTarget.gitTag},
        PublishTarget.homebrew => const {PublishTarget.githubRelease},
        _ => const {},
      };

  /// Whether the destination's public identity depends on Git history.
  /// Non-Git projects remain valid for registry-only releases; selecting one
  /// of these targets is the explicit point where Git becomes required.
  bool get requiresGit => switch (this) {
        PublishTarget.gitTag ||
        PublishTarget.githubRelease ||
        PublishTarget.homebrew =>
          true,
        PublishTarget.pubDev => false,
      };

  static PublishTarget? named(String name) {
    for (final target in values) {
      if (target.configName == name) return target;
    }
    return null;
  }
}
