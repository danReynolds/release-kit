import 'dart:io';

import '../binary_chain.dart';
import '../builds/capability.dart';
import '../engine/assets.dart';
import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/identity.dart';
import '../engine/producer_lane.dart';
import '../engine/producers.dart';
import '../engine/publish_target.dart';
import '../engine/release_stage.dart';
import '../engine/resolve.dart';
import '../engine/stage_board.dart';
import '../engine/stage_contract.dart';
import '../engine/stage_inspection.dart';
import '../engine/stage_receipt.dart';
import '../engine/targets.dart';
import '../engine/tools.dart';
import '../engine/verdict.dart';
import '../output/output.dart';
import '../output/progress.dart';
import '../targets/target_module.dart';
import '../transforms/macos.dart';
import 'release_preparation.dart';
import 'release_progress.dart';

/// Long enough that a preparation board helps instead of flashing briefly.
const _briefPhase = Duration(milliseconds: 800);

/// Owns the private stage boundary and the ambient facts that authorize its
/// reuse at a later public boundary.
final class ReleaseStageCoordinator {
  const ReleaseStageCoordinator({
    required this.initialGit,
    required this.output,
    required this.refreshGit,
    required this.refreshStage,
    required this.tools,
    required this.capabilities,
    required this.stageFor,
    required this.stageOnly,
  });

  final GitState initialGit;
  final Output output;
  final Future<GitState> Function() refreshGit;
  final ReleaseStage Function(ResolvedUnit unit, GitState git) refreshStage;
  final Tools tools;
  final HostCapabilities capabilities;
  final ReleaseStage Function(ResolvedUnit unit) stageFor;
  final bool stageOnly;

  Diagnostic? preparationProblem(
    ResolvedUnit unit,
    StageInspection inspected, {
    required bool mayReplaceReviewed,
  }) {
    if (inspected.reusable) return null;

    final unsafe = inspected.issues
        .where((issue) => issue.kind == StageIssueKind.unsafePath)
        .firstOrNull;
    if (unsafe != null) {
      return Diagnostic(
        code: 'RK-STAGE-001',
        message: 'the release stage path is unsafe',
        remedy: unsafe.toString(),
      );
    }

    final completedOrCorrupt =
        inspected.receipt?.steps.any((step) => step.name == 'complete-stage') ==
                true ||
            inspected.issues
                .any((issue) => issue.kind == StageIssueKind.invalidReceipt);
    if (completedOrCorrupt && !mayReplaceReviewed) {
      return Diagnostic(
        code: 'RK-STAGE-002',
        message: 'the reviewed release stage no longer validates',
        remedy: '${inspected.issues.join('\n')}\n'
            'rk will not silently replace reviewed bytes. Rebuild it '
            'explicitly: rk release ${unit.name} --stage',
      );
    }
    return null;
  }

  bool stageStillValid(
    ReleaseStage stage,
    ResolvedUnit unit, {
    required String changed,
    required HaltKind halt,
  }) {
    final inspected = stage.inspect();
    if (inspected.reusable) return true;
    output.problem(Diagnostic(
      code: 'RK-STAGE-002',
      message: 'the reviewed release stage changed $changed',
      remedy: '${inspected.issues.join('\n')}\n'
          'rebuild it explicitly: rk release ${unit.name} --stage',
    ));
    output.halt(halt);
    return false;
  }

  /// Re-reads every ambient input that authorizes reuse of [stage].
  Future<bool> contextStillValid(
    ReleaseStage stage,
    ResolvedUnit unit, {
    required String changed,
    required HaltKind halt,
  }) async {
    final drift = <String>[];
    final GitState current;
    try {
      current = await refreshGit();
    } on Object catch (error) {
      output.problem(Diagnostic(
        code: 'RK-STAGE-004',
        message: 'the release context could not be refreshed $changed',
        remedy: '$error\n'
            'restore a readable repository, then re-run '
            'rk release ${unit.name} --stage',
      ));
      output.halt(halt);
      return false;
    }

    if (current.isBound != initialGit.isBound) {
      drift.add('the source binding changed');
    } else if (initialGit.isBound && current.head != initialGit.head) {
      drift.add('HEAD is ${current.shortHead}; staged HEAD was '
          '${initialGit.shortHead}');
    }
    if (initialGit.isBound && current.headTree != initialGit.headTree) {
      drift.add('the HEAD tree changed');
    }
    if (initialGit.isBound && !current.isClean) {
      final detail = current.worktreeStatusError ??
          (current.uncommitted.isEmpty
              ? 'the worktree is not clean'
              : 'uncommitted: ${current.uncommitted.join(', ')}');
      drift.add(detail);
    }
    if (unit.publish.contains(PublishTarget.gitTag) && !current.headIsPushed) {
      drift.add('HEAD is no longer present on a remote branch');
    }
    if (initialGit.isBound && current.originUrl != initialGit.originUrl) {
      drift.add('origin is ${current.originUrl ?? 'unreadable'}; staged origin '
          'was ${initialGit.originUrl ?? 'unreadable'}');
    }
    if (unit.publish.contains(PublishTarget.gitTag) &&
        current.signingConfigured != initialGit.signingConfigured) {
      drift.add('the Git tag-signing policy changed');
    }
    if (!initialGit.isBound) {
      final sourceProblem = stage.unboundSourceProblem();
      if (sourceProblem != null) {
        drift.add('the unbound source changed: $sourceProblem');
      }
    }

    try {
      final refreshed = refreshStage(unit, current);
      if (refreshed.directory.identity.id != stage.directory.identity.id) {
        drift.add('the release plan now resolves to '
            '${refreshed.directory.identity.id}; the reviewed stage is '
            '${stage.directory.identity.id}');
      }
    } on Object catch (error) {
      drift.add('the release plan could not be resolved: $error');
    }

    if (drift.isEmpty) return true;
    output.problem(Diagnostic(
      code: 'RK-STAGE-004',
      message: 'the repository or release plan changed $changed',
      remedy: '${drift.join('\n')}\n'
          'restore those inputs or review a replacement stage: '
          'rk release ${unit.name} --stage',
    ));
    output.halt(halt);
    return false;
  }

  /// Produces or reuses the exact receipt-backed private stage.
  Future<PreparedRelease?> prepare({
    required ResolvedUnit unit,
    required Checklist checklist,
    required List<TargetPlan> targets,
    required List<TargetStage> targetStages,
    required ReleaseStage stage,
    required StageInspection inspected,
    required List<TargetClaim> claims,
  }) async {
    final inputs = await _prepareStageInputs(unit, inspected);
    if (inputs == null) return null;
    final signing = inputs.signing;
    final stageProgress = StageReleaseProgress(
      output,
      title: '${unit.name} ${unit.version} · staging',
      board: StageBoard.forUnit(unit, targets, targetStages),
    );
    final notices = <String>[];
    if (inspected.reusable) {
      stageProgress
        ..restore(inspected.receipt!.steps)
        ..settle(title: '${unit.name} ${unit.version} · staged');
      ReleaseSigningContext? recoveredSigning;
      for (final step in inspected.receipt!.steps.where(
        (step) => isMacosBuildReceipt(step.name),
      )) {
        final signature = step.evidence['signature']! as Map;
        final recovered = ReleaseSigningContext(
          publishedRequirement: signature['published_requirement'] as String?,
          firstIdentity: signature['first_identity']! as bool,
          certificateName: signature['certificate']! as String,
          certificateSha256: signature['certificate_sha256']! as String,
          designatedRequirement: signature['designated_requirement'] as String?,
          codeId: signature['code_id']! as String,
        );
        if (recoveredSigning != null &&
            !recoveredSigning.sameRecordedIdentity(recovered)) {
          output.problem(
            Diagnostic(
              code: 'RK-STAGE-003',
              message: 'the completed stage records conflicting signing '
                  'identities',
              remedy: 'rebuild it explicitly: '
                  'rk release ${unit.name} --stage',
            ),
            unit: unit.name,
          );
          output.halt(HaltKind.beforeActing);
          return null;
        }
        recoveredSigning = recovered;
      }
      return PreparedRelease(
        claims: claims,
        signing: recoveredSigning,
      );
    }

    final stageProblem = preparationProblem(
      unit,
      inspected,
      mayReplaceReviewed: stageOnly,
    );
    if (stageProblem != null) {
      stageProgress.discard();
      output.problem(stageProblem, unit: unit.name);
      output.halt(HaltKind.beforeActing);
      return null;
    }

    final progress = <StageStep>[];
    late final List<StageArtifact> sourceArtifacts;
    late final StageStep sourceStep;
    if (inspected.validProgress) {
      progress.addAll(inspected.receipt!.steps);
      sourceStep = progress.first;
      sourceArtifacts = List<StageArtifact>.from(sourceStep.outputs);
    } else {
      try {
        stage.reset();
      } on Object catch (error) {
        stageProgress.discard();
        output.problem(Diagnostic(
          code: 'RK-STAGE-001',
          message: 'the old release stage could not be replaced safely',
          remedy: '$error',
        ));
        output.halt(HaltKind.beforeActing);
        return null;
      }

      try {
        sourceArtifacts = await stage.materializeSource();
        sourceStep = _sourceStageStep(stage, sourceArtifacts);
        progress.add(sourceStep);
        _persistStageProgress(stage, sourceArtifacts, progress);
      } on Object catch (error) {
        stageProgress.discard();
        output.problem(Diagnostic(
          code: 'RK-STAGE-003',
          message: 'the committed source could not be staged',
          remedy: '$error',
        ));
        output.halt(HaltKind.beforeActing);
        return null;
      }
    }

    Future<bool> prepareTargets(StageContributionPhase phase) async {
      for (final targetStage in targetStages.where(
        (item) => item.contract.phase == phase,
      )) {
        final target = targetStage.target;
        final receiptName = targetStage.contract.step.name;
        if (progress.any((record) => record.name == receiptName)) continue;
        final TargetStageOutcome result;
        try {
          result = await targetStage.prepare(
            TargetStageContext(
              contract: targetStage.contract,
              tools: tools,
              git: initialGit,
              attach: output.report.attach,
              stage: stage,
              sourceStep: sourceStep,
              priorSteps: progress,
              progress: stageProgress.handlesFor(targetStage),
            ),
          );
        } on Object catch (error) {
          stageProgress.conclude();
          _stageOperationFailed('${target.label} stage preparation', error);
          return false;
        }
        notices.addAll(result.notices);
        if (result case TargetStageFailure(:final diagnostic, :final unit)) {
          stageProgress.conclude();
          for (final notice in notices) {
            output.say(notice, depth: 1);
          }
          output.problem(diagnostic, unit: unit);
          output.halt(HaltKind.beforeActing);
          return false;
        }
        final step = (result as TargetStageSuccess).step;
        progress.add(step);
        try {
          _persistStageProgress(stage, sourceArtifacts, progress);
          stageProgress.record(step);
        } on Object catch (error) {
          stageProgress.conclude();
          _stageProgressFailed(error);
          return false;
        }
      }
      return true;
    }

    if (!await prepareTargets(StageContributionPhase.beforeArtifacts)) {
      return null;
    }

    final producerSteps = checklist.steps.where((step) {
      return !step.isPublic &&
          step.kind != StepKind.prerequisite &&
          step.kind != StepKind.completeStage;
    }).toList();
    stageProgress.restore(progress);

    final lanes = <String, List<Step>>{};
    for (final step in producerSteps) {
      lanes
          .putIfAbsent('${step.project}/${step.platform!}', () => [])
          .add(step);
    }
    assert(
      () {
        final producerIds = {for (final step in producerSteps) step.id};
        for (final lane in lanes.values) {
          final earlier = <String>{};
          for (final step in lane) {
            for (final need in step.needs) {
              if (producerIds.contains(need) && !earlier.contains(need)) {
                return false;
              }
            }
            earlier.add(step.id);
          }
        }
        return true;
      }(),
      'a producer depends on a step outside or later in its lane',
    );

    final failures = <HaltKind>[];

    Future<void> runLane(String laneName, List<Step> lane) async {
      final laneSource = ProducerLaneSource(
        stage: stage.directory,
        lane: laneName,
      );
      try {
        laneSource.materialize(sourceArtifacts);
        final chain = _chain(unit, repositoryRoot: laneSource.path);
        for (final step in lane) {
          if (failures.isNotEmpty) return;
          try {
            if (_producerRecorded(progress, step)) {
              output.step(
                step,
                verdict: Verdict.exact,
                detail: 'validated in the interrupted stage',
                show: false,
              );
              continue;
            }
            output.report.acted = true;
            final receiptName = receiptNameFor(step);
            stageProgress.begin(receiptName, _producerActivity(step));
            final LocalProducerOutcome act;
            try {
              act = await _actProducer(
                step,
                unit,
                signing,
                chain: chain,
                progress: stageProgress.handleFor(receiptName),
              );
            } on Object catch (error) {
              stageProgress.fail(receiptName);
              _stageOperationProblem(step.summary, error);
              failures.add(HaltKind.stoppedPartway);
              return;
            }
            if (!act.ok) {
              stageProgress.fail(receiptName);
              failures.add(act.halt ?? HaltKind.stoppedPartway);
              return;
            }
            try {
              final recorded = _captureProducerStep(
                stage,
                unit,
                step,
                sourceStep,
                progress,
                act,
              );
              progress.add(recorded);
              try {
                _persistStageProgress(stage, sourceArtifacts, progress);
              } on Object {
                progress.remove(recorded);
                rethrow;
              }
              stageProgress.record(recorded);
            } on Object catch (error) {
              stageProgress.fail(receiptName);
              _stageProgressProblem(error);
              failures.add(HaltKind.beforeActing);
              return;
            }
          } on Object catch (error) {
            _stageOperationProblem('the ${unit.name} stage', error);
            failures.add(HaltKind.stoppedPartway);
            return;
          }
        }
      } on Object catch (error) {
        _stageOperationProblem('the ${unit.name} stage', error);
        failures.add(HaltKind.stoppedPartway);
      } finally {
        try {
          laneSource.close();
        } on Object catch (error) {
          _stageOperationProblem(
            'the ${unit.name} producer lane cleanup',
            error,
          );
          failures.add(HaltKind.stoppedPartway);
        }
      }
    }

    await Future.wait([
      for (final entry in lanes.entries) runLane(entry.key, entry.value),
    ]);
    if (failures.isNotEmpty) {
      stageProgress.concludeStopped();
      if (!output.report.halted) {
        output.halt(failures
            .reduce((left, right) => left.index >= right.index ? left : right));
      }
      return null;
    }

    if (!await prepareTargets(StageContributionPhase.afterArtifacts)) {
      return null;
    }

    stageProgress.begin(
      'complete-stage',
      ProgressActivity(running: 'assembling', failed: 'assembly failed'),
    );
    try {
      stage.finalize(
        releaseAssets: ReleaseAssets.bundleFor(unit),
        evidence: {
          'requested_mode': stageOnly ? 'stage' : 'one-shot',
          if (stage.directory.identity.isGitBound)
            'source_commit': stage.directory.identity.headCommit,
          if (stage.directory.identity.isGitBound)
            'source_tree': stage.directory.identity.headTree,
          if (!stage.directory.identity.isGitBound) 'source_binding': 'unbound',
        },
      );
    } on Object catch (error) {
      stageProgress.conclude();
      output.problem(Diagnostic(
        code: 'RK-STAGE-003',
        message: 'the release stage could not be completed',
        remedy: '$error',
      ));
      output.halt(HaltKind.beforeActing);
      return null;
    }

    output.step(
      checklist.steps.singleWhere(
        (step) => step.kind == StepKind.completeStage,
      ),
      verdict: Verdict.exact,
      detail: 'staged and validated',
      show: false,
    );
    final completed = stage.inspect().receipt!.steps;
    stageProgress
      ..restore(completed)
      ..settle(title: '${unit.name} ${unit.version} · staged');
    for (final notice in notices) {
      output.say(notice, depth: 1);
    }
    return PreparedRelease(
      claims: claims,
      signing: signing,
    );
  }

  /// Confirms that the public identity used to sign the reviewed stage has
  /// not changed while staging and remote reads were in flight.
  Future<bool> signingStillValid(
    ResolvedUnit unit,
    PreparedRelease prepared,
  ) async {
    final project = _macosProject(unit);
    if (project == null) return true;
    final refreshed = await _signingBaseline(unit, project);
    if (!refreshed.ok) return false;
    if (prepared.signing != null &&
        refreshed.requirement == prepared.signing!.publishedRequirement) {
      return true;
    }
    output.problem(Diagnostic(
      code: 'RK-SIGN-013',
      message: 'the published signing identity changed after staging',
      remedy: 'The reviewed signature was built against a different public '
          'baseline. Rebuild it explicitly: rk release ${unit.name} --stage.',
    ));
    output.halt(HaltKind.beforeActing);
    return false;
  }

  StageStep _sourceStageStep(
    ReleaseStage stage,
    List<StageArtifact> sourceArtifacts,
  ) =>
      StageStep(
        name: 'source-snapshot',
        inputs: [
          if (stage.directory.identity.isGitBound)
            StageInput.commit(stage.directory.identity),
          if (stage.directory.identity.isGitBound)
            StageInput.tree(stage.directory.identity),
          StageInput.plan(stage.directory.identity),
        ],
        outputs: sourceArtifacts,
        evidence: stage.directory.identity.isGitBound
            ? {
                'commit': stage.directory.identity.headCommit,
                'tree': stage.directory.identity.headTree,
              }
            : const {'source_binding': 'unbound'},
      );

  void _persistStageProgress(
    ReleaseStage stage,
    List<StageArtifact> sourceArtifacts,
    List<StageStep> steps,
  ) {
    stage.sealSource(sourceArtifacts);
    stage.writeProgress(steps);
  }

  void _stageProgressProblem(Object error) {
    output.problem(Diagnostic(
      code: 'RK-STAGE-003',
      message: 'the completed producer could not be recorded safely',
      remedy: '$error',
    ));
  }

  void _stageProgressFailed(Object error) {
    _stageProgressProblem(error);
    output.halt(HaltKind.beforeActing);
  }

  void _stageOperationProblem(String operation, Object error) {
    output.problem(Diagnostic(
      code: 'RK-STAGE-003',
      message: '$operation failed while preparing the release stage',
      remedy: '$error\nfix the local failure, then re-run; no public target '
          'was changed',
    ));
  }

  void _stageOperationFailed(String operation, Object error) {
    _stageOperationProblem(operation, error);
    if (!output.report.halted) output.halt(HaltKind.stoppedPartway);
  }

  bool _producerRecorded(List<StageStep> progress, Step step) =>
      progress.any((record) => record.name == receiptNameFor(step));

  StageStep _captureProducerStep(
    ReleaseStage stage,
    ResolvedUnit unit,
    Step step,
    StageStep sourceStep,
    List<StageStep> progress,
    LocalProducerOutcome outcome,
  ) {
    final contract = contractFor(unit, step);
    final recorded = {
      for (final record in progress)
        for (final artifact in record.outputs) artifact.path: artifact,
    };
    return StageStep(
      name: contract.name,
      inputs: [
        for (final input in contract.inputs)
          input == 'step:source-snapshot'
              ? StageInput.step(sourceStep)
              : StageInput.artifact(recorded[input] ??
                  (throw StateError(
                      '${contract.name} input $input is not recorded'))),
      ],
      outputs: [
        for (final artifact in outcome.outputs)
          StageArtifact.capture(
            stage: stage.directory,
            path: artifact.path,
            type: artifact.type,
          ),
      ],
      evidence: outcome.evidence,
    );
  }

  /// Resolves unit-scoped claims and signing identity before producers run.
  Future<_StageInputs?> _prepareStageInputs(
    ResolvedUnit unit,
    StageInspection inspected,
  ) async {
    final live = output.progressBoard(
      '${unit.name} ${unit.version} · preparing stage',
      delay: _briefPhase,
      emitSlowToNonTerminal: true,
    );
    final row = live.addRow(
      id: '${unit.name}/release-inputs',
      label: 'Release inputs',
      coordinate: 'signing identity',
    );
    row.handle.begin(CommonProgressActivities.checking);
    ReleaseSigningContext? signing;
    if (!inspected.reusable) {
      final macosProject = _macosProject(unit);
      if (macosProject != null) {
        row.handle.begin(ProgressActivity(
          running: 'checking signing',
          failed: 'signing check failed',
        ));
      }
      final baseline = await _signingBaseline(unit, macosProject);
      if (!baseline.ok) {
        live.conclude();
        return null;
      }
      if (macosProject != null) {
        final publishedRequirement = baseline.requirement;
        final keychain = await _signingCertificate(unit, publishedRequirement);
        if (!keychain.ok) {
          live.conclude();
          return null;
        }
        final codeId = publishedRequirement == null
            ? macosProject.executable
            : BinaryChain.identifierOf(publishedRequirement);
        if (codeId == null || codeId.isEmpty) {
          live.conclude();
          output.problem(Diagnostic(
            code: 'RK-SIGN-009',
            message: 'no release states what this program is called',
            remedy: 'declare one executable in the native project manifest',
          ));
          output.halt(HaltKind.beforeActing);
          return null;
        }
        signing = ReleaseSigningContext(
          publishedRequirement: publishedRequirement,
          firstIdentity: publishedRequirement == null,
          certificateName: keychain.identity!.name,
          codeId: codeId,
          identity: keychain.identity,
          certificateSha256: keychain.certificateSha256,
        );
      }
    }

    row.complete(note: 'checked');
    live.discard();
    return _StageInputs(signing: signing);
  }

  Future<
      ({
        bool ok,
        SigningIdentity? identity,
        String? certificateSha256,
      })> _signingCertificate(
    ResolvedUnit unit,
    String? publishedRequirement,
  ) async {
    final signer = MacOsSigner(tools: tools);
    final certificates = await signer.availableIdentities();
    Diagnostic? refusal;

    if (certificates == null) {
      refusal = Diagnostic(
        code: 'RK-SIGN-006',
        message: 'the login keychain could not be read',
        remedy: 'signing needs `security find-identity -v -p codesigning` to '
            'answer. This is not the same as having no certificate, and rk '
            'will not guess which it is.',
      );
    } else if (certificates.isEmpty) {
      refusal = Diagnostic(
        code: 'RK-SIGN-007',
        message: 'no Developer ID Application certificate is installed',
        remedy: 'a signed release needs one in the login keychain — it is '
            'the only certificate that distributes outside the App Store.',
      );
    } else if (publishedRequirement != null &&
        BinaryChain.teamOf(publishedRequirement) == null) {
      // The sign step also refuses this as RK-SIGN-001. The requirement is in
      // hand here, so the question "can rk tell which certificate reproduces
      // this?" is answerable before stage work begins and does not change by
      // waiting.
      refusal = Diagnostic(
        code: 'RK-SIGN-001',
        message: 'the published release names no team rk can read',
        remedy: 'its designated requirement carries no subject.OU, so rk '
            'cannot tell which certificate reproduces it.',
      );
    } else if (publishedRequirement != null &&
        BinaryChain.teamOf(publishedRequirement) != null &&
        certificates
            .where((c) => c.team == BinaryChain.teamOf(publishedRequirement))
            .isEmpty) {
      // The likeliest signing failure of all — a machine that has a
      // certificate, just not the one the published release names — and the
      // last one this preflight learned to catch. `MacOsSigner.sign` also
      // refuses it, but checking here avoids spending time producing a stage
      // whose signing identity can never match the published baseline.
      refusal = Diagnostic(
        code: 'RK-SIGN-010',
        message: 'no certificate for the team the published release names',
        remedy: 'users installed a binary signed by team '
            '${BinaryChain.teamOf(publishedRequirement)}; this machine has '
            '${certificates.map((c) => c.team).join(', ')}. Signing with a '
            'different team ships what macOS treats as a new program.',
      );
    } else if (publishedRequirement != null &&
        certificates
                .where(
                    (c) => c.team == BinaryChain.teamOf(publishedRequirement))
                .length >
            1) {
      refusal = Diagnostic(
        code: 'RK-SIGN-011',
        message: 'several certificates for team '
            '${BinaryChain.teamOf(publishedRequirement)}, and rk will not '
            'guess which one distributes this',
        remedy: 'leave one Developer ID Application certificate for that '
            'team in the login keychain.',
      );
    } else if (publishedRequirement == null && certificates.length > 1) {
      // With a published requirement the team is derived from it and the
      // sign step picks by that, so several certificates are fine. Without
      // one, nothing says which of them distributes this — and the first
      // signing is what makes the answer permanent.
      refusal = Diagnostic(
        code: 'RK-SIGN-008',
        message: 'this machine has ${certificates.length} Developer ID '
            'certificates and nothing published says which distributes this',
        remedy: 'release once from a machine with one '
            '(${certificates.map((c) => c.team).join(', ')}), and every '
            'release after derives it from what users installed.',
      );
    }

    if (refusal != null) {
      output.problem(refusal, unit: unit.name);
      output.halt(HaltKind.beforeActing);
      return (
        ok: false,
        identity: null,
        certificateSha256: null,
      );
    }
    final selected = publishedRequirement == null
        ? certificates!.single
        : certificates!.singleWhere(
            (certificate) =>
                certificate.team == BinaryChain.teamOf(publishedRequirement),
          );
    final fingerprint = await signer.certificateSha256(selected);
    if (fingerprint == null) {
      output.problem(
        Diagnostic(
          code: 'RK-SIGN-012',
          message: 'the selected signing certificate fingerprint could not '
              'be read',
          remedy: '`security find-certificate -a -c '
              '"${selected.name}" -Z` must report the SHA-256 and SHA-1 '
              'hashes for the exact identity selected by '
              '`security find-identity`.',
        ),
        unit: unit.name,
      );
      output.halt(HaltKind.beforeActing);
      return (
        ok: false,
        identity: null,
        certificateSha256: null,
      );
    }
    return (
      ok: true,
      identity: selected,
      certificateSha256: fingerprint,
    );
  }

  /// The designated requirement of the newest already-published release,
  /// which is what this release's signature must reproduce.
  ///
  /// Derived, not declared: the complete public release history is searched
  /// newest-to-oldest for the latest release that actually shipped a macOS
  /// binary. That binary is the only authority on what identity this program
  /// has. `none` — no earlier signed release — is a null requirement with
  /// `ok`, and the sign step uses the native executable name.
  /// `unreadable` refuses the whole run before anything public acts. Not
  /// knowing the baseline is not permission to ship a new one.
  Future<({bool ok, String? requirement})> _signingBaseline(
    ResolvedUnit unit,
    ResolvedProject? project,
  ) async {
    if (project == null ||
        !unit.publish.contains(PublishTarget.githubRelease) ||
        unit.tagPattern == null) {
      return (ok: true, requirement: null);
    }
    final repository = initialGit.originUrl;
    if (repository == null) return (ok: true, requirement: null);

    final published = PublishedIdentity(
      tools: tools,
      repository: repository,
      workingDirectory: initialGit.root,
    );
    final history = await published.priorReleaseTags(
      tagPattern: unit.tagPattern!,
      before: unit.version,
    );
    if (!history.readable) {
      output.problem(
        Diagnostic(
          code: 'RK-SIGN-004',
          message: 'the identity users already installed could not be read',
          remedy: '${history.why}\n'
              'rk must read the complete public release history before it '
              'can decide this is the first signed release.',
        ),
        unit: unit.name,
      );
      output.halt(HaltKind.beforeActing);
      return (ok: false, requirement: null);
    }

    for (final tag in history.tags!) {
      final scratch = Directory.systemTemp.createTempSync('rk-identity-');
      final reading = await published.read(
        tag: tag,
        executable: project.executable!,
        into: '${scratch.path}/published-identity',
        expectedPublished: true,
      );
      try {
        scratch.deleteSync(recursive: true);
      } on FileSystemException {
        // The published identity answer does not depend on scratch cleanup.
      }
      switch (reading.answer) {
        case IdentityAnswer.found:
          return (ok: true, requirement: reading.requirement);
        case IdentityAnswer.none:
          // A release without this unit's macOS binary is not its signing
          // baseline. Continue to the next older release.
          continue;
        case IdentityAnswer.unreadable:
          output.problem(
            Diagnostic(
              code: 'RK-SIGN-004',
              message: 'the identity users already installed could not be '
                  'read',
              remedy: '${reading.why}\n'
                  'rk found a published signing candidate at $tag; until '
                  'that release can be read, a new signature cannot be '
                  'proven continuous with it.',
            ),
            unit: unit.name,
          );
          output.halt(HaltKind.beforeActing);
          return (ok: false, requirement: null);
      }
    }
    return (ok: true, requirement: null);
  }

  /// The unit's binary project when it ships a macOS build.
  ResolvedProject? _macosProject(ResolvedUnit unit) {
    final project = unit.binaryProject;
    return project != null &&
            project.binaryPlatforms
                .any((platform) => platform.startsWith('macos-'))
        ? project
        : null;
  }

  Future<LocalProducerOutcome> _actProducer(
    Step step,
    ResolvedUnit unit,
    ReleaseSigningContext? signing, {
    required BinaryChain chain,
    ProgressHandle? progress,
  }) async {
    final project = unit.project(step.project!);
    switch (step.kind) {
      case StepKind.build:
        return chain.buildStep(
          step,
          project,
          progress: progress,
          signing: step.platform!.startsWith('macos-')
              ? MacSigning(
                  publishedRequirement: signing!.publishedRequirement,
                  codeId: signing.codeId,
                  identity: signing.identity,
                  certificateSha256: signing.certificateSha256,
                )
              : null,
        );
      case StepKind.notarize:
        return chain.notarizeStep(step, project);
      case StepKind.archive:
        return chain.archiveStep(step, project);
      default:
        throw StateError(
          'step ${step.kind.name} is not a local stage producer',
        );
    }
  }

  BinaryChain _chain(
    ResolvedUnit unit, {
    required String repositoryRoot,
  }) {
    final stage = stageFor(unit);
    return BinaryChain(
      tools: tools,
      output: output,
      workspace: stage.directory.workspace,
      repositoryRoot: repositoryRoot,
      capabilities: capabilities,
      compilerExecutable: stage.compiler?.executable ?? 'dart',
    );
  }

  ProgressActivity _producerActivity(Step step) => switch (step.kind) {
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
        _ => throw StateError('${step.kind.name} is not a stage producer'),
      };
}

class _StageInputs {
  const _StageInputs({required this.signing});

  final ReleaseSigningContext? signing;
}
