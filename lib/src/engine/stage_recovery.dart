import 'checklist.dart';
import 'publish_target.dart';
import 'resolve.dart';
import 'verdict.dart';

/// Whether public progress requires preserving this unit's original stage:
/// whether bytes already public must match the ones it holds.
///
/// Only built release assets do: on a GitHub release, in a Homebrew formula
/// that names their hashes, and in the release manifest a tag annotation
/// records. A unit without them stages the same manifest again from its
/// commit, and a published package binds nothing.
bool hasRecoveryCriticalPublicProgress(
  ResolvedUnit unit,
  Iterable<(Step, Inspection)> observations,
) => observations.any((observation) {
  final (step, state) = observation;
  return step.isPublic &&
      step.unit == unit.name &&
      state.isExact &&
      unit.buildsReleaseAssets &&
      step.target != PublishTarget.pubDev;
});
