import '../engine/compare.dart';
import '../engine/diagnostic.dart';
import '../engine/output.dart';
import '../engine/pubspec.dart';
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

    if (at != null && only == null && units.length > 1) {
      // One ref cannot honestly name several units' releases: applying it to
      // all of them proves each against a tag that released at most one.
      output.problem(
        Diagnostic(
          code: 'RK-CLI-006',
          message: '--at names one release, and this repository has '
              '${units.length} units',
          remedy: 'say which unit the ref belongs to: '
              'rk verify <unit> --at=$at',
        ),
      );
      return ExitCodes.usage;
    }

    var failed = false;
    for (final unit in units) {
      failed = !await _unit(unit) || failed;
    }

    // The tally, computed from the recorded verifications themselves — one
    // line answering "so, overall?", incapable of disagreeing with the rows.
    final all = output.report.verifications;
    final proved = all.where((v) => v['verdict'] == 'exact').length;
    final disclosed = all.where((v) => v['counts'] == false).length;
    final unprovable = all.length - proved - disclosed;
    if (all.isNotEmpty) {
      output.blank();
      output.line(
        [
          '$proved proved',
          if (unprovable > 0) '$unprovable not proved',
          if (disclosed > 0) '$disclosed not examined',
        ].join(' · '),
        mark: failed ? Mark.blocked : Mark.done,
      );
    }
    return failed ? ExitCodes.refused : ExitCodes.ok;
  }

  Future<bool> _unit(ResolvedUnit unit) async {
    final ref = at ?? unit.tag;
    output.unit(unit.name, version: unit.version.canonical, tag: ref);

    final registryProjects =
        unit.projects.where((p) => p.channels.contains('pub.dev')).toList();

    // What this command does not examine is said, on both surfaces — a unit
    // that publishes to three channels must not print one bare check mark.
    // Said as a disclosure, not a failure: nothing below claims these were
    // proved, so nothing upgrades unknown to a pass, and nothing that *was*
    // proved is failed for the disclosure's sake.
    final unexamined = {
      for (final project in unit.projects)
        ...project.channels.where((c) => c != 'pub.dev'),
    };
    if (unexamined.isNotEmpty) {
      output.verification(
        unit.name,
        unexamined.join(', '),
        verdict: Verdict.unknown,
        detail: 'not examined — rk cannot verify binary channels yet',
        counts: false,
      );
    }

    if (registryProjects.isEmpty) {
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
    // not for today. Read through the same parser everything else uses: a
    // hand-rolled second reader disagreed with it on quoted versions and
    // trailing comments, and concluded "not published" about a version that
    // was — the definite negative this tool exists to never state.
    final directory = project.pubspec.directory;
    final manifestPath =
        directory == '.' ? 'pubspec.yaml' : '$directory/pubspec.yaml';
    final manifest = tree.read(manifestPath);
    final atRef = manifest == null
        ? null
        : Pubspec.parse(manifest, manifestPath, Diagnostics())
            ?.version
            ?.canonical;
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
        unit: unit.name,
        depth: 1,
      );
      output.report.rerunHelps = false;
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

    final id = '${unit.name}/pub.dev/${project.name}@$atRef';
    switch (comparison.verdict) {
      case Verdict.exact:
        output.verification(
          unit.name,
          '${project.name} $atRef',
          id: id,
          verdict: Verdict.exact,
          detail: '${comparison.detail} against $ref'
              '${published.published == null ? '' : ' · published '
                  '${published.published!.toIso8601String().split('T').first}'}',
        );
        return true;
      case Verdict.unknown:
        // Honestly partial is not proven: the exit says so, the problem says
        // why, and re-running will not change it — the .pubignore is part of
        // the package.
        output.verification(
          unit.name,
          '${project.name} $atRef',
          id: id,
          verdict: Verdict.unknown,
          detail: comparison.detail,
        );
        output.problem(
          Diagnostic(
            code: 'RK-VER-005',
            message: '${project.name} $atRef could not be fully proved',
            remedy: comparison.detail,
          ),
          unit: unit.name,
          depth: 1,
        );
        output.report.rerunHelps = false;
        return false;
      case Verdict.conflict || Verdict.absent:
        output.verification(
          unit.name,
          '${project.name} $atRef',
          id: id,
          verdict: Verdict.conflict,
          detail: comparison.detail,
          evidence: comparison.evidence,
        );
        // Terminal, and said as data: an agent keying on rerun_helps or
        // problems must not read "retry" out of the one finding rk itself
        // calls unfixable. This is the phase 3 finding — a halt that was
        // prose-only under --json — kept out of the new verb.
        output.problem(
          Diagnostic(
            code: 'RK-VER-006',
            message: '${project.name} $atRef: '
                '${comparison.detail ?? 'differs from the source'}',
            remedy: 'what is published is public and cannot be edited. If '
                'this difference is not yours, treat it as an incident; if '
                'it is, the only way forward is the next version.',
          ),
          unit: unit.name,
          depth: 1,
        );
        output.report.rerunHelps = false;
        return false;
    }
  }
}
