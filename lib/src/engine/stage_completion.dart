import 'dart:convert';

import '../transforms/digest.dart';
import 'assets.dart';
import 'canonical_json.dart';
import 'publish_target.dart';
import 'release_asset.dart';
import 'release_manifest.dart';
import 'resolve.dart';
import 'stage_inspection.dart';
import 'stage_plan.dart';
import 'stage_receipt.dart';

/// The deterministic terminal publication inventory. Construction reads no
/// stage files: it binds current release coordinates to prior producer records.
/// Production writes these exact bytes; portable authorization checks the same
/// commitment without pretending to have read an ancestor's manifest payload.
final class StageCompletion {
  StageCompletion({
    required ResolvedUnit unit,
    required String? repository,
    required String? commit,
    required Iterable<StageArtifact> artifacts,
    required Iterable<ReleaseAssetSpec> releaseAssets,
  }) {
    final specs = validateReleaseAssetSpecs(releaseAssets).toList()
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
    inputs = List.unmodifiable([
      for (final path in paths.toList()..sort())
        StageInput.artifact(byPath[path]!),
    ]);
    evidence = Map.unmodifiable({
      'release_assets': Map.unmodifiable(bindings),
      'homebrew_binding': homebrew?.toEvidence(),
    });
  }

  late final ReleaseManifest manifest;
  late final List<StageInput> inputs;
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

  static List<StageIssue> validate(
    StageReceipt receipt, {
    required ResolvedUnit unit,
    required String? repository,
    DartCompilerIdentity? compiler,
  }) {
    if (!receipt.complete) return const [];
    try {
      final expected = StageCompletion(
        unit: unit,
        repository: repository,
        commit: receipt.identity.headCommit,
        artifacts: receipt.steps
            .take(receipt.steps.length - 1)
            .expand((s) => s.outputs),
        releaseAssets: ReleaseAssets.bundleFor(unit),
      );
      final complete = receipt.steps.last;
      if (CanonicalJson.encode(
                complete.inputs.map((i) => i.toJson()).toList(),
              ) !=
              CanonicalJson.encode(
                expected.inputs.map((i) => i.toJson()).toList(),
              ) ||
          expected.evidence.entries.any(
            (entry) =>
                CanonicalJson.encode(complete.evidence[entry.key]) !=
                CanonicalJson.encode(entry.value),
          )) {
        throw StateError(
          'complete-stage does not bind the current publication inventory',
        );
      }
      final bytes = utf8.encode(expected.manifest.encode());
      final output = complete.outputs.single;
      if (output.path != ReleaseAssets.manifest ||
          output.type != 'manifest' ||
          output.size != bytes.length ||
          output.sha256 != Sha256.hex(bytes)) {
        throw StateError(
          'release manifest commitment differs from the current producer inventory',
        );
      }
      if (compiler != null &&
          DartCompilerIdentity.fromJson(complete.evidence['dart_compiler']) !=
              compiler) {
        throw StateError('completed stage records a different Dart compiler');
      }
      return const [];
    } on Object catch (error) {
      return [
        StageIssue(
          StageIssueKind.invalidManifest,
          '$error',
          path: 'stage.json',
        ),
      ];
    }
  }
}
