import 'dart:convert';
import 'dart:io';

import '../destinations/github_release.dart';
import '../destinations/homebrew.dart';
import '../engine/assets.dart';
import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/publish_target.dart';
import '../engine/producers.dart';
import '../engine/resolve.dart';
import '../engine/stage_contract.dart';
import '../engine/stage_inspection.dart';
import '../engine/stage_receipt.dart';
import '../engine/targets.dart';
import '../engine/verdict.dart';
import '../output/output.dart';
import '../output/progress.dart';
import 'target_module.dart';

final class HomebrewTargetModule extends TargetModule {
  const HomebrewTargetModule();

  @override
  PublishTarget get target => PublishTarget.homebrew;

  @override
  StepKind get stepKind => StepKind.publishCask;

  @override
  Future<TargetReadinessOutcome> preflight(
    TargetReadinessContext context,
    ResolvedUnit unit,
  ) async =>
      const TargetReady();

  @override
  ProgressActivity get actActivity => ProgressActivity(
        running: 'updating',
        failed: 'update failed',
      );

  @override
  TargetExpectation expectation({
    required ResolvedUnit unit,
    required Step step,
    String? repository,
  }) {
    final project = unit.project(step.project!);
    final tap = repository == null ? unit.homebrewTap : unit.tapFor(repository);
    return TargetExpectation(
      label: tap == null ? 'Homebrew' : 'Homebrew · $tap',
      kindLabel: 'Homebrew',
      identity: tap ?? 'no tap configured',
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
  Future<Inspection> inspectExact(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetExpectation target,
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
  String? recoveryBinding(Inspection inspected) =>
      switch (inspected.authority) {
        HomebrewUpdateAuthority(:final recoveryBinding) => recoveryBinding,
        _ => null,
      };

  @override
  String conflictRemedy(
    ResolvedUnit unit,
    TargetExpectation target,
  ) =>
      'restore the cask to the exact release bytes it is meant to '
      'reference, or advance the source version intentionally; then '
      'run rk status ${unit.name} again';

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
      ),
      halt: halt,
    );
  }

  @override
  TargetStage stage({
    required ResolvedUnit unit,
    required TargetExpectation target,
  }) {
    final tag = requiredTargetTag(unit, PublishTarget.homebrew);
    final project = target.project!;
    final executable = project.executable!;
    final archives = {
      for (final platform in project.binaryPlatforms)
        ReleaseAssets.archivePath(project, platform),
    };
    final contract = StageContributionContract(
      phase: StageContributionPhase.afterArtifacts,
      step: StageStepContract(
        'homebrew-cask:${project.name}',
        inputs: archives,
        outputs: {ReleaseAssets.caskPath(project): 'cask'},
        validate: (context, step) {
          final repository = context.repository;
          if (repository == null) {
            return const [
              StageIssue(
                StageIssueKind.invalidStructure,
                'homebrew-cask has no repository identity',
                path: 'stage.json',
              ),
            ];
          }
          final publicArchives = {
            for (final platform in project.binaryPlatforms)
              platform: PlatformAsset(
                name: ReleaseAssets.archiveName(
                  executable,
                  project.version.canonical,
                  platform,
                ),
                sha256: context.receipt.steps
                    .singleWhere((item) =>
                        item.name == archiveReceiptName(project.name, platform))
                    .outputs
                    .single
                    .sha256,
              ),
          };
          final expected = HomebrewCask.renderRelease(
            token: ReleaseAssets.caskToken(executable),
            version: project.version.canonical,
            repository: repository,
            tag: tag,
            executable: executable,
            assets: publicArchives,
          );
          final actual = File(
            context.stage.resolve(ReleaseAssets.caskPath(project)),
          );
          if (actual.existsSync() && actual.readAsStringSync() == expected) {
            return const [];
          }
          return const [
            StageIssue(
              StageIssueKind.invalidStructure,
              'homebrew-cask does not match the staged archives',
              path: 'stage.json',
            ),
          ];
        },
      ),
    );
    return TargetStage(
      target: target,
      contract: contract,
      progress: [
        TargetStageProgress.output(
          id: 'cask',
          output: ReleaseAssets.caskPath(target.project!),
          artifact: ReleaseAssets.caskName(target.project!.executable!),
        ),
      ],
      prepare: (context) => _prepareStage(context, unit, target),
    );
  }

  Future<TargetStageOutcome> _prepareStage(
    TargetStageContext context,
    ResolvedUnit unit,
    TargetExpectation target,
  ) async {
    final tag = requiredTargetTag(unit, PublishTarget.homebrew);
    final receiptName = context.contract.step.name;
    final repository = context.repository;
    if (repository == null) {
      return TargetStageFailure(
        Diagnostic(
          code: 'RK-GIT-002',
          message: 'homebrew needs an origin remote, and this repository '
              'has none',
          remedy: 'rk publishes what others can fetch, and reads back what it '
              'published. git remote add origin <url>, then git push -u '
              'origin ${context.git.branch ?? 'main'}',
        ),
      );
    }

    final project = target.project!;
    final archives = <String, StageArtifact>{};
    for (final platform in project.binaryPlatforms) {
      final record = context.priorSteps
          .where(
              (step) => step.name == archiveReceiptName(project.name, platform))
          .firstOrNull;
      final artifact = record?.outputs
          .where((output) => output.type == 'archive')
          .firstOrNull;
      if (artifact == null) {
        return TargetStageFailure(
          Diagnostic(
            code: 'RK-WORK-001',
            message: 'the workspace has no archive for $platform',
            remedy: 'the archive step produces it — re-running runs it',
          ),
          unit: unit.name,
        );
      }
      archives[platform] = artifact;
    }
    final executable = project.executable!;
    context.progress('cask').begin(
          ProgressActivity(
            running: 'rendering',
            failed: 'rendering failed',
          ),
        );
    final contents = HomebrewCask.renderRelease(
      token: ReleaseAssets.caskToken(executable),
      version: project.version.canonical,
      repository: repository,
      tag: tag,
      executable: executable,
      assets: {
        for (final MapEntry(key: platform, value: archive) in archives.entries)
          platform: PlatformAsset(
            name: ReleaseAssets.archiveName(
              executable,
              project.version.canonical,
              platform,
            ),
            sha256: archive.sha256,
          ),
      },
    );
    context.workspace.write(
      ReleaseAssets.caskPath(project),
      utf8.encode(contents),
    );
    return TargetStageSuccess(
      StageStep(
        name: receiptName,
        inputs: [
          for (final archive in archives.values) StageInput.artifact(archive),
        ],
        outputs: [
          StageArtifact.capture(
            stage: context.stage.directory,
            path: ReleaseAssets.caskPath(project),
            type: 'cask',
          ),
        ],
      ),
    );
  }
}
