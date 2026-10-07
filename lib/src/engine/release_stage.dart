import 'dart:io';
import 'dart:math';

import '../builds/launcher_compiler.dart';
import '../transforms/digest.dart';
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
    DartCompilerIdentity Function()? compilerIdentity,
    RkImplementationIdentity Function()? rkIdentity,
    Map<String, String> Function()? environment,
  }) : repositoryRoot = repositoryRoot ?? git.root,
       _compilerIdentity = compilerIdentity ?? DartCompilerIdentity.readAmbient,
       _rkIdentity = rkIdentity ?? RkImplementationIdentity.readAmbient,
       _environment =
           environment ?? (() => Map<String, String>.of(Platform.environment));

  final SourceTree source;
  final GitState git;
  final String repositoryRoot;
  final StageContractResolver stageContracts;
  final DartCompilerIdentity Function() _compilerIdentity;
  final RkImplementationIdentity Function() _rkIdentity;
  final Map<String, String> Function() _environment;
  final Map<String, ReleaseStage> _stages = {};
  final String _unboundRunId = _newRunId();
  DartCompilerIdentity? _compiler;

  ReleaseStage call(ResolvedUnit unit) => _stages.putIfAbsent(
    unit.name,
    () => _resolve(
      unit,
      git,
      _compiler ??= _readCompilerIdentity(),
      _readRkIdentity(),
    ),
  );

  /// Resolves the stage again from facts read at the release boundary.
  ///
  /// Unlike [call], this deliberately does not reuse the compiler reading or
  /// the initial Git state. Publication must notice a PATH-selected compiler,
  /// signing policy, origin, commit, tree, platform, or plan change that
  /// happened while private preparation or authorization was in progress.
  ReleaseStage refresh(ResolvedUnit unit, GitState currentGit) =>
      _resolve(unit, currentGit, _readCompilerIdentity(), _readRkIdentity());

  ReleaseStage _resolve(
    ResolvedUnit unit,
    GitState currentGit,
    DartCompilerIdentity compiler,
    RkImplementationIdentity rk,
  ) {
    final launcher =
        Platform.isMacOS &&
            unit.projects.any(
              (project) => project.binaryPlatforms.any(
                (platform) => platform.startsWith('macos-'),
              ),
            )
        ? LauncherCompiler.read()
        : null;
    final plan = stagePlanFor(
      unit,
      currentGit,
      launcherCompiler: launcher?.identity,
      compiler: compiler,
      rk: rk,
      environment: _environment(),
    );
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
    final directory = StageDirectory(
      repositoryRoot: repositoryRoot,
      identity: identity,
    );
    return ReleaseStage(
      unit: unit,
      source: source,
      compiler: compiler,
      launcherCompiler: launcher,
      repository: currentGit.originUrl,
      enforceUnitContract: true,
      directory: directory,
      resolvedPlan: plan,
      targetContributions: stageContracts(
        unit: unit,
        repository: currentGit.originUrl,
        sourceRoot: directory.resolve('source'),
      ),
    );
  }

  DartCompilerIdentity _readCompilerIdentity() {
    try {
      return _compilerIdentity();
    } on DartCompilerUnavailable {
      rethrow;
    } on Object catch (error) {
      throw DartCompilerUnavailable('$error');
    }
  }

  RkImplementationIdentity _readRkIdentity() {
    try {
      return _rkIdentity();
    } on Object catch (error) {
      throw StateError(
        'the rk implementation could not be identified: '
        '$error',
      );
    }
  }
}

/// One resolved unit's immutable local release stage.
///
/// The source snapshot and every producer output live beneath the
/// content-addressed directory. Only a complete, re-inspected receipt makes
/// those files reusable; directory contents by themselves carry no authority.
class ReleaseStage {
  ReleaseStage({
    required this.unit,
    required this.source,
    required this.directory,
    this.compiler,
    this.launcherCompiler,
    this.repository,
    this.enforceUnitContract = false,
    Map<String, Object?>? resolvedPlan,
    Iterable<StageContributionContract> targetContributions = const [],
  }) : resolvedPlan = resolvedPlan == null
           ? null
           : CanonicalJson.normalize(resolvedPlan) as Map<String, Object?>,
       targetContributions = List<StageContributionContract>.unmodifiable(
         targetContributions,
       );

  final ResolvedUnit unit;
  final SourceTree source;
  final StageDirectory directory;
  final DartCompilerIdentity? compiler;
  final LauncherCompiler? launcherCompiler;
  final String? repository;

  /// Recorded before production for restoration and rebuild explanations.
  /// Its digest alone cannot authorize reuse of source or provider artifacts.
  final Map<String, Object?>? resolvedPlan;
  final List<StageContributionContract> targetContributions;

  /// Direct construction is used by low-level receipt/atomicity tests whose
  /// deliberately partial producer graphs are not a release plan. Every
  /// production resolver sets this, so status and release always enforce the
  /// resolved unit's complete semantic receipt contract.
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
      sourceRoot: sourceRoot,
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

  /// Bind every declared input, including same-unit archive edges, to a
  /// completed producer's receipt. This does not require unit completion.
  List<StageInput> producerInputs(String producer, Iterable<StageStep> prior) {
    final steps = {for (final step in prior) 'step:${step.name}': step};
    final artifacts = {
      for (final step in prior)
        for (final artifact in step.outputs) artifact.path: artifact,
    };
    return [
      for (final input in producerContract(producer).inputs)
        if (steps[input] case final step?)
          StageInput.step(step)
        else if (artifacts[input] case final artifact?)
          StageInput.artifact(artifact)
        else
          throw StateError('$producer input $input is not recorded'),
    ];
  }

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
    return requireProducerProgress().steps
        .singleWhere((step) => step.name == producer)
        .outputs
        .singleWhere(
          (artifact) => artifact.path == path && artifact.type == type,
        );
  }

  /// Validated completed producer inputs during an active preparation run.
  /// Another producer may already be writing its declared output. Such bytes
  /// are neither adopted nor returned here: only recorded steps are trusted.
  /// Persisted inspection and public completion keep their strict inventory.
  StageReceipt requireProducerProgress() {
    if (!enforceUnitContract) {
      throw StateError('producer input reads require a complete unit contract');
    }
    final inspected = inspect();
    final receipt = inspected.receipt;
    if (inspected.reusable || inspected.validProgress) return receipt!;
    final pendingFiles = <String>{};
    if (receipt != null && !receipt.complete) {
      final recorded = receipt.steps.map((step) => step.name).toSet();
      for (final name in producerNames.where(
        (name) => !recorded.contains(name),
      )) {
        pendingFiles.addAll(producerContract(name).outputs.keys);
      }
    }
    final pendingDirectories = <String>{};
    for (final path in pendingFiles) {
      final parts = StagePath.segments(path);
      for (var i = 1; i < parts.length; i++) {
        pendingDirectories.add(parts.take(i).join('/'));
      }
    }
    final remaining = inspected.issues.where((issue) {
      if (issue.kind != StageIssueKind.extraArtifact || issue.path == null) {
        return true;
      }
      final type = FileSystemEntity.typeSync(
        directory.resolve(issue.path!),
        followLinks: false,
      );
      return !((type == FileSystemEntityType.file &&
              pendingFiles.contains(issue.path)) ||
          (type == FileSystemEntityType.directory &&
              pendingDirectories.contains(issue.path)));
    });
    if (!StageInspection(receipt: receipt, issues: remaining).validProgress) {
      throw StateError(
        'dependency provider stage does not validate: ${remaining.join('; ')}',
      );
    }
    return receipt!;
  }

  String get sourceRoot => directory.resolve('source');

  /// What this stage is, verified.
  ///
  /// The answer is a pure function of the bytes under the stage directory,
  /// so it is remembered against a fingerprint of that directory: a run
  /// asks this question dozens of times, and re-reading and re-hashing tens
  /// of megabytes to answer it again is the largest cost in a release that
  /// changed nothing.
  ///
  /// This is a memo, not a promise that the stage is unchanged. Every call
  /// still re-reads the directory; only hashing is skipped, and only while
  /// every path, size, mode, and timestamp is exactly as it was. Anything
  /// that writes to the stage — rk's own producers included — moves a
  /// timestamp, so the next call verifies from disk again. What a stale
  /// answer would require is a rewrite that restores size, mode, and both
  /// timestamps, which a writer cannot do to change time: the kernel sets
  /// it. Concurrent writers are excluded separately, by the stage lock.
  StageInspection inspect() {
    final now = directory.fingerprint();
    final remembered = _inspected;
    if (remembered != null && _inspectedAt == now) {
      Timings.tally('release stage inspection remembered');
      return remembered;
    }
    // The span covers the reading, not the asking, so a trace counts the
    // stages that were read rather than every time one was asked about.
    final fresh = Timings.spanSync(
      'inspect stage ${unit.name}',
      () => _inspectFromDisk(now),
    );
    _inspected = fresh;
    _inspectedAt = now;
    return fresh;
  }

  StageInspection? _inspected;
  String? _inspectedAt;

  StageInspection _inspectFromDisk(String fingerprint) {
    final inspected = const StageInspector().inspect(
      directory,
      fingerprint: fingerprint,
    );
    final receipt = inspected.receipt;
    final issues = [...inspected.issues];
    if (receipt != null &&
        enforceUnitContract &&
        (receipt.plan == null ||
            CanonicalJson.encode(receipt.plan) !=
                CanonicalJson.encode(resolvedPlan))) {
      issues.add(
        const StageIssue(
          StageIssueKind.wrongStage,
          'the receipt does not record this resolved release plan',
          path: 'stage.json',
        ),
      );
    }
    if (receipt?.complete == true &&
        !issues.any(
          (issue) =>
              issue.kind == StageIssueKind.invalidManifest ||
              issue.path == 'release-manifest.json',
        )) {
      try {
        final manifest = ReleaseManifest.parse(
          File(directory.resolve('release-manifest.json')).readAsStringSync(),
        );
        final wantedHomebrew = _homebrewBinding()?.identity;
        final manifestHomebrew = manifest.homebrew?.identity;
        if (manifest.unit != unit.name ||
            manifest.version != unit.version.canonical ||
            manifest.tag != unit.tag ||
            manifestHomebrew != wantedHomebrew) {
          issues.add(
            const StageIssue(
              StageIssueKind.invalidManifest,
              'release manifest names different release coordinates or '
              'Homebrew formulae',
              path: 'release-manifest.json',
            ),
          );
        }
      } on Object catch (error) {
        issues.add(
          StageIssue(
            StageIssueKind.invalidManifest,
            'release manifest Homebrew binding could not be validated: $error',
            path: 'release-manifest.json',
          ),
        );
      }
    }
    if (receipt != null && _unitContract != null) {
      issues.addAll(_unitContract.validate(directory, receipt));
      issues.addAll(
        StageCompletion.validate(
          receipt,
          unit: unit,
          repository: repository,
          compiler: compiler,
        ),
      );
    }
    final expectedCompiler = compiler;
    if (expectedCompiler == null || receipt?.complete != true) {
      return StageInspection(receipt: receipt, issues: issues);
    }

    final recorded = receipt!.steps.last.evidence['dart_compiler'];
    try {
      final actual = DartCompilerIdentity.fromJson(recorded);
      if (actual != expectedCompiler) {
        issues.add(
          const StageIssue(
            StageIssueKind.wrongStage,
            'the completed stage records a different Dart compiler',
            path: 'stage.json',
          ),
        );
      }
    } on Object {
      issues.add(
        const StageIssue(
          StageIssueKind.invalidStructure,
          'the completed stage does not record its Dart compiler',
          path: 'stage.json',
        ),
      );
    }
    return StageInspection(receipt: receipt, issues: issues);
  }

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

  /// Retains the frozen header across interrupted source-copy recovery. Only
  /// unrecorded source residue may be discarded; never delete stage.json.
  void discardUnrecordedSource() {
    final inspected = inspect();
    final receipt = inspected.receipt;
    if (!inspected.canRestartSource ||
        receipt!.identity.id != directory.identity.id) {
      throw StateError('source retry requires an intact frozen plan header');
    }
    final type = FileSystemEntity.typeSync(sourceRoot, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'source residue is not a directory',
        sourceRoot,
      );
    }
    Directory(sourceRoot).deleteSync(recursive: true);
  }

  /// Removes declared producer outputs that were written but never receipted.
  ///
  /// A producer writes bytes before rk can hash and record them. If that
  /// producer fails, those exact paths are untrusted leftovers, not progress;
  /// retaining them makes the otherwise-valid receipt prefix look corrupt and
  /// forces unrelated completed lanes to run again. Recovery may delete only
  /// output paths from the resolved stage contract and only while an
  /// incomplete receipt proves they were never recorded. It never adopts
  /// bytes and never traverses a symlink.
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

      // Producer-owned directories are not artifacts. Remove empty ones so
      // the strict inventory sees the same tree the receipt describes, but
      // stop at the stage root and retain anything another lane owns.
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

  /// Copies the Git-tracked source into the stage and returns the captured
  /// records. Producers use [sourceRoot], never the mutable worktree.
  Future<List<StageArtifact>> materializeSource() async {
    final snapshot = await StageSourceSnapshot.capture(
      source,
      commit: directory.identity.headCommit,
    );
    // Source inventories usually dominate receipt size. Refuse an oversized
    // inventory before copying any files or running producers, preserving the
    // intact frozen header for a clear diagnostic on retry.
    StageReceipt(
      identity: directory.identity,
      plan: resolvedPlan,
      steps: [StageStep.sourceSnapshot(directory.identity, snapshot.artifacts)],
    ).encodeForStorage();
    return snapshot.materialize(directory);
  }

  /// Returns why mutable, unbound source no longer matches its captured
  /// snapshot. Git-bound stages use their commit/tree identity instead.
  String? unboundSourceProblem() {
    if (directory.identity.isGitBound) return null;
    final receipt = StageReceiptStore(directory).read();
    if (receipt == null || receipt.steps.isEmpty) {
      return 'the stage has no source snapshot receipt';
    }
    final step = receipt.steps.first;
    if (step.name != 'source-snapshot') {
      return 'the stage has no source snapshot step';
    }
    final expected = <String, StageArtifact>{
      for (final artifact in step.outputs)
        if (artifact.path.startsWith('source/'))
          artifact.path.substring('source/'.length): artifact,
    };
    final current = source.trackedFiles().toSet();
    final captured = expected.keys.toSet();
    final added = current.difference(captured).toList()..sort();
    final removed = captured.difference(current).toList()..sort();
    if (added.isNotEmpty || removed.isNotEmpty) {
      return [
        if (added.isNotEmpty) 'added: ${added.join(', ')}',
        if (removed.isNotEmpty) 'removed: ${removed.join(', ')}',
      ].join('; ');
    }
    for (final path in current.toList()..sort()) {
      final bytes = source.readBytes(path);
      if (bytes == null) return '$path disappeared';
      if (bytes.length != expected[path]!.size ||
          Sha256.hex(bytes) != expected[path]!.sha256) {
        return '$path changed';
      }
    }
    return null;
  }

  /// Revalidates the immutable source snapshot and removes only untracked
  /// producer scratch beneath it (for example `.dart_tool`).
  ///
  /// A changed or missing tracked file is refused, never restored: producer
  /// output must not be able to alter the bytes the stage identity names.
  void sealSource(Iterable<StageArtifact> expected) {
    final byPath = {for (final artifact in expected) artifact.path: artifact};
    final source = Directory(sourceRoot);
    if (!source.existsSync()) {
      throw StateError('the staged source snapshot disappeared');
    }
    final extras = <FileSystemEntity>[];
    final entities = source.listSync(recursive: true, followLinks: false)
      ..sort((left, right) => right.path.length.compareTo(left.path.length));
    for (final entity in entities) {
      final relative = entity.path
          .substring(directory.path.length + 1)
          .split(Platform.pathSeparator)
          .join('/');
      final wanted = byPath[relative];
      if (wanted == null) {
        extras.add(entity);
        continue;
      }
      if (entity is! File) {
        throw StateError('staged source changed type: $relative');
      }
      // The snapshot is sealed after every producer, so most of these files
      // were digested moments ago and have not moved since.
      final actual = StageArtifact.confirm(wanted, stage: directory);
      if (actual.mode != wanted.mode ||
          actual.size != wanted.size ||
          actual.sha256 != wanted.sha256) {
        throw StateError('a producer changed staged source: $relative');
      }
    }
    for (final path in byPath.keys) {
      if (!File(directory.resolve(path)).existsSync()) {
        throw StateError('a producer removed staged source: $path');
      }
    }
    for (final entity in extras) {
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      if (type == FileSystemEntityType.directory) {
        final directory = Directory(entity.path);
        if (directory.listSync(followLinks: false).isEmpty) {
          directory.deleteSync();
        }
      } else {
        entity.deleteSync();
      }
    }
  }

  /// Finalizes the public manifest and the strict local receipt.
  ///
  /// The manifest deliberately does not list itself, avoiding a self-digest
  /// cycle; the local receipt does capture it like every other staged file.
  StageReceipt finalize({
    required Iterable<ReleaseAssetSpec> releaseAssets,
    Map<String, Object?> evidence = const {},
  }) {
    final bindings = [
      for (final asset in validateReleaseAssetSpecs(releaseAssets))
        _PublicArtifactBinding(
          publicName: asset.publicName,
          stagedPath: asset.stagedPath,
        ),
    ];
    final publicNames = bindings.map((binding) => binding.publicName).toSet();
    final stagedPaths = bindings.map((binding) => binding.stagedPath).toSet();
    if (publicNames.length != bindings.length ||
        stagedPaths.length != bindings.length) {
      throw ArgumentError(
        'release assets must name unique public files and blobs',
      );
    }
    final homebrewBinding = _homebrewBinding();
    final homebrewStagedPaths = {
      if (homebrewBinding != null) homebrewBinding.stagedPath,
    };
    final duplicatedHomebrew = stagedPaths.intersection(homebrewStagedPaths);
    if (duplicatedHomebrew.isNotEmpty) {
      throw ArgumentError(
        'Homebrew formulae cannot also be release assets: '
        '${duplicatedHomebrew.join(', ')}',
      );
    }
    StageReceipt? progress;
    try {
      progress = StageReceiptStore(directory).read();
    } on Object catch (error) {
      throw StateError('the in-progress stage receipt is invalid: $error');
    }
    if (progress?.complete == true) {
      final inspected = inspect();
      if (!inspected.reusable) {
        throw StateError(
          'the completed stage is invalid and cannot be replaced',
        );
      }
      final existingManifest = ReleaseManifest.parse(
        File(directory.resolve('release-manifest.json')).readAsStringSync(),
      );
      final existingPublic = existingManifest.artifacts
          .map((artifact) => artifact.name)
          .toSet();
      final existingHomebrew = existingManifest.homebrew?.identity;
      final wantedHomebrew = homebrewBinding?.identity;
      if (existingPublic.length != publicNames.length ||
          existingPublic.difference(publicNames).isNotEmpty ||
          existingHomebrew != wantedHomebrew) {
        throw StateError(
          'the completed stage has a different publication inventory',
        );
      }
      return progress!;
    }
    if (progress == null) {
      throw StateError(
        'stage has no producer receipt; files cannot vouch for themselves',
      );
    }
    if (progress.identity.id != directory.identity.id) {
      throw StateError('the in-progress receipt belongs to another stage');
    }

    // A crash between the manifest write and the complete receipt rename can
    // leave only this deterministic, reserved output. It was never trusted;
    // remove and derive it again from the validated producer receipt.
    final oldManifest = File(directory.resolve('release-manifest.json'));
    if (oldManifest.existsSync() &&
        !progress.artifacts.any(
          (artifact) => artifact.path == 'release-manifest.json',
        )) {
      oldManifest.deleteSync();
    }

    final inspectedProgress = inspect();
    if (!inspectedProgress.validProgress) {
      throw StateError(
        'the in-progress stage does not validate: '
        '${inspectedProgress.issues.join('; ')}',
      );
    }

    final beforeManifest = _captureAll();
    final byPath = {
      for (final artifact in beforeManifest) artifact.path: artifact,
    };
    final boundStagedPaths = {...stagedPaths, ...homebrewStagedPaths};
    final missing = boundStagedPaths.difference(byPath.keys.toSet());
    if (missing.isNotEmpty) {
      throw StateError(
        'stage is missing publication artifacts: ${missing.join(', ')}',
      );
    }

    final allowed = <String>{
      for (final path in byPath.keys)
        if (path.startsWith('source/')) path,
      ...boundStagedPaths,
      ...progress.artifacts.map((artifact) => artifact.path),
    };
    final planted = byPath.keys.toSet().difference(allowed);
    if (planted.isNotEmpty) {
      throw StateError(
        'stage contains files no producer recorded: ${planted.join(', ')}',
      );
    }

    final completion = StageCompletion(
      unit: unit,
      repository: repository,
      commit: directory.identity.headCommit,
      artifacts: byPath.values,
      releaseAssets: releaseAssets,
    );
    completion.manifest.writeTo(directory);

    final recorded = progress.artifacts
        .map((artifact) => artifact.path)
        .toSet();
    final unrecorded = byPath.keys.toSet().difference(recorded);
    if (unrecorded.isNotEmpty) {
      throw StateError(
        'stage contains outputs no producer recorded: '
        '${unrecorded.join(', ')}',
      );
    }

    final manifestArtifact = StageArtifact.capture(
      stage: directory,
      path: 'release-manifest.json',
      type: 'manifest',
    );
    final receipt = StageReceipt(
      identity: directory.identity,
      plan: resolvedPlan,
      steps: [
        ...progress.steps,
        StageStep(
          name: 'complete-stage',
          inputs: completion.inputs,
          outputs: [manifestArtifact],
          evidence: {
            ...evidence,
            ...completion.evidence,
            if (compiler != null) 'dart_compiler': compiler!.toJson(),
          },
        ),
      ],
    );
    StageReceiptStore(directory).write(receipt);
    final inspected = inspect();
    if (!inspected.reusable) {
      throw StateError(
        'completed stage did not validate: ${inspected.issues.join('; ')}',
      );
    }
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

  /// Atomically records producer progress without making it reusable.
  ///
  /// A crash can preserve useful evidence, but only [finalize] may flip the
  /// receipt to complete. Outputs must already have been captured explicitly;
  /// an inventory scan never adopts an unrelated file.
  ///
  /// Concurrent platform lanes complete in scheduling order; the record is
  /// canonical. Steps are written in contract order so the receipt reads
  /// the same however the work interleaved.
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

  List<StageArtifact> _captureAll() {
    if (!Directory(directory.path).existsSync()) return const [];
    final artifacts = <StageArtifact>[];
    final entities = Directory(directory.path).listSync(
      recursive: true,
      followLinks: false,
    )..sort((left, right) => left.path.compareTo(right.path));
    for (final entity in entities) {
      if (entity is! File) continue;
      final relative = entity.path
          .substring(directory.path.length + 1)
          .split(Platform.pathSeparator)
          .join('/');
      if (relative == 'stage.json') continue;
      artifacts.add(
        StageArtifact.capture(
          stage: directory,
          path: relative,
          type: _typeOf(relative),
        ),
      );
    }
    return artifacts;
  }

  static String _typeOf(String path) {
    if (path.startsWith('source/')) return 'source';
    // What a project's own build wrote, whatever the files are called: a
    // declared asset may well end in .tar.gz or .zip.
    final parts = path.split('/');
    if (parts.length > 3 && parts[0] == 'producers' && parts[2] == 'assets') {
      return 'asset';
    }
    if (path == 'release-manifest.json') return 'manifest';
    if (path == 'release-notes.md') return 'notes';
    if (path.endsWith('.tar.gz')) return 'archive';
    if (path.endsWith('.rb')) return 'formula';
    if (path.endsWith('.notary-result.json') ||
        path.endsWith('.notary-log.json')) {
      return 'notary';
    }
    if (path.endsWith('.zip')) return 'notary-input';
    return 'executable';
  }

  StagedHomebrewBinding? _homebrewBinding() {
    return StageCompletion.homebrewFor(unit, repository);
  }
}

final class _PublicArtifactBinding {
  const _PublicArtifactBinding({
    required this.publicName,
    required this.stagedPath,
  });

  final String publicName;
  final String stagedPath;
}
