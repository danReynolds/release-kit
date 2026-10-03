import 'checklist.dart';
import 'diagnostic.dart';
import 'inspect.dart';
import 'publish_target.dart';
import 'resolve.dart';
import 'targets.dart';
import 'verdict.dart';
import '../targets/target_module.dart';

/// Whether public progress requires preserving this unit's original stage.
///
/// Built release assets retain their existing exact-byte recovery rule. For a
/// package-only unit, an exact configured tag marks unit-level release progress;
/// an independently public package says nothing about its unstaged siblings.
/// The tag is a progress marker, not proof of a package's frozen dependencies.
bool hasRecoveryCriticalPublicProgress(
  ResolvedUnit unit,
  Iterable<(Step, Inspection)> observations,
) => observations.any((observation) {
  final (step, state) = observation;
  return step.isPublic &&
      step.unit == unit.name &&
      state.isExact &&
      (unit.buildsReleaseAssets ||
          (unit.publish.contains(PublishTarget.gitTag) &&
              step.target == PublishTarget.gitTag));
});

/// One fresh, coherent read of every public coordinate for a release.
///
/// Release deliberately takes this snapshot at more than one temporal
/// boundary. The gate owns what a snapshot means; the command keeps deciding
/// when it must be refreshed and how a refusal is presented.
final class PublicReleaseGate {
  const PublicReleaseGate(this.inspector);

  final Inspector inspector;

  Future<PublicReleaseSnapshot> refresh({
    required ResolvedUnit unit,
    required Iterable<Step> steps,
    required Iterable<TargetPlan> targets,
  }) async {
    // History refresh invalidates native provider caches. Read exact
    // coordinates only after that refresh so the snapshot describes the same
    // public view as its version guards and first-claim disclosures.
    final monotonicity = Diagnostics();
    final history = await inspector.releaseMonotonicity(
      unit,
      targets,
      monotonicity,
      refreshRegistry: true,
    );

    // Exact destination reads remain independent and run together.
    final stepList = steps.toList();
    final inspections = await Future.wait([
      for (final step in stepList) inspector.inspect(step, unit),
    ]);
    final states = <String, Inspection>{
      for (final (index, step) in stepList.indexed) step.id: inspections[index],
    };

    return PublicReleaseSnapshot(
      states: states,
      monotonicityProblems: monotonicity.found,
      claims: history.claims,
      steps: steps,
    );
  }
}

final class PublicReleaseSnapshot {
  PublicReleaseSnapshot({
    required Map<String, Inspection> states,
    required Iterable<Diagnostic> monotonicityProblems,
    Iterable<TargetClaim> claims = const [],
    required Iterable<Step> steps,
  }) : states = Map.unmodifiable(states),
       monotonicityProblems = List.unmodifiable(monotonicityProblems),
       claims = List.unmodifiable(claims),
       _steps = List.unmodifiable(steps);

  final Map<String, Inspection> states;
  final List<Diagnostic> monotonicityProblems;

  /// The names the release would claim for the first time, as this read
  /// found them.
  final List<TargetClaim> claims;
  final List<Step> _steps;

  List<Step> get remaining => _steps
      .where((step) => states[step.id]!.verdict == Verdict.absent)
      .toList();

  Step? get blocked => _steps
      .where((step) => !states[step.id]!.isExact && !states[step.id]!.isAbsent)
      .firstOrNull;
}
