import 'dart:io';
import 'dart:math';

import '../transforms/digest.dart';
import 'release_asset.dart';
import 'assets.dart';
import 'publish_target.dart';
import 'release_manifest.dart';
import 'resolve.dart';
import 'source_tree.dart';
import 'stage.dart';
import 'producers.dart';
import 'stage_contract.dart';
import 'stage_inspection.dart';
import 'stage_plan.dart';
import 'stage_receipt.dart';
import 'git.dart';

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
  })  : repositoryRoot = repositoryRoot ?? git.root,
        _compilerIdentity =
            compilerIdentity ?? DartCompilerIdentity.readAmbient,
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
  ReleaseStage refresh(ResolvedUnit unit, GitState currentGit) => _resolve(
        unit,
        currentGit,
        _readCompilerIdentity(),
        _readRkIdentity(),
      );

  ReleaseStage _resolve(
    ResolvedUnit unit,
    GitState currentGit,
    DartCompilerIdentity compiler,
    RkImplementationIdentity rk,
  ) {
    final plan = stagePlanFor(
      unit,
      currentGit,
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
      repository: currentGit.originUrl,
      enforceUnitContract: true,
      directory: directory,
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
      throw StateError('the rk implementation could not be identified: '
          '$error');
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
    this.repository,
    this.enforceUnitContract = false,
    Iterable<StageContributionContract> targetContributions = const [],
  }) : targetContributions =
            List<StageContributionContract>.unmodifiable(targetContributions);

  final ResolvedUnit unit;
  final SourceTree source;
  final StageDirectory directory;
  final DartCompilerIdentity? compiler;
  final String? repository;
  final List<StageContributionContract> targetContributions;

  /// Direct construction is used by low-level receipt/atomicity tests whose
  /// deliberately partial producer graphs are not a release plan. Every
  /// production resolver sets this, so status and release always enforce the
  /// resolved unit's complete semantic receipt contract.
  final bool enforceUnitContract;

  String get sourceRoot => directory.resolve('source');

  StageInspection inspect() {
    final inspected = const StageInspector().inspect(directory);
    final receipt = inspected.receipt;
    final issues = [...inspected.issues];
    if (receipt?.complete == true &&
        !issues.any((issue) =>
            issue.kind == StageIssueKind.invalidManifest ||
            issue.path == 'release-manifest.json')) {
      try {
        final manifest = ReleaseManifest.parse(
          File(directory.resolve('release-manifest.json')).readAsStringSync(),
        );
        final wantedFormula = _formulaBinding()?.identity;
        final manifestFormula = manifest.formula?.identity;
        if (manifest.unit != unit.name ||
            manifest.version != unit.version.canonical ||
            manifest.tag != unit.tag ||
            manifestFormula != wantedFormula) {
          issues.add(const StageIssue(
            StageIssueKind.invalidManifest,
            'release manifest names different release coordinates or '
            'Homebrew formulas',
            path: 'release-manifest.json',
          ));
        }
      } on Object catch (error) {
        issues.add(StageIssue(
          StageIssueKind.invalidManifest,
          'release manifest formulas could not be validated: $error',
          path: 'release-manifest.json',
        ));
      }
    }
    if (receipt != null && enforceUnitContract) {
      issues.addAll(StageReceiptContract.forUnit(
        unit: unit,
        repository: repository,
        sourceRoot: sourceRoot,
        targetContributions: targetContributions,
        localProducers: localProducerContracts(unit),
      ).validate(directory, receipt));
    }
    final expectedCompiler = compiler;
    if (expectedCompiler == null || receipt?.complete != true) {
      return StageInspection(receipt: receipt, issues: issues);
    }

    final recorded = receipt!.steps.last.evidence['dart_compiler'];
    try {
      final actual = DartCompilerIdentity.fromJson(recorded);
      if (actual != expectedCompiler) {
        issues.add(const StageIssue(
          StageIssueKind.wrongStage,
          'the completed stage records a different Dart compiler',
          path: 'stage.json',
        ));
      }
    } on Object {
      issues.add(const StageIssue(
        StageIssueKind.invalidStructure,
        'the completed stage does not record its Dart compiler',
        path: 'stage.json',
      ));
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
    Directory(directory.path).deleteSync(recursive: true);
  }

  /// Copies the Git-tracked source into the stage and returns the captured
  /// records. Producers use [sourceRoot], never the mutable worktree.
  List<StageArtifact> materializeSource() {
    final outputs = <StageArtifact>[];
    final gitSource = source is GitSourceTree ? source as GitSourceTree : null;
    final gitEntries = gitSource?.trackedEntriesAt(
      directory.identity.headCommit!,
    );
    final byPath = gitEntries == null
        ? const <String, GitTreeEntry>{}
        : {for (final entry in gitEntries) entry.path: entry};
    final tracked = [
      ...(gitEntries?.map((entry) => entry.path) ?? source.trackedFiles())
    ]..sort();
    for (final path in tracked) {
      final entry = byPath[path];
      if (entry != null && !entry.isRegularFile) {
        throw StateError(
          'tracked source $path is a ${entry.unsupportedKind}; release '
          'staging accepts only regular Git files (100644 or 100755)',
        );
      }
      final bytes = gitSource == null
          ? source.readBytes(path)
          : gitSource.readBytesAt(directory.identity.headCommit!, path);
      if (bytes == null) {
        throw StateError('tracked source disappeared while staging: $path');
      }
      final staged = 'source/$path';
      directory.writeBytesAtomically(staged, bytes);
      if (entry != null) {
        _setGitFileMode(directory.resolve(staged), entry);
      }
      outputs.add(StageArtifact.capture(
        stage: directory,
        path: staged,
        type: 'source',
      ));
    }
    return outputs;
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
    final byPath = {
      for (final artifact in expected) artifact.path: artifact,
    };
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
      final actual = StageArtifact.capture(
        stage: directory,
        path: relative,
        type: 'source',
      );
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
          'release assets must name unique public files and blobs');
    }
    final formulaBinding = _formulaBinding();
    final formulaStagedPaths = {
      if (formulaBinding != null) formulaBinding.stagedPath,
    };
    final duplicatedFormulas = stagedPaths.intersection(
      formulaStagedPaths,
    );
    if (duplicatedFormulas.isNotEmpty) {
      throw ArgumentError(
        'Homebrew formulas cannot also be release assets: '
        '${duplicatedFormulas.join(', ')}',
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
      final existingPublic =
          existingManifest.artifacts.map((artifact) => artifact.name).toSet();
      final existingFormula = existingManifest.formula?.identity;
      final wantedFormula = formulaBinding?.identity;
      if (existingPublic.length != publicNames.length ||
          existingPublic.difference(publicNames).isNotEmpty ||
          existingFormula != wantedFormula) {
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
      for (final artifact in beforeManifest) artifact.path: artifact
    };
    final boundStagedPaths = {...stagedPaths, ...formulaStagedPaths};
    final missing = boundStagedPaths.difference(byPath.keys.toSet());
    if (missing.isNotEmpty) {
      throw StateError(
          'stage is missing publication artifacts: ${missing.join(', ')}');
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

    final manifest = ReleaseManifest(
      unit: unit.name,
      version: unit.version.canonical,
      tag: unit.tag,
      commit: directory.identity.headCommit,
      artifacts: [
        for (final binding in bindings)
          ReleaseManifestArtifact.fromStage(
            publicName: _publicName(binding.publicName),
            artifact: byPath[binding.stagedPath]!,
          ),
      ],
      formula: formulaBinding?.bind(byPath[formulaBinding.stagedPath]!),
    );
    manifest.writeTo(directory);

    final recorded =
        progress.artifacts.map((artifact) => artifact.path).toSet();
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
    final orderedBindings = [...bindings]
      ..sort((left, right) => left.publicName.compareTo(right.publicName));
    final completeInputs = <String, StageArtifact>{
      for (final binding in orderedBindings)
        binding.stagedPath: byPath[binding.stagedPath]!,
      if (formulaBinding != null)
        formulaBinding.stagedPath: byPath[formulaBinding.stagedPath]!,
    };
    final receipt = StageReceipt(
      identity: directory.identity,
      steps: [
        ...progress.steps,
        StageStep(
          name: 'complete-stage',
          inputs: [
            for (final path in completeInputs.keys.toList()..sort())
              StageInput.artifact(completeInputs[path]!),
          ],
          outputs: [manifestArtifact],
          evidence: {
            ...evidence,
            'release_assets': {
              for (final binding in orderedBindings)
                binding.publicName: binding.stagedPath,
            },
            'formula_binding': formulaBinding?.toEvidence(),
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
  void writeProgress(Iterable<StageStep> steps) {
    if (steps.any((step) => step.name == 'complete-stage')) {
      throw StateError('only finalize may complete a stage');
    }
    StageReceiptStore(directory).write(StageReceipt(
      identity: directory.identity,
      steps: steps,
    ));
  }

  List<StageArtifact> _captureAll() {
    if (!Directory(directory.path).existsSync()) return const [];
    final artifacts = <StageArtifact>[];
    final entities = Directory(directory.path)
        .listSync(recursive: true, followLinks: false)
      ..sort((left, right) => left.path.compareTo(right.path));
    for (final entity in entities) {
      if (entity is! File) continue;
      final relative = entity.path
          .substring(directory.path.length + 1)
          .split(Platform.pathSeparator)
          .join('/');
      if (relative == 'stage.json') continue;
      artifacts.add(StageArtifact.capture(
        stage: directory,
        path: relative,
        type: _typeOf(relative),
      ));
    }
    return artifacts;
  }

  static String _publicName(String path) {
    if (path.contains('/')) {
      throw ArgumentError('public artifact must be at the stage root: $path');
    }
    return path;
  }

  static String _typeOf(String path) {
    if (path.startsWith('source/')) return 'source';
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

  StagedFormulaBinding? _formulaBinding() {
    final project = unit.projects
        .where(
          (project) => project.publish.contains(PublishTarget.homebrew),
        )
        .firstOrNull;
    if (project == null) return null;
    final sourceRepository = repository;
    if (sourceRepository == null) {
      throw StateError(
        'Homebrew formula bindings need a source repository coordinate',
      );
    }
    return StagedFormulaBinding(
      project: project.name,
      tap: unit.tapFor(sourceRepository),
      path: 'Formula/${project.executable!}.rb',
      stagedPath: ReleaseAssets.formulaPath(project),
    );
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

void _setGitFileMode(String path, GitTreeEntry entry) {
  final permissions = entry.executable ? '755' : '644';
  final changed = Process.runSync('chmod', [permissions, path]);
  if (changed.exitCode != 0) {
    throw FileSystemException(
      'could not preserve Git mode ${entry.mode}: ${changed.stderr}',
      path,
    );
  }
}
