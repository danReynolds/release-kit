import 'dart:convert';
import 'dart:io';

import '../destinations/homebrew.dart';
import '../engine/assets.dart';
import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/resolve.dart';
import '../engine/stage_contract.dart';
import '../engine/stage_inspection.dart';
import '../engine/stage_receipt.dart';
import '../engine/targets.dart';
import '../engine/verdict.dart';
import '../output/output.dart';
import '../transforms/digest.dart';
import 'published_release_evidence.dart';
import 'staged_release_assets.dart';
import 'target_module.dart';
import 'target_release.dart';

final class HomebrewTargetModule extends TargetReleaseModule {
  const HomebrewTargetModule();

  @override
  ReleaseTargetKind get kind => ReleaseTargetKind.homebrew;

  @override
  StepKind get stepKind => StepKind.publishFormula;

  @override
  bool get isPermanent => false;

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
      orElse: () => unit.binaryProject,
    );
    final tap = repository == null ? unit.homebrewTap : unit.tapFor(repository);
    return TargetExpectation(
      kind: kind,
      label: tap == null ? 'Homebrew' : 'Homebrew · $tap',
      coordinate: tap == null
          ? 'Formula/${project.executable}.rb'
          : '$tap/Formula/${project.executable}.rb',
      targetVersion: project.version.canonical,
      step: step,
      project: project,
      // The formula is a GitHub Release artifact too. Its bytes are listed
      // once under the target that owns the artifact inventory.
      artifacts: const [],
      uses: '${ReleaseAssets.formulaName(project.executable!)} from '
          'GitHub Release',
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
      return const Inspection.unknown('not read: --offline');
    }
    final repository = context.repository;
    if (repository == null) {
      return const Inspection.unknown('no origin remote to ask');
    }
    final tap = unit.tapFor(repository);
    final project = unit.binaryProject;
    final executable = project.executable!;
    final stage = context.reusableStage(unit);
    final name = ReleaseAssets.formulaName(executable);
    List<int>? expectedBytes;
    if (stage != null) {
      final expected = File(stage.directory.resolve(name));
      if (!expected.existsSync()) {
        return Inspection.conflict('the completed stage has no $name');
      }
      expectedBytes = expected.readAsBytesSync();
    } else if (context.git.hasTag(unit.tag)) {
      final current = await PublishedReleaseEvidence(context)
          .currentManifestAsset(unit, name);
      if (current.inspection.verdict == Verdict.conflict ||
          current.inspection.verdict == Verdict.unknown) {
        return current.inspection;
      }
      expectedBytes = current.bytes;
    }

    return HomebrewTarget(
      tools: tools,
      tap: tap,
      workingDirectory: context.git.root,
    ).inspect(
      formulaPath: 'Formula/$executable.rb',
      expectedBytes: expectedBytes,
      inspectEarlierRelease: (bytes) =>
          PublishedReleaseEvidence(context).inspectEarlierFormula(unit, bytes),
    );
  }

  @override
  Future<Inspection> inspectLatest(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetExpectation target,
  ) =>
      Future.value(
        const Inspection.unknown(
          'the formula inspection owns the current version',
        ),
      );

  @override
  Inspection currentVersionInspection({
    required Inspection exact,
    required Inspection latest,
  }) =>
      exact;

  @override
  bool get latestVersionGuardsRelease => false;

  @override
  bool get unknownMayWaitForStage => true;

  @override
  String conflictRemedy(
    ResolvedUnit unit,
    TargetExpectation target,
  ) =>
      'restore the formula to the exact release bytes it is meant to '
      'reference, or advance the source version intentionally; then '
      'run rk status ${unit.name} again';

  @override
  Map<String, String> artifactsBlockedByIncompleteArchives(
    ResolvedUnit unit,
    TargetExpectation target,
    String archiveProblem,
  ) =>
      {
        ReleaseAssets.formulaName(target.project!.executable!):
            'cannot be rendered until every archive exists: $archiveProblem',
      };

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
        problem: 'the formula update has no exact public base; re-run so rk '
            'can inspect the tap before updating it',
      );
    }
    final project = unit.binaryProject;
    final executable = project.executable!;
    final formula =
        context.workspace.readBytes(ReleaseAssets.formulaName(executable));
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
      formulaPath: 'Formula/$executable.rb',
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
      ),
      halt: halt,
    );
  }

  @override
  StageContributionContract stageContract({
    required ResolvedUnit unit,
    required TargetExpectation target,
    required String? repository,
    required String sourceRoot,
  }) {
    final project = target.project!;
    final executable = project.executable!;
    final archives = {
      for (final platform in project.binaryPlatforms)
        ReleaseAssets.archiveName(
          executable,
          project.version.canonical,
          platform,
        ),
    };
    return StageContributionContract(
      phase: StageContributionPhase.afterProducers,
      step: StageStepContract(
        'homebrew-formula',
        inputs: archives,
        outputs: {ReleaseAssets.formulaName(executable): 'formula'},
        validate: (context, step) {
          final repository = context.repository;
          if (repository == null) {
            return const [
              StageIssue(
                StageIssueKind.invalidStructure,
                'homebrew-formula has no repository identity',
                path: 'stage.json',
              ),
            ];
          }
          final publicArchives = {
            for (final receiptStep in context.receipt.steps.where(
              (item) => item.name.startsWith('archive:'),
            ))
              receiptStep.name.substring('archive:'.length): PlatformAsset(
                name: receiptStep.outputs.single.path,
                sha256: receiptStep.outputs.single.sha256,
              ),
          };
          final expected = HomebrewFormula.render(
            className: HomebrewFormula.classNameFor(executable),
            description: 'Released by rk',
            homepage: 'https://github.com/$repository',
            version: project.version.canonical,
            repository: repository,
            tag: unit.tag,
            executable: executable,
            assets: publicArchives,
          );
          final actual = File(
            context.stage.resolve(ReleaseAssets.formulaName(executable)),
          );
          if (actual.existsSync() && actual.readAsStringSync() == expected) {
            return const [];
          }
          return const [
            StageIssue(
              StageIssueKind.invalidStructure,
              'homebrew-formula does not match the staged archives',
              path: 'stage.json',
            ),
          ];
        },
      ),
    );
  }

  @override
  Future<TargetStageResult> prepareStage(
    TargetStageContext context,
    ResolvedUnit unit,
    TargetExpectation target,
  ) async {
    final receiptName = context.contract.step.name;
    if (context.progress.any((record) => record.name == receiptName)) {
      return TargetStageResult.succeeded();
    }
    final repository = context.repository;
    if (repository == null) {
      context.output.problem(
        Diagnostic(
          code: 'RK-GIT-002',
          message: 'homebrew needs an origin remote, and this repository '
              'has none',
          remedy: 'rk publishes what others can fetch, and reads back what it '
              'published. git remote add origin <url>, then git push -u '
              'origin ${context.git.branch ?? 'main'}',
        ),
      );
      context.output.halt(HaltKind.beforeActing);
      return const TargetStageResult.failed();
    }

    final project = target.project!;
    final core = StagedReleaseAssets(
      workspace: context.workspace,
      output: context.output,
    ).gather(
      project,
      unit.name,
      includeFinal: false,
    );
    if (core == null) return const TargetStageResult.failed();
    context.output.report.acted = true;
    final executable = project.executable!;
    final contents = HomebrewFormula.render(
      className: HomebrewFormula.classNameFor(executable),
      description: 'Released by rk',
      homepage: 'https://github.com/$repository',
      version: project.version.canonical,
      repository: repository,
      tag: unit.tag,
      executable: executable,
      assets: {
        for (final asset in core)
          if (asset.platform != null)
            asset.platform!: PlatformAsset(
              name: asset.name,
              sha256: Sha256.hex(asset.bytes),
            ),
      },
    );
    context.workspace.write(
      ReleaseAssets.formulaName(executable),
      utf8.encode(contents),
    );
    final archives = context.progress
        .where((record) => record.name.startsWith('archive:'))
        .expand((record) => record.outputs)
        .where((artifact) => artifact.type == 'archive')
        .toList();
    return TargetStageResult.succeeded(
      steps: [
        StageStep(
          name: receiptName,
          inputs: [
            for (final archive in archives) StageInput.artifact(archive),
          ],
          outputs: [
            StageArtifact.capture(
              stage: context.stage.directory,
              path: ReleaseAssets.formulaName(project.executable!),
              type: 'formula',
            ),
          ],
        ),
      ],
    );
  }
}
