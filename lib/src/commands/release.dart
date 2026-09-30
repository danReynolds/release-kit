import 'dart:async';
import 'dart:io';

import '../builds/capability.dart';
import '../engine/assets.dart';
import '../engine/changelog.dart';
import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../output/output.dart';
import '../output/progress.dart';
import '../engine/inspect.dart';
import '../engine/publish_target.dart';
import '../engine/resolve.dart';
import '../engine/release_stage.dart';
import '../engine/source_tree.dart';
import '../engine/stage_inspection.dart';
import '../engine/targets.dart';
import '../engine/tools.dart';
import '../engine/verdict.dart';
import '../targets/target_module.dart';
import 'release_progress.dart';
import 'release_preparation.dart';
import 'release_stage_coordinator.dart';
import 'release_publication_coordinator.dart';

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
    required this.allowInteractiveTools,
    this.preauthorized = false,
    this.stageOnly = false,
    ReleaseStage Function(ResolvedUnit unit)? stageFor,
    ReleaseStage Function(ResolvedUnit unit, GitState git)? refreshStage,
    Future<GitState> Function()? refreshGit,
    Map<String, String> Function()? refreshEnvironment,
    Future<void> Function(Duration)? wait,
    required this.capabilities,
  }) : repositoryGit = repositoryGit ?? git,
       _wait = wait ?? _sleep,
       _stageFor =
           stageFor ??
           ReleaseStages(
             source: tree,
             git: git,
             stageContracts: inspector.targets.stageContractResolver(
               resolution,
             ),
           ).call,
       _refreshStage =
           refreshStage ??
           ((unit, currentGit) => ReleaseStages(
             source: tree,
             git: currentGit,
             stageContracts: inspector.targets.stageContractResolver(
               resolution,
             ),
           ).call(unit)),
       _refreshGit = refreshGit ?? (() async => git),
       _refreshEnvironment =
           refreshEnvironment ??
           (() => Map<String, String>.of(Platform.environment));

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
  /// but does not list yet, and how often it asks. Pub warns that a successful
  /// upload can take up to ten minutes to become visible, so the bound covers
  /// that documented propagation window without becoming an infinite loop.
  static const confirmDeadline = Duration(minutes: 10);
  static const confirmInterval = Duration(seconds: 5);

  final Tools tools;
  final Output output;

  /// Asks the operator an ordinary yes/no question. Returns what they typed,
  /// or null when there is nobody to ask.
  final Future<String?> Function(String prompt)? confirm;

  /// Whether a native provider may inherit this process's terminal.
  ///
  /// Machine output and redirected disclosures keep this false: a native
  /// login must never write beside the one JSON document or ask a question
  /// whose release context the operator cannot see.
  final bool allowInteractiveTools;

  /// Whether `--yes` answered every authorization before the run began. Such
  /// a run has nobody to ask once, so it does not read the whole run first.
  final bool preauthorized;

  /// What this host can produce. Detection belongs at the composition edge so
  /// its bounded optional-runtime probes complete before the command is built;
  /// tests inject the host they mean to exercise.
  final HostCapabilities capabilities;

  /// Prepare and validate the exact private stage, then stop before release
  /// authorization or any public mutation.
  final bool stageOnly;

  final ReleaseStage Function(ResolvedUnit unit) _stageFor;
  final ReleaseStage Function(ResolvedUnit unit, GitState git) _refreshStage;
  final Future<GitState> Function() _refreshGit;
  final Map<String, String> Function() _refreshEnvironment;
  var _sourceWarningShown = false;

  late final ReleaseStageCoordinator _stages = ReleaseStageCoordinator(
    initialGit: git,
    output: output,
    refreshGit: _refreshGit,
    refreshStage: _refreshStage,
    tools: tools,
    capabilities: capabilities,
    stageFor: _stageFor,
    stageOnly: stageOnly,
  );

  late final ReleasePublicationCoordinator _publication =
      ReleasePublicationCoordinator(
        inspector: inspector,
        initialGit: git,
        tools: tools,
        output: output,
        stages: _stages,
        refreshGit: _refreshGit,
        refreshEnvironment: _refreshEnvironment,
        wait: _wait,
        confirm: confirm,
        allowInteractiveTools: allowInteractiveTools,
        confirmDeadline: confirmDeadline,
        confirmInterval: confirmInterval,
      );

  Future<int> run({String? only}) async {
    try {
      return await _runUnits(only: only);
    } finally {
      // Every exit path, including the refusals and the single named unit: a
      // run that stopped partway may still have created the session, and
      // leaving one behind is exactly what this undoes.
      await _publication.restoreCreatedSessions();
    }
  }

  Future<int> _runUnits({String? only}) async {
    // One repository fact for the whole invocation, including ordering or
    // scope refusals that happen before the first unit pipeline starts.
    output.report.repository(
      name: tree.description.split('/').last,
      branch: repositoryGit.branch,
      uncommitted: repositoryGit.uncommitted.length,
      head: git.hasCommit ? git.head : null,
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
            remedy:
                'this repository releases: '
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
          remedy:
              'a dependent package may need its sibling version to be '
              'public before its native package staging can pass. Stage one '
              'unit explicitly: rk stage <unit>',
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
        'Release order: ${ordered.map((unit) => '${unit.name} ${unit.version}').join(' -> ')}',
      );
      output.blank();
      if (!stageOnly && confirm != null && !preauthorized) {
        _showSourceWarning();
        if (!await _askOnce(ordered)) return ExitCodes.refused;
      }
    }
    for (final unit in ordered) {
      final result = await _release(unit);
      if (result != ExitCodes.ok) return result;
      output.previousUnitActed = output.report.acted;
    }
    return ExitCodes.ok;
  }

  /// Says once per run, before anything asks for a yes, that the release
  /// is of uncommitted work.
  void _showSourceWarning() {
    if (sourceWarning == null || _sourceWarningShown) return;
    _sourceWarningShown = true;
    output.heading('Warnings');
    output.warning(sourceWarning!, depth: 1);
    output.blank();
  }

  /// Shows what a repository release will publish, unit by unit, and asks
  /// once for all of it before the first unit acts. Answers false when the
  /// run was declined.
  ///
  /// These are the reads and checks each unit makes before it stages, and
  /// each makes them again: this question discloses, and each unit still
  /// checks. A unit whose fresh reads find something not shown here, or that
  /// rk warns about, asks for itself. So does every unit when fewer than two
  /// have anything to publish, or when one already cannot go ahead: that unit
  /// stops the run when it is reached, and the units before it should not be
  /// released on a yes to it. What only staging finds still stops the run
  /// where it is found.
  Future<bool> _askOnce(List<ResolvedUnit> ordered) async {
    final board = output.progressBoard(
      'Reading what this run publishes',
      emitSlowToNonTerminal: true,
    );
    final List<_UnitPlan> plans;
    try {
      plans = await Future.wait([
        for (final unit in ordered)
          _planFor(
            unit,
            board.addRow(id: unit.name, label: '${unit.name} ${unit.version}'),
          ),
      ]);
    } finally {
      board.discard();
    }

    final stopping = plans.where((plan) => plan.stop != null).firstOrNull;
    if (stopping != null) {
      final name = '${stopping.unit.name} ${stopping.unit.version}';
      output.say(
        stopping.unread
            ? '$name could not be read ahead of its turn (${stopping.stop}), '
                  'so each unit asks for itself.'
            : '$name cannot go ahead as things stand (${stopping.stop}), so '
                  'each unit asks for itself.',
      );
      output.blank();
      return true;
    }
    final asking = [
      for (final plan in plans)
        if (plan.remaining.isNotEmpty) plan,
    ];
    if (asking.length < 2) return true;

    for (final plan in plans) {
      final name = '${plan.unit.name} ${plan.unit.version}';
      if (plan.remaining.isEmpty) {
        output.line(
          name,
          mark: Mark.satisfied,
          note: plan.publishes ? 'already released' : 'nothing to publish',
        );
        continue;
      }
      output.line(name, role: VisualRole.checkpoint, strong: true);
      _publication.showTargets(plan.remaining, plan.claims);
    }
    final names = [
      for (final plan in asking) '${plan.unit.name} ${plan.unit.version}',
    ];
    final series = names.length == 2
        ? names.join(' and ')
        : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
    // The long form each unit's own question would record, since the yes
    // that accepts it is this one.
    output.report.attach(
      'authorization-disclosures/run',
      [
        'one yes for $series, asked before the first of them acted.',
        for (final plan in asking)
          [
            '${plan.unit.name} ${plan.unit.version}',
            for (final target in plan.remaining)
              '  ${target.kindLabel}: '
                  '${_publication.targetNote(target, plan.claims)}',
            ..._publication.disclosureFor(plan.remaining, plan.claims),
          ].join('\n'),
      ].join('\n\n'),
    );

    final answer = await confirm!('Release $series? [y/N] ');
    final accepted = switch (answer?.trim().toLowerCase()) {
      'y' || 'yes' => true,
      _ => false,
    };
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
              'answer yes at the prompt, or pass --yes for an unattended '
              'release',
        ),
      );
      output.halt(HaltKind.beforeActing);
      output.next('rk release');
      return false;
    }
    output.blank();
    _publication.runConsent = RunConsent(
      targets: {
        for (final plan in asking)
          plan.unit.name: {for (final target in plan.remaining) target.step.id},
      },
      claims: {
        for (final plan in asking)
          plan.unit.name: {
            for (final claim in plan.claims) (claim.registrar, claim.name),
          },
      },
    );
    return true;
  }

  /// What [unit] would publish as things stand, read and checked as its own
  /// release reads and checks it before staging.
  Future<_UnitPlan> _planFor(
    ResolvedUnit unit,
    ProgressRowController row,
  ) async {
    row.handle.begin(CommonProgressActivities.checking);
    try {
      final problems = Diagnostics();
      final checklist = Checklist.derive(unit, resolution, problems);
      final targets = inspector.targets.derive(
        unit,
        checklist,
        repository: inspector.repository,
      );
      final targetByStep = {
        for (final target in targets) target.step.id: target,
      };
      final publicSteps = [
        for (final step in checklist.steps)
          if (step.isPublic) step,
      ];
      final stageInspection = _stageFor(unit).inspect();
      // Public destinations only. A prerequisite, such as a provider's
      // version on pub.dev, is what the units before this one publish.
      final inspections = await Future.wait([
        for (final step in publicSteps) inspector.inspect(step, unit),
      ]);
      final states = {
        for (final (index, step) in publicSteps.indexed)
          step.id: inspections[index],
      };
      for (final step in publicSteps) {
        final state = states[step.id]!;
        if (!state.isExact && !state.isAbsent) {
          row.fail();
          return _UnitPlan.stopped(
            unit,
            '${targetByStep[step.id]!.label}: '
            '${state.detail ?? state.verdict.name}',
          );
        }
      }
      final history = await inspector.releaseMonotonicity(
        unit,
        targets,
        problems,
      );
      inspector.tagGuards(unit, checklist, states).forEach(problems.report);
      if (problems.isNotEmpty) {
        row.fail();
        return _UnitPlan.stopped(unit, problems.found.first.message);
      }

      final remaining = [
        for (final step in publicSteps)
          if (!states[step.id]!.isExact) targetByStep[step.id]!,
      ];
      if (remaining.isNotEmpty) {
        final recoversWithoutStage = _recoversWithoutStage(
          stageInspection,
          remaining,
          states,
        );
        String? refusal;
        if (_needsLostStage(
          unit,
          stageInspection,
          publicSteps,
          states,
          recoversWithoutStage: recoversWithoutStage,
        )) {
          refusal = 'the partial release needs its exact stage';
        } else if (!stageInspection.reusable && !recoversWithoutStage) {
          refusal =
              (_refuseIfUnfinishable(unit) ??
                      _stages.preparationProblem(
                        unit,
                        stageInspection,
                        mayReplaceReviewed: false,
                      ))
                  ?.message;
        }
        if (refusal != null) {
          row.fail();
          return _UnitPlan.stopped(unit, refusal);
        }
      }
      row.complete(note: remaining.isEmpty ? 'already released' : 'checked');
      return _UnitPlan(
        unit,
        publishes: publicSteps.isNotEmpty,
        remaining: remaining,
        claims: history.claims,
      );
    } on Object catch (error) {
      row.fail();
      return _UnitPlan.stopped(unit, '$error', unread: true);
    }
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
        final key =
            '${problem.code}\u0000${problem.message}\u0000'
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

    final willPublish =
        !stageOnly &&
        (unit.publish.isNotEmpty ||
            unit.projects.any((project) => project.publish.isNotEmpty));
    output.heading(
      '${willPublish ? 'Releasing' : 'Staging'} ${unit.name} ${unit.version}',
    );
    output.line(
      [
        tree.description.split('/').last,
        if (git.hasCommit)
          '${git.branch ?? 'detached'}@${git.shortHead}'
        else
          'working tree',
        if (repositoryGit.uncommitted.isNotEmpty)
          '${repositoryGit.uncommitted.length} uncommitted',
      ].join(' · '),
      role: VisualRole.secondary,
    );
    output.blank();

    _showSourceWarning();

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
          remedy:
              'without Git, build, authorize, and begin publication in '
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
    final targetByStep = {for (final target in targets) target.step.id: target};
    final initialProgress = TargetReleaseProgress(
      output,
      title: '${unit.name} ${unit.version} · preparing release',
      targets: targets,
    );

    final ReleaseStage stage;
    try {
      stage = _stageFor(unit);
    } on Object catch (error) {
      output.problem(
        Diagnostic(
          code: 'RK-STAGE-001',
          message: 'the release stage identity could not be resolved',
          remedy: '$error',
        ),
      );
      output.halt(HaltKind.beforeActing);
      return ExitCodes.refused;
    }

    var stageInspection = stage.inspect();

    // Destinations are independent, so they are read together: every row
    // says what it is doing at once, and the wait is the slowest read
    // rather than their sum. The report is written afterwards in checklist
    // order, so the document never depends on which answer arrived first.
    for (final step in checklist.steps) {
      final target = targetByStep[step.id];
      if (target == null) continue;
      initialProgress.begin(target, CommonProgressActivities.checking);
    }
    final observed = await Future.wait([
      for (final step in checklist.steps)
        _observeForRelease(step, unit, stageInspection).then((state) {
          final target = targetByStep[step.id];
          if (target != null) initialProgress.observe(target, state);
          return state;
        }),
    ]);
    final states = <String, Inspection>{
      for (final (index, step) in checklist.steps.indexed)
        step.id: observed[index],
    };
    for (final step in checklist.steps) {
      final state = states[step.id]!;
      output.step(
        step,
        verdict: state.verdict,
        detail: state.detail,
        evidence: state.evidence,
        action: step.isPublic
            ? (state.isExact
                  ? ReleaseAction.alreadyPublished.wire
                  : ReleaseAction.notAttempted.wire)
            : null,
        show: false,
      );
    }

    final releaseHistory = await inspector.releaseMonotonicity(
      unit,
      targets,
      problems,
    );
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
    final partialBinaryStageLoss =
        unit.buildsReleaseAssets &&
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
      _publication.haltForState(
        unit,
        initialBlock,
        states[initialBlock.id]!,
        target: targetByStep[initialBlock.id],
      );
      return ExitCodes.refused;
    }

    final publicActions = {
      for (final step in publicSteps)
        step.id: states[step.id]!.isExact
            ? ReleaseAction.alreadyPublished
            : ReleaseAction.notAttempted,
    };
    if (publicSteps.isNotEmpty &&
        publicSteps.every((step) => states[step.id]!.isExact)) {
      output.line(
        '${unit.name} ${unit.version}',
        mark: Mark.satisfied,
        note: 'already released',
      );
      await _publication.verifyAvailability(unit: unit, targets: targets);
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
    final recoversWithoutStage = _recoversWithoutStage(
      stageInspection,
      unfinishedTargets,
      states,
    );
    if (_needsLostStage(
      unit,
      stageInspection,
      publicSteps,
      states,
      recoversWithoutStage: recoversWithoutStage,
    )) {
      output.halt(HaltKind.unfixableByRerun);
      output.problem(
        Diagnostic(
          code: 'RK-STAGE-005',
          message: unit.shipsBinaries
              ? 'the partial binary release needs its exact stage'
              : 'the partial release needs its exact stage',
          remedy:
              'restore ${stage.directory.path} from the machine that '
              'staged this release. ${unit.shipsBinaries ? 'Signed or notarized bytes' : 'What its build wrote'} cannot be '
              'recreated byte-for-byte after a public target has bound them.',
        ),
      );
      if (!stageOnly) _publication.showActions(targets, publicActions);
      return ExitCodes.refused;
    }
    if (!stageInspection.reusable && !recoversWithoutStage) {
      final refusal = _refuseIfUnfinishable(unit);
      if (refusal != null) {
        output.halt(HaltKind.beforeActing);
        output.problem(refusal);
        if (!stageOnly) _publication.showActions(targets, publicActions);
        return ExitCodes.refused;
      }
    }

    if (!stageOnly) {
      // Stage-only mode keeps its explicit ability to replace
      // reviewed-but-invalid bytes. A real release refuses that ambiguity
      // before any local preparation.
      final stageProblem = recoversWithoutStage
          ? null
          : _stages.preparationProblem(
              unit,
              stageInspection,
              mayReplaceReviewed: false,
            );
      if (stageProblem != null) {
        output.problem(stageProblem, unit: unit.name);
        output.halt(HaltKind.beforeActing);
        _publication.showActions(targets, publicActions);
        return ExitCodes.refused;
      }
      if (!localOnly && !_publication.requireAuthorizer(unit)) {
        _publication.showActions(targets, publicActions);
        return ExitCodes.refused;
      }
    }

    // Safe ambient readiness applies to stage-only too: it may not acquire a
    // credential, but it should not spend substantial producer work on bytes
    // the current native endpoint can never publish as configured.
    final endpointBaselines = await _publication.prepareDestinations(
      unit: unit,
      targets: targets,
      states: states,
      actions: publicActions,
      stageOnly: stageOnly,
    );
    if (endpointBaselines == null) return ExitCodes.refused;

    final reusedStage = stageInspection.reusable;
    final PreparedRelease prepared;
    if (recoversWithoutStage) {
      prepared = PreparedRelease(claims: const [], signing: null);
    } else {
      final targetStages = inspector.targets.stages(
        unit: unit,
        targets: targets,
      );
      final result = await _stages.prepare(
        unit: unit,
        checklist: checklist,
        targets: targets,
        targetStages: targetStages,
        stage: stage,
        inspected: stageInspection,
        claims: releaseHistory.claims,
      );
      if (result == null) {
        if (!stageOnly) _publication.showActions(targets, publicActions);
        return ExitCodes.refused;
      }
      prepared = result;
      stageInspection = stage.inspect();
      if (!stageInspection.reusable) {
        output.problem(
          Diagnostic(
            code: 'RK-STAGE-003',
            message: 'the release stage did not remain valid',
            remedy: stageInspection.issues.join('\n'),
          ),
        );
        output.halt(HaltKind.beforeActing);
        if (!stageOnly) _publication.showActions(targets, publicActions);
        return ExitCodes.refused;
      }
    }

    // Re-resolve the complete identity, not only HEAD. The stage plan also
    // binds the PATH-selected compiler, host ABI, origin, destinations, and
    // tag-signing policy. Stage-only completion must make the same claim that
    // those inputs remained stable while producers ran.
    if (!await _stages.contextStillValid(
      stage,
      unit,
      changed: 'after staging',
      halt: HaltKind.beforeActing,
    )) {
      return ExitCodes.refused;
    }

    if (stageOnly || localOnly) {
      output.step(
        checklist.steps.singleWhere(
          (step) => step.kind == StepKind.completeStage,
        ),
        verdict: Verdict.exact,
        detail: 'staged and validated',
        evidence: {
          'stage id': stage.directory.identity.id,
          'stage path': stage.directory.repositoryRelativePath,
        },
        show: false,
      );
      _sayStageClaims(prepared.claims, localOnly ? null : prepared.signing);
      if (unit.binaryProject case final project? when localOnly) {
        output.blank();
        output.line(
          'Archives',
          note:
              '${stage.directory.repositoryRelativePath}/'
              '${ReleaseAssets.producerRoot(project)}/archives',
          role: VisualRole.secondary,
          noteRole: VisualRole.secondary,
        );
      }
      output.blank();
      output.line(
        '${unit.name} ${unit.version} '
        '${reusedStage ? 'is already staged and verified.' : 'staged successfully.'}',
        mark: Mark.done,
        strong: true,
      );
      if (!localOnly) {
        final command = 'rk release ${unit.name}';
        output.report.next(command);
        output.blank();
        output.line(
          'Ready to publish: $command',
          depth: 1,
          role: VisualRole.operatorAction,
        );
      }
      return ExitCodes.ok;
    }

    return _publication.publish(
      PublicationPlan(
        unit: unit,
        steps: checklist.steps,
        publicSteps: publicSteps,
        targets: targets,
        states: states,
        endpointBaselines: endpointBaselines,
        actions: publicActions,
        prepared: prepared,
        stage: stage,
        recoversWithoutStage: recoversWithoutStage,
      ),
    );
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

  /// Whether the targets a unit has left can all finish from authenticated
  /// public inputs once its stage is gone, as a moving channel may. One
  /// versioned publication that still needs bytes keeps the original stage
  /// recovery-critical for the whole run.
  bool _recoversWithoutStage(
    StageInspection stageInspection,
    List<TargetPlan> unfinished,
    Map<String, Inspection> states,
  ) =>
      !stageOnly &&
      !stageInspection.reusable &&
      unfinished.isNotEmpty &&
      unfinished.every((target) {
        final state = states[target.step.id]!;
        return state.isAbsent &&
            inspector.targets
                    .moduleForTarget(target)
                    .stageRecoveryBinding(state) !=
                null;
      });

  /// Whether a partly public release of what [unit] builds needs the exact
  /// stage it no longer has. Once any binary target is exact, the original
  /// signed or notarized stage is recovery-critical until every other target
  /// is also proved exact. An unread forge or tap cannot be treated as
  /// permission to rebuild: it may already contain the bytes bound by the
  /// public tag.
  bool _needsLostStage(
    ResolvedUnit unit,
    StageInspection stageInspection,
    List<Step> publicSteps,
    Map<String, Inspection> states, {
    required bool recoversWithoutStage,
  }) =>
      unit.buildsReleaseAssets &&
      !stageInspection.reusable &&
      !recoversWithoutStage &&
      publicSteps.any((step) => states[step.id]!.isExact) &&
      publicSteps.any((step) {
        final state = states[step.id]!;
        return state.isAbsent || state.verdict == Verdict.unknown;
      });

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
                resolved.reason ?? 'it needs a different host',
                () => [],
              )
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
      message:
          '${unit.name}: this machine cannot produce every platform '
          'it ships',
      remedy:
          'starting anyway would build and sign for minutes and then '
          'stop before publishing anything:\n'
          '  ${folded.join('\n  ')}',
    );
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

  /// Shows irreversible first-claim facts beside a completed private stage.
  void _sayStageClaims(
    List<TargetClaim> claims,
    ReleaseSigningContext? signing,
  ) {
    final firstSigning = signing?.firstCertificate == null ? null : signing;
    if (claims.isEmpty && firstSigning == null) return;
    output.blank();
    // Tense matters: at staging nothing public has happened yet, so saying
    // these *are* permanent would be false a moment before it is true.
    output.line(
      'First release · permanent once published',
      depth: 1,
      state: RuntimeState.attention,
      strong: true,
    );
    for (final claim in claims) {
      output.line(
        '${claim.registrar} package',
        note: claim.name,
        depth: 2,
        labelWidth: 26,
        noteRole: VisualRole.secondary,
      );
    }
    if (firstSigning != null) {
      output.line(
        'macOS code identifier',
        note: firstSigning.codeId,
        depth: 2,
        labelWidth: 26,
        noteRole: VisualRole.secondary,
      );
      output.line(
        'Apple team',
        note: _shortCertificate(firstSigning.firstCertificate!),
        depth: 2,
        labelWidth: 26,
        noteRole: VisualRole.secondary,
      );
    }
  }

  /// Every Developer ID certificate begins the same way; what varies is the
  /// team it names.
  static String _shortCertificate(String certificate) =>
      certificate.replaceFirst('Developer ID Application: ', '');
}

/// What one unit of a repository release would publish, read before the
/// first unit acts, or why it cannot go ahead.
final class _UnitPlan {
  _UnitPlan(
    this.unit, {
    required this.publishes,
    required this.remaining,
    required this.claims,
  }) : stop = null,
       unread = false;

  _UnitPlan.stopped(this.unit, String this.stop, {this.unread = false})
    : publishes = true,
      remaining = const [],
      claims = const [];

  final ResolvedUnit unit;
  final bool publishes;
  final List<TargetPlan> remaining;
  final List<TargetClaim> claims;

  /// Why the unit cannot go ahead, when it cannot.
  final String? stop;

  /// Whether [stop] is that it could not be read at all.
  final bool unread;
}
