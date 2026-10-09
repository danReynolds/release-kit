import '../builds/capability.dart';
import '../engine/changelog.dart';
import '../engine/assets.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/inspect.dart';
import '../engine/publish_target.dart';
import '../engine/receipt.dart';
import '../engine/resolve.dart';
import '../engine/source_tree.dart';
import '../engine/stage.dart';
import '../engine/unit_release.dart';
import '../engine/unit_snapshot.dart';
import '../engine/verdict.dart';
import '../engine/version.dart';
import '../output/output.dart';
import '../targets/target_module.dart';
import 'release_progress.dart';

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

  /// Each unit's stage at this commit; null reads none.
  final Stage Function(ResolvedUnit unit)? stageFor;

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

    final snapshot = await collect(
      only: only,
      checking: output.board('Release targets', elapsed: false),
    );
    render(snapshot);
    return ExitCodes.ok;
  }

  /// Read once for the text and JSON reports. Progress uses the same publication
  /// interpretation as the completed snapshot, including release blockers.
  /// [checking] shows each read as it answers, and is gone once they all
  /// have: the report says the rest.
  Future<StatusSnapshot> collect({String? only, Board? checking}) async {
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
      checking?.discard();
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
      tree.description.split('/').last,
      git: git,
      uncommitted: git.uncommitted.length,
      source: true,
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
      if (_workRemains(unit) && unit.stage?.reusable == true) {
        deferStageWarnings(output, unit.release, unit.stage!.receipt!);
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

  Future<StatusUnitSnapshot> _gather(
    ResolvedUnit unit,
    Board? checking, {
    required String? group,
  }) async {
    final observed = UnitSnapshot.start(
      unit,
      resolution: resolution,
      inspector: inspector,
      repository: git.originUrl,
      hasCommit: git.hasCommit,
      stageFor: stageFor,
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
    final artifactProblems = _artifactProductionProblems(observed.release);
    for (final expectation in expectations) {
      checking
          ?.add(expectation.id, expectation.label, group: group)
          .begin(Activities.checking);
    }

    // Each row settles as its own reads answer, in whatever order they do;
    // the report keeps the configured order.
    var targets = await Future.wait([
      for (final expectation in expectations)
        () async {
          final read = await observed.targetReads[expectation.id]!;
          final target = _publicationObservation(
            _observeTarget(
              expectation,
              read.state,
              read.history,
              stageResult.check,
              artifactProblems,
            ),
          );
          if (checking?[expectation.id] case final row?) {
            switch (target.inspection.verdict) {
              case Verdict.exact:
                row.complete('checked', mark: Mark.satisfied);
              case Verdict.absent:
                row.complete('checked', mark: Mark.none);
              case Verdict.conflict:
                row.fail(note: 'differs');
              case Verdict.unknown:
                row.complete(
                  'unread',
                  mark: Mark.none,
                  tone: RuntimeState.attention,
                );
            }
          }
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
      release: observed.release,
      targets: targets,
      stage: stageResult.check,
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
              .explain(
                unit,
                releasedSource.target.expectation,
                releasedSource.target.inspection,
              )
              .diagnostic,
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
          stageResult.check?.reusable != true &&
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
    final check = observed.stageCheck;
    if (check == null) return _StageResult(state: observed.stageState);
    final message = switch (check.state) {
      StageState.broken =>
        'the incomplete release stage cannot be resumed safely',
      StageState.changed => 'the reviewed release stage no longer validates',
      StageState.unreadable => 'the release stage receipt is invalid',
      StageState.absent || StageState.resumable || StageState.complete => null,
    };
    return _StageResult(
      check: check,
      state: observed.stageState,
      issue: message == null
          ? null
          : StatusIssue(
              unit: unit.name,
              diagnostic: Diagnostic(
                code: 'RK-STAGE-002',
                message: message,
                remedy: check.state == StageState.broken
                    ? 're-run rk stage ${unit.name}. rk keeps '
                          'validated completed lanes when it can and replaces '
                          'only incomplete work'
                    : 'rebuild it explicitly: '
                          'rk stage ${unit.name}',
              ),
              evidence: check.problems,
            ),
    );
  }

  TargetObservation _observeTarget(
    Target expectation,
    Inspection inspection,
    TargetHistory? history,
    StageCheck? stage,
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
    // A lane read as empty is known to be at no version; any other read
    // that names none could not say.
    final current = currentHistory.version != null
        ? (value: currentHistory.version!.canonical, known: true)
        : (value: null, known: currentInspection.verdict == Verdict.absent);

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
        for (final file in [
          ...expectation.files,
        ]..sort((a, b) => (a.name ?? '').compareTo(b.name ?? '')))
          if (file.name case final name?)
            _observeArtifact(file, name, stage, artifactProblems[name]),
      ],
    );
  }

  /// What [stage] holds of [file], which a target publishes as [name].
  ArtifactObservation _observeArtifact(
    Artifact file,
    String name,
    StageCheck? stage,
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

    if (!stage.reusable) {
      return ArtifactObservation(
        name: name,
        status: ArtifactStatus.invalid,
        problem:
            stage.problems[file.path] ??
            'stage does not validate: ${stage.lines.join('; ')}',
      );
    }
    return ArtifactObservation(name: name, status: ArtifactStatus.staged);
  }

  /// The platforms [unit] ships that this host cannot produce, with why.
  Map<String, String> _blocked(ResolvedUnit unit) => {
    for (final project in unit.projects)
      for (final platform in project.binaryPlatforms)
        if (capabilities.resolve(platform) case final capability
            when !capability.canProduce)
          platform: capability.reason ?? 'this host cannot produce $platform',
  };

  /// Why each of [release]'s files this host would have to make cannot be
  /// made, by public name: the archives of the platforms it cannot build,
  /// and the manifest that waits for every one.
  Map<String, String> _artifactProductionProblems(UnitRelease release) {
    final blocked = _blocked(release.unit);
    if (blocked.isEmpty) return const {};
    final summary = blocked.entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join('; ');
    return Map.unmodifiable({
      for (final asset in release.assets)
        if (blocked[asset.madeBy.platform] case final reason?)
          asset.name!:
              '${asset.madeBy.platform} cannot be produced here: $reason',
      ReleaseAssets.manifest:
          'cannot be finalized until every release artifact exists: $summary',
    });
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
              .explain(unit, target.expectation, state)
              .diagnostic
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
      output.report.target(snapshot.unit.name, target.toJson());
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
      state: RuntimeState.agreed(verdicts.map(RuntimeState.of)),
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
            : Mark.of(state.verdict),
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
              release: snapshot.release,
              targets: snapshot.targets,
              stage: snapshot.stage,
            )
        ? snapshot.unit.binaryProject
        : null;
    final localBlocked = localProject != null && !staged
        ? _blocked(snapshot.unit)
        : const <String, String>{};
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

    output.blank();
    output.line(
      agreed?.heading ?? 'Stage',
      depth: 1,
      state: RuntimeState.agreed(statuses.map((status) => status.state)),
      strong: true,
    );

    if (localStatus != null) {
      output.line(
        'Local binaries',
        mark: agreed != null ? Mark.none : localStatus.mark,
        note: agreed != null ? null : localStatus.word,
        depth: 2,
        state: localStatus.state,
        noteRole: VisualRole.secondary,
        noteState: localStatus.state,
      );
      // Each archive, in the order of the platforms it is for.
      for (final archive in snapshot.release.assets) {
        final problem = localBlocked[archive.madeBy.platform];
        final state = staged
            ? ArtifactStatus.staged
            : problem == null
            ? ArtifactStatus.notStaged
            : ArtifactStatus.invalid;
        output.line(
          archive.name!,
          mark: state.mark,
          note: staged ? 'staged' : problem,
          depth: 3,
          labelWidth: 44,
          role: VisualRole.secondary,
          state: state.state,
          noteRole: VisualRole.secondary,
          noteState: state.state,
        );
      }
      // Where they are, once they are: a directory this repository holds.
      if (staged && snapshot.observed.stage != null) {
        output.line(
          'in ${snapshot.observed.stage!.relativePath}/'
          '${ReleaseAssets.producerRoot(localProject!)}/archives',
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
        mark: agreed != null ? Mark.none : status.mark,
        // The word survives whatever the heading says: the plan requires
        // that marks and colour are never the only signal.
        note: agreed != null ? summary : '$summary · ${status.word}',
        depth: 2,
        labelWidth: 30,
        state: status.state,
        noteRole: VisualRole.secondary,
        noteState: status.state,
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
    output.report.step(
      step,
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
  StageCheck? get stage => observed.stageCheck;
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
      release: snapshot.release,
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
  required UnitRelease release,
  required Iterable<TargetObservation> targets,
  required StageCheck? stage,
}) {
  if (!release.unit.shipsBinaries || stage?.reusable == true) return false;
  // A binary unit's release files are its archives.
  final published = targets.any(
    (target) =>
        target.inspection.isExact &&
        release.assets.every(
          (archive) => target.expectation.artifacts.contains(archive.name),
        ),
  );
  return !published;
}

class _StageResult {
  const _StageResult({required this.state, this.check, this.issue});

  final StageCheck? check;
  final Inspection state;
  final StatusIssue? issue;
}

/// What the stage holds of one file a target publishes: the word a row
/// says, its mark, and the state both are drawn in.
enum ArtifactStatus {
  notStaged('not staged', 'Not staged', Mark.none, RuntimeState.neutral),
  staged('staged', 'Staged', Mark.satisfied, RuntimeState.satisfied),
  invalid('invalid', 'Cannot be staged', Mark.blocked, RuntimeState.failure);

  const ArtifactStatus(this.word, this.heading, this.mark, this.state);

  final String word;

  /// What a stage section says when every row agrees on this.
  final String heading;
  final Mark mark;
  final RuntimeState state;
}

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

  /// What `targets[]` says of it in `--json`.
  Map<String, Object?> toJson() => {
    'id': expectation.id,
    'kind': expectation.target.wireName,
    'label': expectation.label,
    'coordinate': expectation.coordinate,
    'current_known': currentKnown,
    'current_version': currentVersion,
    'target_version': expectation.targetVersion,
    'verdict': inspection.verdict.name,
    'detail': ?inspection.detail,
    'uses': ?expectation.uses,
    'artifacts': [
      for (final artifact in artifacts)
        {
          'name': artifact.name,
          'status': artifact.status.name,
          'problem': ?artifact.problem,
        },
    ],
  };
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
