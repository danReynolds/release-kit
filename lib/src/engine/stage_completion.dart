import 'assets.dart';
import 'publish_target.dart';
import 'release_manifest.dart';
import 'resolve.dart';
import 'stage_receipt.dart';

/// The release manifest and publication bindings a stage completes with,
/// derived from the unit and its producers' recorded outputs.
final class StageCompletion {
  StageCompletion({
    required ResolvedUnit unit,
    required String? repository,
    required String? commit,
    required Iterable<StageArtifact> artifacts,
    required Iterable<ReleaseAsset> releaseAssets,
  }) {
    final specs = releaseAssets.toList()
      ..sort((a, b) => a.publicName.compareTo(b.publicName));
    final byPath = {for (final artifact in artifacts) artifact.path: artifact};
    final homebrew = homebrewFor(unit, repository);
    final bindings = {
      for (final spec in specs) spec.publicName: spec.stagedPath,
    };
    final paths = {
      ...bindings.values,
      if (homebrew != null) homebrew.stagedPath,
    };
    if (paths.length != specs.length + (homebrew == null ? 0 : 1)) {
      throw StateError('completion inventory repeats a staged artifact');
    }
    if (!byPath.keys.toSet().containsAll(paths)) {
      throw StateError('completion inventory is missing producer artifacts');
    }
    manifest = ReleaseManifest(
      unit: unit.name,
      version: unit.version.canonical,
      tag: unit.tag,
      commit: commit,
      artifacts: [
        for (final spec in specs)
          ReleaseManifestArtifact.fromStage(
            publicName: spec.publicName,
            artifact: byPath[spec.stagedPath]!,
          ),
      ],
      homebrew: homebrew?.bind(byPath[homebrew.stagedPath]!),
    );
    evidence = Map.unmodifiable({
      'release_assets': Map.unmodifiable(bindings),
      'homebrew_binding': homebrew?.toEvidence(),
    });
  }

  late final ReleaseManifest manifest;
  late final Map<String, Object?> evidence;

  static StagedHomebrewBinding? homebrewFor(
    ResolvedUnit unit,
    String? repository,
  ) {
    if (unit.version.isPrerelease) return null;
    final project = unit.projects
        .where((project) => project.publish.contains(PublishTarget.homebrew))
        .firstOrNull;
    if (project == null) return null;
    if (repository == null) {
      throw StateError(
        'Homebrew formula bindings need a source repository coordinate',
      );
    }
    return StagedHomebrewBinding(
      project: project.name,
      tap: unit.tapFor(repository),
      path: 'Formula/${ReleaseAssets.formulaName(project.executable!)}',
      stagedPath: ReleaseAssets.formulaPath(project),
    );
  }
}
