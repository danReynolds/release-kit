import 'dart:convert';
import 'dart:io';

import '../transforms/digest.dart';
import 'canonical_json.dart';
import 'stage.dart';

/// One digest-bearing input to a completed release step.
class StageInput {
  StageInput({required this.name, required this.sha256}) {
    _requireLabel('input name', name);
    _requireSha256('input $name', sha256);
  }

  factory StageInput.fromJson(Object? value) {
    final map = _strictMap(value, const {'name', 'sha256'}, 'stage input');
    return StageInput(
      name: _string(map, 'name'),
      sha256: _string(map, 'sha256'),
    );
  }

  final String name;
  final String sha256;

  /// Binds a consumer directly to exact bytes emitted by an earlier step.
  factory StageInput.artifact(StageArtifact artifact) => StageInput(
        name: artifact.path,
        sha256: artifact.sha256,
      );

  /// Binds a consumer to the complete, ordered output set of an earlier
  /// step. This is useful for source snapshots and other multi-file inputs.
  factory StageInput.step(StageStep step) => StageInput(
        name: 'step:${step.name}',
        sha256: step.outputSha256,
      );

  factory StageInput.plan(StageIdentity identity) => StageInput(
        name: 'stage:plan',
        sha256: identity.planSha256,
      );

  factory StageInput.commit(StageIdentity identity) => StageInput(
        name: 'stage:commit',
        sha256: Sha256.hex(utf8.encode(identity.headCommit!)),
      );

  factory StageInput.tree(StageIdentity identity) => StageInput(
        name: 'stage:tree',
        sha256: Sha256.hex(utf8.encode(identity.headTree!)),
      );

  Map<String, Object?> toJson() => {'name': name, 'sha256': sha256};
}

/// Exact bytes emitted by a completed release step.
class StageArtifact {
  StageArtifact({
    required String path,
    required this.type,
    required this.mode,
    required this.size,
    required this.sha256,
  }) : path = StagePath.require(path) {
    if (path == 'stage.json') {
      throw ArgumentError('stage.json cannot be a staged artifact');
    }
    if (!RegExp(r'^[a-z][a-z0-9._-]*$').hasMatch(type)) {
      throw ArgumentError('artifact type is not a lowercase token: $type');
    }
    if (!RegExp(r'^0[0-7]{3}$').hasMatch(mode)) {
      throw ArgumentError('artifact mode must look like 0644 or 0755');
    }
    if (size < 0) {
      throw ArgumentError('artifact size cannot be negative');
    }
    _requireSha256('artifact $path', sha256);
  }

  factory StageArtifact.capture({
    required StageDirectory stage,
    required String path,
    required String type,
  }) {
    StagePath.require(path);
    final file = _regularArtifact(stage, path);
    final stat = file.statSync();
    final bytes = file.readAsBytesSync();
    final captured = StageArtifact(
      path: path,
      type: type,
      mode: _mode(stat.mode),
      size: bytes.length,
      sha256: Sha256.hex(bytes),
    );
    stage.noteDigested(path, stat, captured.sha256);
    return captured;
  }

  /// [recorded] again, read afresh unless the file has not moved since this
  /// process digested it.
  ///
  /// A release confirms the same artifacts repeatedly — every receipt write
  /// re-checks everything already recorded, and a stage of forty megabytes
  /// makes that the largest cost in staging. Confirming is not the same as
  /// trusting: a file whose size, mode, or timestamps differ by so much as a
  /// microsecond is read and digested again, and one this process never
  /// digested is always read.
  static StageArtifact confirm(
    StageArtifact recorded, {
    required StageDirectory stage,
  }) =>
      stage.digestStillStands(recorded.path, recorded.sha256)
          ? recorded
          : StageArtifact.capture(
              stage: stage,
              path: recorded.path,
              type: recorded.type,
            );

  factory StageArtifact.fromJson(Object? value) {
    final map = _strictMap(
      value,
      const {'mode', 'path', 'sha256', 'size', 'type'},
      'stage artifact',
    );
    final size = map['size'];
    if (size is! int) {
      throw const FormatException('artifact size is not an integer');
    }
    return StageArtifact(
      path: _string(map, 'path'),
      type: _string(map, 'type'),
      mode: _string(map, 'mode'),
      size: size,
      sha256: _string(map, 'sha256'),
    );
  }

  final String path;

  /// Semantic type: for example `executable`, `archive`, or `cask`.
  final String type;

  /// POSIX permission and special bits, rendered as four octal digits.
  final String mode;
  final int size;
  final String sha256;

  Map<String, Object?> toJson() => {
        'mode': mode,
        'path': path,
        'sha256': sha256,
        'size': size,
        'type': type,
      };
}

/// Inputs, outputs, and bounded evidence for one completed operation.
class StageStep {
  StageStep({
    required this.name,
    Iterable<StageInput> inputs = const [],
    Iterable<StageArtifact> outputs = const [],
    Map<String, Object?> evidence = const {},
  })  : inputs = List<StageInput>.unmodifiable(inputs),
        outputs = List<StageArtifact>.unmodifiable(outputs),
        evidence = _evidence(evidence) {
    _requireLabel('step name', name);
    _requireUnique(this.inputs.map((input) => input.name), 'input name');
    _requireUnique(this.outputs.map((output) => output.path), 'output path');
  }

  factory StageStep.fromJson(Object? value) {
    final map = _strictMap(
      value,
      const {'evidence', 'inputs', 'name', 'outputs'},
      'stage step',
    );
    final inputs = _list(map, 'inputs');
    final outputs = _list(map, 'outputs');
    final evidence = map['evidence'];
    if (evidence is! Map) {
      throw const FormatException('step evidence is not an object');
    }
    return StageStep(
      name: _string(map, 'name'),
      inputs: inputs.map(StageInput.fromJson),
      outputs: outputs.map(StageArtifact.fromJson),
      evidence: evidence.cast<String, Object?>(),
    );
  }

  final String name;
  final List<StageInput> inputs;
  final List<StageArtifact> outputs;

  /// Extensible structured evidence. Signing and notarization producers can
  /// record identities, certificate fingerprints, ticket bindings, results,
  /// and log digests here without changing the receipt schema.
  final Map<String, Object?> evidence;

  /// One digest for this step's complete ordered output relation.
  ///
  /// Paths and metadata are included as well as byte hashes, so substituting
  /// the same bytes under another name or mode changes the dependency.
  String get outputSha256 => Sha256.hex(utf8.encode(CanonicalJson.encode([
        for (final output in outputs) output.toJson(),
      ])));

  Map<String, Object?> toJson() => {
        'evidence': evidence,
        'inputs': inputs.map((input) => input.toJson()).toList(),
        'name': name,
        'outputs': outputs.map((output) => output.toJson()).toList(),
      };
}

/// The only authority for reusing files in a stage directory.
class StageReceipt {
  StageReceipt({
    required this.identity,
    Iterable<StageStep> steps = const [],
  }) : steps = List<StageStep>.unmodifiable(steps) {
    _requireUnique(this.steps.map((step) => step.name), 'step name');
    _requireUnique(artifacts.map((artifact) => artifact.path), 'artifact path');
  }

  factory StageReceipt.parse(String document) {
    final decoded = CanonicalJson.decodeDocument(document);
    // Version before shape: an older receipt differs in both, and the
    // schema message is the one a reader can act on.
    if (decoded is Map && decoded['schema'] != stageSchemaVersion) {
      throw FormatException('unsupported stage schema: ${decoded['schema']}');
    }
    final map = _strictMap(
      decoded,
      const {'schema', 'stage', 'steps'},
      'stage receipt',
    );
    return StageReceipt(
      identity: StageIdentity.fromJson(map['stage']),
      steps: _list(map, 'steps').map(StageStep.fromJson),
    );
  }

  final StageIdentity identity;
  final List<StageStep> steps;

  /// Whether the terminal barrier ran: completion is the recorded fact of
  /// the `complete-stage` step, not a second flag that could disagree with
  /// it. Incomplete receipts preserve diagnostic progress but are never
  /// reusable.
  bool get complete => steps.isNotEmpty && steps.last.name == 'complete-stage';

  Iterable<StageArtifact> get artifacts sync* {
    for (final step in steps) {
      yield* step.outputs;
    }
  }

  Map<String, Object?> toJson() => {
        'schema': stageSchemaVersion,
        'stage': identity.toJson(),
        'steps': steps.map((step) => step.toJson()).toList(),
      };

  String encode() => '${CanonicalJson.encode(toJson())}\n';
}

/// Atomic persistence for `stage.json`.
class StageReceiptStore {
  StageReceiptStore(this.stage);

  final StageDirectory stage;

  /// Writes only after every referenced output matches the record. The
  /// receipt rename is the final operation, so a crash cannot make partial
  /// artifact bytes appear complete.
  void write(StageReceipt receipt) {
    if (receipt.identity.id != stage.identity.id) {
      throw StateError('receipt belongs to a different stage');
    }
    for (final expected in receipt.artifacts) {
      final actual = StageArtifact.confirm(expected, stage: stage);
      if (!_sameArtifact(expected, actual)) {
        throw StateError(
          'artifact changed before receipt write: ${expected.path}',
        );
      }
    }
    stage.writeReceiptBytes(utf8.encode(receipt.encode()));
  }

  /// Reads without creating the stage or changing any bytes.
  StageReceipt? read() {
    final path = stage.resolve('stage.json');
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw const FormatException('stage.json is not a regular file');
    }
    return StageReceipt.parse(File(path).readAsStringSync());
  }
}

bool _sameArtifact(StageArtifact left, StageArtifact right) =>
    left.path == right.path &&
    left.type == right.type &&
    left.mode == right.mode &&
    left.size == right.size &&
    left.sha256 == right.sha256;

File _regularArtifact(StageDirectory stage, String path) {
  final unsafe = stage.unsafeFixedPath();
  if (unsafe != null) {
    throw FileSystemException('unsafe stage path', unsafe);
  }
  var partial = '';
  final parts = StagePath.segments(path);
  for (var i = 0; i < parts.length; i++) {
    partial = partial.isEmpty ? parts[i] : '$partial/${parts[i]}';
    final resolved = stage.resolve(partial);
    final type = FileSystemEntity.typeSync(resolved, followLinks: false);
    final expected = i == parts.length - 1
        ? FileSystemEntityType.file
        : FileSystemEntityType.directory;
    if (type != expected) {
      throw FileSystemException(
        type == FileSystemEntityType.link
            ? 'artifact path contains a symlink'
            : 'artifact is missing or is not a regular file',
        resolved,
      );
    }
  }
  return File(stage.resolve(path));
}

String _mode(int mode) => (mode & 0xfff).toRadixString(8).padLeft(4, '0');

Map<String, Object?> _evidence(Map<String, Object?> evidence) {
  final normalized = CanonicalJson.normalize(evidence);
  if (normalized is! Map<String, Object?>) {
    throw const FormatException('step evidence is not an object');
  }
  return normalized;
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

List<Object?> _list(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! List) throw FormatException('$key is not an array');
  return value.cast<Object?>();
}

void _requireSha256(String label, String value) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw ArgumentError('$label must carry a lowercase SHA-256 digest');
  }
}

void _requireLabel(String label, String value) {
  if (value.trim().isEmpty || value.contains(RegExp(r'[\u0000-\u001f]'))) {
    throw ArgumentError('$label is empty or contains control characters');
  }
}

void _requireUnique(Iterable<String> values, String label) {
  final seen = <String>{};
  for (final value in values) {
    if (!seen.add(value)) throw ArgumentError('duplicate $label: $value');
  }
}
