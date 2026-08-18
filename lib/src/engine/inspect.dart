import '../targets/catalog.dart';
import '../targets/target_module.dart';
import 'assets.dart';
import 'checklist.dart';
import 'diagnostic.dart';
import 'git.dart';
import 'publish_target.dart';
import 'registry.dart';
import 'resolve.dart';
import 'release_stage.dart';
import 'targets.dart';
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
    this.pubDev,
    this.tools,
    this.repository,
    this.stageFor,
    TargetCatalog? targets,
  }) : targets = targets ?? TargetCatalog.builtIn();

  /// Null means no reader was configured — narrow destination tests — and
  /// answers `unknown`, never `absent`: not looking is not a negative.
  final RegistryReader? registry;
  final PublicationInspector? pubDev;
  final GitState git;

  /// Needed to read the forge. Absent means the forge cannot be read, which is
  /// `unknown` — never `absent`.
  final Tools? tools;

  /// `owner/name`, when the repository has an origin to ask about.
  final String? repository;

  /// Resolves the one content-addressed stage both verbs inspect. Null keeps
  /// the engine usable in narrow destination tests that have no filesystem.
  final ReleaseStage Function(ResolvedUnit unit)? stageFor;

  /// The one closed target catalog shared by status and release.
  final TargetCatalog targets;

  /// The read-only dependencies every target receives.
  TargetReadContext get targetReads => TargetReadContext(
        registry: registry,
        pubDev: pubDev,
        git: git,
        tools: tools,
        repository: repository,
        stageFor: stageFor,
      );

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
  static bool hasPublicState(StepKind kind) =>
      kind.isPublic || kind == StepKind.prerequisite;

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
  static Set<String> expectedAssets(ResolvedUnit unit) =>
      ReleaseAssets.expectedForUnit(unit).toSet();

  Future<Inspection> inspect(Step step, ResolvedUnit unit) async {
    final module = targets.moduleForStep(step);
    if (module != null) {
      final target = module.expectation(
        unit: unit,
        step: step,
        repository: repository,
      );
      return module.inspectExact(targetReads, unit, target);
    }
    if (step.kind == StepKind.prerequisite) {
      return _prerequisite(step);
    }
    if (step.kind == StepKind.completeStage) {
      return _stageInspection(unit);
    }
    if (step.kind
        case StepKind.resolve ||
            StepKind.build ||
            StepKind.notarize ||
            StepKind.archive) {
      return targetReads.reusableStage(unit) == null
          ? const Inspection.unknown('local work, decided when it runs')
          : const Inspection.exact(detail: 'validated in the release stage');
    }
    throw StateError('no inspector for ${step.kind.name}');
  }

  /// The newest public version visible in one configured target lane.
  ///
  /// This is status metadata, not a substitute for inspecting the exact
  /// candidate coordinate. The candidate answers whether acting is needed;
  /// this answers the separate operator question, "what is this lane at?"
  Future<Inspection?> inspectLatestVersion(
    TargetExpectation target,
    ResolvedUnit unit,
  ) =>
      targets.moduleForTarget(target).inspectLatest(targetReads, unit, target);

  Inspection _stageInspection(ResolvedUnit unit) {
    final factory = stageFor;
    if (factory == null) {
      return const Inspection.absent(detail: 'not staged');
    }
    try {
      return factory(unit).inspect().asInspection;
    } on Object catch (error) {
      return Inspection.unknown('the release stage could not be read: $error');
    }
  }

  /// A package another unit publishes, which must already be live.
  Future<Inspection> _prerequisite(Step step) async {
    if (registry == null) {
      return const Inspection.unknown('the registry reader is not configured');
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

  /// A version must exceed everything already published, and a tag must
  /// exceed every earlier tag in its namespace.
  ///
  /// Here rather than in a command: the registry half is the tool's top-ranked
  /// failure — publishing a back-version is permanent — and it was implemented
  /// only in status, the verb that does not act. Both verbs call this now, and
  /// release calls it as part of validating independently rather than
  /// trusting status.
  Future<void> monotonicity(ResolvedUnit unit, Diagnostics problems) async {
    for (final module in targets.modules) {
      if (module.stepKind == StepKind.tag &&
          !unit.publish.contains(PublishTarget.gitTag)) {
        continue;
      }
      module
          .localReleaseDiagnostics(targetReads, unit)
          .forEach(problems.report);
    }
  }

  /// The release-only monotonicity gate against every configured public lane.
  ///
  /// Exact-coordinate inspection answers whether this version exists. It
  /// cannot answer whether a newer version exists elsewhere in the same lane:
  /// a shallow checkout can truthfully find `v1.0.0` absent while origin is
  /// already at `v2.0.0`. Release calls this before private production and
  /// again immediately before authorization.
  ///
  /// Targets decide whether their latest-version read is a meaningful guard.
  /// Homebrew, for example, authenticates its public cask bytes during its
  /// exact inspection and therefore declines a second, weaker version read.
  Future<bool> releaseMonotonicity(
    ResolvedUnit unit,
    Iterable<TargetExpectation> targets,
    Diagnostics problems, {
    bool refreshRegistry = false,
  }) async {
    final localTagProblems = Diagnostics();
    if (unit.publish.contains(PublishTarget.gitTag)) {
      for (final module in this
          .targets
          .modules
          .where((item) => item.stepKind == StepKind.tag)) {
        module
            .localReleaseDiagnostics(targetReads, unit)
            .forEach(localTagProblems.report);
      }
    }

    final candidates = <TargetExpectation>[];
    final seen = <String>{};
    for (final target in targets) {
      final key = '${target.kind}\u0000${target.coordinate}';
      if (seen.add(key)) candidates.add(target);
    }

    if (refreshRegistry) {
      for (final target in candidates) {
        this.targets.moduleForTarget(target).invalidate(targetReads, target);
      }
    }

    // Start every independent provider read before awaiting one. A slow
    // forge must not postpone asking origin or pub.dev.
    final reads = [
      for (final target in candidates)
        () async {
          try {
            return await inspectLatestVersion(target, unit);
          } on Object catch (error) {
            return Inspection.unknown(
              'the latest public version could not be read: $error',
            );
          }
        }(),
    ];
    final latest = await Future.wait(reads);

    var remoteTagAhead = false;
    var readIndependentHistory = false;
    for (final (index, target) in candidates.indexed) {
      final inspection = latest[index];
      if (inspection == null) continue;
      readIndependentHistory = true;
      if (inspection.isAbsent) continue;
      if (!inspection.isExact) {
        final module = this.targets.moduleForTarget(target);
        final diagnostic =
            module.diagnosticForInspection(unit, target, inspection);
        if (diagnostic != null) {
          problems.report(diagnostic);
          continue;
        }
        problems.add(
          'RK-REL-001',
          '${target.label}: ${inspection.detail ?? 'the latest public '
              'version could not be read'}',
          remedy: 'restore read access to ${target.label} and re-run; rk '
              'will not publish against an unknown public history',
        );
        continue;
      }

      final raw = inspection.evidence['version'];
      final version = raw == null ? null : Version.tryParse(raw);
      if (version == null) {
        problems.add(
          'RK-REL-001',
          '${target.label}: the latest public version response carried no '
              'semantic version',
          remedy: 'restore a readable version listing for ${target.label} '
              'and re-run',
        );
        continue;
      }

      final targetVersion = Version.tryParse(target.targetVersion)!;
      if (version <= targetVersion) continue;
      final module = this.targets.moduleForTarget(target);
      if (module.publicHistorySupersedesLocalTag) remoteTagAhead = true;
      final diagnostic = module.aheadDiagnostic(unit, target, version);
      if (diagnostic != null) problems.report(diagnostic);
    }

    // The public lane is the stronger fact. Do not tell the operator twice
    // about the same ahead tag merely because it is also present locally.
    if (!remoteTagAhead) {
      localTagProblems.found.forEach(problems.report);
    }
    return readIndependentHistory;
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
    if (!unit.publish.contains(PublishTarget.gitTag)) return const [];
    if (!checklist.steps.any((s) => s.kind == StepKind.tag)) return const [];
    final tag = unit.tag;
    if (tag == null) {
      throw StateError('a selected git-tag target has no resolved tag');
    }

    final publishes = checklist.steps
        .where((step) => step.isPermanent)
        .map((s) => states[s.id])
        .whereType<Inspection>()
        .toList();
    if (publishes.isEmpty) return const [];

    // Both guards read git directly rather than the step's verdict: the
    // verdict now folds in the remote, and a local-but-unpushed tag reads
    // absent — which is work (push it), not the no-tag-at-all case the
    // retro-tag guard exists for, and not exempt from the placement check.
    if (!git.hasTag(tag) && publishes.every((s) => s.isExact)) {
      return [
        Diagnostic(
          code: 'RK-GIT-004',
          message: '${unit.version} is already published, and the tag '
              '$tag does not exist',
          remedy: 'rk will not mint it after the fact — that would bind the '
              'published version to whatever HEAD is now, not to the commit '
              'that produced it. Tag it yourself, at that commit:\n'
              '  git tag $tag <the commit that released '
              '${unit.version}>\n'
              '  git push origin $tag\n'
              'find it: git log --oneline -S "version: ${unit.version}" '
              '-- ${unit.projects.first.pubspec.directory}/pubspec.yaml — '
              'then check out the candidate and run rk status ${unit.name} '
              'before pushing the tag',
        ),
      ];
    }

    final target = git.tagTarget(tag);

    // Unread is not agreement. `tagTargets`' own docstring says so — "callers
    // treat as placement unknown, never as agreement" — and both callers
    // broke the contract by folding null into "at HEAD, nothing to say".
    //
    // One unreachable tag object anywhere in the repository empties the whole
    // map (`git show-ref --tags -d` fails whole, and the failure is
    // swallowed), so this is reachable without any tag rk cares about being
    // broken. The consequence is the guard below going *silent*: rk reports
    // ready, `problems` is empty, all three clauses of the blessed CI gate
    // rule pass, and the release pushes the tag and publishes the version —
    // from a commit the tag does not name. A burned pub.dev version is the
    // one outcome re-running cannot fix.
    if (git.hasTag(tag) && target == null && publishes.any((s) => s.isAbsent)) {
      return [
        Diagnostic(
          code: 'RK-GIT-007',
          message: 'the tag $tag exists, and rk could not read which '
              'commit it names',
          remedy: 'rk proves the tag names the commit it is about to publish '
              'from, and it cannot prove that here — so it will not publish. '
              'One unreachable tag object breaks the read for every tag:\n'
              '  git show-ref --tags -d   (must exit 0)\n'
              '  git fsck --tags          (names what is unreachable)',
        ),
      ];
    }

    if (git.hasTag(tag) &&
        target != null &&
        target != git.head &&
        publishes.any((s) => s.isAbsent)) {
      return [
        Diagnostic(
          code: 'RK-GIT-005',
          message: 'the tag $tag points at ${_short(target)}, and this '
              'release would publish from ${_short(git.head)}',
          remedy: 'what would be published is not what the tag names. Move '
              'the tag deliberately, or check out the tagged commit:\n'
              '  git tag -sf $tag && git push -f origin $tag',
        ),
      ];
    }
    return const [];
  }

  static String _short(String sha) =>
      sha.length > 12 ? sha.substring(0, 12) : sha;
}
