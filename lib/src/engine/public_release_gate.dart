import 'checklist.dart';
import 'diagnostic.dart';
import 'inspect.dart';
import 'resolve.dart';
import 'targets.dart';
import 'verdict.dart';

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
    required Iterable<TargetExpectation> targets,
  }) async {
    final states = <String, Inspection>{};
    for (final step in steps) {
      states[step.id] = await inspector.inspect(step, unit);
    }

    final monotonicity = Diagnostics();
    await inspector.releaseMonotonicity(
      unit,
      targets,
      monotonicity,
      refreshRegistry: true,
    );

    return PublicReleaseSnapshot(
      states: states,
      monotonicityProblems: monotonicity.found,
      steps: steps,
    );
  }
}

final class PublicReleaseSnapshot {
  PublicReleaseSnapshot({
    required Map<String, Inspection> states,
    required Iterable<Diagnostic> monotonicityProblems,
    required Iterable<Step> steps,
  })  : states = Map.unmodifiable(states),
        monotonicityProblems = List.unmodifiable(monotonicityProblems),
        _steps = List.unmodifiable(steps);

  final Map<String, Inspection> states;
  final List<Diagnostic> monotonicityProblems;
  final List<Step> _steps;

  List<Step> get remaining => _steps
      .where((step) => states[step.id]!.verdict == Verdict.absent)
      .toList();

  Step? get blocked => _steps
      .where((step) => !states[step.id]!.isExact && !states[step.id]!.isAbsent)
      .firstOrNull;
}
