import 'dart:convert';
import 'dart:io';

import '../../engine/assets.dart';
import '../../engine/checklist.dart';
import '../../engine/diagnostic.dart';
import '../../engine/publish_target.dart';
import '../../engine/release_manifest.dart';
import '../../engine/resolve.dart';
import '../../engine/targets.dart';
import '../../engine/verdict.dart';
import '../../output/output.dart';
import '../../output/progress.dart';
import '../github_release/client.dart';
import '../git_tag/client.dart';
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
      planNote: '${project.executable} formula',
      coordinate: tap == null
          ? 'Formula/${ReleaseAssets.formulaName(project.executable!)}'
          : '$tap/Formula/${ReleaseAssets.formulaName(project.executable!)}',
      targetVersion: project.version.canonical,
      step: step,
      project: project,
      artifacts: [ReleaseAssets.formulaName(project.executable!)],
      uses: '${ReleaseAssets.formulaName(project.executable!)} bound in the '
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
    final name = ReleaseAssets.formulaName(executable);
    final stagedPath = ReleaseAssets.formulaPath(project);
    if (stage != null) {
      final expected = File(stage.directory.resolve(stagedPath));
      if (!expected.existsSync()) {
        return Inspection.conflict('the completed stage has no $name');
      }
      final destination = HomebrewTarget(
        tools: tools,
        tap: tap,
        workingDirectory: context.git.root,
      );
      return destination.inspect(
        formulaPath: 'Formula/${ReleaseAssets.formulaName(executable)}',
        intendedVersion: project.version,
        expectedBytes: expected.readAsBytesSync(),
      );
    }

    final destination = HomebrewTarget(
      tools: tools,
      tap: tap,
      workingDirectory: context.git.root,
    );
    final publicFormula = await destination.inspect(
      formulaPath: 'Formula/${ReleaseAssets.formulaName(executable)}',
      intendedVersion: project.version,
      expectedBytes: null,
    );
    final sameVersion =
        publicFormula.evidence['version'] == project.version.canonical;
    if (!publicFormula.isAbsent && !sameVersion) return publicFormula;

    if (sameVersion) {
      final historical = await _historicalFormulaIdentity(
        context,
        unit,
        project: project,
        tap: tap,
        formulaPath: 'Formula/$name',
      );
      if (!historical.inspection.isExact) return historical.inspection;
      return destination.inspect(
        formulaPath: 'Formula/$name',
        intendedVersion: project.version,
        expectedBytes: null,
        expectedSha256: historical.formulaSha256,
      );
    }

    final current = await _publishedFormula(
      context,
      unit,
      project: project,
    );
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

  Future<({Inspection inspection, String? formulaSha256})>
      _historicalFormulaIdentity(
    TargetReadContext context,
    ResolvedUnit unit, {
    required ResolvedProject project,
    required String tap,
    required String formulaPath,
  }) async {
    final tag = requiredTargetTag(unit, PublishTarget.gitTag);
    final tagObject = context.git.tagObject(tag);
    final tagCommit = context.git.tagTarget(tag);
    if (tagObject == null || tagCommit == null) {
      return (
        inspection: const Inspection.unknown(
          'the release tag identity is unavailable, so the published formula '
          'cannot be authenticated',
        ),
        formulaSha256: null,
      );
    }
    final binding = await GitTag(
      tools: context.tools!,
      root: context.git.root,
    ).manifestBinding(
      tag: tag,
      expectedObject: tagObject,
      expectedCommit: tagCommit,
    );
    final manifestSha256 = binding.sha256;
    if (manifestSha256 == null) {
      return (
        inspection: _manifestBindingFailure(binding),
        formulaSha256: null,
      );
    }

    final read = await GithubRelease(
      tools: context.tools!,
      repository: context.repository!,
      workingDirectory: context.git.root,
    ).readBoundAsset(
      tag: tag,
      expectedAssets: ReleaseAssets.expectedForUnit(unit).toSet(),
      asset: ReleaseAssets.manifest,
      expectedSha256: manifestSha256,
      prerelease: unit.version.isPrerelease,
    );
    if (!read.inspection.isExact) {
      return (inspection: read.inspection, formulaSha256: null);
    }

    final ReleaseManifest manifest;
    try {
      manifest = ReleaseManifest.parse(utf8.decode(read.bytes!));
    } on Object catch (error) {
      return (
        inspection: Inspection.conflict(
          'the authenticated release manifest is invalid: $error',
        ),
        formulaSha256: null,
      );
    }
    final coordinateDifferences = <String, String>{};
    if (manifest.unit != unit.name) {
      coordinateDifferences['unit'] =
          'manifest ${manifest.unit}, expected ${unit.name}';
    }
    if (manifest.version != unit.version.canonical) {
      coordinateDifferences['version'] =
          'manifest ${manifest.version}, expected ${unit.version.canonical}';
    }
    if (manifest.tag != tag) {
      coordinateDifferences['tag'] =
          'manifest ${manifest.tag ?? '<none>'}, expected $tag';
    }
    if (manifest.commit != tagCommit) {
      coordinateDifferences['source commit'] =
          'manifest ${manifest.commit ?? '<none>'}, expected $tagCommit';
    }
    if (coordinateDifferences.isNotEmpty) {
      return (
        inspection: Inspection.conflict(
          'the authenticated release manifest names a different release',
          evidence: coordinateDifferences,
        ),
        formulaSha256: null,
      );
    }

    final homebrew = manifest.homebrew;
    if (homebrew == null ||
        !homebrew.names(
          project: project.name,
          tap: tap,
          path: formulaPath,
        )) {
      return (
        inspection: Inspection.conflict(
          'the authenticated release manifest does not bind '
          '$tap/$formulaPath',
        ),
        formulaSha256: null,
      );
    }
    return (
      inspection: const Inspection.exact(
        detail: 'published formula identity read from the authenticated '
            'release manifest',
      ),
      formulaSha256: homebrew.sha256,
    );
  }

  Inspection _manifestBindingFailure(TagManifestBinding binding) =>
      switch (binding) {
        TagManifestUnreadable(:final why) => Inspection.unknown(why),
        TagManifestConflict(:final why, :final evidence) =>
          Inspection.conflict(why, evidence: evidence),
        TagManifestAbsent(:final why) ||
        TagManifestMissing(:final why) ||
        TagManifestMalformed(:final why) ||
        TagManifestUnbound(:final why) =>
          Inspection.conflict(
            'the published formula cannot be authenticated: $why',
          ),
        TagManifestBound() => throw StateError('bound manifest has no digest'),
      };

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
      bytes: utf8.encode(HomebrewFormula.renderRelease(
        className: ReleaseAssets.formulaClass(executable),
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
  Diagnostic diagnoseConflict(
    ResolvedUnit unit,
    TargetPlan target,
    Inspection conflict,
  ) =>
      Diagnostic(
        code: 'RK-REL-001',
        message: '${target.label}: '
            '${conflict.detail ?? 'the published formula does not match'}',
        remedy: 'restore the formula to the exact release bytes it is meant to '
            'reference, or advance the source version intentionally; then '
            'run rk status ${unit.name} again',
      );

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
        problem: 'the formula update has no exact public base; re-run so rk '
            'can inspect the tap before updating it',
      );
    }
    final project = target.project!;
    final executable = project.executable!;
    // A recovered payload is authenticated public input. A non-reusable stage
    // may still contain stale files, so it must never outrank that authority.
    final formula = authority.replacement ??
        context.workspace.readBytes(ReleaseAssets.formulaPath(project));
    if (formula == null) {
      return TargetActOutcome(
        ok: false,
        problem: 'the workspace has no '
            '${ReleaseAssets.formulaName(executable)}; the staging phase '
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
      Verdict.absent || Verdict.exact => 'the tap formula was not updated',
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
      homebrewFormulaStage(unit: unit, target: target);
}
