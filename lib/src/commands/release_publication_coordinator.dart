import '../engine/canonical_json.dart';
import '../engine/dependency_graph.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/inspect.dart';
import '../engine/publish_target.dart';
import '../engine/resolve.dart';
import '../engine/stage.dart';
import '../engine/tools.dart';
import '../engine/unit_release.dart';
import '../engine/verdict.dart';
import '../output/output.dart';
import '../output/progress.dart';
import '../targets/target_module.dart';
import 'release_preparation.dart';
import 'release_progress.dart';

enum ReleaseAction {
  notAttempted('not_attempted', 'not attempted'),
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
    required this.release,
    required Map<String, Inspection> states,
    required Map<String, ReleaseAction> actions,
    required this.prepared,
    required this.stage,
    required this.recoversWithoutStage,
  }) : states = Map.of(states),
       actions = Map.of(actions);

  final UnitRelease release;
  ResolvedUnit get unit => release.unit;
  late final List<Step> steps = release.steps.toList();
  List<Target> get targets => release.targets;
  final Map<String, Inspection> states;
  final Map<String, ReleaseAction> actions;
  final PreparedRelease prepared;
  final Stage stage;
  final bool recoversWithoutStage;

  /// The targets this release still publishes: those the snapshot taken
  /// before staging did not find exact.
  List<Target> get remaining => [
    for (final target in targets)
      if (!states[target.id]!.isExact) target,
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

  /// The targets whose native session this run has already signed in to.
  final Set<PublishTarget> _signedIn = {};

  /// Proves every unfinished target can publish from this host, before any
  /// private work is spent on it.
  Future<bool> checkReadiness({
    required ResolvedUnit unit,
    required List<Target> targets,
    required Map<String, Inspection> states,
  }) async {
    final outstanding = targets
        .where((target) => !states[target.id]!.isExact)
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
      final module = inspector.targets.moduleFor(targetKind);
      for (final target in grouped) {
        progress.begin(target, CommonProgressActivities.checking);
      }
      final readiness = await module.ready(
        TargetReadinessContext(
          tools: tools,
          git: initialGit,
          environment: environment,
          progress: progress.combined(grouped),
        ),
        unit,
        signIn: false,
      );
      if (readiness.problem case final problem?) {
        progress
          ..failAll(grouped, activity: CommonProgressActivities.checking)
          ..notAttemptedPending()
          ..settle();
        output.problem(problem, unit: unit.name);
        output.halt(HaltKind.beforeActing);
        return false;
      }
      for (final target in grouped) {
        progress.complete(target, note: readiness.note);
      }
    }
    progress.discard();
    return true;
  }

  void showActions(List<Target> targets, Map<String, ReleaseAction> actions) {
    output.blank();
    output.heading('Release targets');
    for (final target in targets) {
      final action = actions[target.id] ?? ReleaseAction.notAttempted;
      final mark = switch (action) {
        ReleaseAction.completed => Mark.done,
        ReleaseAction.alreadyPublished => Mark.satisfied,
        ReleaseAction.failed => Mark.blocked,
        ReleaseAction.notAttempted => Mark.none,
      };
      output.line(
        target.label,
        mark: mark,
        note: action.human,
        depth: 1,
        role: VisualRole.releaseTarget,
        state: switch (action) {
          ReleaseAction.notAttempted => RuntimeState.neutral,
          ReleaseAction.alreadyPublished => RuntimeState.satisfied,
          ReleaseAction.completed => RuntimeState.success,
          ReleaseAction.failed => RuntimeState.failure,
        },
      );
    }
  }

  /// Stops before anything acts on [step], whose snapshot read refuses it.
  void haltForState(ResolvedUnit unit, Step step, Inspection state) {
    final refusal = _refusal(step, unit, state, acted: false);
    output.problem(refusal.diagnostics.single, unit: unit.name);
    output.halt(refusal.halt);
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
        unprovable: _unprovable(plan),
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
            'stage ${plan.stage.id.id}',
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
        plan.unit.name: {for (final target in plan.remaining) target.id},
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
    if (accepted.isEmpty) {
      if (targets.isNotEmpty) {
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
        if (accepted.contains(target.id)) target,
    ];
    if (!await _acquireSessions(unit, publishing)) {
      showActions(targets, publicActions);
      return ExitCodes.refused;
    }
    final releaseProgress = TargetReleaseProgress(
      output,
      title: '${unit.name} ${unit.version} · releasing',
      targets: targets,
    );
    for (final target in targets.where(
      (target) => !accepted.contains(target.id),
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
      dependenciesOf: (step) => [for (final need in step.needs) need.id],
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
        for (final target in ready.whereType<Target>()) {
          if (!activeTargets.add(target.target)) continue;
          active[target.id] = _publishPublicTarget(
            target: target,
            plan: plan,
            releaseProgress: releaseProgress,
          );
        }
      }

      _describePublicationWaits(
        graph: graph,
        completed: completed,
        active: active.keys.toSet(),
        activeTargets: activeTargets,
        authorizedStepIds: accepted,
        progress: releaseProgress,
      );

      if (active.isEmpty) {
        if (failures.isNotEmpty) break;
        final unresolved = targets
            .where((target) => !completed.contains(target.id))
            .map((target) => target.id)
            .join(', ');
        throw StateError('publication graph made no progress: $unresolved');
      }

      final completion = await Future.any(active.values);
      active.remove(completion.target.id);
      activeTargets.remove(completion.target.target);
      if (completion.failure case final failure?) {
        failures.add(failure);
      } else {
        completed.add(completion.target.id);
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
    return ExitCodes.ok;
  }

  /// Signs in once per target for the run, after the yes and before the
  /// first act that needs it: pub.dev and GitHub have native sessions.
  Future<bool> _acquireSessions(
    ResolvedUnit unit,
    List<Target> publishing,
  ) async {
    final byTarget = <PublishTarget, List<Target>>{};
    for (final target in publishing) {
      if (target.target != PublishTarget.pubDev &&
          target.target != PublishTarget.githubRelease) {
        continue;
      }
      if (_signedIn.contains(target.target)) continue;
      (byTarget[target.target] ??= []).add(target);
    }
    if (byTarget.isEmpty) return true;
    final progress = TargetReleaseProgress(
      output,
      title: '${unit.name} ${unit.version} · preparing release',
      targets: [for (final grouped in byTarget.values) ...grouped],
    );
    final environment = refreshEnvironment();
    for (final MapEntry(key: kind, value: grouped) in byTarget.entries) {
      for (final target in grouped) {
        progress.begin(target, CommonProgressActivities.checkingSignIn);
      }
      final signedIn = await inspector.targets
          .moduleFor(kind)
          .ready(
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
            signIn: true,
          );
      if (signedIn.problem case final problem?) {
        progress
          ..failAll(grouped, activity: CommonProgressActivities.checkingSignIn)
          ..notAttemptedPending()
          ..settle();
        output.problem(problem, unit: unit.name);
        output.halt(HaltKind.beforeActing);
        return false;
      }
      _signedIn.add(kind);
      for (final target in grouped) {
        progress.complete(target, note: signedIn.note);
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
    required TargetReleaseProgress progress,
  }) {
    for (final target in graph.values.whereType<Target>().where(
      (target) =>
          authorizedStepIds.contains(target.id) &&
          !completed.contains(target.id) &&
          !active.contains(target.id),
    )) {
      final blockers = graph
          .unmet(target, completed)
          .map((id) => graph[id])
          .whereType<Target>()
          .map((dependency) => dependency.label)
          .toSet();
      final note = blockers.isNotEmpty
          ? 'waiting for ${blockers.join(', ')}'
          : activeTargets.contains(target.target)
          // One publish at a time to a destination: another is under way.
          ? 'waiting its turn at ${target.kindLabel}'
          : null;
      if (note != null) progress.waiting(target, note: note);
    }
  }

  Future<_PublicTargetCompletion> _publishPublicTarget({
    required Target target,
    required PublicationPlan plan,
    required TargetReleaseProgress releaseProgress,
  }) async {
    final PublicationPlan(
      :unit,
      actions: publicActions,
      :stage,
      :recoversWithoutStage,
    ) = plan;
    // What the act publishes from: the complete stage, or nothing when
    // what is left finishes from public inputs alone.
    final staged = recoversWithoutStage ? null : stage;
    final module = inspector.targets.moduleFor(target.target);
    releaseProgress.begin(target, CommonProgressActivities.checking);
    // The target is read again right before its act: another run or person
    // may have published it since the snapshot.
    var state = await inspector.inspect(target, unit, stage: staged);
    output.step(
      target,
      verdict: state.verdict,
      detail: state.detail,
      evidence: state.evidence,
      action: publicActions[target.id]!.wire,
      show: false,
    );
    if (state.isExact) {
      _completeExistingTarget(target, state, publicActions, releaseProgress);
      return _PublicTargetCompletion.completed(target);
    }
    if (!state.isAbsent) {
      releaseProgress.fail(target, activity: CommonProgressActivities.checking);
      return _PublicTargetCompletion.failed(
        target,
        _refusal(target, unit, state, acted: output.report.actedPublicly),
      );
    }
    final halt = output.report.actedPublicly
        ? HaltKind.stoppedPartway
        : HaltKind.beforeActing;
    if (recoversWithoutStage && !state.recoversWithoutStage) {
      releaseProgress.fail(target, activity: CommonProgressActivities.checking);
      return _PublicTargetCompletion.failed(
        target,
        _PublicationFailure(
          step: target,
          diagnostics: [
            Diagnostic(
              code: 'RK-STAGE-005',
              message:
                  '${target.summary} can no longer recover without its '
                  'stage',
              remedy:
                  'its public inputs changed. Re-run so rk can inspect the '
                  'release again; restore ${stage.path} if the '
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
      final checked = stage.check(plan.release);
      if (!checked.reusable) {
        releaseProgress.fail(
          target,
          activity: CommonProgressActivities.checking,
        );
        return _PublicTargetCompletion.failed(
          target,
          _PublicationFailure(
            step: target,
            diagnostics: [
              Diagnostic(
                code: 'RK-STAGE-002',
                message:
                    'the reviewed release stage changed before '
                    '${target.summary}',
                remedy:
                    '${checked.lines.join('\n')}\n'
                    'rebuild it explicitly: rk stage ${unit.name}',
              ),
            ],
            halt: halt,
          ),
        );
      }
    }

    final actedBefore = output.report.actedPublicly;
    output.report
      ..acted = true
      ..actedPublicly = true;
    final releaseContext = TargetReleaseContext(
      reads: inspector.targetReads,
      tools: tools,
      stage: staged,
      progress: releaseProgress.handle(target),
      runInteractive: allowInteractiveTools
          ? releaseProgress.interactive(tools)
          : null,
      wait: wait,
      confirmDeadline: confirmDeadline,
      confirmInterval: confirmInterval,
    );
    final mutationActivity = _acting(target.target);
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

    // A process result is not public truth unless the provider's answer is
    // the read-back. Every started operation is read back even if another
    // concurrent lane has failed.
    releaseProgress.begin(target, CommonProgressActivities.verifying);
    try {
      state =
          act.confirmed ??
          await module.confirm(releaseContext, unit, target, act);
    } on Object catch (error) {
      state = Inspection.unknown(
        '${target.kindLabel} verification threw: $error',
      );
    }
    publicActions[target.id] = state.isExact
        ? ReleaseAction.completed
        : ReleaseAction.failed;
    output.step(
      target,
      verdict: state.verdict,
      detail: state.detail,
      evidence: state.evidence,
      action: publicActions[target.id]!.wire,
      show: false,
    );
    if (!act.ok && state.isExact) {
      final inspected = act.includeInspectionDetail && state.detail != null
          ? ' · ${state.detail}'
          : '';
      final note =
          '${act.reconciledNote ?? 'command response was lost · public target confirmed exact'}$inspected';
      releaseProgress.complete(target, note: note);
      return _PublicTargetCompletion.completed(target);
    }
    if (!act.ok || !state.isExact) {
      releaseProgress.fail(
        target,
        // A refused act failed where it acted; one that may have landed
        // failed where it was read back.
        activity:
            !act.ok &&
                !act.mayHaveActed &&
                (state.isAbsent || state.verdict == Verdict.conflict)
            ? lastMutationActivity
            : CommonProgressActivities.verifying,
      );
      return _PublicTargetCompletion.failed(
        target,
        _unconfirmed(unit, target, state, act, actedBefore: actedBefore),
      );
    }

    final note = [
      ?act.successNote,
      if (act.includeInspectionDetail) ?state.detail,
    ].join(' · ');
    releaseProgress.complete(target, note: note.isEmpty ? 'published' : note);
    return _PublicTargetCompletion.completed(target);
  }

  /// What an act that did not settle exact means: the halt and the
  /// diagnostic, in [target]'s words.
  _PublicationFailure _unconfirmed(
    ResolvedUnit unit,
    Target target,
    Inspection state,
    TargetActOutcome act, {
    required bool actedBefore,
  }) {
    final module = inspector.targets.moduleFor(target.target);
    final conflict = state.verdict == Verdict.conflict;
    // The provider refused the act because a permanent target was already
    // something else: the conflict a fresh inspection would have found, with
    // the same advice.
    if (conflict && !target.moving && !act.ok && !act.mayHaveActed) {
      final advice = module.explain(unit, target, state).diagnostic;
      return _PublicationFailure(
        step: target,
        diagnostics: [
          Diagnostic(
            code: advice.code,
            message: advice.message,
            source: advice.source,
            remedy: [?advice.remedy, ?act.problem].join('\n'),
            evidence: act.evidence ?? act.diagnostic?.evidence,
          ),
        ],
        halt: actedBefore
            ? HaltKind.actedAndUnfixable
            : HaltKind.unfixableByRerun,
      );
    }
    final given = act.diagnostic;
    final named = given == null || conflict
        ? module.explain(unit, target, state, acted: act)
        : (diagnostic: given, next: null);
    final details = [
      ?given?.remedy,
      ?act.problem,
      ?act.privateEffectDetail,
      if (act.privateEffectDetail == null &&
          act.privateEffect == TargetPrivateEffect.changed)
        'private provider state changed; this step did not confirm a public '
            'release.',
      if (act.privateEffectDetail == null &&
          act.privateEffect == TargetPrivateEffect.uncertain)
        'private provider state may have changed; no public release was '
            'confirmed.',
      ?state.detail,
      ...state.evidence.entries.map((entry) => '${entry.key}: ${entry.value}'),
    ];
    return _PublicationFailure(
      step: target,
      diagnostics: [
        Diagnostic(
          code: named.diagnostic.code,
          message: named.diagnostic.message,
          remedy: details.isEmpty
              ? 're-run; the shared destination inspection will classify the '
                    'public target before any retry'
              : details.join('\n'),
          evidence: act.evidence ?? given?.evidence,
        ),
      ],
      halt: conflict
          ? (target.moving
                ? HaltKind.stoppedPartway
                : HaltKind.actedAndUnfixable)
          : act.mayHaveActed ||
                act.privateEffect == TargetPrivateEffect.uncertain ||
                state.verdict == Verdict.unknown
          ? HaltKind.lostTrack
          : act.privateEffect == TargetPrivateEffect.changed || actedBefore
          ? HaltKind.stoppedPartway
          : HaltKind.beforeActing,
      nextCommand: named.next,
    );
  }

  /// What a target's row says while rk acts on it.
  static ProgressActivity _acting(PublishTarget target) => switch (target) {
    PublishTarget.gitTag => ProgressActivity(
      running: 'creating',
      failed: 'tag creation failed',
    ),
    PublishTarget.pubDev => ProgressActivity(
      running: 'publishing',
      failed: 'publish failed',
    ),
    PublishTarget.githubRelease => ProgressActivity(
      running: 'drafting',
      failed: 'draft failed',
    ),
    PublishTarget.homebrew => ProgressActivity(
      running: 'updating',
      failed: 'update failed',
    ),
  };

  void _completeExistingTarget(
    Target target,
    Inspection state,
    Map<String, ReleaseAction> actions,
    TargetReleaseProgress progress,
  ) {
    actions[target.id] = ReleaseAction.alreadyPublished;
    progress.complete(target, note: 'already published', satisfied: true);
    output.step(
      target,
      mark: Mark.satisfied,
      verdict: state.verdict,
      note: state.detail ?? 'already done',
      action: actions[target.id]!.wire,
      show: false,
    );
  }

  /// A read that found something other than the release missing: a
  /// conflict carries the target's own advice; anything else says what was
  /// read. [acted] is whether this run has already changed something public.
  _PublicationFailure _refusal(
    Step step,
    ResolvedUnit unit,
    Inspection state, {
    required bool acted,
  }) {
    final conflict = state.verdict == Verdict.conflict;
    return _PublicationFailure(
      step: step,
      diagnostics: [
        if (conflict && step is Target)
          inspector.targets
              .moduleFor(step.target)
              .explain(unit, step, state)
              .diagnostic
        else
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
      halt: conflict
          ? (acted ? HaltKind.actedAndUnfixable : HaltKind.unfixableByRerun)
          : (acted ? HaltKind.stoppedPartway : HaltKind.beforeActing),
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

  HaltKind _strongerHalt(HaltKind left, HaltKind right) =>
      left.index >= right.index ? left : right;

  /// The platforms [plan]'s stage built and could not run, from what its
  /// receipt records: a reused stage may have been smoke-tested elsewhere.
  List<({String platform, String reason})> _unprovable(PublicationPlan plan) {
    final checked = plan.stage.check(plan.release);
    if (!checked.reusable) return const [];
    return [
      for (final work in plan.release.work)
        if (work.kind == StepKind.build)
          if (checked.receipt!.producers[work.name]?['smoke'] case {
            'status': 'not-executed',
            'reason': final String reason,
          } when reason.isNotEmpty)
            (platform: work.platform!, reason: reason),
    ];
  }

  /// A row for each of [remaining], saying which are permanent and which
  /// claim a name for the first time.
  void showTargets(List<Target> remaining, List<TargetClaim> claims) {
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
  String targetNote(Target target, List<TargetClaim> claims) =>
      [target.planNote, ..._marks(target, claims)].join(' · ');

  // Keyed by what is claimed, not by where: a unit publishing several
  // packages to pub.dev has one row each, and marking them all because one
  // name is new would tell the operator they are permanently taking names
  // that were taken releases ago.
  static List<String> _marks(Target target, List<TargetClaim> claims) => [
    if (target.isPermanent) 'permanent',
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
    List<Target> remaining,
    List<TargetClaim> claims, {
    ReleaseSigningContext? firstSigning,
    bool firstStep = true,
  }) {
    final permanent = [
      for (final target in remaining)
        if (target.isPermanent) target,
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
                'permanent step is: ${permanent.first.summary}.',
        ].join('\n'),
      ..._recordClaims(claims, firstSigning),
    ];
  }

  void _showAuthorization(
    ResolvedUnit unit,
    List<Target> remaining, {
    required List<({String platform, String reason})> unprovable,
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
    // its durable record.
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
  const _PublicTargetCompletion.completed(this.target) : failure = null;

  const _PublicTargetCompletion.failed(this.target, this.failure);

  final Target target;
  final _PublicationFailure? failure;
}

final class _PublicationFailure {
  const _PublicationFailure({
    required this.step,
    required this.diagnostics,
    required this.halt,
    this.nextCommand,
  });

  final Step step;
  final List<Diagnostic> diagnostics;
  final HaltKind halt;
  final String? nextCommand;

  bool get rerunHelps =>
      halt != HaltKind.unfixableByRerun && halt != HaltKind.actedAndUnfixable;
}
