import 'dart:convert';
import 'dart:io';

import 'atomic_file.dart';
import '../transforms/digest.dart';
import 'canonical_json.dart';
import 'workspace.dart';

/// Increment this only when the identity or receipt contract changes.
const stageSchemaVersion = 5;

/// The content address of one resolved release plan at one exact Git tree.
class StageIdentity {
  StageIdentity._({
    required this.id,
    required this.headCommit,
    required this.headTree,
    required this.planSha256,
    required this.runId,
  });

  /// Canonicalizes [resolvedPlan] before hashing it. The caller must include
  /// every release-affecting choice in that value, including targets,
  /// platforms, signing policy, and toolchain identity.
  factory StageIdentity.forPlan({
    required String headCommit,
    required String headTree,
    required Object? resolvedPlan,
  }) {
    final plan = CanonicalJson.encode(resolvedPlan);
    return StageIdentity.fromDigests(
      headCommit: headCommit,
      headTree: headTree,
      planSha256: Sha256.hex(utf8.encode(plan)),
    );
  }

  /// A one-invocation stage with no source revision claim.
  factory StageIdentity.forUnboundPlan({
    required String runId,
    required Object? resolvedPlan,
  }) {
    final plan = CanonicalJson.encode(resolvedPlan);
    return StageIdentity.fromUnboundDigests(
      runId: runId,
      planSha256: Sha256.hex(utf8.encode(plan)),
    );
  }

  factory StageIdentity.fromUnboundDigests({
    required String runId,
    required String planSha256,
  }) {
    if (runId.trim().isEmpty || runId.contains(RegExp(r'[\u0000-\u001f]'))) {
      throw ArgumentError('unbound stage run id is empty or invalid');
    }
    _requireSha256('resolved plan digest', planSha256);
    final coordinates = <String, Object?>{
      'plan_sha256': planSha256,
      'run_id': runId,
      'schema': stageSchemaVersion,
      'source': 'unbound',
    };
    return StageIdentity._(
      id: Sha256.hex(utf8.encode(CanonicalJson.encode(coordinates))),
      headCommit: null,
      headTree: null,
      planSha256: planSha256,
      runId: runId,
    );
  }

  factory StageIdentity.fromDigests({
    required String headCommit,
    required String headTree,
    required String planSha256,
  }) {
    _requireObjectId('HEAD commit', headCommit);
    _requireObjectId('HEAD tree', headTree);
    if (headCommit.length != headTree.length) {
      throw ArgumentError('HEAD commit and tree use different object formats');
    }
    _requireSha256('resolved plan digest', planSha256);
    final coordinates = <String, Object?>{
      'head_commit': headCommit,
      'head_tree': headTree,
      'plan_sha256': planSha256,
      'schema': stageSchemaVersion,
    };
    return StageIdentity._(
      id: Sha256.hex(utf8.encode(CanonicalJson.encode(coordinates))),
      headCommit: headCommit,
      headTree: headTree,
      planSha256: planSha256,
      runId: null,
    );
  }

  factory StageIdentity.fromJson(Object? value) {
    final map = _strictMap(
        value,
        const {
          'id',
          'head_commit',
          'head_tree',
          'plan_sha256',
          'run_id',
        },
        'stage identity');
    final commit = map['head_commit'];
    final tree = map['head_tree'];
    final runId = map['run_id'];
    final identity = commit == null && tree == null && runId is String
        ? StageIdentity.fromUnboundDigests(
            runId: runId,
            planSha256: _string(map, 'plan_sha256'),
          )
        : StageIdentity.fromDigests(
            headCommit: _string(map, 'head_commit'),
            headTree: _string(map, 'head_tree'),
            planSha256: _string(map, 'plan_sha256'),
          );
    if (_string(map, 'id') != identity.id) {
      throw const FormatException('stage identity does not match its inputs');
    }
    return identity;
  }

  final String id;
  final String? headCommit;
  final String? headTree;
  final String planSha256;
  final String? runId;

  bool get isGitBound => headCommit != null;

  Map<String, Object?> toJson() => {
        'head_commit': headCommit,
        'head_tree': headTree,
        'id': id,
        'plan_sha256': planSha256,
        'run_id': runId,
      };
}

/// The fixed on-disk location and safe atomic write operations for a stage.
class StageDirectory {
  StageDirectory({required String repositoryRoot, required this.identity})
      : repositoryRoot = Directory(repositoryRoot).absolute.path;

  final String repositoryRoot;
  final StageIdentity identity;

  String get path => _join(
        repositoryRoot,
        ['.rk', 'work', 'stages', identity.id],
      );

  Workspace get workspace => Workspace(path);

  String resolve(String relativePath) =>
      _join(path, StagePath.segments(relativePath));

  /// Creates only the fixed stage path, refusing any symlink or non-directory
  /// component below the repository root.
  void ensureExists() {
    final rootType =
        FileSystemEntity.typeSync(repositoryRoot, followLinks: false);
    if (rootType != FileSystemEntityType.directory) {
      throw FileSystemException(
          'repository root is not a directory', repositoryRoot);
    }
    var current = repositoryRoot;
    for (final component in ['.rk', 'work', 'stages', identity.id]) {
      current = _join(current, [component]);
      var type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        Directory(current).createSync();
        type = FileSystemEntity.typeSync(current, followLinks: false);
      }
      if (type != FileSystemEntityType.directory) {
        throw FileSystemException(
          'stage path contains a symlink or non-directory',
          current,
        );
      }
    }
  }

  /// Returns the first unsafe fixed path component, without creating or
  /// changing anything. A missing component is not unsafe; it means no stage.
  String? unsafeFixedPath() {
    var current = repositoryRoot;
    for (final component in ['.rk', 'work', 'stages', identity.id]) {
      current = _join(current, [component]);
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) return null;
      if (type != FileSystemEntityType.directory) return current;
    }
    return null;
  }

  /// Atomically places bytes in the stage before a receipt can name them.
  void writeBytesAtomically(String relativePath, List<int> bytes) {
    final parts = StagePath.segments(relativePath);
    if (relativePath == 'stage.json') {
      throw ArgumentError('stage.json is written only by StageReceiptStore');
    }
    ensureExists();
    _ensureArtifactParents(parts.take(parts.length - 1));
    final destination = resolve(relativePath);
    final existing = FileSystemEntity.typeSync(destination, followLinks: false);
    if (existing != FileSystemEntityType.notFound &&
        existing != FileSystemEntityType.file) {
      throw FileSystemException(
        'artifact destination is a symlink or non-file',
        destination,
      );
    }
    AtomicFile.write(destination, bytes);
  }

  /// Used by the receipt store after it has enforced the reserved filename.
  void writeReceiptBytes(List<int> bytes) {
    ensureExists();
    final destination = resolve('stage.json');
    final existing = FileSystemEntity.typeSync(destination, followLinks: false);
    if (existing != FileSystemEntityType.notFound &&
        existing != FileSystemEntityType.file) {
      throw FileSystemException(
        'stage receipt destination is a symlink or non-file',
        destination,
      );
    }
    AtomicFile.write(destination, bytes);
  }

  void _ensureArtifactParents(Iterable<String> components) {
    var current = path;
    for (final component in components) {
      current = _join(current, [component]);
      var type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        Directory(current).createSync();
        type = FileSystemEntity.typeSync(current, followLinks: false);
      }
      if (type != FileSystemEntityType.directory) {
        throw FileSystemException(
          'artifact path contains a symlink or non-directory',
          current,
        );
      }
    }
  }
}

/// Repository-independent validation for paths recorded in a receipt.
class StagePath {
  const StagePath._();

  static List<String> segments(String path) {
    final parts = path.split('/');
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.startsWith('\\') ||
        path.contains('\\') ||
        path.contains('\u0000') ||
        RegExp(r'^[A-Za-z]:').hasMatch(path) ||
        parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw FormatException('path escapes the stage: $path');
    }
    return List<String>.unmodifiable(parts);
  }

  static String require(String path) {
    segments(path);
    return path;
  }
}

String _join(String root, Iterable<String> parts) =>
    [root, ...parts].join(Platform.pathSeparator);

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
  if (map.keys.toSet().difference(keys).isNotEmpty ||
      keys.difference(map.keys.toSet()).isNotEmpty) {
    throw FormatException('$label has unknown or missing fields');
  }
  return map;
}

String _string(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String) throw FormatException('$key is not a string');
  return value;
}

void _requireObjectId(String label, String value) {
  if (!RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$').hasMatch(value)) {
    throw ArgumentError('$label must be a full lowercase Git object ID');
  }
}

void _requireSha256(String label, String value) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw ArgumentError('$label must be a lowercase SHA-256 digest');
  }
}
