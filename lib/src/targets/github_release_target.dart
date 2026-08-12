import 'dart:convert';
import 'dart:io';

import '../destinations/git_tag.dart';
import '../destinations/github_release.dart';
import '../engine/assets.dart';
import '../engine/checklist.dart';
import '../engine/changelog.dart';
import '../engine/diagnostic.dart';
import '../engine/publish_target.dart';
import '../engine/release_stage.dart';
import '../engine/resolve.dart';
import '../engine/source_tree.dart';
import '../engine/stage_contract.dart';
import '../engine/stage_inspection.dart';
import '../engine/stage_receipt.dart';
import '../engine/targets.dart';
import '../engine/tools.dart';
import '../engine/verdict.dart';
import '../output/output.dart';
import 'published_release_evidence.dart';
import 'target_module.dart';

final class GithubReleaseTargetModule extends TargetModule {
  const GithubReleaseTargetModule();

  @override
  PublishTarget get target => PublishTarget.githubRelease;

  @override
  StepKind get stepKind => StepKind.publishRelease;

  @override
  Future<bool> preflight(
    TargetReadinessContext context,
    ResolvedUnit unit,
  ) async =>
      true;

  @override
  Future<TargetSession?> acquireSession(
    TargetReadinessContext context,
    ResolvedUnit unit,
    List<TargetExpectation> targets,
  ) async {
    ToolResult status;
    try {
      status = await context.tools.run(
        'gh',
        const ['auth', 'status'],
        workingDirectory: context.git.root,
      );
    } on ProcessException {
      status = ToolResult(exitCode: -1, stdout: '', stderr: '');
    }
    if (status.ok) {
      return TargetSession(
        endpoint: effectiveEndpoint(context, unit, targets),
      );
    }
    context.output.problem(
      Diagnostic(
        code: 'RK-GITHUB-010',
        message: 'the GitHub CLI has no usable session',
        remedy: 'Run gh auth login from a terminal, then re-run rk release '
            '${unit.name}. Authentication does not prove write permission; '
            'the exact publish and read-back remain authoritative.',
      ),
      unit: unit.name,
    );
    context.output.halt(HaltKind.beforeActing);
    return null;
  }

  @override
  TargetExpectation expectation({
    required ResolvedUnit unit,
    required Step step,
    String? repository,
  }) {
    final tag = requiredTargetTag(unit, PublishTarget.githubRelease);
    final artifacts = ReleaseAssets.expectedForUnit(unit).toList()..sort();
    return TargetExpectation(
      label: repository == null
          ? 'GitHub Release'
          : 'GitHub Release · $repository',
      kindLabel: 'GitHub Release',
      // Without an origin there is no repository to name, and echoing the
      // tag here would print the Git tag row's identity twice.
      identity: repository ?? 'no origin remote',
      coordinate: repository == null ? tag : '$repository/releases/tag/$tag',
      targetVersion: unit.version.canonical,
      step: step,
      artifacts: artifacts,
      exactComparisonNeedsStage: true,
    );
  }

  @override
  Future<Inspection> inspectExact(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetExpectation target,
  ) async {
    final tag = requiredTargetTag(unit, PublishTarget.githubRelease);
    final tools = context.tools;
    if (tools == null) {
      return const Inspection.unknown('no tools to read the forge with');
    }
    final repository = context.repository;
    if (repository == null) {
      return const Inspection.unknown('no origin remote to ask');
    }
    final expected = target.artifacts.toSet();
    final destination = GithubRelease(
      tools: tools,
      repository: repository,
      workingDirectory: context.git.root,
    );
    final stage = context.reusableStage(unit);
    if (stage == null) {
      final inventory = await destination.inspect(tag, expected);
      if (!inventory.isExact) return inventory;

      final object = context.git.tagObject(tag);
      final commit = context.git.tagTarget(tag);
      if (object == null || commit == null) {
        return const Inspection.unknown(
          'the release exists, but this checkout has no readable annotated '
          'tag object to authenticate its manifest',
        );
      }
      final binding = await GitTag(
        tools: tools,
        root: context.git.root,
      ).manifestBinding(
        tag: tag,
        expectedObject: object,
        expectedCommit: commit,
      );
      switch (binding) {
        case TagManifestBound(:final digest):
          try {
            final expectation =
                PublishedReleaseEvidence(context).manifestExpectation(
              unit,
              digest,
              publicAssets: expected,
            );
            return destination.inspectManifest(expectation);
          } on Object catch (error) {
            return Inspection.unknown(
              'the expected release manifest could not be derived: $error',
            );
          }
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
    final releaseAssets = stage.releaseAssets();
    final manifest = receipt.artifacts.singleWhere(
      (artifact) => artifact.path == ReleaseAssets.manifest,
    );
    final staged = {
      ...releaseAssets,
      ReleaseAssets.manifest: manifest,
    };
    final missing = expected.difference(staged.keys.toSet());
    final extra = staged.keys.toSet().difference(expected);
    if (missing.isNotEmpty || extra.isNotEmpty) {
      return Inspection.conflict(
        'the completed stage has a different release-asset inventory',
        evidence: {
          for (final name in missing) name: 'missing from stage',
          for (final name in extra) name: 'not expected by this target',
        },
      );
    }
    final notes = File(stage.directory.resolve('release-notes.md'));
    if (!notes.existsSync()) {
      return const Inspection.conflict(
        'the completed stage has no release notes',
      );
    }
    return destination.inspectExact(
      GithubReleaseExpectation(
        tag: tag,
        title: '${unit.name} ${unit.version}',
        body: notes.readAsStringSync(),
        assetSha256: {
          for (final name in expected) name: staged[name]!.sha256,
        },
      ),
    );
  }

  @override
  Future<Inspection> inspectLatest(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetExpectation target,
  ) {
    final tools = context.tools;
    if (tools == null) {
      return Future.value(
        const Inspection.unknown('no tools to read the forge with'),
      );
    }
    final repository = context.repository;
    if (repository == null) {
      return Future.value(
        const Inspection.unknown('no origin remote to ask'),
      );
    }
    return GithubRelease(
      tools: tools,
      repository: repository,
      workingDirectory: context.git.root,
    ).inspectLatestVersion(
      requiredTargetTagPattern(unit, PublishTarget.githubRelease),
    );
  }

  @override
  String conflictRemedy(
    ResolvedUnit unit,
    TargetExpectation target,
  ) =>
      'compare the published release with the source named by its tag. '
      'If they are not the intended release, bump the version and '
      'changelog; rk will not replace conflicting public bytes';

  @override
  Future<TargetActOutcome> act(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetExpectation target,
    Inspection inspected,
  ) async {
    final tag = requiredTargetTag(unit, PublishTarget.githubRelease);
    final repository = context.repository;
    if (repository == null) {
      return TargetActOutcome(
        ok: false,
        diagnostic: Diagnostic(
          code: 'RK-GIT-002',
          message: 'github-release needs an origin remote, and this '
              'repository has none',
          remedy: 'rk publishes what others can fetch, and reads back what it '
              'published. git remote add origin <url>, then git push -u '
              'origin ${context.git.branch ?? 'main'}',
        ),
      );
    }
    final assets = _StagedReleaseAssets(
      output: context.output,
    ).gather(context.stage, unit);
    if (assets == null) return const TargetActOutcome.reportedFailure();
    final notesPath = context.workspace.pathOf('release-notes.md');
    if (!File(notesPath).existsSync()) {
      context.output.problem(
        const Diagnostic(
          code: 'RK-CHG-003',
          message: 'the release body was not prepared',
          remedy: 'this is a bug in rk: the preflight prepares it whenever '
              'a github-release step remains',
        ),
      );
      return const TargetActOutcome.reportedFailure();
    }

    final release = GithubRelease(
      tools: context.tools,
      repository: repository,
      workingDirectory: context.git.root,
    );
    context.output.progress('publishing ${assets.length} assets');
    final outcome = await release.publish(
      tag: tag,
      title: '${unit.name} ${unit.version}',
      notesPath: notesPath,
      assets: assets,
    );
    return TargetActOutcome(
      ok: outcome.ok,
      problem: outcome.problem,
      mayHaveActed: outcome.mayHaveActed,
      privateEffect: switch (outcome.draftEffect) {
        DraftEffect.none => TargetPrivateEffect.none,
        DraftEffect.changed => TargetPrivateEffect.changed,
        DraftEffect.uncertain => TargetPrivateEffect.uncertain,
      },
      permanent: outcome.permanent,
    );
  }

  @override
  Future<TargetFailure> classifyFailure(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetExpectation target,
    Inspection state,
    TargetActOutcome act, {
    required bool actedBefore,
  }) async {
    final details = <String>[
      if (act.diagnostic?.remedy != null) act.diagnostic!.remedy!,
      if (act.problem != null) act.problem!,
      if (act.privateEffect == TargetPrivateEffect.changed)
        'GitHub private draft state changed; this step did not publish a '
            'GitHub Release.',
      if (act.privateEffect == TargetPrivateEffect.uncertain)
        'GitHub private draft state may have changed; no GitHub Release was '
            'confirmed public.',
      if (state.detail != null) state.detail!,
      ...state.evidence.entries.map((entry) => '${entry.key}: ${entry.value}'),
      if (act.permanent != null) act.permanent!,
    ];
    final immutableConflict = state.verdict == Verdict.conflict;
    final halt = act.permanent != null || immutableConflict
        ? HaltKind.actedAndUnfixable
        : act.mayHaveActed ||
                act.privateEffect == TargetPrivateEffect.uncertain ||
                state.verdict == Verdict.unknown
            ? HaltKind.lostTrack
            : act.privateEffect == TargetPrivateEffect.changed || actedBefore
                ? HaltKind.stoppedPartway
                : HaltKind.beforeActing;
    return TargetFailure(
      diagnostic: Diagnostic(
        code: act.diagnostic?.code ?? 'RK-REL-003',
        message: act.diagnostic?.message ??
            '${target.step.summary}: '
                '${act.problem ?? state.detail ?? 'the public result could not be confirmed'}',
        remedy: details.isEmpty
            ? 're-run; the shared destination inspection will classify the '
                'public target before any retry'
            : details.join('\n'),
      ),
      halt: halt,
    );
  }

  @override
  TargetStage stage({
    required ResolvedUnit unit,
    required TargetExpectation target,
  }) {
    final contract = StageContributionContract(
      phase: StageContributionPhase.beforeArtifacts,
      step: StageStepContract(
        'release-notes',
        inputs: const {'step:source-snapshot'},
        outputs: const {'release-notes.md': 'notes'},
        validate: (context, step) {
          final expected = _releaseNotes(
            unit,
            SnapshotSourceTree(context.sourceRoot),
          );
          final actual = File(context.stage.resolve('release-notes.md'));
          if (expected != null &&
              actual.existsSync() &&
              actual.readAsStringSync() == expected) {
            return const [];
          }
          return const [
            StageIssue(
              StageIssueKind.invalidStructure,
              'release-notes does not match the staged changelog entry',
              path: 'stage.json',
            ),
          ];
        },
      ),
    );
    return TargetStage(
      target: target,
      contract: contract,
      prepare: (context) => _prepareStage(context, target),
    );
  }

  Future<StageStep?> _prepareStage(
    TargetStageContext context,
    TargetExpectation target,
  ) async {
    final receiptName = context.contract.step.name;
    final source = SnapshotSourceTree(context.stage.sourceRoot);
    final notes = _releaseNotes(context.stage.unit, source);
    if (notes == null) {
      context.output.problem(
        Diagnostic(
          code: 'RK-CHG-003',
          message: 'the changelog entries for ${context.stage.unit.version} '
              'could not be extracted',
          source: context.stage.unit.location,
          remedy: 'validation saw a heading for it; the file changed since, '
              'or this is a bug in rk',
        ),
      );
      context.output.halt(HaltKind.beforeActing);
      return null;
    }
    if (notes.isEmpty) {
      context.output.problem(
        Diagnostic(
          code: 'RK-CHG-004',
          message: 'the changelog entries for ${context.stage.unit.version} '
              'are empty',
          source: context.stage.unit.location,
          remedy: 'the release body is this entry — write what changed '
              'under each ${context.stage.unit.version} heading',
        ),
      );
      context.output.halt(HaltKind.beforeActing);
      return null;
    }

    context.output.report.acted = true;
    context.workspace.write('release-notes.md', utf8.encode(notes));
    return StageStep(
      name: receiptName,
      inputs: [StageInput.step(context.sourceStep)],
      outputs: [
        StageArtifact.capture(
          stage: context.stage.directory,
          path: 'release-notes.md',
          type: 'notes',
        ),
      ],
    );
  }
}

String? _releaseNotes(ResolvedUnit unit, SourceTree source) {
  final entries = <({String project, String body})>[];
  for (final project in unit.projects) {
    final contents = source.read(project.fileAt('CHANGELOG.md'));
    final body =
        contents == null ? null : Changelog.entry(contents, project.version);
    if (body == null) return null;
    entries.add((project: project.name, body: body));
  }
  if (entries.length == 1) return entries.single.body;
  return entries
      .map((entry) => '## ${entry.project}\n\n${entry.body}')
      .join('\n\n');
}

/// Reads the exact asset inventory the GitHub Release will publish.
final class _StagedReleaseAssets {
  const _StagedReleaseAssets({required this.output});

  final Output output;

  /// Joins the static public-name/private-path bundle to the exact captured
  /// artifacts frozen by complete-stage.
  List<GithubReleaseAssetUpload>? gather(
    ReleaseStage stage,
    ResolvedUnit unit,
  ) {
    final receipt = stage.requireReceipt();
    final frozen = stage.releaseAssets();
    final manifest = receipt.artifacts.singleWhere(
      (artifact) => artifact.path == ReleaseAssets.manifest,
    );
    final planned = <String, String>{
      for (final asset in ReleaseAssets.bundleFor(unit))
        asset.publicName: asset.blob.stagedPath,
      ReleaseAssets.manifest: ReleaseAssets.manifest,
    };
    final assets = <GithubReleaseAssetUpload>[];
    for (final entry in planned.entries) {
      final artifact =
          entry.key == ReleaseAssets.manifest ? manifest : frozen[entry.key];
      if (artifact == null || artifact.path != entry.value) {
        output.problem(
          Diagnostic(
            code: 'RK-WORK-001',
            message: 'the completed stage has no exact ${entry.key} binding',
            remedy: '${_producerOf(entry.key)} — re-running runs it',
          ),
          unit: unit.name,
        );
        return null;
      }
      assets.add(GithubReleaseAssetUpload(
        publicName: entry.key,
        stagedPath: stage.directory.resolve(artifact.path),
        size: artifact.size,
        sha256: artifact.sha256,
      ));
    }
    return assets;
  }

  static String _producerOf(String name) {
    if (name == ReleaseAssets.checksums) {
      return 'the checksums step produces it';
    }
    if (name == ReleaseAssets.manifest) {
      return 'the complete-stage step produces it';
    }
    return 'the archive steps produce it';
  }
}
