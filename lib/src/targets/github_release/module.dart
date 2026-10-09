import 'dart:io';

import '../../engine/diagnostic.dart';
import '../../engine/publish_target.dart';
import '../../engine/resolve.dart';
import '../../engine/stage.dart';
import '../../engine/tools.dart';
import '../../engine/unit_release.dart';
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
  ProgressActivity get publishActivity =>
      ProgressActivity(running: 'drafting', failed: 'draft failed');

  @override
  TargetSessionProvider get authentication => const _GithubSession();

  @override
  Future<TargetReadinessOutcome> checkReadiness(
    TargetReadinessContext context,
    ResolvedUnit unit,
  ) async => const TargetReady();

  @override
  Future<Inspection> inspectCandidate(
    TargetReadContext context,
    ResolvedUnit unit,
    Target target, {
    Stage? stage,
  }) async {
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
    if (stage == null) {
      return destination.inspect(
        tag,
        expected,
        prerelease: unit.version.isPrerelease,
      );
    }
    final staged = stage.receipt!.files;
    return destination.inspectExact(
      GithubReleaseExpectation(
        tag: tag,
        prerelease: unit.version.isPrerelease,
        assetSha256: {
          for (final file in target.files)
            if (file.name case final name?) name: staged[file.path]!.sha256,
        },
      ),
    );
  }

  @override
  Diagnostic diagnoseConflict(
    ResolvedUnit unit,
    Target target,
    Inspection conflict,
  ) => Diagnostic(
    code: 'RK-REL-001',
    message:
        '${target.label}: '
        '${conflict.detail ?? 'the published release does not match'}',
    remedy:
        'compare the published release with the source named by its '
        'tag. If they are not the intended release, bump the version '
        'and changelog; rk will not replace conflicting public bytes',
  );

  @override
  Future<TargetActOutcome> publish(
    TargetReleaseContext context,
    ResolvedUnit unit,
    Target target,
    Inspection inspected,
  ) async {
    final tag = requiredTargetTag(unit, PublishTarget.githubRelease);
    final repository = context.repository;
    if (repository == null) {
      return TargetActOutcome(
        ok: false,
        diagnostic: Diagnostic(
          code: 'RK-GIT-003',
          message:
              'github-release needs an origin remote, and this '
              'repository has none',
          remedy:
              'rk publishes what others can fetch, and reads back what it '
              'published. git remote add origin <url>, then git push -u '
              'origin ${context.git.branch ?? 'main'}',
        ),
      );
    }
    // The stage was checked just before this act: it holds every file the
    // release publishes, as its receipt records them.
    final stage = context.stage!;
    final staged = stage.receipt!.files;
    final assets = [
      for (final file in target.files)
        if (file.name case final name?)
          GithubReleaseAssetUpload(
            publicName: name,
            stagedPath: stage.pathOf(file.path),
            size: staged[file.path]!.size,
            sha256: staged[file.path]!.sha256,
          ),
    ];
    final notesPath = stage.pathOf(target.preparedBy!.outputs.single);

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
              ProgressActivity(running: 'uploading', failed: 'upload failed'),
              detail: '$current/$total',
            );
          case GithubPublishEvent.publishing:
            context.progress.begin(
              ProgressActivity(running: 'publishing', failed: 'publish failed'),
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
      evidence: outcome.ok ? null : outcome.transcript,
    );
  }

  @override
  Future<TargetStageOutcome> prepare(TargetStageContext context, Work work) =>
      prepareReleaseNotes(context, work);
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
    List<Target> targets,
  ) async {
    ToolResult status;
    try {
      status = await context.tools.run('gh', const [
        'auth',
        'status',
        '--active',
        '--hostname',
        'github.com',
      ], workingDirectory: context.git.root);
    } on ProcessException {
      status = ToolResult(exitCode: -1, stdout: '', stderr: '');
    }
    if (status.ok) return const TargetReady(note: 'signed in');
    return TargetNotReady(
      Diagnostic(
        code: 'RK-GITHUB-010',
        message: 'the GitHub CLI has no usable session',
        remedy:
            'Run gh auth login from a terminal, then re-run rk release '
            '${unit.name}. Authentication does not prove write permission; '
            'the exact publish and read-back remain authoritative.',
      ),
      unit: unit.name,
    );
  }
}
