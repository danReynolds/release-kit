import 'dart:io';

import '../engine/changelog.dart';
import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/output.dart';
import '../engine/registry.dart';
import '../engine/resolve.dart';
import '../engine/source_tree.dart';
import '../engine/tools.dart';
import '../engine/verdict.dart';

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
    required this.tools,
    required this.output,
    required this.confirm,
    this.dryRun = false,
  });

  final Resolution resolution;
  final SourceTree tree;
  final GitState git;
  final RegistryReader registry;
  final Tools tools;
  final Output output;

  /// Asks the operator to type the version. Returns what they typed, or null
  /// when there is nobody to ask.
  final Future<String?> Function(String prompt)? confirm;

  /// Show what would happen and stop before the first effect.
  final bool dryRun;

  Future<int> run({String? only}) async {
    final units = only == null
        ? resolution.units
        : resolution.units.where((u) => u.name == only).toList();

    if (units.isEmpty) {
      output.line('no unit named "$only"', mark: Mark.blocked);
      output.say('this repository releases: '
          '${resolution.units.map((u) => u.name).join(', ')}');
      return ExitCodes.usage;
    }
    if (units.length > 1) {
      output.line('name the unit to release', mark: Mark.blocked);
      output.say('this repository releases: '
          '${units.map((u) => u.name).join(', ')}');
      return ExitCodes.usage;
    }

    return _release(units.single);
  }

  Future<int> _release(ResolvedUnit unit) async {
    // Refuse anything rk cannot finish here, before doing any work rather
    // than at the last step.
    final refusal = _refuseIfUnfinishable(unit);
    if (refusal != null) {
      output.line(refusal.message, mark: Mark.blocked);
      if (refusal.remedy != null) output.say(refusal.remedy!, depth: 1);
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

    final checklist = Checklist.derive(unit, resolution);
    final states = <String, Inspection>{};

    // Inspect everything first, so the operator is asked about what is
    // actually left rather than about the whole checklist.
    for (final step in checklist.steps) {
      states[step.id] = await _inspect(step, unit);
    }

    final halting = states.entries.where((e) => e.value.halts).toList();
    if (halting.isNotEmpty) {
      final first = halting.first;
      output.halt(
        first.value.verdict == Verdict.conflict
            ? HaltKind.unfixableByRerun
            : HaltKind.beforeActing,
      );
      output.line(first.key, mark: Mark.blocked, note: first.value.detail);
      for (final entry in first.value.evidence.entries) {
        output.say('${entry.key}: ${entry.value}', depth: 1);
      }
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
      output.line(
        step.summary,
        mark: state.isExact ? Mark.satisfied : Mark.none,
        note: state.isExact ? (state.detail ?? 'already done') : null,
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
      final ok = await _act(step, unit);
      if (!ok) return ExitCodes.refused;
    }

    output.blank();
    output.line('${unit.name} ${unit.version} released', mark: Mark.done);
    for (final project in unit.projects) {
      if (!project.channels.contains('pub.dev')) continue;
      output.say('pub.dev/packages/${project.name}/versions/'
          '${project.version}', depth: 1);
    }
    return ExitCodes.ok;
  }

  Diagnostic? _refuseIfUnfinishable(ResolvedUnit unit) {
    if (unit.shipsBinaries) {
      return const Diagnostic(
        code: 'RK-REL-001',
        message: 'binary channels are not built yet',
        remedy: 'this rk releases packages to pub.dev; the build, signing and '
            'release chain is the next milestone',
      );
    }
    return null;
  }

  void _validate(ResolvedUnit unit, Diagnostics problems) {
    if (!git.isClean) {
      problems.add(
        'RK-GIT-001',
        '${git.uncommitted.length} files are uncommitted',
        remedy: 'a release is of a commit, and these are not in one',
      );
    }
    if (!git.headIsPushed) {
      problems.add(
        'RK-GIT-002',
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

  Future<Inspection> _inspect(Step step, ResolvedUnit unit) async {
    switch (step.kind) {
      case StepKind.tag:
        return git.hasTag(unit.tag)
            ? const Inspection.exact(detail: 'already tagged')
            : const Inspection.absent();

      case StepKind.prerequisite:
        final coordinate = step.coordinate!.split('/');
        final name = coordinate[coordinate.length - 2];
        final version = coordinate.last;
        final package = await _safeLookup(name);
        if (package == null) {
          return Inspection.unknown('$name could not be read on pub.dev');
        }
        final has = package.versions.any((v) => v.version.canonical == version);
        return has
            ? const Inspection.exact(detail: 'live')
            : Inspection.conflict('$name $version is not published yet');

      case StepKind.publishRegistry:
        final project = unit.projects.firstWhere((p) => p.name == step.project);
        return registry.inspect(project.name, project.version);

      default:
        return const Inspection.absent();
    }
  }

  Future<RegistryPackage?> _safeLookup(String name) async {
    try {
      return await registry.lookup(name);
    } on Object {
      return null;
    }
  }

  Future<bool> _act(Step step, ResolvedUnit unit) async {
    switch (step.kind) {
      case StepKind.tag:
        return _tag(unit);
      case StepKind.publishRegistry:
        return _publish(step, unit);
      case StepKind.prerequisite:
        return true; // inspected, never performed
      default:
        output.line(step.summary, mark: Mark.blocked, note: 'not built yet');
        return false;
    }
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
      output.line('tag ${unit.tag}', mark: Mark.blocked,
          note: created.summary);
      return false;
    }

    final pushed = await tools.run(
      'git',
      ['push', 'origin', unit.tag],
      workingDirectory: git.root,
    );
    if (!pushed.ok) {
      output.line('tag ${unit.tag}', mark: Mark.blocked, note: pushed.summary);
      output.say('the tag exists locally; push it or delete it before '
          're-running', depth: 1);
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
