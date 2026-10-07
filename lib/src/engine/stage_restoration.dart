import 'dart:convert';

import 'canonical_json.dart';
import 'config.dart';
import 'diagnostic.dart';
import 'git.dart';
import 'native_stage_authorization.dart';
import 'release_stage.dart';
import 'resolve.dart';
import 'resolution_facts.dart';
import 'source_tree.dart';
import 'stage_dependencies.dart';
import 'stage_intent.dart';
import 'stage_inspection.dart';
import 'stage_lookup.dart';
import 'stage_proof.dart';
import 'stage_receipt.dart';
import 'stage_source.dart';
import 'stage_store.dart';
import 'timings.dart';

/// Observes frozen local evidence or reuses native selections transactionally.
/// Restoring commands hold the store's mutation lock; [observeLocal] is read-only.
/// For a selected consumer, only conclusive absence permits fresh discovery. Optional sibling probes accept only completed
/// stages. Every refusal leaves the shared resolver and stage files unchanged.
/// Native semantics are supplied by adapters; this layer owns provenance,
/// source/contract authority, bounds and installation into [ReleaseStages].
final class StageRestoration {
  StageRestoration._({
    required this.stages,
    required this.git,
    required this.authority,
    required this.source,
    required this.resolution,
    required this.resolvedFacts,
    required this.lookup,
    required this.limits,
    required this.refreshGit,
  });

  /// [resolution] is the same model used to construct [stages] and its target
  /// contract resolver. Verify its parsed facts before retaining those objects.
  static Future<StageRestoration> create({
    required ReleaseStages stages,
    required Resolution resolution,
    required GitState currentGit,
    required NativeStageAuthority authority,
    StageProofLimits limits = const StageProofLimits(),
    Future<GitState> Function()? refreshGit,
  }) async {
    if ([
      limits.bytes,
      limits.stages,
      limits.edges,
      limits.depth,
      limits.expandedBytes,
    ].any((limit) => limit < 1)) {
      throw ArgumentError('restoration bounds must be positive');
    }
    final shared = stages.source;
    final StageSourceSnapshot source;
    if (currentGit.isBound) {
      if (shared is! GitSourceTree &&
          shared is! GitCommitSourceTree &&
          !(shared is StageSourceSnapshot &&
              shared.gitCommit == currentGit.head)) {
        throw StateError(
          'bound restoration requires committed resolver source',
        );
      }
      source = await StageSourceSnapshot.capture(
        GitCommitSourceTree(currentGit.root, currentGit.head),
      );
      final selected = await StageSourceSnapshot.capture(
        shared,
        commit: currentGit.head,
      );
      if (CanonicalJson.encode(
            selected.artifacts.map((a) => a.toJson()).toList(),
          ) !=
          CanonicalJson.encode(
            source.artifacts.map((a) => a.toJson()).toList(),
          )) {
        throw StateError(
          'resolver source differs from authoritative Git source',
        );
      }
    } else {
      if (shared is! FrozenSourceTree && shared is! StageSourceSnapshot) {
        throw StateError(
          'unbound restoration requires the invocation snapshot',
        );
      }
      source = await StageSourceSnapshot.capture(shared);
      if (source.gitCommit != null) {
        throw StateError('unbound restoration cannot reuse committed source');
      }
    }
    final diagnostics = Diagnostics();
    final configText = source.read('release.toml');
    if (configText == null) {
      throw StateError('selected source has no release.toml');
    }
    final config = ReleaseConfig.parse(configText, 'release.toml', diagnostics);
    final selectedResolution = config == null
        ? null
        : Resolution.resolve(config, source, diagnostics);
    if (selectedResolution == null) {
      throw StateError(
        'invalid selected release: ${diagnostics.found.join('; ')}',
      );
    }
    final expected = resolutionFacts(selectedResolution);
    if (resolutionFacts(resolution) != expected) {
      throw StateError('parsed resolution differs from authoritative source');
    }
    return StageRestoration._(
      stages: stages,
      git: currentGit,
      authority: authority,
      source: source,
      resolution: resolution,
      resolvedFacts: expected,
      lookup: StageLookup(StageStore(stages.repositoryRoot)),
      limits: limits,
      refreshGit:
          refreshGit ??
          (() => currentGit.isBound
              ? GitState.read(currentGit.root)
              : Future.value(currentGit)),
    );
  }

  final ReleaseStages stages;
  final GitState git;
  final NativeStageAuthority authority;
  final StageSourceSnapshot source;
  final Resolution resolution;
  final String resolvedFacts;
  final StageLookup lookup;
  final StageProofLimits limits;
  final Future<GitState> Function() refreshGit;

  StageIntent _intent(ResolvedUnit unit, GitState current) => stages.intentFor(
    unit,
    currentGit: current,
    readInputs: () => authority.readIntent(unit),
  );

  /// Observes current local evidence without native verification or adoption.
  /// Only copied, already-recorded provider proofs participate; a pending input
  /// never causes provider lookup, recovery, production or source cleanup.
  /// Every returned candidate is uninstalled and carries no native authority.
  Future<StageObservation> observeLocal(String unitName) async {
    _requireResolution();
    final unit = resolution.unit(unitName);
    if (unit == null) {
      throw StateError('unknown current release unit: $unitName');
    }
    final intent = _intent(unit, git);
    final found = await lookup.find(intent);
    if (found.kind != StageLookupKind.found &&
        found.kind != StageLookupKind.absent) {
      return StageObservation._(lookup: found, problem: found.message);
    }
    StageInspection? inspection;
    try {
      if (found.kind == StageLookupKind.absent) {
        final current = await refreshGit();
        _requireResolution();
        _requireBinding(current);
        intent.requireCurrent(_intent(unit, current).base);
        return StageObservation._(lookup: found);
      }
      final root = found.receipt!;
      final budget = _ClosureBudget(limits);
      final nodes = <String, _Node>{};
      _Node add(StageReceipt receipt) {
        final id = receipt.identity.id;
        final previous = nodes[id];
        if (previous != null) {
          if (previous.receipt.encode() != receipt.encode()) {
            throw StateError('conflicting frozen provider receipts');
          }
          return previous;
        }
        budget.add(receipt);
        if (id != root.identity.id && !receipt.complete) {
          throw StateError('dependency proof requires completed providers');
        }
        return nodes[id] = _localNode(receipt, git);
      }

      final consumer = add(root);
      inspection = consumer.stage.inspect();
      _requireRetained(consumer);
      final inputsRecorded = root.steps.any(
        (step) => step.name == StageDependencies.importProducer,
      );
      if (inputsRecorded) {
        _readCopiedProofs(
          consumer,
          budget: budget,
          proofsRead: <String>{},
          add: add,
        );
        _requireGraph(nodes, limits.depth);
      }
      // This is the last await. Reconstruct all current contracts and intents,
      // then re-read direct bytes and the receipt before exposing the snapshot.
      final current = await refreshGit();
      _requireResolution();
      _requireBinding(current);
      late _Node checkedRoot;
      for (final node in nodes.values) {
        final checked = _localNode(node.receipt, current);
        if (node.receipt.identity.id == root.identity.id) checkedRoot = checked;
      }
      inspection = checkedRoot.stage.inspect();
      _requireRetained(checkedRoot);
      return StageObservation._(
        lookup: found,
        candidate: checkedRoot.stage,
        inspection: inspection,
      );
    } on Object catch (error) {
      return StageObservation._(
        lookup: found,
        inspection: inspection,
        problem: '$error',
      );
    }
  }

  _Node _localNode(StageReceipt receipt, GitState current) {
    final name = (receipt.plan?['unit'] as Map?)?['name'];
    final unit = name is String ? resolution.unit(name) : null;
    if (unit == null) throw StateError('proof names an unknown current unit');
    final intent = _intent(unit, current);
    intent.requireReceipt(receipt);
    final candidate = stages.candidateForReceipt(
      unit,
      currentGit: current,
      receipt: receipt,
      intent: intent,
    );
    _requireEcosystems(candidate.dependencies);
    final issues = candidate.validatePortableReceipt(
      receipt,
      authoritativeSource: source,
    );
    if (issues.isNotEmpty) {
      throw StateError(
        'frozen ${unit.name} has invalid local evidence: ${issues.join('; ')}',
      );
    }
    return _Node(receipt, candidate);
  }

  /// [recoveryStageId] is only for independently authenticated public recovery.
  /// A declared provider reference is instead read and authenticated inside the
  /// closure walk, never passed here as public recovery authority.
  Future<ReleaseStage?> restore(String unitName, {String? recoveryStageId}) =>
      _restore(unitName, recoveryStageId: recoveryStageId);

  /// Offers a completed current sibling to fresh named-command discovery.
  /// Missing, incomplete, ambiguous or unusable siblings are not candidates.
  /// This must never replace [restore] for a selected consumer: its frozen
  /// choices cannot be discarded merely because their authorization fails.
  ///
  /// Uses the same full source/native/byte authorization and transactional
  /// adoption, but never recovers pending inputs or writes stage files. The
  /// repository coordinator separately refuses drift in the overall scope.
  Future<ReleaseStage?> restoreCompletedProvider(String unitName) async {
    try {
      return await _restore(unitName, requireComplete: true);
    } on Object {
      return null;
    }
  }

  Future<ReleaseStage?> _restore(
    String unitName, {
    String? recoveryStageId,
    bool requireComplete = false,
  }) async {
    _requireResolution();
    final unit = resolution.unit(unitName);
    if (unit == null) {
      throw StateError('unknown current release unit: $unitName');
    }
    final intent = _intent(unit, git);
    final found = await Timings.span(
      'find stage',
      () => lookup.find(intent, recoveryStageId: recoveryStageId),
    );
    if (found.kind == StageLookupKind.absent) {
      final current = await refreshGit();
      _requireResolution();
      _requireBinding(current);
      intent.requireCurrent(_intent(unit, current).base);
      return null;
    }
    if (found.kind != StageLookupKind.found) {
      throw StateError(
        'cannot restore frozen stage: ${found.message} (${found.path})',
      );
    }
    final receipt = found.receipt!;
    if (requireComplete && !receipt.complete) return null;
    late void Function() recheck;
    return Timings.span(
      'adopt frozen stage',
      () => stages.adoptFrozen(
        unit,
        currentGit: git,
        receipt: receipt,
        intent: intent,
        authorize: (receipt, _) async {
          final restored = await _authorize(
            receipt,
            requireComplete: requireComplete,
          );
          recheck = restored.recheck;
          return restored.dependencies;
        },
        beforeInstall: () => recheck(),
      ),
    );
  }

  Future<({StageDependencies dependencies, void Function() recheck})>
  _authorize(StageReceipt root, {required bool requireComplete}) async {
    if (requireComplete && !root.complete) {
      throw StateError('optional provider requires a completed receipt');
    }
    final budget = _ClosureBudget(limits);
    final nodes = <String, _Node>{};
    final actual = <String>{};
    final proofsRead = <String>{};

    _Node add(StageReceipt receipt, {bool retained = false}) {
      final id = receipt.identity.id;
      final previous = nodes[id];
      if (previous != null) {
        if (previous.receipt.encode() != receipt.encode()) {
          throw StateError('conflicting frozen provider receipts');
        }
        if (retained) actual.add(id);
        return previous;
      }
      budget.add(receipt);
      if (id != root.identity.id && !receipt.complete) {
        throw StateError('dependency proof requires completed providers');
      }
      final node = _localNode(receipt, git);
      nodes[id] = node;
      if (retained) actual.add(id);
      return node;
    }

    void readProofs(_Node node) => _readCopiedProofs(
      node,
      budget: budget,
      proofsRead: proofsRead,
      add: add,
    );

    final consumer = add(root, retained: true);
    final declared = consumer.stage.dependencies;
    final pendingImports = !root.steps.any(
      (step) => step.name == StageDependencies.importProducer,
    );
    if (requireComplete && pendingImports && declared.hasImports) {
      throw StateError('optional provider cannot recover pending inputs');
    }
    if (!pendingImports) {
      // Already-recorded copies are the authority. Missing/corrupt copies must
      // never be repaired from an old provider directory or a registry.
      readProofs(consumer);
    } else {
      for (final input in declared.imports) {
        final id = input.providerIdentity.id;
        final StageReceipt saved;
        if (actual.contains(id)) {
          saved = nodes[id]!.receipt;
        } else {
          saved = lookup.readExact(id, maxBytes: budget.remainingReads);
          budget.readBytes(utf8.encode(saved.encode()).length);
        }
        input.requireProviderReceipt(saved);
        final provider = add(saved, retained: true);
        readProofs(provider);
      }
    }
    _requireGraph(nodes, limits.depth);
    for (final id in actual) {
      _requireRetained(nodes[id]!);
    }
    final authorized = <String, AuthorizedNativeStage>{};
    for (final node in nodes.values) {
      // Empty serialized contexts are not permission to skip native policy.
      authorized[node.receipt.identity.id] = await authority.authorize(
        node.stage.unit,
        node.receipt,
      );
    }
    for (final id in actual) {
      final node = nodes[id]!;
      await authorized[id]!.validateRetained(node.stage, node.receipt);
    }
    var recovered = declared;
    if (pendingImports && !requireComplete) {
      final external = <ExternalStageDependency>[];
      for (final input in declared.external) {
        final restored = await authorized[root.identity.id]!.recoverExternal(
          input,
        );
        _requireSame(input.toJson(), restored.toJson());
        external.add(restored);
      }
      final imports = <ImportedStageDependency>[];
      for (final input in declared.imports) {
        final restored = ImportedStageDependency.fromProvider(
          use: input.use,
          provider: nodes[input.providerIdentity.id]!.stage,
          path: input.original.path,
          type: input.original.type,
        );
        _requireSame(input.toJson(), restored.toJson());
        imports.add(restored);
      }
      recovered = StageDependencies(
        contexts: declared.contexts,
        local: declared.local,
        imports: imports,
        external: external,
      );
    }
    // Last await. Recheck earlier providers as well as the root: a later
    // download/native call may have changed their bytes or current inputs.
    final current = await refreshGit();
    _requireBinding(current);
    void recheck() {
      _requireResolution();
      final retained = <_Node>[];
      for (final node in nodes.values) {
        final intent = _intent(node.stage.unit, current);
        intent.requireReceipt(node.receipt);
        final candidate = stages.candidateForReceipt(
          node.stage.unit,
          currentGit: current,
          receipt: node.receipt,
          intent: intent,
        );
        final issues = candidate.validatePortableReceipt(
          node.receipt,
          authoritativeSource: source,
        );
        if (issues.isNotEmpty) {
          throw StateError(
            'current provider contract changed: ${issues.join('; ')}',
          );
        }
        if (actual.contains(node.receipt.identity.id)) {
          retained.add(_Node(node.receipt, candidate));
        }
      }
      for (final node in retained) {
        _requireRetained(node);
      }
    }

    recheck();
    return (dependencies: recovered, recheck: recheck);
  }

  void _requireResolution() {
    if (resolutionFacts(resolution) != resolvedFacts) {
      throw StateError('parsed resolution changed during frozen authorization');
    }
  }

  void _requireBinding(GitState current) {
    if (current.root != git.root || current.isBound != git.isBound) {
      throw StateError('source binding changed during frozen authorization');
    }
  }

  void _requireEcosystems(StageDependencies dependencies) {
    final ecosystems = <String>{
      for (final context in dependencies.contexts) context.ecosystem,
      for (final context in dependencies.contexts)
        for (final binding in context.bindings) binding.package.ecosystem,
      for (final use in dependencies.uses) use.provider.package.ecosystem,
      for (final input in dependencies.external)
        input.binding.package.ecosystem,
    };
    if (!authority.ecosystems.containsAll(ecosystems)) {
      throw StateError(
        'no native authority for ${ecosystems.difference(authority.ecosystems).join(', ')}',
      );
    }
  }
}

/// A read-only snapshot of local evidence, never native authorization.
/// [candidate] is exposed only after all local checks succeed. [inspection]
/// retains diagnostics on failure, so callers must check [locallyVerified]
/// before using its stage or progress as a successful observation.
final class StageObservation {
  const StageObservation._({
    required this.lookup,
    this.candidate,
    this.inspection,
    this.problem,
  });

  final StageLookupResult lookup;
  final ReleaseStage? candidate;
  final StageInspection? inspection;
  final String? problem;

  bool get locallyVerified =>
      lookup.kind == StageLookupKind.found &&
      candidate != null &&
      inspection != null &&
      problem == null;

  /// Recognized native facts still need the native stage/release checks.
  /// False means no recognized native facts, never that checks were performed.
  bool get nativeAuthorizationDeferred {
    final dependencies = candidate?.dependencies;
    return dependencies != null &&
        (dependencies.contexts.isNotEmpty ||
            dependencies.uses.isNotEmpty ||
            dependencies.external.isNotEmpty);
  }
}

void _readCopiedProofs(
  _Node node, {
  required _ClosureBudget budget,
  required Set<String> proofsRead,
  required void Function(StageReceipt) add,
}) {
  for (final input in node.stage.dependencies.imports) {
    final key = '${node.receipt.identity.id}:${input.proof.path}';
    if (!proofsRead.add(key)) continue;
    budget.readBytes(input.proof.size);
    final closure = StageProofClosure.read(
      node.stage.directory,
      input.proof,
      limits: budget.proofLimits,
    );
    budget.expand(closure.expandedBytes);
    closure.requireImport(input);
    for (final receipt in closure.stages.values) {
      add(receipt);
    }
  }
}

final class _Node {
  const _Node(this.receipt, this.stage);
  final StageReceipt receipt;
  final ReleaseStage stage;
}

void _requireSame(Object? declared, Object? recovered) {
  if (CanonicalJson.encode(declared) != CanonicalJson.encode(recovered)) {
    throw StateError('recovery changed the frozen dependency declaration');
  }
}

void _requireRetained(_Node node) {
  final inspected = node.stage.inspect();
  if (inspected.receipt?.encode() != node.receipt.encode()) {
    throw StateError('retained receipt changed during frozen authorization');
  }
  if (!inspected.reusable &&
      !inspected.validProgress &&
      !inspected.canRestartSource) {
    node.stage.requireProducerProgress();
  }
}

final class _ClosureBudget {
  _ClosureBudget(this.limits);
  final StageProofLimits limits;
  int stages = 0;
  int bytes = 0;
  int edges = 0;
  int readCount = 0;
  int expandedCount = 0;
  int get remainingReads => limits.expandedBytes - readCount;
  StageProofLimits get proofLimits => StageProofLimits(
    bytes: limits.bytes,
    stages: limits.stages,
    edges: limits.edges,
    depth: limits.depth,
    expandedBytes: limits.expandedBytes > expandedCount
        ? limits.expandedBytes - expandedCount
        : 1,
  );

  void add(StageReceipt receipt) {
    stages++;
    bytes += utf8.encode(receipt.encode()).length;
    final value = receipt.plan?['dependency_inputs'];
    if (value != null) {
      edges += StageDependencies.fromJson(value).imports.length;
    }
    if (stages > limits.stages ||
        bytes > limits.bytes ||
        edges > limits.edges) {
      throw StateError('combined dependency proof limit exceeded');
    }
  }

  void readBytes(int size) {
    readCount += size;
    if (readCount > limits.expandedBytes) {
      throw StateError('combined dependency proof read limit exceeded');
    }
  }

  void expand(int size) {
    expandedCount += size;
    if (expandedCount > limits.expandedBytes) {
      throw StateError('combined dependency proof expansion limit exceeded');
    }
  }
}

void _requireGraph(Map<String, _Node> nodes, int maxDepth) {
  final depths = <String, int>{};
  final visiting = <String>{};
  int visit(String id) {
    if (depths[id] case final depth?) return depth;
    if (!visiting.add(id) || visiting.length > maxDepth) {
      throw StateError('cyclic or too deep dependency proof');
    }
    var depth = 1;
    final node = nodes[id]!;
    for (final input in node.stage.dependencies.imports) {
      final provider = nodes[input.providerIdentity.id];
      if (provider == null) {
        throw StateError('dependency proof provider is missing');
      }
      input.requireProviderReceipt(provider.receipt);
      final candidate = 1 + visit(provider.receipt.identity.id);
      if (candidate > depth) depth = candidate;
      if (depth > maxDepth) {
        throw StateError('combined dependency proof depth limit exceeded');
      }
    }
    visiting.remove(id);
    return depths[id] = depth;
  }

  for (final id in nodes.keys) {
    visit(id);
  }
}
