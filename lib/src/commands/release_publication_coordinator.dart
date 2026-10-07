import 'dart:convert';

import '../engine/canonical_json.dart';
import '../engine/checklist.dart';
import '../engine/dependency_graph.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/inspect.dart';
import '../engine/native_publication.dart';
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
import '../transforms/digest.dart';
import 'release_preparation.dart';
import 'release_progress.dart';
import 'release_stage_coordinator.dart';

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
    this.preparedNoop = false,
    Map<String, NativePublicationCheck> nativeChecks = const {},
  }) : nativeChecks = Map.unmodifiable(nativeChecks),
       steps = List.unmodifiable(steps),
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

  /// Preparation proved every public target exact; this plan cannot gain work.
  final bool preparedNoop;
  final Map<String, NativePublicationCheck> nativeChecks;
}

/// What one yes, asked before a repository release's first unit acted,
/// accepted: unit by unit, the targets each was to publish and the names
/// each was to claim for the first time.
final class RunConsent {
  RunConsent._reviewed(
    List<_PublicationReview> reviews,
    Map<String, String> inputs,
  ) : _targets = Map.unmodifiable({
        for (final review in reviews)
          review.plan.unit.name: Set<String>.unmodifiable(
            review.remaining.map((step) => step.id),
          ),
      }),
      _claims = Map.unmodifiable({
        for (final review in reviews)
          review.plan.unit.name: Set<(String, String)>.unmodifiable(
            review.claims.map((claim) => (claim.registrar, claim.name)),
          ),
      }),
      _inputs = Map.unmodifiable(inputs),
      _omitted = List.unmodifiable(reviews.expand((review) => review.omitted)),
      _preparedReviews = List.unmodifiable(
        reviews.where(
          (review) =>
              review.remaining.isNotEmpty || review.plan.publicSteps.isEmpty,
        ),
      ),
      _recoveryBindings = Map.unmodifiable({
        for (final review in reviews)
          review.plan.unit.name: Map<String, String>.unmodifiable(
            review.recoveryBindings,
          ),
      }),
      _targetFacts = Map.unmodifiable({
        for (final review in reviews)
          review.plan.unit.name: Map<String, String>.unmodifiable({
            for (final target in review.remainingTargets)
              target.step.id: _targetDisclosure(target),
          }),
      }),
      _claimFacts = Map.unmodifiable({
        for (final review in reviews)
          review.plan.unit.name: Map<(String, String), String>.unmodifiable({
            for (final claim in review.claims)
              (claim.registrar, claim.name): claim.consequence,
          }),
      });

  final Map<String, Set<String>> _targets;
  final Map<String, Set<(String, String)>> _claims;
  final Map<String, String> _inputs;
  final List<_OmittedTarget> _omitted;
  final List<_PublicationReview> _preparedReviews;
  final Map<String, Map<String, String>> _recoveryBindings;
  final Map<String, Map<String, String>> _targetFacts;
  final Map<String, Map<(String, String), String>> _claimFacts;

  bool recoveryStillMatches(String unit, Map<String, String> bindings) =>
      bindings.entries.every(
        (entry) => _recoveryBindings[unit]?[entry.key] == entry.value,
      );

  /// What [unit] is about to do that the yes did not accept. Empty when it
  /// accepted all of it.
  List<String> unshown(
    ResolvedUnit unit,
    Iterable<TargetPlan> remaining,
    Iterable<TargetClaim> claims, {
    String? inputs,
  }) {
    // A unit with nothing to publish when the question was asked accepted
    // none of what it now would.
    final targets = _targets[unit.name] ?? const {};
    final named = _claims[unit.name] ?? const {};
    return [
      for (final target in remaining)
        if (!targets.contains(target.step.id) ||
            _targetFacts[unit.name]?[target.step.id] !=
                _targetDisclosure(target))
          target.label,
      for (final claim in claims)
        if (!named.contains((claim.registrar, claim.name)) ||
            _claimFacts[unit.name]?[(claim.registrar, claim.name)] !=
                claim.consequence)
          'the first claim of ${claim.name} on ${claim.registrar}',
      if (_inputs[unit.name] != inputs)
        'its reviewed staged inputs or disclosures',
    ];
  }
}

String _targetDisclosure(TargetPlan target) => CanonicalJson.encode({
  'id': target.step.id,
  'coordinate': target.coordinate,
  'version': target.targetVersion,
  'kind': target.kind,
  'note': target.planNote,
  'permanence': target.permanenceNotice,
});

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

  /// The yes a repository release asked for before its first unit acted,
  /// when it asked one.
  RunConsent? runConsent;

  // Observation of scope shrinking is separate from immutable consent. A unit
  // proved entirely public no longer needs private bytes, but its destinations
  // join the global omission checks before any later session or public act.
  final Set<String> _completedReviewUnits = {};
  GitState? _reviewedScopeGit;

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
      delay: briefPhase,
    );
    final context = TargetReadinessContext(
      tools: tools,
      git: initialGit,
      environment: refreshEnvironment(),
    );
    final outstanding = targets
        .where((target) => !states[target.step.id]!.isExact)
        .toList();
    final bindings = <String, String>{};
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
        bindings[target.step.id] = module.destinationBinding(context, unit, [
          target,
        ]);
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
        note = await provider.restore(
          TargetReadinessContext(
            tools: tools,
            git: await refreshGit(),
            environment: refreshEnvironment(),
          ),
        );
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

  /// Reviews the completed private scope before asking once. No session is
  /// acquired here. The same confirm callback handles interactive and --yes
  /// invocations, and the resulting consent cannot grow during publication.
  Future<bool> authorizeRepository(List<PublicationPlan> plans) async {
    if (plans.isEmpty) return true;
    if (_createdSessions.isNotEmpty ||
        plans.any(
          (plan) => plan.actions.values.any(
            (action) =>
                action == ReleaseAction.attempted ||
                action == ReleaseAction.completed,
          ),
        ) ||
        plans.map((plan) => plan.unit.name).toSet().length != plans.length) {
      throw StateError(
        'repository authorization needs an unacted unique scope',
      );
    }
    final reviews = <_PublicationReview>[];
    for (final plan in plans) {
      final review = await _reviewForConsent(plan);
      if (review == null) return false;
      reviews.add(review);
    }
    final asking = reviews
        .where((review) => review.remaining.isNotEmpty)
        .toList();
    for (final review in asking) {
      _showAuthorization(
        review.plan.unit,
        review.remainingTargets,
        stage: review.plan.stage,
        signing: review.plan.prepared.signing,
        claims: review.claims,
      );
    }
    final checked = reviews.where(
      (review) =>
          review.remaining.isNotEmpty || review.plan.publicSteps.isEmpty,
    );
    // A later unit's slow review may invalidate an earlier unit. Recheck all
    // contexts, then all local identities/bytes/endpoints synchronously after
    // the last await, before capturing what the confirmation will accept.
    for (final review in checked) {
      final plan = review.plan;
      if (!plan.recoversWithoutStage &&
          !await stages.signingStillValid(plan.unit, plan.prepared)) {
        return false;
      }
      if (!await stages.contextStillValid(
        plan.stage,
        plan.unit,
        changed: 'before repository authorization',
        halt: HaltKind.beforeActing,
      )) {
        return false;
      }
    }
    if (!await _omittedTargetsStillExact(
      reviews.expand((review) => review.omitted),
      beforeAuthorization: true,
    )) {
      return false;
    }
    final GitState finalGit;
    try {
      finalGit = await refreshGit();
    } on Object catch (error) {
      _reviewChanged('$error');
      return false;
    }
    for (final review in checked) {
      final plan = review.plan;
      if ((finalGit.isBound && !finalGit.isClean) ||
          (plan.unit.publish.contains(PublishTarget.gitTag) &&
              !finalGit.headIsPushed)) {
        _reviewChanged(
          '${plan.unit.name}: the repository is no longer clean and publishable',
        );
        return false;
      }
      try {
        final current = stages.refreshStage(plan.unit, finalGit);
        if (current.directory.identity.id != plan.stage.directory.identity.id) {
          throw StateError('${plan.unit.name}: the release context changed');
        }
      } on Object catch (error) {
        _reviewChanged('$error');
        return false;
      }
      if (!plan.recoversWithoutStage &&
          !stages.stageStillValid(
            plan.stage,
            plan.unit,
            changed: 'before repository authorization',
            halt: HaltKind.beforeActing,
          )) {
        return false;
      }
      if (!_endpointsStillMatch(review, finalGit)) return false;
    }
    final consent = RunConsent._reviewed(reviews, {
      for (final review in reviews)
        review.plan.unit.name: _authorizationInputs(
          review.plan.stage,
          review.plan.prepared.signing,
        ),
    });
    if (asking.isEmpty) {
      runConsent = consent;
      _completedReviewUnits.clear();
      _reviewedScopeGit = null;
      return true;
    }
    if (!requireAuthorizer(asking.first.plan.unit)) return false;
    final names = [
      for (final review in asking)
        '${review.plan.unit.name} ${review.plan.unit.version}',
    ];
    final series = names.length <= 2
        ? names.join(' and ')
        : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
    output.report.attach(
      'authorization-disclosures/run',
      [
        'Private preparation completed for the selected release scope.',
        for (final review in asking)
          [
            '${review.plan.unit.name} ${review.plan.unit.version}',
            'stage ${review.plan.stage.directory.identity.id}',
            if (review.recoveryBindings.isNotEmpty)
              'public recovery ${CanonicalJson.encode(review.recoveryBindings)}',
            ...review.remainingTargets.map(
              (target) =>
                  '  ${target.kindLabel}: ${targetNote(target, review.claims)}',
            ),
            output
                    .report
                    .attachments['authorization-disclosures/${review.plan.unit.name}'] ??
                '',
            CanonicalJson.encode(
              output.report.warningEvidenceFor(review.plan.unit.name),
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
    runConsent = consent;
    _completedReviewUnits.clear();
    _reviewedScopeGit = null;
    output.blank();
    return true;
  }

  void _reviewChanged(String detail) {
    output.problem(
      Diagnostic(
        code: 'RK-STAGE-004',
        message: 'the release context changed before repository authorization',
        remedy:
            'inspect the changed inputs, then prepare and review the release again',
        evidence: detail,
      ),
    );
    output.halt(HaltKind.beforeActing);
  }

  Future<_PublicationReview?> _reviewForConsent(PublicationPlan plan) async {
    final unit = plan.unit;
    final gate = PublicReleaseGate(inspector);
    Future<({List<Step> remaining, List<TargetClaim> claims})?> read() =>
        _refreshPublicGate(
          gate: gate,
          unit: unit,
          publicSteps: plan.publicSteps,
          targets: plan.targets,
          states: plan.states,
          actions: plan.actions,
        );
    var snapshot = await read();
    if (snapshot == null) return null;
    if (plan.preparedNoop && snapshot.remaining.isNotEmpty) {
      final step = snapshot.remaining.first;
      _haltForAuthorizationGrowth(
        step,
        plan.states[step.id]!,
        unit,
        plan.targets,
        plan.actions,
        beforeAuthorization: runConsent == null,
      );
      return null;
    }
    if (snapshot.remaining.isEmpty && plan.publicSteps.isNotEmpty) {
      return _PublicationReview(
        plan,
        snapshot.remaining,
        snapshot.claims,
        const {},
      );
    }
    final endpoints = await prepareDestinations(
      unit: unit,
      targets: plan.targets,
      states: plan.states,
      actions: plan.actions,
      stageOnly: false,
    );
    if (endpoints == null) return null;
    for (final target in plan.targets.where(
      (target) => endpoints.containsKey(target.step.id),
    )) {
      if (endpoints[target.step.id] != plan.endpointBaselines[target.step.id]) {
        _destinationChanged(target.target, plan.targets, plan.actions);
        return null;
      }
    }
    final progress = output.progressBoard(
      '${unit.name} ${unit.version} · preparing release',
      emitSlowToNonTerminal: true,
    );
    final row = progress.addRow(
      id: '${unit.name}/release-inputs',
      label: 'Release inputs',
      coordinate: 'targets · signing · staged bytes',
    );
    row.handle.begin(CommonProgressActivities.checking);
    try {
      if (!plan.recoversWithoutStage &&
          !await stages.signingStillValid(unit, plan.prepared)) {
        return null;
      }
      if (!await stages.contextStillValid(
        plan.stage,
        unit,
        changed: 'before authorization',
        halt: HaltKind.beforeActing,
      )) {
        return null;
      }
      if (!plan.recoversWithoutStage &&
          !stages.stageStillValid(
            plan.stage,
            unit,
            changed: 'before authorization',
            halt: HaltKind.beforeActing,
          )) {
        return null;
      }
      snapshot = await read();
      if (snapshot == null) return null;
      final recovery = <String, String>{};
      final byId = {for (final target in plan.targets) target.step.id: target};
      for (final step in snapshot.remaining) {
        final target = byId[step.id]!;
        if (!endpoints.containsKey(step.id)) {
          _destinationChanged(target.target, plan.targets, plan.actions);
          return null;
        }
        if (!plan.recoversWithoutStage) continue;
        final binding = inspector.targets
            .moduleForTarget(target)
            .stageRecoveryBinding(plan.states[step.id]!);
        if (binding == null) {
          output.problem(
            Diagnostic(
              code: 'RK-STAGE-005',
              message:
                  '${target.step.summary} can no longer recover without its stage',
              remedy:
                  'public inputs changed before authorization; re-run to inspect the release and restore ${plan.stage.directory.path} if its original bytes remain necessary',
            ),
          );
          output.halt(HaltKind.beforeActing);
          showActions(plan.targets, plan.actions);
          return null;
        }
        recovery[step.id] = binding;
      }
      row.complete(note: 'checked');
      return _PublicationReview(
        plan,
        snapshot.remaining,
        snapshot.claims,
        recovery,
      );
    } finally {
      if (output.report.halted) {
        progress.conclude();
      } else {
        progress.discard();
      }
    }
  }

  bool _endpointsStillMatch(_PublicationReview review, GitState git) {
    final plan = review.plan;
    final context = TargetReadinessContext(
      tools: tools,
      git: git,
      environment: refreshEnvironment(),
    );
    for (final target in review.remainingTargets) {
      final current = inspector.targets
          .moduleForTarget(target)
          .destinationBinding(context, plan.unit, [target]);
      if (current != plan.endpointBaselines[target.step.id]) {
        _destinationChanged(target.target, plan.targets, plan.actions);
        return false;
      }
    }
    return true;
  }

  String _authorizationInputs(
    ReleaseStage stage,
    ReleaseSigningContext? signing,
  ) => Sha256.hex(
    utf8.encode(
      CanonicalJson.encode({
        'stage': stage.directory.identity.id,
        'receipt': stage.inspect().receipt?.encode(),
        'signing': signing == null
            ? null
            : {
                'requirement': signing.publishedRequirement,
                'first': signing.firstIdentity,
                'certificate': signing.certificateName,
                'code_id': signing.codeId,
                'certificate_sha256': signing.certificateSha256,
                'designated_requirement': signing.designatedRequirement,
              },
        'warnings': output.report.warningEvidenceFor(stage.unit.name),
      }),
    ),
  );

  bool _repositoryConsentStillValid(_PublicationReview review) {
    final consent = runConsent;
    if (consent == null) return true;
    if (!consent.recoveryStillMatches(
      review.plan.unit.name,
      review.recoveryBindings,
    )) {
      output.problem(
        Diagnostic(
          code: 'RK-STAGE-005',
          message: 'public recovery inputs changed after authorization',
          remedy:
              'inspect the changed public inputs and review a fresh release; '
              'the previous confirmation does not authorize replacement bytes',
        ),
        unit: review.plan.unit.name,
      );
      output.halt(
        output.report.acted ? HaltKind.stoppedPartway : HaltKind.beforeActing,
      );
      showActions(review.plan.targets, review.plan.actions);
      return false;
    }
    final changed = consent.unshown(
      review.plan.unit,
      review.remainingTargets,
      review.claims,
      inputs: _authorizationInputs(
        review.plan.stage,
        review.plan.prepared.signing,
      ),
    );
    if (changed.isEmpty) return true;
    _refuseChangedConsent(review.plan.unit, changed);
    showActions(review.plan.targets, review.plan.actions);
    return false;
  }

  void _refuseChangedConsent(ResolvedUnit unit, List<String> changed) {
    output.problem(
      Diagnostic(
        code: 'RK-AUTH-003',
        message: 'the reviewed release changed after authorization',
        remedy:
            'review a fresh plan; the previous confirmation did not accept ${changed.join(', ')}',
      ),
      unit: unit.name,
    );
    output.halt(
      output.report.acted ? HaltKind.stoppedPartway : HaltKind.beforeActing,
    );
  }

  Future<bool> _omittedTargetsStillExact(
    Iterable<_OmittedTarget> omitted, {
    bool beforeAuthorization = false,
  }) async {
    for (final entry in omitted) {
      // Refresh native registry caches before the exact read. A previous
      // exact observation is not current evidence after a later unit awaits.
      final problems = Diagnostics();
      await inspector.releaseMonotonicity(
        entry.plan.unit,
        [entry.target],
        problems,
        refreshRegistry: true,
      );
      final state = await inspector.inspect(entry.target.step, entry.plan.unit);
      if (!state.isExact) {
        _haltForAuthorizationGrowth(
          entry.target.step,
          state,
          entry.plan.unit,
          entry.plan.targets,
          entry.plan.actions,
          beforeAuthorization: beforeAuthorization,
        );
        return false;
      }
      if (problems.isNotEmpty) {
        output.problems(problems.found);
        output.halt(
          output.report.acted ? HaltKind.stoppedPartway : HaltKind.beforeActing,
        );
        return false;
      }
    }
    return true;
  }

  Iterable<_PublicationReview> get _pendingReviews =>
      (runConsent?._preparedReviews ?? const <_PublicationReview>[]).where(
        (review) => !_completedReviewUnits.contains(review.plan.unit.name),
      );

  Future<bool> _reviewBecamePublic(_PublicationReview review) async {
    final plan = review.plan;
    if (plan.publicSteps.isEmpty) return false;
    final snapshot = await PublicReleaseGate(
      inspector,
    ).refresh(unit: plan.unit, steps: plan.publicSteps, targets: plan.targets);
    if (snapshot.monotonicityProblems.isNotEmpty ||
        snapshot.states.values.any((state) => !state.isExact)) {
      return false;
    }
    _completedReviewUnits.add(plan.unit.name);
    return true;
  }

  /// Cheap local checks after the last awaited provider read. A different valid
  /// receipt is still different consent; mere stage validity is insufficient.
  bool _repositoryInputsStillValid() {
    final halt = output.report.acted
        ? HaltKind.stoppedPartway
        : HaltKind.beforeActing;
    for (final review in _pendingReviews) {
      final plan = review.plan;
      final currentGit = _reviewedScopeGit;
      if (currentGit != null) {
        try {
          if ((currentGit.isBound && !currentGit.isClean) ||
              (plan.unit.publish.contains(PublishTarget.gitTag) &&
                  !currentGit.headIsPushed) ||
              stages
                      .refreshStage(plan.unit, currentGit)
                      .directory
                      .identity
                      .id !=
                  plan.stage.directory.identity.id) {
            throw StateError(
              '${plan.unit.name}: the reviewed release context changed',
            );
          }
        } on Object catch (error) {
          _reviewChanged('$error');
          return false;
        }
        if (!_endpointsStillMatch(review, currentGit)) return false;
      }
      if ((!plan.recoversWithoutStage &&
              !stages.stageStillValid(
                plan.stage,
                plan.unit,
                changed: 'after repository authorization',
                halt: halt,
              )) ||
          !_repositoryConsentStillValid(review)) {
        return false;
      }
    }
    return true;
  }

  Future<bool> _repositoryScopeStillValid() async {
    final consent = runConsent;
    if (!await _omittedTargetsStillExact([
      ...?consent?._omitted,
      for (final review
          in consent?._preparedReviews ?? const <_PublicationReview>[])
        if (_completedReviewUnits.contains(review.plan.unit.name))
          for (final target in review.plan.targets)
            _OmittedTarget(review.plan, target),
    ])) {
      return false;
    }
    final pending = _pendingReviews.toList();
    if (pending.isEmpty) return true;
    // If private inputs changed, first allow the work to shrink when all of
    // this unit's public targets have independently completed. Otherwise every
    // selected pending unit remains part of the reviewed private scope.
    for (final review in pending) {
      final plan = review.plan;
      final inputsChanged =
          consent!._inputs[plan.unit.name] !=
          _authorizationInputs(plan.stage, plan.prepared.signing);
      if ((inputsChanged ||
              (!plan.recoversWithoutStage && !plan.stage.inspect().reusable)) &&
          await _reviewBecamePublic(review)) {
        continue;
      }
      if (!plan.recoversWithoutStage &&
          !await stages.signingStillValid(plan.unit, plan.prepared)) {
        return false;
      }
      if (!await stages.contextStillValid(
        plan.stage,
        plan.unit,
        changed: 'after repository authorization',
        halt: output.report.acted
            ? HaltKind.stoppedPartway
            : HaltKind.beforeActing,
      )) {
        return false;
      }
    }
    final GitState currentGit;
    try {
      currentGit = await refreshGit();
    } on Object catch (error) {
      _reviewChanged('$error');
      return false;
    }
    // Re-read synchronous identities, endpoints and bytes after the last await.
    // Artifact digests are reused only while file metadata remains unchanged.
    // No native discovery or public dependency solving is repeated here.
    _reviewedScopeGit = currentGit;
    return _repositoryInputsStillValid();
  }

  Future<int> publish(PublicationPlan plan) async {
    final unit = plan.unit;
    final publicSteps = plan.publicSteps;
    final targets = plan.targets;
    final endpointBaselines = plan.endpointBaselines;
    final publicActions = plan.actions;
    final prepared = plan.prepared;
    final stage = plan.stage;
    final recoversWithoutStage = plan.recoversWithoutStage;
    final targetByStep = {for (final target in targets) target.step.id: target};

    final review = await _reviewForConsent(plan);
    if (review == null) return ExitCodes.refused;
    final remaining = review.remaining;
    if (!await _repositoryScopeStillValid()) return ExitCodes.refused;
    if (remaining.isEmpty) {
      if (plan.publicSteps.isEmpty) return ExitCodes.ok;
      output.line(
        '${unit.name} ${unit.version}',
        mark: Mark.satisfied,
        note: 'already released',
      );
      await verifyAvailability(unit: unit, targets: targets);
      return ExitCodes.ok;
    }
    if (!_repositoryConsentStillValid(review)) return ExitCodes.refused;
    final remainingTargets = review.remainingTargets;
    final recoveryBindings = review.recoveryBindings;
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
      sessionProgress.begin(target, CommonProgressActivities.checking);
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
        runInteractive: allowInteractiveTools
            ? sessionProgress.interactive(tools)
            : null,
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
      if (!await _repositoryScopeStillValid()) {
        sessionProgress
          ..failAll(grouped, activity: requirement.provider.activity)
          ..notAttemptedPending()
          ..settle();
        return ExitCodes.refused;
      }
      final acquired = await requirement.provider.acquire(
        before,
        unit,
        grouped,
      );
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
      // The freshest read of what this release would claim first: the one
      // the question asked before any unit acted may be older.
      claims: review.claims,
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
    for (final step in publicSteps.where(
      (step) => !authorizedStepIds.contains(step.id),
    )) {
      final state = await inspector.inspect(step, unit);
      if (!state.isExact) {
        _haltForAuthorizationGrowth(step, state, unit, targets, publicActions);
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
            nativeCheck: plan.nativeChecks[step.id],
            signing: prepared.signing,
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
            failures.add(
              _PublicationFailure(
                step: omitted,
                diagnostics: [
                  Diagnostic(
                    code: 'RK-AUTH-003',
                    message: 'the release plan grew after authorization',
                    remedy:
                        '${omitted.summary} was not work when the plan was '
                        'shown. RK will not add it after the yes; inspect the '
                        'changed destination and authorize a fresh plan.',
                  ),
                ],
                halt: HaltKind.stoppedPartway,
              ),
            );
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
    await verifyAvailability(unit: unit, targets: targets);
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
    ReleaseSigningContext? signing,
    NativePublicationCheck? nativeCheck,
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
      releaseProgress.fail(target, activity: CommonProgressActivities.checking);
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
      releaseProgress.fail(target, activity: CommonProgressActivities.checking);
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

    final consent = runConsent;
    if (consent != null) {
      final changed = consent.unshown(
        unit,
        [target],
        historyCheck.claims,
        inputs: _authorizationInputs(stage, signing),
      );
      if (changed.isNotEmpty) {
        _refuseChangedConsent(unit, changed);
        releaseProgress.fail(
          target,
          activity: CommonProgressActivities.checking,
        );
        return _PublicTargetCompletion.failed(
          step,
          _PublicationFailure.reported(step),
        );
      }
    }

    if (nativeCheck != null) {
      final NativePublicationOutcome outcome;
      try {
        outcome = await nativeCheck.verify();
      } on Object catch (error) {
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
                code: 'RK-REL-001',
                message:
                    '${step.summary}: native public dependency verification failed',
                remedy:
                    'restore readable public dependencies and re-run; no upload was attempted for this target',
                evidence: '$error',
              ),
            ],
            halt: output.report.acted
                ? HaltKind.stoppedPartway
                : HaltKind.beforeActing,
          ),
        );
      }
      output.report.attach(
        'native-publication/${step.id}',
        CanonicalJson.encode(outcome.evidence),
      );
      if (outcome case NativePublicationBlocked(:final diagnostic)) {
        releaseProgress.fail(
          target,
          activity: CommonProgressActivities.checking,
        );
        return _PublicTargetCompletion.failed(
          step,
          _PublicationFailure(
            step: step,
            diagnostics: [diagnostic],
            halt: output.report.acted
                ? HaltKind.stoppedPartway
                : HaltKind.beforeActing,
          ),
        );
      }
    }

    // Repository consent validates every selected pending stage together below.
    // Preserve the direct per-unit caller's boundary when no run was reviewed.
    if (runConsent == null) {
      final validationHalt = output.report.acted
          ? HaltKind.stoppedPartway
          : HaltKind.beforeActing;
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
    }

    if (!await _repositoryScopeStillValid()) {
      releaseProgress.fail(target, activity: CommonProgressActivities.checking);
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
      releaseProgress.fail(target, activity: CommonProgressActivities.checking);
      return _PublicTargetCompletion.failed(
        step,
        _inspectionFailure(step, state),
      );
    }
    if (recoversWithoutStage &&
        module.stageRecoveryBinding(state) != recoveryBinding) {
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
                  'public inputs changed after authorization. Re-run so '
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

    if (!_repositoryInputsStillValid()) {
      releaseProgress.fail(target, activity: CommonProgressActivities.checking);
      return _PublicTargetCompletion.failed(
        step,
        _PublicationFailure.reported(step),
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

  Future<({List<Step> remaining, List<TargetClaim> claims})?>
  _refreshPublicGate({
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
      haltForState(
        unit,
        blocked,
        snapshot.states[blocked.id]!,
        target: targets
            .where((target) => target.step.id == blocked.id)
            .firstOrNull,
      );
      showActions(targets, actions);
      return null;
    }
    if (snapshot.monotonicityProblems.isNotEmpty) {
      output.problems(snapshot.monotonicityProblems);
      output.halt(HaltKind.beforeActing);
      showActions(targets, actions);
      return null;
    }
    return (remaining: snapshot.remaining, claims: snapshot.claims);
  }

  void _destinationChanged(
    PublishTarget target,
    List<TargetPlan> targets,
    Map<String, ReleaseAction> actions,
  ) {
    output.problem(
      Diagnostic(
        code: 'RK-DEST-001',
        message:
            '${target.configName} changed destination while preparing '
            'publication',
        remedy:
            'no public target changed. Restore the repository or native '
            'publisher configuration used before staging, then re-run. rk does '
            'not print destination values here because native coordinates may '
            'contain credentials.',
      ),
    );
    output.halt(HaltKind.beforeActing);
    showActions(targets, actions);
  }

  void _haltForAuthorizationGrowth(
    Step step,
    Inspection state,
    ResolvedUnit unit,
    List<TargetPlan> targets,
    Map<String, ReleaseAction> actions, {
    bool beforeAuthorization = false,
  }) {
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
        message: beforeAuthorization
            ? 'the selected release gained work after preparation'
            : 'the release plan grew after authorization',
        remedy: beforeAuthorization
            ? '${step.summary} was already published during preparation; '
                  'inspect the changed destination and prepare a fresh plan.'
            : '${step.summary} was not work when the plan was shown. RK '
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

  Future<bool> _authorize(
    ResolvedUnit unit,
    List<TargetPlan> remaining, {
    required ReleaseStage stage,
    required ReleaseSigningContext? signing,
    required List<TargetClaim> claims,
  }) async {
    final consent = runConsent;
    if (consent != null) {
      final unshown = consent.unshown(
        unit,
        remaining,
        claims,
        inputs: _authorizationInputs(stage, signing),
      );
      if (unshown.isNotEmpty) {
        _refuseChangedConsent(unit, unshown);
        return false;
      }
      output.say('Authorized in the reviewed repository plan.');
      return true;
    }
    _showAuthorization(
      unit,
      remaining,
      stage: stage,
      signing: signing,
      claims: claims,
    );

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
      output.say(
        answer == null
            ? 'No confirmation received for ${unit.name} ${unit.version}.'
            : 'Cancelled release of ${unit.name} ${unit.version}.',
      );
      output.say('Its remaining targets were not published.');
      output.problem(
        Diagnostic(
          code: 'RK-AUTH-002',
          message: 'the release was not authorized',
          remedy:
              'answer yes at the prompt, or pass --yes for an '
              'unattended release',
        ),
        unit: unit.name,
      );
      output.halt(HaltKind.beforeActing);
      output.next('rk release ${unit.name}');
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

final class _PublicationReview {
  _PublicationReview(
    this.plan,
    Iterable<Step> remaining,
    Iterable<TargetClaim> claims,
    Map<String, String> recoveryBindings,
  ) : remaining = List.unmodifiable(remaining),
      claims = List.unmodifiable(claims),
      recoveryBindings = Map.unmodifiable(recoveryBindings);
  final PublicationPlan plan;
  final List<Step> remaining;
  final List<TargetClaim> claims;
  final Map<String, String> recoveryBindings;
  Iterable<_OmittedTarget> get omitted => plan.targets
      .where((target) => !remaining.any((step) => step.id == target.step.id))
      .map((target) => _OmittedTarget(plan, target));
  List<TargetPlan> get remainingTargets => [
    for (final step in remaining)
      plan.targets.singleWhere((target) => target.step.id == step.id),
  ];
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
  final bool reported;

  bool get rerunHelps =>
      halt != HaltKind.unfixableByRerun && halt != HaltKind.actedAndUnfixable;
}

/// Exact targets deliberately excluded from one immutable repository consent.
final class _OmittedTarget {
  const _OmittedTarget(this.plan, this.target);
  final PublicationPlan plan;
  final TargetPlan target;
}
