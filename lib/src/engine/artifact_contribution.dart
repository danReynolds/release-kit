import 'stage.dart';
import 'stage_receipt.dart';

/// The current standalone Dart producer's public archive convention.
///
/// Kept in this dependency-free artifact layer so resolution can detect
/// public-name collisions before a stage or producer writes anything, while
/// destination code and producers share the identical spelling.
String standaloneArchiveName(
  String executable,
  String version,
  String platform,
) =>
    '$executable-$version-$platform.tar.gz';

/// The stable identity of one private output before producer work begins.
///
/// This is the plan-side half of [ProducedBlob]. It lets rk validate output
/// ownership and public-name collisions before any producer writes a file.
final class ProducedBlobRef {
  ProducedBlobRef({
    required this.producerId,
    required String stagedPath,
    required this.type,
    required this.mediaType,
    this.platform,
    this.project,
  }) : stagedPath = StagePath.require(stagedPath) {
    _requireToken(producerId, 'producer id');
    _requireToken(type, 'blob type');
    _requireMediaType(mediaType);
    if (platform case final value?) _requireToken(value, 'platform');
    if (project case final value?) _requireToken(value, 'project');
  }

  final String producerId;
  final String stagedPath;
  final String type;
  final String mediaType;
  final String? platform;
  final String? project;
}

/// Exact captured bytes emitted by a local producer.
///
/// A blob is private merely because it exists. [ReleaseAssetContribution] is
/// the separate projection that gives it a public filename.
final class ProducedBlob {
  ProducedBlob({required this.ref, required this.artifact}) {
    if (artifact.path != ref.stagedPath || artifact.type != ref.type) {
      throw ArgumentError(
        'captured artifact does not match ${ref.producerId} output '
        '${ref.stagedPath}',
      );
    }
  }

  final ProducedBlobRef ref;
  final StageArtifact artifact;

  String get producerId => ref.producerId;
  String get stagedPath => artifact.path;
  String get type => artifact.type;
  String get mediaType => ref.mediaType;
  int get size => artifact.size;
  String get sha256 => artifact.sha256;
  String? get platform => ref.platform;
  String? get project => ref.project;
}

/// A static, pre-write projection of one private output into public release
/// inventory. Ordinary producer contributions cannot claim rk-owned names.
final class ReleaseAssetSpec {
  ReleaseAssetSpec({required this.blob, required this.publicName}) {
    _requirePublicName(publicName, allowGenerated: false);
  }

  ReleaseAssetSpec.generated({required this.blob, required this.publicName}) {
    _requirePublicName(publicName, allowGenerated: true);
    if (publicName.toLowerCase() != 'sha256sums') {
      throw ArgumentError('unknown generated release asset: $publicName');
    }
  }

  final ProducedBlobRef blob;
  final String publicName;
}

/// An exact public projection after the referenced bytes have been captured.
final class ReleaseAssetContribution {
  ReleaseAssetContribution({required this.spec, required this.blob}) {
    if (!identical(spec.blob, blob.ref) &&
        (spec.blob.producerId != blob.ref.producerId ||
            spec.blob.stagedPath != blob.ref.stagedPath ||
            spec.blob.type != blob.ref.type ||
            spec.blob.mediaType != blob.ref.mediaType)) {
      throw ArgumentError('contribution captured a different produced blob');
    }
  }

  final ReleaseAssetSpec spec;
  final ProducedBlob blob;
  String get publicName => spec.publicName;
}

/// Validates and deterministically orders a planned public inventory.
List<ReleaseAssetSpec> validateReleaseAssetSpecs(
  Iterable<ReleaseAssetSpec> specs,
) =>
    _aggregate(specs, (spec) => spec.publicName);

/// Validates and deterministically orders one release's captured inventory.
List<ReleaseAssetContribution> aggregateReleaseAssets(
  Iterable<ReleaseAssetContribution> contributions,
) =>
    _aggregate(contributions, (contribution) => contribution.publicName);

List<T> _aggregate<T>(Iterable<T> values, String Function(T) nameOf) {
  final byName = <String, T>{};
  for (final value in values) {
    final name = nameOf(value);
    final normalized = name.toLowerCase();
    if (byName.containsKey(normalized)) {
      throw ArgumentError('two release assets use the public filename "$name"');
    }
    byName[normalized] = value;
  }
  if (byName.isEmpty) return List<T>.unmodifiable(const []);
  final ordered = byName.values.toList()
    ..sort((left, right) => nameOf(left).compareTo(nameOf(right)));
  return List<T>.unmodifiable(ordered);
}

final RegExp _token = RegExp(r'^[a-z0-9][a-z0-9._-]*$');

void _requireToken(String value, String label) {
  if (!_token.hasMatch(value)) {
    throw ArgumentError('$label must be a stable lowercase token: $value');
  }
}

void _requireMediaType(String value) {
  if (!RegExp(r'^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$')
      .hasMatch(value)) {
    throw ArgumentError('media type must be a stable lowercase type: $value');
  }
}

void _requirePublicName(String value, {required bool allowGenerated}) {
  final reserved = const {'sha256sums', 'release-manifest.json'}
      .contains(value.toLowerCase());
  if (value.isEmpty ||
      value == '.' ||
      value == '..' ||
      value.contains('/') ||
      value.contains(r'\') ||
      (reserved && !allowGenerated) ||
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    throw ArgumentError('public asset name must be one safe filename: $value');
  }
}
