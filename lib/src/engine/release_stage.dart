import 'dart:io';
import 'dart:math';

import 'canonical_json.dart';
import 'release_asset.dart';
import 'release_manifest.dart';
import 'resolve.dart';
import 'source_tree.dart';
import 'stage.dart';
import 'stage_store.dart';
import 'producers.dart';
import 'stage_contract.dart';
import 'stage_completion.dart';
import 'stage_inspection.dart';
import 'stage_plan.dart';
import 'stage_receipt.dart';
import 'stage_source.dart';
import 'git.dart';
import 'timings.dart';

String _newRunId() {
  final random = Random.secure();
  return List.generate(
    4,
    (_) => random.nextInt(0x40000000).toRadixString(16).padLeft(8, '0'),
  ).join();
}

/// One shared, cached stage resolver for status and release composition.
class ReleaseStages {
  ReleaseStages({
    required this.source,
    required this.git,
    required this.stageContracts,
    String? repositoryRoot,
    DartSdk Function()? sdk,
  }) : repositoryRoot = repositoryRoot ?? git.root,
       _sdk = sdk ?? DartSdk.ambient;

  final SourceTree source;
  final GitState git;
  final String repositoryRoot;
  final StageContractResolver stageContracts;
  final DartSdk Function() _sdk;
  final Map<String, ReleaseStage> _stages = {};
  final String _unboundRunId = _newRunId();

  ReleaseStage call(ResolvedUnit unit) =>
      _stages.putIfAbsent(unit.name, () => _resolve(unit, git));

  ReleaseStage _resolve(ResolvedUnit unit, GitState currentGit) {
    final plan = stagePlanFor(unit, currentGit);
    final identity = currentGit.isBound
        ? StageIdentity.forPlan(
            headCommit: currentGit.head,
            headTree: currentGit.headTree,
            resolvedPlan: plan,
          )
        : StageIdentity.forUnboundPlan(
            runId: _unboundRunId,
            resolvedPlan: plan,
          );
    return ReleaseStage(
      unit: unit,
      source: source,
      sdk: _sdk,
      repository: currentGit.originUrl,
      enforceUnitContract: true,
      directory: StageDirectory(
        repositoryRoot: repositoryRoot,
        identity: identity,
      ),
      resolvedPlan: plan,
      targetContributions: stageContracts(
        unit: unit,
        repository: currentGit.originUrl,
      ),
    );
  }
}

/// One resolved unit's immutable local release stage.
///
/// Every producer output lives beneath the content-addressed directory; the
/// source it was built from is named by the stage identity, not copied into
/// it. Only a complete, inspected receipt makes those files reusable;
/// directory contents by themselves carry no authority.
class ReleaseStage {
  ReleaseStage({
    required this.unit,
    required this.source,
    required this.directory,
    DartSdk Function()? sdk,
    this.repository,
    this.enforceUnitContract = false,
    Map<String, Object?>? resolvedPlan,
    Iterable<StageContributionContract> targetContributions = const [],
  }) : _readSdk = sdk ?? DartSdk.ambient,
       resolvedPlan = resolvedPlan == null
           ? null
           : CanonicalJson.normalize(resolvedPlan) as Map<String, Object?>,
       targetContributions = List<StageContributionContract>.unmodifiable(
         targetContributions,
       );

  final ResolvedUnit unit;
  final SourceTree source;
  final StageDirectory directory;
  final String? repository;

  /// The Dart SDK producers build with, read the first time one asks.
  DartSdk get sdk => _sdk ??= _readSdk();
  final DartSdk Function() _readSdk;
  DartSdk? _sdk;

  /// What the stage is built from beyond its commit, recorded in the
  /// receipt so a person can read it.
  final Map<String, Object?>? resolvedPlan;
  final List<StageContributionContract> targetContributions;

  /// Direct construction is used by low-level receipt tests whose
  /// deliberately partial producer graphs are not a release plan. Every
  /// production resolver sets this, so status and release always check a
  /// receipt against the producers this rk runs for the unit.
  final bool enforceUnitContract;

  /// The one receipt contract for this stage, shared by the receipt writer
  /// and the inspector so canonical order and validation cannot drift.
  /// Null exactly when [enforceUnitContract] is off: a deliberately partial
  /// graph has no unit contract to order by or validate against.
  late final StageReceiptContract? _unitContract = _resolveContract();

  StageReceiptContract? _resolveContract() {
    if (!enforceUnitContract) return null;
    return StageReceiptContract.forUnit(
      unit: unit,
      repository: repository,
      targetContributions: targetContributions,
      localProducers: localProducerContracts(unit),
    );
  }

  /// Canonical stage producer IDs and their resolved dependency edges.
  ///
  /// Production stages always enforce a unit contract. Keeping this access on
  /// the stage prevents the coordinator from rebuilding artifact ownership or
  /// target-contribution dependencies a second time.
  List<String> get producerNames => _unitContract?.producerNames ?? const [];

  Set<String> producerDependencies(String producer) =>
      _unitContract?.dependenciesOf(producer) ??
      (throw StateError('this partial stage has no producer graph'));

  StageStepContract producerContract(String producer) =>
      _unitContract?.producerContract(producer) ??
      (throw StateError('this partial stage has no producer contract'));

  /// The recorded output of [producer] at [path], for a later producer in
  /// the same stage. Only recorded steps are trusted.
  StageArtifact requireProducerArtifact({
    required String producer,
    required String path,
    required String type,
  }) {
    if (!enforceUnitContract ||
        producerContract(producer).outputs[path] != type) {
      throw StateError(
        'dependency artifact does not match the producer contract',
      );
    }
    final inspected = inspect();
    if (!inspected.reusable && !inspected.validProgress) {
      throw StateError(
        'the stage does not validate: ${inspected.issues.join('; ')}',
      );
    }
    return inspected.receipt!.steps
        .singleWhere((step) => step.name == producer)
        .outputs
        .singleWhere(
          (artifact) => artifact.path == path && artifact.type == type,
        );
  }

  /// What this stage is: its receipt, checked against the files it records
  /// and against the producers this rk runs for the unit.
  StageInspection inspect() =>
      Timings.spanSync('inspect stage ${unit.name}', () {
        final inspected = const StageInspector().inspect(directory);
        final receipt = inspected.receipt;
        final contract = _unitContract;
        if (receipt == null || contract == null) return inspected;
        final mismatched = contract.validateDeclarations(receipt);
        return mismatched.isEmpty
            ? inspected
            : StageInspection(
                receipt: receipt,
                issues: [...inspected.issues, ...mismatched],
              );
      });

  /// Removes only this already-resolved content-addressed stage.
  ///
  /// Used before producing a replacement for an absent/incomplete stage. A
  /// complete invalid receipt is handled by release policy before this call,
  /// so publication never silently replaces an explicitly reviewed stage.
  void reset() {
    final type = FileSystemEntity.typeSync(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory ||
        directory.unsafeFixedPath() != null) {
      throw FileSystemException('unsafe stage cannot be reset', directory.path);
    }
    final removed = StageStore(
      directory.repositoryRoot,
    ).deleteEntry(StageEntry(name: directory.identity.id, type: type));
    if (!removed) {
      throw FileSystemException(
        'stage changed before it could be reset',
        directory.path,
      );
    }
  }

  /// Removes this unit's earlier stages of a source with no commit. Each such
  /// run starts a stage no later run can reuse, so the one before it is
  /// garbage once this one begins.
  void discardEarlierUnboundStages() {
    if (directory.identity.isGitBound) return;
    final store = StageStore(directory.repositoryRoot);
    for (final entry in store.inventory()) {
      if (entry.name == directory.identity.id ||
          entry.type != FileSystemEntityType.directory) {
        continue;
      }
      try {
        final receipt = StageReceipt.parse(
          File(store.receiptPath(entry.name)!).readAsStringSync(),
        );
        final planned = receipt.plan?['unit'];
        if (receipt.identity.isGitBound ||
            planned is! Map ||
            planned['name'] != unit.name) {
          continue;
        }
        store.deleteEntry(entry);
      } on Object {
        // Not a stage rk can read as this unit's; rk clean shows it.
      }
    }
  }

  /// Removes declared producer outputs that were written but never recorded,
  /// so the producer can run again. It never adopts bytes and never follows
  /// a symlink.
  void discardUnrecordedOutputs(Iterable<String> declaredOutputs) {
    if (directory.unsafeFixedPath() != null) {
      throw FileSystemException(
        'unsafe stage cannot discard interrupted outputs',
        directory.path,
      );
    }
    final receipt = StageReceiptStore(directory).read();
    if (receipt == null || receipt.complete) {
      throw StateError(
        'only an incomplete receipted stage can discard interrupted outputs',
      );
    }
    final recorded = {for (final artifact in receipt.artifacts) artifact.path};
    final candidates = declaredOutputs.toSet().difference(recorded).toList()
      ..sort();
    for (final relativePath in candidates) {
      final parts = StagePath.segments(relativePath);
      var current = directory.path;
      var missing = false;
      for (final part in parts.take(parts.length - 1)) {
        current = '$current${Platform.pathSeparator}$part';
        final type = FileSystemEntity.typeSync(current, followLinks: false);
        if (type == FileSystemEntityType.notFound) {
          missing = true;
          break;
        }
        if (type != FileSystemEntityType.directory) {
          throw FileSystemException(
            'interrupted output path has an unsafe parent',
            current,
          );
        }
      }
      if (missing) continue;

      final path = directory.resolve(relativePath);
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      switch (type) {
        case FileSystemEntityType.notFound:
          continue;
        case FileSystemEntityType.file:
          File(path).deleteSync();
          break;
        case FileSystemEntityType.link:
          Link(path).deleteSync();
          break;
        case FileSystemEntityType.directory:
        case FileSystemEntityType.pipe:
        case FileSystemEntityType.unixDomainSock:
          throw FileSystemException(
            'interrupted output is not a regular file',
            path,
          );
      }

      // Remove the producer's directories it left empty, stopping at the
      // stage root and at anything another lane owns.
      for (var index = parts.length - 1; index > 0; index--) {
        final parent = directory.resolve(parts.take(index).join('/'));
        final parentType = FileSystemEntity.typeSync(
          parent,
          followLinks: false,
        );
        if (parentType != FileSystemEntityType.directory) break;
        if (Directory(parent).listSync(followLinks: false).isNotEmpty) break;
        Directory(parent).deleteSync();
      }
    }
  }

  /// The source this stage is built from, read once into memory: the
  /// committed bytes for a Git-bound stage. Producers export it into
  /// directories of their own, never the mutable worktree.
  Future<StageSourceSnapshot> captureSource() => StageSourceSnapshot.capture(
    source,
    commit: directory.identity.headCommit,
  );

  /// Writes the release manifest and completes the receipt.
  ///
  /// The manifest does not list itself, avoiding a self-digest cycle; the
  /// receipt records it like every other staged file.
  StageReceipt finalize({
    required Iterable<ReleaseAssetSpec> releaseAssets,
    Map<String, Object?> evidence = const {},
  }) {
    final specs = validateReleaseAssetSpecs(releaseAssets).toList();
    final stagedPaths = specs.map((asset) => asset.stagedPath).toSet();
    if (specs.map((asset) => asset.publicName).toSet().length != specs.length ||
        stagedPaths.length != specs.length) {
      throw ArgumentError(
        'release assets must name unique public files and blobs',
      );
    }
    final homebrew = _homebrewBinding();
    if (homebrew != null && stagedPaths.contains(homebrew.stagedPath)) {
      throw ArgumentError(
        'Homebrew formulae cannot also be release assets: '
        '${homebrew.stagedPath}',
      );
    }
    final inspected = inspect();
    final progress = inspected.receipt;
    if (inspected.reusable) return progress!;
    if (progress == null ||
        !(inspected.validProgress || inspected.planRecorded)) {
      throw StateError(
        'the in-progress stage does not validate: '
        '${inspected.issues.join('; ')}',
      );
    }

    // A crash between the manifest write and the receipt rename can leave a
    // manifest the receipt never recorded; it is derived again.
    final oldManifest = File(directory.resolve('release-manifest.json'));
    if (oldManifest.existsSync()) oldManifest.deleteSync();

    final byPath = {
      for (final artifact in progress.artifacts) artifact.path: artifact,
    };
    final missing = {
      ...stagedPaths,
      if (homebrew != null) homebrew.stagedPath,
    }.difference(byPath.keys.toSet());
    if (missing.isNotEmpty) {
      throw StateError(
        'stage is missing publication artifacts: ${missing.join(', ')}',
      );
    }
    final completion = StageCompletion(
      unit: unit,
      repository: repository,
      commit: directory.identity.headCommit,
      artifacts: byPath.values,
      releaseAssets: specs,
    );
    completion.manifest.writeTo(directory);
    final receipt = StageReceipt(
      identity: directory.identity,
      plan: resolvedPlan,
      steps: [
        ...progress.steps,
        StageStep(
          name: 'complete-stage',
          outputs: [
            StageArtifact.capture(
              stage: directory,
              path: 'release-manifest.json',
              type: 'manifest',
            ),
          ],
          evidence: {
            ...evidence,
            ...completion.evidence,
            if (_sdk != null) 'dart_sdk': _sdk!.toJson(),
          },
        ),
      ],
    );
    StageReceiptStore(directory).write(receipt);
    return receipt;
  }

  StageReceipt requireReceipt() {
    final inspected = inspect();
    if (!inspected.reusable || inspected.receipt == null) {
      throw StateError('the release stage is not complete');
    }
    return inspected.receipt!;
  }

  /// Exact public-name to private-blob mapping frozen by complete-stage.
  Map<String, StageArtifact> releaseAssets() {
    final receipt = requireReceipt();
    final complete = receipt.steps.last;
    final encoded = complete.evidence['release_assets'];
    final byPath = {
      for (final artifact in receipt.artifacts) artifact.path: artifact,
    };
    if (encoded is! Map) {
      throw StateError('complete stage has no release asset bindings');
    }
    return Map.unmodifiable({
      for (final entry in encoded.entries)
        if (entry.key is String &&
            entry.value is String &&
            byPath[entry.value] != null)
          entry.key as String: byPath[entry.value]!,
    });
  }

  /// Atomically records producer progress without completing the stage;
  /// only [finalize] completes it.
  ///
  /// Concurrent platform lanes complete in scheduling order; steps are
  /// written in contract order so the receipt reads the same however the
  /// work interleaved.
  void writeProgress(Iterable<StageStep> steps) {
    if (enforceUnitContract && resolvedPlan == null) {
      throw StateError('production receipts require their frozen release plan');
    }
    if (steps.any((step) => step.name == 'complete-stage')) {
      throw StateError('only finalize may complete a stage');
    }
    // Concurrent lanes complete in scheduling order; the record is
    // canonical. A stage without a unit contract — a deliberately partial
    // graph — keeps its given order, which is its own causal truth.
    final contract = _unitContract;
    final ordered = contract == null
        ? List<StageStep>.of(steps)
        : _contractOrdered(steps, contract.producerNames);
    StageReceiptStore(directory).write(
      StageReceipt(
        identity: directory.identity,
        plan: resolvedPlan,
        steps: ordered,
      ),
    );
  }

  /// Steps in contract order; names outside the contract keep their given
  /// order, after the known ones. Stable via the given index.
  static List<StageStep> _contractOrdered(
    Iterable<StageStep> steps,
    List<String> canonical,
  ) {
    final order = {for (final (index, name) in canonical.indexed) name: index};
    final decorated = steps.indexed.toList()
      ..sort((left, right) {
        final byContract = (order[left.$2.name] ?? order.length).compareTo(
          order[right.$2.name] ?? order.length,
        );
        return byContract != 0 ? byContract : left.$1.compareTo(right.$1);
      });
    return [for (final (_, step) in decorated) step];
  }

  StagedHomebrewBinding? _homebrewBinding() {
    return StageCompletion.homebrewFor(unit, repository);
  }
}
