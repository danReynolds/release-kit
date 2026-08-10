import 'dart:convert';
import 'dart:io';

import '../destinations/git_tag.dart';
import '../destinations/github_release.dart';
import '../engine/assets.dart';
import '../engine/checklist.dart';
import '../engine/changelog.dart';
import '../engine/diagnostic.dart';
import '../engine/resolve.dart';
import '../engine/source_tree.dart';
import '../engine/stage_contract.dart';
import '../engine/stage_inspection.dart';
import '../engine/stage_receipt.dart';
import '../engine/targets.dart';
import '../engine/verdict.dart';
import '../engine/workspace.dart';
import '../output/output.dart';
import '../transforms/digest.dart';
import 'published_release_evidence.dart';
import 'target_module.dart';

final class GithubReleaseTargetModule extends TargetModule {
  const GithubReleaseTargetModule();

  @override
  StepKind get stepKind => StepKind.publishRelease;

  @override
  Future<bool> preflight(
    TargetPreflightContext context,
    ResolvedUnit unit,
  ) async =>
      true;

  @override
  TargetExpectation expectation({
    required ResolvedUnit unit,
    required Step step,
    String? repository,
  }) {
    final project = unit.projects.firstWhere(
      (project) => project.name == step.project,
    );
    final artifacts = ReleaseAssets.expectedFor(project).toList()..sort();
    return TargetExpectation(
      label: repository == null
          ? 'GitHub Release'
          : 'GitHub Release · $repository',
      coordinate: repository == null
          ? unit.tag
          : '$repository/releases/tag/${unit.tag}',
      targetVersion: unit.version.canonical,
      step: step,
      project: project,
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
      final inventory = await destination.inspect(unit.tag, expected);
      if (!inventory.isExact) return inventory;

      final object = context.git.tagObject(unit.tag);
      final commit = context.git.tagTarget(unit.tag);
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
        tag: unit.tag,
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
    return destination.inspectExact(
      GithubReleaseExpectation(
        tag: unit.tag,
        title: '${project.name} ${unit.version}',
        body: notes.readAsStringSync(),
        assetSha256: {
          for (final name in expected) name: byPath[name]!.sha256,
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
    ).inspectLatestVersion(unit.tagPattern);
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
    final project = unit.binaryProject;
    final assets = _StagedReleaseAssets(
      workspace: context.workspace,
      output: context.output,
    ).gather(project, unit.name);
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
      tag: unit.tag,
      title: '${project.name} ${unit.version}',
      notesPath: notesPath,
      assetPaths: assets.map((asset) => asset.path).toList(),
      assetSha256: {
        for (final asset in assets) asset.name: Sha256.hex(asset.bytes),
      },
      assetSizes: {
        for (final asset in assets) asset.name: asset.bytes.length,
      },
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
    final project = target.project!;
    final contract = StageContributionContract(
      phase: StageContributionPhase.beforeArtifacts,
      step: StageStepContract(
        'release-notes',
        inputs: const {'step:source-snapshot'},
        outputs: const {'release-notes.md': 'notes'},
        validate: (context, step) {
          final changelog = File(
            '${context.sourceRoot}/${project.fileAt('CHANGELOG.md')}',
          );
          final expected = changelog.existsSync()
              ? Changelog.entry(changelog.readAsStringSync(), project.version)
              : null;
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
    final project = target.project!;
    final changelogPath = project.fileAt('CHANGELOG.md');
    final source = SnapshotSourceTree(context.stage.sourceRoot);
    final contents = source.read(changelogPath);
    final notes =
        contents == null ? null : Changelog.entry(contents, project.version);
    if (notes == null) {
      context.output.problem(
        Diagnostic(
          code: 'RK-CHG-003',
          message: 'the changelog entry for ${project.version} could not be '
              'extracted',
          source: SourceLocation(changelogPath, 1),
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
          message: 'the changelog entry for ${project.version} is empty',
          source: SourceLocation(changelogPath, 1),
          remedy: 'the release body is this entry — write what changed '
              'under the ${project.version} heading',
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

/// Reads the exact asset inventory the GitHub Release will publish.
final class _StagedReleaseAssets {
  const _StagedReleaseAssets({required this.workspace, required this.output});

  final Workspace workspace;
  final Output output;

  List<_StagedReleaseAsset>? gather(
    ResolvedProject project,
    String unit,
  ) {
    final assets = <_StagedReleaseAsset>[];

    _StagedReleaseAsset? read(
      String name,
      String producer,
    ) {
      final bytes = workspace.readBytes(name);
      if (bytes == null) {
        output.problem(
          Diagnostic(
            code: 'RK-WORK-001',
            message: 'the workspace has no $name',
            remedy: '$producer — re-running runs it',
          ),
          unit: unit,
        );
        return null;
      }
      return _StagedReleaseAsset(
        name: name,
        path: workspace.pathOf(name),
        bytes: bytes,
      );
    }

    for (final platform in project.binaryPlatforms) {
      final executable = project.executable!;
      final version = project.version.canonical;
      final archive = read(
        ReleaseAssets.archiveName(executable, version, platform),
        'the archive steps produce it',
      );
      if (archive == null) return null;
      assets.add(archive);

      if (platform.startsWith('macos-')) {
        for (final evidence in [
          ReleaseAssets.notaryResultName(executable, version, platform),
          ReleaseAssets.notaryLogName(executable, version, platform),
        ]) {
          final asset = read(evidence, 'the notarize step produces it');
          if (asset == null) return null;
          assets.add(asset);
        }
      }
    }

    final sums = read(
      ReleaseAssets.checksums,
      'the checksums step produces it',
    );
    if (sums == null) return null;
    assets.add(sums);

    if (project.channels.contains('homebrew')) {
      final formula = read(
        ReleaseAssets.formulaName(project.executable!),
        'the Homebrew target renders it',
      );
      if (formula == null) return null;
      assets.add(formula);
    }
    final manifest = read(
      ReleaseAssets.manifest,
      'the complete-stage step produces it',
    );
    if (manifest == null) return null;
    assets.add(manifest);
    return assets;
  }
}

final class _StagedReleaseAsset {
  const _StagedReleaseAsset({
    required this.name,
    required this.path,
    required this.bytes,
  });

  final String name;
  final String path;
  final List<int> bytes;
}
