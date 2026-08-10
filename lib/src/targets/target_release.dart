import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/release_stage.dart';
import '../engine/resolve.dart';
import '../engine/stage_receipt.dart';
import '../engine/stage_contract.dart';
import '../engine/targets.dart';
import '../engine/tools.dart';
import '../engine/verdict.dart';
import '../engine/workspace.dart';
import '../output/output.dart';
import 'target_module.dart';

/// The complete lifecycle every built-in public target must provide.
abstract base class TargetReleaseModule extends TargetModule {
  const TargetReleaseModule();

  /// Performs this target's ambient, fail-before-staging readiness check.
  ///
  /// Every target must choose this explicitly. A silent inherited success
  /// would let a newly added publisher omit its credential preflight and fail
  /// only after an earlier target had already acted.
  Future<bool> preflight(
    TargetPreflightContext context,
    ResolvedUnit unit,
  );

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

  StageContributionContract? stageContract({
    required ResolvedUnit unit,
    required TargetExpectation target,
    required String? repository,
    required String sourceRoot,
  }) =>
      null;

  Future<TargetStageResult> prepareStage(
    TargetStageContext context,
    ResolvedUnit unit,
    TargetExpectation target,
  ) async =>
      TargetStageResult.succeeded();

  Future<Iterable<TargetClaim>> firstClaims(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetExpectation target,
  ) async =>
      const [];

  /// Whether this target takes an externally irreversible release identity.
  bool get isPermanent;

  String? permanenceNotice(TargetExpectation target) => null;
}

final class TargetStageContext {
  TargetStageContext({
    required this.contract,
    required this.reads,
    required this.tools,
    required this.git,
    required this.repository,
    required this.output,
    required this.stage,
    required this.sourceStep,
    required Iterable<StageStep> progress,
  }) : progress = List<StageStep>.unmodifiable(progress);

  final StageContributionContract contract;
  final TargetReadContext reads;
  final Tools tools;
  final GitState git;
  final String? repository;
  final Output output;
  final ReleaseStage stage;
  Workspace get workspace => stage.directory.workspace;
  final StageStep sourceStep;
  final List<StageStep> progress;
}

final class TargetStageBinding {
  const TargetStageBinding({
    required this.module,
    required this.target,
    required this.contract,
  });

  final TargetReleaseModule module;
  final TargetExpectation target;
  final StageContributionContract contract;
}

final class TargetStageResult {
  TargetStageResult.succeeded({
    Iterable<StageStep> steps = const [],
  })  : ok = true,
        steps = List<StageStep>.unmodifiable(steps);

  const TargetStageResult.failed()
      : ok = false,
        steps = const [];

  final bool ok;
  final List<StageStep> steps;
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
/// The release coordinator owns ordering and the authorization boundary. A
/// target owns only its provider transaction and how that transaction is
/// reconciled with the shared read path.
final class TargetReleaseContext {
  const TargetReleaseContext({
    required this.reads,
    required this.tools,
    required this.git,
    required this.repository,
    required this.output,
    required this.stage,
    required this.wait,
    required this.confirmDeadline,
    required this.confirmInterval,
  });

  final TargetReadContext reads;
  final Tools tools;
  final GitState git;
  final String? repository;
  final Output output;
  final ReleaseStage stage;
  Workspace get workspace => stage.directory.workspace;
  final Future<void> Function(Duration duration) wait;
  final Duration confirmDeadline;
  final Duration confirmInterval;
}

/// Dependencies for an ambient target preflight performed before staging.
final class TargetPreflightContext {
  const TargetPreflightContext({
    required this.tools,
    required this.output,
    required this.git,
  });

  final Tools tools;
  final Output output;
  final GitState git;
}

/// Provider-neutral facts returned by one target act.
final class TargetActOutcome {
  const TargetActOutcome({
    required this.ok,
    this.problem,
    this.mayHaveActed = false,
    this.privateEffect = TargetPrivateEffect.none,
    this.terminal = false,
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
  final bool terminal;
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

/// A target-owned recovery action that is safe only after public absence was
/// established by the shared exact inspection.
abstract interface class TargetCleanup {
  Future<TargetCleanupResult> run();
}

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
    this.rerunHelps = true,
    this.nextCommand,
  });

  final Diagnostic diagnostic;
  final HaltKind halt;
  final bool rerunHelps;
  final String? nextCommand;
}
