import 'dart:convert';
import 'dart:io';

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
import '../output/progress.dart';
import 'target_module.dart';

final class GithubReleaseTargetModule extends TargetModule {
  const GithubReleaseTargetModule();

  @override
  String planNote(TargetExpectation target) =>
      '${target.artifacts.length} asset${target.artifacts.length == 1 ? '' : 's'}'
      ' to ${target.coordinate}';

  @override
  PublishTarget get target => PublishTarget.githubRelease;

  @override
  StepKind get stepKind => StepKind.publishRelease;

  @override
  ProgressActivity get actActivity => ProgressActivity(
        running: 'drafting',
        failed: 'draft failed',
      );

  @override
  TargetSessionProvider get sessionProvider => const _GithubSession();

  @override
  Future<TargetReadinessOutcome> preflight(
    TargetReadinessContext context,
    ResolvedUnit unit,
  ) async =>
      const TargetReady();

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
      return destination.inspect(
        tag,
        expected,
        prerelease: unit.version.isPrerelease,
      );
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
        prerelease: unit.version.isPrerelease,
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
    final gathered = const _StagedReleaseAssets().gather(context.stage, unit);
    final assets = gathered.assets;
    if (assets == null) {
      return TargetActOutcome(ok: false, diagnostic: gathered.diagnostic);
    }
    final notesPath = context.workspace.pathOf('release-notes.md');
    if (!File(notesPath).existsSync()) {
      return const TargetActOutcome(
        ok: false,
        diagnostic: Diagnostic(
          code: 'RK-CHG-003',
          message: 'the release body was not prepared',
          remedy: 'this is a bug in rk: the preflight prepares it whenever '
              'a github-release step remains',
        ),
      );
    }

    final release = GithubRelease(
      tools: context.tools,
      repository: repository,
      workingDirectory: context.git.root,
    );
    final outcome = await release.publish(
      tag: tag,
      title: '${unit.name} ${unit.version}',
      notesPath: notesPath,
      assets: assets,
      prerelease: unit.version.isPrerelease,
      onProgress: (event, current, total) {
        switch (event) {
          case GithubPublishEvent.drafting:
            context.progress.begin(actActivity);
          case GithubPublishEvent.uploading:
            context.progress.begin(
              ProgressActivity(
                running: 'uploading',
                failed: 'upload failed',
              ),
              detail: '$current/$total',
            );
          case GithubPublishEvent.publishing:
            context.progress.begin(
              ProgressActivity(
                running: 'publishing',
                failed: 'publish failed',
              ),
            );
        }
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
      evidence: outcome.transcript,
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
        evidence: act.evidence,
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

  Future<TargetStageOutcome> _prepareStage(
    TargetStageContext context,
    TargetExpectation target,
  ) async {
    final receiptName = context.contract.step.name;
    final source = SnapshotSourceTree(context.stage.sourceRoot);
    final notes = _releaseNotes(context.stage.unit, source);
    if (notes == null) {
      return TargetStageFailure(
        Diagnostic(
          code: 'RK-CHG-003',
          message: 'the changelog entries for ${context.stage.unit.version} '
              'could not be extracted',
          source: context.stage.unit.location,
          remedy: 'validation saw a heading for it; the file changed since, '
              'or this is a bug in rk',
        ),
      );
    }
    if (notes.isEmpty) {
      return TargetStageFailure(
        Diagnostic(
          code: 'RK-CHG-004',
          message: 'the changelog entries for ${context.stage.unit.version} '
              'are empty',
          source: context.stage.unit.location,
          remedy: 'the release body is this entry — write what changed '
              'under each ${context.stage.unit.version} heading',
        ),
      );
    }

    context.workspace.write('release-notes.md', utf8.encode(notes));
    return TargetStageSuccess(
      StageStep(
        name: receiptName,
        inputs: [StageInput.step(context.sourceStep)],
        outputs: [
          StageArtifact.capture(
            stage: context.stage.directory,
            path: 'release-notes.md',
            type: 'notes',
          ),
        ],
      ),
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
  const _StagedReleaseAssets();

  /// Joins the static public-name/private-path bundle to the exact captured
  /// artifacts frozen by complete-stage.
  ({List<GithubReleaseAssetUpload>? assets, Diagnostic? diagnostic}) gather(
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
        asset.publicName: asset.stagedPath,
      ReleaseAssets.manifest: ReleaseAssets.manifest,
    };
    final assets = <GithubReleaseAssetUpload>[];
    for (final entry in planned.entries) {
      final artifact =
          entry.key == ReleaseAssets.manifest ? manifest : frozen[entry.key];
      if (artifact == null || artifact.path != entry.value) {
        return (
          assets: null,
          diagnostic: Diagnostic(
            code: 'RK-WORK-001',
            message: 'the completed stage has no exact ${entry.key} binding',
            remedy: '${_producerOf(entry.key)} — re-running runs it',
          ),
        );
      }
      assets.add(GithubReleaseAssetUpload(
        publicName: entry.key,
        stagedPath: stage.directory.resolve(artifact.path),
        size: artifact.size,
        sha256: artifact.sha256,
      ));
    }
    return (assets: assets, diagnostic: null);
  }

  static String _producerOf(String name) {
    if (name == ReleaseAssets.manifest) {
      return 'the complete-stage step produces it';
    }
    return 'the archive steps produce it';
  }
}

final class _GithubSession extends TargetSessionProvider {
  const _GithubSession();

  @override
  String get id => 'github-cli';

  @override
  ProgressActivity get activity => CommonProgressActivities.checkingSignIn;

  @override
  Future<TargetReadinessOutcome> acquire(
    TargetReadinessContext context,
    ResolvedUnit unit,
    List<TargetExpectation> targets,
  ) async {
    ToolResult status;
    try {
      status = await context.tools.run(
        'gh',
        const ['auth', 'status', '--active', '--hostname', 'github.com'],
        workingDirectory: context.git.root,
      );
    } on ProcessException {
      status = ToolResult(exitCode: -1, stdout: '', stderr: '');
    }
    if (status.ok) return const TargetReady(note: 'signed in');
    return TargetNotReady(
      Diagnostic(
        code: 'RK-GITHUB-010',
        message: 'the GitHub CLI has no usable session',
        remedy: 'Run gh auth login from a terminal, then re-run rk release '
            '${unit.name}. Authentication does not prove write permission; '
            'the exact publish and read-back remain authoritative.',
      ),
      unit: unit.name,
    );
  }
}
