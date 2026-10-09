import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/resolve.dart';
import '../engine/unit_release.dart';
import '../output/output.dart';
import '../output/release_plan.dart';

/// Reports the complete configured release topology without inspecting state.
final class PlanCommand {
  const PlanCommand({
    required this.resolution,
    required this.git,
    required this.output,
  });

  final Resolution resolution;
  final GitState git;
  final Output output;

  int run({String? only}) {
    final repositoryName = git.root.split('/').last;
    // Outside Git there is no worktree to count; a repository with no
    // commit yet still has uncommitted files.
    final uncommitted = git.hasCommit || git.uncommitted.isNotEmpty
        ? git.uncommitted.length
        : null;
    if (only != null && resolution.unit(only) == null) {
      output.problem(
        Diagnostic(
          code: 'RK-CLI-003',
          message: 'no unit named "$only"',
          remedy:
              'this repository releases: '
              '${resolution.units.map((unit) => unit.name).join(', ')}',
        ),
      );
      return ExitCodes.usage;
    }

    final diagnostics = Diagnostics();
    final derived = UnitRelease.all(
      resolution,
      repository: git.originUrl,
      problems: diagnostics,
    );
    if (derived == null || diagnostics.isNotEmpty) {
      output.repository(repositoryName, git: git, uncommitted: uncommitted);
      output.blank();
      output.problems(diagnostics.found);
      return ExitCodes.refused;
    }
    final plan = [
      for (final release in derived)
        if (only == null || release.unit.name == only) release,
    ];
    output.repository(
      repositoryName,
      git: git,
      uncommitted: uncommitted,
      show: false,
    );
    output.report.section('plan', planJson(plan));
    renderPlan(
      output,
      plan,
      repository: repositoryName,
      source: sourceIdentity(
        git.branch,
        git.hasCommit ? git.shortHead : null,
        uncommitted,
      ),
    );
    return ExitCodes.ok;
  }
}

/// What `rk plan --json` reports: each unit, the units it needs first, and
/// its rows in release order.
Map<String, Object?> planJson(Iterable<UnitRelease> releases) => {
  'units': [
    for (final release in releases)
      {
        'name': release.unit.name,
        'version': release.unit.version.canonical,
        'tag': release.unit.tag,
        'requires_units': [
          ...{
            for (final requirement in release.requirements)
              requirement.provider.unitName,
          },
        ],
        'nodes': [for (final node in release.planNodes) node.toJson()],
      },
  ],
};
