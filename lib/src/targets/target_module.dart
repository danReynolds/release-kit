import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/publish_target.dart';
import '../engine/registry.dart';
import '../engine/release_stage.dart';
import '../engine/resolve.dart';
import '../engine/stage_contract.dart';
import '../engine/stage_receipt.dart';
import '../engine/targets.dart';
import '../engine/tools.dart';
import '../engine/verdict.dart';
import '../engine/version.dart';
import '../engine/workspace.dart';
import '../output/output.dart';

/// The tag coordinate guaranteed by a selected tag-backed target.
///
/// Untagged units legitimately carry no tag. Target derivation is the boundary
/// where configuration has already proved that a Git tag, GitHub Release, or
/// Homebrew target is selected and therefore has a tag prerequisite.
String requiredTargetTag(ResolvedUnit unit, PublishTarget target) {
  assert(_selects(unit, target));
  assert(unit.publish.contains(PublishTarget.gitTag));
  final tag = unit.tag;
  assert(tag != null);
  return tag!;
}

/// The tag pattern guaranteed by a selected tag-backed target.
String requiredTargetTagPattern(ResolvedUnit unit, PublishTarget target) {
  assert(_selects(unit, target));
  assert(unit.publish.contains(PublishTarget.gitTag));
  final pattern = unit.tagPattern;
  assert(pattern != null);
  return pattern!;
}

bool _selects(ResolvedUnit unit, PublishTarget target) =>
    target.scope == TargetScope.unit
        ? unit.publish.contains(target)
        : unit.projects.any((project) => project.publish.contains(target));

/// One built-in public target and the manifest-derived identity it reports.
///
/// This is intentionally a closed application seam, not a runtime plugin API.
/// Provider behavior grows behind these modules while checklist ordering stays
/// explicit in the release coordinator.
abstract base class TargetModule {
  const TargetModule();

  PublishTarget get target;
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

  /// A separate public-history read, when this lane has one.
  ///
  /// Null means the exact target inspection also answers "what version is
  /// this lane at?" and no second monotonicity read is needed.
  Future<Inspection?> inspectLatest(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetExpectation target,
  ) async =>
      null;

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

  /// Performs this target's ambient, fail-before-staging readiness check.
  ///
  /// Every target must choose this explicitly. A silent inherited success
  /// would let a new publisher omit credential checks and fail only after an
  /// earlier target had acted.
  Future<bool> preflight(
    TargetReadinessContext context,
    ResolvedUnit unit,
  );

  /// Acquires or refreshes the native publication session after the exact
  /// stage exists and before authorization.
  ///
  /// Returning null means the module already reported a refusal. Every
  /// module chooses explicitly, including destinations whose native tool has
  /// no separate session-acquisition command.
  Future<TargetSession?> acquireSession(
    TargetReadinessContext context,
    ResolvedUnit unit,
    List<TargetExpectation> targets,
  );

  /// The effective destination bound before staging and checked after native
  /// credential acquisition. It is never serialized: an origin URL can carry
  /// credentials even though GitState normally redacts it for reports.
  String effectiveEndpoint(
    TargetReadinessContext context,
    ResolvedUnit unit,
    List<TargetExpectation> targets,
  ) {
    final coordinates = targets.map((item) => item.coordinate).toList()..sort();
    return [
      if (target.requiresGit) context.git.originUrl ?? 'unbound',
      ...coordinates,
    ].join('\n');
  }

  Future<TargetActOutcome> act(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetExpectation target,
    Inspection inspected,
  );

  Future<Inspection> settleAfterAct(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetExpectation target,
  ) =>
      inspectExact(context.reads, unit, target);

  Future<TargetFailure> classifyFailure(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetExpectation target,
    Inspection state,
    TargetActOutcome act, {
    required bool actedBefore,
  });

  Iterable<String> completionLines(
    ResolvedUnit unit,
    TargetExpectation target,
  ) =>
      const [];

  TargetStage? stage({
    required ResolvedUnit unit,
    required TargetExpectation target,
  }) =>
      null;

  Future<Iterable<TargetClaim>> firstClaims(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetExpectation target,
  ) async =>
      const [];

  String? permanenceNotice(TargetExpectation target) => null;
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

final class TargetStageContext {
  TargetStageContext({
    required this.contract,
    required this.tools,
    required this.git,
    required this.output,
    required this.stage,
    required this.sourceStep,
    required Iterable<StageStep> progress,
  }) : progress = List<StageStep>.unmodifiable(progress);

  final StageContributionContract contract;
  final Tools tools;
  final GitState git;
  String? get repository => git.originUrl;
  final Output output;
  final ReleaseStage stage;
  Workspace get workspace => stage.directory.workspace;
  final StageStep sourceStep;
  final List<StageStep> progress;
}

typedef TargetStageProducer = Future<StageStep?> Function(
  TargetStageContext context,
);

/// One optional, target-owned contribution to the reusable local stage.
///
/// Declaration, validation contract, and producer stay together so they
/// cannot drift across two lifecycle hooks.
final class TargetStage {
  const TargetStage({
    required this.target,
    required this.contract,
    required this.prepare,
  });

  final TargetExpectation target;
  final StageContributionContract contract;
  final TargetStageProducer prepare;
}

final class TargetClaim {
  const TargetClaim({
    required this.registrar,
    required this.name,
    required this.consequence,
  });

  final String registrar;
  final String name;
  final String consequence;
}

/// Runtime dependencies for one public target act.
///
/// The release coordinator owns ordering and authorization. A target owns its
/// provider transaction and reconciliation through the shared read path.
final class TargetReleaseContext {
  const TargetReleaseContext({
    required this.reads,
    required this.tools,
    required this.output,
    required this.stage,
    required this.wait,
    required this.confirmDeadline,
    required this.confirmInterval,
  });

  final TargetReadContext reads;
  final Tools tools;
  GitState get git => reads.git;
  String? get repository => reads.repository;
  final Output output;
  final ReleaseStage stage;
  Workspace get workspace => stage.directory.workspace;
  final Future<void> Function(Duration duration) wait;
  final Duration confirmDeadline;
  final Duration confirmInterval;
}

/// Dependencies shared by safe readiness and later session acquisition.
final class TargetReadinessContext {
  TargetReadinessContext({
    required this.tools,
    required this.output,
    required this.git,
    required Map<String, String> environment,
  }) : environment = Map.unmodifiable(environment);

  final Tools tools;
  final Output output;
  final GitState git;
  final Map<String, String> environment;
}

final class TargetSession {
  const TargetSession({required this.endpoint});

  /// Opaque destination identity, compared only for equality and never
  /// reported because it can include credential-bearing native coordinates.
  final String endpoint;
}

/// Provider-neutral facts returned by one target act.
final class TargetActOutcome {
  const TargetActOutcome({
    required this.ok,
    this.problem,
    this.mayHaveActed = false,
    this.privateEffect = TargetPrivateEffect.none,
    this.permanent,
    this.failureAlreadyReported = false,
    this.diagnostic,
    this.coordinate,
    this.cleanupIfAbsent,
    this.successNote,
    this.includeInspectionDetail = false,
    this.reconciledNote,
  });

  const TargetActOutcome.reportedFailure()
      : this(ok: false, failureAlreadyReported: true);

  final bool ok;
  final String? problem;
  final bool mayHaveActed;
  final TargetPrivateEffect privateEffect;
  final String? permanent;
  final bool failureAlreadyReported;
  final Diagnostic? diagnostic;
  final String? coordinate;
  final TargetCleanup? cleanupIfAbsent;
  final String? successNote;
  final bool includeInspectionDetail;
  final String? reconciledNote;
}

/// A private provider-side effect that is not itself a published release.
enum TargetPrivateEffect { none, changed, uncertain }

/// A target-owned recovery action safe only after public absence is proven.
typedef TargetCleanup = Future<TargetCleanupResult> Function();

final class TargetCleanupResult {
  const TargetCleanupResult({required this.ok, required this.detail});

  final bool ok;
  final String detail;
}

/// The target's final classification after an act and authoritative read-back.
final class TargetFailure {
  const TargetFailure({
    required this.diagnostic,
    required this.halt,
    this.nextCommand,
  });

  final Diagnostic diagnostic;
  final HaltKind halt;
  bool get rerunHelps => halt != HaltKind.actedAndUnfixable;
  final String? nextCommand;
}
