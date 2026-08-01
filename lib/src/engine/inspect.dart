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

  final RegistryReader registry;
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
      }
      if (project.binaryPlatforms.isNotEmpty) expected.add('SHA256SUMS');
    }
    return expected;
  }

  Future<Inspection> inspect(Step step, ResolvedUnit unit) async {
    switch (step.kind) {
      case StepKind.tag:
        if (!git.hasTag(unit.tag)) return const Inspection.absent();
        // Where it points is part of the fact. The verdict stays exact — the
        // tag exists — and the cross-step judgment of whether its placement
        // endangers this release belongs to [tagGuards], which can see the
        // other steps.
        final target = git.tagTarget(unit.tag);
        if (target == null || target == git.head) {
          return const Inspection.exact(detail: 'already tagged');
        }
        return Inspection.exact(
          detail: 'already tagged, at ${_short(target)} — not HEAD',
        );

      case StepKind.prerequisite:
        return _prerequisite(step);

      case StepKind.publishRegistry:
        final project = unit.projects.firstWhere((p) => p.name == step.project);
        return registry.inspect(project.name, project.version);

      case StepKind.publishRelease:
        return _release(unit);

      case StepKind.publishFormula:
        // The tap is a repository rk has not been given a way to read here.
        // Saying so is the honest answer; saying `absent` would report a
        // formula that may already point at this release as work still to do.
        return const Inspection.unknown('the tap has not been read');

      case StepKind.build ||
            StepKind.sign ||
            StepKind.notarize ||
            StepKind.archive ||
            StepKind.checksums:
        return const Inspection.unknown('local work, decided when it runs');
    }
  }

  /// A package another unit publishes, which must already be live.
  Future<Inspection> _prerequisite(Step step) async {
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
      package = await registry.lookup(name);
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
    if (tools == null || repository == null) {
      return const Inspection.unknown('the forge has not been read');
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
    for (final project in unit.projects) {
      if (!project.channels.contains('pub.dev')) continue;
      final RegistryPackage? published;
      try {
        published = await registry.lookup(project.name);
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
    final tagStep = checklist.steps
        .where((s) => s.kind == StepKind.tag)
        .map((s) => states[s.id])
        .whereType<Inspection>()
        .firstOrNull;
    if (tagStep == null) return const [];

    final publishes = checklist.steps
        .where((s) => s.kind == StepKind.publishRegistry)
        .map((s) => states[s.id])
        .whereType<Inspection>()
        .toList();
    if (publishes.isEmpty) return const [];

    if (tagStep.isAbsent && publishes.every((s) => s.isExact)) {
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
              '  git push origin ${unit.tag}',
        ),
      ];
    }

    final target = git.tagTarget(unit.tag);
    if (tagStep.isExact &&
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
              '  git tag -f ${unit.tag} && git push -f origin ${unit.tag}',
        ),
      ];
    }
    return const [];
  }

  static String _short(String sha) =>
      sha.length > 12 ? sha.substring(0, 12) : sha;
}
