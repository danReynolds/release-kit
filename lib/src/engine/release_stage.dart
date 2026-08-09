import 'dart:io';

import 'release_manifest.dart';
import 'resolve.dart';
import 'source_tree.dart';
import 'stage.dart';
import 'stage_contract.dart';
import 'stage_inspection.dart';
import 'stage_plan.dart';
import 'stage_receipt.dart';
import 'git.dart';

/// One shared, cached stage resolver for status and release composition.
class ReleaseStages {
  ReleaseStages({
    required this.source,
    required this.git,
    String? repositoryRoot,
    DartCompilerIdentity Function()? compilerIdentity,
    RkImplementationIdentity Function()? rkIdentity,
  })  : repositoryRoot = repositoryRoot ?? git.root,
        _compilerIdentity =
            compilerIdentity ?? DartCompilerIdentity.readAmbient,
        _rkIdentity = rkIdentity ?? RkImplementationIdentity.readAmbient;

  final SourceTree source;
  final GitState git;
  final String repositoryRoot;
  final DartCompilerIdentity Function() _compilerIdentity;
  final RkImplementationIdentity Function() _rkIdentity;
  final Map<String, ReleaseStage> _stages = {};
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
    final identity = StageIdentity.forPlan(
      headCommit: currentGit.head,
      headTree: currentGit.headTree,
      resolvedPlan: stagePlanFor(
        unit,
        currentGit,
        compiler: compiler,
        rk: rk,
      ),
    );
    return ReleaseStage(
      unit: unit,
      source: source,
      compiler: compiler,
      repository: currentGit.originUrl,
      enforceUnitContract: true,
      directory: StageDirectory(
        repositoryRoot: repositoryRoot,
        identity: identity,
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
  });

  final ResolvedUnit unit;
  final SourceTree source;
  final StageDirectory directory;
  final DartCompilerIdentity? compiler;
  final String? repository;

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
    if (receipt != null && enforceUnitContract) {
      issues.addAll(StageReceiptContract.forUnit(
        unit: unit,
        repository: repository,
        sourceRoot: sourceRoot,
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
    final gitEntries =
        gitSource?.trackedEntriesAt(directory.identity.headCommit);
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
          : gitSource.readBytesAt(directory.identity.headCommit, path);
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
  /// [publicArtifacts] are workspace-relative filenames that will be
  /// published. The manifest deliberately does not list itself, avoiding a
  /// self-digest cycle; the local receipt does capture it like every other
  /// staged file.
  StageReceipt finalize({
    required Set<String> publicArtifacts,
    Map<String, Object?> evidence = const {},
  }) {
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
      if (existingPublic.length != publicArtifacts.length ||
          existingPublic.difference(publicArtifacts).isNotEmpty) {
        throw StateError(
          'the completed stage has a different public inventory',
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
    final missing = publicArtifacts.difference(byPath.keys.toSet());
    if (missing.isNotEmpty) {
      throw StateError(
          'stage is missing public artifacts: ${missing.join(', ')}');
    }

    final allowed = <String>{
      for (final path in byPath.keys)
        if (path.startsWith('source/')) path,
      ...publicArtifacts,
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
      identity: directory.identity,
      artifacts: [
        for (final name in publicArtifacts)
          ReleaseManifestArtifact.fromStage(
            publicName: _publicName(name),
            artifact: byPath[name]!,
          ),
      ],
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
    final public = publicArtifacts.toList()..sort();
    final receipt = StageReceipt(
      identity: directory.identity,
      complete: true,
      steps: [
        ...progress.steps,
        StageStep(
          name: 'complete-stage',
          inputs: [
            for (final path in public) StageInput.artifact(byPath[path]!),
          ],
          outputs: [manifestArtifact],
          evidence: {
            ...evidence,
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

  /// Atomically records producer progress without making it reusable.
  ///
  /// A crash can preserve useful evidence, but only [finalize] may flip the
  /// receipt to complete. Outputs must already have been captured explicitly;
  /// an inventory scan never adopts an unrelated file.
  void writeProgress(Iterable<StageStep> steps) {
    StageReceiptStore(directory).write(StageReceipt(
      identity: directory.identity,
      complete: false,
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
    if (path == 'SHA256SUMS') return 'checksums';
    if (path.endsWith('.tar.gz')) return 'archive';
    if (path.endsWith('.rb')) return 'formula';
    if (path.endsWith('.notary-result.json') ||
        path.endsWith('.notary-log.json')) {
      return 'notary';
    }
    if (path.endsWith('.zip')) return 'notary-input';
    return 'executable';
  }
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
