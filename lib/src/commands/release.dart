import 'dart:io';

import '../builds/capability.dart';
import '../engine/changelog.dart';
import '../engine/checklist.dart';
import '../engine/assets.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../output/output.dart';
import '../engine/inspect.dart';
import '../engine/producers.dart';
import '../engine/resolve.dart';
import '../engine/release_stage.dart';
import '../engine/source_tree.dart';
import '../engine/stage_inspection.dart';
import '../engine/stage_board.dart';
import '../engine/stage_contract.dart';
import '../engine/stage_receipt.dart';
import '../engine/targets.dart';
import '../engine/tools.dart';
import '../engine/identity.dart';
import '../engine/verdict.dart';
import '../targets/target_module.dart';
import '../transforms/macos.dart';
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
    required this.inspector,
    required this.tools,
    required this.output,
    required this.confirm,
    this.preauthorized,
    this.stageOnly = false,
    ReleaseStage Function(ResolvedUnit unit)? stageFor,
    ReleaseStage Function(ResolvedUnit unit, GitState git)? refreshStage,
    GitState Function()? refreshGit,
    Future<void> Function(Duration)? wait,
    HostCapabilities? capabilities,
  })  : _wait = wait ?? _sleep,
        _stageFor = stageFor ??
            ReleaseStages(
              source: tree,
              git: git,
              stageContracts:
                  inspector.targets.stageContractResolver(resolution),
            ).call,
        _refreshStage = refreshStage ??
            ((unit, currentGit) => ReleaseStages(
                  source: tree,
                  git: currentGit,
                  stageContracts:
                      inspector.targets.stageContractResolver(resolution),
                ).call(unit)),
        _refreshGit = refreshGit ?? (() => git),
        _capabilities = capabilities;

  static Future<void> _sleep(Duration duration) =>
      Future<void>.delayed(duration);

  final Resolution resolution;
  final SourceTree tree;
  final GitState git;

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

  /// The exact version a noninteractive caller pre-authorized
  /// (`--confirm=<version>`), or null when authorization happens at the
  /// prompt. Checked before any native session or producer runs: a value
  /// that cannot authorize this release must not spend credentials or
  /// contact Apple on the way to refusing.
  final String? preauthorized;

  Future<int> run({String? only}) async {
    if (only != null) {
      final named = resolution.units.where((u) => u.name == only).toList();
      if (named.isEmpty) {
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
      return _release(named.single);
    }

    // A unit is what ships together — several packages under one tag and one
    // version — so a repository that defines one has nothing to
    // disambiguate, and naming it is ceremony `rk status` never asked for.
    // Two units are two releases, each with its own tag, version, and typed
    // authorization; rk will not perform both from one word.
    if (resolution.units.length == 1) return _release(resolution.units.single);

    // A repository with no unit at all never reaches here: resolution
    // refuses it as RK-CONF-004, with an example of the table to add.
    output.problem(
      Diagnostic(
        code: 'RK-CLI-004',
        message: 'name the unit to release',
        remedy: 'each unit is its own release, with its own tag and version. '
            'rk release <unit> releases one of: '
            '${resolution.units.map((u) => u.name).join(', ')}',
      ),
    );
    return ExitCodes.usage;
  }

  Future<int> _release(ResolvedUnit unit) async {
    // The machine surface carries the same identity facts on every verb:
    // doc/json.md promises repository and the unit's version and tag, and
    // the production-alpha retry checkpoint reads both from this document.
    output.report.repository(
      name: tree.description.split('/').last,
      branch: git.branch,
      uncommitted: git.uncommitted.length,
      head: git.head,
      remote: git.originUrl,
    );
    output.report.unit(
      name: unit.name,
      version: unit.version.canonical,
      tag: unit.tag,
    );

    if (preauthorized != null && preauthorized != unit.version.canonical) {
      output.problem(
        Diagnostic(
          code: 'RK-AUTH-002',
          message: 'the authorization does not name this release',
          remedy: '--confirm=$preauthorized cannot authorize '
              '${unit.version}. Authorize exactly this release: '
              '--confirm=${unit.version}',
        ),
        unit: unit.name,
      );
      output.halt(HaltKind.beforeActing);
      return ExitCodes.refused;
    }

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
    final targets = inspector.targets.derive(
      unit,
      checklist,
      repository: inspector.repository,
    );
    final targetByStep = {
      for (final target in targets) target.step.id: target,
    };

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
      final target = targetByStep[step.id];
      return !(stageInspection.reusable == false &&
          state.verdict == Verdict.unknown &&
          target != null &&
          target.exactComparisonNeedsStage);
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
      final preflight = TargetPreflightContext(
        tools: tools,
        output: output,
        git: git,
      );
      final preflighted = <StepKind>{};
      for (final target in targets) {
        if (!states[target.step.id]!.isAbsent) continue;
        final module = inspector.targets.moduleForTarget(target);
        if (!preflighted.add(target.step.kind)) continue;
        if (!await module.preflight(preflight, unit)) {
          _showReleaseActions(targets, publicActions);
          return ExitCodes.refused;
        }
      }
    }

    // `›` is version movement. The groups below already say where these
    // are going, and the arrow had started meaning two things.
    output.heading('${unit.name} ${unit.version} · '
        '${stageOnly ? 'staging' : 'releasing'}');
    output.blank();

    final prepared = await _prepareStage(
      unit,
      checklist,
      targets,
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

    output.line('${unit.name} ${unit.version} staged', mark: Mark.done);
    _renderBoard(
      StageBoard.forUnit(unit, targets),
      progressOf: prepared.receiptSteps,
    );

    if (stageOnly) {
      output.blank();
      output.line(
        'Written to',
        note: stage.directory.path,
        depth: 1,
        labelWidth: 12,
        noteTone: Tone.muted,
      );
      _sayStageClaims(
        prepared.claims,
        prepared.firstCertificate,
        prepared.codeId,
        settled: false,
      );
      // The next command is data for whoever is driving; the operator who
      // just staged does not need to be told what staging is for.
      output.report.next('rk release ${unit.name}');
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

    if (checklist.steps.any((step) =>
        step.kind == StepKind.build && step.platform!.startsWith('macos-'))) {
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
      [for (final step in remaining) targetByStep[step.id]!],
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
      final module = inspector.targets.moduleForTarget(target);
      final currentVersion = Diagnostics();
      final readIndependentHistory = await inspector.releaseMonotonicity(
        unit,
        [target],
        currentVersion,
        refreshRegistry: true,
      );
      if (currentVersion.isNotEmpty) {
        output.halt(
          output.report.acted ? HaltKind.stoppedPartway : HaltKind.beforeActing,
        );
        output.problems(currentVersion.found);
        _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }

      if (readIndependentHistory) {
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
      final releaseContext = TargetReleaseContext(
        reads: inspector.targetReads,
        tools: tools,
        output: output,
        stage: stage,
        wait: _wait,
        confirmDeadline: confirmDeadline,
        confirmInterval: confirmInterval,
      );
      final act = await module.act(releaseContext, unit, target, state);
      // An act's process result is not public truth. A registry can accept an
      // upload before the client loses its response; Git can finish a push
      // before the connection drops; GitHub can apply the final draft PATCH
      // before `gh` exits non-zero. Always run the same destination inspection
      // status uses before deciding what the command result means.
      state = await module.settleAfterAct(releaseContext, unit, target);
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
          final failure = await module.classifyFailure(
            releaseContext,
            unit,
            target,
            state,
            act,
            actedBefore: actedBefore,
          );
          _reportTargetFailure(step, failure);
        } else if (!output.report.halted) {
          output.halt(
            actedBefore ? HaltKind.stoppedPartway : HaltKind.beforeActing,
          );
        }
        _showReleaseActions(targets, publicActions);
        return ExitCodes.refused;
      }
      if (!state.isExact) {
        final failure = await module.classifyFailure(
          releaseContext,
          unit,
          target,
          state,
          act,
          actedBefore: actedBefore,
        );
        _reportTargetFailure(step, failure);
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
    for (final target in targets) {
      final module = inspector.targets.moduleForTarget(target);
      for (final line in module.completionLines(unit, target)) {
        output.say(line, depth: 1);
      }
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

  void _reportTargetFailure(Step step, TargetFailure failure) {
    output.problem(failure.diagnostic, unit: step.unit);
    if (failure.nextCommand case final next?) output.next(next);
    output.halt(failure.halt);
    if (!failure.rerunHelps) output.report.rerunHelps = false;
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

  Future<_PreparedStage?> _prepareStage(
    ResolvedUnit unit,
    Checklist checklist,
    List<TargetExpectation> targets,
    ReleaseStage stage,
    StageInspection inspected,
  ) async {
    final claims = await _firstClaims(unit, targets);
    if (inspected.reusable) {
      final signing = inspected.receipt!.steps
          .where((step) => step.name.startsWith('build:macos-'))
          .firstOrNull
          ?.evidence;
      final signature = signing?['signature'];
      final signatureMap = signature is Map ? signature : const {};
      final firstIdentity = signatureMap['first_identity'] == true;
      return _PreparedStage(
        claims: claims,
        receiptSteps: inspected.receipt!.steps,
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

    final board = StageBoard.forUnit(unit, targets);

    final progress = <StageStep>[];
    late final List<StageArtifact> sourceArtifacts;
    late final StageStep sourceStep;
    if (inspected.validProgress) {
      progress.addAll(inspected.receipt!.steps);
      sourceStep = progress.first;
      sourceArtifacts = List<StageArtifact>.from(sourceStep.outputs);
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
    final targetStages = inspector.targets.stages(
      unit: unit,
      targets: targets,
    );
    Future<bool> prepareTargets(StageContributionPhase phase) async {
      for (final targetStage in targetStages.where(
        (item) => item.contract.phase == phase,
      )) {
        final target = targetStage.target;
        final receiptName = targetStage.contract.step.name;
        final row = board.rowFor(receiptName);
        if (progress.any((record) => record.name == receiptName)) {
          row?.finish();
          continue;
        }
        row?.begin('checking');
        final StageStep? result;
        try {
          result = await targetStage.prepare(
            TargetStageContext(
              contract: targetStage.contract,
              tools: tools,
              git: git,
              output: output,
              stage: stage,
              sourceStep: sourceStep,
              progress: progress,
            ),
          );
        } on Object catch (error) {
          row?.fail('did not complete');
          _stageOperationFailed('${target.label} stage preparation', error);
          return false;
        }
        if (result == null) {
          row?.fail('refused');
          return false;
        }
        progress.add(result);
        row?.finish(note: _contributionNote(result));
        try {
          _persistStageProgress(stage, sourceArtifacts, progress);
        } on Object catch (error) {
          _stageProgressFailed(error);
          return false;
        }
      }
      return true;
    }

    if (!await prepareTargets(StageContributionPhase.beforeArtifacts)) {
      return null;
    }

    String? publishedRequirement;
    String? firstCertificate;
    SigningIdentity? signingIdentity;
    String? certificateSha256;
    String? codeId;
    if (checklist.steps.any((step) =>
        step.kind == StepKind.build && step.platform!.startsWith('macos-'))) {
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

    final producerSteps = checklist.steps.where((step) {
      return !step.isPublic &&
          step.kind != StepKind.prerequisite &&
          step.kind != StepKind.completeStage;
    }).toList();
    for (final step in producerSteps) {
      final row = board.rowFor(receiptNameFor(step));
      final activity = output.begin(step, depth: 0);
      if (_producerRecorded(progress, step)) {
        output.step(
          step,
          verdict: Verdict.exact,
          detail: 'validated in the interrupted stage',
          show: false,
        );
        row?.finish();
        continue;
      }
      output.report.acted = true;
      row?.begin(_phaseOf(step));
      final LocalProducerOutcome act;
      try {
        act = await _actProducer(
          step,
          unit,
          publishedRequirement,
          codeId,
          signingIdentity: signingIdentity,
          certificateSha256: certificateSha256,
        );
      } on Object catch (error) {
        activity.failed('did not complete');
        row?.fail('did not complete');
        return _stageOperationFailed(step.summary, error);
      }
      if (!act.ok) {
        activity.failed(act.problem ?? 'did not complete');
        row?.fail(act.problem ?? 'did not complete');
        if (!output.report.halted) output.halt(HaltKind.stoppedPartway);
        return null;
      }
      row?.finish();
      try {
        progress.add(
            _captureProducerStep(stage, unit, step, sourceStep, progress, act));
        _persistStageProgress(stage, sourceArtifacts, progress);
      } on Object catch (error) {
        return _stageProgressFailed(error);
      }
    }

    if (!await prepareTargets(StageContributionPhase.afterArtifacts)) {
      return null;
    }

    try {
      final publicArtifacts = {
        for (final target in targets)
          for (final artifact in target.artifacts)
            if (artifact != ReleaseAssets.manifest) artifact,
      };
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
      verdict: Verdict.exact,
      detail: 'staged and validated',
      show: false,
    );
    board.rowFor('complete-stage')?.finish();
    return _PreparedStage(
      claims: claims,
      receiptSteps: List<StageStep>.unmodifiable(progress),
      publishedRequirement: publishedRequirement,
      firstCertificate: firstCertificate,
      codeId: codeId,
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

    // "Ever finalized" rather than "complete": a damaged receipt whose
    // complete-stage step is no longer terminal derives incomplete, and
    // silently rebuilding those reviewed bytes is exactly what this
    // refusal exists to prevent.
    final completedOrCorrupt =
        inspected.receipt?.steps.any((step) => step.name == 'complete-stage') ==
                true ||
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

  bool _producerRecorded(List<StageStep> progress, Step step) =>
      progress.any((record) => record.name == receiptNameFor(step));

  StageStep _captureProducerStep(
    ReleaseStage stage,
    ResolvedUnit unit,
    Step step,
    StageStep sourceStep,
    List<StageStep> progress,
    LocalProducerOutcome outcome,
  ) {
    final contract = contractFor(unit, step);
    final recorded = {
      for (final record in progress)
        for (final artifact in record.outputs) artifact.path: artifact,
    };
    return StageStep(
      name: contract.name,
      inputs: [
        for (final input in contract.inputs)
          input == 'step:source-snapshot'
              ? StageInput.step(sourceStep)
              : StageInput.artifact(recorded[input] ??
                  (throw StateError(
                      '${contract.name} input $input is not recorded'))),
      ],
      outputs: [
        for (final output in outcome.outputs)
          StageArtifact.capture(
            stage: stage.directory,
            path: output.path,
            type: output.type,
          ),
      ],
      evidence: outcome.evidence,
    );
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
  Future<List<TargetClaim>> _firstClaims(
    ResolvedUnit unit,
    List<TargetExpectation> targets,
  ) async {
    final reads = [
      for (final target in targets)
        inspector.targets
            .moduleForTarget(target)
            .firstClaims(inspector.targetReads, unit, target),
    ];
    return [for (final found in await Future.wait(reads)) ...found];
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
    List<TargetExpectation> remaining, {
    required String? firstCertificate,
    required String? codeId,
    required List<TargetClaim> claims,
  }) async {
    final permanent = remaining.where((target) {
      return target.step.isPermanent;
    }).toList();

    final disclosed = <String>[];
    output.blank();
    if (permanent.isEmpty) {
      output.say('nothing here is permanent.');
    } else {
      // The ground, marked where it matters: everything before the yes is
      // resumable; the first permanent step after it is not.
      final notices = {
        for (final target in permanent)
          if (inspector.targets.moduleForTarget(target).permanenceNotice(target)
              case final notice?)
            notice,
      };
      final ground = '${notices.join('\n')}\n'
          'everything before this yes re-runs safely. after it, the first '
          'permanent step is: ${permanent.first.step.summary}.';
      output.say(ground);
      disclosed.add(ground);
    }

    disclosed.addAll(_sayClaims(claims, firstCertificate, codeId));

    // Weaker assurance is accepted knowingly or not at all: a platform
    // nothing here can run ships with its smoke test missing, and that is
    // said before the version is typed, not discovered afterwards.
    final unprovable = _unprovable(unit);
    if (unprovable.isNotEmpty) {
      output.blank();
      final warning = 'these ship built but never executed — rk cannot '
          'prove they run or report ${unit.version}:';
      output.say(warning);
      for (final platform in unprovable) {
        output.say(platform, depth: 1);
      }
      disclosed.add('$warning\n${unprovable.join('\n')}');
    }

    // What the prompt disclosed travels with the yes: a --json --confirm
    // caller never sees the prose sink, so the document carries it.
    if (disclosed.isNotEmpty) {
      output.report.attach('authorization-disclosures', disclosed.join('\n\n'));
    }

    if (!_requireAuthorizer(unit)) return false;

    final typed = await confirm!(
      'type ${unit.version} to release, or anything else to stop: ',
    );
    if (typed?.trim() != unit.version.canonical) {
      output.blank();
      output.say(typed == null
          ? 'no terminal to answer on — stopped; nothing was published.'
          : 'stopped. nothing was published.');
      output.problem(
        Diagnostic(
          code: 'RK-AUTH-002',
          message: 'the authorization does not name this release',
          remedy: 'authorize exactly ${unit.version}: type it at the '
              'prompt, or pass --confirm=${unit.version}',
        ),
        unit: unit.name,
      );
      output.halt(HaltKind.beforeActing);
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
        remedy: 'a release is authorized by the operator: type the version '
            'at a terminal, or pass --confirm=<version> as the explicit '
            'noninteractive yes. Without either, rk refuses.',
      ),
      unit: unit.name,
    );
    output.halt(HaltKind.beforeActing);
    return false;
  }

  Future<LocalProducerOutcome> _actProducer(
    Step step,
    ResolvedUnit unit,
    String? publishedRequirement,
    String? codeId, {
    SigningIdentity? signingIdentity,
    String? certificateSha256,
  }) async {
    switch (step.kind) {
      case StepKind.build:
        return _chain(unit).buildStep(
          step,
          unit.binaryProject,
          signing: step.platform!.startsWith('macos-')
              ? MacSigning(
                  publishedRequirement: publishedRequirement,
                  codeId: codeId!,
                  identity: signingIdentity,
                  certificateSha256: certificateSha256,
                )
              : null,
        );
      case StepKind.notarize:
        return _chain(unit).notarizeStep(step, unit.binaryProject);
      case StepKind.archive:
        return _chain(unit).archiveStep(step, unit.binaryProject);
      case StepKind.checksums:
        return _chain(unit).checksumsStep(step, unit.binaryProject);
      default:
        throw StateError(
          'step ${step.kind.name} is not a local stage producer',
        );
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
  /// Says the first-claim disclosures and returns them, so the caller can
  /// carry them onto the machine surface beside the yes they gate.
  /// The names this release makes unreclaimable, without the paragraphs.
  ///
  /// A rehearsal exists to be read before these become permanent, so the
  /// facts belong here — but what "permanent" costs is an argument for the
  /// moment of consent, and [_sayClaims] makes it there, once, before the
  /// version is typed.
  void _sayStageClaims(
    List<TargetClaim> claims,
    String? firstCertificate,
    String? codeId, {
    required bool settled,
  }) {
    if (claims.isEmpty && firstCertificate == null) return;
    output.blank();
    // Tense matters: at staging nothing public has happened yet, so saying
    // these *are* permanent would be false a moment before it is true.
    output.line(
      settled
          ? 'First release · these become permanent'
          : 'First release · permanent once published',
      depth: 1,
      tone: Tone.header,
    );
    for (final claim in claims) {
      output.line(
        '${claim.registrar} package',
        note: claim.name,
        depth: 2,
        labelWidth: 26,
        noteTone: Tone.muted,
      );
    }
    if (firstCertificate != null) {
      output.line(
        'macOS code identifier',
        note: codeId,
        depth: 2,
        labelWidth: 26,
        noteTone: Tone.muted,
      );
      output.line(
        'Apple team',
        note: _shortCertificate(firstCertificate),
        depth: 2,
        labelWidth: 26,
        noteTone: Tone.muted,
      );
    }
  }

  List<String> _sayClaims(
    List<TargetClaim> claims,
    String? firstCertificate,
    String? codeId,
  ) {
    final firstOf = <String>[
      for (final claim in claims)
        '${claim.registrar.padRight(17)}${claim.name}\n'
            '                 ${claim.consequence}',
      if (firstCertificate != null)
        'macOS identity   $codeId\n'
            '                 permanent: sealed into the designated '
            'requirement, and into\n'
            '                 every Keychain item this program creates. '
            'Signed by\n'
            '                 $firstCertificate',
    ];
    if (firstOf.isEmpty) return const [];
    output.blank();
    output.say('this release claims, for the first time:');
    for (final line in firstOf) {
      output.say(line, depth: 1);
    }
    return ['this release claims, for the first time:', ...firstOf];
  }

  /// What a producer is doing to the file it is making, while it does it.
  static String _phaseOf(Step step) => switch (step.kind) {
        StepKind.build => step.platform?.startsWith('macos-') == true
            ? 'building and signing'
            : 'building',
        StepKind.notarize => 'notarizing',
        StepKind.archive => 'archiving',
        StepKind.checksums => 'checksumming',
        _ => 'working',
      };

  /// What a target's own stage check proved, in its own words.
  static String? _contributionNote(StageStep step) =>
      step.evidence['publish_dry_run'] == 'passed'
          ? 'pub dry run passed'
          : null;

  /// The settled stage, grouped by the target that will publish each file.
  ///
  /// The notes are read back out of the receipt rather than remembered from
  /// the run: what a signature or a notarization proved is recorded there,
  /// and a second copy composed at print time could disagree with it.
  void _renderBoard(StageBoard board, {required List<StageStep> progressOf}) {
    // Four producers can report against one file — a macOS archive is
    // built, signed, notarized and packed — so what they proved
    // accumulates. Assigning the note per step let the last one silently
    // erase the identity the first one established.
    final marks = <StageBoardRow, List<String>>{};
    for (final step in progressOf) {
      final row = board.rowFor(step.name);
      if (row == null) continue;
      final signature = step.evidence['signature'];
      final notary = step.evidence['notary'];
      final found = marks.putIfAbsent(row, () => <String>[]);
      if (signature is Map && signature['certificate'] is String) {
        found.add('signed');
      }
      if (notary is Map && notary['status'] == 'Accepted') {
        found.add('notarized');
      }
      if (step.evidence['publish_dry_run'] == 'passed') {
        found.add('pub dry run passed');
      }
    }
    marks.forEach((row, found) {
      if (found.isNotEmpty) row.note = found.join(' · ');
    });

    for (final group in board.groups) {
      output.line(group.label, depth: 1);
      for (final row in group.rows) {
        output.line(
          row.name,
          note: row.note,
          depth: 2,
          labelWidth: 44,
          noteTone: Tone.muted,
        );
      }
    }
  }

  /// Every Developer ID certificate begins the same way; what varies is the
  /// team it names.
  static String _shortCertificate(String certificate) =>
      certificate.replaceFirst('Developer ID Application: ', '');

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

class _PreparedStage {
  const _PreparedStage({
    required this.claims,
    required this.receiptSteps,
    this.publishedRequirement,
    this.firstCertificate,
    this.codeId,
  });

  final List<TargetClaim> claims;

  /// The completed receipt, which is where the settled report reads what
  /// each producer proved — a certificate, Apple's verdict — instead of
  /// carrying prose composed while the work ran.
  final List<StageStep> receiptSteps;
  final String? publishedRequirement;
  final String? firstCertificate;
  final String? codeId;
}
