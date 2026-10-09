import '../builds/capability.dart';
import '../engine/changelog.dart';
import '../engine/assets.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/inspect.dart';
import '../engine/publish_target.dart';
import '../engine/release_stage.dart';
import '../engine/resolve.dart';
import '../engine/source_tree.dart';
import '../engine/stage_inspection.dart';
import '../engine/unit_release.dart';
import '../engine/unit_snapshot.dart';
import '../engine/verdict.dart';
import '../engine/version.dart';
import '../output/output.dart';
import '../targets/target_module.dart';

/// A read-only snapshot of the configured release targets.
///
/// Status never proves that local work *can* be performed by performing it.
/// It reads public destinations and the exact stage receipt, then reports the
/// facts it has. `rk stage` is the command that does producer work.
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

  /// The repository: the commit a stage is built from, and what it says
  /// about the worktree around it.
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

    final snapshot = await collect(only: only, checking: output.targetChecks());
    render(snapshot);
    return ExitCodes.ok;
  }

  /// Read once for the text and JSON reports. Progress uses the same publication
  /// interpretation as the completed snapshot, including release blockers.
  Future<StatusSnapshot> collect({String? only, TargetChecks? checking}) async {
    // Units are shown in the order a repository release takes them,
    // dependencies first. A circle has no order, and refuses the release.
    final ordering = Diagnostics();
    final ordered = resolution.dependencyPlan.units(ordering);
    final units = only == null
        ? ordered
        : ordered.where((u) => u.name == only).toList();
    if (units.isEmpty) throw ArgumentError('No release unit named $only');
    final repositoryProblems = Diagnostics();
    _checkRepositoryState(repositoryProblems, units);

    // Every public read is started before rendering. Future.wait preserves
    // this order even when providers answer in another one.
    final List<StatusUnitSnapshot> snapshots;
    try {
      snapshots = await Future.wait([
        for (final unit in units)
          _gather(unit, checking, group: units.length > 1 ? unit.name : null),
      ]);
    } finally {
      checking?.close();
    }

    final workRemains = snapshots.any(_workRemains);
    final issues = <StatusIssue>[
      for (final diagnostic in ordering.found)
        if (diagnostic.code == 'RK-DEP-004')
          StatusIssue(diagnostic: diagnostic),
      for (final snapshot in snapshots) ...snapshot.issues,
      if (workRemains)
        for (final diagnostic in repositoryProblems.found)
          StatusIssue(diagnostic: diagnostic),
    ];
    final uniqueIssues = _deduplicate(issues);
    String? nextCommand;
    final unfinished = snapshots.where(_workRemains).toList();
    bool readyToRelease(StatusUnitSnapshot snapshot) =>
        _isLocalOnlyOutput(snapshot) ||
        snapshot.stage?.reusable == true ||
        snapshot.observed.recoversWithoutStage;
    if (uniqueIssues.isEmpty && unfinished.isNotEmpty) {
      // A repository release takes every unit, in dependency order — and is
      // the only one that takes a unit with the sibling it releases after:
      // that unit alone would wait for the sibling to be on pub.dev. Staging
      // it alone works, taking the sibling from this source.
      final verb = unfinished.every(readyToRelease) ? 'release' : 'stage';
      final repositoryWide =
          unfinished.length > 1 ||
          (verb == 'release' &&
              unfinished.single.observed.releasesAfterSibling);
      nextCommand = repositoryWide
          ? 'rk $verb'
          : 'rk $verb ${unfinished.single.unit.name}';
    }
    return StatusSnapshot(
      units: snapshots,
      issues: uniqueIssues,
      nextCommand: nextCommand,
    );
  }

  void render(StatusSnapshot snapshot) {
    final snapshots = snapshot.units;
    final uniqueIssues = snapshot.issues;
    output.repository(
      name: tree.description.split('/').last,
      branch: git.branch,
      commit: git.hasCommit ? git.shortHead : null,
      uncommitted: git.uncommitted.length,
      head: git.hasCommit ? git.head : null,
      remote: git.originUrl,
      sourceBinding: git.hasCommit ? 'gitCommit' : 'unbound',
      sourceComparison: git.hasCommit ? 'exact' : 'unavailable',
    );
    if (!git.hasCommit) {
      output.line(
        'Source',
        note: 'no commit yet · commit to stage or release',
        depth: 1,
        labelWidth: 18,
        noteState: RuntimeState.attention,
      );
    }

    for (final snapshot in snapshots) {
      _renderUnit(snapshot);
    }

    for (final unit in snapshots) {
      // What the stage found, such as Pub's validation warnings, is what
      // `rk release` will list before it asks: said here first.
      if (_workRemains(unit)) {
        for (final (:target, :warning) in _stageWarnings(unit)) {
          output.deferWarning(warning, unit: unit.unit.name, target: target);
        }
      }
    }
    output.flushWarnings();
    if (uniqueIssues.isNotEmpty) _renderIssues(uniqueIssues);

    if (uniqueIssues.isNotEmpty) {
      final count = uniqueIssues.length;
      output.blank();
      output.line(
        '$count ${count == 1 ? 'issue prevents' : 'issues prevent'} release',
        mark: Mark.blocked,
        state: RuntimeState.failure,
      );
    }

    if (snapshot.nextCommand case final command?) {
      output.blank();
      output.next(command);
    }
  }

  /// The warnings [unit]'s reusable stage recorded, each with the target
  /// that found it.
  List<({String? target, Diagnostic warning})> _stageWarnings(
    StatusUnitSnapshot unit,
  ) {
    final stage = unit.stage;
    if (stage == null || !stage.reusable) return const [];
    final stages = {
      for (final target in unit.release.targets)
        if (target.preparedBy case final work?) work.name: target.id,
    };
    return [
      for (final step in stage.receipt!.steps)
        for (final warning in recordedTargetStageWarnings(step))
          (target: stages[step.name], warning: warning),
    ];
  }

  Future<StatusUnitSnapshot> _gather(
    ResolvedUnit unit,
    TargetChecks? checking, {
    required String? group,
  }) async {
    final observed = UnitSnapshot.start(
      unit,
      resolution: resolution,
      inspector: inspector,
      repository: git.originUrl,
      hasCommit: git.hasCommit,
      stageFor: stageFor ?? inspector.stageFor,
    );
    final stageResult = _stageResult(observed);
    final diagnostics = Diagnostics();
    observed.releaseProblems.forEach(diagnostics.report);

    for (final project in unit.projects) {
      Changelog.check(
        changelog: project.changelog,
        manifestDirectory: project.pubspec.directory,
        packageName: project.name,
        version: project.version,
        diagnostics: diagnostics,
      );
    }

    final expectations = observed.targets;
    final artifactProblems = _artifactProductionProblems(unit);
    for (final expectation in expectations) {
      checking?.add(expectation.id, expectation.label, group: group);
    }

    // Each row settles as its own reads answer, in whatever order they do;
    // the report keeps the configured order.
    var targets = await Future.wait([
      for (final expectation in expectations)
        () async {
          final target = _publicationObservation(
            _observeTarget(
              expectation,
              await observed.reads[expectation.id]!,
              await observed.historyReads[expectation.id]!,
              stageResult.inspection,
              artifactProblems,
            ),
          );
          checking?.finish(expectation.id, target.inspection.verdict);
          return target;
        }(),
    ]);
    await observed.settle();
    final releasedSource = _releasedSourceMismatch(targets);

    final states = <String, Inspection>{
      ...observed.states,
      for (final target in targets) target.expectation.id: target.inspection,
    };

    final tagGuardProblems = [
      for (final diagnostic in observed.tagProblems)
        if (!(releasedSource != null && diagnostic.code == 'RK-GIT-005'))
          diagnostic,
    ];
    for (final diagnostic in tagGuardProblems) {
      diagnostics.report(diagnostic);
    }

    // The same answer `rk release` gives: a partial release needs its exact
    // stage unless what it has left can finish from public inputs.
    final partialReleaseWithoutStage = observed.needsLostStage(
      recovering: true,
    );
    if (partialReleaseWithoutStage) {
      targets = [
        for (final target in targets)
          TargetObservation(
            expectation: target.expectation,
            inspection: target.inspection,
            currentVersion: target.currentVersion,
            currentKnown: target.currentKnown,
            currentDetail: target.currentDetail,
            historyProblems: target.historyProblems,
            artifacts: [
              for (final artifact in target.artifacts)
                artifact.status == ArtifactStatus.invalid
                    ? artifact
                    : ArtifactObservation(
                        name: artifact.name,
                        status: ArtifactStatus.invalid,
                        problem:
                            'the exact stage is required to finish the '
                            'partial public release',
                      ),
            ],
          ),
      ];
    }
    final localOutputPending = _localBinaryWorkRemains(
      unit: unit,
      targets: targets,
      stage: stageResult.inspection,
    );
    final issues = <StatusIssue>[
      for (final diagnostic in diagnostics.found)
        StatusIssue(
          unit: unit.name,
          target: tagGuardProblems.contains(diagnostic)
              ? targets
                    .where(
                      (target) =>
                          target.expectation.target == PublishTarget.gitTag,
                    )
                    .firstOrNull
                    ?.expectation
                    .id
              : null,
          diagnostic: diagnostic,
        ),
      if (releasedSource != null)
        StatusIssue(
          unit: unit.name,
          diagnostic: inspector.targets
              .moduleFor(releasedSource.target.expectation.target)
              .diagnoseConflict(
                unit,
                releasedSource.target.expectation,
                releasedSource.target.inspection,
              ),
          evidence: {
            'released source': releasedSource.releasedCommit,
            'current source': releasedSource.currentCommit,
          },
        ),
      for (final target in targets)
        for (final diagnostic in target.historyProblems)
          StatusIssue(
            unit: unit.name,
            target: target.expectation.id,
            diagnostic: diagnostic,
          ),
      for (final target in targets)
        if ((target.inspection.verdict == Verdict.conflict ||
                target.inspection.verdict == Verdict.unknown) &&
            !(target.inspection.verdict == Verdict.conflict &&
                target.historyProblems.isNotEmpty))
          _targetIssue(unit, target),
      // As in `rk release`: a lane whose history was read and cannot say
      // its version is an issue; a lane that keeps no history is not.
      for (final target in targets)
        if (!target.currentKnown &&
            observed.histories[target.expectation.id] != null &&
            target.inspection.verdict != Verdict.unknown &&
            target.inspection.verdict != Verdict.conflict)
          _currentVersionIssue(unit, target),
      for (final step in observed.release.requirements)
        if (Inspector.blocks(step, states[step.id]!) &&
            observed.releasedFirstBy(step) == null)
          _prerequisiteIssue(unit, step, states[step.id]!),
      if (stageResult.issue != null &&
          !partialReleaseWithoutStage &&
          (targets.any((target) => !target.inspection.isExact) ||
              localOutputPending))
        stageResult.issue!,
      if (partialReleaseWithoutStage)
        StatusIssue(unit: unit.name, diagnostic: observed.lostStageProblem),
      if (artifactProblems.isNotEmpty &&
          !partialReleaseWithoutStage &&
          stageResult.inspection?.reusable != true &&
          (targets.any((target) => !target.inspection.isExact) ||
              localOutputPending))
        _hostIssue(unit),
    ];

    return StatusUnitSnapshot(
      observed: observed,
      states: states,
      targets: targets,
      stageState: stageResult.state,
      issues: issues,
      sourceVersionAlreadyReleased: releasedSource != null,
    );
  }

  ({TargetObservation target, String releasedCommit, String currentCommit})?
  _releasedSourceMismatch(Iterable<TargetObservation> targets) {
    final tag = targets
        .where(
          (target) =>
              target.expectation.target == PublishTarget.gitTag &&
              target.inspection.isExact &&
              target.inspection.sourceMismatch != null,
        )
        .firstOrNull;
    if (tag == null) return null;
    final mismatch = tag.inspection.sourceMismatch;
    if (mismatch == null) return null;
    return (
      target: tag,
      releasedCommit: mismatch.releasedCommit,
      currentCommit: mismatch.currentCommit,
    );
  }

  TargetObservation _publicationObservation(TargetObservation target) {
    final mismatch = target.inspection.sourceMismatch;
    if (target.expectation.target != PublishTarget.gitTag ||
        target.inspection.verdict != Verdict.conflict ||
        mismatch == null) {
      return target;
    }
    // A valid earlier release is published even when this checkout has moved
    // on. Interpret that before emitting progress; keep its source evidence
    // so the completed report can still flag the change.
    return TargetObservation(
      expectation: target.expectation,
      inspection: Inspection(
        Verdict.exact,
        detail: 'released from ${_shortObjectId(mismatch.releasedCommit)}',
        evidence: target.inspection.evidence,
        sourceMismatch: mismatch,
      ),
      currentVersion: target.currentVersion,
      currentKnown: target.currentKnown,
      currentDetail: target.currentDetail,
      historyProblems: target.historyProblems,
      artifacts: target.artifacts,
    );
  }

  /// The stage as status shows it: what it is, and the issue it raises
  /// when it is there and cannot be used.
  _StageResult _stageResult(UnitSnapshot observed) {
    final unit = observed.unit;
    if (observed.stageReadProblem case final problem?) {
      return _StageResult(
        state: observed.stageState,
        issue: StatusIssue(
          unit: unit.name,
          diagnostic: problem,
          evidence: {'Cause': '${observed.stageError}'},
        ),
      );
    }
    final inspected = observed.stageInspection;
    if (inspected == null) return _StageResult(state: observed.stageState);
    final ordinaryAbsence =
        inspected.receipt?.complete != true &&
        inspected.issues.every(
          (issue) =>
              issue.kind == StageIssueKind.missingReceipt ||
              issue.kind == StageIssueKind.incompleteReceipt,
        );
    return _StageResult(
      inspection: inspected,
      state: observed.stageState,
      issue: ordinaryAbsence || inspected.issues.isEmpty
          ? null
          : StatusIssue(
              unit: unit.name,
              diagnostic: Diagnostic(
                code: 'RK-STAGE-002',
                message: inspected.incomplete
                    ? 'the incomplete release stage cannot be resumed safely'
                    : inspected.claimsCompletion
                    ? 'the reviewed release stage no longer validates'
                    : 'the release stage receipt is invalid',
                remedy: inspected.incomplete
                    ? 're-run rk stage ${unit.name}. rk keeps '
                          'validated completed lanes when it can and replaces '
                          'only incomplete work'
                    : 'rebuild it explicitly: '
                          'rk stage ${unit.name}',
              ),
              evidence: {
                for (final issue in inspected.issues)
                  issue.path ?? issue.kind.name: issue.message,
              },
            ),
    );
  }

  TargetObservation _observeTarget(
    Target expectation,
    Inspection inspection,
    TargetHistory? history,
    StageInspection? stage,
    Map<String, String> artifactProblems,
  ) {
    // A direct read of the candidate coordinate answers whether this release
    // exists. It does not answer whether a newer release exists. For registry,
    // tag, and forge lanes, only the provider's history/listing can answer the
    // separate "what version is this lane at?" question. Homebrew's exact
    // formula read already carries the authenticated current version.
    final currentHistory =
        history ??
        TargetHistory.versioned(inspection: inspection, target: expectation);
    final currentInspection = currentHistory.inspection;
    final current = currentHistory.version != null
        ? _CurrentVersion(value: currentHistory.version!.canonical, known: true)
        : switch (currentInspection.verdict) {
            Verdict.absent => const _CurrentVersion(value: null, known: true),
            Verdict.exact ||
            Verdict.conflict ||
            Verdict.unknown => const _CurrentVersion.unknown(),
          };

    // A definitive conflict in the target's public history is also a
    // conflict for this candidate. Keep an unavailable history read separate:
    // the exact candidate inspection remains useful evidence in that case.
    final effectiveInspection = history?.inspection.verdict == Verdict.conflict
        ? history!.inspection
        : inspection;
    return TargetObservation(
      expectation: expectation,
      inspection: effectiveInspection,
      currentVersion: current.value,
      currentKnown: current.known,
      currentDetail: currentInspection.detail,
      historyProblems: currentHistory.problems,
      artifacts: [
        for (final name in expectation.artifacts)
          _observeArtifact(expectation, name, stage, artifactProblems[name]),
      ],
    );
  }

  ArtifactObservation _observeArtifact(
    Target target,
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
      return ArtifactObservation(name: name, status: ArtifactStatus.notStaged);
    }

    final complete = stage.receipt!.steps.last;
    var stagedPath = name;
    final releaseBindings = complete.evidence['release_assets'];
    if (releaseBindings is Map && releaseBindings[name] is String) {
      stagedPath = releaseBindings[name] as String;
    }
    final homebrewBinding = complete.evidence['homebrew_binding'];
    if (homebrewBinding is Map &&
        target.target == PublishTarget.homebrew &&
        homebrewBinding['project'] == target.project?.name &&
        homebrewBinding['staged_path'] is String) {
      final destinationPath = homebrewBinding['path'];
      if (destinationPath == name ||
          destinationPath is String && destinationPath.endsWith('/$name')) {
        stagedPath = homebrewBinding['staged_path'] as String;
      }
    }

    final related = stage.issues.where((issue) {
      final path = issue.path;
      if (path == null) return false;
      return path == stagedPath ||
          path.startsWith('$stagedPath/') ||
          stagedPath.startsWith('$path/');
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
      (artifact) => artifact.path == stagedPath,
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

  Map<String, String> _artifactProductionProblems(ResolvedUnit unit) {
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
            )] =
            '$platform cannot be produced here: $reason';
      }
      final summary = blocked.entries
          .map((entry) => '${entry.key}: ${entry.value}')
          .join('; ');
      problems[ReleaseAssets.manifest] =
          'cannot be finalized until every release artifact exists: $summary';
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
        message:
            '${unit.name}: this machine cannot produce every platform '
            'it ships',
        remedy: 'stage this unit on a host that can produce:\n$facts',
      ),
    );
  }

  StatusIssue _targetIssue(ResolvedUnit unit, TargetObservation target) {
    final state = target.inspection;
    final label = target.expectation.label;
    final diagnostic = state.verdict == Verdict.conflict
        ? inspector.targets
              .moduleFor(target.expectation.target)
              .diagnoseConflict(unit, target.expectation, state)
        : Diagnostic(
            code: 'RK-REL-001',
            message: '$label: ${_condition(state)}',
            remedy:
                'restore read access to $label, then run '
                'rk status ${unit.name} again',
          );
    return StatusIssue(
      unit: unit.name,
      target: target.expectation.id,
      diagnostic: diagnostic,
      evidence: state.evidence,
    );
  }

  StatusIssue _currentVersionIssue(
    ResolvedUnit unit,
    TargetObservation target,
  ) => StatusIssue(
    unit: unit.name,
    target: target.expectation.id,
    diagnostic: Diagnostic(
      code: 'RK-REL-001',
      message:
          '${target.expectation.label}: the current public version '
          'could not be established',
      remedy:
          'restore read access to ${target.expectation.label}, then '
          'run rk status ${unit.name} again',
    ),
    evidence: {
      if (target.currentDetail != null)
        'current version': target.currentDetail!,
    },
  );

  StatusIssue _prerequisiteIssue(
    ResolvedUnit unit,
    Step step,
    Inspection state,
  ) {
    return StatusIssue(
      unit: unit.name,
      diagnostic: Diagnostic(
        code: 'RK-REL-001',
        message: '${step.summary}: ${_condition(state)}',
        remedy: state.isAbsent
            ? 'publish it first, then run rk status ${unit.name} again'
            : 'restore read access to the prerequisite, then run '
                  'rk status ${unit.name} again',
      ),
      evidence: state.evidence,
    );
  }

  void _renderUnit(StatusUnitSnapshot snapshot) {
    final currentVersions = {
      for (final target in snapshot.targets) target.currentVersion,
    };
    final allCurrentsKnown =
        snapshot.targets.isNotEmpty &&
        snapshot.targets.every((target) => target.currentKnown);
    final agreedCurrent = allCurrentsKnown && currentVersions.length == 1
        ? currentVersions.single
        : null;
    final version = snapshot.unit.version.canonical;

    // The unit line carries movement and nothing else. Whether that version
    // is out there is the publication section's verdict, one line down —
    // naming a place and then the state of that place made two headers
    // argue about one fact.
    final movement = snapshot.sourceVersionAlreadyReleased
        ? '$version · version already released; current source differs'
        : agreedCurrent != null && agreedCurrent != version
        ? _versionMovement(agreedCurrent, version)
        : version;
    final resolvedTag = snapshot.unit.tag;
    final displayedTag = resolvedTag == null || resolvedTag == 'v$version'
        ? null
        : resolvedTag;
    output.unit(
      snapshot.unit.name,
      version: version,
      tag: resolvedTag,
      display: displayedTag == null ? movement : '$movement · $displayedTag',
    );
    final first = {
      for (final step in snapshot.release.requirements)
        if (snapshot.observed.releasedFirstBy(step) case final project?)
          '${project.unitName} ${project.version}',
    };
    if (first.isNotEmpty) {
      output.blank();
      output.line(
        'Releases after',
        note: first.join(', '),
        depth: 1,
        role: VisualRole.secondary,
      );
    }
    for (final step in snapshot.release.steps) {
      // Public targets are recorded once, in targets[], where the settled
      // observation lives; recording them under steps[] too made two
      // spellings of the same fact and left a caller guessing which one is
      // canonical.
      if (step is Target) continue;
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
  void _renderPublication(StatusUnitSnapshot snapshot) {
    if (snapshot.targets.isEmpty) return;
    final currents = {for (final t in snapshot.targets) t.currentVersion};
    final headerStatedMovement =
        snapshot.targets.every((t) => t.currentKnown) && currents.length == 1;
    final verdicts = snapshot.targets.map((t) => t.inspection.verdict).toSet();
    final agreed = verdicts.length == 1 ? verdicts.single : null;
    final linkedTargets = {
      for (final issue in snapshot.issues)
        if (issue.target != null) issue.target,
    };
    final publicationState = _publicationState(verdicts);

    output.blank();
    output.line(
      switch (agreed) {
        Verdict.exact => 'Published',
        Verdict.absent => 'Not published',
        Verdict.conflict => 'Does not match',
        Verdict.unknown => 'Could not be read',
        null => 'Public targets',
      },
      depth: 1,
      state: publicationState,
      strong: true,
    );

    for (final target in snapshot.targets) {
      final state = target.inspection;
      final linked = linkedTargets.contains(target.expectation.id);
      final visualState = linked
          ? RuntimeState.failure
          : RuntimeState.of(state.verdict);
      final speaks =
          state.verdict == Verdict.conflict ||
          state.verdict == Verdict.unknown ||
          state.evidence['comparison'] == 'unavailable' ||
          (snapshot.sourceVersionAlreadyReleased &&
              target.expectation.target == PublishTarget.gitTag);
      output.line(
        target.kindLabel,
        mark: linked
            ? Mark.blocked
            : agreed != null
            ? Mark.none
            : switch (state.verdict) {
                Verdict.exact => Mark.satisfied,
                Verdict.conflict => Mark.blocked,
                Verdict.absent || Verdict.unknown => Mark.none,
              },
        note: [
          target.identity,
          if (!headerStatedMovement &&
              target.currentKnown &&
              target.currentVersion != null &&
              target.currentVersion != target.expectation.targetVersion)
            _versionMovement(
              target.currentVersion!,
              target.expectation.targetVersion,
            ),
          if (agreed == null || speaks || linked)
            state.verdict == Verdict.unknown
                ? 'could not be read'
                : _condition(state),
        ].join(' · '),
        depth: 2,
        labelWidth: 30,
        state: visualState,
        noteRole: VisualRole.secondary,
        noteState: speaks ? visualState : RuntimeState.neutral,
      );
    }
  }

  /// What this repository has ready to publish.
  ///
  /// Public-target rows disappear once their destinations are exact. Binary
  /// stays visible as a selected local output until its exact stage exists.
  void _renderStage(StatusUnitSnapshot snapshot) {
    if (snapshot.sourceVersionAlreadyReleased) return;
    final staged = snapshot.stage?.reusable == true;
    final localProject =
        (staged &&
                snapshot.targets.isEmpty &&
                snapshot.unit.binaryProject != null) ||
            _localBinaryWorkRemains(
              unit: snapshot.unit,
              targets: snapshot.targets,
              stage: snapshot.stage,
            )
        ? snapshot.unit.binaryProject
        : null;
    final localBlocked = {
      if (localProject != null && !staged)
        for (final platform in localProject.binaryPlatforms)
          if (!capabilities.resolve(platform).canProduce)
            platform:
                capabilities.resolve(platform).reason ??
                'this host cannot produce $platform',
    };
    final localStatus = localProject == null
        ? null
        : staged
        ? ArtifactStatus.staged
        : localBlocked.isEmpty
        ? ArtifactStatus.notStaged
        : ArtifactStatus.invalid;
    final rows = <(TargetObservation, String, ArtifactStatus)>[
      for (final target in snapshot.targets)
        if (!target.inspection.isExact)
          if (target.expectation.target == PublishTarget.pubDev)
            (
              target,
              '${target.identity} package archive',
              staged ? ArtifactStatus.staged : ArtifactStatus.notStaged,
            )
          else if (target.artifacts.isNotEmpty)
            (
              target,
              target.stagedSummary,
              target.artifacts
                  .map((artifact) => artifact.status)
                  .reduce((a, b) => a == b ? a : ArtifactStatus.invalid),
            ),
    ];
    if (rows.isEmpty && localStatus == null) return;

    final statuses = {
      if (localStatus != null) localStatus,
      for (final row in rows) row.$3,
    };
    final agreed = statuses.length == 1 ? statuses.single : null;
    final stageState = _stageState(statuses);

    output.blank();
    output.line(
      switch (agreed) {
        ArtifactStatus.staged => 'Staged',
        ArtifactStatus.notStaged => 'Not staged',
        ArtifactStatus.invalid => 'Cannot be staged',
        null => 'Stage',
      },
      depth: 1,
      state: stageState,
      strong: true,
    );

    if (localProject != null) {
      output.line(
        'Local binaries',
        mark: agreed != null ? Mark.none : _artifactMark(localStatus!),
        note: agreed != null ? null : _artifactNote(localStatus!),
        depth: 2,
        state: _artifactState(localStatus!),
        noteRole: VisualRole.secondary,
        noteState: _artifactState(localStatus),
      );
      for (final platform in [...localProject.binaryPlatforms]..sort()) {
        final problem = localBlocked[platform];
        output.line(
          ReleaseAssets.archiveName(
            localProject.executable!,
            localProject.version.canonical,
            platform,
          ),
          mark: staged
              ? Mark.satisfied
              : problem == null
              ? Mark.none
              : Mark.blocked,
          note: staged ? 'staged' : problem,
          depth: 3,
          labelWidth: 44,
          role: VisualRole.secondary,
          state: staged
              ? RuntimeState.satisfied
              : problem == null
              ? RuntimeState.neutral
              : RuntimeState.failure,
          noteRole: VisualRole.secondary,
          noteState: staged
              ? RuntimeState.satisfied
              : problem == null
              ? RuntimeState.neutral
              : RuntimeState.failure,
        );
      }
      // Where they are, once they are: a directory this repository holds.
      if (staged && snapshot.observed.stage != null) {
        output.line(
          'in ${snapshot.observed.stage!.directory.repositoryRelativePath}/'
          '${ReleaseAssets.producerRoot(localProject)}/archives',
          depth: 3,
          role: VisualRole.secondary,
        );
      }
    }

    for (final (target, summary, status) in rows) {
      final invalid = target.artifacts
          .where((a) => a.status == ArtifactStatus.invalid)
          .toList();
      output.line(
        target.kindLabel,
        mark: agreed != null ? Mark.none : _artifactMark(status),
        // The word survives whatever the heading says: the plan requires
        // that marks and colour are never the only signal.
        note: agreed != null ? summary : '$summary · ${_artifactNote(status)}',
        depth: 2,
        labelWidth: 30,
        state: _artifactState(status),
        noteRole: VisualRole.secondary,
        noteState: _artifactState(status),
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
          state: RuntimeState.failure,
          noteState: RuntimeState.failure,
        );
      }
    }
  }

  void _recordTarget(StatusUnitSnapshot snapshot, TargetObservation target) {
    final state = target.inspection;
    output.report.target(
      unit: snapshot.unit.name,
      id: target.expectation.id,
      kind: target.expectation.target.wireName,
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

  static String _artifactNote(ArtifactStatus status) => switch (status) {
    ArtifactStatus.notStaged => 'not staged',
    ArtifactStatus.staged => 'staged',
    ArtifactStatus.invalid => 'invalid',
  };

  static Mark _artifactMark(ArtifactStatus status) => switch (status) {
    ArtifactStatus.notStaged => Mark.none,
    ArtifactStatus.staged => Mark.satisfied,
    ArtifactStatus.invalid => Mark.blocked,
  };

  static RuntimeState _artifactState(ArtifactStatus status) => switch (status) {
    ArtifactStatus.notStaged => RuntimeState.neutral,
    ArtifactStatus.staged => RuntimeState.satisfied,
    ArtifactStatus.invalid => RuntimeState.failure,
  };

  static RuntimeState _publicationState(Set<Verdict> verdicts) {
    if (verdicts.contains(Verdict.conflict)) return RuntimeState.failure;
    if (verdicts.contains(Verdict.unknown)) return RuntimeState.attention;
    if (verdicts.every((verdict) => verdict == Verdict.exact)) {
      return RuntimeState.satisfied;
    }
    if (verdicts.every((verdict) => verdict == Verdict.absent)) {
      return RuntimeState.neutral;
    }
    return RuntimeState.active;
  }

  static RuntimeState _stageState(Set<ArtifactStatus> statuses) {
    if (statuses.contains(ArtifactStatus.invalid)) return RuntimeState.failure;
    if (statuses.every((status) => status == ArtifactStatus.staged)) {
      return RuntimeState.satisfied;
    }
    if (statuses.every((status) => status == ArtifactStatus.notStaged)) {
      return RuntimeState.neutral;
    }
    return RuntimeState.active;
  }

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
        '$unit$where${diagnostic.message}',
        mark: Mark.blocked,
        depth: 1,
        state: RuntimeState.failure,
      );
      for (final entry in issue.evidence.entries) {
        output.line(
          '${entry.key}: ${entry.value}',
          depth: 2,
          role: VisualRole.secondary,
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
    Verdict.absent when state.evidence.containsKey('version') =>
      'needs update${_detailSuffix(state.detail)}',
    Verdict.absent => 'not published${_detailSuffix(state.detail)}',
    Verdict.conflict => 'does not match${_detailSuffix(state.detail)}',
    Verdict.unknown => 'could not be read${_detailSuffix(state.detail)}',
  };

  static String _detailSuffix(String? detail) =>
      detail == null || detail.isEmpty ? '' : ': $detail';

  static String _shortObjectId(String value) =>
      value.length > 7 ? value.substring(0, 7) : value;

  static List<StatusIssue> _deduplicate(Iterable<StatusIssue> issues) {
    final seen = <String>{};
    return [
      for (final issue in issues)
        if (seen.add(issue.deduplicationKey)) issue,
    ];
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

  /// What stops staging here, shown once work remains: the source must be a
  /// clean commit, and a tag needs that commit on origin.
  void _checkRepositoryState(
    Diagnostics problems,
    Iterable<ResolvedUnit> units,
  ) {
    if (git.stagingProblem() case final problem?) problems.report(problem);
    if (units.any((unit) => unit.publish.contains(PublishTarget.gitTag))) {
      final unpushed = git.unpushedProblem();
      if (unpushed != null) problems.report(unpushed);
    }
  }
}

String _versionMovement(String current, String target) {
  final parsedCurrent = Version.tryParse(current);
  final parsedTarget = Version.tryParse(target);
  if (parsedCurrent != null &&
      parsedTarget != null &&
      parsedCurrent > parsedTarget) {
    return '$target · behind $current';
  }
  return '$current › $target';
}

class StatusSnapshot {
  StatusSnapshot({
    required Iterable<StatusUnitSnapshot> units,
    required Iterable<StatusIssue> issues,
    this.nextCommand,
  }) : units = List.unmodifiable(units),
       issues = List.unmodifiable(issues);
  final List<StatusUnitSnapshot> units;
  final List<StatusIssue> issues;
  final String? nextCommand;
}

class StatusUnitSnapshot {
  StatusUnitSnapshot({
    required this.observed,
    required Map<String, Inspection> states,
    required Iterable<TargetObservation> targets,
    required this.stageState,
    required Iterable<StatusIssue> issues,
    required this.sourceVersionAlreadyReleased,
  }) : states = Map<String, Inspection>.unmodifiable(states),
       targets = List<TargetObservation>.unmodifiable(targets),
       issues = List<StatusIssue>.unmodifiable(issues);

  /// What was read, shared with `rk release`.
  final UnitSnapshot observed;
  ResolvedUnit get unit => observed.unit;
  UnitRelease get release => observed.release;
  StageInspection? get stage => observed.stageInspection;
  final Map<String, Inspection> states;
  final List<TargetObservation> targets;
  final Inspection stageState;
  final List<StatusIssue> issues;
  final bool sourceVersionAlreadyReleased;
}

bool _isLocalOnlyOutput(StatusUnitSnapshot snapshot) =>
    snapshot.targets.isEmpty && snapshot.unit.shipsBinaries;

bool _workRemains(StatusUnitSnapshot snapshot) =>
    snapshot.sourceVersionAlreadyReleased ||
    snapshot.targets.any((target) => !target.inspection.isExact) ||
    _localBinaryWorkRemains(
      unit: snapshot.unit,
      targets: snapshot.targets,
      stage: snapshot.stage,
    );

/// Whether this release still needs a private binary stage.
///
/// A binary is a selected local output until an exact public target binds all
/// of its archives. Once that happens, losing its stage does not turn a
/// completed release back into unfinished local work. This stays data-driven:
/// the destination's artifact inventory establishes the binding, so status
/// does not need to know which target kind published the bytes.
bool _localBinaryWorkRemains({
  required ResolvedUnit unit,
  required Iterable<TargetObservation> targets,
  required StageInspection? stage,
}) {
  final project = unit.binaryProject;
  if (project == null || stage?.reusable == true) return false;

  final archiveNames = {
    for (final platform in project.binaryPlatforms)
      ReleaseAssets.archiveName(
        project.executable!,
        project.version.canonical,
        platform,
      ),
  };
  final published = targets.any(
    (target) =>
        target.inspection.isExact &&
        archiveNames.every(target.expectation.artifacts.contains),
  );
  return !published;
}

class _StageResult {
  const _StageResult({required this.state, this.inspection, this.issue});

  final StageInspection? inspection;
  final Inspection state;
  final StatusIssue? issue;
}

class _CurrentVersion {
  const _CurrentVersion({required this.value, required this.known});
  const _CurrentVersion.unknown() : this(value: null, known: false);

  final String? value;
  final bool known;
}

enum ArtifactStatus { notStaged, staged, invalid }

/// What the exact stage inspection established about one expected filename.
class ArtifactObservation {
  const ArtifactObservation({
    required this.name,
    required this.status,
    this.problem,
  });

  final String name;
  final ArtifactStatus status;
  final String? problem;
}

/// One public observation, kept in configured order by its caller.
class TargetObservation {
  TargetObservation({
    required this.expectation,
    required this.inspection,
    required this.currentVersion,
    required this.currentKnown,
    this.currentDetail,
    Iterable<Diagnostic> historyProblems = const [],
    required Iterable<ArtifactObservation> artifacts,
  }) : historyProblems = List<Diagnostic>.unmodifiable(historyProblems),
       artifacts = List<ArtifactObservation>.unmodifiable(artifacts);

  final Target expectation;
  final Inspection inspection;

  /// Null with [currentKnown] true means the provider definitively has no
  /// current release. Null with it false means the read could not answer.
  final String? currentVersion;
  final bool currentKnown;
  final String? currentDetail;
  final List<Diagnostic> historyProblems;

  final List<ArtifactObservation> artifacts;

  /// The kind of destination, without the thing it points at.
  String get kindLabel => expectation.kindLabel;

  /// What this row is about, when the section heading has already said what
  /// state it is in — a tag name, a package, a repository. A row that
  /// carried neither state nor identity read as unfinished.
  String get identity => expectation.identity;

  /// What this target has waiting for it here.
  String get stagedSummary => artifacts.length == 1
      ? artifacts.single.name
      : '${artifacts.length} artifacts';
}

/// A report issue linked to its unit but independent of rendering.
class StatusIssue {
  StatusIssue({
    required this.diagnostic,
    this.unit,
    this.target,
    Map<String, String> evidence = const {},
  }) : evidence = Map<String, String>.unmodifiable(evidence);

  final String? unit;
  final String? target;
  final Diagnostic diagnostic;
  final Map<String, String> evidence;

  String get deduplicationKey => [
    unit ?? '',
    target ?? '',
    diagnostic.code,
    diagnostic.source?.toString() ?? '',
    diagnostic.message,
    diagnostic.remedy ?? '',
  ].join('\u0000');
}
