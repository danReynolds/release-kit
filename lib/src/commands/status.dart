import '../engine/changelog.dart';
import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/inspect.dart';
import '../output/output.dart';
import '../engine/registry.dart';
import '../engine/resolve.dart';
import '../engine/source_tree.dart';
import '../engine/verdict.dart';

/// Where a repository stands: what is live, what is local, what is ready, and
/// what is in the way.
///
/// Read-only, always. It is the only verb that changes nothing, so it is the
/// one an agent may run freely.
class StatusCommand {
  StatusCommand({
    required this.resolution,
    required this.tree,
    required this.git,
    required this.registry,
    required this.inspector,
    required this.output,
  });

  final Resolution resolution;
  final SourceTree tree;
  final GitState git;

  /// Absent when the registry was not read; the verdicts say so themselves.
  final RegistryReader? registry;

  /// Reads reality for a step. The same one `release` uses, so the two cannot
  /// answer the same question differently.
  final Inspector inspector;

  final Output output;

  /// What is public per project, for the target rows — filled per unit.
  final _live = <String, String>{};

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

    output.repository(
      name: tree.description.split('/').last,
      branch: git.branch,
      uncommitted: git.uncommitted.length,
      head: git.head,
      remote: git.originUrl,
      mode: registry == null ? 'offline' : null,
    );

    // Belief starts at the top, so the caveat goes where the reading does —
    // before the plan, not trailing it dressed as a step.
    if (registry == null) {
      output.say(
        'a plan, derived from the manifests alone. Nothing was read from '
        'pub.dev, GitHub, or the Homebrew tap, so none of this says what '
        'is already done.',
      );
    }

    // Read once, before the units, because a unit cannot honestly say "run
    // rk release" while something about the repository would refuse it — and
    // printing the instruction above the reason it will not work is worse than
    // not printing it.
    final repository = Diagnostics();
    _checkRepositoryState(repository);

    var anyWouldRelease = false;
    for (final unit in units) {
      anyWouldRelease =
          await _unit(unit, repositoryBlocks: repository.isNotEmpty) ||
              anyWouldRelease;
    }

    // Repository problems are git facts — local reads, true offline too —
    // and dropping them handed --json callers an empty problems array for a
    // repository the live view calls blocked.
    if ((registry == null || anyWouldRelease) && repository.isNotEmpty) {
      output.blank();
      output.problems(repository.found);
    }

    // Blocked is a state, not a failure: a unit waiting on a changelog entry
    // is rk working. Only a refusal — configuration rk cannot read — exits
    // non-zero, and that happens before this command runs.
    return ExitCodes.ok;
  }

  /// Reports one unit: every step of its checklist, against reality.
  ///
  /// The checklist is the structure, not a parallel walk over channels. A
  /// separate walk is what let status never learn that a unit ships binaries,
  /// never read the forge, and hand a caller a document with no units in it.
  Future<bool> _unit(
    ResolvedUnit unit, {
    required bool repositoryBlocks,
  }) async {
    final problems = Diagnostics();
    final checklist = Checklist.derive(unit, resolution, problems);

    final states = <String, Inspection>{};
    for (final step in checklist.steps) {
      states[step.id] = await inspector.inspect(step, unit);
    }

    _live.clear();
    final live = _live;
    for (final project in unit.projects) {
      if (!project.channels.contains('pub.dev')) continue;
      final state = states['${unit.name}/pub.dev/${project.name}'
          '@${project.version}'];
      if (state == null) continue;
      if (state.isExact) {
        live[project.name] =
            '${project.version} ${state.detail ?? 'published'}';
      } else if (state.isAbsent) {
        final published = await _latestPublished(project.name);
        live[project.name] =
            published == null ? 'not published' : '$published published';
      }

      Changelog.check(
        tree: tree,
        manifestDirectory: project.pubspec.directory,
        packageName: project.name,
        version: project.version,
        diagnostics: problems,
      );
    }

    await inspector.monotonicity(unit, problems);
    inspector.tagGuards(unit, checklist, states).forEach(problems.report);

    // What stops a release stops readiness — the same classification release
    // halts on, so status can never recommend the command release refuses.
    // It is not repeated as a problem, because the step line already says it
    // and the report carries it keyed by the step's own id.
    final blocking = checklist.steps
        .where((s) => Inspector.blocks(s, states[s.id]!))
        .toList();

    final done = checklist.steps
        .where((s) => Inspector.hasPublicState(s.kind) && states[s.id]!.isExact)
        .length;
    final public =
        checklist.steps.where((s) => Inspector.hasPublicState(s.kind)).length;
    final settled =
        problems.isEmpty && blocking.isEmpty && public > 0 && done == public;
    final ready =
        !settled && problems.isEmpty && blocking.isEmpty && !repositoryBlocks;

    output.unit(
      unit.name,
      version: unit.version.canonical,
      tag: unit.tag,
      // One word on the header answers the header's question, and the
      // lanes below say the rest — so it is stated once, here.
      state: ready ? 'ready' : null,
    );

    // A local step whose every downstream public step is already done cannot
    // be work that is left: nine build and archive lines under a release that
    // is out are noise, and the RFC's rule is that children which agreed fold
    // into the fact they agreed on.
    final moot = _mootSteps(checklist, states);

    // One rendering, not two: the reader's question is "what ships where,
    // and what is left", answered by a header per destination with the
    // production chain folded under the one it feeds. The per-step view
    // that used to live behind -v was a second, worse answer to the same
    // question — every step is still recorded, and --json carries the whole
    // checklist keyed by id for anyone who wants it all.
    for (final step in checklist.steps) {
      _record(step, states[step.id]!);
    }
    if (settled) {
      output.line(
        'nothing to release',
        mark: Mark.satisfied,
        depth: 2,
        labelWidth: 48,
        tone: Tone.muted,
      );
    } else {
      _targets(unit, checklist, states, moot,
          repositoryBlocks: repositoryBlocks);
    }

    for (final problem in problems.found) {
      output.problem(problem, depth: 1);
    }

    if (settled) return false;
    if (problems.isEmpty && blocking.isEmpty && !repositoryBlocks) {
      // Status must never recommend the command release refuses — the
      // phase-3 rule, and a first publish is release's own refusal
      // (RK-REG-003): the honest next move on a never-published package is
      // the manual publish, with rk taking over from the release after it.
      final firstPublish = unit.projects
          .where((p) =>
              p.channels.contains('pub.dev') &&
              _live[p.name] == 'not published')
          .firstOrNull;
      if (firstPublish != null) {
        final directory = firstPublish.pubspec.directory;
        output.next(directory == '.'
            ? 'dart pub publish'
            : 'cd $directory && dart pub publish');
      } else {
        output.next('rk release ${unit.name}');
      }
    } else {
      // A prerequisite that is not live points at the unit that must go
      // first, and that is the honest next command — not this one, which
      // release would immediately refuse.
      for (final step in blocking) {
        if (step.kind != StepKind.prerequisite) continue;
        if (!states[step.id]!.isAbsent) continue;
        final parts = step.coordinate?.split('/') ?? const [];
        if (parts.length < 3) continue;
        final declaring = resolution.allProjects
            .where((p) => p.name == parts[parts.length - 2])
            .map((p) => p.unitName)
            .firstOrNull;
        if (declaring != null && declaring != unit.name) {
          output.next('rk release $declaring');
        }
      }
    }
    return true;
  }

  /// Local steps that nothing outstanding depends on.
  ///
  /// A step is moot when every public step reachable from it is already exact.
  /// Walking forwards from a step is walking the `needs` edges backwards, which
  /// is why this reads them the way it does.
  Set<String> _mootSteps(Checklist checklist, Map<String, Inspection> states) {
    final moot = <String>{};

    bool everythingAfterIsDone(Step step, Set<String> visiting) {
      final dependents =
          checklist.steps.where((s) => s.needs.contains(step.id)).toList();
      if (dependents.isEmpty) return false;
      for (final dependent in dependents) {
        if (!visiting.add(dependent.id)) continue;
        if (Inspector.hasPublicState(dependent.kind)) {
          if (!states[dependent.id]!.isExact) return false;
        } else if (!everythingAfterIsDone(dependent, visiting)) {
          return false;
        }
      }
      return true;
    }

    for (final step in checklist.steps) {
      if (Inspector.hasPublicState(step.kind)) continue;
      if (everythingAfterIsDone(step, {step.id})) moot.add(step.id);
    }
    return moot;
  }

  /// The checklist as release targets: a header per destination, the rows
  /// that concern it beneath, every annotation in one shared column.
  ///
  /// The RFC's collapse rule still governs what appears — a settled unit
  /// never reaches here, a conflicted destination folds the chain that can
  /// no longer feed it — and colour repeats the gutter's judgment on the
  /// words themselves, so a scan reads state without reading prose.
  void _targets(
    ResolvedUnit unit,
    Checklist checklist,
    Map<String, Inspection> states,
    Set<String> moot, {
    required bool repositoryBlocks,
  }) {
    const noteColumn = 50;

    void header(String target) => output.line(
          target,
          depth: 1,
          tone: Tone.header,
        );

    void row(
      Step step,
      String subject, {
      String? note,
      int depth = 2,
    }) {
      final state = states[step.id]!;
      output.line(
        subject,
        mark: Mark.of(state.verdict),
        depth: depth,
        labelWidth: noteColumn,
        note: note,
        noteTone: Tone.of(state.verdict),
      );
      if (state.verdict == Verdict.conflict && state.evidence.isNotEmpty) {
        // Names sharing a reason fold onto it — the same sentence three
        // times is one fact said three times.
        final byReason = <String, List<String>>{};
        for (final entry in state.evidence.entries) {
          byReason.putIfAbsent(entry.value, () => []).add(entry.key);
        }
        for (final entry in byReason.entries) {
          output.say('${entry.value.join('\n')}\n  — ${entry.key}',
              depth: depth + 1);
        }
      }
    }

    // Provenance first: the tag is what every target below publishes under.
    final tags = checklist.steps
        .where((s) => s.kind == StepKind.tag && !moot.contains(s.id));
    if (tags.isNotEmpty) {
      header('tag');
      for (final step in tags) {
        final state = states[step.id]!;
        row(
          step,
          unit.tag,
          note: state.detail ?? (state.isAbsent ? 'not created' : null),
        );
      }
    }

    // What another unit must publish before this one can.
    final needs = checklist.steps.where((s) => s.kind == StepKind.prerequisite);
    if (needs.isNotEmpty) {
      header('needs');
      for (final step in needs) {
        final state = states[step.id]!;
        row(
          step,
          step.coordinate ?? step.summary,
          note: state.detail ?? (state.isAbsent ? 'not live yet' : null),
        );
      }
    }

    final registry = checklist.steps
        .where((s) => s.kind == StepKind.publishRegistry)
        .toList();
    if (registry.isNotEmpty) {
      header('pub.dev');
      for (final step in registry) {
        final state = states[step.id]!;
        final project = unit.projects.firstWhere((p) => p.name == step.project);
        final live = _live[project.name];
        row(
          step,
          '${project.name} ${project.version}',
          note: switch (state.verdict) {
            Verdict.exact => state.detail ?? 'published',
            Verdict.unknown => state.detail ?? 'could not be read',
            _ => '${live ?? 'not published'} · publishing is permanent',
          },
        );
        // Refusing to act is not refusing to instruct: rk will not perform
        // a first publish, and now — not at the release prompt — is when
        // knowing that is worth something.
        if (state.isAbsent && live == 'not published' && !repositoryBlocks) {
          output.say(
            'pub.dev requires the first publish by hand: dart pub publish, '
            'once.\nrk owns every release after it.',
            depth: 3,
          );
        }
      }
    }

    for (final step
        in checklist.steps.where((s) => s.kind == StepKind.publishRelease)) {
      final state = states[step.id]!;
      header('github-release');
      row(
        step,
        step.summary
            .replaceFirst('publish ', '')
            .replaceFirst(' to the ${unit.tag} release', ' at ${unit.tag}'),
        note: switch (state.verdict) {
          Verdict.exact => state.detail ?? 'published',
          _ => state.detail,
        },
      );

      // Under a conflicted destination the chain is not work that is left —
      // nothing rk builds can enter a release that is already permanently
      // wrong — so the rows fold, the conflict is the story, and the story
      // ends with the two moves a human can actually make.
      if (state.verdict == Verdict.conflict) {
        output.say(
          'strays from an older configuration can be removed: '
          'gh release delete-asset ${unit.tag} <name>\n'
          'wanted assets get their platform declared in release.toml.',
          depth: 3,
        );
        continue;
      }

      final project = unit.projects.firstWhere((p) => p.name == step.project);
      for (final platform in project.binaryPlatforms) {
        final stages = checklist.steps
            .where((s) => s.platform == platform && s.project == project.name)
            .toList();
        if (stages.isEmpty || stages.every((s) => moot.contains(s.id))) {
          continue;
        }
        final conflicted = stages
            .where((s) => states[s.id]!.verdict == Verdict.conflict)
            .toList();
        final done =
            stages.where((s) => states[s.id]!.isExact).map((s) => s.kind.name);
        output.line(
          '${platform.padRight(14)}'
          '${stages.map((s) => s.kind.name).join(' › ')}',
          mark: conflicted.isNotEmpty
              ? Mark.blocked
              : stages.every((s) => states[s.id]!.isExact)
                  ? Mark.satisfied
                  : Mark.none,
          depth: 2,
          labelWidth: noteColumn,
          note: conflicted.isNotEmpty
              ? states[conflicted.first.id]!.detail
              : done.isEmpty
                  ? null
                  : 'done: ${done.join(', ')}',
          noteTone: conflicted.isNotEmpty ? Tone.bad : Tone.muted,
        );
      }
      for (final sums in checklist.steps
          .where((s) => s.kind == StepKind.checksums && !moot.contains(s.id))) {
        output.line(
          '${'checksums'.padRight(14)}'
          '${sums.summary.replaceFirst('checksums for ', '')}',
          mark: Mark.of(states[sums.id]!.verdict),
          depth: 2,
          labelWidth: noteColumn,
        );
      }
    }

    final formulas =
        checklist.steps.where((s) => s.kind == StepKind.publishFormula);
    for (final step in formulas) {
      final state = states[step.id]!;
      header('homebrew');
      final project = unit.projects.firstWhere((p) => p.name == step.project);
      row(
        step,
        'Formula/${project.executable}.rb',
        note: state.detail,
      );
    }
  }

  /// Records a step without printing it.
  ///
  /// The lanes are the rendering; this is the document. It carries the
  /// whole checklist keyed by step id whatever the terminal folds, which
  /// is the one asymmetry the two surfaces are allowed.
  void _record(Step step, Inspection state) {
    output.step(
      step,
      show: false,
      verdict: state.verdict,
      detail: state.detail,
      evidence: state.evidence,
    );
  }

  Future<String?> _latestPublished(String name) async {
    if (registry == null) return null;
    try {
      final package = await registry!.lookup(name);
      return package?.latest?.version.canonical;
    } on Object {
      return null;
    }
  }

  /// Facts about the repository, which belong to the repository.
  ///
  /// Reported once, not once per unit: real fleury declares six, so a single
  /// dirty worktree produced six identical entries — the same fact six times
  /// is five times of teaching the reader to skim.
  void _checkRepositoryState(Diagnostics problems) {
    final uncommitted = git.uncommittedProblem();
    if (uncommitted != null) problems.report(uncommitted);
    final unpushed = git.unpushedProblem();
    if (unpushed != null) problems.report(unpushed);
  }
}
