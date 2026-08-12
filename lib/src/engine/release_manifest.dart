import 'dart:convert';

import 'canonical_json.dart';
import 'stage.dart';
import 'stage_receipt.dart';

/// Bumped freely until the first published release; after it, a bump
/// orphans every manifest already public — the historical read paths
/// (formula authentication, same-version re-inspection) parse only the
/// current schema — so a post-release bump must teach the parser each
/// retired schema it still needs to read.
const releaseManifestSchemaVersion = 5;

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

/// One destination-owned file and the exact public coordinate that receives
/// it.
///
/// Unlike [ReleaseManifestArtifact], this file is not necessarily a release
/// asset. In particular, a Homebrew formula belongs only in its tap. The
/// manifest carries enough public evidence to authenticate those destination
/// bytes later, while the private stage path remains solely in `stage.json`.
class ReleaseManifestDestinationBinding {
  ReleaseManifestDestinationBinding({
    required this.target,
    required this.project,
    required this.coordinate,
    required this.path,
    required this.type,
    required this.mediaType,
    required this.size,
    required this.sha256,
  }) {
    if (!RegExp(r'^[a-z][a-z0-9.-]*$').hasMatch(target)) {
      throw ArgumentError('destination target is not a lowercase token: '
          '$target');
    }
    _requirePublicText('destination project', project);
    _requirePublicText('destination coordinate', coordinate);
    _requireDestinationPath(path);
    if (!RegExp(r'^[a-z][a-z0-9._-]*$').hasMatch(type)) {
      throw ArgumentError('destination type is not a lowercase token: $type');
    }
    if (!RegExp(
      r'^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$',
    ).hasMatch(mediaType)) {
      throw ArgumentError('destination media type is invalid: $mediaType');
    }
    if (size < 0) {
      throw ArgumentError('destination size cannot be negative');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw ArgumentError(
        'destination must carry a lowercase SHA-256 digest',
      );
    }
  }

  factory ReleaseManifestDestinationBinding.fromStage({
    required String target,
    required String project,
    required String coordinate,
    required String path,
    required String mediaType,
    required StageArtifact artifact,
  }) =>
      ReleaseManifestDestinationBinding(
        target: target,
        project: project,
        coordinate: coordinate,
        path: path,
        type: artifact.type,
        mediaType: mediaType,
        size: artifact.size,
        sha256: artifact.sha256,
      );

  factory ReleaseManifestDestinationBinding.fromJson(Object? value) {
    final map = _strictMap(
      value,
      const {
        'coordinate',
        'media_type',
        'path',
        'project',
        'sha256',
        'size',
        'target',
        'type',
      },
      'destination binding',
    );
    final size = map['size'];
    if (size is! int) {
      throw const FormatException('destination size is not an integer');
    }
    return ReleaseManifestDestinationBinding(
      target: _string(map, 'target'),
      project: _string(map, 'project'),
      coordinate: _string(map, 'coordinate'),
      path: _string(map, 'path'),
      type: _string(map, 'type'),
      mediaType: _string(map, 'media_type'),
      size: size,
      sha256: _string(map, 'sha256'),
    );
  }

  final String target;
  final String project;

  /// Provider coordinate, such as `owner/homebrew-tap`.
  final String coordinate;

  /// Public path inside that coordinate, such as `Formula/tool.rb`.
  final String path;
  final String type;
  final String mediaType;
  final int size;
  final String sha256;

  Map<String, Object?> toJson() => {
        'coordinate': coordinate,
        'media_type': mediaType,
        'path': path,
        'project': project,
        'sha256': sha256,
        'size': size,
        'target': target,
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
    required this.commit,
    required Iterable<ReleaseManifestArtifact> artifacts,
    Iterable<ReleaseManifestDestinationBinding> destinations = const [],
  })  : artifacts = List<ReleaseManifestArtifact>.unmodifiable(
          artifacts.toList()
            ..sort((left, right) => left.name.compareTo(right.name)),
        ),
        destinations = List<ReleaseManifestDestinationBinding>.unmodifiable(
          destinations.toList()..sort(_compareDestinationBindings),
        ) {
    _requirePublicText('unit', unit);
    _requirePublicText('version', version);
    if (tag != null) _requirePublicText('tag', tag!);
    if (commit != null && !RegExp(r'^[0-9a-f]{40}$').hasMatch(commit!)) {
      throw ArgumentError('source commit must be a full lowercase SHA');
    }
    final names = <String>{};
    for (final artifact in this.artifacts) {
      if (!names.add(artifact.name)) {
        throw ArgumentError('duplicate public artifact: ${artifact.name}');
      }
    }
    final destinationPaths = <String>{};
    for (final binding in this.destinations) {
      final key = '${binding.target}\u0000${binding.coordinate}\u0000'
          '${binding.path}';
      if (!destinationPaths.add(key)) {
        throw ArgumentError(
          'duplicate destination path: ${binding.target} '
          '${binding.coordinate}/${binding.path}',
        );
      }
    }
  }

  factory ReleaseManifest.parse(String document) {
    final decoded = CanonicalJson.decodeDocument(document);
    final map = _strictMap(
      decoded,
      const {
        'artifacts',
        'destinations',
        'schema',
        'source',
        'tag',
        'unit',
        'version',
      },
      'release manifest',
    );
    if (map['schema'] != releaseManifestSchemaVersion) {
      throw FormatException(
          'unsupported release manifest schema: ${map['schema']}');
    }
    final source = _strictMap(
      map['source'],
      const {'commit'},
      'release source',
    );
    final artifacts = map['artifacts'];
    if (artifacts is! List) {
      throw const FormatException('manifest artifacts is not an array');
    }
    final destinations = map['destinations'];
    if (destinations is! List) {
      throw const FormatException('manifest destinations is not an array');
    }
    return ReleaseManifest(
      unit: _string(map, 'unit'),
      version: _string(map, 'version'),
      tag: map['tag'] == null ? null : _string(map, 'tag'),
      commit: source['commit'] == null ? null : _string(source, 'commit'),
      artifacts: artifacts.map(ReleaseManifestArtifact.fromJson),
      destinations:
          destinations.map(ReleaseManifestDestinationBinding.fromJson),
    );
  }

  final String unit;
  final String version;
  final String? tag;

  /// The released source commit when Git supplies an externally checkable
  /// anchor. An unbound source deliberately records null: its exact staged
  /// bytes remain locally receipted, but rk does not invent a revision.
  final String? commit;

  final List<ReleaseManifestArtifact> artifacts;
  final List<ReleaseManifestDestinationBinding> destinations;

  Map<String, Object?> toJson() => {
        'artifacts': artifacts.map((artifact) => artifact.toJson()).toList(),
        'destinations':
            destinations.map((binding) => binding.toJson()).toList(),
        'schema': releaseManifestSchemaVersion,
        'source': {'commit': commit},
        'tag': tag,
        'unit': unit,
        'version': version,
      };

  String encode() => '${CanonicalJson.encode(toJson())}\n';

  /// Places the public document atomically. The caller then captures it as a
  /// `manifest` output in the local receipt like any other staged artifact.
  void writeTo(StageDirectory stage, {String path = 'release-manifest.json'}) {
    if (stage.identity.headCommit != commit) {
      throw StateError('release manifest belongs to a different stage');
    }
    stage.writeBytesAtomically(path, utf8.encode(encode()));
  }
}

int _compareDestinationBindings(
  ReleaseManifestDestinationBinding left,
  ReleaseManifestDestinationBinding right,
) {
  for (final comparison in [
    left.target.compareTo(right.target),
    left.project.compareTo(right.project),
    left.coordinate.compareTo(right.coordinate),
    left.path.compareTo(right.path),
  ]) {
    if (comparison != 0) return comparison;
  }
  return 0;
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

void _requireDestinationPath(String path) {
  if (path.isEmpty ||
      path.startsWith('/') ||
      path.startsWith('\\') ||
      path.contains('\\') ||
      path.contains('\u0000') ||
      RegExp(r'^[A-Za-z]:').hasMatch(path)) {
    throw ArgumentError('destination path must be relative and safe: $path');
  }
  final segments = path.split('/');
  if (segments
      .any((segment) => segment.isEmpty || segment == '.' || segment == '..')) {
    throw ArgumentError('destination path must be relative and safe: $path');
  }
  for (final segment in segments) {
    _requirePublicText('destination path segment', segment);
  }
}
