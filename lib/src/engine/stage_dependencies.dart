import 'dart:convert';
import 'dart:io';

import '../transforms/digest.dart';
import 'canonical_json.dart';
import 'file_mode.dart';
import 'native_dependencies.dart';
import 'release_stage.dart';
import 'stage.dart';
import 'stage_contract.dart';
import 'stage_inspection.dart';
import 'stage_receipt.dart';

/// A native-selected artifact occurrence. Native discovery, not this class,
/// establishes compatibility and archive identity. Core keeps its context and
/// install slot intact and connects the producers that consume its bytes.
final class NativeArtifactUse {
  NativeArtifactUse({
    required this.context,
    required this.slot,
    required this.provider,
    required Iterable<String> consumers,
  }) : consumers = List.unmodifiable(consumers.toSet().toList()..sort()) {
    if (context.isEmpty || slot.isEmpty || this.consumers.isEmpty) {
      throw ArgumentError('an artifact use needs a native slot and consumers');
    }
  }

  final String context;
  final String slot;
  final NativeCandidate provider;
  final List<String> consumers;

  factory NativeArtifactUse.fromJson(Object? value) {
    final map = _map(value, {'context', 'slot', 'provider', 'consumers'});
    final provider = _map(map['provider'], {
      'package',
      'version',
      'unit',
      'project',
      'producer',
    });
    final package = _map(provider['package'], {'ecosystem', 'source', 'name'});
    return NativeArtifactUse(
      context: _string(map, 'context'),
      slot: _string(map, 'slot'),
      provider: NativeCandidate(
        package: NativePackage(
          ecosystem: _string(package, 'ecosystem'),
          source: _string(package, 'source'),
          name: _string(package, 'name'),
        ),
        version: _string(provider, 'version'),
        unit: _string(provider, 'unit'),
        project: _string(provider, 'project'),
        producer: _string(provider, 'producer'),
      ),
      consumers: _list(map, 'consumers').cast<String>(),
    );
  }

  Map<String, Object?> toJson() => {
    'context': context,
    'slot': slot,
    'provider': provider.toJson(),
    'consumers': consumers,
  };
}

/// An input produced inside this unit. Its future hash deliberately does not
/// participate in the unit identity. The consuming step records that hash.
final class LocalStageDependency {
  LocalStageDependency({
    required this.use,
    required String path,
    required this.type,
  }) : path = StagePath.require(path);

  final NativeArtifactUse use;
  final String path;
  final String type;

  factory LocalStageDependency.fromJson(Object? value) {
    final map = _map(value, {'use', 'path', 'type'});
    return LocalStageDependency(
      use: NativeArtifactUse.fromJson(map['use']),
      path: _string(map, 'path'),
      type: _string(map, 'type'),
    );
  }

  Map<String, Object?> toJson() => {
    'use': use.toJson(),
    'path': path,
    'type': type,
  };
}

/// Exact bytes imported from a completed, contract-validated provider stage.
/// The portable declaration contains no filesystem location. A provider handle
/// is needed only to create the consumer's independent copy.
final class ImportedStageDependency {
  ImportedStageDependency._({
    required this.use,
    required this.providerIdentity,
    required this.providerReceiptSha256,
    required this.providerOutputSha256,
    required this.original,
    required this.archive,
    required this.proof,
    ReleaseStage? provider,
    String? proofText,
  }) : _provider = provider,
       _proofText = proofText;

  factory ImportedStageDependency.fromProvider({
    required NativeArtifactUse use,
    required ReleaseStage provider,
    required String path,
    required String type,
  }) {
    if (!provider.enforceUnitContract ||
        provider.unit.name != use.provider.unit ||
        !provider.unit.projects.any((p) => p.name == use.provider.project)) {
      throw StateError('dependency provider does not match the selected unit');
    }
    final receipt = provider.requireReceipt();
    final producer = receipt.steps.singleWhere(
      (step) => step.name == use.provider.producer,
    );
    final original = producer.outputs.singleWhere(
      (artifact) => artifact.path == path && artifact.type == type,
    );
    final plan = provider.resolvedPlan;
    if (plan == null || _digest(plan) != receipt.identity.planSha256) {
      throw StateError('dependency provider plan does not match its identity');
    }
    final key = _digest({'context': use.context, 'slot': use.slot});
    final proofText =
        '${CanonicalJson.encode({'plan': plan, 'receipt': receipt.toJson()})}\n';
    return ImportedStageDependency._(
      use: use,
      providerIdentity: receipt.identity,
      providerReceiptSha256: Sha256.hex(utf8.encode(receipt.encode())),
      providerOutputSha256: producer.outputSha256,
      original: original,
      archive: StageArtifact(
        path: 'dependencies/$key/archive',
        type: 'dependency-archive',
        mode: original.mode,
        size: original.size,
        sha256: original.sha256,
      ),
      proof: StageArtifact(
        path: 'dependencies/$key/provider.json',
        type: 'dependency-proof',
        mode: '0644',
        size: utf8.encode(proofText).length,
        sha256: Sha256.hex(utf8.encode(proofText)),
      ),
      provider: provider,
      proofText: proofText,
    );
  }

  /// Restores the declaration, not trust in a receipt. The enclosing stage's
  /// source/intent lookup must validate this resolved plan and its identity;
  /// inspection then verifies the independent imported bytes and proof.
  factory ImportedStageDependency.fromJson(Object? value) {
    final map = _map(value, {
      'use',
      'provider_stage',
      'provider_receipt_sha256',
      'provider_output_sha256',
      'original',
      'archive',
      'proof',
    });
    final use = NativeArtifactUse.fromJson(map['use']);
    final original = StageArtifact.fromJson(map['original']);
    final archive = StageArtifact.fromJson(map['archive']);
    final proof = StageArtifact.fromJson(map['proof']);
    final key = _digest({'context': use.context, 'slot': use.slot});
    final receiptSha256 = _string(map, 'provider_receipt_sha256');
    final outputSha256 = _string(map, 'provider_output_sha256');
    if (archive.path != 'dependencies/$key/archive' ||
        archive.type != 'dependency-archive' ||
        archive.mode != original.mode ||
        archive.size != original.size ||
        archive.sha256 != original.sha256 ||
        proof.path != 'dependencies/$key/provider.json' ||
        proof.type != 'dependency-proof' ||
        proof.mode != '0644' ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(receiptSha256) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(outputSha256)) {
      throw const FormatException('invalid frozen dependency import');
    }
    return ImportedStageDependency._(
      use: use,
      providerIdentity: StageIdentity.fromJson(map['provider_stage']),
      providerReceiptSha256: receiptSha256,
      providerOutputSha256: outputSha256,
      original: original,
      archive: archive,
      proof: proof,
    );
  }

  final NativeArtifactUse use;
  final StageIdentity providerIdentity;
  final String providerReceiptSha256;
  final String providerOutputSha256;
  final StageArtifact original;
  final StageArtifact archive;
  final StageArtifact proof;
  final ReleaseStage? _provider;
  final String? _proofText;

  Map<String, Object?> toJson() => {
    'use': use.toJson(),
    'provider_stage': providerIdentity.toJson(),
    'provider_receipt_sha256': providerReceiptSha256,
    'provider_output_sha256': providerOutputSha256,
    'original': original.toJson(),
    'archive': archive.toJson(),
    'proof': proof.toJson(),
  };

  void materialize(StageDirectory destination) {
    final provider = _provider;
    if (provider == null || _proofText == null) {
      throw StateError(
        'dependency import is missing; restore its verified provider stage before retrying',
      );
    }
    final receipt = provider.requireReceipt();
    if (receipt.identity.id != providerIdentity.id ||
        Sha256.hex(utf8.encode(receipt.encode())) != providerReceiptSha256) {
      throw StateError('dependency provider receipt changed before import');
    }
    // Read and digest the actual copied bytes, even when inspection was cached.
    // A write between provider inspection and this read cannot be blessed.
    final bytes = File(
      provider.directory.resolve(original.path),
    ).readAsBytesSync();
    if (bytes.length != original.size || Sha256.hex(bytes) != original.sha256) {
      throw StateError('dependency archive changed before import');
    }
    destination.writeBytesAtomically(archive.path, bytes);
    destination.writeBytesAtomically(proof.path, utf8.encode(_proofText));
    setFileModes({
      destination.resolve(archive.path): archive.mode,
      destination.resolve(proof.path): proof.mode,
    });
  }

  void validateProof(StageDirectory stage) {
    final document = _map(
      CanonicalJson.decodeDocument(
        File(stage.resolve(proof.path)).readAsStringSync(),
      ),
      {'plan', 'receipt'},
    );
    final receipt = StageReceipt.parse(
      '${CanonicalJson.encode(document['receipt'])}\n',
    );
    final producer = receipt.steps.singleWhere(
      (step) => step.name == use.provider.producer,
    );
    if (!receipt.complete ||
        receipt.identity.id != providerIdentity.id ||
        _digest(document['plan']) != providerIdentity.planSha256 ||
        Sha256.hex(utf8.encode(receipt.encode())) != providerReceiptSha256 ||
        producer.outputSha256 != providerOutputSha256 ||
        !producer.outputs.any(
          (artifact) =>
              CanonicalJson.encode(artifact.toJson()) ==
              CanonicalJson.encode(original.toJson()),
        )) {
      throw const FormatException(
        'dependency provenance differs from the frozen provider',
      );
    }
  }
}

/// Frozen private inputs for a unit. The declarations are part of its resolved
/// plan and canonical contracts, not optional receipt evidence. Copies remain
/// verifiable after their provider stage is removed.
final class StageDependencies {
  StageDependencies({
    Iterable<ImportedStageDependency> imports = const [],
    Iterable<LocalStageDependency> local = const [],
  }) : imports = List.unmodifiable(
         imports.toList()
           ..sort((a, b) => a.archive.path.compareTo(b.archive.path)),
       ),
       local = List.unmodifiable(
         local.toList()..sort(
           (a, b) => CanonicalJson.encode(
             a.toJson(),
           ).compareTo(CanonicalJson.encode(b.toJson())),
         ),
       ) {
    final slots = <(String, String)>{};
    for (final use in uses) {
      if (!slots.add((use.context, use.slot))) {
        throw ArgumentError(
          'duplicate dependency slot ${use.context}/${use.slot}',
        );
      }
    }
  }

  static const importProducer = 'dependency-inputs';
  final List<ImportedStageDependency> imports;
  final List<LocalStageDependency> local;

  factory StageDependencies.fromJson(Object? value) {
    final map = _map(value, {'imports', 'local'});
    return StageDependencies(
      imports: _list(map, 'imports').map(ImportedStageDependency.fromJson),
      local: _list(map, 'local').map(LocalStageDependency.fromJson),
    );
  }
  bool get isEmpty => imports.isEmpty && local.isEmpty;
  Iterable<NativeArtifactUse> get uses => [
    ...imports.map((input) => input.use),
    ...local.map((input) => input.use),
  ];

  Map<String, Object?> toJson() => {
    'imports': [for (final input in imports) input.toJson()],
    'local': [for (final input in local) input.toJson()],
  };

  void validateProducers(String unit, Iterable<StageStepContract> contracts) {
    final byName = {for (final contract in contracts) contract.name: contract};
    for (final use in uses) {
      for (final consumer in use.consumers) {
        if (!byName.containsKey(consumer)) {
          throw StateError(
            'dependency names unknown consumer producer "$consumer"',
          );
        }
      }
    }
    for (final input in imports) {
      if (input.use.provider.unit == unit) {
        throw StateError(
          'same-unit dependency must use a producer artifact edge',
        );
      }
    }
    for (final input in local) {
      final owner = byName[input.use.provider.producer];
      if (input.use.provider.unit != unit ||
          owner == null ||
          owner.outputs[input.path] != input.type ||
          input.use.consumers.contains(owner.name)) {
        throw StateError(
          'local dependency does not match its provider producer',
        );
      }
    }
  }

  StageStepContract decorate(StageStepContract contract) => StageStepContract(
    contract.name,
    inputs: {
      ...contract.inputs,
      for (final input in imports)
        if (input.use.consumers.contains(contract.name)) input.archive.path,
      for (final input in local)
        if (input.use.consumers.contains(contract.name)) input.path,
    },
    outputs: contract.outputs,
    validate: contract.validate,
  );

  StageContributionContract get contribution => StageContributionContract(
    step: StageStepContract(
      importProducer,
      inputs: const {'step:source-snapshot'},
      outputs: {for (final artifact in _outputs) artifact.path: artifact.type},
      validate: (context, step) sync* {
        final actual = {for (final output in step.outputs) output.path: output};
        for (final expected in _outputs) {
          if (CanonicalJson.encode(actual[expected.path]?.toJson()) !=
              CanonicalJson.encode(expected.toJson())) {
            yield StageIssue(
              StageIssueKind.invalidStructure,
              'dependency input differs from the frozen release plan',
              path: expected.path,
            );
          }
        }
        for (final input in imports) {
          try {
            input.validateProof(context.stage);
          } on Object catch (error) {
            yield StageIssue(
              StageIssueKind.invalidStructure,
              'dependency provider proof is invalid: $error',
              path: input.proof.path,
            );
          }
        }
      },
    ),
  );

  Iterable<StageArtifact> get _outputs sync* {
    for (final input in imports) {
      yield input.archive;
      yield input.proof;
    }
  }

  StageStep materialize(StageDirectory stage, StageStep source) {
    if (source.name != 'source-snapshot') {
      throw ArgumentError('dependency imports need the source snapshot');
    }
    for (final input in imports) {
      input.materialize(stage);
    }
    return StageStep(
      name: importProducer,
      inputs: [StageInput.step(source)],
      outputs: _outputs,
    );
  }
}

String _digest(Object? value) =>
    Sha256.hex(utf8.encode(CanonicalJson.encode(value)));

Map<String, Object?> _map(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    throw const FormatException(
      'dependency declaration has missing or unknown fields',
    );
  }
  return value.cast<String, Object?>();
}

String _string(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String ||
      value.isEmpty ||
      value.contains(RegExp(r'[\u0000-\u001f]'))) {
    throw FormatException('invalid dependency $key');
  }
  return value;
}

List<Object?> _list(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! List) throw FormatException('invalid dependency $key');
  return value.cast<Object?>();
}
