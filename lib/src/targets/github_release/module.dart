import 'dart:io';

import '../../engine/assets.dart';
import '../../engine/checklist.dart';
import '../../engine/diagnostic.dart';
import '../../engine/publish_target.dart';
import '../../engine/release_bundle.dart';
import '../../engine/resolve.dart';
import '../../engine/targets.dart';
import '../../engine/tools.dart';
import '../../engine/verdict.dart';
import '../../output/progress.dart';
import '../target_module.dart';
import 'client.dart';
import 'release_notes_stage.dart';

final class GithubReleaseTargetModule extends TargetModule {
  const GithubReleaseTargetModule();

  @override
  PublishTarget get target => PublishTarget.githubRelease;

  @override
  ProgressActivity get publishActivity => ProgressActivity(
        running: 'drafting',
        failed: 'draft failed',
      );

  @override
  TargetSessionProvider get authentication => const _GithubSession();

  @override
  Future<TargetReadinessOutcome> checkReadiness(
    TargetReadinessContext context,
    ResolvedUnit unit,
  ) async =>
      const TargetReady();

  @override
  TargetPlan plan({
    required ResolvedUnit unit,
    required Step step,
    String? repository,
  }) {
    final tag = requiredTargetTag(unit, PublishTarget.githubRelease);
    final artifacts = ReleaseAssets.expectedForUnit(unit).toList()..sort();
    final coordinate =
        repository == null ? tag : '$repository/releases/tag/$tag';
    return TargetPlan(
      label: repository == null
          ? 'GitHub Release'
          : 'GitHub Release · $repository',
      kindLabel: 'GitHub Release',
      // Without an origin there is no repository to name, and echoing the
      // tag here would print the Git tag row's identity twice.
      identity: repository ?? 'no origin remote',
      planNote: '${artifacts.length} asset${artifacts.length == 1 ? '' : 's'} '
          'to $coordinate',
      coordinate: coordinate,
      targetVersion: unit.version.canonical,
      step: step,
      artifacts: artifacts,
    );
  }

  @override
  Future<Inspection> inspectCandidate(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetPlan target,
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

    final resolvedBundle = ReleaseBundle.resolve(stage, unit);
    if (resolvedBundle
        case ReleaseBundleInvalid(:final message, :final evidence)) {
      return Inspection.conflict(message, evidence: evidence);
    }
    final bundle = (resolvedBundle as ReleaseBundleAvailable).bundle;
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
        assetSha256: bundle.sha256ByPublicName,
      ),
    );
  }

  @override
  Future<TargetHistory> inspectHistory(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetPlan target, {
    bool fresh = false,
  }) async {
    final tools = context.tools;
    if (tools == null) {
      return TargetHistory.versioned(
        inspection: const Inspection.unknown(
          'no tools to read the forge with',
        ),
        target: target,
      );
    }
    final repository = context.repository;
    if (repository == null) {
      return TargetHistory.versioned(
        inspection: const Inspection.unknown('no origin remote to ask'),
        target: target,
      );
    }
    final inspection = await GithubRelease(
      tools: tools,
      repository: repository,
      workingDirectory: context.git.root,
    ).inspectLatestVersion(
      requiredTargetTagPattern(unit, PublishTarget.githubRelease),
    );
    return TargetHistory.versioned(inspection: inspection, target: target);
  }

  @override
  Diagnostic diagnoseConflict(
    ResolvedUnit unit,
    TargetPlan target,
    Inspection conflict,
  ) =>
      Diagnostic(
        code: 'RK-REL-001',
        message: '${target.label}: '
            '${conflict.detail ?? 'the published release does not match'}',
        remedy: 'compare the published release with the source named by its '
            'tag. If they are not the intended release, bump the version '
            'and changelog; rk will not replace conflicting public bytes',
      );

  @override
  Future<TargetActOutcome> publish(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetPlan target,
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
    final resolvedBundle = ReleaseBundle.resolve(context.stage, unit);
    if (resolvedBundle
        case ReleaseBundleInvalid(:final message, :final producer)) {
      return TargetActOutcome(
        ok: false,
        diagnostic: Diagnostic(
          code: 'RK-WORK-001',
          message: message,
          remedy: '${producer ?? 'the stage producer'} — re-running runs it',
        ),
      );
    }
    final bundle = (resolvedBundle as ReleaseBundleAvailable).bundle;
    final assets = [
      for (final asset in bundle.assets)
        GithubReleaseAssetUpload(
          publicName: asset.publicName,
          stagedPath: context.stage.directory.resolve(asset.artifact.path),
          size: asset.artifact.size,
          sha256: asset.artifact.sha256,
        ),
    ];
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
            context.progress.begin(publishActivity);
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
      privateEffectDetail: switch (outcome.draftEffect) {
        DraftEffect.none => null,
        DraftEffect.changed =>
          'GitHub private draft state changed; this step did not publish a '
              'GitHub Release.',
        DraftEffect.uncertain =>
          'GitHub private draft state may have changed; no GitHub Release '
              'was confirmed public.',
      },
      permanent: outcome.permanent,
      evidence: outcome.ok ? null : outcome.transcript,
    );
  }

  @override
  TargetStage stageInput({
    required ResolvedUnit unit,
    required TargetPlan target,
  }) =>
      githubReleaseNotesStage(unit: unit, target: target);
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
    List<TargetPlan> targets,
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
