import 'dart:convert';

import '../destinations/github_release.dart';
import 'checklist.dart';
import 'git.dart';
import 'registry.dart';
import 'diagnostic.dart';
import 'resolve.dart';
import 'tools.dart';
import 'verdict.dart';
import 'version.dart';

/// Reads reality for one step, and nothing else.
///
/// One inspector rather than one per command. `status` is `release` without the
/// acting, so a second implementation would be a second set of answers to the
/// same question, and the two would drift — which they had: status inspected
/// channels project by project and never learned that a checklist has build,
/// sign and archive steps in it, while release answered `absent` by default for
/// every kind it did not name, asserting "definitely not there" about
/// destinations it had never asked.
///
/// It takes a step and returns a verdict. It holds no state between calls, acts
/// on nothing, and is the seam CI needs: an executable step is decided from the
/// checklist, its id, and destination reality (CI readiness, seam 1).
class Inspector {
  Inspector({
    required this.registry,
    required this.git,
    this.tools,
    this.repository,
  });

  /// Absent means the registry was not read — `--offline`, exactly like a
  /// null [tools] means the forge was not read. Null rather than a flag: a
  /// verb cannot then branch on a mode, so there is one rendering of one
  /// set of verdicts, and "not read" is a verdict like any other.
  final RegistryReader? registry;
  final GitState git;

  /// Needed to read the forge. Absent means the forge cannot be read, which is
  /// `unknown` — never `absent`.
  final Tools? tools;

  /// `owner/name`, when the repository has an origin to ask about.
  final String? repository;

  /// Whether this step's state lives somewhere rk can read without acting.
  ///
  /// Not [Step.isPublic], which says whether *acting* changes the world — the
  /// two differ on a prerequisite, which is read from pub.dev but performed by
  /// nobody. One name for both was how they got conflated.
  ///
  /// The rest — building, signing, notarizing, archiving — are local work
  /// whose results live in a workspace this run may not have. rk does not claim
  /// they are absent, because it has not looked, and a definite negative is
  /// what lets a release proceed.
  static bool hasPublicState(StepKind kind) => switch (kind) {
        StepKind.tag ||
        StepKind.prerequisite ||
        StepKind.publishRegistry ||
        StepKind.publishRelease ||
        StepKind.publishFormula =>
          true,
        _ => false,
      };

  /// Whether [state] stops a release of [step] before anything acts.
  ///
  /// One classification for both verbs. status computed readiness from its own
  /// rule and recommended `rk release` for a unit release would immediately
  /// refuse — the drift the shared inspector exists to prevent, one layer up.
  ///
  /// Local steps answer unknown by design — they are the work a run does — so
  /// unknown blocks only where the state was supposed to be readable. The one
  /// absence that blocks is a prerequisite: the other unit has not shipped,
  /// and publishing it and re-running is the fix.
  static bool blocks(Step step, Inspection state) => switch (state.verdict) {
        Verdict.conflict => true,
        Verdict.unknown => hasPublicState(step.kind),
        Verdict.absent => step.kind == StepKind.prerequisite,
        Verdict.exact => false,
      };

  /// The asset names a release of [unit] is expected to carry.
  ///
  /// Public and static so a test can hold the set itself to account: emptied,
  /// every release inspects exact, and nothing else notices.
  static Set<String> expectedAssets(ResolvedUnit unit) {
    final expected = <String>{};
    for (final project in unit.projects) {
      final executable = project.executable;
      if (executable == null) continue;
      for (final platform in project.binaryPlatforms) {
        expected.add('$executable-${project.version}-$platform.tar.gz');
        if (platform.startsWith('macos-')) {
          // Apple's verdict and its log are published evidence, so they are
          // expected — a release missing them is not what rk produces.
          expected
            ..add('$executable-${project.version}-$platform'
                '.notary-result.json')
            ..add('$executable-${project.version}-$platform.notary-log.json');
        }
      }
      if (project.channels.contains('homebrew')) {
        expected.add('$executable.rb');
      }
      if (project.binaryPlatforms.isNotEmpty) expected.add('SHA256SUMS');
    }
    return expected;
  }

  Future<Inspection> inspect(Step step, ResolvedUnit unit) async {
    switch (step.kind) {
      case StepKind.tag:
        return _tag(unit);

      case StepKind.prerequisite:
        return _prerequisite(step);

      case StepKind.publishRegistry:
        final project = unit.projects.firstWhere((p) => p.name == step.project);
        final reader = registry;
        if (reader == null) {
          return const Inspection.unknown('not read: --offline');
        }
        return reader.inspect(project.name, project.version);

      case StepKind.publishRelease:
        return _release(unit);

      case StepKind.publishFormula:
        return _formula(unit);

      case StepKind.build ||
            StepKind.sign ||
            StepKind.notarize ||
            StepKind.archive ||
            StepKind.checksums:
        return const Inspection.unknown('local work, decided when it runs');
    }
  }

  /// Local existence is half the fact; the other half is the remote.
  ///
  /// A push that died mid-process leaves a local tag nothing else can see,
  /// and inspecting only `git tag --list` read it as done — so the re-run
  /// skipped the step and completed the release with the tag absent from
  /// origin, silently. The step is done when origin lists it; a local-only
  /// tag is work remaining (the act pushes it), and a remote rk cannot read
  /// is unknown, which blocks rather than permits.
  Future<Inspection> _tag(ResolvedUnit unit) async {
    if (!git.hasTag(unit.tag)) return const Inspection.absent();

    final target = git.tagTarget(unit.tag);
    final placement = target == null || target == git.head
        ? ''
        : ', at ${_short(target)} — HEAD has moved on, expected';

    if (tools == null) {
      // Nothing to ask the remote with: say exactly how much is known.
      return Inspection.exact(detail: 'already tagged locally$placement');
    }

    final remote = await tools!.run(
      'git',
      ['ls-remote', 'origin', 'refs/tags/${unit.tag}'],
      workingDirectory: git.root,
    );
    if (!remote.ok) {
      return Inspection.unknown(
        'the tag exists locally and origin could not be read: '
        '${remote.summary}',
      );
    }
    if (!remote.stdout.contains('refs/tags/${unit.tag}')) {
      return Inspection.absent(
        detail: 'exists locally, not on origin — acting pushes it',
      );
    }
    return Inspection.exact(detail: 'already tagged, pushed$placement');
  }

  /// A package another unit publishes, which must already be live.
  Future<Inspection> _prerequisite(Step step) async {
    if (registry == null) {
      return const Inspection.unknown('not read: --offline');
    }
    // The coordinate is carried by the step so nothing here has to know how an
    // id is spelled: `pub.dev/<package>/<version>`.
    final parts = step.coordinate!.split('/');
    if (parts.length < 3) {
      return const Inspection.unknown('the prerequisite could not be read');
    }
    final name = parts[parts.length - 2];
    final version = parts.last;

    final RegistryPackage? package;
    try {
      package = await registry!.lookup(name);
    } on RegistryUnavailable catch (error) {
      return Inspection.unknown(error.message);
    }
    if (package == null) {
      return Inspection.absent(detail: '$name has never been published');
    }

    final live = package.versions.any((v) => v.version.canonical == version);
    return live
        ? const Inspection.exact(detail: 'live')
        // Absent, not conflict: it is not published *yet*, and publishing it
        // and re-running is exactly the fix. A conflict would halt saying this
        // cannot be fixed by re-running, which is the opposite of true.
        : Inspection.absent(detail: '$name $version is not published yet');
  }

  Future<Inspection> _release(ResolvedUnit unit) async {
    // Two different reasons rk cannot answer, each said as itself: offline
    // was asked for, while a missing origin is a fact about the repository
    // the reader can change.
    if (tools == null) {
      return const Inspection.unknown('not read: --offline');
    }
    if (repository == null) {
      return const Inspection.unknown('no origin remote to ask');
    }
    final expected = expectedAssets(unit);

    return GithubRelease(
      tools: tools!,
      repository: repository!,
      workingDirectory: git.root,
    ).inspect(unit.tag, expected);
  }

  /// A version must exceed everything already published, and a tag must
  /// exceed every earlier tag in its namespace.
  ///
  /// Here rather than in a command: the registry half is the tool's top-ranked
  /// failure — publishing a back-version is permanent — and it was implemented
  /// only in status, the verb that does not act. Both verbs call this now, and
  /// release calls it as part of validating independently rather than
  /// trusting status.
  Future<void> monotonicity(ResolvedUnit unit, Diagnostics problems) async {
    // Nothing to be monotonic against when the registry was not read.
    if (registry == null) return;
    for (final project in unit.projects) {
      if (!project.channels.contains('pub.dev')) continue;
      final RegistryPackage? published;
      try {
        published = await registry!.lookup(project.name);
      } on RegistryUnavailable {
        continue; // the step's own inspection reports this, with a remedy
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

  /// The tap's formula, read from the public repository the same way a
  /// user's `brew install` reads it.
  ///
  /// Exactness here is the version pointer, not bytes: the formula's sha256
  /// values are digests of assets this run may not have built yet, so byte
  /// equality is only checkable by the act (which compares before pushing)
  /// and by `verify` after the fact. A formula naming an earlier version is
  /// `absent` — moving it forward is exactly the work the step does.
  Future<Inspection> _formula(ResolvedUnit unit) async {
    if (tools == null) {
      return const Inspection.unknown('not read: --offline');
    }
    if (repository == null) {
      return const Inspection.unknown('no origin remote to ask');
    }
    // Per unit: a tap is where this unit's formula goes, and a repository
    // with two binary units can point them at two taps.
    final tapRepo =
        unit.homebrewTap ?? '${repository!.split('/').first}/homebrew-tap';
    final project = unit.projects.firstWhere((p) => p.config.wantsBinaries);
    final executable = project.executable!;

    final result = await tools!.run(
      'gh',
      ['api', 'repos/$tapRepo/contents/Formula/$executable.rb'],
    );
    if (!result.ok) {
      if (result.summary.contains('(HTTP 404)')) {
        // The same 404 discipline as the forge: GitHub answers 404 for a
        // repository the token cannot see, so a missing formula is only
        // concluded once the tap has answered for itself.
        final readable = await tools!.run(
          'gh',
          ['repo', 'view', tapRepo, '--json', 'name'],
        );
        return readable.ok
            ? const Inspection.absent(detail: 'no formula in the tap yet')
            : Inspection.unknown(
                'the tap $tapRepo could not be read, so rk cannot tell '
                'what users install',
              );
      }
      return Inspection.unknown('the tap could not be read: ${result.summary}');
    }

    try {
      final decoded = jsonDecode(result.stdout);
      final content = decoded is Map ? decoded['content'] : null;
      if (content is! String) {
        return const Inspection.unknown(
            'the tap answered something unreadable');
      }
      final text =
          utf8.decode(base64Decode(content.replaceAll(RegExp(r'\s'), '')));
      return text.contains('version "${unit.version}"')
          ? Inspection.exact(detail: 'points at ${unit.version}')
          : const Inspection.absent(detail: 'points at an earlier release');
    } on Object {
      return const Inspection.unknown('the tap answered something unreadable');
    }
  }

  /// Cross-step judgments about the tag, which no single step can make.
  ///
  /// Two hazards, both provenance lies:
  ///
  /// - The version is fully published and the tag does not exist. Minting it
  ///   now would bind the published version to whatever HEAD happens to be,
  ///   which is not the commit that produced it. rk refuses and instructs —
  ///   the operator knows which commit released it; rk cannot.
  /// - The tag exists at another commit while registry work remains. Acting
  ///   would publish HEAD's content under a name that points somewhere else.
  List<Diagnostic> tagGuards(
    ResolvedUnit unit,
    Checklist checklist,
    Map<String, Inspection> states,
  ) {
    if (!checklist.steps.any((s) => s.kind == StepKind.tag)) return const [];

    final publishes = checklist.steps
        .where((s) => s.kind == StepKind.publishRegistry)
        .map((s) => states[s.id])
        .whereType<Inspection>()
        .toList();
    if (publishes.isEmpty) return const [];

    // Both guards read git directly rather than the step's verdict: the
    // verdict now folds in the remote, and a local-but-unpushed tag reads
    // absent — which is work (push it), not the no-tag-at-all case the
    // retro-tag guard exists for, and not exempt from the placement check.
    if (!git.hasTag(unit.tag) && publishes.every((s) => s.isExact)) {
      return [
        Diagnostic(
          code: 'RK-GIT-004',
          message: '${unit.version} is already published, and the tag '
              '${unit.tag} does not exist',
          remedy: 'rk will not mint it after the fact — that would bind the '
              'published version to whatever HEAD is now, not to the commit '
              'that produced it. Tag it yourself, at that commit:\n'
              '  git tag ${unit.tag} <the commit that released '
              '${unit.version}>\n'
              '  git push origin ${unit.tag}\n'
              'find it: git log --oneline -S "version: ${unit.version}" '
              '-- ${unit.projects.first.pubspec.directory}/pubspec.yaml — '
              'and prove a candidate before pushing: '
              'rk verify ${unit.name} --at=<sha>',
        ),
      ];
    }

    final target = git.tagTarget(unit.tag);
    if (git.hasTag(unit.tag) &&
        target != null &&
        target != git.head &&
        publishes.any((s) => s.isAbsent)) {
      return [
        Diagnostic(
          code: 'RK-GIT-005',
          message: 'the tag ${unit.tag} points at ${_short(target)}, and this '
              'release would publish from ${_short(git.head)}',
          remedy: 'what would be published is not what the tag names. Move '
              'the tag deliberately, or check out the tagged commit:\n'
              '  git tag -sf ${unit.tag} && git push -f origin ${unit.tag}',
        ),
      ];
    }
    return const [];
  }

  static String _short(String sha) =>
      sha.length > 12 ? sha.substring(0, 12) : sha;
}
