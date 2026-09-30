import 'checklist.dart';
import 'diagnostic.dart';
import 'inspect.dart';
import 'resolve.dart';
import 'targets.dart';
import 'verdict.dart';
import '../targets/target_module.dart';

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
    // Destinations are independent; their reads happen together, the same
    // way status checks them. The slowest read, not the sum, is the wait.
    final stepList = steps.toList();
    final inspections = await Future.wait([
      for (final step in stepList) inspector.inspect(step, unit),
    ]);
    final states = <String, Inspection>{
      for (final (index, step) in stepList.indexed) step.id: inspections[index],
    };

    final monotonicity = Diagnostics();
    final history = await inspector.releaseMonotonicity(
      unit,
      targets,
      monotonicity,
      refreshRegistry: true,
    );

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
