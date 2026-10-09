import 'dart:io';

import '../asset_build.dart';
import '../binary_chain.dart';
import '../builds/capability.dart';
import '../engine/assets.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/identity.dart';
import '../engine/producer_lane.dart';
import '../engine/publish_target.dart';
import '../engine/release_stage.dart';
import '../engine/resolve.dart';
import '../engine/stage_inspection.dart';
import '../engine/stage_receipt.dart';
import '../engine/stage_source.dart';
import '../engine/tools.dart';
import '../engine/unit_release.dart';
import '../engine/verdict.dart';
import '../output/output.dart';
import '../output/progress.dart';
import '../targets/catalog.dart';
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
    required this.targets,
  });

  final GitState initialGit;
  final Output output;
  final Tools tools;
  final HostCapabilities capabilities;
  final ReleaseStage Function(ResolvedUnit unit) stageFor;

  /// The modules that prepare each target's work.
  final TargetCatalog targets;

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
    required UnitRelease release,
    required ReleaseStage stage,
    required StageInspection inspected,
    required List<TargetClaim> claims,
    Map<String, Map<String, String>> fromSource = const {},
  }) async {
    final unit = release.unit;
    final staging = UnitStaging._(
      release: release,
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
      :release,
      :unit,
      :stage,
      :inspected,
      :claims,
      :fromSource,
      :signing,
      :producerSteps,
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
        ..settle(title: '${unit.name} ${unit.version} · already staged');
      _showStageWarnings(
        unit,
        _recordedStageWarnings(inspected.receipt!.steps, release),
      );
      final macosBuilds = {
        for (final work in producerSteps)
          if (work.kind == StepKind.build &&
              work.platform!.startsWith('macos-'))
            work.name,
      };
      ReleaseSigningContext? recoveredSigning;
      for (final step in inspected.receipt!.steps.where(
        (step) => macosBuilds.contains(step.name),
      )) {
        final signature = step.evidence['signature']! as Map;
        final recovered = ReleaseSigningContext(
          publishedRequirement: signature['published_requirement'] as String?,
          firstIdentity: signature['first_identity']! as bool,
          certificateName: signature['certificate']! as String,
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

    if (inspected.validProgress || inspected.planRecorded) {
      output.say('Resuming interrupted staging.', role: VisualRole.secondary);
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
    final completed = {for (final step in progress) step.name};

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

    /// Runs [work], a target's input; null when it is recorded, and
    /// otherwise how the stage stopped.
    Future<HaltKind?> runTargetStage(Work work) async {
      final receiptName = work.name;
      final target = release.preparing(work)!;
      try {
        final result = await targets
            .moduleFor(target.target)
            .prepare(
              TargetStageContext(
                tools: tools,
                git: initialGit,
                attach: output.report.attach,
                stage: stage,
                source: source,
                priorSteps: List<StageStep>.unmodifiable(progress),
                progress: stageProgress.handleFor(receiptName),
                fromSource: fromSource[work.project?.name] ?? const {},
              ),
              work,
            );
        warnings.addAll([
          for (final warning in result.warnings)
            _StageWarning(warning, target: target.id),
        ]);
        if (result case TargetStageFailure(:final diagnostic, :final unit)) {
          _discardInterruptedOutputs(stage, outputsByProducer[receiptName]!);
          stageProgress.fail(receiptName);
          output.problem(diagnostic, unit: unit);
          return HaltKind.beforeActing;
        }
        try {
          record((result as TargetStageSuccess).step);
          return null;
        } on Object catch (error) {
          stageProgress.fail(receiptName);
          _stageProgressProblem(error);
          return HaltKind.beforeActing;
        }
      } on Object catch (error) {
        _discardInterruptedOutputs(stage, outputsByProducer[receiptName]!);
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
          return HaltKind.stoppedPartway;
        }
        if (!act.ok) {
          _discardInterruptedOutputs(stage, outputsByProducer[receiptName]!);
          stageProgress.fail(receiptName);
          return act.halt ?? HaltKind.stoppedPartway;
        }
        try {
          record(_captureProducerStep(stage, step, act));
          return null;
        } on Object catch (error) {
          stageProgress.fail(receiptName);
          _stageProgressProblem(error);
          return HaltKind.beforeActing;
        }
      } on Object catch (error) {
        _discardInterruptedOutputs(stage, outputsByProducer[receiptName]!);
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
      stage.finalize(releaseAssets: ReleaseAssets.bundleFor(unit));
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
    UnitRelease release,
  ) {
    final preparing = {
      for (final target in release.targets)
        if (target.preparedBy case final work?) work.name: target.id,
    };
    final warnings = <_StageWarning>[];
    for (final step in steps) {
      for (final warning in recordedTargetStageWarnings(step)) {
        warnings.add(_StageWarning(warning, target: preparing[step.name]));
      }
    }
    return warnings;
  }

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

  StageStep _captureProducerStep(
    ReleaseStage stage,
    Work step,
    LocalProducerOutcome outcome,
  ) {
    return StageStep(
      name: step.name,
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
        );
      }
    }

    row.complete(note: 'checked');
    live.discard();
    return (value: signing);
  }

  Future<({bool ok, SigningIdentity? identity})> _signingCertificate(
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
      // The requirement is in hand here, so the question "can rk tell which
      // certificate reproduces this?" is answerable before stage work begins
      // and does not change by waiting. The sign step signs with the
      // certificate chosen here.
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
      // certificate, just not the one the published release names — caught
      // before any time goes into a stage whose signing identity can never
      // match the published baseline.
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
      return (ok: false, identity: null);
    }
    final selected = publishedRequirement == null
        ? certificates!.single
        : certificates!.singleWhere(
            (certificate) =>
                certificate.team == BinaryChain.teamOf(publishedRequirement),
          );
    return (ok: true, identity: selected);
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
    Work step,
    ResolvedUnit unit,
    ReleaseSigningContext? signing, {
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
          signing: step.platform!.startsWith('macos-')
              ? MacSigning(
                  publishedRequirement: signing!.publishedRequirement,
                  codeId: signing.codeId,
                  identity: signing.identity!,
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
            'RK_SOURCE_COMMIT': stage.identity.headCommit,
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
    required this.inspected,
    required this.claims,
    required this.fromSource,
  });

  final UnitRelease release;
  ResolvedUnit get unit => release.unit;
  final ReleaseStage stage;
  final StageInspection inspected;
  final List<TargetClaim> claims;
  final Map<String, Map<String, String>> fromSource;

  /// The identity a macOS build signs with; null for anything else.
  ReleaseSigningContext? get signing => _signing;
  ReleaseSigningContext? _signing;

  /// The rows this unit's stage fills.
  List<BoardGroup> get board => release.board;

  /// The local work: builds, notarizations, archives, a project's own build.
  late final List<Work> producerSteps = [
    for (final work in release.work)
      if (work.kind != StepKind.targetStage &&
          work.kind != StepKind.completeStage)
        work,
  ];

  late final Map<String, Set<String>> outputsByProducer = {
    for (final work in release.work)
      if (work.kind != StepKind.completeStage)
        work.name: work.outputs.keys.toSet(),
  };
}
