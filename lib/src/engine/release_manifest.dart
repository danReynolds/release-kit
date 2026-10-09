import 'assets.dart';
import 'canonical_json.dart';
import 'receipt.dart';
import 'unit_release.dart';

/// The only public release-manifest schema this build accepts.
///
/// Schema 7 is the Formula-only contract. Older schemas are not
/// migrated because their Homebrew coordinates no longer belong to this model.
const releaseManifestSchemaVersion = 7;

/// One public file: its name, what it is, and its bytes' size and digest.
typedef ManifestFile = ({String name, String type, int size, String sha256});

/// The formula a release puts in its tap, and where.
typedef ManifestFormula = ({
  String project,
  String tap,
  String path,
  int size,
  String sha256,
});

/// The publishable release inventory: the files a release publishes and the
/// commit it is of, which a tag binds by digest.
///
/// It has no local path, command, environment, credential, log, or other
/// evidence: those stay in the stage's receipt, so they cannot leak merely
/// by writing this.
final class ReleaseManifest {
  ReleaseManifest({
    required this.unit,
    required this.version,
    required this.tag,
    required this.commit,
    required Iterable<ManifestFile> artifacts,
    this.homebrew,
  }) : artifacts = List.unmodifiable(
         artifacts.toList()
           ..sort((left, right) => left.name.compareTo(right.name)),
       );

  /// The manifest of [release], from the files [receipt] records.
  factory ReleaseManifest.of(UnitRelease release, Receipt receipt) {
    final unit = release.unit;
    final type = unit.assetProject == null ? 'archive' : 'asset';
    final formula = release.homebrew;
    final ManifestFormula? homebrew;
    if (formula == null) {
      homebrew = null;
    } else {
      final staged = receipt.files[formula.files.single.path]!;
      homebrew = (
        project: formula.project!.name,
        tap: unit.tapFor(release.repository!),
        path:
            'Formula/${ReleaseAssets.formulaName(formula.project!.executable!)}',
        size: staged.size,
        sha256: staged.sha256,
      );
    }
    return ReleaseManifest(
      unit: unit.name,
      version: unit.version.canonical,
      tag: unit.tag,
      commit: receipt.stage.commit,
      artifacts: [
        for (final asset in release.assets)
          (
            name: asset.name!,
            type: type,
            size: receipt.files[asset.path]!.size,
            sha256: receipt.files[asset.path]!.sha256,
          ),
      ],
      homebrew: homebrew,
    );
  }

  /// A manifest a release published, as `rk use` reads it back.
  factory ReleaseManifest.parse(String document) {
    final decoded = CanonicalJson.decodeDocument(document);
    final schema = decoded is Map ? decoded['schema'] : null;
    if (schema != releaseManifestSchemaVersion) {
      throw FormatException('unsupported release manifest schema: $schema');
    }
    try {
      final map = decoded as Map<String, Object?>;
      final source = map['source'] as Map<String, Object?>;
      final formula = map['homebrew'] as Map<String, Object?>?;
      return ReleaseManifest(
        unit: map['unit'] as String,
        version: map['version'] as String,
        tag: map['tag'] as String?,
        commit: source['commit'] as String?,
        artifacts: [
          for (final file in (map['artifacts'] as List).cast<Map>())
            (
              name: file['name'] as String,
              type: file['type'] as String,
              size: file['size'] as int,
              sha256: file['sha256'] as String,
            ),
        ],
        homebrew: formula == null
            ? null
            : (
                project: formula['project'] as String,
                tap: formula['tap'] as String,
                path: formula['path'] as String,
                size: formula['size'] as int,
                sha256: formula['sha256'] as String,
              ),
      );
    } on TypeError catch (error) {
      throw FormatException('the release manifest is malformed: $error');
    }
  }

  final String unit;
  final String version;
  final String? tag;

  /// The released source commit when Git supplies an externally checkable
  /// anchor. An unbound source records null: rk does not invent a revision.
  final String? commit;

  final List<ManifestFile> artifacts;
  final ManifestFormula? homebrew;

  Map<String, Object?> toJson() => {
    'artifacts': [
      for (final file in artifacts)
        {
          'name': file.name,
          'sha256': file.sha256,
          'size': file.size,
          'type': file.type,
        },
    ],
    'homebrew': switch (homebrew) {
      null => null,
      final formula => {
        'path': formula.path,
        'project': formula.project,
        'sha256': formula.sha256,
        'size': formula.size,
        'tap': formula.tap,
      },
    },
    'schema': releaseManifestSchemaVersion,
    'source': {'commit': commit},
    'tag': tag,
    'unit': unit,
    'version': version,
  };

  String encode() => '${CanonicalJson.encode(toJson())}\n';
}
