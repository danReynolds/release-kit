import 'dart:convert';
import 'dart:io';

import '../../engine/assets.dart';
import '../../engine/checklist.dart';
import '../../engine/diagnostic.dart';
import '../../engine/publish_target.dart';
import '../../engine/resolve.dart';
import '../../engine/targets.dart';
import '../../engine/verdict.dart';
import '../../output/output.dart';
import '../../output/progress.dart';
import '../github_release/client.dart';
import '../target_module.dart';
import 'cask_stage.dart';
import 'client.dart';

final class HomebrewTargetModule extends TargetModule {
  const HomebrewTargetModule();

  @override
  PublishTarget get target => PublishTarget.homebrew;

  @override
  Future<TargetReadinessOutcome> checkReadiness(
    TargetReadinessContext context,
    ResolvedUnit unit,
  ) async =>
      const TargetReady();

  @override
  ProgressActivity get publishActivity => ProgressActivity(
        running: 'updating',
        failed: 'update failed',
      );

  @override
  TargetPlan plan({
    required ResolvedUnit unit,
    required Step step,
    String? repository,
  }) {
    final project = unit.project(step.project!);
    final tap = repository == null ? unit.homebrewTap : unit.tapFor(repository);
    return TargetPlan(
      label: tap == null ? 'Homebrew' : 'Homebrew · $tap',
      kindLabel: 'Homebrew',
      identity: tap ?? 'no tap configured',
      planNote: '${project.executable} cask',
      coordinate: tap == null
          ? 'Casks/${ReleaseAssets.caskName(project.executable!)}'
          : '$tap/Casks/${ReleaseAssets.caskName(project.executable!)}',
      targetVersion: project.version.canonical,
      step: step,
      project: project,
      artifacts: [ReleaseAssets.caskName(project.executable!)],
      uses: '${ReleaseAssets.caskName(project.executable!)} bound in the '
          'release manifest',
    );
  }

  @override
  Future<Inspection> inspectCandidate(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetPlan target,
  ) async {
    final tools = context.tools;
    if (tools == null) {
      return const Inspection.unknown('no tools to read the tap with');
    }
    final repository = context.repository;
    if (repository == null) {
      return const Inspection.unknown('no origin remote to ask');
    }
    final tap = unit.tapFor(repository);
    final project = target.project!;
    final executable = project.executable!;
    final stage = context.reusableStage(unit);
    final name = ReleaseAssets.caskName(executable);
    final stagedPath = ReleaseAssets.caskPath(project);
    if (stage != null) {
      final expected = File(stage.directory.resolve(stagedPath));
      if (!expected.existsSync()) {
        return Inspection.conflict('the completed stage has no $name');
      }
      return HomebrewTarget(
        tools: tools,
        tap: tap,
        workingDirectory: context.git.root,
      ).inspect(
        caskPath: 'Casks/${ReleaseAssets.caskName(executable)}',
        intendedVersion: project.version,
        expectedBytes: expected.readAsBytesSync(),
      );
    }

    final destination = HomebrewTarget(
      tools: tools,
      tap: tap,
      workingDirectory: context.git.root,
    );
    final publicCask = await destination.inspect(
      caskPath: 'Casks/${ReleaseAssets.caskName(executable)}',
      intendedVersion: project.version,
      expectedBytes: null,
    );
    final sameVersion =
        publicCask.evidence['version'] == project.version.canonical;
    if (!publicCask.isAbsent && !sameVersion) return publicCask;

    final current = await _publishedCask(
      context,
      unit,
      project: project,
    );
    if (!current.inspection.isExact) {
      if (current.inspection.isAbsent ||
          publicCask.evidence['public cask'] == 'absent') {
        // The GitHub release is not public yet. Ordinary staging will render
        // the cask from the exact archives it is about to publish.
        return publicCask;
      }
      return current.inspection;
    }

    return destination.inspect(
      caskPath: 'Casks/${ReleaseAssets.caskName(executable)}',
      intendedVersion: project.version,
      expectedBytes: current.bytes,
    );
  }

  Future<({Inspection inspection, List<int>? bytes})> _publishedCask(
    TargetReadContext context,
    ResolvedUnit unit, {
    required ResolvedProject project,
  }) async {
    final repository = context.repository!;
    final tag = requiredTargetTag(unit, PublishTarget.githubRelease);
    final executable = project.executable!;
    final archiveNames = {
      for (final platform in project.binaryPlatforms)
        ReleaseAssets.archiveName(
          executable,
          project.version.canonical,
          platform,
        ),
    };
    final read = await GithubRelease(
      tools: context.tools!,
      repository: repository,
      workingDirectory: context.git.root,
    ).readAssetDigests(
      tag: tag,
      expectedAssets: ReleaseAssets.expectedForUnit(unit).toSet(),
      requestedAssets: archiveNames,
      prerelease: unit.version.isPrerelease,
    );
    if (!read.inspection.isExact) {
      return (inspection: read.inspection, bytes: null);
    }
    final assets = <String, PlatformAsset>{};
    for (final platform in project.binaryPlatforms) {
      final name = ReleaseAssets.archiveName(
        executable,
        project.version.canonical,
        platform,
      );
      final sha256 = read.digests[name];
      if (sha256 == null) {
        return (
          inspection: Inspection.unknown(
            'the GitHub Release did not report a digest for $name',
          ),
          bytes: null,
        );
      }
      assets[platform] = PlatformAsset(name: name, sha256: sha256);
    }
    return (
      inspection: read.inspection,
      bytes: utf8.encode(HomebrewCask.renderRelease(
        token: ReleaseAssets.caskToken(executable),
        version: project.version.canonical,
        repository: repository,
        tag: tag,
        assets: assets,
        executable: executable,
      )),
    );
  }

  @override
  String? stageRecoveryBinding(Inspection inspected) =>
      switch (inspected.authority) {
        HomebrewUpdateAuthority(:final recoveryBinding) => recoveryBinding,
        _ => null,
      };

  @override
  String conflictRemedy(
    ResolvedUnit unit,
    TargetPlan target,
  ) =>
      'restore the cask to the exact release bytes it is meant to '
      'reference, or advance the source version intentionally; then '
      'run rk status ${unit.name} again';

  @override
  Future<TargetActOutcome> publish(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetPlan target,
    Inspection inspected,
  ) async {
    final repository = context.repository;
    if (repository == null) {
      return TargetActOutcome(
        ok: false,
        diagnostic: Diagnostic(
          code: 'RK-GIT-002',
          message: 'homebrew needs an origin remote, and this repository '
              'has none',
          remedy: 'rk publishes what others can fetch, and reads back what it '
              'published. git remote add origin <url>, then git push -u '
              'origin ${context.git.branch ?? 'main'}',
        ),
      );
    }
    final authority = inspected.authority;
    if (authority is! HomebrewUpdateAuthority) {
      return const TargetActOutcome(
        ok: false,
        problem: 'the cask update has no exact public base; re-run so rk '
            'can inspect the tap before updating it',
      );
    }
    final project = target.project!;
    final executable = project.executable!;
    // A recovered payload is authenticated public input. A non-reusable stage
    // may still contain stale files, so it must never outrank that authority.
    final cask = authority.replacement ??
        context.workspace.readBytes(ReleaseAssets.caskPath(project));
    if (cask == null) {
      return TargetActOutcome(
        ok: false,
        problem: 'the workspace has no '
            '${ReleaseAssets.caskName(executable)}; the staging phase '
            'renders it — re-running runs it',
      );
    }
    final Directory scratch;
    try {
      scratch = Directory.systemTemp.createTempSync('rk-tap-');
    } on FileSystemException catch (error) {
      return TargetActOutcome(
        ok: false,
        problem: 'a temporary checkout could not be created: $error',
      );
    }
    final outcome = await HomebrewTap(
      tools: context.tools,
      tap: unit.tapFor(repository),
      checkout: '${scratch.path}/tap',
    ).update(
      caskPath: 'Casks/${ReleaseAssets.caskName(executable)}',
      contents: utf8.decode(cask),
      message: '$executable ${project.version}',
      authority: authority,
    );
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      // Public truth, not scratch cleanup, decides the target.
    }
    return TargetActOutcome(
      ok: outcome.ok,
      problem: outcome.problem,
      mayHaveActed: outcome.mayHaveActed,
      evidence: outcome.ok ? null : outcome.transcript,
    );
  }

  @override
  Future<TargetFailure> classifyUnconfirmedPublication(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetPlan target,
    Inspection state,
    TargetActOutcome act, {
    required bool actedBefore,
  }) async {
    final code = switch (state.verdict) {
      Verdict.unknown => 'RK-BREW-002',
      Verdict.conflict => 'RK-BREW-003',
      Verdict.absent || Verdict.exact => 'RK-BREW-001',
    };
    final message = switch (state.verdict) {
      Verdict.unknown => 'the tap was updated and could not be read back',
      Verdict.conflict => 'the public tap does not hold what rk pushed',
      Verdict.absent || Verdict.exact => 'the tap cask was not updated',
    };
    final details = <String>[
      if (act.diagnostic?.remedy != null) act.diagnostic!.remedy!,
      if (act.problem != null) act.problem!,
      if (state.detail != null) state.detail!,
      ...state.evidence.entries.map((entry) => '${entry.key}: ${entry.value}'),
    ];
    final halt = state.verdict == Verdict.conflict
        ? HaltKind.stoppedPartway
        : act.mayHaveActed || state.verdict == Verdict.unknown
            ? HaltKind.lostTrack
            : actedBefore
                ? HaltKind.stoppedPartway
                : HaltKind.beforeActing;
    return TargetFailure(
      diagnostic: Diagnostic(
        code: code,
        message: message,
        remedy: details.isEmpty
            ? 're-run; the shared destination inspection will classify the '
                'public target before any retry'
            : details.join('\n'),
        evidence: act.evidence ?? act.diagnostic?.evidence,
      ),
      halt: halt,
    );
  }

  @override
  TargetStage stageInput({
    required ResolvedUnit unit,
    required TargetPlan target,
  }) =>
      homebrewCaskStage(unit: unit, target: target);
}
