import 'dart:async';
import 'dart:io';

import '../builds/capability.dart';
import '../builds/macos_identity.dart';
import '../engine/assets.dart';
import '../engine/changelog.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../output/output.dart';
import '../engine/inspect.dart';
import '../engine/publish_target.dart';
import '../engine/registry.dart';
import '../engine/release_dependencies.dart';
import '../engine/resolve.dart';
import '../engine/source_tree.dart';
import '../engine/stage.dart';
import '../engine/tools.dart';
import '../engine/unit_release.dart';
import '../engine/unit_snapshot.dart';
import '../engine/verdict.dart';
import '../targets/target_module.dart';
import 'release_progress.dart';
import 'release_publish.dart';
import 'release_stage.dart';
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
    required this.inspector,
    required this.tools,
    required this.output,
    required this.confirm,
    required this.allowInteractiveTools,
    this.stageOnly = false,
    Stage Function(ResolvedUnit unit)? stageFor,
    Map<String, String> Function()? refreshEnvironment,
    Future<void> Function(Duration)? wait,
    required this.capabilities,
  }) : _wait = wait ?? _sleep,
       _stageFor = stageFor ?? _stagesAt(git, tree),
       _refreshEnvironment =
           refreshEnvironment ??
           (() => Map<String, String>.of(Platform.environment));

  static Future<void> _sleep(Duration duration) =>
      Future<void>.delayed(duration);

  static Stage Function(ResolvedUnit unit) _stagesAt(
    GitState git,
    SourceTree tree,
  ) {
    final stages = Stages(git.root);
    return (unit) => stages.of(unit, git, tree);
  }

  final Resolution resolution;
  final SourceTree tree;

  /// The repository: the commit a stage is built from, and what it says
  /// about the worktree around it.
  final GitState git;

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

  final Stage Function(ResolvedUnit unit) _stageFor;

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

  final Map<String, String> Function() _refreshEnvironment;

  late final _stages = StageRunner(
    initialGit: git,
    output: output,
    tools: tools,
    capabilities: capabilities,
    targets: inspector.targets,
  );

  late final _publication = Publication(
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
    output.repository(
      tree.description.split('/').last,
      git: git,
      uncommitted: git.uncommitted.length,
      source: true,
      show: false,
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
      output.halt(Stop.refused);
      return ExitCodes.refused;
    }
    return _runRepository(ordered);
  }

  Future<int> _runRepository(List<ResolvedUnit> selected) async {
    final runs = await _prepareRepository(selected);
    output.flushWarnings();
    if (runs == null) return ExitCodes.refused;
    if (stageOnly || runs.isEmpty) return ExitCodes.ok;
    output.timeline.phase('publishing');
    final public = [
      for (final run in runs)
        if (run.read.targets.isNotEmpty) run.read.unit,
    ];
    if (public.isNotEmpty) {
      output.heading(
        'Release order: '
        '${public.map((unit) => '${unit.name} ${unit.version}').join(' › ')}',
      );
      output.blank();
    }
    if (!await _publication.authorize(runs)) {
      return ExitCodes.refused;
    }
    for (final run in runs) {
      final code = await _publication.publish(run);
      if (code != ExitCodes.ok) return code;
    }
    return ExitCodes.ok;
  }

  /// Finishes every selected private stage before returning any public work:
  /// every unit's run, ready to publish, or null when one refused. A later
  /// preparation failure preserves earlier stages without acquiring
  /// sessions.
  Future<List<UnitRun>?> _prepareRepository(List<ResolvedUnit> selected) async {
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
    if (!_validateRepositoryScope(selected)) return null;
    _sayRun(selected);
    output.timeline.phase('preparing');
    // Every unit's destinations are read at once; each unit is then shown,
    // in release order, as its answers arrive.
    final runs = [for (final unit in selected) _startReads(unit)];
    for (final run in runs) {
      final read = await Timings.span(
        'inspect ${run.read.unit.name}',
        () => _inspectRelease(run),
      );
      if (!read) return null;
    }
    // Every unit's destinations are checked before any unit spends private
    // work: a conflict or an unready target in the last unit refuses before
    // the first one builds.
    for (final run in runs) {
      if (!_admit(run.read)) return null;
      final ready = await Timings.span(
        'check readiness ${run.read.unit.name}',
        () => _publication.checkReadiness(run),
      );
      if (!ready) return null;
    }
    if (!runs.every((run) => run.read.released)) {
      output.timeline.phase('staging');
    }
    // Each unit is checked, and its signing settled, one at a time in
    // release order. Then every unit that needs a stage builds at once, and
    // each is finished in release order again.
    for (final run in runs) {
      final planned = await Timings.span(
        'plan ${run.read.unit.name}',
        () => _planRelease(run),
      );
      if (!planned) return null;
    }
    final staging = [
      for (final run in runs)
        if (!run.read.released && !run.recovering) run,
    ];
    Future<List<UnitRun>?> finish() async {
      final staged = await _stage(staging);
      // The warnings every unit found while staging, said once, in release
      // order whichever unit finished first.
      output.flushWarnings(order: [for (final run in runs) run.read.unit.name]);
      // Every unit's staging is said, even past one that failed: once, for
      // all of them.
      var refused = false;
      final said = <UnitRun>[];
      final ready = <UnitSnapshot>[];
      for (final run in runs) {
        final finished = _finishRelease(run, staged: staged.contains(run));
        if (!finished.ok) {
          refused = true;
          continue;
        }
        if (finished.said) said.add(run);
        if (finished.readyToPublish) ready.add(run.read);
      }
      if (said.isNotEmpty) _sayStaged(said);
      if (!refused && ready.isNotEmpty) _sayReadyToPublish(ready);
      return refused ? null : runs;
    }

    // Units staged side by side say how they stopped once, after all of
    // them have said what they staged.
    return staging.length > 1 ? output.holdingHalts(finish) : finish();
  }

  /// Says once what this run stages or releases, and from which commit.
  void _sayRun(List<ResolvedUnit> selected) {
    final publishes = selected.any(
      (unit) =>
          unit.publish.isNotEmpty ||
          unit.projects.any((project) => project.publish.isNotEmpty),
    );
    output.heading(
      '${!stageOnly && publishes ? 'Releasing' : 'Staging'} '
      '${_series([for (final unit in selected) '${unit.name} ${unit.version}'])}',
    );
    output.line(
      [
        tree.description.split('/').last,
        '${git.branch ?? 'detached'}@${git.shortHead}',
      ].join(' · '),
      role: VisualRole.secondary,
    );
    output.blank();
  }

  /// Whether nothing the snapshot read stops [read]'s unit before private
  /// work.
  bool _admit(UnitSnapshot read) {
    if (read.stageReadProblem case final problem?) {
      output.problem(problem, unit: read.unit.name);
      output.halt(Stop.refused);
      return false;
    }
    final partialStageLoss = read.partialStageLoss;
    final blocked = read.release.steps.where((step) {
      if (step.kind == StepKind.completeStage) return false;
      // A sibling the stage can take from this source waits for nothing
      // while staging, which is private. A sibling released in this run
      // publishes first, in dependency order, and is public before this
      // unit uploads. Only a release that needs a package some other run
      // must publish waits for it here.
      if (step is Requirement &&
          (read.released ||
              stageOnly ||
              _releasing.contains(step.provider.name))) {
        return false;
      }
      final state = read.states[step.id]!;
      return !(partialStageLoss && state.verdict == Verdict.unknown) &&
          Inspector.blocks(step, state);
    }).firstOrNull;
    if (blocked == null) return true;
    if (read.releasedFirstBy(blocked) case final sibling?) {
      // Released by itself, this unit would wait for a package its sibling
      // has yet to put on pub.dev. A repository release publishes it first.
      output.problem(
        Diagnostic(
          code: 'RK-REL-001',
          message:
              '${blocked.summary}: '
              '${read.states[blocked.id]!.detail ?? 'not published yet'}; '
              '${sibling.unitName} releases it',
          remedy:
              'release them together, in order: rk release — or release '
              '${sibling.unitName} first: rk release ${sibling.unitName}',
        ),
        unit: read.unit.name,
      );
      output.halt(Stop.refused);
      output.next('rk release');
      return false;
    }
    _publication.haltForState(read.unit, blocked, read.states[blocked.id]!);
    return false;
  }

  /// Cheap, source-owned refusals for every selected unit before preparation.
  /// Native contexts own package order; the release model must not reject a
  /// guessed publication cycle before discovery can select hosted fallback.
  bool _validateRepositoryScope(List<ResolvedUnit> units) {
    final unique = <String, Diagnostic>{};
    for (final unit in units) {
      final problems = Diagnostics();
      _validate(unit, problems);
      UnitRelease.derive(
        unit,
        resolution,
        repository: inspector.repository,
        problems: problems,
      );
      for (final problem in problems.found) {
        final key =
            '${problem.code}\u0000${problem.message}\u0000'
            '${problem.source ?? ''}';
        unique.putIfAbsent(key, () => problem);
      }
    }
    if (unique.isEmpty) return true;
    output.halt(Stop.refused);
    output.problems(unique.values.toList());
    return false;
  }

  /// Starts reading [unit]'s destinations and version history, showing
  /// nothing, so every unit's reads run at once.
  UnitRun _startReads(ResolvedUnit unit) => UnitRun(
    UnitSnapshot.start(
      unit,
      resolution: resolution,
      inspector: inspector,
      repository: inspector.repository,
      hasCommit: git.hasCommit,
      stageFor: _stageFor,
    ),
  );

  /// Shows [unit] as its answers arrive, and records them. False when what
  /// was read refuses the release.
  Future<bool> _inspectRelease(UnitRun run) async {
    final read = run.read;
    final ResolvedUnit(:name, :version) = read.unit;
    final board = targetBoard(
      output,
      '$name $version · preparing release',
      read.targets,
    );

    // Destinations are independent, so they are read together: every row
    // says what it is doing at once, and the wait is the slowest read
    // rather than their sum. The report is written afterwards in release
    // order, so the document never depends on which answer arrived first.
    for (final row in board.rows) {
      row.begin(Activities.checking);
    }
    await Future.wait([
      for (final target in read.targets)
        read.reads[target.id]!.then(
          (state) => observe(board[target.id], state),
        ),
    ]);
    await read.settle();
    for (final step in read.release.steps) {
      final state = read.states[step.id]!;
      output.report.step(
        step,
        verdict: state.verdict,
        detail: state.detail,
        evidence: state.evidence,
        action: run.actions[step]?.wire,
      );
    }

    final problems = Diagnostics();
    read.historyProblems.forEach(problems.report);
    read.tagProblems.forEach(problems.report);
    board.discard();
    if (problems.isEmpty) return true;
    output.halt(Stop.refused);
    output.problems(problems.found);
    return false;
  }

  /// Checks [run]'s unit against everything that refuses it before
  /// staging, and settles what its staging needs first. False when refused.
  Future<bool> _planRelease(UnitRun run) async {
    final read = run.read;
    final unit = read.unit;
    if (read.released) return true;
    final check = read.stageCheck!;

    bool refuse(Diagnostic problem, Stop stop) {
      output.halt(stop);
      output.problem(problem, unit: unit.name);
      if (!stageOnly) _publication.showActions(run);
      return false;
    }

    // A moving channel may finish from authenticated public inputs once the
    // stage is gone. Staging alone never does: it builds the stage.
    run.recovering = !stageOnly && read.recoversWithoutStage;
    if (read.needsLostStage(recovering: !stageOnly)) {
      return refuse(read.lostStageProblem, Stop.unfixable);
    }
    if (run.recovering) return true;
    if (!check.reusable) {
      if (_refuseIfUnfinishable(unit) case final refusal?) {
        return refuse(refusal, Stop.refused);
      }
    }
    // Stage-only mode keeps its explicit ability to replace
    // reviewed-but-invalid bytes. A real release refuses that ambiguity
    // before any local preparation.
    if (_stages.preparationProblem(unit, check, mayReplaceReviewed: stageOnly)
        case final problem?) {
      return refuse(problem, Stop.refused);
    }

    run.fromSource = await _fromSource(unit);
    if (!await _stages.begin(run)) {
      if (!stageOnly) _publication.showActions(run);
      return false;
    }
    return true;
  }

  /// Builds or reuses every stage in [staging], all at once: the runs whose
  /// stage is ready. One left out refused and said why. Several units share
  /// one board.
  Future<Set<UnitRun>> _stage(List<UnitRun> staging) async {
    if (staging.isEmpty) return const {};
    if (staging.length == 1) {
      final run = staging.single;
      final staged = await Timings.span(
        'stage ${run.read.unit.name}',
        () => _stages.run(run),
      );
      return {if (staged) run};
    }
    final live = output.board(
      'staging ${staging.length} units',
      heartbeat: true,
    );
    final shared = [
      for (final run in staging)
        StageRows(
          live,
          run.read.release,
          unit: '${run.read.unit.name} ${run.read.unit.version}',
        ),
    ];
    final staged = await Future.wait([
      for (final (index, run) in staging.indexed)
        Timings.span(
          'stage ${run.read.unit.name}',
          () => _stages.run(run, shared: shared[index]),
        ),
    ]);
    if (staged.every((ok) => ok)) {
      // A stage reused is not staged again: the title says which it was.
      final reused = staging.where((run) => run.read.stageReusable).length;
      final count = staging.length;
      live.settle(
        title: reused == 0
            ? '$count units staged'
            : reused == count
            ? '$count units · already staged'
            : '$count units · ${count - reused} staged, $reused already staged',
      );
    } else {
      live.conclude();
    }
    return {
      for (final (index, run) in staging.indexed)
        if (staged[index]) run,
    };
  }

  /// Finishes [run]'s unit once its stage is built ([staged]; false when
  /// staging refused): says what was staged. Not [ok] when staging refused;
  /// [said] when the run's closing summary names this unit's stage.
  ({bool ok, bool said, bool readyToPublish}) _finishRelease(
    UnitRun run, {
    required bool staged,
  }) {
    final read = run.read;
    final UnitSnapshot(:unit, :release, :targets) = read;
    final stage = read.stage!;
    if (read.released) {
      if (stageOnly) {
        output.line(
          '${unit.name} ${unit.version}',
          mark: Mark.satisfied,
          note: 'already released',
        );
      }
      return (ok: true, said: false, readyToPublish: false);
    }
    if (run.recovering) return (ok: true, said: false, readyToPublish: false);
    if (!staged) {
      if (!stageOnly) _publication.showActions(run);
      return (ok: false, said: false, readyToPublish: false);
    }

    final localOnly = targets.isEmpty;
    if (!stageOnly && !localOnly) {
      return (ok: true, said: false, readyToPublish: false);
    }
    output.report.step(
      release.barrier,
      verdict: Verdict.exact,
      detail: 'staged and validated',
      evidence: {'stage id': stage.id.id, 'stage path': stage.relativePath},
    );
    return (ok: true, said: true, readyToPublish: stageOnly && !localOnly);
  }

  /// Says, once for the run, what every unit's stage holds: the names its
  /// release would claim first, where local archives are, and whether each
  /// stage was built now or was already there.
  void _sayStaged(List<UnitRun> staged) {
    _sayStageClaims(
      [for (final run in staged) ...run.read.claims],
      [
        for (final run in staged)
          if (run.read.targets.isNotEmpty)
            if (run.identity case final signing? when signing.first) signing,
      ],
    );
    for (final run in staged) {
      final UnitSnapshot(:unit, :targets, :stage) = run.read;
      if (targets.isNotEmpty) continue;
      if (unit.binaryProject case final project?) {
        final archives =
            '${stage!.relativePath}/'
            '${ReleaseAssets.producerRoot(project)}/archives';
        output.blank();
        output.line(
          'Archives',
          note: staged.length == 1
              ? archives
              : '${unit.name} ${unit.version} · $archives',
          role: VisualRole.secondary,
          noteRole: VisualRole.secondary,
        );
      }
    }
    String names(Iterable<UnitRun> runs) => _series([
      for (final run in runs) '${run.read.unit.name} ${run.read.unit.version}',
    ]);
    final built = staged.where((run) => !run.read.stageReusable).toList();
    final reused = staged.where((run) => run.read.stageReusable).toList();
    output.blank();
    output.line(
      '${[if (built.isNotEmpty) '${names(built)} staged successfully', if (reused.isNotEmpty) '${names(reused)} ${reused.length == 1 ? 'is' : 'are'} already staged and verified'].join('; ')}.',
      mark: Mark.done,
      strong: true,
    );
  }

  /// Says, once for the run, the command that publishes what [staged]
  /// holds: the unit's own `rk release`, unless several units were staged or
  /// the unit releases after a sibling — then the repository's, which
  /// publishes them in order.
  void _sayReadyToPublish(List<UnitSnapshot> staged) {
    final command = staged.length == 1 && !staged.single.releasesAfterSibling
        ? 'rk release ${staged.single.unit.name}'
        : 'rk release';
    // Only the tag a release pushes needs a commit origin can fetch. Until
    // origin has it, the release would refuse (RK-GIT-003), so that comes
    // first, and nothing is offered that would refuse.
    final unpushed =
        staged.any((read) => read.unit.publish.contains(PublishTarget.gitTag))
        ? git.unpushedProblem()
        : null;
    output.blank();
    if (unpushed != null) {
      output.warning(unpushed, depth: 1);
      output.line(
        'Ready to publish once origin has this commit: $command',
        depth: 1,
        role: VisualRole.operatorAction,
      );
      return;
    }
    output.report.next(command);
    output.line(
      'Ready to publish: $command',
      depth: 1,
      role: VisualRole.operatorAction,
    );
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
    // A stage is named by its commit, so every unit needs a clean one.
    if (git.stagingProblem() case final problem?) problems.report(problem);
    // Staging is private: only the tag a release pushes needs a commit
    // origin can fetch.
    if (!stageOnly && unit.publish.contains(PublishTarget.gitTag)) {
      final unpushed = git.unpushedProblem();
      if (unpushed != null) problems.report(unpushed);
    }
    for (final project in unit.projects) {
      Changelog.check(
        changelog: project.changelog,
        manifestDirectory: project.pubspec.directory,
        packageName: project.name,
        version: project.version,
        diagnostics: problems,
      );
    }
  }

  /// Shows irreversible first-claim facts beside the completed private
  /// stages: every unit's, under one heading.
  void _sayStageClaims(
    List<TargetClaim> claims,
    List<MacIdentity> firstSignings,
  ) {
    if (claims.isEmpty && firstSignings.isEmpty) return;
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
    for (final firstSigning in firstSignings) {
      output.line(
        'macOS code identifier',
        note: firstSigning.codeId,
        depth: 2,
        labelWidth: 26,
        noteRole: VisualRole.secondary,
      );
      output.line(
        'Apple team',
        note: _shortCertificate(firstSigning.certificate),
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

/// "a", "a and b", "a, b and c": several names in one sentence.
String _series(List<String> names) => names.length <= 2
    ? names.join(' and ')
    : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
