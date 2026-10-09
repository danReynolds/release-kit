import 'dart:io';

import '../asset_build.dart';
import '../binary_chain.dart';
import '../builds/capability.dart';
import '../builds/macos_identity.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/producer_lane.dart';
import '../engine/publish_target.dart';
import '../engine/receipt.dart';
import '../engine/resolve.dart';
import '../engine/stage.dart';
import '../engine/stage_source.dart';
import '../engine/tools.dart';
import '../engine/unit_release.dart';
import '../engine/verdict.dart';
import '../output/output.dart';
import '../output/progress.dart';
import '../targets/catalog.dart';
import '../targets/target_module.dart';
import 'release_preparation.dart';
import 'release_progress.dart';

/// Owns the private stage boundary: building, resuming or reusing the stage
/// a release publishes from.
final class ReleaseStageCoordinator {
  const ReleaseStageCoordinator({
    required this.initialGit,
    required this.output,
    required this.tools,
    required this.capabilities,
    required this.targets,
  });

  final GitState initialGit;
  final Output output;
  final Tools tools;
  final HostCapabilities capabilities;

  /// The modules that prepare each target's work.
  final TargetCatalog targets;

  /// Why a release must not replace [check]'s stage: one that completed
  /// and no longer validates, or whose receipt cannot be read, holds bytes
  /// an operator may have reviewed. `rk stage` may rebuild it
  /// ([mayReplaceReviewed]); a release refuses.
  Diagnostic? preparationProblem(
    ResolvedUnit unit,
    StageCheck check, {
    required bool mayReplaceReviewed,
  }) {
    if (mayReplaceReviewed ||
        (check.state != StageState.changed &&
            check.state != StageState.unreadable)) {
      return null;
    }
    final reviewed = check.state == StageState.changed;
    return Diagnostic(
      code: 'RK-STAGE-002',
      message: reviewed
          ? 'the reviewed release stage no longer validates'
          : 'the release stage receipt is invalid',
      remedy:
          '${check.lines.join('\n')}\n'
          '${reviewed ? 'rk will not silently replace reviewed bytes. ' : ''}'
          'Rebuild it explicitly: rk stage ${unit.name}',
    );
  }

  /// Settles what staging [unit] needs before its producers run: leftovers
  /// of an interrupted run are cleared, and its signing identity is chosen.
  /// Units do this one at a time, since choosing an identity may ask the
  /// operator. [fromSource] names, for each Pub package, the repository
  /// packages it takes from this source: see [StageRun.fromSource].
  Future<UnitStaging?> begin({
    required UnitRelease release,
    required Stage stage,
    required StageCheck check,
    required List<TargetClaim> claims,
    Map<String, Map<String, String>> fromSource = const {},
  }) async {
    final unit = release.unit;
    final staging = UnitStaging._(
      release: release,
      stage: stage,
      check: check,
      claims: claims,
      fromSource: fromSource,
    );
    if (check.state == StageState.resumable) {
      _discardUnrecorded(stage, [
        for (final work in release.work) ...work.outputs,
      ]);
    }
    if (!check.reusable && MacIdentity.signs(unit)) {
      final signing = await MacIdentity.settle(tools, output, unit, initialGit);
      if (signing == null) return null;
      staging._signing = signing;
    }
    return staging;
  }

  /// Produces or reuses the exact receipt-backed private stage [staging]
  /// describes. Its rows go on [shared] when units stage side by side, and
  /// on a board of its own otherwise.
  Future<PreparedRelease?> complete(
    UnitStaging staging, {
    StageReleaseProgress? shared,
  }) async {
    final UnitStaging(
      :release,
      :unit,
      :stage,
      :check,
      :claims,
      :fromSource,
      :signing,
      :producerSteps,
    ) = staging;
    final stageProgress =
        shared ??
        StageReleaseProgress(
          output,
          title: '${unit.name} ${unit.version} · staging',
          board: staging.board,
        );
    final warnings = <_StageWarning>[];
    if (check.reusable) {
      final receipt = check.receipt!;
      stageProgress
        ..restore(receipt.producers)
        ..settle(title: '${unit.name} ${unit.version} · already staged');
      _showStageWarnings(unit, _recordedStageWarnings(receipt, release));
      return PreparedRelease(
        claims: claims,
        signing: MacIdentity.recorded(receipt),
      );
    }

    if (check.state == StageState.resumable) {
      output.say('Resuming interrupted staging.', role: VisualRole.secondary);
    } else {
      if (check.state == StageState.changed) {
        output.say(
          'Rebuilding: the recorded stage no longer verifies.',
          role: VisualRole.secondary,
        );
      }
      try {
        stage.begin();
      } on Object catch (error) {
        stageProgress.discard();
        output.problem(
          Diagnostic(
            code: 'RK-STAGE-001',
            message: 'the old release stage could not be replaced safely',
            remedy:
                'resolve the recorded filesystem failure, then re-run '
                'rk stage ${unit.name}',
            evidence: '$error',
          ),
        );
        output.halt(HaltKind.beforeActing);
        return null;
      }
    }

    final recorded = stage.receipt!.producers;
    stageProgress.restore(recorded);
    final completed = {...recorded.keys};

    // Producers build from the commit the stage names, read once into
    // memory when anything remains to produce; each exports it into a
    // directory of its own.
    late final StageSourceSnapshot source;
    if (release.work.any(
      (work) => work != release.barrier && !completed.contains(work.name),
    )) {
      try {
        source = await stage.captureSource();
      } on Object catch (error) {
        stageProgress.discard();
        output.problem(
          Diagnostic(
            code: 'RK-STAGE-003',
            message: 'the committed source could not be read',
            remedy:
                'resolve the recorded source failure, then re-run '
                'rk stage ${unit.name}',
            evidence: '$error',
          ),
        );
        output.halt(HaltKind.beforeActing);
        return null;
      }
    }
    final laneSources = <String, ProducerLaneSource>{};
    final laneChains = <String, BinaryChain>{};
    final failures = <HaltKind>[];

    /// Records what [work] produced, and fills the rows it completes; null
    /// when it is recorded, and otherwise how the stage stopped. Work that
    /// failed has said why.
    HaltKind? settle(Work work, Produced produced) {
      if (produced.halt case final halt?) {
        _discardUnrecorded(stage, work.outputs);
        stageProgress.fail(work.name);
        return halt;
      }
      try {
        stage.record(
          work,
          evidence: produced.evidence,
          warnings: produced.warnings,
        );
        stageProgress.restore({
          work.name: stage.receipt!.producers[work.name]!,
        });
        return null;
      } on Object catch (error) {
        stageProgress.fail(work.name);
        _stageProgressProblem(error);
        return HaltKind.beforeActing;
      }
    }

    /// Runs [work], a target's input; null when it is recorded, and
    /// otherwise how the stage stopped.
    Future<HaltKind?> runTargetStage(Work work) async {
      final receiptName = work.name;
      final target = release.preparing(work)!;
      try {
        final produced = await targets
            .moduleFor(target.target)
            .prepare(
              StageRun(
                unit: unit,
                stage: stage,
                source: source,
                tools: tools,
                git: initialGit,
                output: output,
                rows: stageProgress.handleFor(receiptName),
                fromSource: fromSource[work.project?.name] ?? const {},
              ),
              work,
            );
        warnings.addAll([
          for (final warning in produced.warnings)
            _StageWarning(warning, target: target.id),
        ]);
        return settle(work, produced);
      } on Object catch (error) {
        _discardUnrecorded(stage, work.outputs);
        stageProgress.fail(receiptName);
        return _stageOperationProblem(
          '${target.label} stage preparation',
          error,
        );
      }
    }

    /// Runs [step], local work; null when it is recorded, and otherwise how
    /// the stage stopped.
    Future<HaltKind?> runProducer(Work step) async {
      final receiptName = step.name;
      // A project's own build has no platform; it is one lane of its own.
      final laneName = step.platform == null
          ? '${step.project!.name}/build'
          : '${step.project!.name}/${step.platform!}';
      try {
        final laneSource = laneSources.putIfAbsent(
          laneName,
          () => ProducerLaneSource.export(source, project: step.project!),
        );
        final chain = laneChains.putIfAbsent(
          laneName,
          () => _chain(stage, repositoryRoot: laneSource.path),
        );
        output.report.acted = true;
        stageProgress.begin(receiptName, _producerActivity(step));
        final Produced produced;
        try {
          produced = await _actProducer(
            step,
            unit,
            signing,
            chain: chain,
            progress: stageProgress.handleFor(receiptName),
          );
        } on Object catch (error) {
          _discardUnrecorded(stage, step.outputs);
          stageProgress.fail(receiptName);
          _stageOperationProblem(step.summary, error);
          return HaltKind.stoppedPartway;
        }
        return settle(step, produced);
      } on Object catch (error) {
        _discardUnrecorded(stage, step.outputs);
        stageProgress.fail(receiptName);
        return _stageOperationProblem('the ${unit.name} stage', error);
      }
    }

    /// Runs [work] in order, skipping what is recorded. Once any lane has
    /// failed, it starts nothing new; what is already running finishes.
    Future<void> lane(Iterable<Work> work) async {
      for (final piece in work) {
        if (failures.isNotEmpty) return;
        if (completed.contains(piece.name)) continue;
        final halt = piece.kind == StepKind.targetStage
            ? await runTargetStage(piece)
            : await runProducer(piece);
        if (halt != null) {
          failures.add(halt);
          return;
        }
        completed.add(piece.name);
      }
    }

    // Fixed lanes, started in the work's order: each package archive, the
    // release notes, and each platform's build, notarization and archive
    // (or the project's own build) side by side; each formula once every
    // archive is there.
    final platforms = <String?, List<Work>>{};
    for (final work in producerSteps) {
      (platforms[work.platform] ??= []).add(work);
    }
    await Future.wait([
      for (final work in release.work)
        if (work.kind == StepKind.targetStage &&
            work.target != PublishTarget.homebrew)
          lane([work]),
      Future.wait([for (final chain in platforms.values) lane(chain)]).then(
        (_) => lane([
          for (final work in release.work)
            if (work.target == PublishTarget.homebrew) work,
        ]),
      ),
    ]);

    for (final laneSource in laneSources.values) {
      try {
        laneSource.close();
      } on Object catch (error) {
        _stageOperationProblem('the ${unit.name} producer lane cleanup', error);
        failures.add(HaltKind.stoppedPartway);
      }
    }
    if (failures.isNotEmpty) {
      stageProgress.concludeStopped();
      if (!output.report.halted) {
        output.halt(
          failures.reduce(
            (left, right) => left.index >= right.index ? left : right,
          ),
        );
      }
      return null;
    }

    stageProgress.begin(
      'complete-stage',
      ProgressActivity(running: 'assembling', failed: 'assembly failed'),
    );
    try {
      stage.complete(release);
    } on Object catch (error) {
      stageProgress.conclude();
      output.problem(
        Diagnostic(
          code: 'RK-STAGE-003',
          message: 'the release stage could not be completed',
          remedy:
              'resolve the recorded stage assembly failure, then re-run '
              'rk stage ${unit.name}',
          evidence: '$error',
        ),
      );
      output.halt(HaltKind.beforeActing);
      return null;
    }

    output.step(
      release.barrier,
      verdict: Verdict.exact,
      detail: 'staged and validated',
      show: false,
    );
    stageProgress
      ..restore(stage.receipt!.producers)
      ..settle(title: '${unit.name} ${unit.version} · staged');
    _showStageWarnings(unit, warnings);
    return PreparedRelease(claims: claims, signing: signing);
  }

  /// Removes those of [files] the receipt does not record, so the work that
  /// writes them runs again from a clean slate: what an interrupted run
  /// wrote, or a producer that failed. Recorded files are kept.
  void _discardUnrecorded(Stage stage, Iterable<String> files) {
    try {
      stage.discardUnrecorded(files);
    } on Object {
      // The original failure remains the useful diagnosis, and the producer
      // that needs the path reports what it finds there.
    }
  }

  /// The warnings [receipt] keeps, each with the target its work prepares.
  List<_StageWarning> _recordedStageWarnings(
    Receipt receipt,
    UnitRelease release,
  ) => [
    for (final work in release.work)
      for (final warning in receipt.warnings(work.name))
        _StageWarning(warning, target: release.preparing(work)?.id),
  ];

  /// Says [found] with the run's other warnings, once every unit is staged.
  void _showStageWarnings(ResolvedUnit unit, Iterable<_StageWarning> found) {
    final seen = <String>{};
    for (final warning in found) {
      if (!seen.add(
        '${warning.diagnostic.code}\u0000'
        '${warning.diagnostic.message}',
      )) {
        continue;
      }
      output.deferWarning(
        warning.diagnostic,
        unit: unit.name,
        target: warning.target,
      );
    }
  }

  void _stageProgressProblem(Object error) {
    output.problem(
      Diagnostic(
        code: 'RK-STAGE-003',
        message: 'the completed producer could not be recorded safely',
        remedy:
            'resolve the recorded stage-write failure, then rebuild the '
            'stage',
        evidence: '$error',
      ),
    );
  }

  /// Reports [error] from [operation], and says how the stage stopped.
  HaltKind _stageOperationProblem(String operation, Object error) {
    // The source cannot be staged as committed, which is known before any
    // of it is built, and says why itself.
    if (error is StageSourceRefusal) {
      output.problem(error.diagnostic);
      return HaltKind.beforeActing;
    }
    output.problem(
      Diagnostic(
        code: 'RK-STAGE-003',
        message: '$operation failed while preparing the release stage',
        remedy:
            'fix the recorded local failure, then re-run; no public target '
            'was changed',
        evidence: '$error',
      ),
    );
    return HaltKind.stoppedPartway;
  }

  Future<Produced> _actProducer(
    Work step,
    ResolvedUnit unit,
    MacIdentity? signing, {
    required BinaryChain chain,
    ProgressHandle? progress,
  }) async {
    final project = step.project!;
    switch (step.kind) {
      case StepKind.build:
        return chain.buildStep(
          step,
          project,
          progress: progress,
          signing: step.platform!.startsWith('macos-') ? signing! : null,
        );
      case StepKind.notarize:
        return chain.notarizeStep(step, project);
      case StepKind.archive:
        return chain.archiveStep(step, project);
      case StepKind.buildAssets:
        final stage = chain.stage;
        return AssetBuild(
          tools: tools,
          output: output,
          stage: stage,
          sourceRoot: chain.repositoryRoot,
          // Beside the stages rather than in one, so it outlives them.
          cacheDirectory: [
            initialGit.root,
            '.rk',
            'cache',
            unit.name,
            project.name,
          ].join(Platform.pathSeparator),
        ).build(
          step,
          project,
          progress: progress,
          environment: {
            'RK_SOURCE_COMMIT': stage.id.commit,
            if (initialGit.originUrl case final repository?)
              'RK_REPOSITORY': repository,
            'RK_VERSION': project.version.canonical,
            if (unit.tag case final tag?) 'RK_TAG': tag,
          },
        );
      default:
        throw StateError(
          'step ${step.kind.name} is not a local stage producer',
        );
    }
  }

  BinaryChain _chain(Stage stage, {required String repositoryRoot}) =>
      BinaryChain(
        tools: tools,
        output: output,
        stage: stage,
        repositoryRoot: repositoryRoot,
        capabilities: capabilities,
        compilerExecutable: stage.sdk.executable,
      );

  ProgressActivity _producerActivity(Work step) => switch (step.kind) {
    StepKind.build => ProgressActivity(
      running: 'building',
      failed: 'build failed',
    ),
    StepKind.notarize => ProgressActivity(
      running: 'notarizing',
      failed: 'notarization failed',
    ),
    StepKind.archive => ProgressActivity(
      running: 'packaging',
      failed: 'packaging failed',
    ),
    StepKind.buildAssets => ProgressActivity(
      running: 'building',
      failed: 'build failed',
    ),
    _ => throw StateError('${step.kind.name} is not a stage producer'),
  };
}

final class _StageWarning {
  const _StageWarning(this.diagnostic, {this.target});

  final Diagnostic diagnostic;
  final String? target;
}

/// One unit's staging, settled up to its producers: see
/// [ReleaseStageCoordinator.begin].
final class UnitStaging {
  UnitStaging._({
    required this.release,
    required this.stage,
    required this.check,
    required this.claims,
    required this.fromSource,
  });

  final UnitRelease release;
  ResolvedUnit get unit => release.unit;
  final Stage stage;
  final StageCheck check;
  final List<TargetClaim> claims;
  final Map<String, Map<String, String>> fromSource;

  /// The identity a macOS build signs with; null for anything else.
  MacIdentity? get signing => _signing;
  MacIdentity? _signing;

  /// The rows this unit's stage fills.
  List<BoardGroup> get board => release.board;

  /// The local work: builds, notarizations, archives, a project's own build.
  late final List<Work> producerSteps = [
    for (final work in release.work)
      if (work.kind != StepKind.targetStage &&
          work.kind != StepKind.completeStage)
        work,
  ];
}
