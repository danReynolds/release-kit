import 'dart:convert';
import 'dart:io';

import '../builds/capability.dart';
import '../engine/changelog.dart';
import '../engine/checklist.dart';
import '../engine/assets.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../output/output.dart';
import '../engine/inspect.dart';
import '../engine/registry.dart';
import '../engine/resolve.dart';
import '../engine/release_stage.dart';
import '../engine/source_tree.dart';
import '../engine/stage_inspection.dart';
import '../engine/stage_receipt.dart';
import '../engine/targets.dart';
import '../engine/tools.dart';
import '../engine/identity.dart';
import '../engine/verdict.dart';
import '../transforms/macos.dart';
import '../transforms/digest.dart';
import '../destinations/git_tag.dart';
import '../destinations/github_release.dart';
import '../destinations/homebrew.dart';
import '../binary_chain.dart';

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
    required this.registry,
    required this.inspector,
    required this.tools,
    required this.output,
    required this.confirm,
    this.stageOnly = false,
    ReleaseStage Function(ResolvedUnit unit)? stageFor,
    ReleaseStage Function(ResolvedUnit unit, GitState git)? refreshStage,
    GitState Function()? refreshGit,
    Future<void> Function(Duration)? wait,
    HostCapabilities? capabilities,
  })  : _wait = wait ?? _sleep,
        _stageFor = stageFor ?? ReleaseStages(source: tree, git: git).call,
        _refreshStage = refreshStage ??
            ((unit, currentGit) =>
                ReleaseStages(source: tree, git: currentGit).call(unit)),
        _refreshGit = refreshGit ?? (() => git),
        _capabilities = capabilities;

  static Future<void> _sleep(Duration duration) =>
      Future<void>.delayed(duration);

  final Resolution resolution;
  final SourceTree tree;
  final GitState git;
  final RegistryReader registry;

  /// Reads reality for a step. The same one `status` uses, so the two verbs
  /// cannot answer the same question differently — release grew its own copy
  /// once, and it answered `absent` by default for every kind it did not name.
  final Inspector inspector;

  /// Waits, injectable so a test proves the polling without living it.
  final Future<void> Function(Duration) _wait;

  /// How long the confirming read chases a version the registry has accepted
  /// but does not list yet, and how often it asks. Bounded: an unlisted
  /// version after a minute is worth a human's eyes, not an infinite loop.
  static const confirmDeadline = Duration(seconds: 60);
  static const confirmInterval = Duration(seconds: 5);

  final Tools tools;
  final Output output;

  /// Asks the operator to type the version. Returns what they typed, or null
  /// when there is nobody to ask.
  final Future<String?> Function(String prompt)? confirm;

  /// What this host can produce — injectable so a drive can span platforms
  /// the test machine does not have. Null detects lazily, once.
  HostCapabilities? _capabilities;
  HostCapabilities get capabilities =>
      _capabilities ??= HostCapabilities.detect();

  /// Prepare and validate the exact private stage, then stop before release
  /// authorization or any public mutation.
  final bool stageOnly;

  final ReleaseStage Function(ResolvedUnit unit) _stageFor;
  final ReleaseStage Function(ResolvedUnit unit, GitState git) _refreshStage;
  final GitState Function() _refreshGit;
  final Map<String, BinaryChain> _chains = {};

  Future<int> run({String? only}) async {
    if (only == null) {
      output.problem(
        Diagnostic(
          code: 'RK-CLI-004',
          message: 'name the unit to release',
          remedy: 'rk release <unit> releases one of: '
              '${resolution.units.map((u) => u.name).join(', ')}',
        ),
      );
      return ExitCodes.usage;
    }

    final units = resolution.units.where((u) => u.name == only).toList();

    if (units.isEmpty) {
      output.problem(
        Diagnostic(
          code: 'RK-CLI-003',
          message: 'no unit named "$only"',
          remedy: 'this repository releases: '
              '${resolution.units.map((u) => u.name).join(', ')}',
        ),
      );
      return ExitCodes.usage;
    }

    return _release(units.single);
  }

  Future<int> _release(ResolvedUnit unit) async {
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
    final targets = TargetExpectation.derive(
      unit,
      checklist,
      repository: inspector.repository,
    );

    final ReleaseStage stage;
    try {
      stage = _stageFor(unit);
    } on Object catch (error) {
      output.problem(Diagnostic(
        code: 'RK-STAGE-001',
        message: 'the release stage identity could not be resolved',
        remedy: '$error',
      ));
      output.halt(HaltKind.beforeActing);
      return ExitCodes.refused;
    }

    var stageInspection = stage.inspect();
    final states = <String, Inspection>{};
    for (final step in checklist.steps) {
      states[step.id] = await _observeForRelease(
        step,
        unit,
        stageInspection,
      );
      final state = states[step.id]!;
      output.step(
        step,
        verdict: state.verdict,
        detail: state.detail,
        evidence: state.evidence,
        action: step.isPublic
            ? (state.isExact
                ? _ReleaseAction.alreadyExact.wire
                : _ReleaseAction.notAttempted.wire)
            : null,
        show: false,
      );
    }

    await inspector.releaseMonotonicity(unit, targets, problems);
    inspector.tagGuards(unit, checklist, states).forEach(problems.report);
    if (problems.isNotEmpty) {
      output.halt(HaltKind.beforeActing);
      output.problems(problems.found);
      return ExitCodes.refused;
    }

    // A forge or tap that already exists cannot be compared byte-for-byte
    // until this source has an exact stage. Defer only that specific unknown;
    // every other unread public target still blocks before local work.
    final initialBlock = checklist.steps.where((step) {
      if (step.kind == StepKind.completeStage) return false;
      final state = states[step.id]!;
      if (!Inspector.blocks(step, state)) return false;
      return !(stageInspection.reusable == false &&
          state.verdict == Verdict.unknown &&
          (step.kind == StepKind.publishRelease ||
              step.kind == StepKind.publishFormula));
    }).firstOrNull;
    if (initialBlock != null) {
      _haltForState(initialBlock, states[initialBlock.id]!);
      return ExitCodes.refused;
    }

    final publicSteps = checklist.steps.where((step) => step.isPublic).toList();
    final publicActions = {
      for (final step in publicSteps)
        step.id: states[step.id]!.isExact
            ? _ReleaseAction.alreadyExact
            : _ReleaseAction.notAttempted,
    };
    if (publicSteps.isNotEmpty &&
        publicSteps.every((step) => states[step.id]!.isExact)) {
      output.line(
        '${unit.name} ${unit.version}',
        mark: Mark.done,
        note: 'already released',
      );
      return ExitCodes.ok;
    }

    // Once any binary target is exact, the original signed/notarized stage is
    // recovery-critical until every other target is also proved exact. An
    // unread forge or tap cannot be treated as permission to rebuild: it may
    // already contain the bytes bound by the public tag.
    final partialBinaryRelease = unit.shipsBinaries &&
        !stageInspection.reusable &&
        publicSteps.any((step) => states[step.id]!.isExact) &&
        publicSteps.any((step) {
          final state = states[step.id]!;
          return state.isAbsent || state.verdict == Verdict.unknown;
        });
    if (partialBinaryRelease) {
      output.halt(HaltKind.unfixableByRerun);
      output.problem(Diagnostic(
        code: 'RK-STAGE-005',
        message: 'the partial binary release needs its exact stage',
        remedy: 'restore ${stage.directory.path} from the machine that '
            'staged this release. Signed or notarized bytes cannot be '
            'recreated byte-for-byte after a public target has bound them.',
      ));
      if (!stageOnly) _showReleaseActions(targets, publicActions);
      return ExitCodes.refused;
    }
    if (!stageInspection.reusable) {
      final refusal = _refuseIfUnfinishable(unit);
      if (refusal != null) {
        output.halt(HaltKind.beforeActing);
        output.problem(refusal);
        if (!stageOnly) _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }
    }

    if (!stageOnly) {
      // Do not acquire or refresh a native publishing session when the stage
      // facts already prove this run must stop. Stage-only mode keeps its
      // explicit ability to replace reviewed-but-invalid bytes.
      final stageProblem = _stagePreparationProblem(
        unit,
        stageInspection,
        mayReplaceReviewed: false,
      );
      if (stageProblem != null) {
        output.problem(stageProblem, unit: unit.name);
        output.halt(HaltKind.beforeActing);
        _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }
      if (!_requireAuthorizer(unit)) {
        _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }
      final remaining =
          publicSteps.where((step) => states[step.id]!.isAbsent).toList();
      if (!await _preflightPubSession(unit, remaining)) {
        _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }
    }

    output.heading('${unit.name} ${unit.version} › '
        '${unit.projects.expand((p) => p.channels).toSet().join(', ')}');
    output.blank();

    for (final step in checklist.steps) {
      final state = states[step.id]!;
      output.step(
        step,
        mark: state.isExact ? Mark.satisfied : Mark.none,
        verdict: state.verdict,
        detail: state.detail,
        note: state.isExact ? (state.detail ?? 'already done') : null,
        action: step.isPublic ? publicActions[step.id]!.wire : null,
        depth: 0,
      );
    }

    final prepared = await _prepareStage(
      unit,
      checklist,
      stage,
      stageInspection,
    );
    if (prepared == null) {
      if (!stageOnly) _showReleaseActions(targets, publicActions);
      return ExitCodes.refused;
    }
    stageInspection = stage.inspect();
    if (!stageInspection.reusable) {
      output.problem(Diagnostic(
        code: 'RK-STAGE-003',
        message: 'the release stage did not remain valid',
        remedy: stageInspection.issues.join('\n'),
      ));
      output.halt(HaltKind.beforeActing);
      if (!stageOnly) _showReleaseActions(targets, publicActions);
      return ExitCodes.refused;
    }

    // Re-resolve the complete identity, not only HEAD. The stage plan also
    // binds the PATH-selected compiler, host ABI, origin, destinations, and
    // tag-signing policy. Stage-only completion must make the same claim that
    // those inputs remained stable while producers ran.
    if (!_releaseContextStillValid(
      stage,
      unit,
      changed: 'after staging',
      halt: HaltKind.beforeActing,
    )) {
      return ExitCodes.refused;
    }

    if (stageOnly) {
      _sayClaims(
        prepared.claims,
        prepared.firstCertificate,
        prepared.codeId,
      );
      output.blank();
      output.line(
        '${unit.name} ${unit.version} staged',
        mark: Mark.done,
        note: stage.directory.identity.id,
      );
      output.say('validated at ${stage.directory.path}');
      output.next('rk release ${unit.name}');
      return ExitCodes.ok;
    }

    // Public reality is refreshed after staging. Unknown and conflict never
    // grant permission; exact work is skipped; only absent work may act.
    for (final step in publicSteps) {
      states[step.id] = await inspector.inspect(step, unit);
      publicActions[step.id] = states[step.id]!.isExact
          ? _ReleaseAction.alreadyExact
          : _ReleaseAction.notAttempted;
      output.step(
        step,
        verdict: states[step.id]!.verdict,
        detail: states[step.id]!.detail,
        evidence: states[step.id]!.evidence,
        action: publicActions[step.id]!.wire,
        show: false,
      );
      if (states[step.id]!.isExact || states[step.id]!.isAbsent) continue;
      _haltForState(step, states[step.id]!);
      _showReleaseActions(targets, publicActions);
      return ExitCodes.refused;
    }

    final refreshedVersions = Diagnostics();
    await inspector.releaseMonotonicity(
      unit,
      targets,
      refreshedVersions,
      refreshRegistry: true,
    );
    if (refreshedVersions.isNotEmpty) {
      output.halt(HaltKind.beforeActing);
      output.problems(refreshedVersions.found);
      _showReleaseActions(targets, publicActions);
      return ExitCodes.refused;
    }

    var remaining =
        publicSteps.where((step) => states[step.id]!.isAbsent).toList();
    if (remaining.isEmpty) {
      output.blank();
      output.line(
        '${unit.name} ${unit.version}',
        mark: Mark.done,
        note: 'already released',
      );
      return ExitCodes.ok;
    }

    if (checklist.steps.any((step) => step.kind == StepKind.sign)) {
      final refreshedBaseline = await _signingBaseline(unit);
      if (!refreshedBaseline.ok) {
        _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }
      if (refreshedBaseline.requirement != prepared.publishedRequirement) {
        output.problem(Diagnostic(
          code: 'RK-SIGN-013',
          message: 'the published signing identity changed after staging',
          remedy: 'The reviewed signature was built against a different '
              'public baseline. Rebuild it explicitly: '
              'rk release ${unit.name} --stage.',
        ));
        output.halt(HaltKind.beforeActing);
        _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }
    }

    if (!_releaseContextStillValid(
      stage,
      unit,
      changed: 'before authorization',
      halt: HaltKind.beforeActing,
    )) {
      _showReleaseActions(targets, publicActions);
      return ExitCodes.refused;
    }

    // Public reads can take long enough for a local process or operator to
    // alter the private stage. Consent must bind the bytes inspected now,
    // not the ones that were valid before those reads began.
    if (!_stageStillValid(
      stage,
      unit,
      changed: 'before authorization',
      halt: HaltKind.beforeActing,
    )) {
      _showReleaseActions(targets, publicActions);
      return ExitCodes.refused;
    }

    // Authorization names the targets and consequences that are true now,
    // after every potentially slow signing/context check. The per-target loop
    // still reads again after consent; this snapshot exists so the operator
    // never authorizes a stale remaining set.
    for (final step in publicSteps) {
      states[step.id] = await inspector.inspect(step, unit);
      publicActions[step.id] = states[step.id]!.isExact
          ? _ReleaseAction.alreadyExact
          : _ReleaseAction.notAttempted;
      output.step(
        step,
        verdict: states[step.id]!.verdict,
        detail: states[step.id]!.detail,
        evidence: states[step.id]!.evidence,
        action: publicActions[step.id]!.wire,
        show: false,
      );
      if (states[step.id]!.isExact || states[step.id]!.isAbsent) continue;
      _haltForState(step, states[step.id]!);
      _showReleaseActions(targets, publicActions);
      return ExitCodes.refused;
    }
    final authorizationVersions = Diagnostics();
    await inspector.releaseMonotonicity(
      unit,
      targets,
      authorizationVersions,
      refreshRegistry: true,
    );
    if (authorizationVersions.isNotEmpty) {
      output.halt(HaltKind.beforeActing);
      output.problems(authorizationVersions.found);
      _showReleaseActions(targets, publicActions);
      return ExitCodes.refused;
    }
    remaining = publicSteps.where((step) => states[step.id]!.isAbsent).toList();
    if (remaining.isEmpty) {
      output.blank();
      output.line(
        '${unit.name} ${unit.version}',
        mark: Mark.done,
        note: 'already released',
      );
      return ExitCodes.ok;
    }

    if (!await _authorize(
      unit,
      remaining,
      firstCertificate: prepared.firstCertificate,
      codeId: prepared.codeId,
      claims: prepared.claims,
    )) {
      _showReleaseActions(targets, publicActions);
      return ExitCodes.refused;
    }
    if (!_releaseContextStillValid(
      stage,
      unit,
      changed: 'during authorization',
      halt: HaltKind.beforeActing,
    )) {
      _showReleaseActions(targets, publicActions);
      return ExitCodes.refused;
    }
    if (!_stageStillValid(
      stage,
      unit,
      changed: 'during authorization',
      halt: HaltKind.beforeActing,
    )) {
      _showReleaseActions(targets, publicActions);
      return ExitCodes.refused;
    }

    output.blank();
    var completedPublicTarget = false;
    for (final step in publicSteps) {
      var state = await inspector.inspect(step, unit);
      if (state.isExact) {
        publicActions[step.id] = _ReleaseAction.alreadyExact;
        output.step(
          step,
          mark: Mark.satisfied,
          verdict: state.verdict,
          note: state.detail ?? 'already done',
          action: publicActions[step.id]!.wire,
        );
        continue;
      }
      if (!state.isAbsent) {
        _haltForState(step, state);
        _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }

      final target = targets.singleWhere(
        (target) => target.step.id == step.id,
      );
      if (target.kind != ReleaseTargetKind.homebrew) {
        final currentVersion = Diagnostics();
        await inspector.releaseMonotonicity(
          unit,
          [target],
          currentVersion,
          refreshRegistry: true,
        );
        if (currentVersion.isNotEmpty) {
          output.halt(
            output.report.acted
                ? HaltKind.stoppedPartway
                : HaltKind.beforeActing,
          );
          output.problems(currentVersion.found);
          _showReleaseActions(targets, publicActions);
          return ExitCodes.refused;
        }

        // The latest-version read may have refreshed a registry cache, and a
        // candidate can appear while the operator is authorizing. Re-read the
        // exact coordinate from that same fresh provider view before acting.
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
          publicActions[step.id] = _ReleaseAction.alreadyExact;
          output.step(
            step,
            mark: Mark.satisfied,
            verdict: state.verdict,
            note: state.detail ?? 'already done',
            action: publicActions[step.id]!.wire,
          );
          continue;
        }
        if (!state.isAbsent) {
          _haltForState(step, state);
          _showReleaseActions(targets, publicActions);
          return ExitCodes.refused;
        }
      }

      if (!_stageStillValid(
        stage,
        unit,
        changed: 'before ${step.summary}',
        halt: completedPublicTarget
            ? HaltKind.stoppedPartway
            : HaltKind.beforeActing,
      )) {
        _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }
      if (!_releaseContextStillValid(
        stage,
        unit,
        changed: 'before ${step.summary}',
        halt: completedPublicTarget
            ? HaltKind.stoppedPartway
            : HaltKind.beforeActing,
      )) {
        _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }

      // Make the provider observation the last fallible read before the act.
      // Local stage/context validation above cannot therefore create a gap in
      // which a newly exact or conflicting target is acted on blindly.
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
        publicActions[step.id] = _ReleaseAction.alreadyExact;
        output.step(
          step,
          mark: Mark.satisfied,
          verdict: state.verdict,
          note: state.detail ?? 'already done',
          action: publicActions[step.id]!.wire,
        );
        continue;
      }
      if (!state.isAbsent) {
        _haltForState(step, state);
        _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }
      final actedBefore = output.report.acted;
      output.report.acted = true;
      publicActions[step.id] = _ReleaseAction.attempted;
      output.step(
        step,
        verdict: state.verdict,
        detail: state.detail,
        evidence: state.evidence,
        action: publicActions[step.id]!.wire,
        show: false,
      );
      final act = await _act(
        step,
        unit,
        prepared.publishedRequirement,
        prepared.codeId,
        prepared.notesPath,
        inspectedTarget: state,
      );
      // An act's process result is not public truth. A registry can accept an
      // upload before the client loses its response; Git can finish a push
      // before the connection drops; GitHub can apply the final draft PATCH
      // before `gh` exits non-zero. Always run the same destination inspection
      // status uses before deciding what the command result means.
      state = await _observeAfterAct(step, unit, target);
      publicActions[step.id] =
          state.isExact ? _ReleaseAction.completed : _ReleaseAction.failed;
      output.step(
        step,
        verdict: state.verdict,
        detail: state.detail,
        evidence: state.evidence,
        action: publicActions[step.id]!.wire,
        show: false,
      );
      if (!act.ok) {
        if (state.isExact && !output.report.halted) {
          output.step(
            step,
            mark: Mark.done,
            verdict: state.verdict,
            detail: state.detail,
            note: act.reconciledNote ??
                'command response was lost · public target confirmed exact',
            action: publicActions[step.id]!.wire,
          );
          completedPublicTarget = true;
          continue;
        }
        if (!act.failureAlreadyReported) {
          await _reportDestinationFailure(
            step,
            target,
            state,
            act,
            actedBefore: actedBefore,
          );
        } else if (!output.report.halted) {
          output.halt(
            actedBefore ? HaltKind.stoppedPartway : HaltKind.beforeActing,
          );
        }
        _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }
      if (!state.isExact) {
        if (target.kind == ReleaseTargetKind.homebrew ||
            target.kind == ReleaseTargetKind.gitTag ||
            target.kind == ReleaseTargetKind.pubDev) {
          await _reportDestinationFailure(
            step,
            target,
            state,
            act,
            actedBefore: actedBefore,
          );
          _showReleaseActions(targets, publicActions);
          return ExitCodes.refused;
        }
        _haltForState(step, state, afterAct: true);
        _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }
      if (act.successNote != null) {
        final inspected = act.includeInspectionDetail && state.detail != null
            ? ' · ${state.detail}'
            : '';
        output.step(
          step,
          mark: Mark.done,
          verdict: state.verdict,
          detail: state.detail,
          note: '${act.successNote}$inspected',
          action: publicActions[step.id]!.wire,
        );
      }
      completedPublicTarget = true;
    }

    output.blank();
    output.line('${unit.name} ${unit.version} released', mark: Mark.done);
    for (final project in unit.projects) {
      if (!project.channels.contains('pub.dev')) continue;
      output.say(
          'pub.dev/packages/${project.name}/versions/'
          '${project.version}',
          depth: 1);
    }
    return ExitCodes.ok;
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

  /// The authoritative post-action read.
  ///
  /// pub.dev can accept immutable bytes before its version index exposes
  /// them. Polling belongs here, where every observation is the same exact
  /// archive comparison status uses, rather than inside the publisher where
  /// an early absence could emit a halt that a later exact read cannot undo.
  Future<Inspection> _observeAfterAct(
    Step step,
    ResolvedUnit unit,
    TargetExpectation target,
  ) async {
    if (target.kind != ReleaseTargetKind.pubDev) {
      return inspector.inspect(step, unit);
    }

    final project = unit.projects.firstWhere((p) => p.name == step.project);
    var waited = Duration.zero;
    while (true) {
      registry.forget(project.name);
      final state = await inspector.inspect(step, unit);
      if (!state.isAbsent || waited >= confirmDeadline) {
        if (state.isAbsent && waited >= confirmDeadline) {
          return Inspection.absent(
            detail: 'pub.dev does not report it after ${waited.inSeconds}s: '
                '${project.name} ${project.version}',
            evidence: state.evidence,
          );
        }
        return state;
      }
      await _wait(confirmInterval);
      waited += confirmInterval;
    }
  }

  void _haltForState(Step step, Inspection state, {bool afterAct = false}) {
    output.halt(
      state.verdict == Verdict.conflict
          ? (afterAct ? HaltKind.actedAndUnfixable : HaltKind.unfixableByRerun)
          : afterAct
              ? HaltKind.lostTrack
              : HaltKind.beforeActing,
    );
    output.problem(Diagnostic(
      code: afterAct ? 'RK-REL-003' : 'RK-REL-001',
      message: '${step.summary}: ${state.detail ?? state.verdict.name}',
      remedy: state.evidence.isEmpty
          ? (state.verdict == Verdict.unknown
              ? 'the target could not be proven; fix the read and re-run'
              : null)
          : state.evidence.entries
              .map((entry) => '${entry.key}: ${entry.value}')
              .join('\n'),
    ));
  }

  void _showReleaseActions(
    List<TargetExpectation> targets,
    Map<String, _ReleaseAction> actions,
  ) {
    output.blank();
    output.heading('Release targets');
    for (final target in targets) {
      final action = actions[target.step.id] ?? _ReleaseAction.notAttempted;
      final mark = switch (action) {
        _ReleaseAction.completed => Mark.done,
        _ReleaseAction.alreadyExact => Mark.satisfied,
        _ReleaseAction.failed => Mark.blocked,
        _ReleaseAction.notAttempted || _ReleaseAction.attempted => Mark.none,
      };
      output.line(
        target.label,
        mark: mark,
        note: action.human,
        depth: 1,
      );
    }
  }

  bool _stageStillValid(
    ReleaseStage stage,
    ResolvedUnit unit, {
    required String changed,
    required HaltKind halt,
  }) {
    final inspected = stage.inspect();
    if (inspected.reusable) return true;
    output.problem(Diagnostic(
      code: 'RK-STAGE-002',
      message: 'the reviewed release stage changed $changed',
      remedy: '${inspected.issues.join('\n')}\n'
          'rebuild it explicitly: rk release ${unit.name} --stage',
    ));
    output.halt(halt);
    return false;
  }

  /// Re-reads every ambient input that authorizes reuse of [stage].
  ///
  /// A valid receipt proves the staged bytes did not change. It cannot prove
  /// that the repository, remote, signing policy, host, or PATH-selected
  /// compiler still describe the release the operator is about to publish.
  /// Re-resolving the stage identity binds those facts at each public boundary.
  bool _releaseContextStillValid(
    ReleaseStage stage,
    ResolvedUnit unit, {
    required String changed,
    required HaltKind halt,
  }) {
    final drift = <String>[];
    final GitState current;
    try {
      current = _refreshGit();
    } on Object catch (error) {
      output.problem(Diagnostic(
        code: 'RK-STAGE-004',
        message: 'the release context could not be refreshed $changed',
        remedy: '$error\n'
            'restore a readable repository, then re-run '
            'rk release ${unit.name} --stage',
      ));
      output.halt(halt);
      return false;
    }

    if (current.head != git.head) {
      drift.add(
          'HEAD is ${current.shortHead}; staged HEAD was ${git.shortHead}');
    }
    if (current.headTree != git.headTree) {
      drift.add('the HEAD tree changed');
    }
    if (!current.isClean) {
      final detail = current.worktreeStatusError ??
          (current.uncommitted.isEmpty
              ? 'the worktree is not clean'
              : 'uncommitted: ${current.uncommitted.join(', ')}');
      drift.add(detail);
    }
    if (!current.headIsPushed) {
      drift.add('HEAD is no longer present on a remote branch');
    }
    if (current.originUrl != git.originUrl) {
      drift.add('origin is ${current.originUrl ?? 'unreadable'}; staged origin '
          'was ${git.originUrl ?? 'unreadable'}');
    }
    if (current.signingConfigured != git.signingConfigured) {
      drift.add('the Git tag-signing policy changed');
    }

    try {
      final refreshed = _refreshStage(unit, current);
      if (refreshed.directory.identity.id != stage.directory.identity.id) {
        drift.add('the release plan now resolves to '
            '${refreshed.directory.identity.id}; the reviewed stage is '
            '${stage.directory.identity.id}');
      }
    } on Object catch (error) {
      drift.add('the release plan could not be resolved: $error');
    }

    if (drift.isEmpty) return true;
    output.problem(Diagnostic(
      code: 'RK-STAGE-004',
      message: 'the repository or release plan changed $changed',
      remedy: '${drift.join('\n')}\n'
          'restore those inputs or review a replacement stage: '
          'rk release ${unit.name} --stage',
    ));
    output.halt(halt);
    return false;
  }

  Future<void> _reportDestinationFailure(
    Step step,
    TargetExpectation target,
    Inspection state,
    _ActOutcome act, {
    required bool actedBefore,
  }) async {
    final homebrew = target.kind == ReleaseTargetKind.homebrew;
    final tag = target.kind == ReleaseTargetKind.gitTag;
    final pub = target.kind == ReleaseTargetKind.pubDev;

    String? cleanup;
    var localCleanupFailed = false;
    if (tag && state.isAbsent && act.removeLocalTagIfAbsent != null) {
      final removed = await _tags.deleteLocal(act.removeLocalTagIfAbsent!);
      localCleanupFailed = !removed.ok;
      cleanup = removed.ok
          ? 'the local tag was removed, so re-running starts clean'
          : 'the local tag could not be removed and was left in place; '
              're-running inspects and pushes it safely';
    }

    late final String code;
    late final String message;
    if (homebrew) {
      code = switch (state.verdict) {
        Verdict.unknown => 'RK-BREW-002',
        Verdict.conflict => 'RK-BREW-003',
        Verdict.absent || Verdict.exact => 'RK-BREW-001',
      };
      message = switch (state.verdict) {
        Verdict.unknown => 'the tap was updated and could not be read back',
        Verdict.conflict => 'the public tap does not hold what rk pushed',
        Verdict.absent || Verdict.exact => 'the tap formula was not updated',
      };
    } else if (pub) {
      if (state.verdict == Verdict.conflict) {
        code = 'RK-PUB-006';
        message = '${act.coordinate ?? step.project}: '
            '${state.detail ?? 'the public archive differs'}';
      } else {
        code = act.diagnostic?.code ?? 'RK-PUB-005';
        message = act.diagnostic?.message ??
            '${act.coordinate ?? step.project}: the exact public archive '
                'could not be confirmed';
      }
    } else if (tag) {
      if (state.verdict == Verdict.conflict) {
        code = 'RK-TAG-004';
        message = 'origin did not confirm the release binding on '
            '${act.coordinate ?? target.coordinate}';
      } else {
        code = act.diagnostic?.code ?? 'RK-TAG-003';
        message = act.diagnostic?.message ??
            'the push reported success, and origin did not confirm the exact '
                'tag ${act.coordinate ?? target.coordinate}';
      }
    } else {
      code = 'RK-REL-003';
      message = '${step.summary}: '
          '${act.problem ?? state.detail ?? 'the public result could not be confirmed'}';
    }

    final details = <String>[
      if (act.diagnostic?.remedy != null) act.diagnostic!.remedy!,
      if (act.problem != null) act.problem!,
      if (act.draftEffect == DraftEffect.changed)
        'GitHub private draft state changed; this step did not publish a '
            'GitHub Release.',
      if (act.draftEffect == DraftEffect.uncertain)
        'GitHub private draft state may have changed; no GitHub Release was '
            'confirmed public.',
      if (state.detail != null) state.detail!,
      ...state.evidence.entries.map((entry) => '${entry.key}: ${entry.value}'),
      if (act.permanent != null) act.permanent!,
      if (cleanup != null) cleanup,
    ];
    output.problem(
      Diagnostic(
        code: code,
        message: message,
        remedy: details.isEmpty
            ? 're-run; the shared destination inspection will classify the '
                'public target before any retry'
            : details.join('\n'),
      ),
      unit: step.unit,
    );

    if (pub && code == 'RK-PUB-005') {
      output.next('rk status ${step.unit}');
    }

    final immutableConflict = state.verdict == Verdict.conflict &&
        (target.kind == ReleaseTargetKind.githubRelease || pub || tag);
    final repairableFormulaConflict =
        homebrew && state.verdict == Verdict.conflict;
    final tagPushProvedAbsent = tag && !act.ok && state.isAbsent;
    final kind = act.terminal || immutableConflict
        ? HaltKind.actedAndUnfixable
        : repairableFormulaConflict || localCleanupFailed
            ? HaltKind.stoppedPartway
            : tagPushProvedAbsent
                ? (actedBefore
                    ? HaltKind.stoppedPartway
                    : HaltKind.beforeActing)
                : act.mayHaveActed ||
                        act.draftEffect == DraftEffect.uncertain ||
                        state.verdict == Verdict.unknown
                    ? HaltKind.lostTrack
                    : act.draftEffect == DraftEffect.changed || actedBefore
                        ? HaltKind.stoppedPartway
                        : HaltKind.beforeActing;
    output.halt(kind);
    if (kind == HaltKind.actedAndUnfixable) {
      output.report.rerunHelps = false;
    }
  }

  Future<_PreparedStage?> _prepareStage(
    ResolvedUnit unit,
    Checklist checklist,
    ReleaseStage stage,
    StageInspection inspected,
  ) async {
    final claims = await _firstClaims(unit);
    if (inspected.reusable) {
      final notes = File(stage.directory.resolve('release-notes.md'));
      final signing = inspected.receipt!.steps
          .where((step) => step.name.startsWith('sign:'))
          .firstOrNull
          ?.evidence;
      final signature = signing?['signature'];
      final signatureMap = signature is Map ? signature : const {};
      final firstIdentity = signatureMap['first_identity'] == true;
      return _PreparedStage(
        claims: claims,
        notesPath: notes.existsSync() ? notes.path : null,
        publishedRequirement: signatureMap['published_requirement'] as String?,
        firstCertificate:
            firstIdentity ? signatureMap['certificate'] as String? : null,
        codeId: signatureMap['code_id'] as String?,
      );
    }

    final stageProblem = _stagePreparationProblem(
      unit,
      inspected,
      mayReplaceReviewed: stageOnly,
    );
    if (stageProblem != null) {
      output.problem(stageProblem, unit: unit.name);
      output.halt(HaltKind.beforeActing);
      return null;
    }

    output.say(
      stageOnly
          ? 'staging prepares real release bytes and may use signing and '
              'notary credentials or contact Apple; it publishes nothing.'
          : 'preparing the exact private stage before authorization.',
    );

    final progress = <StageStep>[];
    late final List<StageArtifact> sourceArtifacts;
    late final StageStep sourceStep;
    if (inspected.validProgress) {
      progress.addAll(inspected.receipt!.steps);
      sourceStep = progress.first;
      sourceArtifacts = List<StageArtifact>.from(sourceStep.outputs);
      output.say('resuming the validated staged work already on disk.');
    } else {
      try {
        stage.reset();
      } on Object catch (error) {
        output.problem(Diagnostic(
          code: 'RK-STAGE-001',
          message: 'the old release stage could not be replaced safely',
          remedy: '$error',
        ));
        output.halt(HaltKind.beforeActing);
        return null;
      }

      try {
        sourceArtifacts = stage.materializeSource();
        sourceStep = _sourceStageStep(stage, sourceArtifacts);
        progress.add(sourceStep);
        _persistStageProgress(stage, sourceArtifacts, progress);
      } on Object catch (error) {
        output.problem(Diagnostic(
          code: 'RK-STAGE-003',
          message: 'the committed source could not be staged',
          remedy: '$error',
        ));
        output.halt(HaltKind.beforeActing);
        return null;
      }
    }
    final stagedSource = SnapshotSourceTree(stage.sourceRoot);

    final pubProjects = unit.projects
        .where((project) => project.channels.contains('pub.dev'))
        .toList()
      ..sort((left, right) => left.name.compareTo(right.name));
    for (final project in pubProjects) {
      final receiptName = 'pub-preflight:${project.name}';
      if (progress.any((record) => record.name == receiptName)) continue;
      try {
        if (!await _publishPreflight(project, stage.sourceRoot)) return null;
      } on Object catch (error) {
        return _stageOperationFailed(
          'the package preflight for ${project.name}',
          error,
        );
      }
      progress.add(StageStep(
        name: receiptName,
        inputs: [StageInput.step(sourceStep)],
        evidence: const {
          'publish_dry_run': 'passed',
          'consumer_resolve': 'passed',
        },
      ));
      try {
        _persistStageProgress(stage, sourceArtifacts, progress);
      } on Object catch (error) {
        return _stageProgressFailed(error);
      }
    }

    String? publishedRequirement;
    String? firstCertificate;
    SigningIdentity? signingIdentity;
    String? certificateSha256;
    String? codeId;
    if (checklist.steps.any((step) => step.kind == StepKind.sign)) {
      final baseline = await _signingBaseline(unit);
      if (!baseline.ok) return null;
      publishedRequirement = baseline.requirement;
      if (publishedRequirement != null &&
          !_declarationAgrees(unit, publishedRequirement)) {
        return null;
      }
      final keychain = await _signingCertificate(unit, publishedRequirement);
      if (!keychain.ok) return null;
      firstCertificate = keychain.firstCertificate;
      signingIdentity = keychain.identity;
      certificateSha256 = keychain.certificateSha256;
      codeId = publishedRequirement == null
          ? unit.codeId
          : BinaryChain.identifierOf(publishedRequirement) ?? unit.codeId;
      if (codeId == null) {
        output.problem(Diagnostic(
          code: 'RK-SIGN-009',
          message: 'no release states what this program is called',
          remedy: 'Add to [release.${unit.name}]: code_id = '
              '"${_conventionalCodeId(unit)}". The first signature makes '
              'this identity permanent.',
        ));
        output.halt(HaltKind.beforeActing);
        return null;
      }
    }

    String? notesPath;
    if (checklist.steps.any((step) => step.kind == StepKind.publishRelease)) {
      if (!progress.any((record) => record.name == 'release-notes')) {
        final notes = _releaseNotes(unit.binaryProject, source: stagedSource);
        if (notes == null) return null;
        try {
          output.report.acted = true;
          _chain(unit).workspace.write('release-notes.md', utf8.encode(notes));
          progress.add(StageStep(
            name: 'release-notes',
            inputs: [StageInput.step(sourceStep)],
            outputs: [
              StageArtifact.capture(
                stage: stage.directory,
                path: 'release-notes.md',
                type: 'notes',
              ),
            ],
          ));
          _persistStageProgress(stage, sourceArtifacts, progress);
        } on Object catch (error) {
          return _stageOperationFailed('release-note production', error);
        }
      }
      notesPath = _chain(unit).workspace.pathOf('release-notes.md');
    }

    final producerSteps = checklist.steps.where((step) {
      return !step.isPublic &&
          step.kind != StepKind.prerequisite &&
          step.kind != StepKind.completeStage;
    }).toList()
      ..sort(_compareProducerSteps);
    for (final step in producerSteps) {
      if (_producerRecorded(progress, step)) {
        output.step(
          step,
          mark: Mark.satisfied,
          verdict: Verdict.exact,
          detail: 'validated in the interrupted stage',
          note: 'validated in the interrupted stage',
        );
        continue;
      }
      final replacedBuild = step.kind == StepKind.sign
          ? progress
              .where(
                (record) => record.name == 'build:${step.platform}',
              )
              .firstOrNull
          : null;
      output.report.acted = true;
      final _ActOutcome act;
      try {
        act = await _act(
          step,
          unit,
          publishedRequirement,
          codeId,
          notesPath,
          signingIdentity: signingIdentity,
          certificateSha256: certificateSha256,
        );
      } on Object catch (error) {
        return _stageOperationFailed(step.summary, error);
      }
      if (!act.ok) {
        if (!output.report.halted) output.halt(HaltKind.stoppedPartway);
        return null;
      }
      try {
        if (replacedBuild != null) progress.remove(replacedBuild);
        progress.add(_captureProducerStep(
          stage,
          step,
          sourceStep,
          progress,
          act.producer!,
          smokeEvidence: replacedBuild?.evidence['smoke'],
        ));
        _persistStageProgress(stage, sourceArtifacts, progress);
      } on Object catch (error) {
        return _stageProgressFailed(error);
      }
    }

    if (unit.shipsBinaries &&
        unit.binaryProject.channels.contains('homebrew')) {
      final repository = _repository('homebrew');
      if (repository == null) return null;
      try {
        final core = _chain(unit).gatherAssets(
          unit.binaryProject,
          unit.name,
          includeFinal: false,
        );
        if (core == null) return null;
        if (!progress.any((record) => record.name == 'homebrew-formula')) {
          output.report.acted = true;
          _chain(unit).renderFormula(
            project: unit.binaryProject,
            repository: repository,
            tag: unit.tag,
            assets: core,
          );
          final archives = progress
              .where((record) => record.name.startsWith('archive:'))
              .expand((record) => record.outputs)
              .where((artifact) => artifact.type == 'archive')
              .toList();
          progress.add(StageStep(
            name: 'homebrew-formula',
            inputs: [
              for (final archive in archives) StageInput.artifact(archive),
            ],
            outputs: [
              StageArtifact.capture(
                stage: stage.directory,
                path: ReleaseAssets.formulaName(
                  unit.binaryProject.executable!,
                ),
                type: 'formula',
              ),
            ],
          ));
          _persistStageProgress(stage, sourceArtifacts, progress);
        }
      } on Object catch (error) {
        return _stageOperationFailed('Homebrew formula production', error);
      }
    }

    try {
      final publicArtifacts = unit.shipsBinaries
          ? (Inspector.expectedAssets(unit)..remove(ReleaseAssets.manifest))
          : <String>{};
      stage.finalize(
        publicArtifacts: publicArtifacts,
        evidence: {
          'requested_mode': stageOnly ? 'stage' : 'one-shot',
          'source_commit': stage.directory.identity.headCommit,
          'source_tree': stage.directory.identity.headTree,
        },
      );
    } on Object catch (error) {
      output.problem(Diagnostic(
        code: 'RK-STAGE-003',
        message: 'the release stage could not be completed',
        remedy: '$error',
      ));
      output.halt(HaltKind.beforeActing);
      return null;
    }

    output.step(
      checklist.steps.singleWhere(
        (step) => step.kind == StepKind.completeStage,
      ),
      mark: Mark.done,
      verdict: Verdict.exact,
      detail: 'staged and validated',
      note: 'staged and validated',
    );
    return _PreparedStage(
      claims: claims,
      publishedRequirement: publishedRequirement,
      firstCertificate: firstCertificate,
      codeId: codeId,
      notesPath: notesPath,
    );
  }

  Diagnostic? _stagePreparationProblem(
    ResolvedUnit unit,
    StageInspection inspected, {
    required bool mayReplaceReviewed,
  }) {
    if (inspected.reusable) return null;

    final unsafe = inspected.issues
        .where((issue) => issue.kind == StageIssueKind.unsafePath)
        .firstOrNull;
    if (unsafe != null) {
      return Diagnostic(
        code: 'RK-STAGE-001',
        message: 'the release stage path is unsafe',
        remedy: unsafe.toString(),
      );
    }

    final completedOrCorrupt = inspected.receipt?.complete == true ||
        inspected.issues
            .any((issue) => issue.kind == StageIssueKind.invalidReceipt);
    if (completedOrCorrupt && !mayReplaceReviewed) {
      return Diagnostic(
        code: 'RK-STAGE-002',
        message: 'the reviewed release stage no longer validates',
        remedy: '${inspected.issues.join('\n')}\n'
            'rk will not silently replace reviewed bytes. Rebuild it '
            'explicitly: rk release ${unit.name} --stage',
      );
    }
    return null;
  }

  StageStep _sourceStageStep(
    ReleaseStage stage,
    List<StageArtifact> sourceArtifacts,
  ) =>
      StageStep(
        name: 'source-snapshot',
        inputs: [
          StageInput.commit(stage.directory.identity),
          StageInput.tree(stage.directory.identity),
          StageInput.plan(stage.directory.identity),
        ],
        outputs: sourceArtifacts,
        evidence: {
          'commit': stage.directory.identity.headCommit,
          'tree': stage.directory.identity.headTree,
        },
      );

  void _persistStageProgress(
    ReleaseStage stage,
    List<StageArtifact> sourceArtifacts,
    List<StageStep> steps,
  ) {
    stage.sealSource(sourceArtifacts);
    stage.writeProgress(steps);
  }

  _PreparedStage? _stageProgressFailed(Object error) {
    output.problem(Diagnostic(
      code: 'RK-STAGE-003',
      message: 'the completed producer could not be recorded safely',
      remedy: '$error',
    ));
    output.halt(HaltKind.beforeActing);
    return null;
  }

  _PreparedStage? _stageOperationFailed(String operation, Object error) {
    output.problem(Diagnostic(
      code: 'RK-STAGE-003',
      message: '$operation failed while preparing the release stage',
      remedy: '$error\nfix the local failure, then re-run; no public target '
          'was changed',
    ));
    if (!output.report.halted) output.halt(HaltKind.stoppedPartway);
    return null;
  }

  bool _producerRecorded(List<StageStep> progress, Step step) {
    final names = progress.map((record) => record.name).toSet();
    final platform = step.platform;
    return switch (step.kind) {
      StepKind.build => names.contains('build:$platform') ||
          (platform?.startsWith('macos-') == true &&
              names.contains('sign:$platform')),
      StepKind.sign => names.contains('sign:$platform'),
      StepKind.notarize => names.contains('notarize:$platform'),
      StepKind.archive => names.contains('archive:$platform'),
      StepKind.checksums => names.contains('checksums'),
      _ => false,
    };
  }

  static int _compareProducerSteps(Step left, Step right) {
    if (left.kind == StepKind.checksums) return 1;
    if (right.kind == StepKind.checksums) return -1;
    final byPlatform = left.platform!.compareTo(right.platform!);
    if (byPlatform != 0) return byPlatform;
    const rank = {
      StepKind.build: 0,
      StepKind.sign: 1,
      StepKind.notarize: 2,
      StepKind.archive: 3,
    };
    return rank[left.kind]!.compareTo(rank[right.kind]!);
  }

  StageStep _captureProducerStep(
    ReleaseStage stage,
    Step step,
    StageStep sourceStep,
    List<StageStep> progress,
    LocalProducerOutcome outcome, {
    required Object? smokeEvidence,
  }) {
    final outputs = [
      for (final output in outcome.outputs)
        StageArtifact.capture(
          stage: stage.directory,
          path: output.path,
          type: output.type,
        ),
    ];
    final evidence = <String, Object?>{
      ...outcome.evidence,
      if (step.kind == StepKind.sign && smokeEvidence != null)
        'smoke': smokeEvidence,
    };
    final platform = step.platform;
    switch (step.kind) {
      case StepKind.build:
      case StepKind.sign:
        return StageStep(
          name: '${step.kind == StepKind.sign ? 'sign' : 'build'}:$platform',
          inputs: [StageInput.step(sourceStep)],
          outputs: outputs,
          evidence: evidence,
        );

      case StepKind.notarize:
        final binary = progress
            .expand((record) => record.outputs)
            .where((artifact) =>
                artifact.type == 'executable' &&
                artifact.path.startsWith('$platform/'))
            .single;
        return StageStep(
          name: 'notarize:$platform',
          inputs: [StageInput.artifact(binary)],
          outputs: outputs,
          evidence: evidence,
        );

      case StepKind.archive:
        final binary = progress
            .expand((record) => record.outputs)
            .where((artifact) =>
                artifact.type == 'executable' &&
                artifact.path.startsWith('$platform/'))
            .single;
        return StageStep(
          name: 'archive:$platform',
          inputs: [StageInput.artifact(binary)],
          outputs: outputs,
          evidence: evidence,
        );

      case StepKind.checksums:
        final archives = progress
            .where((record) => record.name.startsWith('archive:'))
            .expand((record) => record.outputs)
            .where((artifact) => artifact.type == 'archive')
            .toList();
        if (archives.isEmpty) {
          throw StateError('checksums have no recorded archive inputs');
        }
        return StageStep(
          name: 'checksums',
          inputs: [
            for (final archive in archives) StageInput.artifact(archive),
          ],
          outputs: outputs,
          evidence: evidence,
        );

      default:
        throw StateError('step ${step.kind.name} is not a local producer');
    }
  }

  /// Package names this release claims for the first time.
  ///
  /// rk used to refuse a first publish outright (RK-REG-003), on the stated
  /// grounds that it "accepts the terms and names a publisher, which is the
  /// author's ceremony". That was not true. pub's own publish command has no
  /// first-time branch at all: `--force` skips only the confirmation prompt,
  /// the prompt text is identical for a new name, there is no terms
  /// acceptance in the flow, and a verified publisher is configured on the
  /// website afterwards or not at all. RFC 0002 *did* ask for the refusal —
  /// and asked for it on the same false premise, that "pub.dev accepts a
  /// first version only from an interactive publish". The spec is amended
  /// where it said so, per its own rule: where the code is right, move the
  /// spec.
  ///
  /// What IS true is narrower and worth saying out loud: a pub.dev package
  /// name is claimed permanently. It cannot be renamed, moved to another
  /// package, or given back. That is not a reason to refuse a release the
  /// operator intends — it is a reason to make sure they are looking at the
  /// name before they consent, because the accident this guards against is a
  /// typo claiming a name nobody meant to own.
  Future<List<String>> _firstClaims(ResolvedUnit unit) async {
    final claims = <String>[];
    for (final project in unit.projects) {
      if (!project.channels.contains('pub.dev')) continue;
      try {
        if (await registry.lookup(project.name) == null) {
          claims.add(project.name);
        }
      } on RegistryUnavailable {
        // Unread is not "never published" — the step's own inspection
        // reports the unreachable registry, and an unknown here must not
        // manufacture a claim notice for a name that may well exist.
        continue;
      }
    }
    return claims;
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
                  resolved.reason ?? 'it needs a different host', () => [])
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
      message: '${unit.name}: this machine cannot produce every platform '
          'it ships',
      remedy: 'starting anyway would build and sign for minutes and then '
          'stop before publishing anything:\n'
          '  ${folded.join('\n  ')}',
    );
  }

  /// Platforms this host can build but not execute, as the prompt says it.
  ///
  /// Read from the same capability resolution the chain builds with, before
  /// anything acts, so the operator sees it in the plan rather than after.
  List<String> _unprovable(ResolvedUnit unit) {
    if (!unit.shipsBinaries) return const [];
    final unprovable = <String>[];
    for (final project in unit.projects) {
      for (final platform in project.binaryPlatforms) {
        final resolved = capabilities.resolve(platform);
        if (resolved.canProduce && !resolved.canProve) {
          unprovable.add('$platform — ${resolved.reason}');
        }
      }
    }
    return unprovable;
  }

  void _validate(ResolvedUnit unit, Diagnostics problems) {
    final uncommitted = git.uncommittedProblem();
    if (uncommitted != null) problems.report(uncommitted);
    final unpushed = git.unpushedProblem();
    if (unpushed != null) problems.report(unpushed);
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

  /// Whether this machine can sign, resolved before anything acts.
  ///
  /// Returns the certificate a *first* signed release will make permanent,
  /// or null when there is a published identity to reproduce instead. The
  /// The keychain used to be read only by `MacOsSigner.sign`, where its answer
  /// arrived too late to make a useful preflight decision in the older
  /// publish-before-build pipeline. The current stage-before-public order
  /// keeps both this check and signing ahead of the tag, but the explicit
  /// preflight still produces the clearer refusal before stage work begins.
  Future<
      ({
        bool ok,
        String? firstCertificate,
        SigningIdentity? identity,
        String? certificateSha256,
      })> _signingCertificate(
    ResolvedUnit unit,
    String? publishedRequirement,
  ) async {
    final signer = MacOsSigner(tools: tools);
    final certificates = await signer.availableIdentities();
    Diagnostic? refusal;

    if (certificates == null) {
      refusal = Diagnostic(
        code: 'RK-SIGN-006',
        message: 'the login keychain could not be read',
        remedy: 'signing needs `security find-identity -v -p codesigning` to '
            'answer. This is not the same as having no certificate, and rk '
            'will not guess which it is.',
      );
    } else if (certificates.isEmpty) {
      refusal = Diagnostic(
        code: 'RK-SIGN-007',
        message: 'no Developer ID Application certificate is installed',
        remedy: 'a signed release needs one in the login keychain — it is '
            'the only certificate that distributes outside the App Store.',
      );
    } else if (publishedRequirement != null &&
        BinaryChain.teamOf(publishedRequirement) == null) {
      // The sign step also refuses this as RK-SIGN-001. The requirement is in
      // hand here, so the question "can rk tell which certificate reproduces
      // this?" is answerable before stage work begins and does not change by
      // waiting.
      refusal = Diagnostic(
        code: 'RK-SIGN-001',
        message: 'the published release names no team rk can read',
        remedy: 'its designated requirement carries no subject.OU, so rk '
            'cannot tell which certificate reproduces it.',
      );
    } else if (publishedRequirement != null &&
        BinaryChain.teamOf(publishedRequirement) != null &&
        certificates
            .where((c) => c.team == BinaryChain.teamOf(publishedRequirement))
            .isEmpty) {
      // The likeliest signing failure of all — a machine that has a
      // certificate, just not the one the published release names — and the
      // last one this preflight learned to catch. `MacOsSigner.sign` also
      // refuses it, but checking here avoids spending time producing a stage
      // whose signing identity can never match the published baseline.
      refusal = Diagnostic(
        code: 'RK-SIGN-010',
        message: 'no certificate for the team the published release names',
        remedy: 'users installed a binary signed by team '
            '${BinaryChain.teamOf(publishedRequirement)}; this machine has '
            '${certificates.map((c) => c.team).join(', ')}. Signing with a '
            'different team ships what macOS treats as a new program.',
      );
    } else if (publishedRequirement != null &&
        certificates
                .where(
                    (c) => c.team == BinaryChain.teamOf(publishedRequirement))
                .length >
            1) {
      refusal = Diagnostic(
        code: 'RK-SIGN-011',
        message: 'several certificates for team '
            '${BinaryChain.teamOf(publishedRequirement)}, and rk will not '
            'guess which one distributes this',
        remedy: 'leave one Developer ID Application certificate for that '
            'team in the login keychain.',
      );
    } else if (publishedRequirement == null && certificates.length > 1) {
      // With a published requirement the team is derived from it and the
      // sign step picks by that, so several certificates are fine. Without
      // one, nothing says which of them distributes this — and the first
      // signing is what makes the answer permanent.
      refusal = Diagnostic(
        code: 'RK-SIGN-008',
        message: 'this machine has ${certificates.length} Developer ID '
            'certificates and nothing published says which distributes this',
        remedy: 'release once from a machine with one '
            '(${certificates.map((c) => c.team).join(', ')}), and every '
            'release after derives it from what users installed.',
      );
    }

    if (refusal != null) {
      output.problem(refusal, unit: unit.name);
      output.halt(HaltKind.beforeActing);
      return (
        ok: false,
        firstCertificate: null,
        identity: null,
        certificateSha256: null,
      );
    }
    final selected = publishedRequirement == null
        ? certificates!.single
        : certificates!.singleWhere(
            (certificate) =>
                certificate.team == BinaryChain.teamOf(publishedRequirement),
          );
    final fingerprint = await signer.certificateSha256(selected);
    if (fingerprint == null) {
      output.problem(
        Diagnostic(
          code: 'RK-SIGN-012',
          message: 'the selected signing certificate fingerprint could not '
              'be read',
          remedy: '`security find-certificate -a -c '
              '"${selected.name}" -Z` must report the SHA-256 and SHA-1 '
              'hashes for the exact identity selected by '
              '`security find-identity`.',
        ),
        unit: unit.name,
      );
      output.halt(HaltKind.beforeActing);
      return (
        ok: false,
        firstCertificate: null,
        identity: null,
        certificateSha256: null,
      );
    }
    return (
      ok: true,
      firstCertificate: publishedRequirement == null ? selected.name : null,
      identity: selected,
      certificateSha256: fingerprint,
    );
  }

  /// The operator's presence and typed confirmation are the authorization for
  /// a local release. Where a tag already exists, its signature is.
  Future<bool> _authorize(
    ResolvedUnit unit,
    List<Step> remaining, {
    required String? firstCertificate,
    required String? codeId,
    required List<String> claims,
  }) async {
    final permanent = remaining.where((s) => s.isPermanent).toList();

    output.blank();
    if (permanent.isEmpty) {
      output.say('nothing here is permanent.');
    } else {
      // The ground, marked where it matters: everything before the yes is
      // resumable; the first permanent step after it is not.
      output.say('pub.dev never deletes a version. a version can be '
          'retracted, which hides it and removes nothing.\n'
          'everything before this yes re-runs safely. after it, the first '
          'permanent step is: ${permanent.first.summary}.');
    }

    _sayClaims(claims, firstCertificate, codeId);

    // Weaker assurance is accepted knowingly or not at all: a platform
    // nothing here can run ships with its smoke test missing, and that is
    // said before the version is typed, not discovered afterwards.
    final unprovable = _unprovable(unit);
    if (unprovable.isNotEmpty) {
      output.blank();
      output.say('these ship built but never executed — rk cannot prove '
          'they run or report ${unit.version}:');
      for (final platform in unprovable) {
        output.say(platform, depth: 1);
      }
    }

    if (!_requireAuthorizer(unit)) return false;

    final typed = await confirm!(
      'type ${unit.version} to release, or anything else to stop: ',
    );
    if (typed?.trim() != unit.version.canonical) {
      output.blank();
      output.say(typed == null
          ? 'no terminal to answer on — stopped; nothing was published. '
              'A release is authorized at a terminal.'
          : 'stopped. nothing was published.');
      return false;
    }
    return true;
  }

  bool _requireAuthorizer(ResolvedUnit unit) {
    if (confirm != null) return true;
    output.problem(
      Diagnostic(
        code: 'RK-AUTH-001',
        message: 'nobody is here to authorize this release',
        remedy: 'a release from a terminal is authorized by the operator '
            'confirming it. Unattended, rk needs a signed tag instead — '
            'and verifying one is on the ledger, so today unattended '
            'means refused.',
      ),
      unit: unit.name,
    );
    output.halt(HaltKind.beforeActing);
    return false;
  }

  Future<_ActOutcome> _act(
    Step step,
    ResolvedUnit unit,
    String? publishedRequirement,
    String? codeId,
    String? notesPath, {
    SigningIdentity? signingIdentity,
    String? certificateSha256,
    Inspection? inspectedTarget,
  }) async {
    switch (step.kind) {
      case StepKind.tag:
        return _tag(unit);
      case StepKind.publishRegistry:
        return _publish(step, unit);
      case StepKind.prerequisite:
        return const _ActOutcome.succeeded(); // inspected, never performed
      case StepKind.build:
        return _ActOutcome.producer(
          await _chain(unit).buildStep(
            step,
            unit.binaryProject,
            publishedRequirement: publishedRequirement,
          ),
        );
      case StepKind.sign:
        return _ActOutcome.producer(
          await _chain(unit).signStep(
            step,
            unit.binaryProject,
            publishedRequirement: publishedRequirement,
            codeId: codeId!,
            signingIdentity: signingIdentity,
            certificateSha256: certificateSha256,
          ),
        );
      case StepKind.notarize:
        return _ActOutcome.producer(
          await _chain(unit).notarizeStep(step, unit.binaryProject),
        );
      case StepKind.archive:
        return _ActOutcome.producer(
          await _chain(unit).archiveStep(step, unit.binaryProject),
        );
      case StepKind.checksums:
        return _ActOutcome.producer(
          await _chain(unit).checksumsStep(step, unit.binaryProject),
        );
      case StepKind.completeStage:
        return const _ActOutcome.succeeded();
      case StepKind.publishRelease:
        return _publishRelease(unit, _chain(unit), notesPath);
      case StepKind.publishFormula:
        final authority = inspectedTarget?.authority;
        if (authority is! HomebrewUpdateAuthority) {
          return _ActOutcome.homebrew(TapOutcome.failed(
            'the formula update has no exact public base; re-run so rk can '
            'inspect the tap before updating it',
          ));
        }
        return _publishFormula(unit, _chain(unit), authority);
    }
  }

  BinaryChain _chain(ResolvedUnit unit) => _chains.putIfAbsent(unit.name, () {
        final stage = _stageFor(unit);
        return BinaryChain(
          tools: tools,
          output: output,
          workspace: stage.directory.workspace,
          repositoryRoot: stage.sourceRoot,
          capabilities: capabilities,
          compilerExecutable: stage.compiler?.executable ?? 'dart',
        );
      });

  /// The designated requirement of the newest already-published release,
  /// which is what this release's signature must reproduce.
  ///
  /// Derived, not declared: the complete public release history is searched
  /// newest-to-oldest for the latest release that actually shipped a macOS
  /// binary. That binary is the only authority on what identity this program
  /// has. `none` — no earlier signed release — is a null requirement with
  /// `ok`, and the sign step falls back to the unit's declared `code_id`.
  /// `unreadable` refuses the whole run before anything public acts. Not
  /// knowing the baseline is not permission to ship a new one.
  Future<({bool ok, String? requirement})> _signingBaseline(
    ResolvedUnit unit,
  ) async {
    final repository = git.originUrl;
    if (repository == null) return (ok: true, requirement: null);

    final published = PublishedIdentity(
      tools: tools,
      repository: repository,
      workingDirectory: git.root,
    );
    final history = await published.priorReleaseTags(
      tagPattern: unit.tagPattern,
      before: unit.version,
    );
    if (!history.readable) {
      output.problem(
        Diagnostic(
          code: 'RK-SIGN-004',
          message: 'the identity users already installed could not be read',
          remedy: '${history.why}\n'
              'rk must read the complete public release history before it '
              'can decide this is the first signed release.',
        ),
        unit: unit.name,
      );
      output.halt(HaltKind.beforeActing);
      return (ok: false, requirement: null);
    }

    for (final tag in history.tags!) {
      final scratch = Directory.systemTemp.createTempSync('rk-identity-');
      final reading = await published.read(
        tag: tag,
        executable: unit.binaryProject.executable!,
        into: '${scratch.path}/published-identity',
        expectedPublished: true,
      );
      try {
        scratch.deleteSync(recursive: true);
      } on FileSystemException {
        // The published identity answer does not depend on scratch cleanup.
      }
      switch (reading.answer) {
        case IdentityAnswer.found:
          return (ok: true, requirement: reading.requirement);
        case IdentityAnswer.none:
          // A public source-only release is not a signing baseline. Continue
          // until the newest release that actually shipped a macOS binary.
          continue;
        case IdentityAnswer.unreadable:
          output.problem(
            Diagnostic(
              code: 'RK-SIGN-004',
              message: 'the identity users already installed could not be read',
              remedy: '${reading.why}\n'
                  'rk found a published signing candidate at $tag; until '
                  'that release can be read, a new signature cannot be '
                  'proven continuous with it.',
            ),
            unit: unit.name,
          );
          output.halt(HaltKind.beforeActing);
          return (ok: false, requirement: null);
      }
    }
    return (ok: true, requirement: null); // first signed release
  }

  Future<_ActOutcome> _publishRelease(
    ResolvedUnit unit,
    BinaryChain chain,
    String? notesPath,
  ) async {
    final repository = _repository('github-release');
    if (repository == null) return const _ActOutcome.reportedFailure();

    final project = unit.binaryProject;
    final assets = chain.gatherAssets(project, unit.name);
    if (assets == null) return const _ActOutcome.reportedFailure();

    // The body was read and written in preflight — the last refusable
    // input, resolved before the first act.
    if (notesPath == null) {
      output.problem(
        Diagnostic(
          code: 'RK-CHG-003',
          message: 'the release body was not prepared',
          remedy: 'this is a bug in rk: the preflight prepares it whenever '
              'a github-release step remains',
        ),
      );
      return const _ActOutcome.reportedFailure();
    }

    final outcome = await chain.publishRelease(
      repository: repository,
      tag: unit.tag,
      title: '${project.name} ${unit.version}',
      notesPath: notesPath,
      assets: assets,
    );
    return _ActOutcome.github(outcome);
  }

  /// Every name this release takes for good, in one block.
  ///
  /// One line per registrar, each with its own notion of permanence, the
  /// name on its own line and the consequence indented under it — a reader
  /// who skims still sees the name, which is the thing a typo gets wrong.
  ///
  /// The macOS half was a separate sentence, gated on
  /// `shipsBinaries && permanent.isNotEmpty && certificates.length == 1`.
  /// None of those three is first-ness: `isPermanent` is `publishRegistry`
  /// alone, so it meant "a pub.dev publish remains" — true of every release
  /// of a pub.dev unit. It therefore announced a first signing on every
  /// later release from a one-certificate machine, and stayed silent on a
  /// genuine first release of a binaries-only unit, which has nothing
  /// permanent in it at all. `publishedRequirement == null` is the fact, and
  /// it is what `firstCertificate` carries.
  void _sayClaims(
    List<String> claims,
    String? firstCertificate,
    String? codeId,
  ) {
    final firstOf = <String>[
      for (final name in claims)
        'pub.dev          $name\n'
            '                 permanent: a package name cannot be renamed, '
            'reassigned,\n'
            '                 or released back',
      if (firstCertificate != null)
        'macOS identity   $codeId\n'
            '                 permanent: sealed into the designated '
            'requirement, and into\n'
            '                 every Keychain item this program creates. '
            'Signed by\n'
            '                 $firstCertificate',
    ];
    if (firstOf.isEmpty) return;
    output.blank();
    output.say('this release claims, for the first time:');
    for (final line in firstOf) {
      output.say(line, depth: 1);
    }
  }

  /// A conventional identifier to *suggest*, never to use.
  ///
  /// `io.github.<owner>.<command>` is what a human usually picks for
  /// GitHub-hosted software with no domain, and rk offers it in RK-SIGN-009's
  /// remedy as text to read and edit. It is deliberately not a fallback: the
  /// rule reproduces rk's own declared identifier exactly, and misses
  /// keybay's — where the `.cli` suffix was chosen so one signed program in a
  /// two-unit repository would not claim the bare product name. A rule that
  /// reproduces the less considered choice and misses the more considered one
  /// is a suggestion, not a derivation. Two real packages by one owner that
  /// both declare `executables: cli` collide under it outright.
  String _conventionalCodeId(ResolvedUnit unit) {
    final executable = unit.binaryProject.executable ?? unit.name;
    final owner = git.originUrl?.split('/').first.toLowerCase();
    return owner == null || owner.isEmpty
        ? executable
        : 'io.github.$owner.$executable';
  }

  /// Whether the unit's declared `code_id` agrees with the published
  /// requirement, recording the refusal when it does not.
  ///
  /// Derivation wins when nothing is declared; a declaration that
  /// *contradicts* what users already installed is either a typo or an
  /// identity migration, and both deserve a refusal naming the two values
  /// rather than a signature mismatch after the tag is public.
  bool _declarationAgrees(ResolvedUnit unit, String publishedRequirement) {
    final declared = unit.codeId;
    if (declared == null) return true;
    final published = BinaryChain.identifierOf(publishedRequirement);
    if (published == null || declared == published) return true;

    output.problem(
      Diagnostic(
        code: 'RK-SIGN-005',
        message: 'code_id disagrees with the release users already installed',
        remedy: 'the identity is derived from the published binary; the '
            'declaration only fills what no release states yet.\n'
            'declared $declared, published $published\n'
            'A deliberate identity change is a migration rk does not '
            'automate, because it ships what macOS treats as a new program.',
      ),
      unit: unit.name,
    );
    output.halt(HaltKind.beforeActing);
    return false;
  }

  /// The changelog entry for this version, or null with a recorded problem.
  ///
  /// Validation already proved the heading exists; extraction failing after
  /// that is unexpected, and saying so beats publishing with a body that
  /// silently fell back to something else.
  String? _releaseNotes(
    ResolvedProject project, {
    SourceTree? source,
  }) {
    final path = project.fileAt('CHANGELOG.md');
    final contents = (source ?? tree).read(path);
    final entry =
        contents == null ? null : Changelog.entry(contents, project.version);
    if (entry != null && entry.isEmpty) {
      // The heading exists — validation passed — and there is nothing under
      // it. For the verb whose release body *is* this entry, publishing an
      // empty one silently would be prose nobody wrote shipping as if
      // someone had.
      output.problem(
        Diagnostic(
          code: 'RK-CHG-004',
          message: 'the changelog entry for ${project.version} is empty',
          source: SourceLocation(path, 1),
          remedy: 'the release body is this entry — write what changed '
              'under the ${project.version} heading',
        ),
      );
      output.halt(HaltKind.beforeActing);
      return null;
    }
    if (entry == null) {
      output.problem(
        Diagnostic(
          code: 'RK-CHG-003',
          message: 'the changelog entry for ${project.version} could not be '
              'extracted',
          source: SourceLocation(path, 1),
          remedy: 'validation saw a heading for it; the file changed since, '
              'or this is a bug in rk',
        ),
      );
      output.halt(HaltKind.beforeActing);
      return null;
    }
    return entry;
  }

  Future<_ActOutcome> _publishFormula(
    ResolvedUnit unit,
    BinaryChain chain,
    HomebrewUpdateAuthority authority,
  ) async {
    final repository = _repository('homebrew');
    if (repository == null) return const _ActOutcome.reportedFailure();

    final tap = unit.tapFor(repository);

    final outcome = await chain.updateFormula(
      tap: tap,
      project: unit.binaryProject,
      authority: authority,
    );
    return _ActOutcome.homebrew(outcome);
  }

  /// The `owner/name` this repository pushes to.
  /// The `owner/name` this repository pushes to, or null with the refusal
  /// recorded.
  ///
  /// A problem, not a bare line: `Output.line` writes only to the sink, so a
  /// run stopped here handed a --json caller an empty problems array — the
  /// same invisibility the formula step's RK-BREW-001 was built to end.
  /// [step] names the destination that wanted it, because the message was
  /// hardcoded to github-release while the tap step calls this too.
  String? _repository(String step) {
    final remote = git.originUrl;
    if (remote == null) {
      output.problem(
        Diagnostic(
          code: 'RK-GIT-002',
          message: '$step needs an origin remote, and this repository has none',
          remedy: 'rk publishes what others can fetch, and reads back what it '
              'published. git remote add origin <url>, then git push -u '
              'origin ${git.branch ?? 'main'}',
        ),
      );
      output.halt(HaltKind.beforeActing);
      return null;
    }
    return remote;
  }

  /// The tag destination, spoken to through git.
  GitTag get _tags => GitTag(tools: tools, root: git.root);

  /// Creates and pushes the tag that records this release.
  ///
  /// A record written after the operator authorized, not the authorization
  /// itself — which is why rk may write it here and never may where a tag is
  /// what authorizes.
  Future<_ActOutcome> _tag(ResolvedUnit unit) async {
    final signed = git.signingConfigured;

    // The step can be half-done: a push that died leaves a local tag, which
    // the inspection now reports as absent-with-work ("not on origin"). The
    // act then pushes what exists rather than failing to re-create it.
    if (git.hasTag(unit.tag)) {
      output.say('the tag exists locally; pushing it', depth: 1);
      return _pushTag(unit, signed: signed, preExisting: true);
    }

    final created = await _tags.create(
      unit.tag,
      signed: signed,
      message: _tagMessage(unit),
    );
    if (!created.ok) {
      return _ActOutcome._(
        ok: false,
        coordinate: unit.tag,
        diagnostic: Diagnostic(
          code: 'RK-TAG-001',
          message: 'the tag ${unit.tag} could not be created',
          remedy: created.summary,
        ),
        reconciledNote: 'tag creation response was lost · origin confirmed '
            'the exact release tag',
      );
    }

    final pushed = await _tags.push(unit.tag);
    if (!pushed.ok) {
      // The shared destination read decides whether this ambiguous response
      // landed. If it proves absence, the reporting layer removes only the
      // local tag this run created; unknown preserves it for a safe re-run.
      return _ActOutcome._(
        ok: false,
        coordinate: unit.tag,
        mayHaveActed: true,
        removeLocalTagIfAbsent: unit.tag,
        diagnostic: Diagnostic(
          code: 'RK-TAG-002',
          message: 'the tag ${unit.tag} could not be pushed',
          remedy: '${pushed.summary}\norigin will be read before this result '
              'is classified; a re-run inspects before pushing again',
        ),
        reconciledNote: 'push response was lost · origin confirmed exact',
      );
    }
    return _ActOutcome._(
      ok: true,
      coordinate: unit.tag,
      mayHaveActed: true,
      successNote: [if (signed) 'signed' else 'unsigned', 'pushed'].join(', '),
    );
  }

  String _tagMessage(ResolvedUnit unit) {
    final digest = _manifestDigest(unit);
    return '${unit.name} ${unit.version}\n\n'
        'release-manifest-sha256: $digest';
  }

  String _manifestDigest(ResolvedUnit unit) {
    final manifest = File(
      _stageFor(unit).directory.resolve(ReleaseAssets.manifest),
    );
    if (!manifest.existsSync()) {
      throw StateError('the completed stage has no release manifest');
    }
    return Sha256.hex(manifest.readAsBytesSync());
  }

  Future<_ActOutcome> _pushTag(
    ResolvedUnit unit, {
    required bool signed,
    required bool preExisting,
  }) async {
    final pushed = await _tags.push(unit.tag);
    if (!pushed.ok) {
      return _ActOutcome._(
        ok: false,
        coordinate: unit.tag,
        mayHaveActed: true,
        diagnostic: Diagnostic(
          code: 'RK-TAG-002',
          message: 'the tag ${unit.tag} could not be pushed',
          remedy: '${pushed.summary}\nthe tag pre-existed this run, so it '
              'was left in place — re-running pushes it again',
        ),
        reconciledNote: 'push response was lost · origin confirmed exact',
      );
    }
    return _ActOutcome._(
      ok: true,
      coordinate: unit.tag,
      mayHaveActed: true,
      successNote: [
        if (signed) 'signed' else 'unsigned',
        'pushed',
        if (preExisting) 'pre-existing local tag',
      ].join(', '),
    );
  }

  Future<_ActOutcome> _publish(Step step, ResolvedUnit unit) async {
    final project = unit.projects.firstWhere((p) => p.name == step.project);
    final sourceRoot = _stageFor(unit).sourceRoot;
    final directory = project.pubspec.directory == '.'
        ? sourceRoot
        : '$sourceRoot/${project.pubspec.directory}';

    // Validation and the consumer resolve already ran, pre-act, in the
    // preflight — a refusal there costs nothing public.
    final code = await tools.runInteractive(
      'dart',
      const ['pub', 'publish', '--force'],
      workingDirectory: directory,
    );
    if (code != 0) {
      // A non-zero client exit is ambiguous. Do not inspect or halt here: the
      // release loop owns the one exact public read that can reconcile an
      // accepted upload whose MFA/network response was lost.
      registry.forget(project.name);
      return _ActOutcome._(
        ok: false,
        coordinate: '${project.name} ${project.version}',
        mayHaveActed: true,
        diagnostic: Diagnostic(
          code: 'RK-PUB-003',
          message: '${project.name}: dart pub publish did not complete',
          remedy: 'fix what dart pub reported and re-run. The login preflight '
              'confirms a current session, not uploader permission for this '
              'package; if the upload may have landed, re-running inspects '
              'public truth before acting',
        ),
        reconciledNote:
            'publish response was lost · public archive confirmed exact',
      );
    }

    // The release loop now owns the bounded exact-read polling. Invalidate the
    // provider cache before handing it that outcome; the publisher has made
    // everything this process knew about the coordinate stale.
    registry.forget(project.name);
    return _ActOutcome._(
      ok: true,
      coordinate: '${project.name} ${project.version}',
      mayHaveActed: true,
      successNote: 'published',
      includeInspectionDetail: true,
    );
  }

  /// Establishes the native pub.dev session before private production begins.
  ///
  /// This is intentionally neither a checklist step nor stage evidence. A
  /// session is ambient and expiring, and a successful login says nothing
  /// about whether this account may publish a particular package. The real
  /// publish and its exact read-back remain authoritative.
  Future<bool> _preflightPubSession(
    ResolvedUnit unit,
    Iterable<Step> remaining,
  ) async {
    if (!remaining.any((step) => step.kind == StepKind.publishRegistry)) {
      return true;
    }

    int code;
    try {
      code = await tools.runInteractive(
        'dart',
        const ['pub', 'login'],
        workingDirectory: git.root,
      );
    } on ProcessException {
      code = -1;
    }
    if (code == 0) return true;

    output.problem(
      Diagnostic(
        code: 'RK-PUB-007',
        message: 'dart pub login did not complete',
        remedy: 'Run dart pub login from a terminal, then re-run rk release '
            '${unit.name}. A successful login confirms a current session, '
            'not permission to publish every package.',
      ),
      unit: unit.name,
    );
    output.halt(HaltKind.beforeActing);
    return false;
  }

  /// pub's validation and the consumer resolve, both read-only.
  ///
  /// The gate matches what the act will do. `dart pub publish --dry-run`
  /// exits non-zero for warnings and for errors alike, while `--force` — the
  /// actual act — publishes past warnings and refuses errors. Gating on the
  /// exit code alone made rk stricter than the registry it publishes to:
  /// keybay's deliberate, test-enforced exact pins are "warnings", pub.dev
  /// accepted them at 0.1.0, and rk would have refused the release — after
  /// pushing the tag. Warnings are printed, so the operator confirms the
  /// permanent act having seen them; errors block; a summary rk cannot
  /// classify blocks, because fail-closed is for the unrecognised.
  Future<bool> _publishPreflight(
    ResolvedProject project,
    String sourceRoot,
  ) async {
    final directory = project.pubspec.directory == '.'
        ? sourceRoot
        : '$sourceRoot/${project.pubspec.directory}';

    final dry = await tools.run(
      'dart',
      const ['pub', 'publish', '--dry-run'],
      workingDirectory: directory,
    );
    final validation = '${dry.stdout}\n${dry.stderr}'.trim();
    output.report.attach('pub-dry-run-${project.name}.txt', validation);

    if (!dry.ok) {
      final summary = RegExp(r'Package has[^\n]*')
          .allMatches(validation)
          .map((m) => m.group(0)!)
          .lastOrNull;
      final warningsOnly = summary != null &&
          !summary.toLowerCase().contains('error') &&
          summary.toLowerCase().contains('warning');
      if (!warningsOnly) {
        output.problem(
          Diagnostic(
            code: 'RK-PUB-001',
            message: 'pub refuses to publish ${project.name}',
            remedy: validation.isEmpty ? dry.summary : validation,
          ),
          unit: project.unitName,
        );
        output.halt(HaltKind.beforeActing);
        return false;
      }
      // The same warnings pub's interactive publish would have shown, shown —
      // the operator confirms the permanent act having seen them.
      output.say('pub warns, and --force will publish past these:', depth: 1);
      for (final line in validation.split('\n')) {
        if (line.trimLeft().startsWith('*')) output.say(line.trim(), depth: 2);
      }
    }

    return _consumerResolve(project, directory);
  }

  /// Resolution as every consumer will see it. False halts the step.
  Future<bool> _consumerResolve(
    ResolvedProject project,
    String directory,
  ) async {
    final probe = Directory.systemTemp.createTempSync('rk-consumer-');
    try {
      File('${probe.path}/pubspec.yaml').writeAsStringSync('''
name: rk_consumer_probe
publish_to: none
environment:
  sdk: '>=3.0.0 <4.0.0'
dependencies:
  ${project.name}: ${project.version}
dependency_overrides:
  ${project.name}:
    path: ${directory.replaceAll('\\', '/')}
''');
      final resolved = await tools.run(
        'dart',
        const ['pub', 'get', '--no-precompile'],
        workingDirectory: probe.path,
      );
      if (!resolved.ok) {
        output.problem(
          Diagnostic(
            code: 'RK-PUB-002',
            message: '${project.name}: consumers could not resolve this',
            remedy: '${resolved.summary}\n'
                'the probe resolves as a Dart consumer on this SDK; a '
                'package needing Flutter or a newer SDK than the probe '
                'models is a limit rk has not lifted yet — see the ledger',
          ),
          unit: project.unitName,
        );
        output.halt(HaltKind.beforeActing);
        return false;
      }
      return true;
    } finally {
      probe.deleteSync(recursive: true);
    }
  }
}

enum _ReleaseAction {
  notAttempted('not_attempted', 'not attempted'),
  attempted('attempted', 'attempted; result unknown'),
  alreadyExact('already_exact', 'already exact'),
  completed('completed', 'completed'),
  failed('failed', 'failed');

  const _ReleaseAction(this.wire, this.human);

  final String wire;
  final String human;
}

class _ActOutcome {
  const _ActOutcome._({
    required this.ok,
    this.problem,
    this.mayHaveActed = false,
    this.draftEffect = DraftEffect.none,
    this.terminal = false,
    this.permanent,
    this.failureAlreadyReported = false,
    this.diagnostic,
    this.coordinate,
    this.removeLocalTagIfAbsent,
    this.successNote,
    this.includeInspectionDetail = false,
    this.reconciledNote,
    this.producer,
  });

  const _ActOutcome.succeeded() : this._(ok: true);

  const _ActOutcome.reportedFailure()
      : this._(ok: false, failureAlreadyReported: true);

  factory _ActOutcome.producer(LocalProducerOutcome outcome) => _ActOutcome._(
        ok: outcome.ok,
        problem: outcome.problem,
        failureAlreadyReported: !outcome.ok,
        producer: outcome,
      );

  factory _ActOutcome.github(PublishOutcome outcome) => _ActOutcome._(
        ok: outcome.ok,
        problem: outcome.problem,
        mayHaveActed: outcome.mayHaveActed,
        draftEffect: outcome.draftEffect,
        terminal: outcome.isTerminal,
        permanent: outcome.permanent,
      );

  factory _ActOutcome.homebrew(TapOutcome outcome) => _ActOutcome._(
        ok: outcome.ok,
        problem: outcome.problem,
        mayHaveActed: outcome.mayHaveActed,
      );

  final bool ok;
  final String? problem;
  final bool mayHaveActed;
  final DraftEffect draftEffect;
  final bool terminal;
  final String? permanent;
  final bool failureAlreadyReported;
  final Diagnostic? diagnostic;
  final String? coordinate;
  final String? removeLocalTagIfAbsent;
  final String? successNote;
  final bool includeInspectionDetail;
  final String? reconciledNote;
  final LocalProducerOutcome? producer;
}

class _PreparedStage {
  const _PreparedStage({
    required this.claims,
    this.publishedRequirement,
    this.firstCertificate,
    this.codeId,
    this.notesPath,
  });

  final List<String> claims;
  final String? publishedRequirement;
  final String? firstCertificate;
  final String? codeId;
  final String? notesPath;
}
