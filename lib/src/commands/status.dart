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
import '../engine/version.dart';

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
    );

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

    // Only when something would actually be released: whether the worktree is
    // clean is of no consequence to a repository with nothing left to publish.
    if (anyWouldRelease && repository.isNotEmpty) {
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
    output.say(
      'derived from the manifests alone. Nothing was read from pub.dev,\n'
      'the forge, or the tap, so none of this says what is already done.',
      depth: 1,
    );
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

    final live = <String, String>{};
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

    await _checkMonotonic(unit, problems);

    // Not knowing is not permission to publish. A public step rk could not
    // read, or that conflicts, stops this unit being called ready — but it is
    // not repeated as a problem, because the step line already says it and the
    // report already carries it keyed by the step's own id, which is better
    // machine data than a second entry saying the same thing in prose.
    final unread = checklist.steps.where((s) {
      if (!Inspector.hasPublicState(s.kind)) return false;
      final verdict = states[s.id]!.verdict;
      return verdict == Verdict.unknown || verdict == Verdict.conflict;
    }).toList();

    final done = checklist.steps
        .where((s) => Inspector.hasPublicState(s.kind) && states[s.id]!.isExact)
        .length;
    final public =
        checklist.steps.where((s) => Inspector.hasPublicState(s.kind)).length;
    final summary = _liveSummary(live);

    final settled =
        problems.isEmpty && unread.isEmpty && public > 0 && done == public;
    final ready =
        !settled && problems.isEmpty && unread.isEmpty && !repositoryBlocks;

    output.unit(
      unit.name,
      version: unit.version.canonical,
      tag: unit.tag,
    );

    // What is public today, and what would change it.
    output.line(
      summary,
      mark: settled ? Mark.satisfied : Mark.none,
      depth: 1,
      labelWidth: 48,
      note: settled
          ? 'nothing to release'
          : ready
              ? '→ ${unit.version} ready'
              : null,
    );

    // A local step whose every downstream public step is already done cannot
    // be work that is left: nine build and archive lines under a release that
    // is out are noise, and the RFC's rule is that children which agreed fold
    // into the fact they agreed on.
    final moot = _mootSteps(checklist, states);
    for (final step in checklist.steps) {
      _reportStep(step, states[step.id]!, show: !moot.contains(step.id));
    }

    for (final problem in problems.found) {
      output.problem(problem, depth: 1);
    }

    if (settled) return false;
    if (problems.isEmpty && unread.isEmpty && !repositoryBlocks) {
      output.next('rk release ${unit.name}');
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

  /// One step, said in the terms its verdict earns.
  void _reportStep(Step step, Inspection state, {bool show = true}) {
    output.step(
      step,
      show: show,
      verdict: state.verdict,
      detail: state.detail,
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
  String _liveSummary(Map<String, String> live) {
    if (live.isEmpty) return 'not published';
    final distinct = live.values.toSet();
    if (distinct.length == 1) return distinct.single;
    return live.entries.map((e) => '${e.key} ${e.value}').join(', ');
  }

  /// A version must exceed everything already published, and a tag must
  /// exceed every earlier tag in its namespace.
  ///
  /// The registry half matters most: a tag can be missing entirely, and
  /// publishing behind what is live is the highest-ranked failure this design
  /// exists to prevent.
  Future<void> _checkMonotonic(ResolvedUnit unit, Diagnostics problems) async {
    for (final project in unit.projects) {
      if (!project.channels.contains('pub.dev')) continue;
      final RegistryPackage? published;
      try {
        published = await registry.lookup(project.name);
      } on RegistryUnavailable {
        continue; // the inspection reports this, with a remedy
      }
      final latest = published?.latest;
      if (latest == null) continue;
      if (latest.version > project.version) {
        problems.add(
          'RK-MONO-002',
          '${project.name} ${latest.version} is already published, and this '
              'would publish ${project.version}',
          source:
              SourceLocation(project.pubspec.path, project.pubspec.versionLine),
          remedy: 'a release moves forward — bump past ${latest.version}',
        );
      }
    }

    for (final tag in git.tagsMatching(unit.tagPattern)) {
      final raw = GitState.versionIn(tag, unit.tagPattern);
      if (raw == null) continue;
      final existing = Version.tryParse(raw);
      if (existing == null) continue;
      if (existing == unit.version) continue;
      if (existing > unit.version) {
        problems.add(
          'RK-MONO-001',
          'the tag $tag is ahead of ${unit.version}, which this release '
              'would publish',
          remedy: 'a release moves forward — bump past $raw',
        );
        return;
      }
    }
  }

  /// Facts about the repository, which belong to the repository.
  ///
  /// Reported once, not once per unit: real fleury declares six, so a single
  /// dirty worktree produced six identical entries — the same fact six times
  /// is five times of teaching the reader to skim.
  void _checkRepositoryState(Diagnostics problems) {
    if (!git.isClean) {
      problems.add(
        'RK-GIT-001',
        git.uncommitted.length == 1
            ? '1 file is uncommitted'
            : '${git.uncommitted.length} files are uncommitted',
        remedy: 'a release is of a commit, and these are not in one: '
            '${git.uncommitted.take(3).join(', ')}'
            '${git.uncommitted.length > 3 ? ', …' : ''}',
      );
    }
    if (!git.headIsPushed) {
      problems.add(
        'RK-GIT-002',
        '${git.shortHead} is not on any remote',
        remedy: 'a tag on it would point at something nobody else can '
            'fetch — git push',
      );
    }
  }
}
