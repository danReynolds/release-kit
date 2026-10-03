import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../transforms/digest.dart';
import 'canonical_json.dart';
import 'file_mode.dart';
import 'native_dependencies.dart';
import 'native_stage_context.dart';
import 'release_stage.dart';
import 'stage.dart';
import 'stage_contract.dart';
import 'stage_inspection.dart';
import 'stage_receipt.dart';
import 'stage_proof.dart';

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
    return NativeArtifactUse(
      context: _string(map, 'context'),
      slot: _string(map, 'slot'),
      provider: NativeCandidate.fromJson(map['provider']),
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
    final proofText = StageProofClosure.fromReceipt(receipt, [
      for (final input in provider.dependencies.imports)
        input.readProof(provider.directory),
    ]).encode();
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

  StageProofClosure readProof(StageDirectory stage) {
    final closure = StageProofClosure.read(stage, proof);
    closure.requireImport(this);
    return closure;
  }

  void validateProof(StageDirectory stage) => readProof(stage);

  /// Causal receipt/metadata check only. Source and native authorization remain
  /// the caller's responsibility; no provider filesystem is needed here.
  void requireProviderReceipt(StageReceipt receipt) {
    final producer = receipt.steps
        .where((step) => step.name == use.provider.producer)
        .singleOrNull;
    final unit = receipt.plan?['unit'];
    if (!receipt.complete ||
        receipt.plan == null ||
        producer == null ||
        receipt.identity.id != providerIdentity.id ||
        unit is! Map ||
        unit['name'] != use.provider.unit ||
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

/// An adapter-verified external archive. There is no provider stage or release
/// obligation. The caller validates native source/integrity/manifest evidence
/// first; core freezes exact immutable bytes and their consuming slot.
final class ExternalStageDependency {
  ExternalStageDependency._({
    required this.context,
    required this.binding,
    required Iterable<String> consumers,
    required this.archive,
    Uint8List? bytes,
  }) : consumers = List.unmodifiable(consumers.toSet().toList()..sort()),
       _bytes = bytes {
    if (context.isEmpty ||
        this.consumers.isEmpty ||
        binding.provider != null ||
        archive.path !=
            'dependencies/${_digest({'context': context, 'slot': binding.slot})}/archive' ||
        archive.type != 'dependency-archive' ||
        archive.mode != '0644') {
      throw ArgumentError('invalid external native archive declaration');
    }
  }

  factory ExternalStageDependency.fromBytes({
    required String context,
    required NativeStageBinding binding,
    required Iterable<String> consumers,
    required List<int> bytes,
    required String expectedSha256,
  }) {
    final owned = Uint8List.fromList(bytes).asUnmodifiableView();
    if (Sha256.hex(owned) != expectedSha256) {
      throw StateError(
        'external native archive differs from its authorized digest',
      );
    }
    return ExternalStageDependency._(
      context: context,
      binding: binding,
      consumers: consumers,
      bytes: owned,
      archive: StageArtifact(
        path:
            'dependencies/${_digest({'context': context, 'slot': binding.slot})}/archive',
        type: 'dependency-archive',
        mode: '0644',
        size: owned.length,
        sha256: expectedSha256,
      ),
    );
  }

  /// Structural restore only. Native source authorization must independently
  /// validate the frozen coordinate and integrity before binding this plan.
  factory ExternalStageDependency.fromJson(Object? value) {
    final map = _map(value, {'context', 'binding', 'consumers', 'archive'});
    return ExternalStageDependency._(
      context: _string(map, 'context'),
      binding: NativeStageBinding.fromJson(map['binding']),
      consumers: _list(map, 'consumers').cast<String>(),
      archive: StageArtifact.fromJson(map['archive']),
    );
  }
  final String context;
  final NativeStageBinding binding;
  final List<String> consumers;
  final StageArtifact archive;
  final Uint8List? _bytes;
  Map<String, Object?> toJson() => {
    'context': context,
    'binding': binding.toJson(),
    'consumers': consumers,
    'archive': archive.toJson(),
  };

  void materialize(StageDirectory destination) {
    final bytes = _bytes;
    if (bytes == null) {
      throw StateError(
        'external native archive is missing; reacquire its exact authorized bytes before retrying',
      );
    }
    if (bytes.length != archive.size || Sha256.hex(bytes) != archive.sha256) {
      throw StateError('external native archive changed before import');
    }
    destination.writeBytesAtomically(archive.path, bytes);
    setFileModes({destination.resolve(archive.path): archive.mode});
  }
}

/// Frozen private inputs for a unit. The declarations are part of its resolved
/// plan and canonical contracts, not optional receipt evidence. Copies remain
/// verifiable after their provider stage is removed.
final class StageDependencies {
  StageDependencies({
    Iterable<ImportedStageDependency> imports = const [],
    Iterable<LocalStageDependency> local = const [],
    Iterable<ExternalStageDependency> external = const [],
    Iterable<NativeStageContext> contexts = const [],
  }) : imports = List.unmodifiable(
         imports.toList()
           ..sort((a, b) => a.archive.path.compareTo(b.archive.path)),
       ),
       external = List.unmodifiable(
         external.toList()
           ..sort((a, b) => a.archive.path.compareTo(b.archive.path)),
       ),
       contexts = List.unmodifiable(
         contexts.toList()..sort((a, b) => a.context.compareTo(b.context)),
       ),
       local = List.unmodifiable(
         local.toList()..sort(
           (a, b) => CanonicalJson.encode(
             a.toJson(),
           ).compareTo(CanonicalJson.encode(b.toJson())),
         ),
       ) {
    final slots = <(String, String)>{};
    for (final use in _allUses) {
      if (!slots.add((use.context, use.slot))) {
        throw ArgumentError(
          'duplicate dependency slot ${use.context}/${use.slot}',
        );
      }
    }
    final byContext = {
      for (final context in this.contexts) context.context: context,
    };
    if (byContext.length != this.contexts.length) {
      throw ArgumentError('duplicate native resolution context');
    }
    if (this.external.isNotEmpty && this.contexts.isEmpty) {
      throw ArgumentError(
        'external archives require an authorized native context',
      );
    }
    if (this.contexts.isNotEmpty) {
      final declared = <(String, String)>{};
      for (final context in this.contexts) {
        for (final binding in context.bindings) {
          declared.add((context.context, binding.slot));
        }
      }
      if (declared.length != slots.length || !declared.containsAll(slots)) {
        throw ArgumentError(
          'native context archive coverage has missing or extra slots',
        );
      }
      for (final use in _allUses) {
        final context = byContext[use.context]!;
        final binding = context.bindings.singleWhere(
          (binding) => binding.slot == use.slot,
        );
        if (_digest(binding.toJson()) != _digest(use.binding.toJson()) ||
            _digest(context.consumers) != _digest(use.consumers)) {
          throw ArgumentError(
            'native context does not authorize this archive identity or consumers',
          );
        }
      }
    }
  }

  static const importProducer = 'dependency-inputs';
  final List<ImportedStageDependency> imports;
  final List<LocalStageDependency> local;
  final List<ExternalStageDependency> external;
  final List<NativeStageContext> contexts;

  factory StageDependencies.fromJson(Object? value) {
    final map = _map(value, {
      'imports',
      'local',
      if (value is Map && value.containsKey('external')) 'external',
      if (value is Map && value.containsKey('contexts')) 'contexts',
    });
    return StageDependencies(
      imports: _list(map, 'imports').map(ImportedStageDependency.fromJson),
      local: _list(map, 'local').map(LocalStageDependency.fromJson),
      external: map.containsKey('external')
          ? _list(map, 'external').map(ExternalStageDependency.fromJson)
          : const [],
      contexts: map.containsKey('contexts')
          ? _list(map, 'contexts').map(NativeStageContext.fromJson)
          : const [],
    );
  }
  bool get isEmpty =>
      imports.isEmpty && local.isEmpty && external.isEmpty && contexts.isEmpty;
  bool get hasImports => imports.isNotEmpty || external.isNotEmpty;
  Iterable<NativeArtifactUse> get uses => [
    ...imports.map((input) => input.use),
    ...local.map((input) => input.use),
  ];

  Iterable<
    ({
      String context,
      String slot,
      List<String> consumers,
      NativeStageBinding binding,
    })
  >
  get _allUses sync* {
    for (final use in uses) {
      yield (
        context: use.context,
        slot: use.slot,
        consumers: use.consumers,
        binding: NativeStageBinding(
          slot: use.slot,
          package: use.provider.package,
          version: use.provider.version,
          provider: use.provider,
        ),
      );
    }
    for (final input in external) {
      yield (
        context: input.context,
        slot: input.binding.slot,
        consumers: input.consumers,
        binding: input.binding,
      );
    }
  }

  Map<String, Object?> toJson() => {
    'imports': [for (final input in imports) input.toJson()],
    'local': [for (final input in local) input.toJson()],
    if (external.isNotEmpty)
      'external': [for (final input in external) input.toJson()],
    if (contexts.isNotEmpty)
      'contexts': [for (final context in contexts) context.toJson()],
  };

  void validateProducers(
    String unit,
    Iterable<StageStepContract> contracts, {
    Set<String>? owners,
  }) {
    final byName = {for (final contract in contracts) contract.name: contract};
    for (final context in contexts) {
      if (owners != null && !owners.contains(context.owner)) {
        throw StateError('native context owner is outside this release unit');
      }
      for (final consumer in context.consumers) {
        if (!byName.containsKey(consumer)) {
          throw StateError(
            'native context names unknown consumer producer "$consumer"',
          );
        }
      }
    }
    for (final use in _allUses) {
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
      for (final input in external)
        if (input.consumers.contains(contract.name)) input.archive.path,
    },
    outputs: contract.outputs,
    validateEvidence: contract.validateEvidence,
    validate: contract.validate,
  );

  StageContributionContract get contribution => StageContributionContract(
    step: StageStepContract(
      importProducer,
      inputs: const {'step:source-snapshot'},
      outputs: {for (final artifact in _outputs) artifact.path: artifact.type},
      validateEvidence: (context, step) =>
          validateRecordedInputs(context.receipt),
      validate: (context, step) sync* {
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

  /// Checks the exact frozen imports and their consumer bindings from receipt
  /// declarations. This is shared with portable proof verification; it neither
  /// reads files nor substitutes for native/current-plan authorization.
  List<StageIssue> validateRecordedInputs(StageReceipt receipt) {
    final issues = <StageIssue>[];
    void reject(String message, [String? path]) => issues.add(
      StageIssue(StageIssueKind.invalidStructure, message, path: path),
    );
    final unit = receipt.plan?['unit'];
    final unitName = unit is Map ? unit['name'] : null;
    if ((imports.isNotEmpty || local.isNotEmpty) &&
        (unitName is! String || unitName.isEmpty)) {
      reject('dependency receipt has no unit ownership');
    }
    for (final input in imports) {
      if (input.use.provider.unit == unitName) {
        reject('same-unit dependency must use a producer artifact edge');
      }
    }
    for (final input in local) {
      if (input.use.provider.unit != unitName) {
        reject('local dependency names another unit');
      }
    }
    final steps = {for (final step in receipt.steps) step.name: step};
    final step = steps[importProducer];
    if (step == null) {
      if (hasImports && receipt.complete) {
        reject('missing dependency input producer');
      }
    } else {
      final source = steps['source-snapshot'];
      if (!hasImports ||
          source == null ||
          step.inputs.length != 1 ||
          step.inputs.single.name != 'step:source-snapshot' ||
          step.inputs.single.sha256 != source.outputSha256) {
        reject('dependency input producer is not bound to its source');
      }
      final actual = {for (final output in step.outputs) output.path: output};
      final expected = _outputs.toList();
      if (actual.length != expected.length) {
        reject('dependency input inventory differs from the frozen plan');
      }
      for (final artifact in expected) {
        if (CanonicalJson.encode(actual[artifact.path]?.toJson()) !=
            CanonicalJson.encode(artifact.toJson())) {
          reject(
            'dependency input differs from the frozen release plan',
            artifact.path,
          );
        }
      }
    }
    void requireConsumer(String consumer, StageArtifact artifact) {
      final consuming = steps[consumer];
      if (consuming == null) {
        if (receipt.complete) reject('missing dependency consumer $consumer');
      } else if (!consuming.inputs.any(
        (input) =>
            input.name == artifact.path && input.sha256 == artifact.sha256,
      )) {
        reject(
          'dependency consumer $consumer does not bind the frozen archive',
          artifact.path,
        );
      }
    }

    for (final input in imports) {
      for (final consumer in input.use.consumers) {
        requireConsumer(consumer, input.archive);
      }
    }
    for (final input in external) {
      for (final consumer in input.consumers) {
        requireConsumer(consumer, input.archive);
      }
    }
    for (final input in local) {
      final producer = steps[input.use.provider.producer];
      final artifact = producer?.outputs
          .where(
            (output) => output.path == input.path && output.type == input.type,
          )
          .singleOrNull;
      if (artifact == null) {
        if (receipt.complete || input.use.consumers.any(steps.containsKey)) {
          reject('local dependency lacks its provider artifact', input.path);
        }
      } else {
        for (final consumer in input.use.consumers) {
          requireConsumer(consumer, artifact);
        }
      }
    }
    return issues;
  }

  Iterable<StageArtifact> get _outputs sync* {
    for (final input in external) {
      yield input.archive;
    }
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
    for (final input in external) {
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
