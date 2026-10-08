import 'dart:io';

import '../asset_build.dart';
import '../binary_chain.dart';
import '../builds/capability.dart';
import '../engine/assets.dart';
import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/dependency_graph.dart';
import '../engine/git.dart';
import '../engine/identity.dart';
import '../engine/producer_lane.dart';
import '../engine/producers.dart';
import '../engine/publish_target.dart';
import '../engine/release_stage.dart';
import '../engine/resolve.dart';
import '../engine/stage_board.dart';
import '../engine/stage_inspection.dart';
import '../engine/stage_receipt.dart';
import '../engine/stage_source.dart';
import '../engine/targets.dart';
import '../engine/tools.dart';
import '../engine/verdict.dart';
import '../output/output.dart';
import '../output/progress.dart';
import '../targets/target_module.dart';
import '../transforms/macos.dart';
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
    required this.stageFor,
    required this.stageOnly,
  });

  final GitState initialGit;
  final Output output;
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
        inspected.claimsCompletion ||
        inspected.issues.any(
          (issue) => issue.kind == StageIssueKind.invalidReceipt,
        );
    if (completedOrCorrupt && !mayReplaceReviewed) {
      final reviewed = inspected.claimsCompletion;
      return Diagnostic(
        code: 'RK-STAGE-002',
        message: reviewed
            ? 'the reviewed release stage no longer validates'
            : 'the release stage receipt is invalid',
        remedy:
            '${inspected.issues.join('\n')}\n'
            '${reviewed ? 'rk will not silently replace reviewed bytes. ' : ''}'
            'Rebuild it explicitly: rk stage ${unit.name}',
      );
    }
    return null;
  }

  /// Settles what staging [unit] needs before its producers run: leftovers
  /// of an interrupted run are cleared, and its signing identity is chosen.
  /// Units do this one at a time, since choosing an identity may ask the
  /// operator. [fromSource] names, for each Pub package, the repository
  /// packages it takes from this source: see [TargetStageContext.fromSource].
  Future<UnitStaging?> begin({
    required ResolvedUnit unit,
    required Checklist checklist,
    required List<TargetPlan> targets,
    required List<TargetStage> targetStages,
    required ReleaseStage stage,
    required StageInspection inspected,
    required List<TargetClaim> claims,
    Map<String, Map<String, String>> fromSource = const {},
  }) async {
    final staging = UnitStaging._(
      unit: unit,
      checklist: checklist,
      targets: targets,
      targetStages: targetStages,
      stage: stage,
      inspected: inspected,
      claims: claims,
      fromSource: fromSource,
    );
    _discardUnrecordedOutputs(
      stage,
      inspected,
      staging.outputsByProducer.values.expand((outputs) => outputs).toSet(),
    );
    final signing = await _prepareStageInputs(unit, inspected);
    if (signing == null) return null;
    return staging.._signing = signing.value;
  }

  /// Produces or reuses the exact receipt-backed private stage [staging]
  /// describes. Its rows go on [shared] when units stage side by side, and
  /// on a board of its own otherwise.
  Future<PreparedRelease?> complete(
    UnitStaging staging, {
    StageReleaseProgress? shared,
  }) async {
    final UnitStaging(
      :unit,
      :checklist,
      :targets,
      :targetStages,
      :stage,
      :inspected,
      :claims,
      :fromSource,
      :signing,
      :producerSteps,
      :targetStagesByName,
      :outputsByProducer,
    ) = staging;
    final stageProgress =
        shared ??
        StageReleaseProgress(
          output,
          title: '${unit.name} ${unit.version} · staging',
          board: staging.board,
        );
    final warnings = <_StageWarning>[];
    if (inspected.reusable) {
      stageProgress
        ..restore(inspected.receipt!.steps)
        ..settle(title: '${unit.name} ${unit.version} · staged');
      _showStageWarnings(
        unit,
        _recordedStageWarnings(inspected.receipt!.steps, targetStagesByName),
      );
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
              message:
                  'the completed stage records conflicting signing '
                  'identities',
              remedy:
                  'rebuild it explicitly: '
                  'rk stage ${unit.name}',
            ),
            unit: unit.name,
          );
          output.halt(HaltKind.beforeActing);
          return null;
        }
        recoveredSigning = recovered;
      }
      return PreparedRelease(claims: claims, signing: recoveredSigning);
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

    if (inspected.validProgress || inspected.planRecorded) {
      output.say('Resuming interrupted staging.', role: VisualRole.secondary);
    } else if (!stage.directory.identity.isGitBound) {
      output.say(
        'Staging a temporary source snapshot; each run starts a new stage.',
        role: VisualRole.secondary,
      );
      stage.discardEarlierUnboundStages();
    } else if (inspected.claimsCompletion) {
      output.say(
        'Rebuilding: the recorded stage no longer verifies.',
        role: VisualRole.secondary,
      );
    }

    final progress = <StageStep>[];
    if (inspected.validProgress) {
      progress.addAll(inspected.receipt!.steps);
    } else if (!inspected.planRecorded) {
      try {
        stage.reset();
        stage.writeProgress(const []);
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

    stageProgress.restore(progress);
    final producersByName = {
      for (final step in producerSteps) receiptNameFor(step): step,
    };
    final runnable = {...producersByName.keys, ...targetStagesByName.keys};
    final graph = DependencyGraph<String>(
      stage.producerNames,
      idOf: (producer) => producer,
      dependenciesOf: stage.producerDependencies,
    );
    final completed = {for (final step in progress) step.name};

    // Producers build from the commit the stage names, read once into
    // memory when anything remains to produce; each exports it into a
    // directory of its own.
    late final StageSourceSnapshot source;
    if (runnable.difference(completed).isNotEmpty) {
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

    void record(StageStep recorded) {
      progress.add(recorded);
      try {
        stage.writeProgress(progress);
        stageProgress.record(recorded);
      } on Object {
        progress.remove(recorded);
        rethrow;
      }
    }

    Future<_StageWorkCompletion> runTargetStage(
      String receiptName,
      TargetStage targetStage,
    ) async {
      final target = targetStage.target;
      try {
        final result = await targetStage.prepare(
          TargetStageContext(
            contract: stage.producerContract(receiptName),
            tools: tools,
            git: initialGit,
            attach: output.report.attach,
            stage: stage,
            source: source,
            priorSteps: List<StageStep>.unmodifiable(progress),
            progress: stageProgress.handlesFor(targetStage),
            fromSource: fromSource[target.project?.name] ?? const {},
          ),
        );
        warnings.addAll([
          for (final warning in result.warnings)
            _StageWarning(warning, target: target.step.id),
        ]);
        if (result case TargetStageFailure(:final diagnostic, :final unit)) {
          _discardInterruptedOutputs(stage, outputsByProducer[receiptName]!);
          stageProgress.fail(receiptName);
          output.problem(diagnostic, unit: unit);
          return _StageWorkCompletion.failed(
            receiptName,
            HaltKind.beforeActing,
          );
        }
        try {
          record((result as TargetStageSuccess).step);
          return _StageWorkCompletion.succeeded(receiptName);
        } on Object catch (error) {
          stageProgress.fail(receiptName);
          _stageProgressProblem(error);
          return _StageWorkCompletion.failed(
            receiptName,
            HaltKind.beforeActing,
          );
        }
      } on Object catch (error) {
        _discardInterruptedOutputs(stage, outputsByProducer[receiptName]!);
        stageProgress.fail(receiptName);
        _stageOperationProblem('${target.label} stage preparation', error);
        return _StageWorkCompletion.failed(
          receiptName,
          HaltKind.stoppedPartway,
        );
      }
    }

    Future<_StageWorkCompletion> runProducer(
      String receiptName,
      Step step,
    ) async {
      // A project's own build has no platform; it is one lane of its own.
      final laneName = step.platform == null
          ? '${step.project}/build'
          : '${step.project}/${step.platform!}';
      try {
        final laneSource = laneSources.putIfAbsent(
          laneName,
          () => ProducerLaneSource.export(source),
        );
        final chain = laneChains.putIfAbsent(
          laneName,
          () => _chain(unit, repositoryRoot: laneSource.path),
        );
        output.report.acted = true;
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
          _discardInterruptedOutputs(stage, outputsByProducer[receiptName]!);
          stageProgress.fail(receiptName);
          _stageOperationProblem(step.summary, error);
          return _StageWorkCompletion.failed(
            receiptName,
            HaltKind.stoppedPartway,
          );
        }
        if (!act.ok) {
          _discardInterruptedOutputs(stage, outputsByProducer[receiptName]!);
          stageProgress.fail(receiptName);
          return _StageWorkCompletion.failed(
            receiptName,
            act.halt ?? HaltKind.stoppedPartway,
          );
        }
        try {
          record(_captureProducerStep(stage, step, act));
          return _StageWorkCompletion.succeeded(receiptName);
        } on Object catch (error) {
          stageProgress.fail(receiptName);
          _stageProgressProblem(error);
          return _StageWorkCompletion.failed(
            receiptName,
            HaltKind.beforeActing,
          );
        }
      } on Object catch (error) {
        _discardInterruptedOutputs(stage, outputsByProducer[receiptName]!);
        stageProgress.fail(receiptName);
        _stageOperationProblem('the ${unit.name} stage', error);
        return _StageWorkCompletion.failed(
          receiptName,
          HaltKind.stoppedPartway,
        );
      }
    }

    Future<_StageWorkCompletion> runWork(String name) {
      final targetStage = targetStagesByName[name];
      if (targetStage != null) return runTargetStage(name, targetStage);
      final producer = producersByName[name];
      if (producer != null) return runProducer(name, producer);
      throw StateError('the stage graph has no executor for "$name"');
    }

    final active = <String, Future<_StageWorkCompletion>>{};
    while (completed.intersection(runnable).length < runnable.length ||
        active.isNotEmpty) {
      if (failures.isEmpty) {
        final ready = graph
            .ready(completed: completed, active: active.keys.toSet())
            .where(runnable.contains)
            .toList();
        for (final name in ready) {
          active[name] = runWork(name);
        }
        if (active.isEmpty && ready.isEmpty) {
          _stageOperationProblem(
            'the ${unit.name} stage dependency graph',
            StateError('no producer is ready'),
          );
          failures.add(HaltKind.beforeActing);
          break;
        }
      }
      if (active.isEmpty) break;
      final result = await Future.any(active.values);
      active.remove(result.producer);
      if (result.halt case final halt?) {
        failures.add(halt);
      } else {
        completed.add(result.producer);
      }
    }

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
      checklist.steps.singleWhere(
        (step) => step.kind == StepKind.completeStage,
      ),
      verdict: Verdict.exact,
      detail: 'staged and validated',
      show: false,
    );
    final completedReceipt = stage.inspect().receipt!.steps;
    stageProgress
      ..restore(completedReceipt)
      ..settle(title: '${unit.name} ${unit.version} · staged');
    _showStageWarnings(unit, warnings);
    return PreparedRelease(claims: claims, signing: signing);
  }

  /// Removes what an interrupted run's producers wrote but never recorded,
  /// so they run again from a clean slate. Recorded outputs are kept.
  void _discardUnrecordedOutputs(
    ReleaseStage stage,
    StageInspection inspected,
    Set<String> declaredOutputs,
  ) {
    if (!inspected.validProgress && !inspected.planRecorded) return;
    try {
      stage.discardUnrecordedOutputs(declaredOutputs);
    } on Object {
      // The producer that needs the path reports what it finds there.
    }
  }

  void _discardInterruptedOutputs(
    ReleaseStage stage,
    Set<String> declaredOutputs,
  ) {
    try {
      final inspected = stage.inspect();
      if (inspected.receipt?.complete == false) {
        stage.discardUnrecordedOutputs(declaredOutputs);
      }
    } on Object {
      // The original producer failure remains the useful diagnosis. A later
      // run will inspect the leftover and either recover it or replace the
      // incomplete stage; cleanup cannot make publication less safe.
    }
  }

  List<_StageWarning> _recordedStageWarnings(
    Iterable<StageStep> steps,
    Map<String, TargetStage> targetStages,
  ) {
    final warnings = <_StageWarning>[];
    for (final step in steps) {
      for (final warning in recordedTargetStageWarnings(step)) {
        warnings.add(
          _StageWarning(
            warning,
            target: targetStages[step.name]?.target.step.id,
          ),
        );
      }
    }
    return warnings;
  }

  void _showStageWarnings(ResolvedUnit unit, Iterable<_StageWarning> found) {
    final seen = <String>{};
    final warnings = [
      for (final warning in found)
        if (seen.add(
          '${warning.diagnostic.code}\u0000'
          '${warning.diagnostic.message}',
        ))
          warning,
    ];
    if (warnings.isEmpty) return;
    output.blank();
    output.heading('Warnings');
    for (final warning in warnings) {
      output.warning(
        warning.diagnostic,
        unit: unit.name,
        target: warning.target,
        depth: 1,
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

  void _stageOperationProblem(String operation, Object error) {
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
  }

  StageStep _captureProducerStep(
    ReleaseStage stage,
    Step step,
    LocalProducerOutcome outcome,
  ) {
    final contract = stage.producerContract(receiptNameFor(step));
    return StageStep(
      name: contract.name,
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
  Future<({ReleaseSigningContext? value})?> _prepareStageInputs(
    ResolvedUnit unit,
    StageInspection inspected,
  ) async {
    final live = output.progressBoard(
      '${unit.name} ${unit.version} · preparing stage',
      delay: briefPhase,
      emitSlowToNonTerminal: true,
    );
    final row = live.addRow(
      id: '${unit.name}/release-inputs',
      label: 'Release inputs',
      coordinate: _macosProject(unit) == null
          ? 'source and producer inputs'
          : 'notarization and signing identity',
    );
    row.handle.begin(CommonProgressActivities.checking);
    ReleaseSigningContext? signing;
    if (!inspected.reusable) {
      final macosProject = _macosProject(unit);
      if (macosProject != null) {
        row.handle.begin(
          ProgressActivity(
            running: 'checking notarization',
            failed: 'notarization check failed',
          ),
        );
        final notary = await MacOsNotarizer(tools: tools).preflight();
        if (!notary.ok) {
          live.conclude();
          output.problem(
            Diagnostic(
              code: 'RK-NOTARY-004',
              message: 'the rk-notary credential is not ready',
              remedy: notary.remedy ?? notary.problem,
              evidence: notary.transcript,
            ),
            unit: unit.name,
          );
          output.halt(HaltKind.beforeActing);
          return null;
        }
        row.handle.begin(
          ProgressActivity(
            running: 'checking signing',
            failed: 'signing check failed',
          ),
        );
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
          output.problem(
            Diagnostic(
              code: 'RK-SIGN-009',
              message: 'no release states what this program is called',
              remedy: 'declare one executable in the native project manifest',
            ),
          );
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
    return (value: signing);
  }

  Future<({bool ok, SigningIdentity? identity, String? certificateSha256})>
  _signingCertificate(ResolvedUnit unit, String? publishedRequirement) async {
    final signer = MacOsSigner(tools: tools);
    final certificates = await signer.availableIdentities();
    Diagnostic? refusal;

    if (certificates == null) {
      refusal = Diagnostic(
        code: 'RK-SIGN-006',
        message: 'the login keychain could not be read',
        remedy:
            'signing needs `security find-identity -v -p codesigning` to '
            'answer. This is not the same as having no certificate, and rk '
            'will not guess which it is.',
      );
    } else if (certificates.isEmpty) {
      refusal = Diagnostic(
        code: 'RK-SIGN-007',
        message: 'no Developer ID Application certificate is installed',
        remedy:
            'a signed release needs one in the login keychain — it is '
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
        remedy:
            'its designated requirement carries no subject.OU, so rk '
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
        remedy:
            'users installed a binary signed by team '
            '${BinaryChain.teamOf(publishedRequirement)}; this machine has '
            '${certificates.map((c) => c.team).join(', ')}. Signing with a '
            'different team ships what macOS treats as a new program.',
      );
    } else if (publishedRequirement != null &&
        certificates
                .where(
                  (c) => c.team == BinaryChain.teamOf(publishedRequirement),
                )
                .length >
            1) {
      refusal = Diagnostic(
        code: 'RK-SIGN-011',
        message:
            'several certificates for team '
            '${BinaryChain.teamOf(publishedRequirement)}, and rk will not '
            'guess which one distributes this',
        remedy:
            'leave one Developer ID Application certificate for that '
            'team in the login keychain.',
      );
    } else if (publishedRequirement == null && certificates.length > 1) {
      // With a published requirement the team is derived from it and the
      // sign step picks by that, so several certificates are fine. Without
      // one, nothing says which of them distributes this — and the first
      // signing is what makes the answer permanent.
      refusal = Diagnostic(
        code: 'RK-SIGN-008',
        message:
            'this machine has ${certificates.length} Developer ID '
            'certificates and nothing published says which distributes this',
        remedy:
            'release once from a machine with one '
            '(${certificates.map((c) => c.team).join(', ')}), and every '
            'release after derives it from what users installed.',
      );
    }

    if (refusal != null) {
      output.problem(refusal, unit: unit.name);
      output.halt(HaltKind.beforeActing);
      return (ok: false, identity: null, certificateSha256: null);
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
          message:
              'the selected signing certificate fingerprint could not '
              'be read',
          remedy:
              '`security find-certificate -a -c '
              '"${selected.name}" -Z` must report the SHA-256 and SHA-1 '
              'hashes for the exact identity selected by '
              '`security find-identity`.',
        ),
        unit: unit.name,
      );
      output.halt(HaltKind.beforeActing);
      return (ok: false, identity: null, certificateSha256: null);
    }
    return (ok: true, identity: selected, certificateSha256: fingerprint);
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
          remedy:
              '${history.why}\n'
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
              message:
                  'the identity users already installed could not be '
                  'read',
              remedy:
                  '${reading.why}\n'
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
            project.binaryPlatforms.any(
              (platform) => platform.startsWith('macos-'),
            )
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
      case StepKind.buildAssets:
        final stage = stageFor(unit).directory;
        return AssetBuild(
          tools: tools,
          output: output,
          workspace: stage.workspace,
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
            if (stage.identity.headCommit case final commit?)
              'RK_SOURCE_COMMIT': commit,
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

  BinaryChain _chain(ResolvedUnit unit, {required String repositoryRoot}) {
    final stage = stageFor(unit);
    return BinaryChain(
      tools: tools,
      output: output,
      workspace: stage.directory.workspace,
      repositoryRoot: repositoryRoot,
      capabilities: capabilities,
      compilerExecutable: stage.sdk.executable,
      stage: stage,
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
    required this.unit,
    required this.checklist,
    required this.targets,
    required this.targetStages,
    required this.stage,
    required this.inspected,
    required this.claims,
    required this.fromSource,
  });

  final ResolvedUnit unit;
  final Checklist checklist;
  final List<TargetPlan> targets;
  final List<TargetStage> targetStages;
  final ReleaseStage stage;
  final StageInspection inspected;
  final List<TargetClaim> claims;
  final Map<String, Map<String, String>> fromSource;

  /// The identity a macOS build signs with; null for anything else.
  ReleaseSigningContext? get signing => _signing;
  ReleaseSigningContext? _signing;

  /// The rows this unit's stage fills.
  StageBoard get board => StageBoard.forUnit(unit, targets, targetStages);

  late final List<Step> producerSteps = checklist.steps
      .where(
        (step) =>
            !step.isPublic &&
            step.kind != StepKind.prerequisite &&
            step.kind != StepKind.completeStage,
      )
      .toList();

  late final Map<String, TargetStage> targetStagesByName = {
    for (final targetStage in targetStages)
      targetStage.contract.name: targetStage,
  };

  late final Map<String, Set<String>> outputsByProducer = {
    for (final step in producerSteps)
      receiptNameFor(step): contractFor(unit, step).outputs.keys.toSet(),
    for (final entry in targetStagesByName.entries)
      entry.key: entry.value.contract.outputs.keys.toSet(),
  };
}

final class _StageWorkCompletion {
  const _StageWorkCompletion.succeeded(this.producer) : halt = null;

  const _StageWorkCompletion.failed(this.producer, this.halt);

  final String producer;
  final HaltKind? halt;
}
