import 'dart:convert';

import 'canonical_json.dart';
import 'stage.dart';
import 'stage_receipt.dart';

const releaseManifestSchemaVersion = 1;

/// One public file, deliberately stripped of its local stage path and all
/// producer evidence.
class ReleaseManifestArtifact {
  ReleaseManifestArtifact({
    required this.name,
    required this.type,
    required this.size,
    required this.sha256,
  }) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains('\u0000') ||
        RegExp(r'^[A-Za-z]:').hasMatch(name)) {
      throw ArgumentError('public artifact name must be one filename: $name');
    }
    if (!RegExp(r'^[a-z][a-z0-9._-]*$').hasMatch(type)) {
      throw ArgumentError('artifact type is not a lowercase token: $type');
    }
    if (size < 0) {
      throw ArgumentError('artifact size cannot be negative');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw ArgumentError('artifact must carry a lowercase SHA-256 digest');
    }
  }

  factory ReleaseManifestArtifact.fromStage({
    required String publicName,
    required StageArtifact artifact,
  }) =>
      ReleaseManifestArtifact(
        name: publicName,
        type: artifact.type,
        size: artifact.size,
        sha256: artifact.sha256,
      );

  factory ReleaseManifestArtifact.fromJson(Object? value) {
    final map = _strictMap(
      value,
      const {'name', 'sha256', 'size', 'type'},
      'release artifact',
    );
    final size = map['size'];
    if (size is! int) {
      throw const FormatException('artifact size is not an integer');
    }
    return ReleaseManifestArtifact(
      name: _string(map, 'name'),
      type: _string(map, 'type'),
      size: size,
      sha256: _string(map, 'sha256'),
    );
  }

  final String name;
  final String type;
  final int size;
  final String sha256;

  Map<String, Object?> toJson() => {
        'name': name,
        'sha256': sha256,
        'size': size,
        'type': type,
      };
}

/// The publishable release inventory.
///
/// This model has no local path, command, environment, credential, log, or
/// free-form evidence field. Those belong only in the local stage receipt, so
/// they cannot leak merely by serializing this object.
class ReleaseManifest {
  ReleaseManifest({
    required this.unit,
    required this.version,
    required this.tag,
    required this.identity,
    required Iterable<ReleaseManifestArtifact> artifacts,
  }) : artifacts = List<ReleaseManifestArtifact>.unmodifiable(
          artifacts.toList()
            ..sort((left, right) => left.name.compareTo(right.name)),
        ) {
    _requirePublicText('unit', unit);
    _requirePublicText('version', version);
    _requirePublicText('tag', tag);
    final names = <String>{};
    for (final artifact in this.artifacts) {
      if (!names.add(artifact.name)) {
        throw ArgumentError('duplicate public artifact: ${artifact.name}');
      }
    }
  }

  factory ReleaseManifest.parse(String document) {
    final decoded = CanonicalJson.decodeDocument(document);
    final map = _strictMap(
      decoded,
      const {
        'artifacts',
        'schema',
        'source',
        'stage_id',
        'tag',
        'unit',
        'version'
      },
      'release manifest',
    );
    if (map['schema'] != releaseManifestSchemaVersion) {
      throw FormatException(
          'unsupported release manifest schema: ${map['schema']}');
    }
    final source = _strictMap(
      map['source'],
      const {'commit', 'plan_sha256', 'tree'},
      'release source',
    );
    final identity = StageIdentity.fromDigests(
      headCommit: _string(source, 'commit'),
      headTree: _string(source, 'tree'),
      planSha256: _string(source, 'plan_sha256'),
    );
    if (_string(map, 'stage_id') != identity.id) {
      throw const FormatException(
          'manifest stage ID does not match its source');
    }
    final artifacts = map['artifacts'];
    if (artifacts is! List) {
      throw const FormatException('manifest artifacts is not an array');
    }
    return ReleaseManifest(
      unit: _string(map, 'unit'),
      version: _string(map, 'version'),
      tag: _string(map, 'tag'),
      identity: identity,
      artifacts: artifacts.map(ReleaseManifestArtifact.fromJson),
    );
  }

  final String unit;
  final String version;
  final String tag;
  final StageIdentity identity;
  final List<ReleaseManifestArtifact> artifacts;

  Map<String, Object?> toJson() => {
        'artifacts': artifacts.map((artifact) => artifact.toJson()).toList(),
        'schema': releaseManifestSchemaVersion,
        'source': {
          'commit': identity.headCommit,
          'plan_sha256': identity.planSha256,
          'tree': identity.headTree,
        },
        'stage_id': identity.id,
        'tag': tag,
        'unit': unit,
        'version': version,
      };

  String encode() => '${CanonicalJson.encode(toJson())}\n';

  /// Places the public document atomically. The caller then captures it as a
  /// `manifest` output in the local receipt like any other staged artifact.
  void writeTo(StageDirectory stage, {String path = 'release-manifest.json'}) {
    if (stage.identity.id != identity.id) {
      throw StateError('release manifest belongs to a different stage');
    }
    stage.writeBytesAtomically(path, utf8.encode(encode()));
  }
}

Map<String, Object?> _strictMap(
  Object? value,
  Set<String> keys,
  String label,
) {
  if (value is! Map) throw FormatException('$label is not an object');
  final map = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$label has a non-string key');
    }
    map[entry.key as String] = entry.value;
  }
  final actual = map.keys.toSet();
  if (actual.difference(keys).isNotEmpty ||
      keys.difference(actual).isNotEmpty) {
    throw FormatException('$label has unknown or missing fields');
  }
  return map;
}

String _string(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String) throw FormatException('$key is not a string');
  return value;
}

void _requirePublicText(String label, String value) {
  if (value.trim().isEmpty || value.contains(RegExp(r'[\u0000-\u001f]'))) {
    throw ArgumentError('$label is empty or contains control characters');
  }
}
