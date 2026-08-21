import 'assets.dart';
import 'release_stage.dart';
import 'resolve.dart';
import 'stage_receipt.dart';

/// One completed-stage artifact under the public name a target publishes.
///
/// Targets should not reconstruct this binding from producer paths. The
/// complete-stage receipt is the authority for both the private bytes and the
/// public inventory reviewed by the operator.
final class ReleaseBundleAsset {
  const ReleaseBundleAsset({
    required this.publicName,
    required this.artifact,
  });

  final String publicName;
  final StageArtifact artifact;
}

/// The exact public bundle frozen by a completed release stage.
final class ReleaseBundle {
  ReleaseBundle._(Iterable<ReleaseBundleAsset> assets)
      : assets = List<ReleaseBundleAsset>.unmodifiable(assets);

  /// Resolves the configured bundle against the completed receipt.
  ///
  /// A failure is returned as data because a missing binding is an RK stage
  /// problem that a target must report before attempting its provider call.
  static ReleaseBundleResolution resolve(
    ReleaseStage stage,
    ResolvedUnit unit,
  ) {
    final receipt = stage.requireReceipt();
    final frozen = stage.releaseAssets();
    final manifest = receipt.artifacts.where(
      (artifact) => artifact.path == ReleaseAssets.manifest,
    );
    if (manifest.length != 1) {
      return const ReleaseBundleResolution.invalid(
        message: 'the completed stage has no exact release-manifest.json '
            'binding',
        publicName: ReleaseAssets.manifest,
        producer: 'the complete-stage step',
      );
    }

    final planned = <String, String>{
      for (final asset in ReleaseAssets.bundleFor(unit))
        asset.publicName: asset.stagedPath,
      ReleaseAssets.manifest: ReleaseAssets.manifest,
    };
    final actualNames = {...frozen.keys, ReleaseAssets.manifest};
    final missing = planned.keys.toSet().difference(actualNames);
    final extra = actualNames.difference(planned.keys.toSet());
    if (missing.isNotEmpty || extra.isNotEmpty) {
      return ReleaseBundleResolution.invalid(
        message: 'the completed stage has a different release-asset '
            'inventory',
        evidence: {
          for (final name in missing) name: 'missing from stage',
          for (final name in extra) name: 'not expected by this target',
        },
      );
    }
    final assets = <ReleaseBundleAsset>[];
    for (final entry in planned.entries) {
      final artifact = entry.key == ReleaseAssets.manifest
          ? manifest.single
          : frozen[entry.key];
      if (artifact == null || artifact.path != entry.value) {
        return ReleaseBundleResolution.invalid(
          message: 'the completed stage has no exact ${entry.key} binding',
          publicName: entry.key,
          producer: entry.key == ReleaseAssets.manifest
              ? 'the complete-stage step'
              : 'the archive steps',
        );
      }
      assets.add(ReleaseBundleAsset(
        publicName: entry.key,
        artifact: artifact,
      ));
    }
    return ReleaseBundleResolution.available(ReleaseBundle._(assets));
  }

  final List<ReleaseBundleAsset> assets;

  Set<String> get publicNames => {
        for (final asset in assets) asset.publicName,
      };

  Map<String, String> get sha256ByPublicName => {
        for (final asset in assets) asset.publicName: asset.artifact.sha256,
      };
}

/// Result of joining a release plan to its completed-stage artifacts.
sealed class ReleaseBundleResolution {
  const ReleaseBundleResolution();

  const factory ReleaseBundleResolution.available(ReleaseBundle bundle) =
      ReleaseBundleAvailable;

  const factory ReleaseBundleResolution.invalid({
    required String message,
    String? publicName,
    String? producer,
    Map<String, String> evidence,
  }) = ReleaseBundleInvalid;
}

final class ReleaseBundleAvailable extends ReleaseBundleResolution {
  const ReleaseBundleAvailable(this.bundle);

  final ReleaseBundle bundle;
}

final class ReleaseBundleInvalid extends ReleaseBundleResolution {
  const ReleaseBundleInvalid({
    required this.message,
    this.publicName,
    this.producer,
    this.evidence = const {},
  });

  final String message;
  final String? publicName;
  final String? producer;
  final Map<String, String> evidence;
}
