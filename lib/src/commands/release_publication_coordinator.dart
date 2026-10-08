import '../engine/canonical_json.dart';
import '../engine/checklist.dart';
import '../engine/dependency_graph.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/inspect.dart';
import '../engine/publish_target.dart';
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
    required Map<String, ReleaseAction> actions,
    required this.prepared,
    required this.stage,
    required this.recoversWithoutStage,
  }) : steps = List.unmodifiable(steps),
       publicSteps = List.unmodifiable(publicSteps),
       targets = List.unmodifiable(targets),
       states = Map.of(states),
       actions = Map.of(actions);

  final ResolvedUnit unit;
  final List<Step> steps;
  final List<Step> publicSteps;
  final List<TargetPlan> targets;
  final Map<String, Inspection> states;
  final Map<String, ReleaseAction> actions;
  final PreparedRelease prepared;
  final ReleaseStage stage;
  final bool recoversWithoutStage;

  /// The targets this release still publishes: those the snapshot taken
  /// before staging did not find exact.
  List<TargetPlan> get remaining => [
    for (final target in targets)
      if (!states[target.step.id]!.isExact) target,
  ];
}

/// Owns the late, public half of a release.
///
/// Public state is read once before staging, and that snapshot is what one
/// question asks about. After the yes, each act reads its own target again,
/// checks the staged bytes it publishes, acts, and reads the result back.
/// Nothing the yes did not accept is published.
final class ReleasePublicationCoordinator {
  ReleasePublicationCoordinator({
    required this.inspector,
    required this.initialGit,
    required this.tools,
    required this.output,
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
  final Map<String, String> Function() refreshEnvironment;
  final Future<void> Function(Duration) wait;
  final Future<String?> Function(String prompt)? confirm;
  final bool allowInteractiveTools;
  final Duration confirmDeadline;
  final Duration confirmInterval;

  /// The public steps the one yes accepted, by unit. Null until asked.
  Map<String, Set<String>>? _authorized;

  /// The native sessions already acquired this run, by provider.
  final Set<String> _sessions = {};

  /// Gives eventually-consistent providers a bounded chance to become usable
  /// through their consumer-facing path after exact publication read-back.
  ///
  /// This cannot change release success: every check runs only after the
  /// public coordinate is already proven exact, and a pending result warns the
  /// operator not to repeat the irreversible act.
  Future<void> verifyAvailability({
    required ResolvedUnit unit,
    required List<TargetPlan> targets,
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
    required ProgressRowController row,
  }) async {
    final module = inspector.targets.moduleForTarget(target);
    final context = TargetAvailabilityContext(tools: tools);
    var waited = Duration.zero;
    while (true) {
      row.handle.begin(CommonProgressActivities.verifying);
      final TargetAvailabilityOutcome? outcome;
      try {
        outcome = await module.checkAvailability(context, unit, target);
      } on Object catch (error) {
        final diagnostic = Diagnostic(
          code: 'RK-REL-004',
          message:
              '${target.label}: consumer availability could not be '
              'checked',
          remedy:
              'publication already reconciled exactly; restore the '
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

  /// Proves every unfinished target can publish from this host, before any
  /// private work is spent on it.
  Future<bool> checkReadiness({
    required ResolvedUnit unit,
    required List<TargetPlan> targets,
    required Map<String, Inspection> states,
    required Map<String, ReleaseAction> actions,
    required bool stageOnly,
  }) async {
    final outstanding = targets
        .where((target) => !states[target.step.id]!.isExact)
        .toList();
    if (outstanding.isEmpty) return true;
    final progress = TargetReleaseProgress(
      output,
      title: '${unit.name} ${unit.version} · preparing release',
      targets: targets,
      delay: briefPhase,
    );
    final environment = refreshEnvironment();
    for (final targetKind in outstanding.map((item) => item.target).toSet()) {
      final grouped = outstanding
          .where((item) => item.target == targetKind)
          .toList();
      final module = inspector.targets.moduleForTarget(grouped.first);
      for (final target in grouped) {
        progress.begin(target, CommonProgressActivities.checking);
      }
      final readiness = await module.checkReadiness(
        TargetReadinessContext(
          tools: tools,
          git: initialGit,
          environment: environment,
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
        return false;
      }
      final note = (readiness as TargetReady).note;
      for (final target in grouped) {
        progress.complete(target, note: note);
      }
    }
    progress.discard();
    return true;
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

  void haltForState(
    ResolvedUnit unit,
    Step step,
    Inspection state, {
    TargetPlan? target,
    bool afterAct = false,
  }) {
    // Targets own their recovery advice. The observed bytes remain in the
    // step's JSON evidence, rather than taking the place of an action.
    final diagnostic =
        state.verdict == Verdict.conflict && target != null && !afterAct
        ? inspector.targets
              .moduleForTarget(target)
              .diagnoseConflict(unit, target, state)
        : Diagnostic(
            code: afterAct ? 'RK-REL-003' : 'RK-REL-001',
            message: '${step.summary}: ${state.detail ?? state.verdict.name}',
            remedy: state.evidence.isEmpty
                ? (state.verdict == Verdict.unknown
                      ? 'the target could not be proven; fix the read and re-run'
                      : null)
                : state.evidence.entries
                      .map((entry) => '${entry.key}: ${entry.value}')
                      .join('\n'),
          );
    output.problem(diagnostic, unit: unit.name);
    output.halt(
      state.verdict == Verdict.conflict
          ? (afterAct ? HaltKind.actedAndUnfixable : HaltKind.unfixableByRerun)
          : afterAct
          ? HaltKind.lostTrack
          : HaltKind.beforeActing,
    );
  }

  /// Asks once, for every unit, whether to publish what the snapshot found
  /// missing. No session is acquired before the answer.
  Future<bool> authorize(List<PublicationPlan> plans) async {
    final asking = plans.where((plan) => plan.remaining.isNotEmpty).toList();
    if (asking.isEmpty) {
      _authorized = const {};
      return true;
    }
    for (final plan in asking) {
      _showAuthorization(
        plan.unit,
        plan.remaining,
        stage: plan.stage,
        signing: plan.prepared.signing,
        claims: plan.prepared.claims,
      );
    }
    if (!requireAuthorizer(asking.first.unit)) return false;
    final names = [
      for (final plan in asking) '${plan.unit.name} ${plan.unit.version}',
    ];
    final series = names.length <= 2
        ? names.join(' and ')
        : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
    output.report.attach(
      'authorization-disclosures/run',
      [
        'Private preparation completed for the selected release scope.',
        for (final plan in asking)
          [
            '${plan.unit.name} ${plan.unit.version}',
            'stage ${plan.stage.directory.identity.id}',
            ...plan.remaining.map(
              (target) =>
                  '  ${target.kindLabel}: '
                  '${targetNote(target, plan.prepared.claims)}',
            ),
            output
                    .report
                    .attachments['authorization-disclosures/${plan.unit.name}'] ??
                '',
            CanonicalJson.encode(
              output.report.warningEvidenceFor(plan.unit.name),
            ),
          ].join('\n'),
      ].join('\n\n'),
    );
    final answer = await confirm!('Release $series? [y/N] ');
    final accepted = const {'y', 'yes'}.contains(answer?.trim().toLowerCase());
    if (!accepted) {
      output.blank();
      output.say(
        answer == null
            ? 'No confirmation received for $series.'
            : 'Cancelled release of $series.',
      );
      output.problem(
        const Diagnostic(
          code: 'RK-AUTH-002',
          message: 'the release was not authorized',
          remedy:
              'answer yes at the prompt, or pass --yes for an unattended release',
        ),
      );
      output.halt(HaltKind.beforeActing);
      output.next(
        plans.length == 1
            ? 'rk release ${plans.single.unit.name}'
            : 'rk release',
      );
      return false;
    }
    _authorized = {
      for (final plan in asking)
        plan.unit.name: {for (final target in plan.remaining) target.step.id},
    };
    output.blank();
    return true;
  }

  /// Publishes what [authorize] accepted for [plan]'s unit, in dependency
  /// order, and nothing else.
  Future<int> publish(PublicationPlan plan) async {
    final authorized = _authorized;
    if (authorized == null) {
      throw StateError('publication needs one authorization first');
    }
    final unit = plan.unit;
    final targets = plan.targets;
    final publicActions = plan.actions;
    final accepted = authorized[unit.name] ?? const <String>{};
    final targetByStep = {for (final target in targets) target.step.id: target};
    if (accepted.isEmpty) {
      if (plan.publicSteps.isNotEmpty) {
        output.line(
          '${unit.name} ${unit.version}',
          mark: Mark.satisfied,
          note: 'already released',
        );
      }
      return ExitCodes.ok;
    }
    final publishing = [
      for (final target in targets)
        if (accepted.contains(target.step.id)) target,
    ];
    if (!await _acquireSessions(unit, publishing)) {
      showActions(targets, publicActions);
      return ExitCodes.refused;
    }
    output.say('Authorized in the reviewed repository plan.');

    final releaseProgress = TargetReleaseProgress(
      output,
      title: '${unit.name} ${unit.version} · releasing',
      targets: targets,
    );
    for (final target in targets.where(
      (target) => !accepted.contains(target.step.id),
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
        if (!step.isPublic || !accepted.contains(step.id)) step.id,
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
            stage: plan.stage,
            recoversWithoutStage: plan.recoversWithoutStage,
          );
        }
      }

      _describePublicationWaits(
        graph: graph,
        completed: completed,
        active: active.keys.toSet(),
        activeTargets: activeTargets,
        authorizedStepIds: accepted,
        targetByStep: targetByStep,
        progress: releaseProgress,
      );

      if (active.isEmpty) {
        if (failures.isNotEmpty) break;
        final unresolved = plan.publicSteps
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
    }

    if (failures.isNotEmpty || output.report.halted) {
      releaseProgress
        ..notAttemptedPending()
        ..settle();
      _reportPublicationFailures(failures);
      return ExitCodes.refused;
    }

    releaseProgress.settle(released: true);
    await verifyAvailability(unit: unit, targets: publishing);
    return ExitCodes.ok;
  }

  /// Signs in once per provider for the run, after the yes and before the
  /// first act that needs it.
  Future<bool> _acquireSessions(
    ResolvedUnit unit,
    List<TargetPlan> publishing,
  ) async {
    final byProvider = <String, (TargetSessionProvider, List<TargetPlan>)>{};
    for (final target in publishing) {
      final provider = inspector.targets.moduleForTarget(target).authentication;
      if (provider == null || _sessions.contains(provider.id)) continue;
      final (_, grouped) = byProvider[provider.id] ??= (provider, []);
      grouped.add(target);
    }
    if (byProvider.isEmpty) return true;
    final progress = TargetReleaseProgress(
      output,
      title: '${unit.name} ${unit.version} · preparing release',
      targets: [for (final (_, grouped) in byProvider.values) ...grouped],
    );
    final environment = refreshEnvironment();
    for (final (provider, grouped) in byProvider.values) {
      for (final target in grouped) {
        progress.begin(target, provider.activity);
      }
      final acquired = await provider.acquire(
        TargetReadinessContext(
          tools: tools,
          git: initialGit,
          environment: environment,
          progress: progress.combined(grouped),
          runInteractive: allowInteractiveTools
              ? progress.interactive(tools)
              : null,
        ),
        unit,
        grouped,
      );
      if (acquired case TargetNotReady(:final diagnostic, :final unit)) {
        progress
          ..failAll(grouped, activity: provider.activity)
          ..notAttemptedPending()
          ..settle();
        output.problem(diagnostic, unit: unit);
        output.halt(HaltKind.beforeActing);
        return false;
      }
      _sessions.add(provider.id);
      final note = (acquired as TargetReady).note;
      for (final target in grouped) {
        progress.complete(target, note: note);
      }
    }
    progress.discard();
    return true;
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
  }) async {
    final module = inspector.targets.moduleForTarget(target);
    releaseProgress.begin(target, CommonProgressActivities.checking);
    // The target is read again right before its act: another run or person
    // may have published it since the snapshot.
    var state = await inspector.inspect(step, unit);
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
      releaseProgress.fail(target, activity: CommonProgressActivities.checking);
      return _PublicTargetCompletion.failed(
        step,
        _inspectionFailure(step, target, unit, state),
      );
    }
    final halt = output.report.acted
        ? HaltKind.stoppedPartway
        : HaltKind.beforeActing;
    if (recoversWithoutStage && !module.recoversWithoutStage(state)) {
      releaseProgress.fail(target, activity: CommonProgressActivities.checking);
      return _PublicTargetCompletion.failed(
        step,
        _PublicationFailure(
          step: step,
          diagnostics: [
            Diagnostic(
              code: 'RK-STAGE-005',
              message:
                  '${step.summary} can no longer recover without its '
                  'stage',
              remedy:
                  'its public inputs changed. Re-run so rk can inspect the '
                  'release again; restore ${stage.directory.path} if the '
                  'target still needs the original bytes.',
            ),
          ],
          halt: halt,
        ),
      );
    }
    // What the act publishes is read from the stage, so its recorded bytes
    // are checked again first. Within a run this costs a stat per file.
    if (!recoversWithoutStage) {
      final inspected = stage.inspect();
      if (!inspected.reusable) {
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
                code: 'RK-STAGE-002',
                message:
                    'the reviewed release stage changed before '
                    '${step.summary}',
                remedy:
                    '${inspected.issues.join('\n')}\n'
                    'rebuild it explicitly: rk stage ${unit.name}',
              ),
            ],
            halt: halt,
          ),
        );
      }
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
      runInteractive: allowInteractiveTools
          ? releaseProgress.interactive(tools)
          : null,
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
    publicActions[step.id] = state.isExact
        ? ReleaseAction.completed
        : ReleaseAction.failed;
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
    progress.complete(target, note: 'already published', satisfied: true);
    output.step(
      step,
      mark: Mark.satisfied,
      verdict: state.verdict,
      note: state.detail ?? 'already done',
      action: actions[step.id]!.wire,
      show: false,
    );
  }

  /// A target read right before its act found something other than the
  /// release missing. A conflict carries the target's own advice, as it
  /// does when the snapshot finds it.
  _PublicationFailure _inspectionFailure(
    Step step,
    TargetPlan target,
    ResolvedUnit unit,
    Inspection state,
  ) {
    final acted = output.report.acted;
    return _PublicationFailure(
      step: step,
      diagnostics: [
        if (state.verdict == Verdict.conflict)
          inspector.targets
              .moduleForTarget(target)
              .diagnoseConflict(unit, target, state)
        else
          Diagnostic(
            code: 'RK-REL-001',
            message: '${step.summary}: ${state.detail ?? state.verdict.name}',
            remedy: state.evidence.isEmpty
                ? 'the target could not be proven; fix the read and re-run'
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
    for (final failure in failures) {
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

  /// A row for each of [remaining], saying which are permanent and which
  /// claim a name for the first time.
  void showTargets(List<TargetPlan> remaining, List<TargetClaim> claims) {
    // Grouped by destination, the way status and staging read. What is
    // permanent is said on the row it belongs to: a paragraph explaining
    // that publishing is forever tells an operator what they already know,
    // and buries the one line they do not.
    for (final target in remaining) {
      output.line(
        target.kindLabel,
        note: targetNote(target, claims),
        depth: 1,
        labelWidth: 26,
        role: VisualRole.releaseTarget,
        noteState: _marks(target, claims).isEmpty
            ? RuntimeState.neutral
            : RuntimeState.attention,
      );
    }
  }

  /// What [target]'s row says: what arrives there, and its marks.
  String targetNote(TargetPlan target, List<TargetClaim> claims) =>
      [target.planNote, ..._marks(target, claims)].join(' · ');

  // Keyed by what is claimed, not by where: a unit publishing several
  // packages to pub.dev has one row each, and marking them all because one
  // name is new would tell the operator they are permanently taking names
  // that were taken releases ago.
  static List<String> _marks(TargetPlan target, List<TargetClaim> claims) => [
    if (target.step.isPermanent) 'permanent',
    if (claims.any(
      (claim) =>
          claim.registrar == target.kindLabel &&
          claim.name == target.coordinate,
    ))
      'first claim',
  ];

  /// The long form of what a yes for [remaining] accepts, which travels with
  /// it: what the permanent targets mean, and every name claimed first.
  ///
  /// [firstStep] says which permanent step is the first a yes lets happen,
  /// which only the question itself knows when it covers several units.
  List<String> disclosureFor(
    List<TargetPlan> remaining,
    List<TargetClaim> claims, {
    ReleaseSigningContext? firstSigning,
    bool firstStep = true,
  }) {
    final permanent = [
      for (final target in remaining)
        if (target.step.isPermanent) target,
    ];
    final notices = {
      for (final target in permanent)
        if (target.permanenceNotice case final notice?) notice,
    };
    return [
      if (permanent.isNotEmpty)
        [
          ...notices,
          if (firstStep)
            'everything before this yes re-runs safely. after it, the first '
                'permanent step is: ${permanent.first.step.summary}.',
        ].join('\n'),
      ..._recordClaims(claims, firstSigning),
    ];
  }

  void _showAuthorization(
    ResolvedUnit unit,
    List<TargetPlan> remaining, {
    required ReleaseStage stage,
    required ReleaseSigningContext? signing,
    required List<TargetClaim> claims,
  }) {
    final disclosed = <String>[];
    output.blank();
    output.line(
      'Release ${unit.name} ${unit.version}',
      role: VisualRole.checkpoint,
      strong: true,
    );

    showTargets(remaining, claims);
    final firstSigning = signing?.firstCertificate == null ? null : signing;
    if (firstSigning != null) {
      // The identifier first: it is what gets sealed into the designated
      // requirement and every Keychain item, so a wrong one has to be seen
      // rather than hunted for. The certificate says who signed it.
      output.line(
        'macOS identity',
        note:
            '${firstSigning.codeId} signed by '
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
    disclosed.addAll(
      disclosureFor(remaining, claims, firstSigning: firstSigning),
    );

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
            message:
                '${item.platform} was built but not executed: '
                '${item.reason}',
            remedy:
                'run the staged binary on ${item.platform} before '
                'release if that platform is release-critical',
          ),
          unit: unit.name,
          depth: 1,
        );
      }
      disclosed.add(
        'these ship built but never executed — rk cannot '
        'prove they run or report ${unit.version}:\n'
        '${unprovable.map((item) => '${item.platform} — ${item.reason}').join('\n')}',
      );
    }

    // What the yes accepts travels with it. The attachment keeps the long
    // form even when the terminal surface intentionally stays concise.
    if (disclosed.isNotEmpty) {
      output.report.attach(
        'authorization-disclosures/${unit.name}',
        disclosed.join('\n\n'),
      );
    }
  }

  bool requireAuthorizer(ResolvedUnit unit) {
    if (confirm != null) return true;
    output.problem(
      Diagnostic(
        code: 'RK-AUTH-001',
        message: 'nobody is here to authorize this release',
        remedy:
            'answer yes at a terminal, or pass --yes for an unattended '
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
  });

  factory _PublicationFailure.fromTarget(Step step, TargetFailure failure) =>
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

  bool get rerunHelps =>
      halt != HaltKind.unfixableByRerun && halt != HaltKind.actedAndUnfixable;
}
