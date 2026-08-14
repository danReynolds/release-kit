import 'publish_target.dart';

/// One choice presented by `rk init` and documented by `rk target`.
///
/// A binary is a local output rather than a public target. Keeping it in the
/// same small vocabulary as the four public targets lets the selector and the
/// reference command agree without pretending their lifecycles are identical.
enum ReleaseChoice {
  binary(
    id: 'binary',
    selectorLabel: 'Binary',
    category: ReleaseChoiceCategory.localOutput,
    summary: 'Build standalone executable archives. Publishes nothing.',
  ),
  gitTag(
    id: 'git-tag',
    selectorLabel: 'Git tag',
    category: ReleaseChoiceCategory.releaseTarget,
    summary: 'Create and push a version tag.',
  ),
  pubDev(
    id: 'pub.dev',
    selectorLabel: 'pub.dev',
    category: ReleaseChoiceCategory.releaseTarget,
    summary: 'Publish a Dart package to pub.dev.',
  ),
  githubRelease(
    id: 'github-release',
    selectorLabel: 'GitHub',
    category: ReleaseChoiceCategory.releaseTarget,
    summary: 'Create a GitHub Release with selected outputs.',
  ),
  homebrew(
    id: 'homebrew',
    selectorLabel: 'Homebrew',
    category: ReleaseChoiceCategory.releaseTarget,
    summary: 'Publish stable executable releases through a Homebrew tap.',
  );

  const ReleaseChoice({
    required this.id,
    required this.selectorLabel,
    required this.category,
    required this.summary,
  });

  final String id;
  final String selectorLabel;
  final ReleaseChoiceCategory category;
  final String summary;

  /// Choices enabled alongside this one by the init selector.
  Set<ReleaseChoice> get requires {
    final result = <ReleaseChoice>{};
    if (this == ReleaseChoice.homebrew) result.add(ReleaseChoice.binary);
    final target = PublishTarget.named(id);
    if (target != null) {
      for (final prerequisite in target.prerequisites) {
        _addTargetAndPrerequisites(prerequisite, result);
      }
    }
    return Set.unmodifiable(result);
  }

  static ReleaseChoice? named(String id) {
    for (final choice in values) {
      if (choice.id == id) return choice;
    }
    return null;
  }
}

enum ReleaseChoiceCategory { localOutput, releaseTarget }

void _addTargetAndPrerequisites(
  PublishTarget target,
  Set<ReleaseChoice> result,
) {
  for (final prerequisite in target.prerequisites) {
    _addTargetAndPrerequisites(prerequisite, result);
  }
  final choice = ReleaseChoice.named(target.configName);
  if (choice == null) {
    throw StateError('no release choice describes ${target.configName}');
  }
  result.add(choice);
}
