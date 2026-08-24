import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/release_plan.dart';
import '../engine/resolve.dart';
import '../output/output.dart';
import '../output/release_plan.dart';
import '../targets/catalog.dart';

/// Reports the complete configured release topology without inspecting state.
final class PlanCommand {
  const PlanCommand({
    required this.resolution,
    required this.git,
    required this.output,
    required this.targets,
  });

  final Resolution resolution;
  final GitState git;
  final Output output;
  final TargetCatalog targets;

  int run({String? only}) {
    final repositoryName = git.root.split('/').last;
    final uncommitted = git.isBound ? git.uncommitted.length : null;
    if (only != null && resolution.unit(only) == null) {
      output.problem(
        Diagnostic(
          code: 'RK-CLI-003',
          message: 'no unit named "$only"',
          remedy: 'this repository releases: '
              '${resolution.units.map((unit) => unit.name).join(', ')}',
        ),
      );
      return ExitCodes.usage;
    }

    final diagnostics = Diagnostics();
    final derived = RepositoryReleasePlan.derive(
      resolution: resolution,
      repository: git.originUrl,
      targets: targets,
      diagnostics: diagnostics,
    );
    if (derived == null || diagnostics.isNotEmpty) {
      output.repository(
        name: repositoryName,
        branch: git.branch,
        commit: git.hasCommit ? git.shortHead : null,
        uncommitted: uncommitted,
        head: git.hasCommit ? git.head : null,
        remote: git.originUrl,
      );
      output.blank();
      output.problems(diagnostics.found);
      return ExitCodes.refused;
    }
    final plan = only == null ? derived : derived.select(only);
    output.report.repository(
      name: repositoryName,
      branch: git.branch,
      uncommitted: uncommitted,
      head: git.hasCommit ? git.head : null,
      remote: git.originUrl,
    );
    output.report.releasePlan(plan.toJson());
    ReleasePlanRenderer(output).render(
      plan,
      repository: repositoryName,
      branch: git.branch,
      commit: git.hasCommit ? git.shortHead : null,
      uncommitted: uncommitted,
    );
    return ExitCodes.ok;
  }
}
