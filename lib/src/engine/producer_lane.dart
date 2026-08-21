import 'dart:convert';
import 'dart:io';

import '../transforms/digest.dart';
import 'file_mode.dart';
import 'stage.dart';
import 'stage_receipt.dart';

/// A private source tree for one platform producer chain.
///
/// Producer outputs still meet in the content-addressed stage workspace, at
/// paths owned by their platform. Their working files do not: Dart and other
/// tools may create `.dart_tool` or similar scratch beneath the source tree,
/// and one lane must never clean or reuse another lane's transient state.
///
/// Lane trees are siblings of the receipt-governed stage rather than children
/// of it, so an in-progress receipt never has to tolerate unrecorded files.
/// They are removed after a lane drains. If rk or the machine stops first,
/// the ordinary stage-store cleanup inventories the sibling and the next run
/// replaces the exact lane directory before using it.
final class ProducerLaneSource {
  ProducerLaneSource({
    required this.stage,
    required String lane,
  }) : _laneId = Sha256.hex(utf8.encode(lane));

  final StageDirectory stage;
  final String _laneId;

  String get _parentPath => '${stage.path}.lanes';

  /// The repository root a producer in this lane must use.
  String get path => _join(_parentPath, _laneId);

  /// Replaces any interrupted copy of this lane with the exact staged source.
  void materialize(Iterable<StageArtifact> sourceArtifacts) {
    _reset();
    final copied = <String, StageArtifact>{};
    for (final artifact in sourceArtifacts) {
      if (!artifact.path.startsWith('source/')) {
        throw ArgumentError(
          'producer lane input is not staged source: ${artifact.path}',
        );
      }
      final relative = artifact.path.substring('source/'.length);
      final segments = StagePath.segments(relative);
      final confirmed = StageArtifact.confirm(artifact, stage: stage);
      if (!_sameArtifact(confirmed, artifact)) {
        throw StateError(
          'staged source changed before producer lane materialization: '
          '${artifact.path}',
        );
      }

      final destination = _joinAll(path, segments);
      _ensureParents(segments.take(segments.length - 1));
      File(stage.resolve(artifact.path)).copySync(destination);
      copied[destination] = artifact;
    }

    setFileModes({
      for (final entry in copied.entries) entry.key: entry.value.mode,
    });
    for (final entry in copied.entries) {
      final file = File(entry.key);
      final bytes = file.readAsBytesSync();
      final artifact = entry.value;
      if (posixMode(file.statSync().mode) != artifact.mode ||
          bytes.length != artifact.size ||
          Sha256.hex(bytes) != artifact.sha256) {
        throw StateError(
          'producer lane source does not match the staged snapshot: '
          '${artifact.path}',
        );
      }
    }
  }

  /// Removes only this lane's private source copy.
  void close() {
    final parent = _fixedParent(create: false);
    if (parent == null) return;
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'producer lane path is a symlink or non-directory',
        path,
      );
    }
    Directory(path).deleteSync(recursive: true);
    if (Directory(parent).listSync(followLinks: false).isEmpty) {
      Directory(parent).deleteSync();
    }
  }

  void _reset() {
    _fixedParent(create: true);
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      if (type != FileSystemEntityType.directory) {
        throw FileSystemException(
          'producer lane path is a symlink or non-directory',
          path,
        );
      }
      Directory(path).deleteSync(recursive: true);
    }
    Directory(path).createSync();
  }

  String? _fixedParent({required bool create}) {
    var current = stage.repositoryRoot;
    if (FileSystemEntity.typeSync(current, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
        'repository root is a symlink or non-directory',
        current,
      );
    }
    for (final component in [
      '.rk',
      'work',
      'stages',
      '${stage.identity.id}.lanes',
    ]) {
      current = _join(current, component);
      var type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        if (!create) return null;
        Directory(current).createSync();
        type = FileSystemEntity.typeSync(current, followLinks: false);
      }
      if (type != FileSystemEntityType.directory) {
        throw FileSystemException(
          'producer lane path contains a symlink or non-directory',
          current,
        );
      }
    }
    return current;
  }

  void _ensureParents(Iterable<String> components) {
    var current = path;
    for (final component in components) {
      current = _join(current, component);
      var type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        Directory(current).createSync();
        type = FileSystemEntity.typeSync(current, followLinks: false);
      }
      if (type != FileSystemEntityType.directory) {
        throw FileSystemException(
          'producer lane source contains a symlink or non-directory',
          current,
        );
      }
    }
  }
}

bool _sameArtifact(StageArtifact left, StageArtifact right) =>
    left.path == right.path &&
    left.type == right.type &&
    left.mode == right.mode &&
    left.size == right.size &&
    left.sha256 == right.sha256;

String _join(String first, String second) =>
    [first, second].join(Platform.pathSeparator);

String _joinAll(String first, Iterable<String> rest) =>
    [first, ...rest].join(Platform.pathSeparator);
