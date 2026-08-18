import 'dart:async';
import 'dart:io';

import '../builds/capability.dart';
import '../engine/changelog.dart';
import '../engine/checklist.dart';
import '../engine/assets.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../output/output.dart';
import '../output/progress.dart';
import '../engine/inspect.dart';
import '../engine/producers.dart';
import '../engine/publish_target.dart';
import '../engine/public_release_gate.dart';
import '../engine/resolve.dart';
import '../engine/release_stage.dart';
import '../engine/source_tree.dart';
import '../engine/stage_inspection.dart';
import '../engine/stage_board.dart';
import '../engine/stage_contract.dart';
import '../engine/stage_receipt.dart';
import '../engine/targets.dart';
import '../engine/tools.dart';
import '../engine/identity.dart';
import '../engine/verdict.dart';
import '../targets/target_module.dart';
import '../transforms/macos.dart';
import '../binary_chain.dart';

/// Executes a release: inspect, act, inspect again, one step at a time — and
/// decides everything rk refuses.
///
/// The second half is easy to miss and is most of the file: the refusal
/// ladder lives here, not in the engine. An unfinishable host, a dirty
/// worktree, an unpushed HEAD, a back-version, a misplaced tag, a first
/// publish, an unreadable signing baseline, a missing changelog entry, an
/// unauthorized run — each is refused here, before anything acts.
///
/// Every step is decided from its own inspection of reality, never from what a
/// previous step left behind — which is what makes re-running the resume, and
/// what will let CI split the steps across machines later.
class ReleaseCommand {
  ReleaseCommand({
    required this.resolution,
    required this.tree,
    required this.git,
    GitState? repositoryGit,
    this.sourceWarning,
    required this.inspector,
    required this.tools,
    required this.output,
    required this.confirm,
    this.stageOnly = false,
    ReleaseStage Function(ResolvedUnit unit)? stageFor,
    ReleaseStage Function(ResolvedUnit unit, GitState git)? refreshStage,
    GitState Function()? refreshGit,
    Map<String, String> Function()? refreshEnvironment,
    Future<void> Function(Duration)? wait,
    HostCapabilities? capabilities,
  })  : repositoryGit = repositoryGit ?? git,
        _wait = wait ?? _sleep,
        _stageFor = stageFor ??
            ReleaseStages(
              source: tree,
              git: git,
              stageContracts:
                  inspector.targets.stageContractResolver(resolution),
            ).call,
        _refreshStage = refreshStage ??
            ((unit, currentGit) => ReleaseStages(
                  source: tree,
                  git: currentGit,
                  stageContracts:
                      inspector.targets.stageContractResolver(resolution),
                ).call(unit)),
        _refreshGit = refreshGit ?? (() => git),
        _refreshEnvironment = refreshEnvironment ??
            (() => Map<String, String>.of(Platform.environment)),
        _capabilities = capabilities;

  static Future<void> _sleep(Duration duration) =>
      Future<void>.delayed(duration);

  final Resolution resolution;
  final SourceTree tree;

  /// The source identity used for staging and public comparison.
  final GitState git;

  /// The surrounding repository, retained when dirty bytes are unbound.
  final GitState repositoryGit;
  final Diagnostic? sourceWarning;

  /// Reads reality for a step. The same one `status` uses, so the two verbs
  /// cannot answer the same question differently — release grew its own copy
  /// once, and it answered `absent` by default for every kind it did not name.
  final Inspector inspector;

  /// Waits, injectable so a test proves the polling without living it.
  final Future<void> Function(Duration) _wait;

  /// How long the confirming read chases a version the registry has accepted
  /// but does not list yet, and how often it asks. Bounded: an unlisted
  /// version after a minute is worth a human's eyes, not an infinite loop.
  static const confirmDeadline = Duration(seconds: 60);
  static const confirmInterval = Duration(seconds: 5);

  final Tools tools;
  final Output output;

  /// Asks the operator an ordinary yes/no question. Returns what they typed,
  /// or null when there is nobody to ask.
  final Future<String?> Function(String prompt)? confirm;

  /// What this host can produce — injectable so a drive can span platforms
  /// the test machine does not have. Null detects lazily, once.
  HostCapabilities? _capabilities;
  HostCapabilities get capabilities =>
      _capabilities ??= HostCapabilities.detect();

  /// Prepare and validate the exact private stage, then stop before release
  /// authorization or any public mutation.
  final bool stageOnly;

  final ReleaseStage Function(ResolvedUnit unit) _stageFor;
  final ReleaseStage Function(ResolvedUnit unit, GitState git) _refreshStage;
  final GitState Function() _refreshGit;
  final Map<String, String> Function() _refreshEnvironment;
  final Map<String, BinaryChain> _chains = {};
  var _sourceWarningShown = false;

  Future<int> run({String? only}) async {
    // One repository fact for the whole invocation, including ordering or
    // scope refusals that happen before the first unit pipeline starts.
    output.report.repository(
      name: tree.description.split('/').last,
      branch: repositoryGit.branch,
      uncommitted: repositoryGit.uncommitted.length,
      head: git.isBound ? git.head : null,
      remote: repositoryGit.originUrl,
      sourceBinding: git.isBound ? 'gitCommit' : 'unbound',
      sourceComparison: git.isBound ? 'exact' : 'unavailable',
    );
    if (only != null) {
      final named = resolution.units.where((u) => u.name == only).toList();
      if (named.isEmpty) {
        output.problem(
          Diagnostic(
            code: 'RK-CLI-003',
            message: 'no unit named "$only"',
            remedy: 'this repository releases: '
                '${resolution.units.map((u) => u.name).join(', ')}',
          ),
        );
        return ExitCodes.usage;
      }
      return _release(named.single);
    }

    if (stageOnly && resolution.units.length > 1) {
      output.problem(
        Diagnostic(
          code: 'RK-CLI-004',
          message: 'name the unit to stage',
          remedy: 'a dependent package may need its sibling version to be '
              'public before its native package staging can pass. Stage one '
              'unit explicitly: rk release <unit> --stage',
        ),
      );
      return ExitCodes.usage;
    }

    final dependencyProblems = Diagnostics();
    final ordered = resolution.dependencyPlan.units(dependencyProblems);
    if (dependencyProblems.isNotEmpty) {
      output.halt(HaltKind.beforeActing);
      output.problems(dependencyProblems.found);
      return ExitCodes.refused;
    }
    for (final unit in ordered) {
      // Register the full repository scope before the first unit can stop, so
      // JSON retains the same ordered plan the human preamble shows.
      output.report.unit(
        name: unit.name,
        version: unit.version.canonical,
        tag: unit.tag,
      );
    }
    if (!_validateRepositoryScope(ordered)) return ExitCodes.refused;
    if (ordered.length > 1) {
      output.heading(
          'Release order: ${ordered.map((unit) => '${unit.name} ${unit.version}').join(' -> ')}');
      output.blank();
    }
    for (final unit in ordered) {
      final result = await _release(unit);
      if (result != ExitCodes.ok) return result;
      output.previousUnitActed = output.report.acted;
    }
    return ExitCodes.ok;
  }

  /// Cheap, source-owned refusals for every unit before the first one acts.
  /// Native publish validation remains in each exact unit stage because a
  /// dependant may not resolve until its provider has become public.
  bool _validateRepositoryScope(List<ResolvedUnit> units) {
    final unique = <String, Diagnostic>{};
    for (final unit in units) {
      final problems = Diagnostics();
      _validate(unit, problems);
      Checklist.derive(unit, resolution, problems);
      for (final problem in problems.found) {
        final key = '${problem.code}\u0000${problem.message}\u0000'
            '${problem.source ?? ''}';
        unique.putIfAbsent(key, () => problem);
      }
    }
    if (unique.isEmpty) return true;
    output.halt(HaltKind.beforeActing);
    output.problems(unique.values.toList());
    return false;
  }

  Future<int> _release(ResolvedUnit unit) async {
    // The machine surface carries the same identity facts on every verb:
    // doc/json.md promises repository and the unit's version and tag, and
    // the production-alpha retry checkpoint reads both from this document.
    output.report.unit(
      name: unit.name,
      version: unit.version.canonical,
      tag: unit.tag,
    );

    if (sourceWarning != null && !_sourceWarningShown) {
      _sourceWarningShown = true;
      output.heading('Warnings');
      output.warning(sourceWarning!, depth: 1);
      output.blank();
    }

    final problems = Diagnostics();
    _validate(unit, problems);
    if (problems.isNotEmpty) {
      output.halt(HaltKind.beforeActing);
      output.problems(problems.found);
      return ExitCodes.refused;
    }

    final checklist = Checklist.derive(unit, resolution, problems);
    if (problems.isNotEmpty) {
      output.halt(HaltKind.beforeActing);
      output.problems(problems.found);
      return ExitCodes.refused;
    }
    final publicSteps = checklist.steps.where((step) => step.isPublic).toList();
    final localOnly = publicSteps.isEmpty;
    if (stageOnly && !git.isBound && !localOnly) {
      output.problem(
        Diagnostic(
          code: 'RK-SRC-002',
          message: 'an unbound stage cannot be authorized by a later run',
          remedy: 'without Git, build, authorize, and begin publication in '
              'one invocation: rk release ${unit.name}',
        ),
        unit: unit.name,
      );
      output.halt(HaltKind.beforeActing);
      return ExitCodes.refused;
    }
    final targets = inspector.targets.derive(
      unit,
      checklist,
      repository: inspector.repository,
    );
    final targetByStep = {
      for (final target in targets) target.step.id: target,
    };
    final endpointBaselines = <String, String>{};
    final initialProgress = _TargetProgress(
      output,
      title: '${unit.name} ${unit.version} · preparing release',
      targets: targets,
    );

    final ReleaseStage stage;
    try {
      stage = _stageFor(unit);
    } on Object catch (error) {
      output.problem(Diagnostic(
        code: 'RK-STAGE-001',
        message: 'the release stage identity could not be resolved',
        remedy: '$error',
      ));
      output.halt(HaltKind.beforeActing);
      return ExitCodes.refused;
    }

    var stageInspection = stage.inspect();
    final states = <String, Inspection>{};
    for (final step in checklist.steps) {
      final target = targetByStep[step.id];
      if (target != null) {
        initialProgress.begin(
          target,
          inspector.targets.moduleForTarget(target).inspectActivity,
        );
      }
      states[step.id] = await _observeForRelease(
        step,
        unit,
        stageInspection,
      );
      final state = states[step.id]!;
      if (target != null) initialProgress.observe(target, state);
      output.step(
        step,
        verdict: state.verdict,
        detail: state.detail,
        evidence: state.evidence,
        action: step.isPublic
            ? (state.isExact
                ? _ReleaseAction.alreadyPublished.wire
                : _ReleaseAction.notAttempted.wire)
            : null,
        show: false,
      );
    }

    await inspector.releaseMonotonicity(unit, targets, problems);
    inspector.tagGuards(unit, checklist, states).forEach(problems.report);
    initialProgress.discard();
    if (problems.isNotEmpty) {
      output.halt(HaltKind.beforeActing);
      output.problems(problems.found);
      return ExitCodes.refused;
    }

    // Unknown public state never grants permission to perform local work.
    // The sole deferral is target-independent: once a binary publication is
    // exact and its stage is gone, the recovery check below owns the clearer
    // RK-STAGE-005 refusal for every remaining target.
    final partialBinaryStageLoss = unit.shipsBinaries &&
        !stageInspection.reusable &&
        publicSteps.any((step) => states[step.id]!.isExact);
    final initialBlock = checklist.steps.where((step) {
      if (step.kind == StepKind.completeStage) return false;
      final state = states[step.id]!;
      if (partialBinaryStageLoss && state.verdict == Verdict.unknown) {
        return false;
      }
      return Inspector.blocks(step, state);
    }).firstOrNull;
    if (initialBlock != null) {
      _haltForState(initialBlock, states[initialBlock.id]!);
      return ExitCodes.refused;
    }

    final publicActions = {
      for (final step in publicSteps)
        step.id: states[step.id]!.isExact
            ? _ReleaseAction.alreadyPublished
            : _ReleaseAction.notAttempted,
    };
    if (publicSteps.isNotEmpty &&
        publicSteps.every((step) => states[step.id]!.isExact)) {
      output.line(
        '${unit.name} ${unit.version}',
        mark: Mark.done,
        note: 'already released',
      );
      return ExitCodes.ok;
    }

    // A moving channel may be able to finish from authenticated public
    // inputs even after the local stage is lost. This is intentionally an
    // all-remaining-targets check: one versioned publication that still needs
    // bytes keeps the original stage recovery-critical for the whole run.
    final unfinishedTargets = [
      for (final step in publicSteps)
        if (!states[step.id]!.isExact) targetByStep[step.id]!,
    ];
    final recoversWithoutStage = !stageOnly &&
        !localOnly &&
        !stageInspection.reusable &&
        unfinishedTargets.isNotEmpty &&
        unfinishedTargets.every((target) {
          final state = states[target.step.id]!;
          return state.isAbsent &&
              inspector.targets
                  .moduleForTarget(target)
                  .canActWithoutReusableStage(state);
        });

    // Once any binary target is exact, the original signed/notarized stage is
    // recovery-critical until every other target is also proved exact. An
    // unread forge or tap cannot be treated as permission to rebuild: it may
    // already contain the bytes bound by the public tag.
    final partialBinaryRelease = unit.shipsBinaries &&
        !stageInspection.reusable &&
        !recoversWithoutStage &&
        publicSteps.any((step) => states[step.id]!.isExact) &&
        publicSteps.any((step) {
          final state = states[step.id]!;
          return state.isAbsent || state.verdict == Verdict.unknown;
        });
    if (partialBinaryRelease) {
      output.halt(HaltKind.unfixableByRerun);
      output.problem(Diagnostic(
        code: 'RK-STAGE-005',
        message: 'the partial binary release needs its exact stage',
        remedy: 'restore ${stage.directory.path} from the machine that '
            'staged this release. Signed or notarized bytes cannot be '
            'recreated byte-for-byte after a public target has bound them.',
      ));
      if (!stageOnly) _showReleaseActions(targets, publicActions);
      return ExitCodes.refused;
    }
    if (!stageInspection.reusable && !recoversWithoutStage) {
      final refusal = _refuseIfUnfinishable(unit);
      if (refusal != null) {
        output.halt(HaltKind.beforeActing);
        output.problem(refusal);
        if (!stageOnly) _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }
    }

    if (!stageOnly) {
      // Stage-only mode keeps its explicit ability to replace
      // reviewed-but-invalid bytes. A real release refuses that ambiguity
      // before any local preparation.
      final stageProblem = recoversWithoutStage
          ? null
          : _stagePreparationProblem(
              unit,
              stageInspection,
              mayReplaceReviewed: false,
            );
      if (stageProblem != null) {
        output.problem(stageProblem, unit: unit.name);
        output.halt(HaltKind.beforeActing);
        _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }
      if (!localOnly && !_requireAuthorizer(unit)) {
        _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }
    }

    // Safe ambient readiness applies to stage-only too: it may not acquire a
    // credential, but it should not spend substantial producer work on bytes
    // the current native endpoint can never publish as configured.
    final preflightProgress = _TargetProgress(
      output,
      title: '${unit.name} ${unit.version} · preparing release',
      targets: targets,
    );
    final preflight = TargetReadinessContext(
      tools: tools,
      git: git,
      environment: _refreshEnvironment(),
    );
    final outstanding =
        targets.where((target) => !states[target.step.id]!.isExact).toList();
    for (final targetKind in outstanding.map((item) => item.target).toSet()) {
      final grouped =
          outstanding.where((item) => item.target == targetKind).toList();
      final module = inspector.targets.moduleForTarget(grouped.first);
      for (final target in grouped) {
        preflightProgress.begin(target, module.preflightActivity);
      }
      final readiness = await module.preflight(
        TargetReadinessContext(
          tools: tools,
          git: git,
          environment: _refreshEnvironment(),
          progress: preflightProgress.combined(grouped),
        ),
        unit,
      );
      if (readiness case TargetNotReady(:final diagnostic, :final unit)) {
        preflightProgress
          ..failAll(grouped, activity: module.preflightActivity)
          ..notAttemptedPending()
          ..settle();
        output.problem(diagnostic, unit: unit);
        output.halt(HaltKind.beforeActing);
        if (!stageOnly) _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }
      final note = (readiness as TargetReady).note;
      for (final target in grouped) {
        preflightProgress.complete(target, note: note);
      }
      for (final target in grouped) {
        endpointBaselines[target.step.id] =
            module.effectiveEndpoint(preflight, unit, [target]);
      }
    }
    // Readiness that passed is not news; the transient rows served their
    // purpose while the checks ran.
    preflightProgress.discard();

    final _PreparedStage prepared;
    if (recoversWithoutStage) {
      prepared = _PreparedStage(
        claims: const [],
        receiptSteps: const [],
        signing: null,
      );
    } else {
      final targetStages = inspector.targets.stages(
        unit: unit,
        targets: targets,
      );
      final stageInputs = await _prepareStageInputs(
        unit,
        targets,
        stageInspection,
      );
      if (stageInputs == null) {
        if (!stageOnly) _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }

      final stageProgress = _StageProgress(
        output,
        title: '${unit.name} ${unit.version} · staging',
        board: StageBoard.forUnit(unit, targets, targetStages),
      );

      final result = await _prepareStage(
        unit,
        checklist,
        targets,
        targetStages,
        stage,
        stageInspection,
        stageProgress,
        stageInputs,
      );
      if (result == null) {
        if (!stageOnly) _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }
      prepared = result;
      stageInspection = stage.inspect();
      if (!stageInspection.reusable) {
        output.problem(Diagnostic(
          code: 'RK-STAGE-003',
          message: 'the release stage did not remain valid',
          remedy: stageInspection.issues.join('\n'),
        ));
        output.halt(HaltKind.beforeActing);
        if (!stageOnly) _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }
    }

    // Re-resolve the complete identity, not only HEAD. The stage plan also
    // binds the PATH-selected compiler, host ABI, origin, destinations, and
    // tag-signing policy. Stage-only completion must make the same claim that
    // those inputs remained stable while producers ran.
    if (!_releaseContextStillValid(
      stage,
      unit,
      changed: 'after staging',
      halt: HaltKind.beforeActing,
    )) {
      return ExitCodes.refused;
    }

    if (stageOnly || localOnly) {
      output.blank();
      output.line(
        'Written to',
        note: stage.directory.path,
        depth: 1,
        labelWidth: 12,
        noteTone: Tone.muted,
      );
      _sayStageClaims(
        prepared.claims,
        localOnly ? null : prepared.signing,
        settled: false,
      );
      // The next command is data for whoever is driving; the operator who
      // just staged does not need to be told what staging is for.
      if (!localOnly) output.report.next('rk release ${unit.name}');
      return ExitCodes.ok;
    }

    // Public reality is refreshed after staging. Unknown and conflict never
    // grant permission; exact work is skipped; only absent work may act.
    final releaseInputs = output.progressBoard(
      '${unit.name} ${unit.version} · preparing release',
      emitSlowToNonTerminal: true,
    );
    final releaseInputsRow = releaseInputs.addRow(
      id: '${unit.name}/release-inputs',
      label: 'Release inputs',
      coordinate: 'targets · signing · staged bytes',
    );
    releaseInputsRow.handle.begin(CommonProgressActivities.checking);
    final gate = PublicReleaseGate(inspector);
    var remaining = await _refreshPublicGate(
      gate: gate,
      unit: unit,
      publicSteps: publicSteps,
      targets: targets,
      states: states,
      actions: publicActions,
    );
    if (remaining == null) {
      releaseInputs.conclude();
      return ExitCodes.refused;
    }
    if (remaining.isEmpty) {
      releaseInputsRow.complete(note: 'checked');
      releaseInputs.discard();
      output.blank();
      output.line(
        '${unit.name} ${unit.version}',
        mark: Mark.done,
        note: 'already released',
      );
      return ExitCodes.ok;
    }

    final macosProject = recoversWithoutStage ? null : _macosProject(unit);
    if (macosProject != null) {
      releaseInputsRow.handle.begin(ProgressActivity(
        running: 'checking signing',
        failed: 'signing check failed',
      ));
    }
    final refreshedBaseline = await _signingBaseline(unit, macosProject);
    if (!refreshedBaseline.ok) {
      releaseInputs.conclude();
      _showReleaseActions(targets, publicActions);
      return ExitCodes.refused;
    }
    if (macosProject != null &&
        (prepared.signing == null ||
            refreshedBaseline.requirement !=
                prepared.signing!.publishedRequirement)) {
      releaseInputs.conclude();
      output.problem(Diagnostic(
        code: 'RK-SIGN-013',
        message: 'the published signing identity changed after staging',
        remedy: 'The reviewed signature was built against a different '
            'public baseline. Rebuild it explicitly: '
            'rk release ${unit.name} --stage.',
      ));
      output.halt(HaltKind.beforeActing);
      _showReleaseActions(targets, publicActions);
      return ExitCodes.refused;
    }

    if (!_releaseContextStillValid(
      stage,
      unit,
      changed: 'before authorization',
      halt: HaltKind.beforeActing,
    )) {
      releaseInputs.conclude();
      _showReleaseActions(targets, publicActions);
      return ExitCodes.refused;
    }

    // Public reads can take long enough for a local process or operator to
    // alter the private stage. Consent must bind the bytes inspected now,
    // not the ones that were valid before those reads began.
    if (!recoversWithoutStage &&
        !_stageStillValid(
          stage,
          unit,
          changed: 'before authorization',
          halt: HaltKind.beforeActing,
        )) {
      releaseInputs.conclude();
      _showReleaseActions(targets, publicActions);
      return ExitCodes.refused;
    }

    // Authorization names the targets and consequences that are true now,
    // after every potentially slow signing/context check. The per-target loop
    // still reads again after consent; this snapshot exists so the operator
    // never authorizes a stale remaining set.
    releaseInputsRow.handle.begin(CommonProgressActivities.checking);
    remaining = await _refreshPublicGate(
      gate: gate,
      unit: unit,
      publicSteps: publicSteps,
      targets: targets,
      states: states,
      actions: publicActions,
    );
    if (remaining == null) {
      releaseInputs.conclude();
      return ExitCodes.refused;
    }
    if (remaining.isEmpty) {
      releaseInputsRow.complete(note: 'checked');
      releaseInputs.discard();
      output.blank();
      output.line(
        '${unit.name} ${unit.version}',
        mark: Mark.done,
        note: 'already released',
      );
      return ExitCodes.ok;
    }

    // Native sessions are deliberately late: package validation, builds,
    // signing, notarization, bundle assembly, and exact remote reads have all
    // completed. The operator is not asked to refresh credentials for bytes
    // rk may later refuse. Each adapter's effective endpoint is frozen before
    // staging and re-read after acquisition so ambient config cannot redirect
    // the authorized publication.
    final remainingTargets = [
      for (final step in remaining) targetByStep[step.id]!,
    ];
    final recoveryBindings = <String, String>{};
    if (recoversWithoutStage) {
      for (final target in remainingTargets) {
        final module = inspector.targets.moduleForTarget(target);
        final binding = module.recoveryBinding(states[target.step.id]!);
        if (binding == null) {
          releaseInputs.conclude();
          output.problem(Diagnostic(
            code: 'RK-STAGE-005',
            message: '${target.step.summary} can no longer recover without '
                'its stage',
            remedy: 'public inputs changed before authorization. Re-run so '
                'rk can inspect the release again; restore '
                '${stage.directory.path} if the target still needs the '
                'original bytes.',
          ));
          output.halt(HaltKind.beforeActing);
          _showReleaseActions(targets, publicActions);
          return ExitCodes.refused;
        }
        recoveryBindings[target.step.id] = binding;
      }
    }
    releaseInputsRow.complete(note: 'checked');
    releaseInputs.discard();
    final sessionProgress = _TargetProgress(
      output,
      title: '${unit.name} ${unit.version} · preparing release',
      targets: targets,
    );
    for (final target in targets.where(
      (target) => !remainingTargets.contains(target),
    )) {
      sessionProgress.complete(
        target,
        note: 'already published',
        satisfied: true,
        restore: true,
      );
    }
    final sessionRequirements = <String, TargetSessionRequirement>{};
    for (final target in remainingTargets) {
      final module = inspector.targets.moduleForTarget(target);
      final provider = module.sessionProvider;
      if (provider == null) continue;
      final before = TargetReadinessContext(
        tools: tools,
        git: _refreshGit(),
        environment: _refreshEnvironment(),
      );
      final endpoint = module.effectiveEndpoint(before, unit, [target]);
      final key = '${provider.id}\u0000$endpoint';
      final existing = sessionRequirements[key];
      sessionRequirements[key] = TargetSessionRequirement(
        key: key,
        provider: provider,
        targets: [...?existing?.targets, target],
      );
    }
    final sessionTargetIds = {
      for (final requirement in sessionRequirements.values)
        for (final target in requirement.targets) target.step.id,
    };
    for (final target in remainingTargets.where(
      (target) => !sessionTargetIds.contains(target.step.id),
    )) {
      sessionProgress.begin(
        target,
        inspector.targets.moduleForTarget(target).preflightActivity,
      );
      sessionProgress.complete(target, note: 'checked');
    }
    for (final requirement in sessionRequirements.values) {
      final grouped = requirement.targets;
      for (final target in grouped) {
        sessionProgress.begin(target, requirement.provider.activity);
      }
      final before = TargetReadinessContext(
        tools: tools,
        git: _refreshGit(),
        environment: _refreshEnvironment(),
        progress: sessionProgress.combined(grouped),
        runInteractive: sessionProgress.interactive(tools),
      );
      final beforeMatches = grouped.every((target) {
        final module = inspector.targets.moduleForTarget(target);
        final baseline = endpointBaselines[target.step.id];
        return baseline != null &&
            module.effectiveEndpoint(before, unit, [target]) == baseline;
      });
      if (!beforeMatches) {
        sessionProgress
          ..failAll(grouped, activity: requirement.provider.activity)
          ..notAttemptedPending()
          ..settle();
        _destinationChanged(grouped.first.target, targets, publicActions);
        return ExitCodes.refused;
      }
      final acquired =
          await requirement.provider.acquire(before, unit, grouped);
      if (acquired case TargetNotReady(:final diagnostic, :final unit)) {
        sessionProgress
          ..failAll(grouped, activity: requirement.provider.activity)
          ..notAttemptedPending()
          ..settle();
        output.problem(diagnostic, unit: unit);
        output.halt(HaltKind.beforeActing);
        _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }
      final after = TargetReadinessContext(
        tools: tools,
        git: _refreshGit(),
        environment: _refreshEnvironment(),
      );
      final afterMatches = grouped.every((target) {
        final module = inspector.targets.moduleForTarget(target);
        final baseline = endpointBaselines[target.step.id];
        return baseline != null &&
            module.effectiveEndpoint(after, unit, [target]) == baseline;
      });
      if (!afterMatches) {
        sessionProgress
          ..failAll(grouped, activity: requirement.provider.activity)
          ..notAttemptedPending()
          ..settle();
        _destinationChanged(grouped.first.target, targets, publicActions);
        return ExitCodes.refused;
      }
      final note = (acquired as TargetReady).note;
      for (final target in grouped) {
        sessionProgress.complete(target, note: note);
      }
    }

    sessionProgress.discard();
    if (!await _authorize(
      unit,
      [for (final step in remaining) targetByStep[step.id]!],
      signing: prepared.signing,
      claims: prepared.claims,
    )) {
      _showReleaseActions(targets, publicActions);
      return ExitCodes.refused;
    }
    final authorizedStepIds = {for (final step in remaining) step.id};
    if (!_releaseContextStillValid(
      stage,
      unit,
      changed: 'during authorization',
      halt: HaltKind.beforeActing,
    )) {
      _showReleaseActions(targets, publicActions);
      return ExitCodes.refused;
    }
    if (!recoversWithoutStage &&
        !_stageStillValid(
          stage,
          unit,
          changed: 'during authorization',
          halt: HaltKind.beforeActing,
        )) {
      _showReleaseActions(targets, publicActions);
      return ExitCodes.refused;
    }

    // Consent may lose work when another actor completes it, but it may not
    // gain work. Sweep every omitted target together before the first act so
    // one that disappeared from public truth cannot hide behind an earlier
    // authorized step in checklist order.
    for (final step
        in publicSteps.where((step) => !authorizedStepIds.contains(step.id))) {
      final state = await inspector.inspect(step, unit);
      if (!state.isExact) {
        _haltForAuthorizationGrowth(
          step,
          state,
          unit,
          targets,
          publicActions,
        );
        return ExitCodes.refused;
      }
    }

    final releaseProgress = _TargetProgress(
      output,
      title: '${unit.name} ${unit.version} · releasing',
      targets: targets,
    );
    for (final target in targets.where(
      (target) => !authorizedStepIds.contains(target.step.id),
    )) {
      releaseProgress.complete(
        target,
        note: 'already published',
        satisfied: true,
        restore: true,
      );
    }
    var completedPublicTarget = false;
    for (final step in publicSteps) {
      final target = targetByStep[step.id]!;
      final module = inspector.targets.moduleForTarget(target);
      releaseProgress.begin(target, module.inspectActivity);
      var state = await inspector.inspect(step, unit);
      if (!authorizedStepIds.contains(step.id) && !state.isExact) {
        releaseProgress
          ..fail(target, activity: module.inspectActivity)
          ..notAttemptedPending()
          ..settle();
        _haltForAuthorizationGrowth(
          step,
          state,
          unit,
          targets,
          publicActions,
        );
        return ExitCodes.refused;
      }
      if (state.isExact) {
        publicActions[step.id] = _ReleaseAction.alreadyPublished;
        releaseProgress.complete(
          targetByStep[step.id]!,
          note: 'already published',
          satisfied: true,
        );
        output.step(
          step,
          mark: Mark.satisfied,
          verdict: state.verdict,
          note: state.detail ?? 'already done',
          action: publicActions[step.id]!.wire,
          show: false,
        );
        continue;
      }
      if (!state.isAbsent) {
        releaseProgress
          ..fail(target, activity: module.inspectActivity)
          ..notAttemptedPending()
          ..settle();
        _haltForState(step, state);
        return ExitCodes.refused;
      }
      final currentVersion = Diagnostics();
      final readIndependentHistory = await inspector.releaseMonotonicity(
        unit,
        [target],
        currentVersion,
        refreshRegistry: true,
      );
      if (currentVersion.isNotEmpty) {
        releaseProgress
          ..fail(target, activity: module.inspectActivity)
          ..notAttemptedPending()
          ..settle();
        output.halt(
          output.report.acted ? HaltKind.stoppedPartway : HaltKind.beforeActing,
        );
        output.problems(currentVersion.found);
        return ExitCodes.refused;
      }

      if (readIndependentHistory) {
        // The latest-version read may have refreshed a registry cache, and a
        // candidate can appear while the operator is authorizing. Re-read the
        // exact coordinate from that same fresh provider view before acting.
        state = await inspector.inspect(step, unit);
        output.step(
          step,
          verdict: state.verdict,
          detail: state.detail,
          evidence: state.evidence,
          action: publicActions[step.id]!.wire,
          show: false,
        );
        if (state.isExact) {
          publicActions[step.id] = _ReleaseAction.alreadyPublished;
          releaseProgress.complete(
            target,
            note: 'already published',
            satisfied: true,
          );
          output.step(
            step,
            mark: Mark.satisfied,
            verdict: state.verdict,
            note: state.detail ?? 'already done',
            action: publicActions[step.id]!.wire,
            show: false,
          );
          continue;
        }
        if (!state.isAbsent) {
          releaseProgress
            ..fail(target, activity: module.inspectActivity)
            ..notAttemptedPending()
            ..settle();
          _haltForState(step, state);
          return ExitCodes.refused;
        }
      }

      if (!recoversWithoutStage &&
          !_stageStillValid(
            stage,
            unit,
            changed: 'before ${step.summary}',
            halt: completedPublicTarget
                ? HaltKind.stoppedPartway
                : HaltKind.beforeActing,
          )) {
        releaseProgress
          ..fail(target)
          ..notAttemptedPending()
          ..settle();
        return ExitCodes.refused;
      }
      if (!_releaseContextStillValid(
        stage,
        unit,
        changed: 'before ${step.summary}',
        halt: completedPublicTarget
            ? HaltKind.stoppedPartway
            : HaltKind.beforeActing,
      )) {
        releaseProgress
          ..fail(target)
          ..notAttemptedPending()
          ..settle();
        return ExitCodes.refused;
      }

      // Make the provider observation the last fallible read before the act.
      // Local stage/context validation above cannot therefore create a gap in
      // which a newly exact or conflicting target is acted on blindly.
      state = await inspector.inspect(step, unit);
      output.step(
        step,
        verdict: state.verdict,
        detail: state.detail,
        evidence: state.evidence,
        action: publicActions[step.id]!.wire,
        show: false,
      );
      if (state.isExact) {
        publicActions[step.id] = _ReleaseAction.alreadyPublished;
        releaseProgress.complete(
          target,
          note: 'already published',
          satisfied: true,
        );
        output.step(
          step,
          mark: Mark.satisfied,
          verdict: state.verdict,
          note: state.detail ?? 'already done',
          action: publicActions[step.id]!.wire,
          show: false,
        );
        continue;
      }
      if (!state.isAbsent) {
        releaseProgress
          ..fail(target, activity: module.inspectActivity)
          ..notAttemptedPending()
          ..settle();
        _haltForState(step, state);
        return ExitCodes.refused;
      }
      if (recoversWithoutStage &&
          module.recoveryBinding(state) != recoveryBindings[step.id]) {
        releaseProgress
          ..fail(target, activity: module.inspectActivity)
          ..notAttemptedPending()
          ..settle();
        output.problem(Diagnostic(
          code: 'RK-STAGE-005',
          message: '${step.summary} can no longer recover without its stage',
          remedy: 'public inputs changed after authorization. Re-run so rk '
              'can inspect the release again; restore ${stage.directory.path} '
              'if the target still needs the original bytes.',
        ));
        output.halt(
          completedPublicTarget
              ? HaltKind.stoppedPartway
              : HaltKind.beforeActing,
        );
        return ExitCodes.refused;
      }
      final actedBefore = output.report.acted;
      output.report.acted = true;
      publicActions[step.id] = _ReleaseAction.attempted;
      output.step(
        step,
        verdict: state.verdict,
        detail: state.detail,
        evidence: state.evidence,
        action: publicActions[step.id]!.wire,
        show: false,
      );
      final releaseContext = TargetReleaseContext(
        reads: inspector.targetReads,
        tools: tools,
        stage: stage,
        progress: releaseProgress.handle(target),
        runInteractive: releaseProgress.interactive(tools),
        wait: _wait,
        confirmDeadline: confirmDeadline,
        confirmInterval: confirmInterval,
      );
      final mutationActivity = module.actActivity;
      releaseProgress.begin(target, mutationActivity);
      late final TargetActOutcome act;
      try {
        act = await module.act(releaseContext, unit, target, state);
      } on Object catch (error) {
        act = TargetActOutcome(
          ok: false,
          mayHaveActed: true,
          problem: '${target.kindLabel} operation threw: $error',
        );
      }
      final lastMutationActivity =
          releaseContext.progress.activity ?? mutationActivity;
      // An act's process result is not public truth. A registry can accept an
      // upload before the client loses its response; Git can finish a push
      // before the connection drops; GitHub can apply the final draft PATCH
      // before `gh` exits non-zero. Always run the same destination inspection
      // status uses before deciding what the command result means.
      releaseProgress.begin(target, module.verifyActivity);
      try {
        state = await module.settleAfterAct(releaseContext, unit, target);
      } on Object catch (error) {
        state = Inspection.unknown(
          '${target.kindLabel} verification threw: $error',
        );
      }
      publicActions[step.id] =
          state.isExact ? _ReleaseAction.completed : _ReleaseAction.failed;
      output.step(
        step,
        verdict: state.verdict,
        detail: state.detail,
        evidence: state.evidence,
        action: publicActions[step.id]!.wire,
        show: false,
      );
      if (!act.ok) {
        if (state.isExact && !output.report.halted) {
          final inspected = act.includeInspectionDetail && state.detail != null
              ? ' · ${state.detail}'
              : '';
          final note =
              '${act.reconciledNote ?? 'command response was lost · public target confirmed exact'}$inspected';
          releaseProgress.complete(
            target,
            note: note,
          );
          output.step(
            step,
            mark: Mark.done,
            verdict: state.verdict,
            detail: state.detail,
            note: note,
            action: publicActions[step.id]!.wire,
            show: false,
          );
          completedPublicTarget = true;
          continue;
        }
        releaseProgress.fail(
          target,
          activity:
              state.isAbsent ? lastMutationActivity : module.verifyActivity,
        );
        releaseProgress.notAttemptedPending();
        releaseProgress.settle();
        final failure = await module.classifyFailure(
          releaseContext,
          unit,
          target,
          state,
          act,
          actedBefore: actedBefore,
        );
        _reportTargetFailure(step, failure);
        return ExitCodes.refused;
      }
      if (!state.isExact) {
        releaseProgress.fail(target, activity: module.verifyActivity);
        releaseProgress.notAttemptedPending();
        releaseProgress.settle();
        final failure = await module.classifyFailure(
          releaseContext,
          unit,
          target,
          state,
          act,
          actedBefore: actedBefore,
        );
        _reportTargetFailure(step, failure);
        return ExitCodes.refused;
      }
      final inspected = act.includeInspectionDetail && state.detail != null
          ? ' · ${state.detail}'
          : '';
      releaseProgress.complete(
        target,
        note: '${act.successNote ?? 'published'}$inspected',
      );
      if (act.successNote != null) {
        output.step(
          step,
          mark: Mark.done,
          verdict: state.verdict,
          detail: state.detail,
          note: '${act.successNote}$inspected',
          action: publicActions[step.id]!.wire,
          show: false,
        );
      }
      completedPublicTarget = true;
    }

    releaseProgress.settle(released: true);
    for (final target in targets) {
      final module = inspector.targets.moduleForTarget(target);
      for (final line in module.completionLines(unit, target)) {
        output.say(line, depth: 1);
      }
    }
    return ExitCodes.ok;
  }

  void _destinationChanged(
    PublishTarget target,
    List<TargetExpectation> targets,
    Map<String, _ReleaseAction> actions,
  ) {
    output.problem(Diagnostic(
      code: 'RK-DEST-001',
      message: '${target.configName} changed destination while preparing '
          'publication',
      remedy: 'no public target changed. Restore the repository or native '
          'publisher configuration used before staging, then re-run. rk does '
          'not print destination values here because native coordinates may '
          'contain credentials.',
    ));
    output.halt(HaltKind.beforeActing);
    _showReleaseActions(targets, actions);
  }

  void _haltForAuthorizationGrowth(
    Step step,
    Inspection state,
    ResolvedUnit unit,
    List<TargetExpectation> targets,
    Map<String, _ReleaseAction> actions,
  ) {
    actions[step.id] = _ReleaseAction.notAttempted;
    output.step(
      step,
      verdict: state.verdict,
      detail: state.detail,
      evidence: state.evidence,
      action: actions[step.id]!.wire,
      show: false,
    );
    output.problem(
      Diagnostic(
        code: 'RK-AUTH-003',
        message: 'the release plan grew after authorization',
        remedy: '${step.summary} was not work when the plan was shown. RK '
            'will not add it after the yes; inspect the changed destination '
            'and authorize a fresh plan.',
      ),
      unit: unit.name,
      target: step.id,
    );
    output.halt(
      output.report.acted ? HaltKind.stoppedPartway : HaltKind.beforeActing,
    );
    _showReleaseActions(targets, actions);
  }

  Future<Inspection> _observeForRelease(
    Step step,
    ResolvedUnit unit,
    StageInspection stage,
  ) {
    if (step.kind == StepKind.completeStage) {
      return Future.value(stage.asInspection);
    }
    if (!step.isPublic &&
        step.kind != StepKind.prerequisite &&
        stage.reusable) {
      return Future.value(
        const Inspection.exact(detail: 'validated in the release stage'),
      );
    }
    return inspector.inspect(step, unit);
  }

  /// Applies one engine-owned public snapshot to the command report.
  ///
  /// Returning null means the gate refused. An empty list means every target
  /// was already published. Keeping that distinction here lets both temporal
  /// checkpoints share one presentation without hiding when they occur.
  Future<List<Step>?> _refreshPublicGate({
    required PublicReleaseGate gate,
    required ResolvedUnit unit,
    required List<Step> publicSteps,
    required List<TargetExpectation> targets,
    required Map<String, Inspection> states,
    required Map<String, _ReleaseAction> actions,
  }) async {
    final snapshot = await gate.refresh(
      unit: unit,
      steps: publicSteps,
      targets: targets,
    );
    for (final step in publicSteps) {
      final state = snapshot.states[step.id]!;
      states[step.id] = state;
      actions[step.id] = state.isExact
          ? _ReleaseAction.alreadyPublished
          : _ReleaseAction.notAttempted;
      output.step(
        step,
        verdict: state.verdict,
        detail: state.detail,
        evidence: state.evidence,
        action: actions[step.id]!.wire,
        show: false,
      );
    }

    final blocked = snapshot.blocked;
    if (blocked != null) {
      _haltForState(blocked, snapshot.states[blocked.id]!);
      _showReleaseActions(targets, actions);
      return null;
    }
    if (snapshot.monotonicityProblems.isNotEmpty) {
      output.problems(snapshot.monotonicityProblems);
      output.halt(HaltKind.beforeActing);
      _showReleaseActions(targets, actions);
      return null;
    }
    return snapshot.remaining;
  }

  void _reportTargetFailure(Step step, TargetFailure failure) {
    output.problem(failure.diagnostic, unit: step.unit);
    if (failure.nextCommand case final next?) output.next(next);
    output.halt(failure.halt);
    if (!failure.rerunHelps) output.report.rerunHelps = false;
  }

  void _haltForState(Step step, Inspection state, {bool afterAct = false}) {
    output.problem(Diagnostic(
      code: afterAct ? 'RK-REL-003' : 'RK-REL-001',
      message: '${step.summary}: ${state.detail ?? state.verdict.name}',
      remedy: state.evidence.isEmpty
          ? (state.verdict == Verdict.unknown
              ? 'the target could not be proven; fix the read and re-run'
              : null)
          : state.evidence.entries
              .map((entry) => '${entry.key}: ${entry.value}')
              .join('\n'),
    ));
    output.halt(
      state.verdict == Verdict.conflict
          ? (afterAct ? HaltKind.actedAndUnfixable : HaltKind.unfixableByRerun)
          : afterAct
              ? HaltKind.lostTrack
              : HaltKind.beforeActing,
    );
  }

  void _showReleaseActions(
    List<TargetExpectation> targets,
    Map<String, _ReleaseAction> actions,
  ) {
    output.blank();
    output.heading('Release targets');
    for (final target in targets) {
      final action = actions[target.step.id] ?? _ReleaseAction.notAttempted;
      final mark = switch (action) {
        _ReleaseAction.completed => Mark.done,
        _ReleaseAction.alreadyPublished => Mark.satisfied,
        _ReleaseAction.failed => Mark.blocked,
        _ReleaseAction.notAttempted || _ReleaseAction.attempted => Mark.none,
      };
      output.line(
        target.label,
        mark: mark,
        note: action.human,
        depth: 1,
      );
    }
  }

  bool _stageStillValid(
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
  ///
  /// A valid receipt proves the staged bytes did not change. It cannot prove
  /// that the repository, remote, signing policy, host, or PATH-selected
  /// compiler still describe the release the operator is about to publish.
  /// Re-resolving the stage identity binds those facts at each public boundary.
  bool _releaseContextStillValid(
    ReleaseStage stage,
    ResolvedUnit unit, {
    required String changed,
    required HaltKind halt,
  }) {
    final drift = <String>[];
    final GitState current;
    try {
      current = _refreshGit();
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

    if (current.isBound != git.isBound) {
      drift.add('the source binding changed');
    } else if (git.isBound && current.head != git.head) {
      drift.add(
          'HEAD is ${current.shortHead}; staged HEAD was ${git.shortHead}');
    }
    if (git.isBound && current.headTree != git.headTree) {
      drift.add('the HEAD tree changed');
    }
    if (git.isBound && !current.isClean) {
      final detail = current.worktreeStatusError ??
          (current.uncommitted.isEmpty
              ? 'the worktree is not clean'
              : 'uncommitted: ${current.uncommitted.join(', ')}');
      drift.add(detail);
    }
    if (unit.publish.contains(PublishTarget.gitTag) && !current.headIsPushed) {
      drift.add('HEAD is no longer present on a remote branch');
    }
    if (git.isBound && current.originUrl != git.originUrl) {
      drift.add('origin is ${current.originUrl ?? 'unreadable'}; staged origin '
          'was ${git.originUrl ?? 'unreadable'}');
    }
    if (unit.publish.contains(PublishTarget.gitTag) &&
        current.signingConfigured != git.signingConfigured) {
      drift.add('the Git tag-signing policy changed');
    }
    if (!git.isBound) {
      final sourceProblem = stage.unboundSourceProblem();
      if (sourceProblem != null) {
        drift.add('the unbound source changed: $sourceProblem');
      }
    }

    try {
      final refreshed = _refreshStage(unit, current);
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

  /// Resolves slow, shared release inputs before artifact rows begin moving.
  ///
  /// Claims and signing identity are unit-scoped facts, not artifacts and not
  /// publication targets. Giving them one honest row avoids both duplicating
  /// them under every target and leaving the operator staring at queued output
  /// rows while a public-history or keychain read is still in flight.
  Future<_StageInputs?> _prepareStageInputs(
    ResolvedUnit unit,
    List<TargetExpectation> targets,
    StageInspection inspected,
  ) async {
    final live = output.progressBoard(
      '${unit.name} ${unit.version} · preparing stage',
      emitSlowToNonTerminal: true,
    );
    final row = live.addRow(
      id: '${unit.name}/release-inputs',
      label: 'Release inputs',
      coordinate: 'claims · signing identity',
    );
    row.handle.begin(CommonProgressActivities.checking);
    final claims = await _firstClaims(unit, targets);

    _ProjectSigningContext? signing;
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
        signing = _ProjectSigningContext(
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
    return _StageInputs(claims: claims, signing: signing);
  }

  Future<_PreparedStage?> _prepareStage(
    ResolvedUnit unit,
    Checklist checklist,
    List<TargetExpectation> targets,
    List<TargetStage> targetStages,
    ReleaseStage stage,
    StageInspection inspected,
    _StageProgress stageProgress,
    _StageInputs inputs,
  ) async {
    final claims = inputs.claims;
    final notices = <String>[];
    if (inspected.reusable) {
      stageProgress
        ..restore(inspected.receipt!.steps)
        ..settle(title: '${unit.name} ${unit.version} · staged');
      _ProjectSigningContext? signing;
      for (final step in inspected.receipt!.steps.where(
        (step) => isMacosBuildReceipt(step.name),
      )) {
        final signature = step.evidence['signature']! as Map;
        final recovered = _ProjectSigningContext(
          publishedRequirement: signature['published_requirement'] as String?,
          firstIdentity: signature['first_identity']! as bool,
          certificateName: signature['certificate']! as String,
          certificateSha256: signature['certificate_sha256']! as String,
          designatedRequirement: signature['designated_requirement'] as String?,
          codeId: signature['code_id']! as String,
        );
        if (signing != null && !signing.sameRecordedIdentity(recovered)) {
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
        signing = recovered;
      }
      return _PreparedStage(
        claims: claims,
        receiptSteps: inspected.receipt!.steps,
        signing: signing,
      );
    }

    final stageProblem = _stagePreparationProblem(
      unit,
      inspected,
      mayReplaceReviewed: stageOnly,
    );
    if (stageProblem != null) {
      // Nothing began: the board owes no snapshot, matching the silent
      // refusal this path always had.
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
        sourceArtifacts = stage.materializeSource();
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
        if (progress.any((record) => record.name == receiptName)) {
          continue;
        }
        final TargetStageOutcome result;
        try {
          result = await targetStage.prepare(
            TargetStageContext(
              contract: targetStage.contract,
              tools: tools,
              git: git,
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

    final signing = inputs.signing;

    final producerSteps = checklist.steps.where((step) {
      return !step.isPublic &&
          step.kind != StepKind.prerequisite &&
          step.kind != StepKind.completeStage;
    }).toList();
    stageProgress.restore(progress);

    // Platform-less producers — dependency resolution — are the serial
    // prelude: they run to completion, in checklist order, before any lane
    // starts, because every build's `needs` edge points at them. Then one
    // lane per platform chain: a platform's build, notarize, and archive
    // touch only that platform's artifacts, so lanes are independent until
    // the complete-stage barrier, and the receipt's causal check accepts
    // any cross-lane interleaving because no input crosses a lane.
    final prelude = [
      for (final step in producerSteps)
        if (step.platform == null) step,
    ];
    final lanes = <String, List<Step>>{};
    for (final step in producerSteps) {
      if (step.platform == null) continue;
      lanes
          .putIfAbsent('${step.project}/${step.platform!}', () => [])
          .add(step);
    }
    assert(
      () {
        // The grouping and the checklist's graph must agree: every producer
        // dependency resolves in the prelude or earlier in its own lane.
        final producerIds = {for (final step in producerSteps) step.id};
        final preludeIds = {for (final step in prelude) step.id};
        for (final lane in lanes.values) {
          final earlier = <String>{...preludeIds};
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
      'a producer depends on a step outside its prelude or lane',
    );

    // A failure drains. The lane that failed marks its row and says its
    // problem right away; the others finish the step already in flight — a
    // killed half-written producer is exactly the ambiguity receipts exist
    // to prevent — and start nothing new. Failures collect the halts they
    // ask for; the strongest is spoken once after the drain, so content,
    // never scheduling, picks the epitaph. With near-simultaneous failures
    // the problems print in completion order — the concurrency is real.
    final failures = <HaltKind>[];

    Future<void> runLane(List<Step> lane) async {
      try {
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
                  stage, unit, step, sourceStep, progress, act);
              progress.add(recorded);
              try {
                _persistStageProgress(stage, sourceArtifacts, progress);
              } on Object {
                // Unrecordable means unrecorded: the step must not ride a
                // draining lane's later persist into the receipt.
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
            // Nothing may escape the join unfenced: an unexpected throw
            // stops new work and is spoken like any other stage failure
            // instead of crashing out while sibling lanes keep running.
            _stageOperationProblem('the ${unit.name} stage', error);
            failures.add(HaltKind.stoppedPartway);
            return;
          }
        }
      } on Object catch (error) {
        _stageOperationProblem('the ${unit.name} stage', error);
        failures.add(HaltKind.stoppedPartway);
      }
    }

    await runLane(prelude);
    if (failures.isEmpty) {
      await Future.wait([for (final lane in lanes.values) runLane(lane)]);
    }
    if (failures.isNotEmpty) {
      // Rows still active belong to drained lanes whose in-flight step
      // finished after the stop: their artifacts were not attempted, and
      // the rows say that rather than borrowing the failure's wording.
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
    return _PreparedStage(
      claims: claims,
      receiptSteps: completed,
      signing: signing,
    );
  }

  Diagnostic? _stagePreparationProblem(
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

    // "Ever finalized" rather than "complete": a damaged receipt whose
    // complete-stage step is no longer terminal derives incomplete, and
    // silently rebuilding those reviewed bytes is exactly what this
    // refusal exists to prevent.
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
        for (final output in outcome.outputs)
          StageArtifact.capture(
            stage: stage.directory,
            path: output.path,
            type: output.type,
          ),
      ],
      evidence: outcome.evidence,
    );
  }

  /// Package names this release claims for the first time.
  ///
  /// rk used to refuse a first publish outright (RK-REG-003), on the stated
  /// grounds that it "accepts the terms and names a publisher, which is the
  /// author's ceremony". That was not true. pub's own publish command has no
  /// first-time branch at all: `--force` skips only the confirmation prompt,
  /// the prompt text is identical for a new name, there is no terms
  /// acceptance in the flow, and a verified publisher is configured on the
  /// website afterwards or not at all. RFC 0002 *did* ask for the refusal —
  /// and asked for it on the same false premise, that "pub.dev accepts a
  /// first version only from an interactive publish". The spec is amended
  /// where it said so, per its own rule: where the code is right, move the
  /// spec.
  ///
  /// What IS true is narrower and worth saying out loud: a pub.dev package
  /// name is claimed permanently. It cannot be renamed, moved to another
  /// package, or given back. That is not a reason to refuse a release the
  /// operator intends — it is a reason to make sure they are looking at the
  /// name before they consent, because the accident this guards against is a
  /// typo claiming a name nobody meant to own.
  Future<List<TargetClaim>> _firstClaims(
    ResolvedUnit unit,
    List<TargetExpectation> targets,
  ) async {
    final reads = [
      for (final target in targets)
        inspector.targets
            .moduleForTarget(target)
            .firstClaims(inspector.targetReads, unit, target),
    ];
    return [for (final found in await Future.wait(reads)) ...found];
  }

  /// Refuses what this machine cannot finish, before any work rather than at
  /// the last step.
  Diagnostic? _refuseIfUnfinishable(ResolvedUnit unit) {
    if (!unit.shipsBinaries) return null;

    // The same capabilities the chain will build with — a second detect()
    // here let the refusal and the build disagree about what this host is.
    //
    // Platforms blocked for the same reason fold onto one line: two
    // identical sentences are one fact said twice. Grouped as they are
    // found, because the version that encoded '$platform — $reason' into a
    // list and parsed it back apart two lines later carried an arm for a
    // shape its own encoder could not produce.
    final byReason = <String, List<String>>{};
    for (final project in unit.projects) {
      for (final platform in project.binaryPlatforms) {
        final resolved = capabilities.resolve(platform);
        if (!resolved.canProduce) {
          byReason
              .putIfAbsent(
                  resolved.reason ?? 'it needs a different host', () => [])
              .add(platform);
        }
      }
    }
    if (byReason.isEmpty) return null;
    final folded = byReason.entries
        .map((e) => '${e.value.join(', ')} — ${e.key}')
        .toList();

    return Diagnostic(
      code: 'RK-HOST-001',
      message: '${unit.name}: this machine cannot produce every platform '
          'it ships',
      remedy: 'starting anyway would build and sign for minutes and then '
          'stop before publishing anything:\n'
          '  ${folded.join('\n  ')}',
    );
  }

  /// Platforms this host can build but not execute, as the prompt says it.
  ///
  /// Read from the same capability resolution the chain builds with, before
  /// anything acts, so the operator sees it in the plan rather than after.
  List<String> _unprovable(ResolvedUnit unit) {
    if (!unit.shipsBinaries) return const [];
    final unprovable = <String>[];
    for (final project in unit.projects) {
      for (final platform in project.binaryPlatforms) {
        final resolved = capabilities.resolve(platform);
        if (resolved.canProduce && !resolved.canProve) {
          unprovable.add('$platform — ${resolved.reason}');
        }
      }
    }
    return unprovable;
  }

  void _validate(ResolvedUnit unit, Diagnostics problems) {
    if (sourceWarning == null) {
      final uncommitted = repositoryGit.uncommittedProblem();
      if (uncommitted != null) problems.report(uncommitted);
    }
    if (unit.publish.contains(PublishTarget.gitTag)) {
      final unpushed = repositoryGit.unpushedProblem();
      if (unpushed != null) problems.report(unpushed);
    }
    for (final project in unit.projects) {
      Changelog.check(
        tree: tree,
        manifestDirectory: project.pubspec.directory,
        packageName: project.name,
        version: project.version,
        diagnostics: problems,
      );
    }
  }

  /// Whether this machine can sign, resolved before anything acts.
  ///
  /// Returns the exact certificate this project must sign with. Whether it is
  /// a first identity is kept separately in the project signing context. The
  /// keychain used to be read only by `MacOsSigner.sign`, where its answer
  /// arrived too late to make a useful preflight decision in the older
  /// publish-before-build pipeline. The current stage-before-public order
  /// keeps both this check and signing ahead of the tag, but the explicit
  /// preflight still produces the clearer refusal before stage work begins.
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

  /// The operator's ordinary yes is the authorization for a local release.
  /// Where a tag already exists, its signature is.
  Future<bool> _authorize(
    ResolvedUnit unit,
    List<TargetExpectation> remaining, {
    required _ProjectSigningContext? signing,
    required List<TargetClaim> claims,
  }) async {
    final permanent = remaining.where((target) {
      return target.step.isPermanent;
    }).toList();

    final disclosed = <String>[];
    output.blank();
    output.line('Release', tone: Tone.header);
    output.line(
      '${unit.name} ${unit.version}',
      depth: 1,
      tone: Tone.header,
    );
    for (final target in remaining) {
      output.line(target.step.summary, depth: 2);
    }
    if (permanent.isEmpty) {
      output.say('nothing here is permanent.');
    } else {
      // The ground, marked where it matters: everything before the yes is
      // resumable; the first permanent step after it is not.
      final notices = {
        for (final target in permanent)
          if (inspector.targets.moduleForTarget(target).permanenceNotice(target)
              case final notice?)
            notice,
      };
      final ground = '${notices.join('\n')}\n'
          'everything before this yes re-runs safely. after it, the first '
          'permanent step is: ${permanent.first.step.summary}.';
      output.say(ground);
      disclosed.add(ground);
    }

    disclosed.addAll(_sayClaims(claims, signing));

    // Weaker assurance is accepted knowingly or not at all: a platform
    // nothing here can run ships with its smoke test missing, and that is
    // said before the release is authorized, not discovered afterwards.
    final unprovable = _unprovable(unit);
    if (unprovable.isNotEmpty) {
      output.blank();
      final warning = 'these ship built but never executed — rk cannot '
          'prove they run or report ${unit.version}:';
      output.say(warning);
      for (final platform in unprovable) {
        output.say(platform, depth: 1);
      }
      disclosed.add('$warning\n${unprovable.join('\n')}');
    }

    // What the prompt disclosed travels with the yes. A --json --yes caller
    // never sees the prose sink, so the document carries it.
    if (disclosed.isNotEmpty) {
      output.report.attach(
        'authorization-disclosures/${unit.name}',
        disclosed.join('\n\n'),
      );
    }

    if (!_requireAuthorizer(unit)) return false;

    final answer = await confirm!(
      'Release ${unit.name} ${unit.version}? [y/N] ',
    );
    final accepted = switch (answer?.trim().toLowerCase()) {
      'y' || 'yes' => true,
      _ => false,
    };
    if (!accepted) {
      output.blank();
      output.say(answer == null
          ? 'no terminal to answer on — stopped; nothing was published.'
          : 'stopped. nothing was published.');
      output.problem(
        Diagnostic(
          code: 'RK-AUTH-002',
          message: 'the release was not authorized',
          remedy: 'answer yes at the prompt, or pass --yes for an '
              'unattended release',
        ),
        unit: unit.name,
      );
      output.halt(HaltKind.beforeActing);
      return false;
    }
    return true;
  }

  bool _requireAuthorizer(ResolvedUnit unit) {
    if (confirm != null) return true;
    output.problem(
      Diagnostic(
        code: 'RK-AUTH-001',
        message: 'nobody is here to authorize this release',
        remedy: 'answer yes at a terminal, or pass --yes for an unattended '
            'release. Without either, rk refuses.',
      ),
      unit: unit.name,
    );
    output.halt(HaltKind.beforeActing);
    return false;
  }

  Future<LocalProducerOutcome> _actProducer(
    Step step,
    ResolvedUnit unit,
    _ProjectSigningContext? signing, {
    ProgressHandle? progress,
  }) async {
    final project = unit.project(step.project!);
    switch (step.kind) {
      case StepKind.resolve:
        return _chain(unit).resolveStep(step, project);
      case StepKind.build:
        return _chain(unit).buildStep(
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
        return _chain(unit).notarizeStep(step, project);
      case StepKind.archive:
        return _chain(unit).archiveStep(step, project);
      default:
        throw StateError(
          'step ${step.kind.name} is not a local stage producer',
        );
    }
  }

  BinaryChain _chain(ResolvedUnit unit) => _chains.putIfAbsent(unit.name, () {
        final stage = _stageFor(unit);
        return BinaryChain(
          tools: tools,
          output: output,
          workspace: stage.directory.workspace,
          repositoryRoot: stage.sourceRoot,
          capabilities: capabilities,
          compilerExecutable: stage.compiler?.executable ?? 'dart',
        );
      });

  ProgressActivity _producerActivity(Step step) => switch (step.kind) {
        StepKind.resolve => ProgressActivity(
            running: 'resolving',
            failed: 'resolution failed',
          ),
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
    final repository = git.originUrl;
    if (repository == null) return (ok: true, requirement: null);

    final published = PublishedIdentity(
      tools: tools,
      repository: repository,
      workingDirectory: git.root,
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

  /// Every name this release takes for good, in one block.
  ///
  /// One line per registrar, each with its own notion of permanence, the
  /// name on its own line and the consequence indented under it — a reader
  /// who skims still sees the name, which is the thing a typo gets wrong.
  ///
  /// The macOS half was a separate sentence, gated on
  /// `shipsBinaries && permanent.isNotEmpty && certificates.length == 1`.
  /// None of those three is first-ness: `isPermanent` is `publishRegistry`
  /// alone, so it meant "a pub.dev publish remains" — true of every release
  /// of a pub.dev unit. It therefore announced a first signing on every
  /// later release from a one-certificate machine, and stayed silent on a
  /// genuine first release of a binaries-only unit, which has nothing
  /// permanent in it at all. `publishedRequirement == null` is the fact, and
  /// it is what `firstCertificate` carries.
  /// Says the first-claim disclosures and returns them, so the caller can
  /// carry them onto the machine surface beside the yes they gate.
  /// The names this release makes unreclaimable, without the paragraphs.
  ///
  /// A rehearsal exists to be read before these become permanent, so the
  /// facts belong here — but what "permanent" costs is an argument for the
  /// moment of consent, and [_sayClaims] makes it there, once, before the
  /// release is authorized.
  void _sayStageClaims(
    List<TargetClaim> claims,
    _ProjectSigningContext? signing, {
    required bool settled,
  }) {
    final firstSigning = signing?.firstCertificate == null ? null : signing;
    if (claims.isEmpty && firstSigning == null) return;
    output.blank();
    // Tense matters: at staging nothing public has happened yet, so saying
    // these *are* permanent would be false a moment before it is true.
    output.line(
      settled
          ? 'First release · these become permanent'
          : 'First release · permanent once published',
      depth: 1,
      tone: Tone.header,
    );
    for (final claim in claims) {
      output.line(
        '${claim.registrar} package',
        note: claim.name,
        depth: 2,
        labelWidth: 26,
        noteTone: Tone.muted,
      );
    }
    if (firstSigning != null) {
      output.line(
        'macOS code identifier',
        note: firstSigning.codeId,
        depth: 2,
        labelWidth: 26,
        noteTone: Tone.muted,
      );
      output.line(
        'Apple team',
        note: _shortCertificate(firstSigning.firstCertificate!),
        depth: 2,
        labelWidth: 26,
        noteTone: Tone.muted,
      );
    }
  }

  List<String> _sayClaims(
    List<TargetClaim> claims,
    _ProjectSigningContext? signing,
  ) {
    final firstSigning = signing?.firstCertificate == null ? null : signing;
    final firstOf = <String>[
      for (final claim in claims)
        '${claim.registrar.padRight(17)}${claim.name}\n'
            '                 ${claim.consequence}',
      if (firstSigning != null)
        '${'macOS identity'.padRight(17)}${firstSigning.codeId}\n'
            '                 permanent: sealed into the designated '
            'requirement, and into\n'
            '                 every Keychain item this program creates. '
            'Signed by\n'
            '                 ${firstSigning.firstCertificate}',
    ];
    if (firstOf.isEmpty) return const [];
    output.blank();
    output.say('this release claims, for the first time:');
    for (final line in firstOf) {
      output.say(line, depth: 1);
    }
    return ['this release claims, for the first time:', ...firstOf];
  }

  /// Every Developer ID certificate begins the same way; what varies is the
  /// team it names.
  static String _shortCertificate(String certificate) =>
      certificate.replaceFirst('Developer ID Application: ', '');
}

final class _TargetProgress {
  _TargetProgress(
    Output output, {
    required String title,
    required Iterable<TargetExpectation> targets,
  })  : _output = output,
        live = output.progressBoard(
          title,
          emitSlowToNonTerminal: true,
        ) {
    for (final target in targets) {
      _controllers[target.step.id] = live.addRow(
        id: target.step.id,
        label: target.kindLabel,
        coordinate: target.coordinate,
      );
    }
  }

  final Output _output;
  final LiveProgress live;
  final Map<String, ProgressRowController> _controllers = {};

  ProgressRowController _row(TargetExpectation target) =>
      _controllers[target.step.id]!;

  ProgressHandle handle(TargetExpectation target) => _row(target).handle;

  ProgressHandle combined(Iterable<TargetExpectation> targets) =>
      ProgressHandle.combine(targets.map(handle));

  void begin(TargetExpectation target, ProgressActivity activity,
      {String? detail}) {
    final row = _row(target);
    if (row.state == ProgressRowState.complete) return;
    row.handle.begin(activity, detail: detail);
  }

  void complete(
    TargetExpectation target, {
    required String note,
    bool satisfied = false,
    bool restore = false,
  }) {
    final row = _row(target);
    if (row.state == ProgressRowState.complete) return;
    final mark = satisfied ? ProgressRowMark.satisfied : ProgressRowMark.done;
    if (restore || row.state == ProgressRowState.pending) {
      row.restoreComplete(note: note, mark: mark);
    } else {
      row.complete(note: note, mark: mark);
    }
  }

  void observe(TargetExpectation target, Inspection inspection) {
    final row = _row(target);
    if (row.state != ProgressRowState.active) return;
    if (inspection.isExact) {
      row.complete(
        note: 'already published',
        mark: ProgressRowMark.satisfied,
      );
    } else if (inspection.isAbsent) {
      row.complete(
        note: 'not published',
        mark: ProgressRowMark.none,
      );
    } else {
      row.complete(
        note:
            inspection.verdict == Verdict.conflict ? 'conflict' : 'unreadable',
        mark: ProgressRowMark.none,
        emphasis: ProgressRowEmphasis.attention,
      );
    }
  }

  void fail(
    TargetExpectation target, {
    ProgressActivity? activity,
    String? note,
  }) {
    final row = _row(target);
    if (row.state == ProgressRowState.active) {
      row.fail(activity: activity, note: note);
    }
  }

  void failAll(
    Iterable<TargetExpectation> targets, {
    required ProgressActivity activity,
  }) {
    for (final target in targets) {
      fail(target, activity: activity);
    }
  }

  void notAttemptedPending() {
    for (final row in _controllers.values.where(
      (row) => row.state == ProgressRowState.pending,
    )) {
      row.notAttempted();
    }
  }

  ProgressInteractiveRunner interactive(Tools tools) {
    return (
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    }) async {
      live.suspend();
      try {
        return await tools.runInteractive(
          executable,
          arguments,
          workingDirectory: workingDirectory,
        );
      } finally {
        live.resume(afterNativeOutput: _output.isTerminal);
      }
    };
  }

  void discard() => live.discard();

  void settle({bool released = false}) => live.settle(
        title: released
            ? live.model.title.replaceFirst(' · releasing', ' · released')
            : null,
      );
}

/// Receipt-backed stage rows rendered through the one shared progress model.
final class _StageProgress {
  _StageProgress(
    Output output, {
    required String title,
    required this.board,
  }) : live = output.progressBoard(
          title,
          emitSlowToNonTerminal: true,
        ) {
    for (final group in board.groups) {
      for (final row in group.rows) {
        _controllers[row] = live.addRow(
          id: row.id,
          label: row.name,
          group: group.label,
        );
      }
    }
  }

  final StageBoard board;
  final LiveProgress live;
  final Map<StageBoardRow, ProgressRowController> _controllers = {};
  final Map<String, StageStep> _recorded = {};

  ProgressHandle? handleFor(String producer) {
    final rows = board.rowsFor(producer);
    if (rows.isEmpty) return null;
    return ProgressHandle.combine(
      rows.map((row) => _controllers[row]!.handle),
    );
  }

  Map<String, ProgressHandle> handlesFor(TargetStage stage) => {
        for (final view in stage.progress)
          view.id: _controllers[
                  board.progressRow(stage.contract.step.name, view.id)!]!
              .handle,
      };

  void begin(String producer, ProgressActivity activity) {
    for (final row in board.rowsFor(producer)) {
      final controller = _controllers[row]!;
      if (controller.state == ProgressRowState.complete) continue;
      controller.handle.begin(activity);
    }
  }

  void record(StageStep step) => restore([step]);

  void restore(Iterable<StageStep> steps) {
    for (final step in steps) {
      _recorded[step.name] = step;
    }
    for (final group in board.groups) {
      for (final row in group.rows) {
        final expected = board.producersFor(row);
        if (expected.isEmpty || !expected.every(_recorded.containsKey)) {
          continue;
        }
        final controller = _controllers[row]!;
        final note = _noteFor(expected);
        switch (controller.state) {
          case ProgressRowState.pending:
            controller.restoreComplete(note: note);
          case ProgressRowState.active:
            controller.complete(note: note);
          case ProgressRowState.complete:
          case ProgressRowState.failed:
          case ProgressRowState.notAttempted:
            break;
        }
      }
    }
  }

  String _noteFor(Set<String> producers) {
    final facts = <String>['staged'];
    for (final producer in producers) {
      final step = _recorded[producer]!;
      final signature = step.evidence['signature'];
      final notary = step.evidence['notary'];
      if (signature is Map && signature['certificate'] is String) {
        facts.add('signed');
      }
      if (notary is Map && notary['status'] == 'Accepted') {
        facts.add('notarized');
      }
    }
    return facts.toSet().join(' · ');
  }

  /// Marks one producer's row failed while the board stays live, so a
  /// draining run keeps describing its other lanes.
  void fail(String producer) {
    for (final row in board.rowsFor(producer)) {
      final controller = _controllers[row]!;
      if (controller.state == ProgressRowState.active) {
        controller.fail();
      }
    }
  }

  void conclude() => live.conclude();

  void discard() => live.discard();

  /// Concludes a drained run. A row still active belongs to a lane whose
  /// in-flight step finished after the stop — its artifact was not
  /// attempted, and the row says so instead of borrowing the failure's
  /// wording. Rows that failed were already marked by their own lane.
  void concludeStopped() {
    for (final group in board.groups) {
      for (final row in group.rows) {
        final controller = _controllers[row]!;
        if (controller.state == ProgressRowState.active) {
          controller.notAttempted();
        }
      }
    }
    live.conclude();
  }

  void settle({String? title}) => live.settle(title: title);
}

enum _ReleaseAction {
  notAttempted('not_attempted', 'not attempted'),
  attempted('attempted', 'attempted; result unknown'),
  alreadyPublished('already_published', 'already published'),
  completed('completed', 'completed'),
  failed('failed', 'failed');

  const _ReleaseAction(this.wire, this.human);

  final String wire;
  final String human;
}

class _StageInputs {
  const _StageInputs({required this.claims, required this.signing});

  final List<TargetClaim> claims;
  final _ProjectSigningContext? signing;
}

class _PreparedStage {
  _PreparedStage({
    required this.claims,
    required this.receiptSteps,
    required this.signing,
  });

  final List<TargetClaim> claims;

  /// The completed receipt, which is where the settled report reads what
  /// each producer proved — a certificate, Apple's verdict — instead of
  /// carrying prose composed while the work ran.
  final List<StageStep> receiptSteps;

  /// The unit's signing identity, when it ships a macOS binary.
  final _ProjectSigningContext? signing;
}

final class _ProjectSigningContext {
  const _ProjectSigningContext({
    required this.publishedRequirement,
    required this.firstIdentity,
    required this.certificateName,
    required this.codeId,
    this.identity,
    this.certificateSha256,
    this.designatedRequirement,
  });

  final String? publishedRequirement;
  final bool firstIdentity;
  final String certificateName;
  final String codeId;

  /// Present only while producing a new stage. A reusable stage needs the
  /// recorded public baseline and disclosure fields, never live keychain state.
  final SigningIdentity? identity;
  final String? certificateSha256;
  final String? designatedRequirement;

  String? get firstCertificate => firstIdentity ? certificateName : null;

  bool sameRecordedIdentity(_ProjectSigningContext other) =>
      publishedRequirement == other.publishedRequirement &&
      firstIdentity == other.firstIdentity &&
      certificateName == other.certificateName &&
      certificateSha256 == other.certificateSha256 &&
      designatedRequirement == other.designatedRequirement &&
      codeId == other.codeId;
}
