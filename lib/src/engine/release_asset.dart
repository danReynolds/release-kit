import 'stage.dart';

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

/// One static, pre-write projection from a private staged output to its public
/// release filename. Producer outputs cannot claim rk-owned names.
final class ReleaseAssetSpec {
  ReleaseAssetSpec({required String stagedPath, required this.publicName})
      : stagedPath = StagePath.require(stagedPath) {
    _requirePublicName(publicName);
  }

  final String stagedPath;
  final String publicName;
}

/// Validates and deterministically orders a planned public inventory.
List<ReleaseAssetSpec> validateReleaseAssetSpecs(
  Iterable<ReleaseAssetSpec> specs,
) {
  final byName = <String, ReleaseAssetSpec>{};
  for (final spec in specs) {
    final name = spec.publicName;
    final normalized = name.toLowerCase();
    if (byName.containsKey(normalized)) {
      throw ArgumentError('two release assets use the public filename "$name"');
    }
    byName[normalized] = spec;
  }
  if (byName.isEmpty) return List<ReleaseAssetSpec>.unmodifiable(const []);
  final ordered = byName.values.toList()
    ..sort((left, right) => left.publicName.compareTo(right.publicName));
  return List<ReleaseAssetSpec>.unmodifiable(ordered);
}

void _requirePublicName(String value) {
  final reserved = value.toLowerCase() == 'release-manifest.json';
  if (value.isEmpty ||
      value == '.' ||
      value == '..' ||
      value.contains('/') ||
      value.contains(r'\') ||
      reserved ||
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    throw ArgumentError('public asset name must be one safe filename: $value');
  }
}
