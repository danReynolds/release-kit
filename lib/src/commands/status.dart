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
  });

  final Resolution resolution;
  final SourceTree tree;
  final GitState git;
  final RegistryReader registry;
  final Output output;

  Future<int> run({String? only}) async {
    final units = only == null
        ? resolution.units
        : resolution.units.where((u) => u.name == only).toList();

    if (units.isEmpty) {
      output.line(
        'no unit named "$only"',
        mark: Mark.blocked,
      );
      output.say('this repository releases: '
          '${resolution.units.map((u) => u.name).join(', ')}');
      return ExitCodes.usage;
    }

    output.heading(_repositoryLine());

    for (final unit in units) {
      await _unit(unit);
    }

    // Blocked is a state, not a failure: a unit waiting on a changelog entry
    // is rk working. Only a refusal — configuration rk cannot read — exits
    // non-zero, and that happens before this command runs.
    return ExitCodes.ok;
  }

  String _repositoryLine() {
    final name = tree.description.split('/').last;
    final parts = <String>[name];
    if (git.branch != null) parts.add(git.branch!);
    if (!git.isClean) {
      parts.add('${git.uncommitted.length} uncommitted');
    }
    return parts.join(' · ');
  }

  /// Reports one unit.
  Future<void> _unit(ResolvedUnit unit) async {
    output.blank();

    final problems = Diagnostics();
    final inspections = <String, Inspection>{};

    for (final project in unit.projects) {
      if (!project.channels.contains('pub.dev')) continue;
      inspections[project.name] =
          await registry.inspect(project.name, project.version);
      Changelog.check(
        tree: tree,
        manifestDirectory: project.pubspec.directory,
        packageName: project.name,
        version: project.version,
        diagnostics: problems,
      );
    }

    await _checkMonotonic(unit, problems);
    _checkRepositoryState(unit, problems);

    final live = _liveSummary(unit, inspections);

    // `every` on an empty map is true, which would report a binary-only unit
    // — one with nothing on a registry — as already released.
    final released =
        inspections.isNotEmpty && inspections.values.every((i) => i.isExact);

    if (released) {
      output.line(unit.name, note: '$live — nothing to release');
      return;
    }

    if (problems.isNotEmpty) {
      output.line(unit.name, mark: Mark.blocked, note: live);
      for (final problem in problems.found) {
        output.problem(problem, depth: 1);
      }
      return;
    }

    output.line(unit.name, note: '$live → ${unit.version} ready');
    for (final entry in inspections.entries) {
      if (entry.value.verdict == Verdict.unknown) {
        output.line(
          entry.key,
          mark: Mark.blocked,
          depth: 1,
          note: entry.value.detail,
        );
        return;
      }
    }

    _printPlan(unit);
  }

  /// One line describing what is public today.
  String _liveSummary(ResolvedUnit unit, Map<String, Inspection> inspections) {
    final published = <String>[];
    for (final project in unit.projects) {
      final inspection = inspections[project.name];
      if (inspection == null) continue;
      if (inspection.isExact) {
        published.add('${project.version} published');
      }
    }
    if (published.isNotEmpty && published.toSet().length == 1) {
      return published.first;
    }
    return 'not published';
  }

  void _printPlan(ResolvedUnit unit) {
    final checklist = Checklist.derive(unit, resolution);
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
      } on Object {
        continue; // unreachable is reported by the inspection instead
      }
      final latest = published?.latest;
      if (latest == null) continue;
      if (latest.version > project.version) {
        problems.add(
          'RK-MONO-002',
          '${project.name} ${latest.version} is already published, and this '
              'would publish ${project.version}',
          source: SourceLocation(project.pubspec.path, project.pubspec.versionLine),
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
        '${git.uncommitted.length} files are uncommitted',
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
