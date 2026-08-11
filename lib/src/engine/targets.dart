import 'checklist.dart';
import 'diagnostic.dart';
import 'resolve.dart';
import 'verdict.dart';

/// The immutable, manifest-derived identity of one public target.
///
/// Status and release already share [Step] as their execution contract. This
/// smaller view carries only what a report needs, without recovering meaning
/// from a step id or its human prose.
class TargetExpectation {
  TargetExpectation({
    required this.label,
    required this.coordinate,
    required this.targetVersion,
    required this.step,
    required Iterable<String> artifacts,
    this.project,
    this.uses,
    this.exactComparisonNeedsStage = false,
  }) : artifacts = List<String>.unmodifiable(artifacts);

  /// Stable report spelling derived from the canonical checklist kind.
  String get kind => step.kind.targetName!;
  final String label;
  final String coordinate;
  final String targetVersion;
  final Step step;
  final ResolvedProject? project;
  final List<String> artifacts;

  /// A concise reference to an artifact inventoried by another target.
  final String? uses;

  /// Whether exact public bytes need a staged local counterpart.
  final bool exactComparisonNeedsStage;
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

  /// The kind of destination, without the thing it points at.
  String get kindLabel => expectation.label.split(' · ').first;

  /// What this row is about, when the section heading has already said what
  /// state it is in — a tag name, a package, a repository. A row that
  /// carried neither state nor identity read as unfinished.
  String get identity {
    final parts = expectation.label.split(' · ');
    return parts.length > 1
        ? parts.sublist(1).join(' · ')
        : expectation.coordinate;
  }

  /// What this target has waiting for it here.
  String get stagedSummary => artifacts.length == 1
      ? artifacts.single.name
      : '${artifacts.length} artifacts';
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
