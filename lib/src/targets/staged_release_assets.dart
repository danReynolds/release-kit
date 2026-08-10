import '../engine/assets.dart';
import '../engine/diagnostic.dart';
import '../engine/resolve.dart';
import '../engine/workspace.dart';
import '../output/output.dart';

/// Reads the exact public assets a target needs from the validated stage.
final class StagedReleaseAssets {
  const StagedReleaseAssets({required this.workspace, required this.output});

  final Workspace workspace;
  final Output output;

  List<StagedReleaseAsset>? gather(
    ResolvedProject project,
    String unit, {
    bool includeFinal = true,
  }) {
    final assets = <StagedReleaseAsset>[];
    StagedReleaseAsset? named(
      String name,
      String producer, {
      String? platform,
    }) {
      final bytes = workspace.readBytes(name);
      if (bytes == null) {
        output.problem(
          Diagnostic(
            code: 'RK-WORK-001',
            message: 'the workspace has no $name',
            remedy: '$producer — re-running runs it',
          ),
          unit: unit,
        );
        return null;
      }
      return StagedReleaseAsset(
        name: name,
        path: workspace.pathOf(name),
        bytes: bytes,
        platform: platform,
      );
    }

    for (final platform in project.binaryPlatforms) {
      final executable = project.executable!;
      final version = project.version.canonical;
      final archive = named(
        ReleaseAssets.archiveName(executable, version, platform),
        'the archive steps produce it',
        platform: platform,
      );
      if (archive == null) return null;
      assets.add(archive);

      if (platform.startsWith('macos-')) {
        for (final evidence in [
          ReleaseAssets.notaryResultName(executable, version, platform),
          ReleaseAssets.notaryLogName(executable, version, platform),
        ]) {
          final asset = named(evidence, 'the notarize step produces it');
          if (asset == null) return null;
          assets.add(asset);
        }
      }
    }

    final sums =
        named(ReleaseAssets.checksums, 'the checksums step produces it');
    if (sums == null) return null;
    assets.add(sums);

    if (includeFinal) {
      if (project.channels.contains('homebrew')) {
        final formula = named(
          ReleaseAssets.formulaName(project.executable!),
          'the staging phase renders it',
        );
        if (formula == null) return null;
        assets.add(formula);
      }
      final manifest = named(
        ReleaseAssets.manifest,
        'the complete-stage step produces it',
      );
      if (manifest == null) return null;
      assets.add(manifest);
    }
    return assets;
  }
}

final class StagedReleaseAsset {
  const StagedReleaseAsset({
    required this.name,
    required this.path,
    required this.bytes,
    required this.platform,
  });

  final String name;
  final String path;
  final List<int> bytes;
  final String? platform;
}
