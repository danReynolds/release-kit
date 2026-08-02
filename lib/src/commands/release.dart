import 'dart:io';

import '../builds/capability.dart';
import '../engine/changelog.dart';
import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/output.dart';
import '../engine/inspect.dart';
import '../engine/registry.dart';
import '../engine/resolve.dart';
import '../engine/source_tree.dart';
import '../engine/tools.dart';
import '../engine/verdict.dart';
import 'binary_chain.dart';

/// Executes a release: inspect, act, verify, one step at a time.
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
    this.dryRun = false,
  });

  final Resolution resolution;
  final SourceTree tree;
  final GitState git;
  final RegistryReader registry;

  /// Reads reality for a step. The same one `status` uses, so the two verbs
  /// cannot answer the same question differently — release grew its own copy
  /// once, and it answered `absent` by default for every kind it did not name.
  final Inspector inspector;

  final Tools tools;
  final Output output;

  /// Asks the operator to type the version. Returns what they typed, or null
  /// when there is nobody to ask.
  final Future<String?> Function(String prompt)? confirm;

  /// Show what would happen and stop before the first effect.
  final bool dryRun;

  /// Assets produced during this run, so the steps that ship them do not have
  /// to rebuild what the step before them just made.
  List<ReleaseAsset>? _produced;

  Future<int> run({String? only}) async {
    final units = only == null
        ? resolution.units
        : resolution.units.where((u) => u.name == only).toList();

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
    if (units.length > 1) {
      output.problem(
        Diagnostic(
          code: 'RK-CLI-004',
          message: 'name the unit to release',
          remedy: 'this repository releases several, and a release is of one: '
              '${units.map((u) => u.name).join(', ')}',
        ),
      );
      return ExitCodes.usage;
    }

    return _release(units.single);
  }

  Future<int> _release(ResolvedUnit unit) async {
    // Refuse anything rk cannot finish here, before doing any work rather
    // than at the last step.
    final refusal = _refuseIfUnfinishable(unit);
    if (refusal != null) {
      output.problem(refusal);
      return ExitCodes.refused;
    }

    // Validate independently: rk cannot assume status was run, and its
    // findings may be stale by now.
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
    final states = <String, Inspection>{};

    // Inspect everything first, so the operator is asked about what is
    // actually left rather than about the whole checklist.
    for (final step in checklist.steps) {
      states[step.id] = await inspector.inspect(step, unit);
    }

    // Everything inspected is recorded before anything is decided, so a halt
    // is never prose-only: a caller gets the checklist with verdicts keyed by
    // step id, whatever happens next.
    for (final step in checklist.steps) {
      final state = states[step.id]!;
      output.step(
        step,
        verdict: state.verdict,
        detail: state.detail,
        evidence: state.evidence,
        show: false,
      );
    }

    // Release validates independently rather than trusting status — and the
    // top-ranked failure, publishing a back-version, was checked only by the
    // verb that does not act.
    await inspector.monotonicity(unit, problems);
    inspector.tagGuards(unit, checklist, states).forEach(problems.report);
    await _refuseFirstPublish(unit, problems);
    if (problems.isNotEmpty) {
      output.halt(HaltKind.beforeActing);
      output.problems(problems.found);
      return ExitCodes.refused;
    }

    // What blocks, before anything acts. Local steps answer unknown by
    // design — they are the work this run does — so unknown halts only where
    // the state was supposed to be readable: a destination rk could not reach
    // is not permission to publish to it. The one absence that blocks is a
    // prerequisite, and it blocks as something re-running fixes once the
    // other unit has shipped.
    final halting = checklist.steps
        .where((s) => Inspector.blocks(s, states[s.id]!))
        .toList();
    if (halting.isNotEmpty) {
      final first = halting.first;
      final state = states[first.id]!;
      output.halt(
        state.verdict == Verdict.conflict
            ? HaltKind.unfixableByRerun
            : HaltKind.beforeActing,
      );
      // A problem, not a bare line: the same call records it, so the halt a
      // person reads is the halt a caller gets.
      output.problem(
        Diagnostic(
          code: 'RK-REL-001',
          message: '${first.summary}: '
              '${state.detail ?? state.verdict.name}',
          remedy: state.evidence.isEmpty
              ? null
              : state.evidence.entries
                  .map((e) => '${e.key}: ${e.value}')
                  .join('\n'),
        ),
      );
      return ExitCodes.refused;
    }

    final remaining =
        checklist.steps.where((s) => !states[s.id]!.isExact).toList();

    if (remaining.isEmpty) {
      output.line(
        '${unit.name} ${unit.version}',
        mark: Mark.done,
        note: 'already released',
      );
      return ExitCodes.ok;
    }

    output.heading('${unit.name} ${unit.version} → '
        '${_channels(unit).join(', ')}');
    output.blank();

    for (final step in checklist.steps) {
      final state = states[step.id]!;
      output.step(
        step,
        mark: state.isExact ? Mark.satisfied : Mark.none,
        verdict: state.verdict,
        detail: state.detail,
        note: state.isExact ? (state.detail ?? 'already done') : null,
        depth: 0,
      );
    }

    if (dryRun) {
      output.blank();
      output.say('nothing was started.');
      return ExitCodes.ok;
    }

    if (!await _authorize(unit, remaining)) return ExitCodes.refused;

    output.blank();
    for (final step in checklist.steps) {
      if (states[step.id]!.isExact) continue;
      // From here on the world may change, which is what makes a failure
      // worth recording evidence about.
      output.report.acted = true;
      final ok = await _act(step, unit);
      if (!ok) return ExitCodes.refused;
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

  /// A package that has never existed is not published by rk.
  ///
  /// The first publish is a ceremony — accepting pub.dev's terms, choosing a
  /// publisher — and running it under --force from an executor would perform
  /// that ceremony as a side effect, or fail halfway into one. Refusing to
  /// act is not refusing to instruct: the exact command is printed, and every
  /// release after the first belongs to rk.
  Future<void> _refuseFirstPublish(
    ResolvedUnit unit,
    Diagnostics problems,
  ) async {
    for (final project in unit.projects) {
      if (!project.channels.contains('pub.dev')) continue;
      final RegistryPackage? package;
      try {
        package = await registry.lookup(project.name);
      } on RegistryUnavailable {
        continue; // the step's own inspection already reports this
      }
      if (package != null) continue;
      problems.add(
        'RK-REG-003',
        '${project.name} has never been published, and a first publish is '
            'not rk\'s to perform',
        remedy: 'the first release accepts the terms and names a publisher, '
            'which is the author\'s ceremony. Run it once by hand:\n'
            '  cd ${project.pubspec.directory} && dart pub publish\n'
            'and every release after it belongs to rk.',
      );
    }
  }

  /// Refuses what this machine cannot finish, before any work rather than at
  /// the last step.
  Diagnostic? _refuseIfUnfinishable(ResolvedUnit unit) {
    if (!unit.shipsBinaries) return null;

    final capabilities = HostCapabilities.detect();
    final blocked = <String>[];
    for (final project in unit.projects) {
      for (final platform in project.binaryPlatforms) {
        final resolved = capabilities.resolve(platform);
        if (!resolved.canProduce) {
          blocked.add('$platform — ${resolved.reason}');
        }
      }
    }
    if (blocked.isEmpty) return null;

    return Diagnostic(
      code: 'RK-REL-001',
      message: 'this machine cannot produce every platform this unit ships',
      remedy: 'starting anyway would build and sign for minutes and then '
          'stop before publishing anything:\n  ${blocked.join('\n  ')}',
    );
  }

  void _validate(ResolvedUnit unit, Diagnostics problems) {
    if (!git.isClean) {
      problems.add(
        'RK-GIT-001',
        '${git.uncommitted.length} paths are uncommitted',
        remedy: 'a release is of a commit, and these are not in one',
      );
    }
    if (!git.headIsPushed) {
      problems.add(
        'RK-GIT-003',
        '${git.shortHead} is not on any remote',
        remedy: 'git push, so the tag points at something others can fetch',
      );
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

  Set<String> _channels(ResolvedUnit unit) {
    final channels = <String>{};
    for (final project in unit.projects) {
      channels.addAll(project.channels);
    }
    return channels;
  }

  /// The operator's presence and typed confirmation are the authorization for
  /// a local release. Where a tag already exists, its signature is.
  Future<bool> _authorize(ResolvedUnit unit, List<Step> remaining) async {
    final permanent = remaining.where((s) => s.isPermanent).toList();

    output.blank();
    if (permanent.isEmpty) {
      output.say('nothing here is permanent.');
    } else {
      output.say('pub.dev never deletes a version. a version can be '
          'retracted, which hides it and removes nothing.');
    }

    if (confirm == null) {
      output.blank();
      output.line(
        'nobody is here to authorize this',
        mark: Mark.blocked,
      );
      output.say('a release from a terminal is authorized by the operator '
          'confirming it. Unattended, rk needs a signed tag instead.');
      return false;
    }

    final typed = await confirm!(
      'type ${unit.version} to release, or anything else to stop: ',
    );
    if (typed?.trim() != unit.version.canonical) {
      output.blank();
      output.say('stopped. nothing was published.');
      return false;
    }
    return true;
  }

  Future<bool> _act(Step step, ResolvedUnit unit) async {
    switch (step.kind) {
      case StepKind.tag:
        return _tag(unit);
      case StepKind.publishRegistry:
        return _publish(step, unit);
      case StepKind.prerequisite:
        return true; // inspected, never performed
      case StepKind.build:
        // The whole chain runs once, at the first build step: signing,
        // notarizing and archiving are one sequence per platform, and
        // splitting them here would mean re-reading artifacts between them.
        return _produce(unit);
      case StepKind.sign ||
            StepKind.notarize ||
            StepKind.archive ||
            StepKind.checksums:
        return true; // done by the chain the first build started
      case StepKind.publishRelease:
        return _publishRelease(unit);
      case StepKind.publishFormula:
        return _publishFormula(unit);
    }
  }

  BinaryChain _chain(ResolvedUnit unit) => BinaryChain(
        tools: tools,
        output: output,
        workspace: '${git.root}/.rk/work/${unit.tag}-${git.shortHead}',
        repositoryRoot: git.root,
        capabilities: HostCapabilities.detect(),
      );

  ResolvedProject _binaryProject(ResolvedUnit unit) =>
      unit.projects.firstWhere((p) => p.config.wantsBinaries);

  Future<bool> _produce(ResolvedUnit unit) async {
    final project = _binaryProject(unit);
    final identity = resolution.identity;

    final assets = await _chain(unit).produce(
      unit: unit,
      project: project,
      appleTeam: identity?.appleTeam,
      codeId: identity?.codeId,
    );
    if (assets == null) return false;
    _produced = assets;
    return true;
  }

  Future<bool> _publishRelease(ResolvedUnit unit) async {
    final assets = _produced;
    if (assets == null) {
      output.line('github-release',
          mark: Mark.blocked, note: 'nothing was produced to publish');
      return false;
    }
    final repository = _repository();
    if (repository == null) return false;

    final url = await _chain(unit).publishRelease(
      repository: repository,
      tag: unit.tag,
      title: '${_binaryProject(unit).name} ${unit.version}',
      assets: assets,
    );
    return url != null;
  }

  Future<bool> _publishFormula(ResolvedUnit unit) async {
    final assets = _produced;
    if (assets == null) return false;
    final repository = _repository();
    if (repository == null) return false;

    final identity = resolution.identity;
    final tap =
        identity?.homebrewTap ?? '${repository.split('/').first}/homebrew-tap';

    return _chain(unit).updateFormula(
      tap: tap,
      repository: repository,
      tag: unit.tag,
      project: _binaryProject(unit),
      assets: assets,
    );
  }

  /// The `owner/name` this repository pushes to.
  String? _repository() {
    final remote = git.originUrl;
    if (remote == null) {
      output.line('github-release',
          mark: Mark.blocked, note: 'this repository has no origin remote');
      return null;
    }
    return remote;
  }

  /// Creates and pushes the tag that records this release.
  ///
  /// A record written after the operator authorized, not the authorization
  /// itself — which is why rk may write it here and never may where a tag is
  /// what authorizes.
  Future<bool> _tag(ResolvedUnit unit) async {
    final signed = git.signingConfigured;
    final args = [
      'tag',
      if (signed) '-s' else '-a',
      unit.tag,
      '-m',
      '${unit.name} ${unit.version}',
    ];

    final created = await tools.run('git', args, workingDirectory: git.root);
    if (!created.ok) {
      output.line('tag ${unit.tag}', mark: Mark.blocked, note: created.summary);
      return false;
    }

    final pushed = await tools.run(
      'git',
      ['push', 'origin', unit.tag],
      workingDirectory: git.root,
    );
    if (!pushed.ok) {
      output.line('tag ${unit.tag}', mark: Mark.blocked, note: pushed.summary);
      output.say(
          'the tag exists locally; push it or delete it before '
          're-running',
          depth: 1);
      return false;
    }

    output.line(
      'tag ${unit.tag}',
      mark: Mark.done,
      note: signed ? 'signed, pushed' : 'pushed, unsigned',
    );
    return true;
  }

  Future<bool> _publish(Step step, ResolvedUnit unit) async {
    final project = unit.projects.firstWhere((p) => p.name == step.project);
    final directory = project.pubspec.directory == '.'
        ? git.root
        : '${git.root}/${project.pubspec.directory}';

    // A consumer resolve first: overrides are excluded from the archive but
    // honoured locally, so a dry run can pass while the published package is
    // unresolvable for everyone else.
    final dry = await tools.run(
      'dart',
      const ['pub', 'publish', '--dry-run'],
      workingDirectory: directory,
    );
    if (!dry.ok) {
      output.line(project.name, mark: Mark.blocked, note: dry.summary);
      return false;
    }

    final code = await tools.runInteractive(
      'dart',
      const ['pub', 'publish', '--force'],
      workingDirectory: directory,
    );
    if (code != 0) {
      output.line(project.name, mark: Mark.blocked, note: 'publish failed');
      return false;
    }

    // Verify against reality rather than trusting the publisher's own word.
    // rk just acted on this coordinate, so what it knew about the package is
    // stale by rk's own hand. Without this, the confirming read answers from
    // the memo the pre-act inspection wrote, and every successful publish
    // reports failure.
    registry.forget(project.name);
    final after = await registry.inspect(project.name, project.version);
    if (!after.isExact) {
      output.line(
        project.name,
        mark: Mark.blocked,
        note: 'published, but pub.dev does not report it yet',
      );
      output.say('re-run to confirm; nothing else is needed', depth: 1);
      return false;
    }

    output.line(
      '${project.name} ${project.version}',
      mark: Mark.done,
      note: 'published',
    );
    return true;
  }
}

/// Reads a confirmation from the terminal, or nothing when there is no
/// terminal to read from.
Future<String?> promptOnTerminal(String prompt) async {
  if (!stdin.hasTerminal) return null;
  stdout.write(prompt);
  return stdin.readLineSync();
}
