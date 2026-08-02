import '../engine/compare.dart';
import '../engine/diagnostic.dart';
import '../engine/output.dart';
import '../engine/registry.dart';
import '../engine/resolve.dart';
import '../engine/source_tree.dart';
import '../engine/verdict.dart';

/// Proves a published release against the source its tag names.
///
/// Anyone with a fresh clone can run it, at any later date: it reads the
/// registry, git's object store, and nothing else. No credentials, no `.rk/`,
/// no state — that property is the point, and it is why this command can be
/// somebody else's audit and not only rk's own check.
///
/// What it proves is byte identity: the archive the registry serves for the
/// version, against the tree at the tag, in both directions, through the one
/// [Comparator] the release verbs also use. What it cannot know, it says —
/// a version with no tag has no commit to bind to, and rk does not pretend
/// otherwise.
class VerifyCommand {
  VerifyCommand({
    required this.resolution,
    required this.registry,
    required this.comparator,
    required this.treeAt,
    required this.output,
    this.at,
  });

  final Resolution resolution;
  final RegistryReader registry;
  final Comparator comparator;

  /// The repository at a ref, or null when the ref does not resolve.
  ///
  /// A seam rather than a call to git, so the command is provable against
  /// memory trees; `bin/rk.dart` passes `GitTreeAtRef.at`.
  final SourceTree? Function(String ref) treeAt;

  final Output output;

  /// A ref overriding the derived tag — `--at=v0.1.0` — for a release made
  /// under an older tag scheme than today's configuration derives.
  final String? at;

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

    var failed = false;
    for (final unit in units) {
      failed = !await _unit(unit) || failed;
    }
    return failed ? ExitCodes.refused : ExitCodes.ok;
  }

  Future<bool> _unit(ResolvedUnit unit) async {
    final ref = at ?? unit.tag;
    output.unit(unit.name, version: unit.version.canonical, tag: ref);

    final registryProjects =
        unit.projects.where((p) => p.channels.contains('pub.dev')).toList();
    if (registryProjects.isEmpty) {
      output.line(
        'nothing on pub.dev to verify — binary channels are proved by '
        'their own release assets',
        depth: 1,
      );
      return true;
    }

    final tree = treeAt(ref);
    if (tree == null) {
      output.problem(
        Diagnostic(
          code: 'RK-VER-001',
          message: 'the ref $ref does not exist, so there is no source to '
              'prove the published version against',
          remedy: at == null
              ? 'nothing binds the published version to a commit — no tag '
                  'records it. If it was released under an older tag scheme, '
                  'name that tag: rk verify ${unit.name} --at=<ref>'
              : 'check the ref passed with --at',
        ),
        depth: 1,
      );
      return false;
    }

    var verified = true;
    for (final project in registryProjects) {
      verified = await _project(unit, project, tree, ref) && verified;
    }
    return verified;
  }

  Future<bool> _project(
    ResolvedUnit unit,
    ResolvedProject project,
    SourceTree tree,
    String ref,
  ) async {
    // The version under proof is the one the ref's own manifest claims — the
    // working tree may have moved on, and verify answers for the release,
    // not for today.
    final directory = project.pubspec.directory;
    final manifest = tree.read(
      directory == '.' ? 'pubspec.yaml' : '$directory/pubspec.yaml',
    );
    final atRef = manifest == null
        ? null
        : RegExp(r'^version:\s*(\S+)\s*$', multiLine: true)
            .firstMatch(manifest)
            ?.group(1);
    if (atRef == null) {
      output.problem(
        Diagnostic(
          code: 'RK-VER-002',
          message: '${project.name} has no readable version at $ref',
          remedy: 'the manifest at the ref is missing or declares no version '
              '— was this package at "$directory" then?',
        ),
        depth: 1,
      );
      return false;
    }

    final RegistryPackage? package;
    try {
      package = await registry.lookup(project.name);
    } on RegistryUnavailable catch (error) {
      output.problem(
        Diagnostic(
          code: 'RK-REG-001',
          message: '${project.name}: ${error.message}',
          remedy: 'rk cannot prove anything against a registry it could not '
              'read — try again',
        ),
        depth: 1,
      );
      return false;
    }

    final published = package?.versions
        .where((v) => v.version.canonical == atRef)
        .firstOrNull;
    if (published == null) {
      output.problem(
        Diagnostic(
          code: 'RK-VER-003',
          message: '${project.name} $atRef is not on pub.dev, so there is '
              'nothing to verify',
          remedy: package == null
              ? 'the package has never been published'
              : 'published: '
                  '${package.versions.map((v) => v.version).join(', ')}',
        ),
        depth: 1,
      );
      return false;
    }

    final List<int> archive;
    try {
      archive = await registry.archive(published);
    } on ArchiveTampered catch (tampered) {
      output.problem(
        Diagnostic(
          code: 'RK-VER-004',
          message: '${project.name} $atRef: $tampered',
          remedy: 'stop and look — retrying will not change what the '
              'registry serves',
        ),
        depth: 1,
      );
      return false;
    } on RegistryUnavailable catch (error) {
      output.problem(
        Diagnostic(
          code: 'RK-REG-001',
          message: '${project.name}: ${error.message}',
          remedy: 'try again',
        ),
        depth: 1,
      );
      return false;
    }

    final comparison = await comparator.compare(
      archive: archive,
      tree: tree,
      packageDirectory: directory,
    );

    switch (comparison.verdict) {
      case Verdict.exact:
        output.verification(
          unit.name,
          '${project.name} $atRef',
          verdict: Verdict.exact,
          detail: '${comparison.detail} against $ref'
              '${published.published == null ? '' : ' · published '
                  '${published.published!.toIso8601String().split('T').first}'}',
        );
        return true;
      case Verdict.unknown:
        // Honestly partial is not proven: the exit says so, the detail says
        // why, and nothing upgrades it to a pass.
        output.verification(
          unit.name,
          '${project.name} $atRef',
          verdict: Verdict.unknown,
          detail: comparison.detail,
        );
        return false;
      case Verdict.conflict || Verdict.absent:
        output.verification(
          unit.name,
          '${project.name} $atRef',
          verdict: Verdict.conflict,
          detail: comparison.detail,
          evidence: comparison.evidence,
        );
        output.say(
          'what is published is public and cannot be edited. If this '
          'difference is not yours, treat it as an incident; if it is, the '
          'only way forward is the next version.',
          depth: 1,
        );
        return false;
    }
  }
}
