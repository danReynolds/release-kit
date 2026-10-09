import 'dart:convert';

import '../../engine/assets.dart';
import '../../engine/unit_release.dart';
import '../target_module.dart';
import 'client.dart';

/// Stages Homebrew's formula: rendered after the archives it names, from the
/// digests their receipts record, with the renderer lost-stage recovery uses.
Future<Produced> prepareFormula(StageRun run, Work work) async {
  final unit = run.unit;
  // The release refused a unit with no origin before anything was staged:
  // a GitHub release cannot be read without one.
  final repository = run.repository!;
  final project = work.project!;
  // The formula runs once every archive it names is recorded.
  final recorded = run.stage.receipt!.files;

  final executable = project.executable!;
  run.rows?.begin((running: 'rendering', failed: 'rendering failed'));
  final contents = HomebrewFormula.renderRelease(
    className: ReleaseAssets.formulaClass(executable),
    version: project.version.canonical,
    repository: repository,
    tag: unit.tag!,
    executable: executable,
    assets: {
      for (final archive in work.inputs)
        archive.platform!: PlatformAsset(
          name: ReleaseAssets.archiveName(
            executable,
            project.version.canonical,
            archive.platform!,
          ),
          sha256: recorded[archive.outputs.single]!.sha256,
        ),
    },
  );
  run.stage.write(work.outputs.single, utf8.encode(contents));
  return const Produced();
}
