import 'dart:convert';

import 'canonical_json.dart';
import 'stage.dart';
import 'stage_receipt.dart';

/// Bumped freely until the first published release; after it, a bump
/// orphans every manifest already public — the historical read paths
/// (cask authentication, same-version re-inspection) parse only the
/// current schema — so a post-release bump must teach the parser each
/// retired schema it still needs to read.
const releaseManifestSchemaVersion = 6;

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

/// One private staged Homebrew cask and the tap path that will receive it.
///
/// This exact shape is frozen into the terminal receipt. The public manifest
/// receives the same public identity, but never the private [stagedPath].
final class StagedCaskBinding {
  StagedCaskBinding({
    required this.project,
    required this.tap,
    required this.path,
    required String stagedPath,
  }) : stagedPath = StagePath.require(stagedPath) {
    _requirePublicText('cask project', project);
    _requirePublicText('cask tap', tap);
    _requireDestinationPath(path);
  }

  factory StagedCaskBinding.fromEvidence(Object? value) {
    final map = _strictMap(
      value,
      const {
        'path',
        'project',
        'staged_path',
        'tap',
      },
      'staged cask binding',
    );
    return StagedCaskBinding(
      project: _string(map, 'project'),
      tap: _string(map, 'tap'),
      path: _string(map, 'path'),
      stagedPath: _string(map, 'staged_path'),
    );
  }

  final String project;
  final String tap;
  final String path;
  final String stagedPath;

  String get identity => _caskIdentity(project, tap, path);

  Map<String, Object?> toEvidence() => {
        'path': path,
        'project': project,
        'staged_path': stagedPath,
        'tap': tap,
      };

  ReleaseManifestCask bind(StageArtifact artifact) {
    if (artifact.path != stagedPath) {
      throw ArgumentError('cask binding captured a different output');
    }
    return ReleaseManifestCask.fromStage(
      project: project,
      tap: tap,
      path: path,
      artifact: artifact,
    );
  }
}

/// One Homebrew cask and the exact public tap path that receives it.
///
/// Unlike [ReleaseManifestArtifact], this file is not necessarily a release
/// asset: it belongs only in its tap. The manifest carries enough public
/// evidence to authenticate those bytes later, while the private stage path
/// remains solely in `stage.json`.
class ReleaseManifestCask {
  ReleaseManifestCask({
    required this.project,
    required this.tap,
    required this.path,
    required this.size,
    required this.sha256,
  }) {
    _requirePublicText('cask project', project);
    _requirePublicText('cask tap', tap);
    _requireDestinationPath(path);
    if (size < 0) {
      throw ArgumentError('cask size cannot be negative');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw ArgumentError('cask must carry a lowercase SHA-256 digest');
    }
  }

  factory ReleaseManifestCask.fromStage({
    required String project,
    required String tap,
    required String path,
    required StageArtifact artifact,
  }) =>
      ReleaseManifestCask(
        project: project,
        tap: tap,
        path: path,
        size: artifact.size,
        sha256: artifact.sha256,
      );

  factory ReleaseManifestCask.fromJson(Object? value) {
    final map = _strictMap(
      value,
      const {
        'path',
        'project',
        'sha256',
        'size',
        'tap',
      },
      'cask binding',
    );
    final size = map['size'];
    if (size is! int) {
      throw const FormatException('cask size is not an integer');
    }
    return ReleaseManifestCask(
      project: _string(map, 'project'),
      tap: _string(map, 'tap'),
      path: _string(map, 'path'),
      size: size,
      sha256: _string(map, 'sha256'),
    );
  }

  final String project;

  /// Tap repository, such as `owner/homebrew-tap`.
  final String tap;

  /// Public path inside that coordinate, such as `Casks/tool.rb`.
  final String path;
  final int size;
  final String sha256;

  String get identity => _caskIdentity(project, tap, path);
  bool names({
    required String project,
    required String tap,
    required String path,
  }) =>
      this.project == project && this.tap == tap && this.path == path;

  Map<String, Object?> toJson() => {
        'path': path,
        'project': project,
        'sha256': sha256,
        'size': size,
        'tap': tap,
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
    this.cask,
  }) : artifacts = List<ReleaseManifestArtifact>.unmodifiable(
          artifacts.toList()
            ..sort((left, right) => left.name.compareTo(right.name)),
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
  }

  factory ReleaseManifest.parse(String document) {
    final decoded = CanonicalJson.decodeDocument(document);
    final map = _strictMap(
      decoded,
      const {
        'artifacts',
        'cask',
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
    return ReleaseManifest(
      unit: _string(map, 'unit'),
      version: _string(map, 'version'),
      tag: map['tag'] == null ? null : _string(map, 'tag'),
      commit: source['commit'] == null ? null : _string(source, 'commit'),
      artifacts: artifacts.map(ReleaseManifestArtifact.fromJson),
      cask: map['cask'] == null
          ? null
          : ReleaseManifestCask.fromJson(map['cask']),
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
  final ReleaseManifestCask? cask;

  Map<String, Object?> toJson() => {
        'artifacts': artifacts.map((artifact) => artifact.toJson()).toList(),
        'cask': cask?.toJson(),
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

String _caskIdentity(
  String project,
  String tap,
  String path,
) =>
    '$project\u0000$tap\u0000$path';

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
