import '../engine/changelog.dart';
import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
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
    required this.output,
    this.offline = false,
  });

  final Resolution resolution;
  final SourceTree tree;
  final GitState git;
  final RegistryReader registry;
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

    for (final unit in units) {
      if (offline) {
        _offlineUnit(unit);
      } else {
        await _unit(unit);
      }
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

  /// Reports one unit.
  Future<void> _unit(ResolvedUnit unit) async {
    output.blank();

    final problems = Diagnostics();
    final live = <String, String>{};
    var inspected = 0;
    var exact = 0;
    final unchecked = <String>{};

    for (final project in unit.projects) {
      for (final channel in project.channels) {
        if (channel != 'pub.dev') {
          // Saying nothing about a channel rk cannot read would let a
          // half-finished release look complete.
          unchecked.add(channel);
          continue;
        }

        inspected++;
        final inspection =
            await registry.inspect(project.name, project.version);

        switch (inspection.verdict) {
          case Verdict.exact:
            exact++;
            live[project.name] =
                '${project.version} ${inspection.detail ?? 'published'}';
          case Verdict.absent:
            final published = await _latestPublished(project.name);
            live[project.name] =
                published == null ? 'not published' : '$published published';
          case Verdict.unknown:
            // Not knowing is not permission to publish, so it joins the
            // problems rather than being reported beside a "ready" line.
            problems.add(
              'RK-REG-001',
              '${project.name}: ${inspection.detail ?? 'pub.dev could not be read'}',
              remedy: 'rk cannot tell what is published, so it will not say '
                  'this is ready — try again',
            );
          case Verdict.conflict:
            problems.add(
              'RK-REG-002',
              '${project.name}: ${inspection.detail ?? 'differs from this source'}',
            );
        }

        Changelog.check(
          tree: tree,
          manifestDirectory: project.pubspec.directory,
          packageName: project.name,
          version: project.version,
          diagnostics: problems,
        );
      }
    }

    // The checklist's own checks — a first-party pin the release does not
    // satisfy, a dependency circle — are found by deriving it, so it is
    // derived before anything is called ready.
    Checklist.derive(unit, resolution, problems);

    final summary = _liveSummary(unit, live);

    // Nothing to release settles it: whether the worktree is clean or a later
    // tag exists only matters to a release that is going to happen.
    if (problems.isEmpty &&
        inspected > 0 &&
        exact == inspected &&
        unchecked.isEmpty) {
      output.line(unit.name, note: '$summary — nothing to release');
      return;
    }

    await _checkMonotonic(unit, problems);
    _checkRepositoryState(unit, problems);

    if (problems.isNotEmpty) {
      output.line(unit.name, mark: Mark.blocked, note: summary);
      for (final problem in problems.found) {
        output.problem(problem, depth: 1);
      }
      return;
    }

    output.line(unit.name, note: '$summary → ${unit.version} ready');
    _printPlan(unit, problems);
    if (unchecked.isNotEmpty) {
      output.say(
        'not checked: ${unchecked.join(', ')} — rk cannot read those yet',
        depth: 1,
      );
    }
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
  String _liveSummary(ResolvedUnit unit, Map<String, String> live) {
    if (live.isEmpty) return 'not published';
    final distinct = live.values.toSet();
    if (distinct.length == 1) return distinct.single;
    return live.entries.map((e) => '${e.key} ${e.value}').join(', ');
  }

  void _printPlan(ResolvedUnit unit, Diagnostics problems) {
    final checklist = Checklist.derive(unit, resolution, problems);
    final channels = <String>{};
    for (final project in unit.projects) {
      channels.addAll(project.channels);
    }
    output.line(
      channels.join(', '),
      depth: 1,
      note: '${checklist.steps.length} steps',
    );
    output.next('rk release ${unit.name}');
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

  void _checkRepositoryState(ResolvedUnit unit, Diagnostics problems) {
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
