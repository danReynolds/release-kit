import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../transforms/digest.dart';
import 'canonical_json.dart';
import 'file_mode.dart';
import 'stage.dart';
import 'stage_dependencies.dart';
import 'stage_receipt.dart';
import 'stage_receipt_structure.dart';

/// Bounds apply to the flattened document and to reconstruction of all nested
/// proof commitments, so a wide graph cannot cause unbounded repeated encoding.
final class StageProofLimits {
  const StageProofLimits({
    this.bytes = 32 * 1024 * 1024,
    this.stages = 128,
    this.edges = 4096,
    this.depth = 128,
    this.expandedBytes = 128 * 1024 * 1024,
  });
  final int bytes;
  final int stages;
  final int edges;
  final int depth;
  final int expandedBytes;

  void _requireValid() {
    if ([bytes, stages, edges, depth, expandedBytes].any((n) => n < 1)) {
      throw ArgumentError('dependency proof bounds must be positive');
    }
  }
}

/// Portable provenance, not authorization of source or native selections.
/// Each node has a single plan authority in its receipt header. The caller must
/// still match every node to current source, native facts and producer contracts.
/// Only direct dependency payloads are retained by a consumer; ancestor payloads
/// are not required merely to authenticate the dependency receipts that used them.
final class StageProofClosure {
  StageProofClosure._(this.root, Map<String, StageReceipt> stages, this.limits)
    : stages = Map.unmodifiable(stages) {
    limits._requireValid();
    _validate();
  }

  factory StageProofClosure.fromReceipt(
    StageReceipt receipt,
    Iterable<StageProofClosure> ancestors, {
    StageProofLimits limits = const StageProofLimits(),
  }) {
    limits._requireValid();
    final nodes = <String, StageReceipt>{receipt.identity.id: receipt};
    for (final proof in ancestors) {
      for (final node in proof.stages.entries) {
        final previous = nodes[node.key];
        if (previous != null && previous.encode() != node.value.encode()) {
          throw const FormatException('conflicting dependency proof receipts');
        }
        nodes[node.key] = node.value;
        if (nodes.length > limits.stages) {
          throw const FormatException('dependency proof stage limit exceeded');
        }
      }
    }
    return StageProofClosure._(receipt.identity.id, nodes, limits);
  }

  factory StageProofClosure.parse(
    String text, {
    StageProofLimits limits = const StageProofLimits(),
  }) {
    limits._requireValid();
    if (utf8.encode(text).length > limits.bytes) {
      throw const FormatException('dependency proof byte limit exceeded');
    }
    final value = CanonicalJson.decodeDocument(text);
    if (value is! Map ||
        value.length != 3 ||
        value['format'] != 1 ||
        value['root'] is! String ||
        value['stages'] is! Map) {
      throw const FormatException('unsupported dependency proof format');
    }
    final encoded = value['stages'] as Map;
    if (encoded.length > limits.stages) {
      throw const FormatException('dependency proof stage limit exceeded');
    }
    final nodes = <String, StageReceipt>{};
    for (final entry in encoded.entries) {
      if (entry.key is! String) {
        throw const FormatException('invalid proof stage id');
      }
      nodes[entry.key as String] = StageReceipt.parse(
        '${CanonicalJson.encode(entry.value)}\n',
      );
    }
    return StageProofClosure._(value['root'] as String, nodes, limits);
  }

  /// No-follow, bounded read with exact metadata verification. Does not inspect
  /// deleted ancestor directories or execute any artifact from the proof.
  static StageProofClosure read(
    StageDirectory stage,
    StageArtifact artifact, {
    StageProofLimits limits = const StageProofLimits(),
  }) {
    limits._requireValid();
    if (artifact.type != 'dependency-proof' || artifact.size > limits.bytes) {
      throw const FormatException('invalid or oversized dependency proof');
    }
    if (stage.unsafeFixedPath() != null) {
      throw const FormatException('unsafe dependency proof stage path');
    }
    var path = stage.path;
    final segments = StagePath.segments(artifact.path);
    for (var i = 0; i < segments.length; i++) {
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw const FormatException('unsafe dependency proof directory');
      }
      path = '$path/${segments[i]}';
    }
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException('dependency proof is not a regular file');
    }
    final stat = File(path).statSync();
    if (stat.size != artifact.size || posixMode(stat.mode) != artifact.mode) {
      throw const FormatException('dependency proof metadata changed');
    }
    final file = File(path).openSync();
    final bytes = BytesBuilder(copy: false);
    try {
      while (bytes.length < artifact.size) {
        final chunk = file.readSync(
          min(64 * 1024, artifact.size - bytes.length),
        );
        if (chunk.isEmpty) {
          throw const FormatException('dependency proof changed while reading');
        }
        bytes.add(chunk);
      }
      if (file.lengthSync() != artifact.size) {
        throw const FormatException('dependency proof size changed');
      }
    } finally {
      file.closeSync();
    }
    final content = bytes.takeBytes();
    if (Sha256.hex(content) != artifact.sha256) {
      throw const FormatException('dependency proof bytes changed');
    }
    return StageProofClosure.parse(utf8.decode(content), limits: limits);
  }

  final String root;
  final Map<String, StageReceipt> stages;
  final StageProofLimits limits;
  final Map<String, List<ImportedStageDependency>> _imports = {};

  String encode() => _encode(root, stages.keys.toSet());

  void requireImport(ImportedStageDependency input) {
    if (root != input.providerIdentity.id) {
      throw const FormatException('dependency proof has the wrong root');
    }
    input.requireProviderReceipt(stages[root]!);
    final bytes = utf8.encode(encode());
    if (bytes.length != input.proof.size ||
        Sha256.hex(bytes) != input.proof.sha256) {
      throw const FormatException(
        'dependency proof differs from its frozen declaration',
      );
    }
  }

  void _validate() {
    if (stages.isEmpty ||
        stages.length > limits.stages ||
        !stages.containsKey(root)) {
      throw const FormatException('missing root or oversized dependency proof');
    }
    var edges = 0;
    for (final entry in stages.entries) {
      final receipt = entry.value;
      if (receipt.identity.id != entry.key ||
          receipt.plan == null ||
          !receipt.complete) {
        throw const FormatException(
          'dependency proof needs complete identity-matching plan receipts',
        );
      }
      final structure = StageReceiptStructure.validate(receipt);
      if (structure.isNotEmpty) {
        throw FormatException('invalid dependency receipt: ${structure.first}');
      }
      final dependencies = receipt.plan!['dependency_inputs'] == null
          ? StageDependencies()
          : StageDependencies.fromJson(receipt.plan!['dependency_inputs']);
      final inputs = dependencies.validateRecordedInputs(receipt);
      if (inputs.isNotEmpty) {
        throw FormatException('invalid dependency inputs: ${inputs.first}');
      }
      _imports[entry.key] = dependencies.imports;
      edges += dependencies.imports.length;
      if (edges > limits.edges) {
        throw const FormatException('dependency proof edge limit exceeded');
      }
    }
    final reachable = _reachable(root);
    if (reachable.length != stages.length) {
      throw const FormatException('dependency proof contains unrelated stages');
    }
    if (utf8.encode(encode()).length > limits.bytes) {
      throw const FormatException('dependency proof byte limit exceeded');
    }
    final commitments = <String, ({int size, String sha256})>{};
    var expandedBytes = 0;
    for (final imports in _imports.values) {
      for (final input in imports) {
        final id = input.providerIdentity.id;
        input.requireProviderReceipt(stages[id]!);
        final commitment = commitments.putIfAbsent(id, () {
          final bytes = utf8.encode(_encode(id, _reachable(id)));
          expandedBytes += bytes.length;
          if (expandedBytes > limits.expandedBytes) {
            throw const FormatException(
              'dependency proof expansion limit exceeded',
            );
          }
          return (size: bytes.length, sha256: Sha256.hex(bytes));
        });
        if (commitment.size != input.proof.size ||
            commitment.sha256 != input.proof.sha256) {
          throw const FormatException(
            'nested dependency proof differs from its frozen declaration',
          );
        }
      }
    }
  }

  Set<String> _reachable(String id) {
    final reached = <String>{};
    final visiting = <String>{};
    final heights = <String, int>{};
    int visit(String node) {
      if (visiting.contains(node)) {
        throw const FormatException('cyclic dependency proof');
      }
      if (!stages.containsKey(node)) {
        throw const FormatException('missing ancestor dependency proof');
      }
      if (heights[node] case final height?) return height;
      if (visiting.length >= limits.depth) {
        throw const FormatException('dependency proof depth limit exceeded');
      }
      visiting.add(node);
      reached.add(node);
      var height = 1;
      for (final input in _imports[node]!) {
        height = max(height, 1 + visit(input.providerIdentity.id));
      }
      if (height > limits.depth) {
        throw const FormatException('dependency proof depth limit exceeded');
      }
      visiting.remove(node);
      heights[node] = height;
      return height;
    }

    visit(id);
    return reached;
  }

  String _encode(String id, Set<String> nodes) =>
      '${CanonicalJson.encode({
        'format': 1,
        'root': id,
        'stages': {for (final node in nodes) node: stages[node]!.toJson()},
      })}\n';
}
