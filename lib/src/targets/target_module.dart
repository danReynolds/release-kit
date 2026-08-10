import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/registry.dart';
import '../engine/release_stage.dart';
import '../engine/resolve.dart';
import '../engine/targets.dart';
import '../engine/tools.dart';
import '../engine/verdict.dart';
import '../engine/version.dart';

/// One built-in public target and the manifest-derived identity it reports.
///
/// This is intentionally a closed application seam, not a runtime plugin API.
/// Provider behavior grows behind these modules while checklist ordering stays
/// explicit in the release coordinator.
abstract base class TargetModule {
  const TargetModule();

  ReleaseTargetKind get kind;
  StepKind get stepKind;

  TargetExpectation expectation({
    required ResolvedUnit unit,
    required Step step,
    String? repository,
  });

  Future<Inspection> inspectExact(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetExpectation target,
  );

  Future<Inspection> inspectLatest(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetExpectation target,
  );

  /// Which provider read answers the status question "what version is it at?"
  Inspection currentVersionInspection({
    required Inspection exact,
    required Inspection latest,
  }) =>
      latest;

  /// Whether a fresh latest-version read is required immediately before act.
  bool get latestVersionGuardsRelease => true;

  /// Whether an exact read may be unknown only because the private stage that
  /// supplies its expected bytes has not been produced yet.
  bool get unknownMayWaitForStage => false;

  /// Whether this public history makes the matching local-tag-ahead diagnostic
  /// redundant.
  bool get publicHistorySupersedesLocalTag => false;

  /// Invalidates provider state after an act or before an authoritative read.
  void invalidate(TargetReadContext context, TargetExpectation target) {}

  Diagnostic? aheadDiagnostic(
    ResolvedUnit unit,
    TargetExpectation target,
    Version publicVersion,
  ) =>
      Diagnostic(
        code: 'RK-MONO-003',
        message: '${target.label} is already at $publicVersion, ahead of the '
            'target ${target.targetVersion}',
        remedy: 'a release moves forward — bump past $publicVersion',
      );

  /// Whether a cross-step diagnostic belongs on this target's status row.
  bool ownsDiagnostic(
    Diagnostic diagnostic,
    TargetExpectation target,
  ) =>
      false;

  /// Local facts that also guard release when a remote history read cannot
  /// yet supersede them.
  Iterable<Diagnostic> localReleaseDiagnostics(
    TargetReadContext context,
    ResolvedUnit unit,
  ) =>
      const [];

  String conflictRemedy(
    ResolvedUnit unit,
    TargetExpectation target,
  );

  /// Target-owned staged artifacts that cannot be made until all configured
  /// archives can be produced on this host.
  Map<String, String> artifactsBlockedByIncompleteArchives(
    ResolvedUnit unit,
    TargetExpectation target,
    String archiveProblem,
  ) =>
      const {};
}

/// Read-only dependencies shared by the four built-in target modules.
final class TargetReadContext {
  const TargetReadContext({
    required this.registry,
    required this.pubDev,
    required this.git,
    required this.tools,
    required this.repository,
    required this.stageFor,
  });

  final RegistryReader? registry;
  final PublicationInspector? pubDev;
  final GitState git;
  final Tools? tools;
  final String? repository;
  final ReleaseStage Function(ResolvedUnit unit)? stageFor;

  ReleaseStage? reusableStage(ResolvedUnit unit) {
    final factory = stageFor;
    if (factory == null) return null;
    try {
      final stage = factory(unit);
      return stage.inspect().reusable ? stage : null;
    } on Object {
      return null;
    }
  }
}
