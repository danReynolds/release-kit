import 'dart:convert';
import 'dart:typed_data';

import '../transforms/digest.dart';
import 'canonical_json.dart';
import 'file_mode.dart';
import 'source_tree.dart';
import 'stage.dart';
import 'stage_receipt.dart';

/// Exact source inventory shared by production and portable authorization.
/// Select authoritative source before capture: Git-backed trees read committed
/// bytes/modes; other trees represent the caller's single-invocation snapshot.
/// Keeping owned bytes permits one capture to authenticate a whole proof closure.
final class StageSourceSnapshot implements SourceTree {
  StageSourceSnapshot._(
    this.description,
    this._files,
    this.artifacts,
    this.gitCommit,
  );

  static Future<StageSourceSnapshot> capture(
    SourceTree source, {
    String? commit,
  }) async {
    if (source is StageSourceSnapshot) {
      if (commit != null &&
          source.gitCommit != null &&
          commit != source.gitCommit) {
        throw StateError('source capture names a different Git commit');
      }
      return source;
    }
    final GitCommitSourceTree? git;
    if (source is GitSourceTree) {
      if (commit == null) {
        throw StateError('committed source capture requires a commit');
      }
      git = GitCommitSourceTree(source.root, commit);
    } else if (source is GitCommitSourceTree) {
      if (commit != null && commit != source.commit) {
        throw StateError('source capture names a different Git commit');
      }
      git = source;
    } else {
      git = null;
    }
    final entries = {
      for (final entry in git?.trackedEntries() ?? <GitTreeEntry>[])
        entry.path: entry,
    };
    final paths = [...(git?.trackedFiles() ?? source.trackedFiles())]..sort();
    for (final path in paths) {
      StagePath.require(path);
      final entry = entries[path];
      if (entry != null && !entry.isRegularFile) {
        throw StateError(
          'tracked source $path is a ${entry.unsupportedKind}; release '
          'staging accepts only regular Git files (100644 or 100755)',
        );
      }
    }
    // A non-Git snapshot must own its complete inventory and bytes before the
    // first asynchronous boundary, just as ordinary source production does.
    final batched = git == null ? null : await git.readBytesBatch(paths);
    final files = <String, Uint8List>{};
    final artifacts = <StageArtifact>[];
    for (final path in paths) {
      final bytes = git == null ? source.readBytes(path) : batched![path];
      if (bytes == null) {
        throw StateError('tracked source disappeared while staging: $path');
      }
      final owned = Uint8List.fromList(bytes).asUnmodifiableView();
      files[path] = owned;
      artifacts.add(
        StageArtifact(
          path: 'source/$path',
          type: 'source',
          mode: entries[path]?.executable == true ? '0755' : '0644',
          size: owned.length,
          sha256: Sha256.hex(owned),
        ),
      );
    }
    return StageSourceSnapshot._(
      source.description,
      Map.unmodifiable(files),
      List.unmodifiable(artifacts),
      git?.commit,
    );
  }

  @override
  final String description;
  final String? gitCommit;
  final Map<String, Uint8List> _files;
  final List<StageArtifact> artifacts;

  @override
  List<String> trackedFiles() => List.unmodifiable(_files.keys);
  @override
  List<int>? readBytes(String path) => _files[_path(path)];
  @override
  String? read(String path) {
    final bytes = readBytes(path);
    return bytes == null ? null : utf8.decode(bytes);
  }

  @override
  bool exists(String path) {
    final normalized = _path(path);
    return normalized.isEmpty ||
        _files.containsKey(normalized) ||
        _files.keys.any((file) => file.startsWith('$normalized/'));
  }

  /// A pending header claims no source output. Every recorded source byte and
  /// mode, however, must match exactly; self-consistent forged hashes do not
  /// establish source authority.
  void requireReceipt(StageReceipt receipt) {
    if (gitCommit != null && gitCommit != receipt.identity.headCommit) {
      throw StateError('source snapshot belongs to a different Git commit');
    }
    if (receipt.steps.isEmpty) return;
    final source = receipt.steps.first;
    if (source.name != 'source-snapshot' ||
        CanonicalJson.encode(source.outputs.map((a) => a.toJson()).toList()) !=
            CanonicalJson.encode(artifacts.map((a) => a.toJson()).toList())) {
      throw StateError(
        'recorded source inventory differs from authoritative source',
      );
    }
  }

  List<StageArtifact> materialize(StageDirectory stage) {
    for (final entry in _files.entries) {
      stage.writeBytesAtomically('source/${entry.key}', entry.value);
    }
    setFileModes({
      for (final artifact in artifacts)
        stage.resolve(artifact.path): artifact.mode,
    });
    return [
      for (final artifact in artifacts)
        StageArtifact.capture(
          stage: stage,
          path: artifact.path,
          type: artifact.type,
        ),
    ];
  }
}

String _path(String path) {
  final value = path
      .split('/')
      .where((part) => part.isNotEmpty && part != '.')
      .join('/');
  if (value.isNotEmpty) StagePath.require(value);
  return value;
}
