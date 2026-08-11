import '../builds/capability.dart';
import '../engine/changelog.dart';
import '../engine/checklist.dart';
import '../engine/assets.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/inspect.dart';
import '../engine/release_stage.dart';
import '../engine/resolve.dart';
import '../engine/source_tree.dart';
import '../engine/stage_inspection.dart';
import '../engine/targets.dart';
import '../engine/verdict.dart';
import '../engine/version.dart';
import '../output/output.dart';

/// A read-only snapshot of the configured release targets.
///
/// Status never proves that local work *can* be performed by performing it.
/// It reads public destinations and the exact stage receipt, then reports the
/// facts it has. `rk release --stage` is the command that does producer work.
class StatusCommand {
  StatusCommand({
    required this.resolution,
    required this.tree,
    required this.git,
    required this.inspector,
    required this.output,
    this.stageFor,
    HostCapabilities? capabilities,
  }) : capabilities = capabilities ?? HostCapabilities.inspect();

  final Resolution resolution;
  final SourceTree tree;
  final GitState git;
  final Inspector inspector;
  final Output output;
  final HostCapabilities capabilities;

  /// An explicit seam for filesystem tests. In normal composition the same
  /// resolver already installed on [inspector] is used.
  final ReleaseStage Function(ResolvedUnit unit)? stageFor;

  Future<int> run({String? only}) async {
    final units = only == null
        ? resolution.units
        : resolution.units.where((unit) => unit.name == only).toList();

    if (units.isEmpty) {
      output.problem(Diagnostic(
        code: 'RK-CLI-003',
        message: 'no unit named "$only"',
        remedy: 'this repository releases: '
            '${resolution.units.map((unit) => unit.name).join(', ')}',
      ));
      return ExitCodes.usage;
    }

    final repositoryProblems = Diagnostics();
    _checkRepositoryState(repositoryProblems);

    // Every public read is started before rendering. Future.wait preserves
    // this configured order even when providers answer in another one.
    final checking = output.targetChecks();
    final List<_UnitSnapshot> snapshots;
    try {
      snapshots = await Future.wait([
        for (final unit in units)
          _gather(unit, checking, qualifyLabel: units.length > 1),
      ]);
    } finally {
      checking.close();
    }

    output.repository(
      name: tree.description.split('/').last,
      branch: git.branch == null
          ? null
          : '${git.branch}@${git.head.substring(0, 7)}',
      uncommitted: git.uncommitted.length,
      head: git.head,
      remote: git.originUrl,
    );

    for (final snapshot in snapshots) {
      _renderUnit(snapshot);
    }

    final workRemains = snapshots.any(
      (snapshot) =>
          snapshot.targets.any((target) => !target.inspection.isExact),
    );
    final issues = <StatusIssue>[
      for (final snapshot in snapshots) ...snapshot.issues,
      if (workRemains)
        for (final diagnostic in repositoryProblems.found)
          StatusIssue(diagnostic: diagnostic),
    ];
    final uniqueIssues = _deduplicate(issues);
    if (uniqueIssues.isNotEmpty) _renderIssues(uniqueIssues);

    // Only a refusal concludes. rk does not congratulate itself: success is
    // the absence of an issue, the rows already say what is published and
    // what is staged, and exit 0 says it to anything parsing. The next
    // command stays in the document (`next[]`), where an agent reads it,
    // and off the report, where it was telling an operator what they had
    // just decided to do.
    if (uniqueIssues.isNotEmpty) {
      final count = uniqueIssues.length;
      output.blank();
      output.line(
        '$count ${count == 1 ? 'issue prevents' : 'issues prevent'} release',
        mark: Mark.blocked,
        tone: Tone.bad,
      );
    }

    final unfinished = snapshots
        .where((snapshot) => snapshot.targets.any(
              (target) => !target.inspection.isExact,
            ))
        .toList();
    if (uniqueIssues.isEmpty && unfinished.length == 1) {
      final snapshot = unfinished.single;
      output.report.next(
        snapshot.stage?.reusable == true
            ? 'rk release ${snapshot.unit.name}'
            : 'rk release ${snapshot.unit.name} --stage',
      );
    }

    // A status issue is a state to resolve, not a command crash.
    return ExitCodes.ok;
  }

  Future<_UnitSnapshot> _gather(
    ResolvedUnit unit,
    TargetChecks checking, {
    required bool qualifyLabel,
  }) async {
    final diagnostics = Diagnostics();
    final checklist = Checklist.derive(unit, resolution, diagnostics);

    for (final project in unit.projects) {
      Changelog.check(
        tree: tree,
        manifestDirectory: project.pubspec.directory,
        packageName: project.name,
        version: project.version,
        diagnostics: diagnostics,
      );
    }

    final stageResult = _inspectStage(unit);
    final expectations = inspector.targets.derive(
      unit,
      checklist,
      repository: git.originUrl,
    );
    final artifactProblems = _artifactProductionProblems(unit, expectations);
    for (final expectation in expectations) {
      checking.add(
        expectation.step.id,
        qualifyLabel
            ? '${unit.name} · ${expectation.label}'
            : expectation.label,
      );
    }

    // Calling every async operation before awaiting one is intentional: the
    // targets are independent network reads, and a slow forge must not delay
    // asking pub.dev (or vice versa).
    final targetFutures = [
      for (final expectation in expectations)
        _observeAndFinish(
          expectation,
          unit,
          stageResult.inspection,
          artifactProblems,
          checking,
        ),
    ];
    final prerequisiteSteps = checklist.steps
        .where((step) => step.kind == StepKind.prerequisite)
        .toList();
    final prerequisiteFutures = [
      for (final step in prerequisiteSteps) _inspectSafely(step, unit),
    ];
    final monotonicity = inspector.monotonicity(unit, diagnostics);

    var targets = await Future.wait(targetFutures);
    final prerequisites = await Future.wait(prerequisiteFutures);
    await monotonicity;

    final states = <String, Inspection>{
      for (final target in targets)
        target.expectation.step.id: target.inspection,
      for (final (index, step) in prerequisiteSteps.indexed)
        step.id: prerequisites[index],
    };

    for (final step in checklist.steps) {
      if (states.containsKey(step.id)) continue;
      states[step.id] = step.kind == StepKind.completeStage
          ? stageResult.state
          : step.phase == StepPhase.stage
              ? stageResult.inspection?.reusable == true
                  ? const Inspection.exact(
                      detail: 'validated in the release stage',
                    )
                  : const Inspection.unknown(
                      'local work, decided when it runs',
                    )
              // Public targets and prerequisites were populated above.
              : const Inspection.unknown('the target was not inspected');
    }

    for (final diagnostic in inspector.tagGuards(unit, checklist, states)) {
      diagnostics.report(diagnostic);
    }

    final partialBinaryWithoutStage = unit.shipsBinaries &&
        stageResult.inspection?.reusable != true &&
        targets.any((target) => target.inspection.isExact) &&
        targets.any((target) =>
            target.inspection.isAbsent ||
            target.inspection.verdict == Verdict.unknown);
    if (partialBinaryWithoutStage) {
      targets = [
        for (final target in targets)
          TargetObservation(
            expectation: target.expectation,
            inspection: target.inspection,
            currentVersion: target.currentVersion,
            currentKnown: target.currentKnown,
            currentDetail: target.currentDetail,
            artifacts: [
              for (final artifact in target.artifacts)
                artifact.status == ArtifactStatus.invalid
                    ? artifact
                    : ArtifactObservation(
                        name: artifact.name,
                        status: ArtifactStatus.invalid,
                        problem: 'the exact stage is required to finish the '
                            'partial public release',
                      ),
            ],
          ),
      ];
    }
    final issues = <StatusIssue>[
      for (final diagnostic in diagnostics.found)
        StatusIssue(
          unit: unit.name,
          target: _diagnosticTarget(diagnostic, targets),
          diagnostic: diagnostic,
        ),
      for (final target in targets)
        if (target.inspection.verdict == Verdict.conflict ||
            target.inspection.verdict == Verdict.unknown)
          _targetIssue(unit, target),
      for (final target in targets)
        if (!target.currentKnown &&
            target.inspection.verdict != Verdict.unknown &&
            target.inspection.verdict != Verdict.conflict)
          _currentVersionIssue(unit, target),
      for (final target in targets)
        if (_isAhead(target) && !_aheadAlreadyReported(target, diagnostics))
          _aheadIssue(unit, target),
      for (final step in prerequisiteSteps)
        if (Inspector.blocks(step, states[step.id]!))
          _prerequisiteIssue(unit, step, states[step.id]!),
      if (stageResult.issue != null &&
          !partialBinaryWithoutStage &&
          targets.any((target) => !target.inspection.isExact))
        stageResult.issue!,
      if (partialBinaryWithoutStage)
        StatusIssue(
          unit: unit.name,
          diagnostic: Diagnostic(
            code: 'RK-STAGE-005',
            message: '${unit.name}: the partial binary release needs its '
                'exact stage',
            remedy:
                'restore ${stageResult.path ?? '.rk/work/stages/<stage-id>'} '
                'from the machine that staged this release. Signed or '
                'notarized bytes cannot be recreated byte-for-byte after a '
                'public target has bound them.',
          ),
        ),
      if (artifactProblems.isNotEmpty &&
          !partialBinaryWithoutStage &&
          stageResult.inspection?.reusable != true &&
          targets.any((target) => !target.inspection.isExact))
        _hostIssue(unit),
    ];

    return _UnitSnapshot(
      unit: unit,
      checklist: checklist,
      states: states,
      targets: targets,
      stage: stageResult.inspection,
      issues: issues,
    );
  }

  Future<TargetObservation> _observeAndFinish(
    TargetExpectation expectation,
    ResolvedUnit unit,
    StageInspection? stage,
    Map<String, String> artifactProblems,
    TargetChecks checking,
  ) async {
    final observed = await _observeTarget(
      expectation,
      unit,
      stage,
      artifactProblems,
    );
    checking.finish(expectation.step.id, observed.inspection.verdict);
    return observed;
  }

  _StageResult _inspectStage(ResolvedUnit unit) {
    final factory = stageFor ?? inspector.stageFor;
    if (factory == null ||
        !_isFullObjectId(git.head) ||
        !_isFullObjectId(git.headTree)) {
      return const _StageResult(
        state: Inspection.absent(detail: 'not staged'),
      );
    }
    try {
      final stage = factory(unit);
      final inspected = stage.inspect();
      final ordinaryAbsence = inspected.receipt?.complete != true &&
          inspected.issues.every(
            (issue) =>
                issue.kind == StageIssueKind.missingReceipt ||
                issue.kind == StageIssueKind.incompleteReceipt,
          );
      return _StageResult(
        inspection: inspected,
        state: inspected.asInspection,
        path: stage.directory.path,
        issue: ordinaryAbsence || inspected.issues.isEmpty
            ? null
            : StatusIssue(
                unit: unit.name,
                diagnostic: Diagnostic(
                  code: 'RK-STAGE-002',
                  message: 'the reviewed release stage no longer validates',
                  remedy: 'rebuild it explicitly: '
                      'rk release ${unit.name} --stage',
                ),
                evidence: {
                  for (final issue in inspected.issues)
                    issue.path ?? issue.kind.name: issue.message,
                },
              ),
      );
    } on Object catch (error) {
      return _StageResult(
        state: Inspection.unknown(
          'the release stage could not be read: $error',
        ),
        issue: StatusIssue(
          unit: unit.name,
          diagnostic: Diagnostic(
            code: 'RK-STAGE-002',
            message: 'the release stage could not be inspected',
            remedy: 'fix the stage read error below, then rebuild it with '
                'rk release ${unit.name} --stage\n$error',
          ),
        ),
      );
    }
  }

  Future<TargetObservation> _observeTarget(
    TargetExpectation expectation,
    ResolvedUnit unit,
    StageInspection? stage,
    Map<String, String> artifactProblems,
  ) async {
    final inspectionFuture = _inspectSafely(expectation.step, unit);
    final latestFuture = _inspectLatestSafely(expectation, unit);

    final inspection = await inspectionFuture;
    final latest = await latestFuture;
    // A direct read of the candidate coordinate answers whether this release
    // exists. It does not answer whether a newer release exists. For registry,
    // tag, and forge lanes, only the provider's history/listing can answer the
    // separate "what version is this lane at?" question. Homebrew's exact
    // formula read already carries the authenticated current version.
    final currentInspection = latest ?? inspection;
    final reportedVersion = currentInspection.evidence['version'];
    final parsedVersion =
        reportedVersion == null ? null : Version.tryParse(reportedVersion);
    final current = parsedVersion != null
        ? _CurrentVersion(value: parsedVersion.canonical, known: true)
        : switch (currentInspection.verdict) {
            Verdict.absent => const _CurrentVersion(value: null, known: true),
            Verdict.exact ||
            Verdict.conflict ||
            Verdict.unknown =>
              const _CurrentVersion.unknown(),
          };

    return TargetObservation(
      expectation: expectation,
      inspection: inspection,
      currentVersion: current.value,
      currentKnown: current.known,
      currentDetail: currentInspection.detail,
      artifacts: [
        for (final name in expectation.artifacts)
          _observeArtifact(name, stage, artifactProblems[name]),
      ],
    );
  }

  Future<Inspection> _inspectSafely(Step step, ResolvedUnit unit) async {
    try {
      return await inspector.inspect(step, unit);
    } on Object catch (error) {
      return Inspection.unknown('the target read failed: $error');
    }
  }

  Future<Inspection?> _inspectLatestSafely(
    TargetExpectation target,
    ResolvedUnit unit,
  ) async {
    try {
      return await inspector.inspectLatestVersion(target, unit);
    } on Object catch (error) {
      return Inspection.unknown('the current version read failed: $error');
    }
  }

  ArtifactObservation _observeArtifact(
    String name,
    StageInspection? stage,
    String? productionProblem,
  ) {
    if (stage == null || stage.receipt?.complete != true) {
      if (productionProblem != null) {
        return ArtifactObservation(
          name: name,
          status: ArtifactStatus.invalid,
          problem: productionProblem,
        );
      }
      return ArtifactObservation(
        name: name,
        status: ArtifactStatus.notStaged,
      );
    }

    final related = stage.issues.where((issue) {
      final path = issue.path;
      if (path == null) return false;
      return path == name ||
          path.startsWith('$name/') ||
          name.startsWith('$path/');
    }).toList();
    if (!stage.reusable) {
      final usefulIssues = related.isEmpty ? stage.issues : related;
      final detail = usefulIssues.map((issue) => issue.toString()).join('; ');
      return ArtifactObservation(
        name: name,
        status: ArtifactStatus.invalid,
        problem: related.isNotEmpty
            ? related.map((issue) => issue.message).join('; ')
            : 'stage does not validate: $detail',
      );
    }

    final recorded = stage.receipt!.artifacts.any(
      (artifact) => artifact.path == name,
    );
    if (!recorded) {
      return ArtifactObservation(
        name: name,
        status: ArtifactStatus.invalid,
        problem: 'missing from the completed stage',
      );
    }
    return ArtifactObservation(name: name, status: ArtifactStatus.staged);
  }

  Map<String, String> _artifactProductionProblems(
    ResolvedUnit unit,
    List<TargetExpectation> targets,
  ) {
    final blocked = <String, String>{};
    for (final project in unit.projects) {
      for (final platform in project.binaryPlatforms) {
        final capability = capabilities.resolve(platform);
        if (!capability.canProduce) {
          blocked[platform] =
              capability.reason ?? 'this host cannot produce $platform';
        }
      }
    }
    if (blocked.isEmpty) return const {};

    final problems = <String, String>{};
    for (final project in unit.projects) {
      final executable = project.executable;
      if (executable == null) continue;
      for (final platform in project.binaryPlatforms) {
        final reason = blocked[platform];
        if (reason == null) continue;
        problems[ReleaseAssets.archiveName(
          executable,
          project.version.canonical,
          platform,
        )] = '$platform cannot be produced here: $reason';
      }
      final summary = blocked.entries
          .map((entry) => '${entry.key}: ${entry.value}')
          .join('; ');
      problems[ReleaseAssets.checksums] =
          'cannot be finalized until every archive exists: $summary';
      problems[ReleaseAssets.manifest] =
          'cannot be finalized until every release artifact exists: $summary';
    }
    for (final stage
        in inspector.targets.stages(unit: unit, targets: targets)) {
      final blockedInputs =
          stage.contract.step.inputs.where(problems.containsKey).toList();
      if (blockedInputs.isEmpty) continue;
      final reason =
          blockedInputs.map((input) => '$input: ${problems[input]}').join('; ');
      for (final output in stage.contract.step.outputs.keys) {
        problems[output] = 'cannot be produced until $reason';
      }
    }
    return Map.unmodifiable(problems);
  }

  StatusIssue _hostIssue(ResolvedUnit unit) {
    final byReason = <String, List<String>>{};
    for (final project in unit.projects) {
      for (final platform in project.binaryPlatforms) {
        final capability = capabilities.resolve(platform);
        if (capability.canProduce) continue;
        byReason
            .putIfAbsent(
              capability.reason ?? 'it needs a different host',
              () => [],
            )
            .add(platform);
      }
    }
    final facts = byReason.entries
        .map((entry) => '${entry.value.join(', ')} — ${entry.key}')
        .join('\n');
    return StatusIssue(
      unit: unit.name,
      diagnostic: Diagnostic(
        code: 'RK-HOST-001',
        message: '${unit.name}: this machine cannot produce every platform '
            'it ships',
        remedy: 'stage this unit on a host that can produce:\n$facts',
      ),
    );
  }

  StatusIssue _targetIssue(
    ResolvedUnit unit,
    TargetObservation target,
  ) {
    final state = target.inspection;
    final label = target.expectation.label;
    return StatusIssue(
      unit: unit.name,
      target: target.expectation.step.id,
      diagnostic: Diagnostic(
        code: 'RK-REL-001',
        message: '$label: ${_condition(state)}',
        remedy: state.verdict == Verdict.unknown
            ? 'restore read access to $label, then run '
                'rk status ${unit.name} again'
            : _targetConflictRemedy(unit, target),
      ),
      evidence: state.evidence,
    );
  }

  String _targetConflictRemedy(
    ResolvedUnit unit,
    TargetObservation target,
  ) =>
      inspector.targets
          .moduleForTarget(target.expectation)
          .conflictRemedy(unit, target.expectation);

  StatusIssue _currentVersionIssue(
    ResolvedUnit unit,
    TargetObservation target,
  ) =>
      StatusIssue(
        unit: unit.name,
        target: target.expectation.step.id,
        diagnostic: Diagnostic(
          code: 'RK-REL-001',
          message: '${target.expectation.label}: the current public version '
              'could not be established',
          remedy: 'restore read access to ${target.expectation.label}, then '
              'run rk status ${unit.name} again',
        ),
        evidence: {
          if (target.currentDetail != null)
            'current version': target.currentDetail!,
        },
      );

  bool _isAhead(TargetObservation target) {
    final current = target.currentVersion == null
        ? null
        : Version.tryParse(target.currentVersion!);
    final intended = Version.tryParse(target.expectation.targetVersion);
    return current != null && intended != null && current > intended;
  }

  bool _aheadAlreadyReported(
    TargetObservation target,
    Diagnostics diagnostics,
  ) {
    final module = inspector.targets.moduleForTarget(target.expectation);
    return diagnostics.found.any(
      (problem) => module.ownsDiagnostic(problem, target.expectation),
    );
  }

  StatusIssue _aheadIssue(
    ResolvedUnit unit,
    TargetObservation target,
  ) {
    final current = Version.tryParse(target.currentVersion!)!;
    final diagnostic = inspector.targets
        .moduleForTarget(target.expectation)
        .aheadDiagnostic(unit, target.expectation, current)!;
    return StatusIssue(
      unit: unit.name,
      target: target.expectation.step.id,
      diagnostic: diagnostic,
    );
  }

  StatusIssue _prerequisiteIssue(
    ResolvedUnit unit,
    Step step,
    Inspection state,
  ) {
    ResolvedProject? declaring;
    for (final project in resolution.allProjects) {
      if (step.coordinate == 'pub.dev/${project.name}/${project.version}') {
        declaring = project;
        break;
      }
    }
    return StatusIssue(
      unit: unit.name,
      diagnostic: Diagnostic(
        code: 'RK-REL-001',
        message: '${step.summary}: ${_condition(state)}',
        remedy: declaring != null && state.isAbsent
            ? 'publish the prerequisite first: '
                'rk release ${declaring.unitName}'
            : 'restore read access to the prerequisite, then run '
                'rk status ${unit.name} again',
      ),
      evidence: state.evidence,
    );
  }

  void _renderUnit(_UnitSnapshot snapshot) {
    final currentVersions = {
      for (final target in snapshot.targets) target.currentVersion,
    };
    final allCurrentsKnown = snapshot.targets.isNotEmpty &&
        snapshot.targets.every((target) => target.currentKnown);
    final agreedCurrent = allCurrentsKnown && currentVersions.length == 1
        ? currentVersions.single
        : null;
    final version = snapshot.unit.version.canonical;

    // The unit line carries movement and nothing else. Whether that version
    // is out there is the publication section's verdict, one line down —
    // naming a place and then the state of that place made two headers
    // argue about one fact.
    final movement = agreedCurrent != null && agreedCurrent != version
        ? '$agreedCurrent › $version'
        : version;
    final tag = snapshot.unit.tag == 'v$version' ? null : snapshot.unit.tag;
    output.unit(
      snapshot.unit.name,
      version: version,
      tag: snapshot.unit.tag,
      display: tag == null ? movement : '$movement · $tag',
    );
    for (final step in snapshot.checklist.steps) {
      // Public targets are recorded once, in targets[], where the settled
      // observation lives; recording them under steps[] too made two
      // spellings of the same fact and left a caller guessing which one is
      // canonical.
      if (step.kind.targetName != null) continue;
      _record(step, snapshot.states[step.id]!);
    }
    for (final target in snapshot.targets) {
      _recordTarget(snapshot, target);
    }

    _renderPublication(snapshot);
    _renderStage(snapshot);
  }

  /// Where each target stands publicly.
  ///
  /// The state is the heading, because the words already say which world
  /// they describe: published is public, staged is here. A row then only
  /// has to identify the thing it is about, and only carries a mark when it
  /// disagrees with the others.
  void _renderPublication(_UnitSnapshot snapshot) {
    if (snapshot.targets.isEmpty) return;
    final currents = {for (final t in snapshot.targets) t.currentVersion};
    final headerStatedMovement =
        snapshot.targets.every((t) => t.currentKnown) && currents.length == 1;
    final verdicts = snapshot.targets.map((t) => t.inspection.verdict).toSet();
    final agreed = verdicts.length == 1 ? verdicts.single : null;
    final anyExact = snapshot.targets.any((t) => t.inspection.isExact);

    output.blank();
    output.line(
      switch (agreed) {
        Verdict.exact => 'Published',
        Verdict.absent => 'Not published',
        Verdict.conflict => 'Does not match',
        Verdict.unknown => 'Could not be read',
        null => anyExact ? 'Partly published' : 'Not published',
      },
      depth: 1,
      tone: Tone.header,
    );

    for (final target in snapshot.targets) {
      final state = target.inspection;
      final linked = snapshot.issues.any(
        (issue) => issue.target == target.expectation.step.id,
      );
      final tone = linked ? Tone.bad : Tone.of(state.verdict);
      final speaks =
          state.verdict == Verdict.conflict || state.verdict == Verdict.unknown;
      output.line(
        target.kindLabel,
        mark: linked
            ? Mark.blocked
            : agreed != null
                ? Mark.none
                : switch (state.verdict) {
                    Verdict.exact => Mark.done,
                    Verdict.conflict => Mark.blocked,
                    Verdict.absent || Verdict.unknown => Mark.none,
                  },
        note: speaks
            ? _condition(state)
            : headerStatedMovement
                ? target.identity
                : '${target.identity} · '
                    '${target.currentKnown ? target.currentVersion ?? '—' : '?'}'
                    ' › ${target.expectation.targetVersion}',
        depth: 2,
        labelWidth: 30,
        tone: tone,
        noteTone: speaks ? tone : Tone.muted,
      );
    }
  }

  /// What this repository has ready to publish.
  ///
  /// Absent once every target is public: those files are out there, and
  /// what is on this disk stopped being something anyone can act on.
  void _renderStage(_UnitSnapshot snapshot) {
    final staged = snapshot.stage?.reusable == true;
    final rows = <(TargetObservation, String, ArtifactStatus)>[
      for (final target in snapshot.targets)
        if (!target.inspection.isExact)
          if (target.expectation.kind == 'pubDev')
            (
              target,
              'package source',
              staged ? ArtifactStatus.staged : ArtifactStatus.notStaged
            )
          else if (target.artifacts.isNotEmpty)
            (
              target,
              target.stagedSummary,
              target.artifacts
                  .map((artifact) => artifact.status)
                  .reduce((a, b) => a == b ? a : ArtifactStatus.invalid)
            ),
    ];
    if (rows.isEmpty) return;

    final statuses = {for (final row in rows) row.$3};
    final agreed = statuses.length == 1 ? statuses.single : null;

    output.blank();
    output.line(
      switch (agreed) {
        ArtifactStatus.staged => 'Staged',
        ArtifactStatus.notStaged => 'Not staged',
        ArtifactStatus.invalid => 'Cannot be staged',
        null => 'Partly staged',
      },
      depth: 1,
      tone: Tone.header,
    );

    for (final (target, summary, status) in rows) {
      final invalid = target.artifacts
          .where((a) => a.status == ArtifactStatus.invalid)
          .toList();
      output.line(
        target.kindLabel,
        mark: agreed != null ? Mark.none : _artifactMark(status),
        note: summary,
        depth: 2,
        labelWidth: 30,
        tone: Tone.plain,
        noteTone: Tone.muted,
      );
      // A broken artifact is named, always: which one and why are the only
      // questions it raises, and a count answers neither.
      for (final artifact in invalid) {
        output.line(
          artifact.name,
          mark: Mark.blocked,
          note: artifact.problem,
          depth: 3,
          labelWidth: 36,
          tone: Tone.bad,
          noteTone: Tone.bad,
        );
      }
    }
  }

  void _recordTarget(_UnitSnapshot snapshot, TargetObservation target) {
    final state = target.inspection;
    output.report.target(
      unit: snapshot.unit.name,
      id: target.expectation.step.id,
      kind: target.expectation.kind,
      label: target.expectation.label,
      coordinate: target.expectation.coordinate,
      targetVersion: target.expectation.targetVersion,
      verdict: state.verdict.name,
      currentKnown: target.currentKnown,
      currentVersion: target.currentVersion,
      detail: state.detail,
      uses: target.expectation.uses,
      artifacts: [
        for (final artifact in target.artifacts)
          {
            'name': artifact.name,
            'status': artifact.status.name,
            if (artifact.problem != null) 'problem': artifact.problem,
          },
      ],
    );
  }

  static Mark _artifactMark(ArtifactStatus status) => switch (status) {
        ArtifactStatus.notStaged => Mark.none,
        ArtifactStatus.staged => Mark.done,
        ArtifactStatus.invalid => Mark.blocked,
      };

  void _renderIssues(List<StatusIssue> issues) {
    output.blank();
    output.heading('Issues');
    final severalUnits = resolution.units.length > 1;
    for (final issue in issues) {
      output.report.problem(
        issue.diagnostic,
        unit: issue.unit,
        target: issue.target,
      );
      final diagnostic = issue.diagnostic;
      final where = diagnostic.source == null ? '' : '${diagnostic.source}  ';
      final unit = severalUnits && issue.unit != null ? '${issue.unit} · ' : '';
      output.line(
        '$unit$where${diagnostic.message} · ${diagnostic.code}',
        mark: Mark.blocked,
        depth: 1,
        tone: Tone.bad,
      );
      for (final entry in issue.evidence.entries) {
        output.line(
          '${entry.key}: ${entry.value}',
          depth: 2,
          tone: Tone.muted,
        );
      }
      output.say(
        'Fix: ${diagnostic.remedy ?? 'correct this condition, then run rk status again'}',
        depth: 2,
      );
    }
  }

  static String _condition(Inspection state) => switch (state.verdict) {
        Verdict.exact => state.detail ?? 'published exactly',
        Verdict.absent => 'not published${_detailSuffix(state.detail)}',
        Verdict.conflict => 'does not match${_detailSuffix(state.detail)}',
        Verdict.unknown => 'could not be read${_detailSuffix(state.detail)}',
      };

  static String _detailSuffix(String? detail) =>
      detail == null || detail.isEmpty ? '' : ': $detail';

  static bool _isFullObjectId(String value) =>
      RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$').hasMatch(value);

  static List<StatusIssue> _deduplicate(Iterable<StatusIssue> issues) {
    final seen = <String>{};
    return [
      for (final issue in issues)
        if (seen.add(issue.deduplicationKey)) issue,
    ];
  }

  String? _diagnosticTarget(
    Diagnostic diagnostic,
    List<TargetObservation> targets,
  ) {
    for (final target in targets) {
      final expectation = target.expectation;
      if (inspector.targets
          .moduleForTarget(expectation)
          .ownsDiagnostic(diagnostic, expectation)) {
        return expectation.step.id;
      }
    }
    return null;
  }

  void _record(Step step, Inspection state) {
    output.step(
      step,
      show: false,
      verdict: state.verdict,
      detail: state.detail,
      evidence: state.evidence,
    );
  }

  void _checkRepositoryState(Diagnostics problems) {
    final uncommitted = git.uncommittedProblem();
    if (uncommitted != null) problems.report(uncommitted);
    final unpushed = git.unpushedProblem();
    if (unpushed != null) problems.report(unpushed);
  }
}

class _UnitSnapshot {
  _UnitSnapshot({
    required this.unit,
    required this.checklist,
    required Map<String, Inspection> states,
    required Iterable<TargetObservation> targets,
    required this.stage,
    required Iterable<StatusIssue> issues,
  })  : states = Map<String, Inspection>.unmodifiable(states),
        targets = List<TargetObservation>.unmodifiable(targets),
        issues = List<StatusIssue>.unmodifiable(issues);

  final ResolvedUnit unit;
  final Checklist checklist;
  final Map<String, Inspection> states;
  final List<TargetObservation> targets;
  final StageInspection? stage;
  final List<StatusIssue> issues;
}

class _StageResult {
  const _StageResult({
    required this.state,
    this.inspection,
    this.issue,
    this.path,
  });

  final StageInspection? inspection;
  final Inspection state;
  final StatusIssue? issue;
  final String? path;
}

class _CurrentVersion {
  const _CurrentVersion({required this.value, required this.known});
  const _CurrentVersion.unknown() : this(value: null, known: false);

  final String? value;
  final bool known;
}
