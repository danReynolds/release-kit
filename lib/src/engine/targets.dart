import 'assets.dart';
import 'checklist.dart';
import 'diagnostic.dart';
import 'resolve.dart';
import 'verdict.dart';

/// A configured public place a release is expected to reach.
enum ReleaseTargetKind {
  gitTag,
  pubDev,
  githubRelease,
  homebrew,
}

/// The immutable, manifest-derived identity of one public target.
///
/// Status and release already share [Step] as their execution contract. This
/// smaller view carries only what a report needs, without recovering meaning
/// from a step id or its human prose.
class TargetExpectation {
  TargetExpectation({
    required this.kind,
    required this.label,
    required this.coordinate,
    required this.targetVersion,
    required this.step,
    required Iterable<String> artifacts,
    this.project,
    this.uses,
  }) : artifacts = List<String>.unmodifiable(artifacts);

  final ReleaseTargetKind kind;
  final String label;
  final String coordinate;
  final String targetVersion;
  final Step step;
  final ResolvedProject? project;
  final List<String> artifacts;

  /// A concise reference to an artifact inventoried by another target.
  final String? uses;

  static List<TargetExpectation> derive(
    ResolvedUnit unit,
    Checklist checklist, {
    String? repository,
  }) {
    final targets = <TargetExpectation>[];
    for (final step in checklist.steps) {
      switch (step.kind) {
        case StepKind.tag:
          targets.add(TargetExpectation(
            kind: ReleaseTargetKind.gitTag,
            label: 'Git tag',
            coordinate: unit.tag,
            targetVersion: unit.version.canonical,
            step: step,
            // The tag binds the manifest digest in its annotation; it does
            // not host a file named release-manifest.json. Binary releases
            // publish that file on GitHub. A pub-only release is recovered
            // directly from its peeled source commit plus pub.dev's archive,
            // so inventing a downloadable tag artifact here would lie.
            artifacts: const [],
            uses: unit.shipsBinaries
                ? '${ReleaseAssets.manifest} from GitHub Release'
                : null,
          ));

        case StepKind.publishRegistry:
          final project = unit.projects.firstWhere(
            (project) => project.name == step.project,
          );
          targets.add(TargetExpectation(
            kind: ReleaseTargetKind.pubDev,
            label: 'pub.dev · ${project.name}',
            coordinate: project.name,
            targetVersion: project.version.canonical,
            step: step,
            project: project,
            // pub publishes the staged source directory. There is no honest
            // public archive filename to invent for this row.
            artifacts: const [],
          ));

        case StepKind.publishRelease:
          final project = unit.projects.firstWhere(
            (project) => project.name == step.project,
          );
          final artifacts = ReleaseAssets.expectedFor(project).toList()..sort();
          targets.add(TargetExpectation(
            kind: ReleaseTargetKind.githubRelease,
            label: repository == null
                ? 'GitHub Release'
                : 'GitHub Release · $repository',
            coordinate: repository == null
                ? unit.tag
                : '$repository/releases/tag/${unit.tag}',
            targetVersion: unit.version.canonical,
            step: step,
            project: project,
            artifacts: artifacts,
          ));

        case StepKind.publishFormula:
          final project = unit.projects.firstWhere(
            (project) => project.name == step.project,
          );
          final tap =
              repository == null ? unit.homebrewTap : unit.tapFor(repository);
          targets.add(TargetExpectation(
            kind: ReleaseTargetKind.homebrew,
            label: tap == null ? 'Homebrew' : 'Homebrew · $tap',
            coordinate: tap == null
                ? 'Formula/${project.executable}.rb'
                : '$tap/Formula/${project.executable}.rb',
            targetVersion: project.version.canonical,
            step: step,
            project: project,
            // The formula is a GitHub Release artifact too. Its bytes are
            // listed once under the target that owns the artifact inventory.
            artifacts: const [],
            uses: '${ReleaseAssets.formulaName(project.executable!)} from '
                'GitHub Release',
          ));

        case StepKind.prerequisite ||
              StepKind.build ||
              StepKind.sign ||
              StepKind.notarize ||
              StepKind.archive ||
              StepKind.checksums ||
              StepKind.completeStage:
          break;
      }
    }
    return List<TargetExpectation>.unmodifiable(targets);
  }
}

enum ArtifactStatus {
  notStaged,
  staged,
  invalid,
}

/// What the exact stage inspection established about one expected filename.
class ArtifactObservation {
  const ArtifactObservation({
    required this.name,
    required this.status,
    this.problem,
  });

  final String name;
  final ArtifactStatus status;
  final String? problem;
}

/// One public observation, kept in configured order by its caller.
class TargetObservation {
  TargetObservation({
    required this.expectation,
    required this.inspection,
    required this.currentVersion,
    required this.currentKnown,
    this.currentDetail,
    required Iterable<ArtifactObservation> artifacts,
  }) : artifacts = List<ArtifactObservation>.unmodifiable(artifacts);

  final TargetExpectation expectation;
  final Inspection inspection;

  /// Null with [currentKnown] true means the provider definitively has no
  /// current release. Null with it false means the read could not answer.
  final String? currentVersion;
  final bool currentKnown;
  final String? currentDetail;
  final List<ArtifactObservation> artifacts;
}

/// A report issue linked to its unit but independent of rendering.
class StatusIssue {
  StatusIssue({
    required this.diagnostic,
    this.unit,
    this.target,
    Map<String, String> evidence = const {},
  }) : evidence = Map<String, String>.unmodifiable(evidence);

  final String? unit;
  final String? target;
  final Diagnostic diagnostic;
  final Map<String, String> evidence;

  String get deduplicationKey => [
        unit ?? '',
        target ?? '',
        diagnostic.code,
        diagnostic.source?.toString() ?? '',
        diagnostic.message,
        diagnostic.remedy ?? '',
      ].join('\u0000');
}
