import '../engine/checklist.dart';
import '../engine/dependency_graph.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/inspect.dart';
import '../engine/publish_target.dart';
import '../engine/public_release_gate.dart';
import '../engine/release_stage.dart';
import '../engine/resolve.dart';
import '../engine/targets.dart';
import '../engine/tools.dart';
import '../engine/verdict.dart';
import '../output/output.dart';
import '../output/progress.dart';
import '../targets/target_module.dart';
import 'release_preparation.dart';
import 'release_progress.dart';
import 'release_stage_coordinator.dart';

/// Long enough that a preparation board helps instead of flashing briefly.
const _briefPhase = Duration(milliseconds: 800);

enum ReleaseAction {
  notAttempted('not_attempted', 'not attempted'),
  attempted('attempted', 'attempted; result unknown'),
  alreadyPublished('already_published', 'already published'),
  completed('completed', 'completed'),
  failed('failed', 'failed');

  const ReleaseAction(this.wire, this.human);

  final String wire;
  final String human;
}

/// Everything public publication receives after private preparation settles.
final class PublicationPlan {
  PublicationPlan({
    required this.unit,
    required Iterable<Step> steps,
    required Iterable<Step> publicSteps,
    required Iterable<TargetPlan> targets,
    required Map<String, Inspection> states,
    required Map<String, String> endpointBaselines,
    required Map<String, ReleaseAction> actions,
    required this.prepared,
    required this.stage,
    required this.recoversWithoutStage,
  })  : steps = List.unmodifiable(steps),
        publicSteps = List.unmodifiable(publicSteps),
        targets = List.unmodifiable(targets),
        states = Map.of(states),
        actions = Map.of(actions),
        endpointBaselines = Map.unmodifiable(endpointBaselines);

  final ResolvedUnit unit;
  final List<Step> steps;
  final List<Step> publicSteps;
  final List<TargetPlan> targets;
  final Map<String, Inspection> states;
  final Map<String, String> endpointBaselines;
  final Map<String, ReleaseAction> actions;
  final PreparedRelease prepared;
  final ReleaseStage stage;
  final bool recoversWithoutStage;
}

/// Owns the late, public half of a release.
final class ReleasePublicationCoordinator {
  ReleasePublicationCoordinator({
    required this.inspector,
    required this.initialGit,
    required this.tools,
    required this.output,
    required this.stages,
    required this.refreshGit,
    required this.refreshEnvironment,
    required this.wait,
    required this.confirm,
    required this.allowInteractiveTools,
    required this.confirmDeadline,
    required this.confirmInterval,
  });

  final Inspector inspector;
  final GitState initialGit;
  final Tools tools;
  final Output output;
  final ReleaseStageCoordinator stages;
  final Future<GitState> Function() refreshGit;
  final Map<String, String> Function() refreshEnvironment;
  final Future<void> Function(Duration) wait;
  final Future<String?> Function(String prompt)? confirm;
  final bool allowInteractiveTools;
  final Duration confirmDeadline;
  final Duration confirmInterval;

  final Map<String, TargetSessionProvider> _createdSessions = {};

  /// Gives eventually-consistent providers a bounded chance to become usable
  /// through their consumer-facing path after exact publication read-back.
  ///
  /// This cannot change release success: every check runs only after the
  /// public coordinate is already proven exact, and a pending result warns the
  /// operator not to repeat the irreversible act.
  Future<void> verifyAvailability({
    required ResolvedUnit unit,
    required List<TargetPlan> targets,
    required ReleaseStage? stage,
  }) async {
    if (targets.isEmpty) return;
    final progress = output.progressBoard(
      '${unit.name} ${unit.version} · checking availability',
    );
    final rows = {
      for (final target in targets)
        target.step.id: progress.addRow(
          id: '${target.step.id}/availability',
          label: target.kindLabel,
          coordinate: target.identity,
        ),
    };
    final warnings = await Future.wait([
      for (final target in targets)
        _verifyTargetAvailability(
          unit: unit,
          target: target,
          stage: stage,
          row: rows[target.step.id]!,
        ),
    ]);
    progress.discard();
    final pending = warnings.nonNulls.toList();
    if (pending.isEmpty) return;
    output.blank();
    output.heading('Availability warnings');
    for (final warning in pending) {
      output.warning(
        warning.diagnostic,
        unit: unit.name,
        target: warning.target.step.id,
        depth: 1,
      );
    }
  }

  Future<_AvailabilityWarning?> _verifyTargetAvailability({
    required ResolvedUnit unit,
    required TargetPlan target,
    required ReleaseStage? stage,
    required ProgressRowController row,
  }) async {
    final module = inspector.targets.moduleForTarget(target);
    final context = TargetAvailabilityContext(tools: tools, stage: stage);
    var waited = Duration.zero;
    while (true) {
      row.handle.begin(CommonProgressActivities.verifying);
      final TargetAvailabilityOutcome? outcome;
      try {
        outcome = await module.checkAvailability(context, unit, target);
      } on Object catch (error) {
        final diagnostic = Diagnostic(
          code: 'RK-REL-004',
          message: '${target.label}: consumer availability could not be '
              'checked',
          remedy: 'publication already reconciled exactly; restore the '
              'consumer check and verify without repeating publication',
          evidence: '$error',
        );
        row.fail(note: 'availability check failed');
        return _AvailabilityWarning(target, diagnostic);
      }
      switch (outcome) {
        case null:
          row.notAttempted(note: 'no delayed availability check');
          return null;
        case TargetAvailable(:final note):
          row.complete(note: note);
          return null;
        case TargetAvailabilityPending(:final diagnostic):
          if (waited >= confirmDeadline) {
            row.fail(note: 'still propagating');
            return _AvailabilityWarning(target, diagnostic);
          }
      }
      await wait(confirmInterval);
      waited += confirmInterval;
    }
  }

  /// Proves every unfinished target can publish from this host and freezes
  /// the destination each later credential acquisition must preserve.
  Future<Map<String, String>?> prepareDestinations({
    required ResolvedUnit unit,
    required List<TargetPlan> targets,
    required Map<String, Inspection> states,
    required Map<String, ReleaseAction> actions,
    required bool stageOnly,
  }) async {
    final progress = TargetReleaseProgress(
      output,
      title: '${unit.name} ${unit.version} · preparing release',
      targets: targets,
      delay: _briefPhase,
    );
    final context = TargetReadinessContext(
      tools: tools,
      git: initialGit,
      environment: refreshEnvironment(),
    );
    final outstanding =
        targets.where((target) => !states[target.step.id]!.isExact).toList();
    final bindings = <String, String>{};
    for (final targetKind in outstanding.map((item) => item.target).toSet()) {
      final grouped =
          outstanding.where((item) => item.target == targetKind).toList();
      final module = inspector.targets.moduleForTarget(grouped.first);
      for (final target in grouped) {
        progress.begin(target, CommonProgressActivities.checking);
      }
      final readiness = await module.checkReadiness(
        TargetReadinessContext(
          tools: tools,
          git: initialGit,
          environment: refreshEnvironment(),
          progress: progress.combined(grouped),
        ),
        unit,
      );
      if (readiness case TargetNotReady(:final diagnostic, :final unit)) {
        progress
          ..failAll(grouped, activity: CommonProgressActivities.checking)
          ..notAttemptedPending()
          ..settle();
        output.problem(diagnostic, unit: unit);
        output.halt(HaltKind.beforeActing);
        if (!stageOnly) showActions(targets, actions);
        return null;
      }
      final note = (readiness as TargetReady).note;
      for (final target in grouped) {
        progress.complete(target, note: note);
        bindings[target.step.id] =
            module.destinationBinding(context, unit, [target]);
      }
    }
    progress.discard();
    return Map.unmodifiable(bindings);
  }

  Future<void> restoreCreatedSessions() async {
    if (_createdSessions.isEmpty) return;
    final providers = _createdSessions.values.toList();
    _createdSessions.clear();
    for (final provider in providers) {
      final String? note;
      try {
        note = await provider.restore(TargetReadinessContext(
          tools: tools,
          git: await refreshGit(),
          environment: refreshEnvironment(),
        ));
      } on Object {
        continue;
      }
      if (note != null) output.say(note);
    }
  }

  void showActions(
    List<TargetPlan> targets,
    Map<String, ReleaseAction> actions,
  ) {
    output.blank();
    output.heading('Release targets');
    for (final target in targets) {
      final action = actions[target.step.id] ?? ReleaseAction.notAttempted;
      final mark = switch (action) {
        ReleaseAction.completed => Mark.done,
        ReleaseAction.alreadyPublished => Mark.satisfied,
        ReleaseAction.failed => Mark.blocked,
        ReleaseAction.notAttempted || ReleaseAction.attempted => Mark.none,
      };
      output.line(
        target.label,
        mark: mark,
        note: action.human,
        depth: 1,
        role: VisualRole.releaseTarget,
        state: switch (action) {
          ReleaseAction.notAttempted => RuntimeState.neutral,
          ReleaseAction.attempted => RuntimeState.attention,
          ReleaseAction.alreadyPublished => RuntimeState.satisfied,
          ReleaseAction.completed => RuntimeState.success,
          ReleaseAction.failed => RuntimeState.failure,
        },
      );
    }
  }

  void haltForState(Step step, Inspection state, {bool afterAct = false}) {
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

  Future<int> publish(PublicationPlan plan) async {
    final unit = plan.unit;
    final publicSteps = plan.publicSteps;
    final targets = plan.targets;
    final states = plan.states;
    final endpointBaselines = plan.endpointBaselines;
    final publicActions = plan.actions;
    final prepared = plan.prepared;
    final stage = plan.stage;
    final recoversWithoutStage = plan.recoversWithoutStage;
    final targetByStep = {
      for (final target in targets) target.step.id: target,
    };

    // Consent is based on fresh public truth and the same private stage that
    // was reviewed. These reads intentionally happen here, immediately before
    // sessions and authorization, rather than in the outer command.
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
        mark: Mark.satisfied,
        note: 'already released',
      );
      await verifyAvailability(
        unit: unit,
        targets: targets,
        stage: stage.inspect().reusable ? stage : null,
      );
      return ExitCodes.ok;
    }

    if (!recoversWithoutStage && prepared.signing != null) {
      releaseInputsRow.handle.begin(ProgressActivity(
        running: 'checking signing',
        failed: 'signing check failed',
      ));
    }
    if (!recoversWithoutStage &&
        !await stages.signingStillValid(unit, prepared)) {
      releaseInputs.conclude();
      showActions(targets, publicActions);
      return ExitCodes.refused;
    }
    if (!await stages.contextStillValid(
      stage,
      unit,
      changed: 'before authorization',
      halt: HaltKind.beforeActing,
    )) {
      releaseInputs.conclude();
      showActions(targets, publicActions);
      return ExitCodes.refused;
    }
    if (!recoversWithoutStage &&
        !stages.stageStillValid(
          stage,
          unit,
          changed: 'before authorization',
          halt: HaltKind.beforeActing,
        )) {
      releaseInputs.conclude();
      showActions(targets, publicActions);
      return ExitCodes.refused;
    }

    // Slow reads above can change which targets remain. Authorization may
    // lose work to another actor, but it never silently gains work.
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
        mark: Mark.satisfied,
        note: 'already released',
      );
      await verifyAvailability(
        unit: unit,
        targets: targets,
        stage: stage.inspect().reusable ? stage : null,
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
        final binding = module.stageRecoveryBinding(states[target.step.id]!);
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
          showActions(targets, publicActions);
          return ExitCodes.refused;
        }
        recoveryBindings[target.step.id] = binding;
      }
    }
    releaseInputsRow.complete(note: 'checked');
    releaseInputs.discard();
    final sessionProgress = TargetReleaseProgress(
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
      final provider = module.authentication;
      if (provider == null) continue;
      final before = TargetReadinessContext(
        tools: tools,
        git: await refreshGit(),
        environment: refreshEnvironment(),
      );
      final endpoint = module.destinationBinding(before, unit, [target]);
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
        CommonProgressActivities.checking,
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
        git: await refreshGit(),
        environment: refreshEnvironment(),
        progress: sessionProgress.combined(grouped),
        runInteractive:
            allowInteractiveTools ? sessionProgress.interactive(tools) : null,
      );
      final beforeMatches = grouped.every((target) {
        final module = inspector.targets.moduleForTarget(target);
        final baseline = endpointBaselines[target.step.id];
        return baseline != null &&
            module.destinationBinding(before, unit, [target]) == baseline;
      });
      if (!beforeMatches) {
        sessionProgress
          ..failAll(grouped, activity: requirement.provider.activity)
          ..notAttemptedPending()
          ..settle();
        _destinationChanged(grouped.first.target, targets, publicActions);
        return ExitCodes.refused;
      }
      // Asked before acquiring, so "rk created this" is a fact rather than an
      // inference from a login that may have found a session already there.
      final established = _createdSessions.containsKey(requirement.key)
          ? false
          : await requirement.provider.established(before);
      final acquired =
          await requirement.provider.acquire(before, unit, grouped);
      if (established == false) {
        _createdSessions[requirement.key] = requirement.provider;
      }
      if (acquired case TargetNotReady(:final diagnostic, :final unit)) {
        sessionProgress
          ..failAll(grouped, activity: requirement.provider.activity)
          ..notAttemptedPending()
          ..settle();
        output.problem(diagnostic, unit: unit);
        output.halt(HaltKind.beforeActing);
        showActions(targets, publicActions);
        return ExitCodes.refused;
      }
      final after = TargetReadinessContext(
        tools: tools,
        git: await refreshGit(),
        environment: refreshEnvironment(),
      );
      final afterMatches = grouped.every((target) {
        final module = inspector.targets.moduleForTarget(target);
        final baseline = endpointBaselines[target.step.id];
        return baseline != null &&
            module.destinationBinding(after, unit, [target]) == baseline;
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
      stage: stage,
      signing: prepared.signing,
      claims: prepared.claims,
    )) {
      showActions(targets, publicActions);
      return ExitCodes.refused;
    }
    final authorizedStepIds = {for (final step in remaining) step.id};
    if (!await stages.contextStillValid(
      stage,
      unit,
      changed: 'during authorization',
      halt: HaltKind.beforeActing,
    )) {
      showActions(targets, publicActions);
      return ExitCodes.refused;
    }
    if (!recoversWithoutStage &&
        !stages.stageStillValid(
          stage,
          unit,
          changed: 'during authorization',
          halt: HaltKind.beforeActing,
        )) {
      showActions(targets, publicActions);
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

    final releaseProgress = TargetReleaseProgress(
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
    final graph = DependencyGraph<Step>(
      plan.steps,
      idOf: (step) => step.id,
      dependenciesOf: (step) => step.needs,
    );
    final completed = <String>{
      for (final step in plan.steps)
        if (!step.isPublic || !authorizedStepIds.contains(step.id)) step.id,
    };
    final active = <String, Future<_PublicTargetCompletion>>{};
    final activeTargets = <PublishTarget>{};
    final failures = <_PublicationFailure>[];

    while (completed.length < plan.steps.length || active.isNotEmpty) {
      if (failures.isEmpty) {
        final ready = graph.ready(
          completed: completed,
          active: active.keys.toSet(),
        );
        for (final step in ready.where((step) => step.isPublic)) {
          final target = targetByStep[step.id]!;
          if (!activeTargets.add(target.target)) continue;
          active[step.id] = _publishPublicTarget(
            step: step,
            target: target,
            unit: unit,
            publicActions: publicActions,
            releaseProgress: releaseProgress,
            stage: stage,
            recoversWithoutStage: recoversWithoutStage,
            recoveryBinding: recoveryBindings[step.id],
          );
        }
      }

      _describePublicationWaits(
        graph: graph,
        completed: completed,
        active: active.keys.toSet(),
        activeTargets: activeTargets,
        authorizedStepIds: authorizedStepIds,
        targetByStep: targetByStep,
        progress: releaseProgress,
      );

      if (active.isEmpty) {
        if (failures.isNotEmpty) break;
        final unresolved = publicSteps
            .where((step) => !completed.contains(step.id))
            .map((step) => step.id)
            .join(', ');
        throw StateError('publication graph made no progress: $unresolved');
      }

      final completion = await Future.any(active.values);
      active.remove(completion.step.id);
      activeTargets.remove(completion.step.target);
      if (completion.failure case final failure?) {
        failures.add(failure);
      } else {
        completed.add(completion.step.id);
      }
      if (failures.isEmpty && output.report.acted) {
        for (final omitted in publicSteps.where(
          (step) => !authorizedStepIds.contains(step.id),
        )) {
          final state = await inspector.inspect(omitted, unit);
          if (!state.isExact) {
            publicActions[omitted.id] = ReleaseAction.notAttempted;
            output.step(
              omitted,
              verdict: state.verdict,
              detail: state.detail,
              evidence: state.evidence,
              action: publicActions[omitted.id]!.wire,
              show: false,
            );
            failures.add(_PublicationFailure(
              step: omitted,
              diagnostics: [
                Diagnostic(
                  code: 'RK-AUTH-003',
                  message: 'the release plan grew after authorization',
                  remedy: '${omitted.summary} was not work when the plan was '
                      'shown. RK will not add it after the yes; inspect the '
                      'changed destination and authorize a fresh plan.',
                ),
              ],
              halt: HaltKind.stoppedPartway,
            ));
            break;
          }
        }
      }
    }

    if (failures.isNotEmpty || output.report.halted) {
      releaseProgress
        ..notAttemptedPending()
        ..settle();
      _reportPublicationFailures(failures);
      return ExitCodes.refused;
    }

    releaseProgress.settle(released: true);
    await verifyAvailability(
      unit: unit,
      targets: targets,
      stage: stage.inspect().reusable ? stage : null,
    );
    return ExitCodes.ok;
  }

  void _describePublicationWaits({
    required DependencyGraph<Step> graph,
    required Set<String> completed,
    required Set<String> active,
    required Set<PublishTarget> activeTargets,
    required Set<String> authorizedStepIds,
    required Map<String, TargetPlan> targetByStep,
    required TargetReleaseProgress progress,
  }) {
    for (final step in graph.values.where(
      (step) =>
          step.isPublic &&
          authorizedStepIds.contains(step.id) &&
          !completed.contains(step.id) &&
          !active.contains(step.id),
    )) {
      final target = targetByStep[step.id]!;
      final blockers = graph
          .unmet(step, completed)
          .map((id) => graph[id])
          .where((dependency) => dependency.isPublic)
          .map((dependency) => targetByStep[dependency.id]!.label)
          .toSet();
      final note = blockers.isNotEmpty
          ? 'waiting for ${blockers.join(', ')}'
          : activeTargets.contains(target.target)
              ? 'waiting for ${target.kindLabel} lane'
              : null;
      if (note != null) progress.waiting(target, note: note);
    }
  }

  Future<_PublicTargetCompletion> _publishPublicTarget({
    required Step step,
    required TargetPlan target,
    required ResolvedUnit unit,
    required Map<String, ReleaseAction> publicActions,
    required TargetReleaseProgress releaseProgress,
    required ReleaseStage stage,
    required bool recoversWithoutStage,
    required String? recoveryBinding,
  }) async {
    final module = inspector.targets.moduleForTarget(target);
    releaseProgress.begin(target, CommonProgressActivities.checking);
    var state = await inspector.inspect(step, unit);
    if (state.isExact) {
      _completeExistingTarget(
        step,
        target,
        state,
        publicActions,
        releaseProgress,
      );
      return _PublicTargetCompletion.completed(step);
    }
    if (!state.isAbsent) {
      releaseProgress.fail(
        target,
        activity: CommonProgressActivities.checking,
      );
      return _PublicTargetCompletion.failed(
        step,
        _inspectionFailure(step, state),
      );
    }

    final currentVersion = Diagnostics();
    final historyCheck = await inspector.releaseMonotonicity(
      unit,
      [target],
      currentVersion,
      refreshRegistry: true,
    );
    if (currentVersion.isNotEmpty) {
      releaseProgress.fail(
        target,
        activity: CommonProgressActivities.checking,
      );
      return _PublicTargetCompletion.failed(
        step,
        _PublicationFailure(
          step: step,
          diagnostics: currentVersion.found,
          halt: output.report.acted
              ? HaltKind.stoppedPartway
              : HaltKind.beforeActing,
        ),
      );
    }

    if (historyCheck.readIndependentHistory) {
      // A latest-version read may refresh a provider cache. Re-read this
      // exact coordinate from the same fresh view before any act.
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
        _completeExistingTarget(
          step,
          target,
          state,
          publicActions,
          releaseProgress,
        );
        return _PublicTargetCompletion.completed(step);
      }
      if (!state.isAbsent) {
        releaseProgress.fail(
          target,
          activity: CommonProgressActivities.checking,
        );
        return _PublicTargetCompletion.failed(
          step,
          _inspectionFailure(step, state),
        );
      }
    }

    final validationHalt =
        output.report.acted ? HaltKind.stoppedPartway : HaltKind.beforeActing;
    if (!recoversWithoutStage &&
        !stages.stageStillValid(
          stage,
          unit,
          changed: 'before ${step.summary}',
          halt: validationHalt,
        )) {
      releaseProgress.fail(target);
      return _PublicTargetCompletion.failed(
        step,
        _PublicationFailure.reported(step),
      );
    }
    if (!await stages.contextStillValid(
      stage,
      unit,
      changed: 'before ${step.summary}',
      halt: validationHalt,
    )) {
      releaseProgress.fail(target);
      return _PublicTargetCompletion.failed(
        step,
        _PublicationFailure.reported(step),
      );
    }

    // This provider observation is the last fallible read before the act.
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
      _completeExistingTarget(
        step,
        target,
        state,
        publicActions,
        releaseProgress,
      );
      return _PublicTargetCompletion.completed(step);
    }
    if (!state.isAbsent) {
      releaseProgress.fail(
        target,
        activity: CommonProgressActivities.checking,
      );
      return _PublicTargetCompletion.failed(
        step,
        _inspectionFailure(step, state),
      );
    }
    if (recoversWithoutStage &&
        module.stageRecoveryBinding(state) != recoveryBinding) {
      releaseProgress.fail(
        target,
        activity: CommonProgressActivities.checking,
      );
      return _PublicTargetCompletion.failed(
        step,
        _PublicationFailure(
          step: step,
          diagnostics: [
            Diagnostic(
              code: 'RK-STAGE-005',
              message: '${step.summary} can no longer recover without its '
                  'stage',
              remedy: 'public inputs changed after authorization. Re-run so '
                  'rk can inspect the release again; restore '
                  '${stage.directory.path} if the target still needs the '
                  'original bytes.',
            ),
          ],
          halt: output.report.acted
              ? HaltKind.stoppedPartway
              : HaltKind.beforeActing,
        ),
      );
    }

    final actedBefore = output.report.acted;
    output.report.acted = true;
    publicActions[step.id] = ReleaseAction.attempted;
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
      runInteractive:
          allowInteractiveTools ? releaseProgress.interactive(tools) : null,
      wait: wait,
      confirmDeadline: confirmDeadline,
      confirmInterval: confirmInterval,
    );
    final mutationActivity = module.publishActivity;
    releaseProgress.begin(target, mutationActivity);
    late final TargetActOutcome act;
    try {
      act = await module.publish(releaseContext, unit, target, state);
    } on Object catch (error) {
      act = TargetActOutcome(
        ok: false,
        mayHaveActed: true,
        problem: '${target.kindLabel} operation threw: $error',
      );
    }
    final lastMutationActivity =
        releaseContext.progress.activity ?? mutationActivity;

    // A process result is not public truth. Every started operation performs
    // its destination read-back even if another concurrent lane has failed.
    releaseProgress.begin(target, CommonProgressActivities.verifying);
    try {
      state = await module.confirmPublication(releaseContext, unit, target);
    } on Object catch (error) {
      state = Inspection.unknown(
        '${target.kindLabel} verification threw: $error',
      );
    }
    publicActions[step.id] =
        state.isExact ? ReleaseAction.completed : ReleaseAction.failed;
    output.step(
      step,
      verdict: state.verdict,
      detail: state.detail,
      evidence: state.evidence,
      action: publicActions[step.id]!.wire,
      show: false,
    );
    if (!act.ok && state.isExact) {
      final inspected = act.includeInspectionDetail && state.detail != null
          ? ' · ${state.detail}'
          : '';
      final note =
          '${act.reconciledNote ?? 'command response was lost · public target confirmed exact'}$inspected';
      releaseProgress.complete(target, note: note);
      output.step(
        step,
        mark: Mark.done,
        verdict: state.verdict,
        detail: state.detail,
        note: note,
        action: publicActions[step.id]!.wire,
        show: false,
      );
      return _PublicTargetCompletion.completed(step);
    }
    if (!act.ok || !state.isExact) {
      releaseProgress.fail(
        target,
        activity: !act.ok && state.isAbsent
            ? lastMutationActivity
            : CommonProgressActivities.verifying,
      );
      final failure = await module.classifyUnconfirmedPublication(
        releaseContext,
        unit,
        target,
        state,
        act,
        actedBefore: actedBefore,
      );
      return _PublicTargetCompletion.failed(
        step,
        _PublicationFailure.fromTarget(step, failure),
      );
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
    return _PublicTargetCompletion.completed(step);
  }

  void _completeExistingTarget(
    Step step,
    TargetPlan target,
    Inspection state,
    Map<String, ReleaseAction> actions,
    TargetReleaseProgress progress,
  ) {
    actions[step.id] = ReleaseAction.alreadyPublished;
    progress.complete(
      target,
      note: 'already published',
      satisfied: true,
    );
    output.step(
      step,
      mark: Mark.satisfied,
      verdict: state.verdict,
      note: state.detail ?? 'already done',
      action: actions[step.id]!.wire,
      show: false,
    );
  }

  _PublicationFailure _inspectionFailure(Step step, Inspection state) {
    final acted = output.report.acted;
    return _PublicationFailure(
      step: step,
      diagnostics: [
        Diagnostic(
          code: 'RK-REL-001',
          message: '${step.summary}: ${state.detail ?? state.verdict.name}',
          remedy: state.evidence.isEmpty
              ? (state.verdict == Verdict.unknown
                  ? 'the target could not be proven; fix the read and re-run'
                  : null)
              : state.evidence.entries
                  .map((entry) => '${entry.key}: ${entry.value}')
                  .join('\n'),
        ),
      ],
      halt: state.verdict == Verdict.conflict
          ? acted
              ? HaltKind.actedAndUnfixable
              : HaltKind.unfixableByRerun
          : acted
              ? HaltKind.stoppedPartway
              : HaltKind.beforeActing,
    );
  }

  void _reportPublicationFailures(List<_PublicationFailure> failures) {
    for (final failure in failures.where((failure) => !failure.reported)) {
      for (final diagnostic in failure.diagnostics) {
        output.problem(diagnostic, unit: failure.step.unit);
      }
      if (failure.nextCommand case final next?) output.next(next);
      if (!failure.rerunHelps) output.report.rerunHelps = false;
    }
    if (output.report.halted || failures.isEmpty) return;
    output.halt(failures.map((failure) => failure.halt).reduce(_strongerHalt));
  }

  HaltKind _strongerHalt(HaltKind left, HaltKind right) {
    const severity = {
      HaltKind.beforeActing: 0,
      HaltKind.stoppedPartway: 1,
      HaltKind.lostTrack: 2,
      HaltKind.unfixableByRerun: 3,
      HaltKind.actedAndUnfixable: 4,
    };
    return severity[left]! >= severity[right]! ? left : right;
  }

  Future<List<Step>?> _refreshPublicGate({
    required PublicReleaseGate gate,
    required ResolvedUnit unit,
    required List<Step> publicSteps,
    required List<TargetPlan> targets,
    required Map<String, Inspection> states,
    required Map<String, ReleaseAction> actions,
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
          ? ReleaseAction.alreadyPublished
          : ReleaseAction.notAttempted;
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
      haltForState(blocked, snapshot.states[blocked.id]!);
      showActions(targets, actions);
      return null;
    }
    if (snapshot.monotonicityProblems.isNotEmpty) {
      output.problems(snapshot.monotonicityProblems);
      output.halt(HaltKind.beforeActing);
      showActions(targets, actions);
      return null;
    }
    return snapshot.remaining;
  }

  void _destinationChanged(
    PublishTarget target,
    List<TargetPlan> targets,
    Map<String, ReleaseAction> actions,
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
    showActions(targets, actions);
  }

  void _haltForAuthorizationGrowth(
    Step step,
    Inspection state,
    ResolvedUnit unit,
    List<TargetPlan> targets,
    Map<String, ReleaseAction> actions,
  ) {
    actions[step.id] = ReleaseAction.notAttempted;
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
    showActions(targets, actions);
  }

  List<({String platform, String reason})> _unprovable(ReleaseStage stage) {
    final unprovable = <({String platform, String reason})>[];
    final inspected = stage.inspect();
    final receipt = inspected.reusable ? inspected.receipt : null;
    if (receipt == null) return unprovable;
    for (final step in receipt.steps) {
      final parts = step.name.split(':');
      if (parts.length != 3 || parts.first != 'build') continue;
      final smoke = step.evidence['smoke'];
      if (smoke is! Map || smoke['status'] != 'not-executed') continue;
      final reason = smoke['reason'];
      if (reason is! String || reason.isEmpty) continue;
      unprovable.add((platform: parts.last, reason: reason));
    }
    return unprovable;
  }

  Future<bool> _authorize(
    ResolvedUnit unit,
    List<TargetPlan> remaining, {
    required ReleaseStage stage,
    required ReleaseSigningContext? signing,
    required List<TargetClaim> claims,
  }) async {
    final permanent = remaining.where((target) {
      return target.step.isPermanent;
    }).toList();

    final disclosed = <String>[];
    output.blank();
    output.line(
      'Release ${unit.name} ${unit.version}',
      role: VisualRole.checkpoint,
      strong: true,
    );

    // Grouped by destination, the way status and staging read. What is
    // permanent is said on the row it belongs to: a paragraph explaining
    // that publishing is forever tells an operator what they already know,
    // and buries the one line they do not.
    // Keyed by what is claimed, not by where: a unit publishing several
    // packages to pub.dev has one row each, and marking them all because
    // one name is new would tell the operator they are permanently taking
    // names that were taken releases ago.
    final firstClaims = {
      for (final claim in claims) '${claim.registrar}\u0000${claim.name}',
    };
    for (final target in remaining) {
      final permanence = <String>[
        if (target.step.isPermanent) 'permanent',
        if (firstClaims.contains('${target.kindLabel}\u0000'
            '${target.coordinate}'))
          'first claim',
      ];
      output.line(
        target.kindLabel,
        note: [target.planNote, ...permanence].join(' · '),
        depth: 1,
        labelWidth: 26,
        role: VisualRole.releaseTarget,
        noteState:
            permanence.isEmpty ? RuntimeState.neutral : RuntimeState.attention,
      );
    }
    final firstSigning = signing?.firstCertificate == null ? null : signing;
    if (firstSigning != null) {
      // The identifier first: it is what gets sealed into the designated
      // requirement and every Keychain item, so a wrong one has to be seen
      // rather than hunted for. The certificate says who signed it.
      output.line(
        'macOS identity',
        note: '${firstSigning.codeId} signed by '
            '${_shortCertificate(firstSigning.firstCertificate!)} · '
            'permanent · first claim',
        depth: 1,
        labelWidth: 26,
        role: VisualRole.requirement,
        noteState: RuntimeState.attention,
      );
    }
    // Nothing is said about permanence beyond the rows. A sentence telling
    // an operator that a release is permanent, printed above a prompt they
    // reached deliberately, is a paragraph they learn to scroll past — and
    // the rows already name which destinations mean it. The full wording,
    // and which step is the first that cannot be re-run, stay in the record
    // that travels with the authorization.
    if (permanent.isNotEmpty) {
      final notices = {
        for (final target in permanent)
          if (target.permanenceNotice case final notice?) notice,
      };
      disclosed.add('${notices.join('\n')}\n'
          'everything before this yes re-runs safely. after it, the first '
          'permanent step is: ${permanent.first.step.summary}.');
    }

    disclosed.addAll(_recordClaims(claims, firstSigning));

    // A weaker build proof belongs on the authorization surface as well as in
    // its durable record. Read the completed receipt rather than this host's
    // capability: a reused stage may have been smoke-tested elsewhere.
    final unprovable = _unprovable(stage);
    if (unprovable.isNotEmpty) {
      output.blank();
      output.heading('Warnings');
      for (final item in unprovable) {
        output.warning(
          Diagnostic(
            code: 'RK-BUILD-002',
            message: '${item.platform} was built but not executed: '
                '${item.reason}',
            remedy: 'run the staged binary on ${item.platform} before '
                'release if that platform is release-critical',
          ),
          unit: unit.name,
          depth: 1,
        );
      }
      disclosed.add('these ship built but never executed — rk cannot '
          'prove they run or report ${unit.version}:\n'
          '${unprovable.map((item) => '${item.platform} — ${item.reason}').join('\n')}');
    }

    // What the yes accepts travels with it. The attachment keeps the long
    // form even when the terminal surface intentionally stays concise.
    if (disclosed.isNotEmpty) {
      output.report.attach(
        'authorization-disclosures/${unit.name}',
        disclosed.join('\n\n'),
      );
    }

    if (!requireAuthorizer(unit)) return false;

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

  bool requireAuthorizer(ResolvedUnit unit) {
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

  /// Long-form first claims retained with the authorization record.
  List<String> _recordClaims(
    List<TargetClaim> claims,
    ReleaseSigningContext? firstSigning,
  ) {
    // Sentences, not columns. This is read out of the report by whoever or
    // whatever consented; the alignment it used to carry was for a screen
    // that no longer prints it.
    final firstOf = <String>[
      for (final claim in claims)
        '${claim.registrar} ${claim.name} — ${claim.consequence}',
      if (firstSigning != null)
        'macOS identity ${firstSigning.codeId} — permanent: sealed into the '
            'designated requirement, and into every Keychain item this '
            'program creates. Signed by ${firstSigning.firstCertificate}',
    ];
    if (firstOf.isEmpty) return const [];
    return ['this release claims, for the first time:', ...firstOf];
  }

  /// Every Developer ID certificate begins the same way; what varies is the
  /// team it names.
  static String _shortCertificate(String certificate) =>
      certificate.replaceFirst('Developer ID Application: ', '');
}

final class _PublicTargetCompletion {
  const _PublicTargetCompletion.completed(this.step) : failure = null;

  const _PublicTargetCompletion.failed(this.step, this.failure);

  final Step step;
  final _PublicationFailure? failure;
}

final class _AvailabilityWarning {
  const _AvailabilityWarning(this.target, this.diagnostic);

  final TargetPlan target;
  final Diagnostic diagnostic;
}

final class _PublicationFailure {
  const _PublicationFailure({
    required this.step,
    required this.diagnostics,
    required this.halt,
    this.nextCommand,
  }) : reported = false;

  const _PublicationFailure.reported(this.step)
      : diagnostics = const [],
        halt = HaltKind.beforeActing,
        nextCommand = null,
        reported = true;

  factory _PublicationFailure.fromTarget(
    Step step,
    TargetFailure failure,
  ) =>
      _PublicationFailure(
        step: step,
        diagnostics: [failure.diagnostic],
        halt: failure.halt,
        nextCommand: failure.nextCommand,
      );

  final Step step;
  final List<Diagnostic> diagnostics;
  final HaltKind halt;
  final String? nextCommand;
  final bool reported;

  bool get rerunHelps =>
      halt != HaltKind.unfixableByRerun && halt != HaltKind.actedAndUnfixable;
}
