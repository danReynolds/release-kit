import 'dart:io';

import '../destinations/homebrew.dart';
import '../destinations/git_tag.dart';
import '../destinations/github_release.dart';
import '../destinations/pub_dev.dart';
import 'assets.dart';
import 'changelog.dart';
import 'checklist.dart';
import 'git.dart';
import 'registry.dart';
import 'diagnostic.dart';
import 'resolve.dart';
import 'release_stage.dart';
import 'source_tree.dart';
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
    PubDevInspector? pubDev,
    this.tools,
    this.repository,
    this.stageFor,
  }) : pubDev = pubDev ??
            (registry is PubDevInspector ? registry as PubDevInspector : null);

  /// Absent means the registry was not read — `--offline`, exactly like a
  /// null [tools] means the forge was not read. Null rather than a flag: a
  /// verb cannot then branch on a mode, so there is one rendering of one
  /// set of verdicts, and "not read" is a verdict like any other.
  final RegistryReader? registry;
  final PubDevInspector? pubDev;
  final GitState git;

  /// Needed to read the forge. Absent means the forge cannot be read, which is
  /// `unknown` — never `absent`.
  final Tools? tools;

  /// `owner/name`, when the repository has an origin to ask about.
  final String? repository;

  /// Resolves the one content-addressed stage both verbs inspect. Null keeps
  /// the engine usable in narrow destination tests that have no filesystem.
  final ReleaseStage Function(ResolvedUnit unit)? stageFor;

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
  static Set<String> expectedAssets(ResolvedUnit unit) => {
        for (final project in unit.projects)
          ...ReleaseAssets.expectedFor(project),
      };

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
        final exact = pubDev;
        if (exact == null) {
          return const Inspection.unknown(
            'the exact pub.dev inspector was not configured',
          );
        }
        final stage = _reusableStage(unit);
        return exact.inspectProject(
          project,
          expectedSource:
              stage == null ? null : SnapshotSourceTree(stage.sourceRoot),
        );

      case StepKind.publishRelease:
        return _release(unit);

      case StepKind.publishFormula:
        return _formula(unit);

      case StepKind.completeStage:
        return _stageInspection(unit);

      case StepKind.build ||
            StepKind.sign ||
            StepKind.notarize ||
            StepKind.archive ||
            StepKind.checksums:
        return _reusableStage(unit) == null
            ? const Inspection.unknown('local work, decided when it runs')
            : const Inspection.exact(detail: 'validated in the release stage');
    }
  }

  /// The newest public version visible in one configured target lane.
  ///
  /// This is status metadata, not a substitute for inspecting the exact
  /// candidate coordinate. The candidate answers whether acting is needed;
  /// this answers the separate operator question, "what is this lane at?"
  Future<Inspection> inspectLatestVersion(
    TargetExpectation target,
    ResolvedUnit unit,
  ) async {
    switch (target.kind) {
      case ReleaseTargetKind.pubDev:
        final reader = registry;
        if (reader == null) {
          return const Inspection.unknown('not read: --offline');
        }
        try {
          final package = await reader.lookup(target.coordinate);
          final latest = package?.latest;
          return latest == null
              ? const Inspection.absent(
                  detail: 'no published package version',
                )
              : Inspection.exact(
                  detail: 'latest published package is ${latest.version}',
                  evidence: {'version': latest.version.canonical},
                );
        } on Object catch (error) {
          return Inspection.unknown(
            'the latest pub.dev version could not be read: $error',
          );
        }

      case ReleaseTargetKind.gitTag:
        if (tools == null) {
          return const Inspection.unknown('origin was not read: --offline');
        }
        return GitTag(tools: tools!, root: git.root)
            .inspectLatestVersion(unit.tagPattern);

      case ReleaseTargetKind.githubRelease:
        if (tools == null) {
          return const Inspection.unknown('not read: --offline');
        }
        if (repository == null) {
          return const Inspection.unknown('no origin remote to ask');
        }
        return GithubRelease(
          tools: tools!,
          repository: repository!,
          workingDirectory: git.root,
        ).inspectLatestVersion(unit.tagPattern);

      case ReleaseTargetKind.homebrew:
        // Formula inspection parses and authenticates the public bytes and
        // carries their version in its own evidence. Reading the tap twice
        // would add latency without adding a stronger fact.
        return const Inspection.unknown(
          'the formula inspection owns the current version',
        );
    }
  }

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

  ReleaseStage? _reusableStage(ResolvedUnit unit) {
    final factory = stageFor;
    if (factory == null) return null;
    try {
      final stage = factory(unit);
      return stage.inspect().reusable ? stage : null;
    } on Object {
      return null;
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
    if (tools == null) {
      return Inspection.unknown(
        git.hasTag(unit.tag)
            ? 'the tag exists locally; origin was not read: --offline'
            : 'origin was not read: --offline',
      );
    }
    final target = GitTag(tools: tools!, root: git.root);
    final stage = _reusableStage(unit);
    String? manifestSha256;
    if (stage != null) {
      try {
        final manifest = stage.requireReceipt().artifacts.singleWhere(
              (artifact) => artifact.path == ReleaseAssets.manifest,
            );
        manifestSha256 = manifest.sha256;
      } on Object catch (error) {
        return Inspection.unknown(
          'the expected release tag binding could not be read: $error',
        );
      }
    }

    // The public tag must be a release record, not merely a ref at HEAD. A
    // reusable stage supplies the exact expected manifest; without one, one
    // structurally valid binding and the configured signature are still
    // required. This stateless remote read remains authoritative immediately
    // after rk creates a tag, when this Inspector's GitState snapshot cannot
    // yet contain its local object id.
    final remote = await target.inspectReleaseBinding(
      tag: unit.tag,
      expectedCommit: git.head,
      expectedManifestSha256: manifestSha256,
      requireSignature: git.signingConfigured,
    );
    if (!remote.isAbsent || !git.hasTag(unit.tag)) return remote;

    // A pre-existing local tag is the bytes `_tag` will push. Validate that
    // input while the destination is still absent, so a malformed lightweight,
    // wrong-manifest, or bad-signature tag is refused before authorization.
    final commit = git.tagTarget(unit.tag);
    if (commit == null) {
      return const Inspection.unknown(
        'could not read the expected local tag commit',
      );
    }
    final object = git.tagObject(unit.tag);
    if (object == null) {
      return const Inspection.unknown(
        'could not read the expected local tag object',
      );
    }
    if (commit.toLowerCase() != git.head.toLowerCase()) {
      return Inspection.conflict(
        'the local release tag points at a different source commit',
        evidence: {
          'source commit': 'local $commit, expected ${git.head}',
        },
      );
    }
    final local = await target.inspectLocalReleaseBinding(
      tag: unit.tag,
      expectedObject: object,
      expectedCommit: commit,
      expectedManifestSha256: manifestSha256,
      requireSignature: git.signingConfigured,
    );
    return local.isExact ? remote : local;
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
    final target = GithubRelease(
      tools: tools!,
      repository: repository!,
      workingDirectory: git.root,
    );
    final stage = _reusableStage(unit);
    if (stage == null) {
      final inventory = await target.inspect(unit.tag, expected);
      if (!inventory.isExact) return inventory;

      final object = git.tagObject(unit.tag);
      final commit = git.tagTarget(unit.tag);
      if (object == null || commit == null) {
        return const Inspection.unknown(
          'the release exists, but this checkout has no readable annotated '
          'tag object to authenticate its manifest',
        );
      }
      final binding =
          await GitTag(tools: tools!, root: git.root).manifestBinding(
        tag: unit.tag,
        expectedObject: object,
        expectedCommit: commit,
      );
      switch (binding) {
        case TagManifestBound(:final digest):
          final project = unit.binaryProject;
          final source = GitCommitSourceTree(git.root, git.head);
          final changelog = source.read(project.fileAt('CHANGELOG.md'));
          final notes = changelog == null
              ? null
              : Changelog.entry(changelog, project.version);
          if (notes == null) {
            return const Inspection.unknown(
              'the expected release notes could not be read from the '
              'released commit',
            );
          }
          return target.inspectManifest(GithubManifestExpectation(
            unit: unit.name,
            version: unit.version.canonical,
            tag: unit.tag,
            sourceCommit: git.head,
            sourceTree: git.headTree,
            title: '${project.name} ${unit.version}',
            body: notes,
            manifestSha256: digest,
            publicAssets: expected,
          ));
        case TagManifestAbsent(:final why):
          return Inspection.conflict(
            'the GitHub Release exists without its release tag',
            evidence: {'tag': why},
          );
        case TagManifestConflict(:final why, :final evidence):
          return Inspection.conflict(why, evidence: evidence);
        case TagManifestMissing(:final why) ||
              TagManifestMalformed(:final why) ||
              TagManifestUnbound(:final why):
          return Inspection.conflict(
            'the release tag does not bind its public manifest',
            evidence: {'tag': why},
          );
        case TagManifestUnreadable(:final why):
          return Inspection.unknown(why);
      }
    }

    final receipt = stage.requireReceipt();
    final byPath = {
      for (final artifact in receipt.artifacts) artifact.path: artifact,
    };
    final missing = expected.difference(byPath.keys.toSet());
    if (missing.isNotEmpty) {
      return Inspection.conflict(
        'the completed stage is missing release assets',
        evidence: {for (final name in missing) name: 'missing from stage'},
      );
    }
    final notes = File(stage.directory.resolve('release-notes.md'));
    if (!notes.existsSync()) {
      return const Inspection.conflict(
        'the completed stage has no release notes',
      );
    }
    final project = unit.binaryProject;
    return target.inspectExact(GithubReleaseExpectation(
      tag: unit.tag,
      title: '${project.name} ${unit.version}',
      body: notes.readAsStringSync(),
      assetSha256: {
        for (final name in expected) name: byPath[name]!.sha256,
      },
    ));
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
    // Only the registry half needs the registry. The guard used to sit above
    // both loops, which silently dropped RK-MONO-001 — a refusal computed
    // entirely from local git — whenever `--offline` was passed, handing
    // `--json` callers an empty problems array for a repository whose tags
    // are ahead of its manifests.
    if (registry != null) {
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
            source: SourceLocation(
              project.pubspec.path,
              project.pubspec.versionLine,
            ),
            remedy: 'a release moves forward — bump past ${latest.version}',
          );
        }
      }
    }

    _localTagMonotonicity(unit, problems);
  }

  /// The release-only monotonicity gate against every configured public lane.
  ///
  /// Exact-coordinate inspection answers whether this version exists. It
  /// cannot answer whether a newer version exists elsewhere in the same lane:
  /// a shallow checkout can truthfully find `v1.0.0` absent while origin is
  /// already at `v2.0.0`. Release calls this before private production and
  /// again immediately before authorization.
  ///
  /// Homebrew is deliberately omitted. Its exact formula inspection parses
  /// the public version and authenticates the complete formula bytes against
  /// the manifest bound into that release's tag. It returns absent only for a
  /// proven earlier formula and conflict for an equal or newer one. A second,
  /// weaker version-only tap read would add latency and no permission.
  Future<void> releaseMonotonicity(
    ResolvedUnit unit,
    Iterable<TargetExpectation> targets,
    Diagnostics problems, {
    bool refreshRegistry = false,
  }) async {
    final localTagProblems = Diagnostics();
    _localTagMonotonicity(unit, localTagProblems);

    final guarded = <TargetExpectation>[];
    final seen = <String>{};
    for (final target in targets) {
      if (target.kind == ReleaseTargetKind.homebrew) continue;
      final key = '${target.kind.name}\u0000${target.coordinate}';
      if (seen.add(key)) guarded.add(target);
    }

    if (refreshRegistry) {
      for (final target in guarded) {
        if (target.kind == ReleaseTargetKind.pubDev) {
          registry?.forget(target.coordinate);
        }
      }
    }

    // Start every independent provider read before awaiting one. A slow
    // forge must not postpone asking origin or pub.dev.
    final reads = [
      for (final target in guarded)
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
    for (final (index, target) in guarded.indexed) {
      final inspection = latest[index];
      if (inspection.isAbsent) continue;
      if (!inspection.isExact) {
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
      if (target.kind == ReleaseTargetKind.pubDev) {
        final project = target.project!;
        problems.add(
          'RK-MONO-002',
          '${project.name} $version is already published, and this would '
              'publish ${project.version}',
          source: SourceLocation(
            project.pubspec.path,
            project.pubspec.versionLine,
          ),
          remedy: 'a release moves forward — bump past $version',
        );
        continue;
      }
      if (target.kind == ReleaseTargetKind.gitTag) remoteTagAhead = true;
      problems.add(
        'RK-MONO-003',
        '${target.label} is at $version, ahead of the '
            '${target.targetVersion} this release would publish',
        remedy: 'a release moves forward — bump past $version',
      );
    }

    // The public lane is the stronger fact. Do not tell the operator twice
    // about the same ahead tag merely because it is also present locally.
    if (!remoteTagAhead) {
      localTagProblems.found.forEach(problems.report);
    }
  }

  void _localTagMonotonicity(
    ResolvedUnit unit,
    Diagnostics problems,
  ) {
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
  /// Expected bytes come from the exact local stage while preparing a release,
  /// or from the public release manifest after publication. A formula naming
  /// an earlier authenticated release is `absent` — moving it forward is
  /// exactly the work the step does. Unauthenticated or different same/newer
  /// bytes are a conflict, never permission to overwrite blindly.
  Future<Inspection> _formula(ResolvedUnit unit) async {
    if (tools == null) {
      return const Inspection.unknown('not read: --offline');
    }
    if (repository == null) {
      return const Inspection.unknown('no origin remote to ask');
    }
    // Per unit: a tap is where this unit's formula goes, and a repository
    // with two binary units can point them at two taps.
    final tapRepo = unit.tapFor(repository!);
    final project = unit.binaryProject;
    final executable = project.executable!;
    final stage = _reusableStage(unit);
    final name = ReleaseAssets.formulaName(executable);
    List<int>? expectedBytes;
    if (stage != null) {
      final expected = File(stage.directory.resolve(name));
      if (!expected.existsSync()) {
        return Inspection.conflict(
          'the completed stage has no $name',
        );
      }
      expectedBytes = expected.readAsBytesSync();
    } else if (git.hasTag(unit.tag)) {
      final current = await _currentManifestAsset(unit, name);
      if (current.inspection.verdict == Verdict.conflict ||
          current.inspection.verdict == Verdict.unknown) {
        return current.inspection;
      }
      expectedBytes = current.bytes;
    }

    return HomebrewTarget(
      tools: tools!,
      tap: tapRepo,
      workingDirectory: git.root,
    ).inspect(
      formulaPath: 'Formula/$executable.rb',
      expectedBytes: expectedBytes,
      inspectEarlierRelease: (bytes) => _inspectEarlierFormula(unit, bytes),
    );
  }

  Future<({Inspection inspection, List<int>? bytes})> _currentManifestAsset(
    ResolvedUnit unit,
    String assetName,
  ) async {
    final object = git.tagObject(unit.tag);
    final commit = git.tagTarget(unit.tag);
    if (object == null || commit == null) {
      return (
        inspection: const Inspection.unknown(
          'the release tag object could not be read',
        ),
        bytes: null,
      );
    }
    final binding = await GitTag(tools: tools!, root: git.root).manifestBinding(
      tag: unit.tag,
      expectedObject: object,
      expectedCommit: commit,
    );
    if (binding case TagManifestBound(:final digest)) {
      try {
        final expected = _manifestExpectation(unit, digest);
        final read = await GithubRelease(
          tools: tools!,
          repository: repository!,
          workingDirectory: git.root,
        ).readManifestBoundAsset(expected, assetName);
        return (inspection: read.inspection, bytes: read.bytes);
      } on Object catch (error) {
        return (
          inspection: Inspection.unknown(
            'the expected release manifest could not be derived: $error',
          ),
          bytes: null,
        );
      }
    }
    return (inspection: _bindingInspection(binding), bytes: null);
  }

  GithubManifestExpectation _manifestExpectation(
    ResolvedUnit unit,
    String digest,
  ) {
    final project = unit.binaryProject;
    final source = GitCommitSourceTree(git.root, git.head);
    final changelog = source.read(project.fileAt('CHANGELOG.md'));
    final notes =
        changelog == null ? null : Changelog.entry(changelog, project.version);
    if (notes == null) {
      throw StateError('release notes are absent from the released commit');
    }
    return GithubManifestExpectation(
      unit: unit.name,
      version: unit.version.canonical,
      tag: unit.tag,
      sourceCommit: git.head,
      sourceTree: git.headTree,
      title: '${project.name} ${unit.version}',
      body: notes,
      manifestSha256: digest,
      publicAssets: expectedAssets(unit),
    );
  }

  Future<Inspection> _inspectEarlierFormula(
    ResolvedUnit unit,
    List<int> publicBytes,
  ) async {
    final version = HomebrewFormula.versionIn(publicBytes);
    if (version == null) {
      return const Inspection.conflict(
        'the public formula is not generated by rk with one canonical version',
      );
    }
    if (version >= unit.version) {
      return Inspection.conflict(
        'the public formula claims ${version.canonical}, not an earlier '
        'release than ${unit.version}',
      );
    }
    final tag = unit.tagPattern.replaceAll('{version}', version.canonical);
    final object = git.tagObject(tag);
    final commit = git.tagTarget(tag);
    if (object == null || commit == null) {
      return Inspection.unknown(
        'the earlier release tag $tag is not available in this checkout',
      );
    }
    final binding = await GitTag(tools: tools!, root: git.root).manifestBinding(
      tag: tag,
      expectedObject: object,
      expectedCommit: commit,
    );
    if (binding case TagManifestBound(:final digest)) {
      final project = unit.binaryProject;
      final assetName = ReleaseAssets.formulaName(project.executable!);
      final read = await GithubRelease(
        tools: tools!,
        repository: repository!,
        workingDirectory: git.root,
      ).readHistoricalManifestBoundAsset(
        GithubHistoricalManifestExpectation(
          unit: unit.name,
          version: version.canonical,
          tag: tag,
          sourceCommit: commit,
          manifestSha256: digest,
          title: '${project.name} ${version.canonical}',
        ),
        assetName,
      );
      if (!read.inspection.isExact) return read.inspection;
      final released = read.bytes!;
      if (!_sameBytes(released, publicBytes)) {
        return Inspection.conflict(
          'the tap formula differs from the formula bound to $tag',
        );
      }
      return Inspection.exact(
        detail: 'matches the manifest-bound formula from $tag',
        evidence: {'version': version.canonical},
      );
    }
    return _bindingInspection(binding);
  }

  static Inspection _bindingInspection(TagManifestBinding binding) =>
      switch (binding) {
        TagManifestBound() => const Inspection.unknown(
            'the tag manifest binding was not consumed',
          ),
        TagManifestAbsent(:final why) => Inspection.conflict(
            'the release tag is absent',
            evidence: {'tag': why},
          ),
        TagManifestConflict(:final why, :final evidence) =>
          Inspection.conflict(why, evidence: evidence),
        TagManifestMissing(:final why) ||
        TagManifestMalformed(:final why) ||
        TagManifestUnbound(:final why) =>
          Inspection.conflict(
            'the release tag does not bind its public manifest',
            evidence: {'tag': why},
          ),
        TagManifestUnreadable(:final why) => Inspection.unknown(why),
      };

  static bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
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
              'then check out the candidate and run rk status ${unit.name} '
              'before pushing the tag',
        ),
      ];
    }

    final target = git.tagTarget(unit.tag);

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
    if (git.hasTag(unit.tag) &&
        target == null &&
        publishes.any((s) => s.isAbsent)) {
      return [
        Diagnostic(
          code: 'RK-GIT-007',
          message: 'the tag ${unit.tag} exists, and rk could not read which '
              'commit it names',
          remedy: 'rk proves the tag names the commit it is about to publish '
              'from, and it cannot prove that here — so it will not publish. '
              'One unreachable tag object breaks the read for every tag:\n'
              '  git show-ref --tags -d   (must exit 0)\n'
              '  git fsck --tags          (names what is unreachable)',
        ),
      ];
    }

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
