import 'dart:io';

import '../asset_build.dart';
import '../binary_chain.dart';
import '../builds/capability.dart';
import '../builds/macos_identity.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/publish_target.dart';
import '../engine/receipt.dart';
import '../engine/resolve.dart';
import '../engine/stage.dart';
import '../engine/stage_source.dart';
import '../engine/tools.dart';
import '../engine/unit_release.dart';
import '../engine/unit_snapshot.dart';
import '../engine/verdict.dart';
import '../output/output.dart';
import '../targets/catalog.dart';
import '../targets/target_module.dart';
import 'release_progress.dart';
import 'release_publish.dart' show UnitRun;

/// Builds, resumes or reuses the stage a unit's release publishes from.
final class StageRunner {
  const StageRunner({
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

  /// Settles what staging [run]'s unit needs before its producers run:
  /// leftovers of an interrupted run are cleared, and the identity its
  /// macOS build signs as is chosen. Units do this one at a time, since
  /// choosing an identity may ask the operator. False when refused, having
  /// said why.
  Future<bool> begin(UnitRun run) async {
    final UnitSnapshot(:unit, :release) = run.read;
    final check = run.read.stageCheck!;
    if (check.state == StageState.resumable) {
      _discardUnrecorded(run.read.stage!, [
        for (final work in release.work) ...work.outputs,
      ]);
    }
    if (!check.reusable && MacIdentity.signs(unit)) {
      run.identity = await MacIdentity.settle(tools, output, unit, initialGit);
      if (run.identity == null) return false;
    }
    return true;
  }

  /// Produces or reuses the receipt-backed stage [run]'s unit publishes
  /// from. Its rows go on [shared] when units stage side by side, and on a
  /// board of its own otherwise. False when it stopped, having said why.
  Future<bool> run(UnitRun run, {StageRows? shared}) async {
    final UnitSnapshot(:unit, :release) = run.read;
    final stage = run.read.stage!;
    final check = run.read.stageCheck!;
    final board = shared == null
        ? output.board(
            '${unit.name} ${unit.version} · staging',
            heartbeat: true,
          )
        : null;
    final rows = shared ?? StageRows(board!, release);
    // Stopped before any work: the board this unit owns goes, and on a
    // board units share its rows say they were not attempted.
    void abandon() => board == null ? rows.abandon() : board.discard();
    final warnings = <({Diagnostic warning, String target})>[];
    if (check.reusable) {
      final receipt = check.receipt!;
      rows.restore(receipt);
      board?.settle(title: '${unit.name} ${unit.version} · already staged');
      deferStageWarnings(output, release, receipt);
      run.identity = MacIdentity.recorded(receipt);
      return true;
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
        abandon();
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
        output.halt(Stop.refused);
        return false;
      }
    }

    rows.restore(stage.receipt!);
    final completed = {...stage.receipt!.producers.keys};

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
        abandon();
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
        output.halt(Stop.refused);
        return false;
      }
    }
    final lanes = <String, BinaryChain>{};
    final failures = <Stop>[];

    /// Records what [work] produced, and fills the rows it completes; null
    /// when it is recorded, and otherwise why the stage stopped. Work that
    /// failed has said why.
    Stop? settle(Work work, Produced produced) {
      if (produced.halt case final halt?) {
        _discardUnrecorded(stage, work.outputs);
        rows.fail(work);
        return halt;
      }
      try {
        stage.record(
          work,
          evidence: produced.evidence,
          warnings: produced.warnings,
        );
        rows.restore(stage.receipt!);
        return null;
      } on Object catch (error) {
        rows.fail(work);
        _stageProgressProblem(error);
        return Stop.refused;
      }
    }

    /// Runs [work], a target's input; null when it is recorded, and
    /// otherwise why the stage stopped.
    Future<Stop?> runTargetStage(Work work) async {
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
                rows: rows.of(work),
                fromSource: run.fromSource[work.project?.name] ?? const {},
              ),
              work,
            );
        warnings.addAll([
          for (final warning in produced.warnings)
            (warning: warning, target: target.id),
        ]);
        return settle(work, produced);
      } on Object catch (error) {
        _discardUnrecorded(stage, work.outputs);
        rows.fail(work);
        return _stageOperationProblem(
          '${target.label} stage preparation',
          error,
        );
      }
    }

    /// Runs [step], local work; null when it is recorded, and otherwise why
    /// the stage stopped.
    Future<Stop?> runProducer(Work step) async {
      // A project's own build has no platform; it is one lane of its own.
      final laneName = step.platform == null
          ? '${step.project!.name}/build'
          : '${step.project!.name}/${step.platform!}';
      try {
        final chain = lanes.putIfAbsent(
          laneName,
          () => _lane(stage, source, step.project!),
        );
        output.report.acted = true;
        rows.begin(step, _producerActivity(step));
        final Produced produced;
        try {
          produced = await _actProducer(
            step,
            unit,
            run.identity,
            chain: chain,
            progress: rows.of(step),
          );
        } on Object catch (error) {
          _discardUnrecorded(stage, step.outputs);
          rows.fail(step);
          _stageOperationProblem(step.summary, error);
          return Stop.partway;
        }
        return settle(step, produced);
      } on Object catch (error) {
        _discardUnrecorded(stage, step.outputs);
        rows.fail(step);
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
    for (final work in release.work) {
      if (work.kind == StepKind.targetStage ||
          work.kind == StepKind.completeStage) {
        continue;
      }
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

    for (final chain in lanes.values) {
      try {
        final directory = Directory(chain.repositoryRoot);
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      } on Object catch (error) {
        _stageOperationProblem('the ${unit.name} producer lane cleanup', error);
        failures.add(Stop.partway);
      }
    }
    if (failures.isNotEmpty) {
      rows.stopped();
      board?.conclude();
      if (!output.report.halted) output.halt(Stop.worst(failures));
      return false;
    }

    rows.begin(release.barrier, (
      running: 'assembling',
      failed: 'assembly failed',
    ));
    try {
      stage.complete(release);
    } on Object catch (error) {
      board?.conclude();
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
      output.halt(Stop.refused);
      return false;
    }

    output.record(
      release.barrier,
      verdict: Verdict.exact,
      detail: 'staged and validated',
    );
    rows.restore(stage.receipt!);
    board?.settle(title: '${unit.name} ${unit.version} · staged');
    for (final (:warning, :target) in warnings) {
      output.deferWarning(warning, unit: unit.name, target: target);
    }
    return true;
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

  /// Reports [error] from [operation], and says why the stage stopped.
  Stop _stageOperationProblem(String operation, Object error) {
    // The source cannot be staged as committed, which is known before any
    // of it is built, and says why itself.
    if (error is StageSourceRefusal) {
      output.problem(error.diagnostic);
      return Stop.refused;
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
    return Stop.partway;
  }

  Future<Produced> _actProducer(
    Work step,
    ResolvedUnit unit,
    MacIdentity? signing, {
    required BinaryChain chain,
    Rows? progress,
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

  /// A lane for [project]'s producers: a platform's build, notarization and
  /// archive, or the project's own build. Their outputs meet in the stage;
  /// their working files do not, since tools write scratch such as
  /// `.dart_tool` beneath the source, and one lane must never clean or reuse
  /// another's. So each lane works in its own export of [source], outside
  /// the repository, removed once every lane drains. The export is whole: a
  /// binary's Dart source can import any file by its path, and a project's
  /// own build may read anything. Only Pub bounds what it reads (see
  /// [StageSourceSnapshot.dartBuildInputs]).
  BinaryChain _lane(
    Stage stage,
    StageSourceSnapshot source,
    ResolvedProject project,
  ) {
    final compiler = stage.sdk.executable;
    final directory = Directory.systemTemp.createTempSync('rk-lane-');
    try {
      source.export(directory.path, reader: project.name);
    } on Object {
      directory.deleteSync(recursive: true);
      rethrow;
    }
    return BinaryChain(
      tools: tools,
      output: output,
      stage: stage,
      repositoryRoot: directory.path,
      capabilities: capabilities,
      compilerExecutable: compiler,
    );
  }

  Activity _producerActivity(Work step) => switch (step.kind) {
    StepKind.build => (running: 'building', failed: 'build failed'),
    StepKind.notarize => (running: 'notarizing', failed: 'notarization failed'),
    StepKind.archive => (running: 'packaging', failed: 'packaging failed'),
    StepKind.buildAssets => (running: 'building', failed: 'build failed'),
    _ => throw StateError('${step.kind.name} is not a stage producer'),
  };
}
