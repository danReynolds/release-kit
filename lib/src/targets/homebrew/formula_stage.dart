import 'dart:convert';

import '../../engine/assets.dart';
import '../../engine/diagnostic.dart';
import '../../engine/producers.dart';
import '../../engine/publish_target.dart';
import '../../engine/resolve.dart';
import '../../engine/stage_contract.dart';
import '../../engine/stage_receipt.dart';
import '../../engine/targets.dart';
import '../../output/progress.dart';
import '../target_module.dart';
import 'client.dart';

/// Homebrew's formula-rendering contribution to the reusable release stage.
///
/// It runs after the archives it names and renders the formula from the
/// digests their receipts record, with the renderer lost-stage recovery uses.
TargetStage homebrewFormulaStage({
  required ResolvedUnit unit,
  required TargetPlan target,
}) {
  final project = target.project!;
  final archives = {
    for (final platform in project.binaryPlatforms)
      ReleaseAssets.archivePath(project, platform),
  };
  final contract = StageStepContract(
    'homebrew-formula:${project.name}',
    inputs: archives,
    outputs: {ReleaseAssets.formulaPath(project): 'formula'},
  );
  return TargetStage(
    target: target,
    contract: contract,
    planLabel: 'Homebrew formula',
    progress: [
      TargetStageProgress.output(
        id: 'formula',
        output: ReleaseAssets.formulaPath(target.project!),
        artifact: ReleaseAssets.formulaName(target.project!.executable!),
      ),
    ],
    prepare: (context) => _prepareStage(context, unit, target),
  );
}

Future<TargetStageOutcome> _prepareStage(
  TargetStageContext context,
  ResolvedUnit unit,
  TargetPlan target,
) async {
  final tag = requiredTargetTag(unit, PublishTarget.homebrew);
  final receiptName = context.contract.name;
  final repository = context.repository;
  if (repository == null) {
    return TargetStageFailure(
      Diagnostic(
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

  final project = target.project!;
  final archives = <String, StageArtifact>{};
  for (final platform in project.binaryPlatforms) {
    final record = context.priorSteps
        .where(
          (step) => step.name == archiveReceiptName(project.name, platform),
        )
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
  context
      .progress('formula')
      .begin(
        ProgressActivity(running: 'rendering', failed: 'rendering failed'),
      );
  final contents = HomebrewFormula.renderRelease(
    className: ReleaseAssets.formulaClass(executable),
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
    ReleaseAssets.formulaPath(project),
    utf8.encode(contents),
  );
  return TargetStageSuccess(
    StageStep(
      name: receiptName,
      outputs: [
        StageArtifact.capture(
          stage: context.stage.directory,
          path: ReleaseAssets.formulaPath(project),
          type: 'formula',
        ),
      ],
    ),
  );
}
