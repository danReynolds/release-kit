import '../builds/capability.dart';
import '../engine/changelog.dart';
import '../engine/checklist.dart';
import '../engine/assets.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/inspect.dart';
import '../engine/registry.dart';
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
    required this.registry,
    required this.inspector,
    required this.output,
    this.stageFor,
    HostCapabilities? capabilities,
  }) : capabilities = capabilities ?? HostCapabilities.inspect();

  final Resolution resolution;
  final SourceTree tree;
  final GitState git;
  final RegistryReader? registry;
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
      branch: git.branch,
      uncommitted: git.uncommitted.length,
      head: git.head,
      remote: git.originUrl,
      mode: registry == null ? 'offline' : null,
    );

    if (registry == null) {
      output.say(
        'public targets were not read. Unknown is not treated as unpublished.',
      );
    }

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

    output.blank();
    if (uniqueIssues.isNotEmpty) {
      final count = uniqueIssues.length;
      output.line(
        '$count ${count == 1 ? 'issue prevents' : 'issues prevent'} release',
        mark: Mark.blocked,
        tone: Tone.bad,
      );
    } else if (!workRemains) {
      output.line(
        'Published everywhere configured',
        mark: Mark.done,
        tone: Tone.muted,
      );
    } else if (snapshots
        .where((snapshot) => snapshot.targets.any(
              (target) => !target.inspection.isExact,
            ))
        .every((snapshot) => snapshot.stage?.reusable == true)) {
      output.line('Good to release', mark: Mark.done);
    } else {
      output.line('No known issues', mark: Mark.done);
    }

    if (uniqueIssues.isEmpty) {
      final unfinished = snapshots
          .where((snapshot) => snapshot.targets.any(
                (target) => !target.inspection.isExact,
              ))
          .toList();
      if (unfinished.length == 1) {
        final snapshot = unfinished.single;
        output.next(
          snapshot.stage?.reusable == true
              ? 'rk release ${snapshot.unit.name}'
              : 'rk release ${snapshot.unit.name} --stage',
        );
      }
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
    final artifactProblems = _artifactProductionProblems(unit);
    final expectations = TargetExpectation.derive(
      unit,
      checklist,
      repository: git.originUrl,
    );
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
      states[step.id] = switch (step.kind) {
        StepKind.completeStage => stageResult.state,
        StepKind.build ||
        StepKind.sign ||
        StepKind.notarize ||
        StepKind.archive ||
        StepKind.checksums =>
          stageResult.inspection?.reusable == true
              ? const Inspection.exact(
                  detail: 'validated in the release stage',
                )
              : const Inspection.unknown(
                  'local work, decided when it runs',
                ),
        // Public and prerequisite states were populated above.
        StepKind.tag ||
        StepKind.prerequisite ||
        StepKind.publishRegistry ||
        StepKind.publishRelease ||
        StepKind.publishFormula =>
          const Inspection.unknown('the target was not inspected'),
      };
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
            (registry != null && target.inspection.verdict == Verdict.unknown))
          _targetIssue(unit, target),
      for (final target in targets)
        if (registry != null &&
            !target.currentKnown &&
            target.inspection.verdict != Verdict.unknown &&
            target.inspection.verdict != Verdict.conflict)
          _currentVersionIssue(unit, target),
      for (final target in targets)
        if (_isAhead(target) && !_aheadAlreadyReported(target, diagnostics))
          _aheadIssue(unit, target),
      for (final step in prerequisiteSteps)
        if (registry != null && Inspector.blocks(step, states[step.id]!))
          _prerequisiteIssue(unit, step, states[step.id]!),
      if (registry == null && targets.isNotEmpty)
        StatusIssue(
          unit: unit.name,
          diagnostic: Diagnostic(
            code: 'RK-REL-001',
            message: '${unit.name}: public targets were not read',
            remedy: 'read them before release: rk status ${unit.name}',
          ),
        ),
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
    final currentInspection =
        expectation.kind == ReleaseTargetKind.homebrew ? inspection : latest;
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

  Future<Inspection> _inspectLatestSafely(
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
        )] = '$platform cannot be produced here: $reason';
        if (platform.startsWith('macos-')) {
          problems[ReleaseAssets.notaryResultName(
            executable,
            project.version.canonical,
            platform,
          )] = '$platform cannot be produced here: $reason';
          problems[ReleaseAssets.notaryLogName(
            executable,
            project.version.canonical,
            platform,
          )] = '$platform cannot be produced here: $reason';
        }
      }
      final summary = blocked.entries
          .map((entry) => '${entry.key}: ${entry.value}')
          .join('; ');
      problems[ReleaseAssets.checksums] =
          'cannot be finalized until every archive exists: $summary';
      problems[ReleaseAssets.manifest] =
          'cannot be finalized until every release artifact exists: $summary';
      if (project.channels.contains('homebrew')) {
        problems[ReleaseAssets.formulaName(executable)] =
            'cannot be rendered until every archive exists: $summary';
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
            ? registry == null
                ? 'read the public targets: rk status ${unit.name}'
                : 'restore read access to $label, then run '
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
      switch (target.expectation.kind) {
        ReleaseTargetKind.gitTag =>
          'do not move the public tag. If it is not the intended release, '
              'bump the version and changelog, then stage the new release',
        ReleaseTargetKind.pubDev =>
          'pub.dev versions are immutable. Bump the version and changelog, '
              'then stage the new release',
        ReleaseTargetKind.githubRelease =>
          'compare the published release with the source named by its tag. '
              'If they are not the intended release, bump the version and '
              'changelog; rk will not replace conflicting public bytes',
        ReleaseTargetKind.homebrew =>
          'restore the formula to the exact release bytes it is meant to '
              'reference, or advance the source version intentionally; then '
              'run rk status ${unit.name} again',
      };

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
    final existingCode = switch (target.expectation.kind) {
      ReleaseTargetKind.pubDev => 'RK-MONO-002',
      ReleaseTargetKind.gitTag => 'RK-MONO-001',
      ReleaseTargetKind.githubRelease || ReleaseTargetKind.homebrew => null,
    };
    return existingCode != null &&
        diagnostics.found.any((problem) => problem.code == existingCode);
  }

  StatusIssue _aheadIssue(
    ResolvedUnit unit,
    TargetObservation target,
  ) =>
      StatusIssue(
        unit: unit.name,
        target: target.expectation.step.id,
        diagnostic: Diagnostic(
          code: 'RK-MONO-003',
          message: '${target.expectation.label} is already at '
              '${target.currentVersion}, ahead of the target '
              '${target.expectation.targetVersion}',
          remedy: 'a release moves forward — bump past '
              '${target.currentVersion}',
        ),
      );

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
            : registry == null
                ? 'read the public prerequisite: rk status ${unit.name}'
                : 'restore read access to the prerequisite, then run '
                    'rk status ${unit.name} again',
      ),
      evidence: state.evidence,
    );
  }

  void _renderUnit(_UnitSnapshot snapshot) {
    final allCurrentsKnown = snapshot.targets.isNotEmpty &&
        snapshot.targets.every((target) => target.currentKnown);
    final currentVersions = {
      for (final target in snapshot.targets) target.currentVersion,
    };
    final hasAgreedCurrent = allCurrentsKnown && currentVersions.length == 1;
    final currentVersion =
        hasAgreedCurrent ? currentVersions.single ?? '—' : null;
    output.unit(
      snapshot.unit.name,
      version: snapshot.unit.version.canonical,
      tag: snapshot.unit.tag,
      display: hasAgreedCurrent
          ? '$currentVersion › ${snapshot.unit.version.canonical} · '
              '${snapshot.unit.tag}'
          : 'target ${snapshot.unit.version.canonical} · '
              '${snapshot.unit.tag}',
    );
    for (final step in snapshot.checklist.steps) {
      _record(step, snapshot.states[step.id]!);
    }

    output.line('Targets', depth: 1, tone: Tone.header);
    for (final target in snapshot.targets) {
      final state = target.inspection;
      final hasLinkedIssue = snapshot.issues.any(
        (issue) => issue.target == target.expectation.step.id,
      );
      final targetTone = hasLinkedIssue ? Tone.bad : Tone.of(state.verdict);
      output.report.target(
        unit: snapshot.unit.name,
        id: target.expectation.step.id,
        kind: target.expectation.kind.name,
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
      final current = target.currentKnown ? target.currentVersion ?? '—' : '?';
      output.line(
        target.expectation.label,
        mark: hasLinkedIssue
            ? Mark.blocked
            : switch (state.verdict) {
                Verdict.exact => Mark.done,
                Verdict.conflict => Mark.blocked,
                Verdict.absent || Verdict.unknown => Mark.none,
              },
        note: '$current › ${target.expectation.targetVersion} · '
            '${_condition(state)}',
        depth: 2,
        labelWidth: 30,
        tone: targetTone,
        noteTone: targetTone,
      );
      for (final artifact in target.artifacts) {
        output.line(
          artifact.name,
          mark: switch (artifact.status) {
            ArtifactStatus.notStaged => Mark.none,
            ArtifactStatus.staged => Mark.done,
            ArtifactStatus.invalid => Mark.blocked,
          },
          note: switch (artifact.status) {
            ArtifactStatus.notStaged => 'not staged',
            ArtifactStatus.staged => 'staged',
            ArtifactStatus.invalid => artifact.problem,
          },
          depth: 3,
          labelWidth: 54,
          tone: artifact.status == ArtifactStatus.invalid
              ? Tone.bad
              : artifact.status == ArtifactStatus.staged
                  ? Tone.muted
                  : Tone.plain,
          noteTone:
              artifact.status == ArtifactStatus.invalid ? Tone.bad : Tone.muted,
        );
      }
      if (target.expectation.uses case final uses?) {
        output.line(
          'uses $uses',
          depth: 3,
          tone: Tone.muted,
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

  static String? _diagnosticTarget(
    Diagnostic diagnostic,
    List<TargetObservation> targets,
  ) {
    const gitTargetCodes = {
      'RK-MONO-001',
      'RK-GIT-004',
      'RK-GIT-005',
      'RK-GIT-007',
    };
    if (gitTargetCodes.contains(diagnostic.code)) {
      return targets
          .where(
            (target) => target.expectation.kind == ReleaseTargetKind.gitTag,
          )
          .firstOrNull
          ?.expectation
          .step
          .id;
    }
    if (diagnostic.code == 'RK-MONO-002') {
      final source = diagnostic.source?.path;
      return targets
          .where(
            (target) =>
                target.expectation.kind == ReleaseTargetKind.pubDev &&
                target.expectation.project?.pubspec.path == source,
          )
          .firstOrNull
          ?.expectation
          .step
          .id;
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
