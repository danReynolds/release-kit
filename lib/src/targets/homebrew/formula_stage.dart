import 'dart:convert';

import '../../engine/assets.dart';
import '../../engine/diagnostic.dart';
import '../../engine/publish_target.dart';
import '../../engine/stage_receipt.dart';
import '../../engine/unit_release.dart';
import '../../output/progress.dart';
import '../target_module.dart';
import 'client.dart';

/// Stages Homebrew's formula: rendered after the archives it names, from the
/// digests their receipts record, with the renderer lost-stage recovery uses.
Future<TargetStageOutcome> prepareFormula(
  TargetStageContext context,
  Work work,
) async {
  final unit = context.stage.unit;
  final tag = requiredTargetTag(unit, PublishTarget.homebrew);
  final repository = context.repository;
  if (repository == null) {
    return TargetStageFailure(
      Diagnostic(
        code: 'RK-GIT-002',
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

  final project = work.project!;
  final archives = <String, StageArtifact>{};
  for (final input in work.inputs) {
    final platform = input.platform!;
    final record = context.priorSteps
        .where((step) => step.name == input.name)
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
  context.progress?.begin(
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
      name: work.name,
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
