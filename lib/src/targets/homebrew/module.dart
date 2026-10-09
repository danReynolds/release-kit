import 'dart:convert';
import 'dart:io';

import '../../engine/assets.dart';
import '../../engine/diagnostic.dart';
import '../../engine/publish_target.dart';
import '../../engine/resolve.dart';
import '../../engine/stage.dart';
import '../../engine/unit_release.dart';
import '../../engine/verdict.dart';
import '../../output/progress.dart';
import '../github_release/client.dart';
import '../target_module.dart';
import 'client.dart';
import 'formula_stage.dart';

final class HomebrewTargetModule extends TargetModule {
  const HomebrewTargetModule();

  @override
  PublishTarget get target => PublishTarget.homebrew;

  @override
  Future<TargetReadinessOutcome> checkReadiness(
    TargetReadinessContext context,
    ResolvedUnit unit,
  ) async => const TargetReady();

  @override
  ProgressActivity get publishActivity =>
      ProgressActivity(running: 'updating', failed: 'update failed');

  @override
  Future<Inspection> inspectCandidate(
    TargetReadContext context,
    ResolvedUnit unit,
    Target target, {
    Stage? stage,
  }) async {
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
    final destination = HomebrewTarget(
      tools: tools,
      tap: tap,
      workingDirectory: context.git.root,
    );
    if (stage != null) {
      return destination.inspect(
        formulaPath: 'Formula/${ReleaseAssets.formulaName(executable)}',
        intendedVersion: project.version,
        expectedBytes: stage.readBytes(target.files.single.path)!,
      );
    }

    final publicFormula = await destination.inspect(
      formulaPath: 'Formula/${ReleaseAssets.formulaName(executable)}',
      intendedVersion: project.version,
      expectedBytes: null,
    );
    // A formula already at this version is published: what the tap holds
    // is what its users install.
    if (publicFormula.evidence['version'] == project.version.canonical) {
      return Inspection.exact(
        detail: 'the tap formula is at ${project.version.canonical}',
        evidence: publicFormula.evidence,
      );
    }
    if (!publicFormula.isAbsent) return publicFormula;

    // Without its stage, the formula is rendered from the digests GitHub
    // reports for the published archives.
    final current = await _publishedFormula(context, unit, project: project);
    if (!current.inspection.isExact) {
      if (current.inspection.isAbsent ||
          publicFormula.evidence['public formula'] == 'absent') {
        // The GitHub release is not public yet. Ordinary staging will render
        // the formula from the exact archives it is about to publish.
        return publicFormula;
      }
      return current.inspection;
    }
    return destination.inspect(
      formulaPath: 'Formula/${ReleaseAssets.formulaName(executable)}',
      intendedVersion: project.version,
      expectedBytes: current.bytes,
    );
  }

  Future<({Inspection inspection, List<int>? bytes})> _publishedFormula(
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
    final read =
        await GithubRelease(
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
      bytes: utf8.encode(
        HomebrewFormula.renderRelease(
          className: ReleaseAssets.formulaClass(executable),
          version: project.version.canonical,
          repository: repository,
          tag: tag,
          assets: assets,
          executable: executable,
        ),
      ),
    );
  }

  @override
  bool recoversWithoutStage(Inspection inspected) =>
      switch (inspected.authority) {
        HomebrewUpdateAuthority(:final replacement) => replacement != null,
        _ => false,
      };

  @override
  Diagnostic diagnoseConflict(
    ResolvedUnit unit,
    Target target,
    Inspection conflict,
  ) => Diagnostic(
    code: 'RK-REL-001',
    message:
        '${target.label}: '
        '${conflict.detail ?? 'the published formula does not match'}',
    remedy:
        'restore the formula to the exact release bytes it is meant to '
        'reference, or advance the source version intentionally; then '
        'run rk status ${unit.name} again',
  );

  @override
  Future<TargetActOutcome> publish(
    TargetReleaseContext context,
    ResolvedUnit unit,
    Target target,
    Inspection inspected,
  ) async {
    final repository = context.repository;
    if (repository == null) {
      return TargetActOutcome(
        ok: false,
        diagnostic: Diagnostic(
          code: 'RK-GIT-003',
          message:
              'homebrew needs an origin remote, and this repository '
              'has none',
          remedy:
              'rk publishes what others can fetch, and reads back what it '
              'published. git remote add origin <url>, then git push -u '
              'origin ${context.git.branch ?? 'main'}',
        ),
      );
    }
    final authority = inspected.authority;
    if (authority is! HomebrewUpdateAuthority) {
      return const TargetActOutcome(
        ok: false,
        problem:
            'the formula update has no exact public base; re-run so rk '
            'can inspect the tap before updating it',
      );
    }
    final project = target.project!;
    final executable = project.executable!;
    // A recovered payload is authenticated public input; without one, the
    // stage was checked just before this act.
    final formula =
        authority.replacement ??
        context.stage!.readBytes(target.files.single.path)!;
    final Directory scratch;
    try {
      scratch = Directory.systemTemp.createTempSync('rk-tap-');
    } on FileSystemException catch (error) {
      return TargetActOutcome(
        ok: false,
        problem: 'a temporary checkout could not be created: $error',
      );
    }
    final outcome =
        await HomebrewTap(
          tools: context.tools,
          tap: unit.tapFor(repository),
          checkout: '${scratch.path}/tap',
        ).update(
          formulaPath: 'Formula/${ReleaseAssets.formulaName(executable)}',
          contents: utf8.decode(formula),
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
  bool get conflictIsPermanent => false;

  @override
  ({String code, String message, String? next}) nameUnconfirmed(
    ResolvedUnit unit,
    Target target,
    Inspection state,
    TargetActOutcome act,
  ) => switch (state.verdict) {
    Verdict.unknown => (
      code: 'RK-BREW-002',
      message: 'the tap was updated and could not be read back',
      next: null,
    ),
    Verdict.conflict => (
      code: 'RK-BREW-003',
      message: 'the public tap does not hold what rk pushed',
      next: null,
    ),
    Verdict.absent || Verdict.exact => (
      code: 'RK-BREW-001',
      message: 'the tap formula was not updated',
      next: null,
    ),
  };

  @override
  Future<TargetStageOutcome> prepare(TargetStageContext context, Work work) =>
      prepareFormula(context, work);
}
