import '../engine/changelog.dart';
import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/inspect.dart';
import '../engine/output.dart';
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
    this.offline = false,
  });

  final Resolution resolution;
  final SourceTree tree;
  final GitState git;
  final RegistryReader registry;

  /// Reads reality for a step. The same one `release` uses, so the two cannot
  /// answer the same question differently.
  final Inspector inspector;

  final Output output;

  /// What is public per project, for the target rows — filled per unit.
  final _live = <String, String>{};

  /// Report only what can be derived without a network.
  ///
  /// The engine's whole first layer is pure computation, and this is how it is
  /// demonstrated on its own: the checklist a release would run, with reality
  /// stated as unread rather than guessed at.
  final bool offline;

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
      head: git.shortHead,
      remote: git.originUrl,
      mode: offline ? 'offline' : null,
    );

    // Belief starts at the top, so the offline caveat goes where the reading
    // does — before the plan, not trailing it dressed as a step.
    if (offline) {
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
      if (offline) {
        _offlineUnit(unit);
      } else {
        anyWouldRelease =
            await _unit(unit, repositoryBlocks: repository.isNotEmpty) ||
                anyWouldRelease;
      }
    }

    // Repository problems are git facts — local reads, inside the offline
    // promise — and dropping them offline handed --json callers an empty
    // problems array for a repository the live view calls blocked.
    if ((offline || anyWouldRelease) && repository.isNotEmpty) {
      output.blank();
      output.problems(repository.found);
    }

    // Blocked is a state, not a failure: a unit waiting on a changelog entry
    // is rk working. Only a refusal — configuration rk cannot read — exits
    // non-zero, and that happens before this command runs.
    return ExitCodes.ok;
  }

  /// The checklist, with nothing read from anywhere.
  void _offlineUnit(ResolvedUnit unit) {
    output.unit(
      unit.name,
      version: unit.version.canonical,
      tag: unit.tag,
    );

    final problems = Diagnostics();
    final checklist = Checklist.derive(unit, resolution, problems);
    for (final step in checklist.steps) {
      output.step(step);
    }
    for (final problem in problems.found) {
      output.problem(problem, depth: 1);
    }
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
    final registrySteps =
        checklist.steps.where((s) => s.kind == StepKind.publishRegistry);
    final summary = _liveSummary(
      live,
      hasRegistry: registrySteps.isNotEmpty,
      registryUnread:
          registrySteps.any((s) => states[s.id]!.verdict == Verdict.unknown),
    );

    final settled =
        problems.isEmpty && blocking.isEmpty && public > 0 && done == public;
    final ready =
        !settled && problems.isEmpty && blocking.isEmpty && !repositoryBlocks;

    output.unit(
      unit.name,
      version: unit.version.canonical,
      tag: unit.tag,
      // One word on the header answers the header's question; the verbose
      // view repeats it on the summary line it already had.
      state: !output.verbose && ready ? 'ready' : null,
    );

    // A local step whose every downstream public step is already done cannot
    // be work that is left: nine build and archive lines under a release that
    // is out are noise, and the RFC's rule is that children which agreed fold
    // into the fact they agreed on.
    final moot = _mootSteps(checklist, states);

    if (output.verbose) {
      // Per-step detail belongs to -v: every checklist line, in derivation
      // order, with the live summary above it.
      final note = settled
          ? 'nothing to release'
          : ready
              ? '→ ${unit.version} ready'
              : null;
      if (summary != null) {
        output.line(
          summary,
          mark: settled ? Mark.satisfied : Mark.none,
          depth: 1,
          labelWidth: 48,
          note: note,
        );
      } else if (note != null) {
        output.line(
          note,
          mark: settled ? Mark.satisfied : Mark.none,
          depth: 1,
          labelWidth: 48,
        );
      }
      for (final step in checklist.steps) {
        _reportStep(step, states[step.id]!, show: !moot.contains(step.id));
      }
    } else {
      // The reader's question is "what ships where, and what is left" — so
      // the default view is one lane per destination, the production chain
      // folded under the destination it feeds. Every step is still recorded:
      // the document carries the whole checklist keyed by id, whatever the
      // terminal folds.
      for (final step in checklist.steps) {
        _reportStep(step, states[step.id]!, show: false);
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
    }

    for (final problem in problems.found) {
      output.problem(problem, depth: 1);
    }

    if (settled) return false;
    if (problems.isEmpty && blocking.isEmpty && !repositoryBlocks) {
      output.next('rk release ${unit.name}');
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

    Mark markOf(Inspection state) => switch (state.verdict) {
          Verdict.exact => Mark.satisfied,
          Verdict.conflict => Mark.blocked,
          _ => Mark.none,
        };

    Tone toneOf(Inspection state) => switch (state.verdict) {
          Verdict.exact => Tone.muted,
          Verdict.conflict => Tone.bad,
          Verdict.unknown => Tone.attention,
          Verdict.absent => Tone.plain,
        };

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
        mark: markOf(state),
        depth: depth,
        labelWidth: noteColumn,
        note: note,
        noteTone: toneOf(state),
      );
      if (state.verdict == Verdict.conflict && state.evidence.isNotEmpty) {
        for (final entry in state.evidence.entries) {
          output.say('${entry.key}: ${entry.value}', depth: depth + 1);
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
          Verdict.unknown => state.detail,
          _ => null,
        },
      );

      // Under a conflicted destination the chain is not work that is left —
      // nothing rk builds can enter a release that is already permanently
      // wrong — so the rows fold, the conflict is the story, and the story
      // ends with the two moves a human can actually make.
      if (state.verdict == Verdict.conflict) {
        output.say(
          'if these are strays from an older configuration, delete them on '
          'the release page;\nif they are wanted, declare their platform in '
          'release.toml.',
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
          '${stages.map((s) => s.kind.name).join(' → ')}',
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
          mark: markOf(states[sums.id]!),
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

  /// One step, said in the terms its verdict earns.
  void _reportStep(Step step, Inspection state, {bool show = true}) {
    output.step(
      step,
      show: show,
      verdict: state.verdict,
      detail: state.detail,
      evidence: state.evidence,
      mark: switch (state.verdict) {
        // Already so, and rk read that it is.
        Verdict.exact => Mark.satisfied,
        Verdict.conflict => Mark.blocked,
        // Absent is work to do, and unknown is work rk could not rule out.
        // Neither earns a glyph; what separates them is the note.
        Verdict.absent || Verdict.unknown => Mark.none,
      },
      note: switch (state.verdict) {
        Verdict.exact => state.detail ?? 'done',
        Verdict.unknown =>
          Inspector.hasPublicState(step.kind) ? state.detail : null,
        _ => step.isPermanent ? 'permanent' : null,
      },
    );
  }

  Future<String?> _latestPublished(String name) async {
    try {
      final package = await registry.lookup(name);
      return package?.latest?.version.canonical;
    } on Object {
      return null;
    }
  }

  /// What is public today, named per project unless they all agree.
  ///
  /// Null when there is nothing honest to say: a unit with no registry
  /// channel has no registry summary, and a registry rk could not read gets
  /// "could not be read" — the step lines were honest all along, and this
  /// line was concluding "not published" from a socket error one line above
  /// them.
  String? _liveSummary(
    Map<String, String> live, {
    required bool hasRegistry,
    required bool registryUnread,
  }) {
    if (!hasRegistry) return null;
    if (live.isEmpty) {
      return registryUnread ? 'pub.dev could not be read' : 'not published';
    }
    final distinct = live.values.toSet();
    if (distinct.length == 1) return distinct.single;
    return live.entries.map((e) => '${e.key} ${e.value}').join(', ');
  }

  /// Facts about the repository, which belong to the repository.
  ///
  /// Reported once, not once per unit: real fleury declares six, so a single
  /// dirty worktree produced six identical entries — the same fact six times
  /// is five times of teaching the reader to skim.
  void _checkRepositoryState(Diagnostics problems) {
    if (!git.isClean) {
      // Few enough to count is few enough to print; only a long list
      // truncates, with the count and the way to the rest — and -v never
      // elides, because verbose that elides is not verbose.
      final paths = output.verbose || git.uncommitted.length <= 8
          ? git.uncommitted.join(', ')
          : '${git.uncommitted.take(8).join(', ')} '
              '…and ${git.uncommitted.length - 8} more (-v shows all)';
      problems.add(
        'RK-GIT-001',
        git.uncommitted.length == 1
            ? '1 path is uncommitted'
            : '${git.uncommitted.length} paths are uncommitted',
        remedy: 'a release is of a commit, and these are not in one: $paths',
      );
    }
    final unpushed = git.unpushedProblem();
    if (unpushed != null) problems.report(unpushed);
  }
}
