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
import '../engine/stage_recovery.dart';
import '../engine/publish_target.dart';
import '../engine/registry.dart';
import '../engine/release_dependencies.dart';
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
import '../engine/timings.dart';

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
    this.stageOnly = false,
    ReleaseStage Function(ResolvedUnit unit)? stageFor,
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

  /// What this host can produce. Detection belongs at the composition edge so
  /// its bounded optional-runtime probes complete before the command is built;
  /// tests inject the host they mean to exercise.
  final HostCapabilities capabilities;

  /// Prepare and validate the exact private stage, then stop before release
  /// authorization or any public mutation.
  final bool stageOnly;

  final ReleaseStage Function(ResolvedUnit unit) _stageFor;

  /// The packages this run releases, so a prerequisite on one of them is met
  /// by this run's own publication rather than by an earlier one.
  Set<String> _releasing = const {};

  /// The repository packages each of [unit]'s Pub packages takes from this
  /// source when staged, by package, each with its directory: see
  /// [ReleaseDependencyPlan.fromSource].
  Future<Map<String, Map<String, String>>> _fromSource(
    ResolvedUnit unit,
  ) async => {
    for (final project in unit.projects)
      if (project.publish.contains(PublishTarget.pubDev))
        project.name: {
          for (final sibling in await resolution.dependencyPlan.fromSource(
            project,
            _published,
          ))
            sibling.name: sibling.pubspec.directory,
        },
  };

  /// Whether [version] of [package] is on pub.dev. One rk cannot read
  /// counts as not yet: the stage then takes it from this source, and a
  /// release still waits to read it before publishing what needs it.
  Future<bool> _published(String package, String version) async {
    try {
      final published = await inspector.registry?.lookup(package);
      return published?.versions.any((v) => v.version.canonical == version) ??
          false;
    } on RegistryUnavailable {
      return false;
    }
  }

  /// The package a prerequisite step waits for: its coordinate is
  /// `pub.dev/<package>/<version>`.
  static String? _prerequisitePackage(Step step) {
    final parts = step.coordinate?.split('/');
    return parts == null || parts.length < 3 ? null : parts[1];
  }

  final Map<String, String> Function() _refreshEnvironment;
  var _sourceWarningShown = false;

  late final ReleaseStageCoordinator _stages = ReleaseStageCoordinator(
    initialGit: git,
    output: output,
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
      output.timeline.endPhase();
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
      final named = resolution.units
          .where((unit) => unit.name == only)
          .toList();
      if (named.isEmpty) {
        output.problem(
          Diagnostic(
            code: 'RK-CLI-003',
            message: 'no unit named "$only"',
            remedy:
                'this repository releases: '
                '${resolution.units.map((unit) => unit.name).join(', ')}',
          ),
        );
        return ExitCodes.usage;
      }
      return _runRepository(named);
    }
    final problems = Diagnostics();
    final ordered = resolution.dependencyPlan.units(problems);
    if (problems.isNotEmpty) {
      output.problems(problems.found);
      output.halt(HaltKind.beforeActing);
      return ExitCodes.refused;
    }
    return _runRepository(ordered);
  }

  Future<int> _runRepository(List<ResolvedUnit> selected) async {
    final prepared = await _prepareRepository(selected);
    if (prepared.code != ExitCodes.ok || stageOnly) return prepared.code;
    final publications = prepared.publications;
    if (publications.isEmpty) return ExitCodes.ok;
    output.timeline.phase('publishing');
    final publicUnits = publications.where(
      (plan) => plan.publicSteps.isNotEmpty,
    );
    if (publicUnits.isNotEmpty) {
      output.heading(
        'Release order: '
        '${publicUnits.map((plan) => '${plan.unit.name} ${plan.unit.version}').join(' -> ')}',
      );
      output.blank();
    }
    if (!await _publication.authorize(publications)) {
      return ExitCodes.refused;
    }
    for (final publication in publications) {
      final code = await _publication.publish(publication);
      if (code != ExitCodes.ok) return code;
      output.previousUnitActed = output.report.acted;
    }
    return ExitCodes.ok;
  }

  /// Finishes every selected private stage before returning any public work.
  /// The publication coordinator receives only these completed plans; a later
  /// preparation failure preserves earlier stages without acquiring sessions.
  Future<({int code, List<PublicationPlan> publications})> _prepareRepository(
    List<ResolvedUnit> selected,
  ) async {
    final publications = <PublicationPlan>[];
    ({int code, List<PublicationPlan> publications}) result(int code) =>
        (code: code, publications: List.unmodifiable(publications));
    _releasing = {
      for (final unit in selected)
        for (final project in unit.projects) project.name,
    };
    for (final unit in selected) {
      output.report.unit(
        name: unit.name,
        version: unit.version.canonical,
        tag: unit.tag,
      );
    }
    if (!_validateRepositoryScope(selected)) return result(ExitCodes.refused);
    output.timeline.phase('preparing');
    // Every unit's destinations are read at once; each unit is then shown,
    // in release order, as its answers arrive.
    final reads = {for (final unit in selected) unit.name: _startReads(unit)};
    final inspected = <String, _InspectedUnit>{};
    for (final unit in selected) {
      final observation = await Timings.span(
        'inspect ${unit.name}',
        () => _inspectRelease(unit, reads[unit.name]!),
      );
      if (observation == null) return result(ExitCodes.refused);
      inspected[unit.name] = observation;
    }
    bool isNoop(_InspectedUnit unit) =>
        unit.targets.isNotEmpty &&
        unit.targets.every((target) => unit.states[target.step.id]!.isExact);
    // Every unit's destinations are checked before any unit spends private
    // work: a conflict or an unready target in the last unit refuses before
    // the first one builds.
    for (final observation in inspected.values) {
      final unit = observation.unit;
      final publicSteps = observation.checklist.steps
          .where((s) => s.isPublic)
          .toList();
      final partialStageLoss =
          !observation.stageInspection.reusable &&
          !_releasedElsewhere(publicSteps, observation.states) &&
          hasRecoveryCriticalPublicProgress(unit, [
            for (final step in publicSteps)
              (step, observation.states[step.id]!),
          ]);
      final blocked = publicSteps.where((step) {
        final state = observation.states[step.id]!;
        return !(partialStageLoss && state.verdict == Verdict.unknown) &&
            Inspector.blocks(step, state);
      }).firstOrNull;
      if (blocked != null) {
        _publication.haltForState(
          unit,
          blocked,
          observation.states[blocked.id]!,
          target: observation.targets
              .where((t) => t.step.id == blocked.id)
              .singleOrNull,
        );
        return result(ExitCodes.refused);
      }
      final ready = await Timings.span(
        'check readiness ${unit.name}',
        () => _publication.checkReadiness(
          unit: unit,
          targets: observation.targets,
          states: observation.states,
          actions: {
            for (final target in observation.targets)
              target.step.id: observation.states[target.step.id]!.isExact
                  ? ReleaseAction.alreadyPublished
                  : ReleaseAction.notAttempted,
          },
          stageOnly: true,
        ),
      );
      if (!ready) return result(ExitCodes.refused);
    }
    final work = [
      for (final unit in selected)
        if (!isNoop(inspected[unit.name]!)) unit,
    ];
    Future<({int code, List<PublicationPlan> publications})>
    finishNoops() async {
      for (final unit in selected.where((u) => isNoop(inspected[u.name]!))) {
        final prepared = await _prepareRelease(inspected[unit.name]!);
        if (prepared.code != ExitCodes.ok) return result(prepared.code);
        if (prepared.publication case final publication?) {
          publications.add(publication);
        }
      }
      return result(ExitCodes.ok);
    }

    if (work.isEmpty) return finishNoops();
    output.timeline.phase('staging');
    // Each unit is checked, and its signing settled, one at a time in
    // release order. Then every unit that needs a stage builds at once, and
    // each is finished in release order again.
    final planned = <_ReleasePlan>[];
    for (final unit in work) {
      final plan = await Timings.span(
        'plan ${unit.name}',
        () => _planRelease(inspected[unit.name]!),
      );
      if (plan == null) return result(ExitCodes.refused);
      planned.add(plan);
    }
    final stagings = [
      for (final plan in planned)
        if (plan.staging case final staging?) staging,
    ];
    Future<({int code, List<PublicationPlan> publications})> finish() async {
      final prepared = await _stage(stagings);
      // Every unit says how its staging went, even past one that failed.
      var code = ExitCodes.ok;
      for (final plan in planned) {
        final finished = _finishRelease(plan, prepared[plan.unit.name]);
        if (finished.code != ExitCodes.ok) {
          if (code == ExitCodes.ok) code = finished.code;
          continue;
        }
        if (finished.publication case final publication?) {
          publications.add(publication);
        }
      }
      if (code != ExitCodes.ok) return result(code);
      return finishNoops();
    }

    // Units staged side by side say how they stopped once, after all of
    // them have said what they staged.
    return stagings.length > 1 ? output.holdingHalts(finish) : finish();
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

  /// Cheap, source-owned refusals for every selected unit before preparation.
  /// Native contexts own package order; structural checklists must not reject
  /// a guessed publication cycle before discovery can select hosted fallback.
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

  /// Starts reading [unit]'s destinations and version history, showing
  /// nothing, so every unit's reads run at once. A unit whose reads cannot
  /// start reads them itself, and its inspection says what is wrong.
  _UnitReads _startReads(ResolvedUnit unit) {
    final checklist = Checklist.derive(unit, resolution, Diagnostics());
    final targets = inspector.targets.derive(
      unit,
      checklist,
      repository: inspector.repository,
    );
    final stage = _stageFor(unit);
    final stageInspection = stage.inspect();
    final problems = Diagnostics();
    return _UnitReads(
      checklist: checklist,
      targets: targets,
      stage: stage,
      stageInspection: stageInspection,
      states: {
        for (final step in checklist.steps)
          step.id: _observeForRelease(step, unit, stageInspection)..ignore(),
      },
      history: inspector.releaseMonotonicity(unit, targets, problems)
        ..ignore(),
      problems: problems,
    );
  }

  Future<_InspectedUnit?> _inspectRelease(
    ResolvedUnit unit,
    _UnitReads reads,
  ) async {
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
    final checklist = reads.checklist;
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
      return null;
    }
    final targets = reads.targets;
    final targetByStep = {for (final target in targets) target.step.id: target};
    final initialProgress = TargetReleaseProgress(
      output,
      title: '${unit.name} ${unit.version} · preparing release',
      targets: targets,
    );

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
        reads.states[step.id]!.then((state) {
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

    final releaseHistory = await reads.history;
    reads.problems.found.forEach(problems.report);
    inspector.tagGuards(unit, checklist, states).forEach(problems.report);
    initialProgress.discard();
    if (problems.isNotEmpty) {
      output.halt(HaltKind.beforeActing);
      output.problems(problems.found);
      return null;
    }

    return _InspectedUnit(
      unit: unit,
      checklist: checklist,
      targets: targets,
      states: states,
      history: releaseHistory,
      stage: reads.stage,
      stageInspection: reads.stageInspection,
    );
  }

  Future<({int code, PublicationPlan? publication})> _prepareRelease(
    _InspectedUnit inspected,
  ) async {
    final plan = await _planRelease(inspected);
    if (plan == null) return (code: ExitCodes.refused, publication: null);
    final prepared = await _stage([?plan.staging]);
    return _finishRelease(plan, prepared[plan.unit.name]);
  }

  /// Checks [inspected]'s unit against everything that refuses it before
  /// staging, and settles what its staging needs first. Null when refused.
  Future<_ReleasePlan?> _planRelease(_InspectedUnit inspected) async {
    final unit = inspected.unit;
    final checklist = inspected.checklist;
    final targets = inspected.targets;
    final states = inspected.states;
    final releaseHistory = inspected.history;
    final publicSteps = checklist.steps.where((step) => step.isPublic).toList();
    final targetByStep = {for (final target in targets) target.step.id: target};
    final stage = inspected.stage;
    final stageInspection = inspected.stageInspection;

    final alreadyReleased =
        publicSteps.isNotEmpty &&
        publicSteps.every((step) => states[step.id]!.isExact);

    // Unknown destination state never grants permission to produce locally.
    // Native preparation can defer public dependency availability, and a lost
    // recovery-critical partial stage retains its specific refusal below.
    final partialStageLoss =
        !_releasedElsewhere(publicSteps, states) &&
        !stageInspection.reusable &&
        hasRecoveryCriticalPublicProgress(unit, [
          for (final step in publicSteps) (step, states[step.id]!),
        ]);
    final initialBlock = checklist.steps.where((step) {
      if (step.kind == StepKind.completeStage) return false;
      if (step.kind == StepKind.prerequisite) {
        // A sibling the stage can take from this source waits for nothing
        // while staging, which is private. A sibling released in this run
        // publishes first, in dependency order, and is public before this
        // unit uploads. Only a release that needs a package some other run
        // must publish waits for it here.
        if (alreadyReleased ||
            stageOnly ||
            _releasing.contains(_prerequisitePackage(step))) {
          return false;
        }
      }
      final state = states[step.id]!;
      if (partialStageLoss && state.verdict == Verdict.unknown) {
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
      return null;
    }

    final publicActions = {
      for (final step in publicSteps)
        step.id: states[step.id]!.isExact
            ? ReleaseAction.alreadyPublished
            : ReleaseAction.notAttempted,
    };
    final plan = _ReleasePlan(
      inspected: inspected,
      stage: stage,
      stageInspection: stageInspection,
      publicSteps: publicSteps,
      publicActions: publicActions,
      alreadyReleased: alreadyReleased,
    );
    if (alreadyReleased) return plan;

    // A moving channel may be able to finish from authenticated public
    // inputs even after the local stage is lost. This is intentionally an
    // all-remaining-targets check: one versioned publication that still needs
    // bytes keeps the original stage recovery-critical for the whole run.
    final unfinishedTargets = [
      for (final step in publicSteps)
        if (!states[step.id]!.isExact) targetByStep[step.id]!,
    ];
    plan.recoversWithoutStage = _recoversWithoutStage(
      stageInspection,
      unfinishedTargets,
      states,
    );
    if (_needsLostStage(
      unit,
      stageInspection,
      publicSteps,
      states,
      recoversWithoutStage: plan.recoversWithoutStage,
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
              'staged this release. Its recorded archive bytes cannot be '
              'recreated byte-for-byte after a public target has bound them.',
        ),
      );
      if (!stageOnly) _publication.showActions(targets, publicActions);
      return null;
    }
    if (!stageInspection.reusable && !plan.recoversWithoutStage) {
      final refusal = _refuseIfUnfinishable(unit);
      if (refusal != null) {
        output.halt(HaltKind.beforeActing);
        output.problem(refusal);
        if (!stageOnly) _publication.showActions(targets, publicActions);
        return null;
      }
    }

    if (!stageOnly) {
      // Stage-only mode keeps its explicit ability to replace
      // reviewed-but-invalid bytes. A real release refuses that ambiguity
      // before any local preparation.
      final stageProblem = plan.recoversWithoutStage
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
        return null;
      }
    }

    if (plan.recoversWithoutStage) return plan;
    final staging = await _stages.begin(
      unit: unit,
      checklist: checklist,
      targets: targets,
      targetStages: inspector.targets.stages(unit: unit, targets: targets),
      stage: stage,
      inspected: stageInspection,
      claims: releaseHistory.claims,
      fromSource: await _fromSource(unit),
    );
    if (staging == null) {
      if (!stageOnly) _publication.showActions(targets, publicActions);
      return null;
    }
    return plan..staging = staging;
  }

  /// Builds or reuses every stage in [stagings], all at once, by unit name;
  /// a null result is a unit whose staging refused and said why. Several
  /// units share one board.
  Future<Map<String, PreparedRelease?>> _stage(
    List<UnitStaging> stagings,
  ) async {
    if (stagings.isEmpty) return const {};
    if (stagings.length == 1) {
      final staging = stagings.single;
      return {
        staging.unit.name: await Timings.span(
          'stage ${staging.unit.name}',
          () => _stages.complete(staging),
        ),
      };
    }
    final live = output.progressBoard(
      'staging ${stagings.length} units',
      emitSlowToNonTerminal: true,
    );
    final shared = [
      for (final staging in stagings)
        StageReleaseProgress.shared(
          live,
          board: staging.board,
          unit: '${staging.unit.name} ${staging.unit.version}',
        ),
    ];
    final prepared = await Future.wait([
      for (final (index, staging) in stagings.indexed)
        Timings.span(
          'stage ${staging.unit.name}',
          () => _stages.complete(staging, shared: shared[index]),
        ),
    ]);
    if (prepared.every((result) => result != null)) {
      live.settle(title: '${stagings.length} units staged');
    } else {
      live.conclude();
    }
    return {
      for (final (index, staging) in stagings.indexed)
        staging.unit.name: prepared[index],
    };
  }

  /// Finishes [plan]'s unit once its stage is built ([prepared]; null when
  /// staging refused): says what was staged, and hands publication the
  /// plan it acts on.
  ({int code, PublicationPlan? publication}) _finishRelease(
    _ReleasePlan plan,
    PreparedRelease? prepared,
  ) {
    final _ReleasePlan(:unit, :stage, :publicSteps, :publicActions) = plan;
    final checklist = plan.inspected.checklist;
    final targets = plan.inspected.targets;
    final states = plan.inspected.states;
    final localOnly = publicSteps.isEmpty;
    if (plan.alreadyReleased) {
      if (stageOnly) {
        output.line(
          '${unit.name} ${unit.version}',
          mark: Mark.satisfied,
          note: 'already released',
        );
        return (code: ExitCodes.ok, publication: null);
      }
      return (
        code: ExitCodes.ok,
        publication: PublicationPlan(
          unit: unit,
          steps: checklist.steps,
          publicSteps: publicSteps,
          targets: targets,
          states: states,
          actions: publicActions,
          prepared: PreparedRelease(
            claims: plan.inspected.history.claims,
            signing: null,
          ),
          stage: stage,
          recoversWithoutStage: true,
        ),
      );
    }

    final reusedStage = plan.stageInspection.reusable;
    if (plan.recoversWithoutStage) {
      prepared = PreparedRelease(claims: const [], signing: null);
    } else {
      if (prepared == null) {
        if (!stageOnly) _publication.showActions(targets, publicActions);
        return (code: ExitCodes.refused, publication: null);
      }
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
      if (stageOnly) return (code: ExitCodes.ok, publication: null);
    }

    return (
      code: ExitCodes.ok,
      publication: PublicationPlan(
        unit: unit,
        steps: checklist.steps,
        publicSteps: publicSteps,
        targets: targets,
        states: states,
        actions: publicActions,
        prepared: prepared,
        stage: stage,
        recoversWithoutStage: plan.recoversWithoutStage,
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
                .recoversWithoutStage(state);
      });

  /// Whether a partial public release needs the exact stage it no longer has.
  /// Only built release assets make the original stage recovery-critical; a
  /// unit without them, or a pub.dev package, stages again from its commit.
  /// Unread destinations cannot authorize reconstruction once unit-level
  /// release progress is established.
  bool _needsLostStage(
    ResolvedUnit unit,
    StageInspection stageInspection,
    List<Step> publicSteps,
    Map<String, Inspection> states, {
    required bool recoversWithoutStage,
  }) =>
      !_releasedElsewhere(publicSteps, states) &&
      !stageInspection.reusable &&
      !recoversWithoutStage &&
      hasRecoveryCriticalPublicProgress(unit, [
        for (final step in publicSteps) (step, states[step.id]!),
      ]) &&
      publicSteps.any((step) {
        final state = states[step.id]!;
        return state.isAbsent || state.verdict == Verdict.unknown;
      });

  /// Whether an earlier commit released this version. It is public from that
  /// commit's stage, not from one this commit could have lost: what remains
  /// of it is finished there (RK-GIT-009), and what cannot be read, including
  /// a tag whose commit this clone has yet to fetch, says so.
  static bool _releasedElsewhere(
    List<Step> publicSteps,
    Map<String, Inspection> states,
  ) => publicSteps.any((step) => states[step.id]!.releasedFrom != null);

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
    // Staging is private: only the tag a release pushes needs a commit
    // origin can fetch.
    if (!stageOnly && unit.publish.contains(PublishTarget.gitTag)) {
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

/// One unit's public reads, started before any unit is shown.
final class _UnitReads {
  _UnitReads({
    required this.checklist,
    required this.targets,
    required this.stage,
    required this.stageInspection,
    required this.states,
    required this.history,
    required this.problems,
  });

  final Checklist checklist;
  final List<TargetPlan> targets;
  final ReleaseStage stage;
  final StageInspection stageInspection;

  /// Each step's state as it arrives, by step id.
  final Map<String, Future<Inspection>> states;

  /// The lanes' version history.
  final Future<ReleaseHistoryCheck> history;

  /// What the history read refuses.
  final Diagnostics problems;
}

/// One unit's release after its checks: what staging it needs, if any.
final class _ReleasePlan {
  _ReleasePlan({
    required this.inspected,
    required this.stage,
    required this.stageInspection,
    required this.publicSteps,
    required this.publicActions,
    required this.alreadyReleased,
  });

  final _InspectedUnit inspected;
  final ReleaseStage stage;
  final StageInspection stageInspection;
  final List<Step> publicSteps;
  final Map<String, ReleaseAction> publicActions;
  final bool alreadyReleased;

  /// Whether every remaining target can finish from public inputs alone.
  var recoversWithoutStage = false;

  /// The stage to build or reuse; null when none is needed.
  UnitStaging? staging;

  ResolvedUnit get unit => inspected.unit;
}

/// The one public snapshot a release takes of a unit, before staging. It
/// carries no session or permission to perform a public operation.
final class _InspectedUnit {
  _InspectedUnit({
    required this.unit,
    required this.checklist,
    required Iterable<TargetPlan> targets,
    required Map<String, Inspection> states,
    required this.history,
    required this.stage,
    required this.stageInspection,
  }) : targets = List.unmodifiable(targets),
       states = Map.unmodifiable(states);

  final ResolvedUnit unit;
  final Checklist checklist;
  final List<TargetPlan> targets;
  final Map<String, Inspection> states;
  final ReleaseHistoryCheck history;
  final ReleaseStage stage;
  final StageInspection stageInspection;
}
