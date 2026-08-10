import 'dart:convert';
import 'dart:io';

import 'package:release_kit/src/engine/config.dart';
import 'package:release_kit/src/engine/diagnostic.dart';
import 'package:release_kit/src/engine/release_manifest.dart';
import 'package:release_kit/src/engine/release_stage.dart';
import 'package:release_kit/src/engine/resolve.dart';
import 'package:release_kit/src/engine/source_tree.dart';
import 'package:release_kit/src/engine/stage.dart';
import 'package:release_kit/src/engine/stage_archive.dart';
import 'package:release_kit/src/engine/stage_inspection.dart';
import 'package:release_kit/src/engine/stage_receipt.dart';
import 'package:release_kit/src/transforms/archive.dart';
import 'package:test/test.dart';

const _commit = '1111111111111111111111111111111111111111';
const _tree = '2222222222222222222222222222222222222222';
const _config = '''
schema = 1

[release.tool]
publish = ["github-release"]
binary_platforms = ["macos-arm64"]
''';
const _asset = 'tool-1.2.3-macos-arm64.tar.gz';
const _notaryInput = 'macos-arm64/tool.zip';
const _notaryResult = 'tool-1.2.3-macos-arm64.notary-result.json';
const _notaryLog = 'tool-1.2.3-macos-arm64.notary-log.json';

void main() {
  late Directory repository;
  late MemorySourceTree source;
  late ResolvedUnit unit;
  late StageIdentity identity;
  late ReleaseStage release;

  setUp(() {
    repository = Directory.systemTemp.createTempSync('rk-release-stage-');
    source = _source();
    unit = _resolveUnit(source);
    identity = StageIdentity.forPlan(
      headCommit: _commit,
      headTree: _tree,
      resolvedPlan: {
        'unit': unit.name,
        'version': unit.version.canonical,
        'tag': unit.tag,
        'targets': ['github-release'],
        'platforms': ['macos-arm64'],
        'toolchain': 'test-dart',
      },
    );
    release = ReleaseStage(
      unit: unit,
      source: source,
      directory: StageDirectory(
        repositoryRoot: repository.path,
        identity: identity,
      ),
    );
  });

  tearDown(() => repository.deleteSync(recursive: true));

  test('materializes every tracked source byte in deterministic order', () {
    final captured = release.materializeSource();

    expect(
      captured.map((artifact) => artifact.path),
      [
        'source/README.md',
        'source/bin/tool.dart',
        'source/pubspec.yaml',
        'source/release.toml',
      ],
    );
    for (final entry in source.files.entries) {
      expect(
        File(release.directory.resolve('source/${entry.key}'))
            .readAsBytesSync(),
        utf8.encode(entry.value),
        reason: entry.key,
      );
    }

    source.files['bin/tool.dart'] = 'void main() => print("changed");\n';
    expect(
      File(release.directory.resolve('source/bin/tool.dart'))
          .readAsStringSync(),
      contains('hello'),
      reason: 'the staged snapshot no longer reads the mutable source tree',
    );
  });

  test('materializes the committed tree, not later worktree bytes', () {
    final sourceRepository =
        Directory.systemTemp.createTempSync('rk-release-source-');
    addTearDown(() => sourceRepository.deleteSync(recursive: true));
    _git(sourceRepository, ['init', '-q']);
    _git(sourceRepository, ['config', 'user.email', 'test@example.com']);
    _git(sourceRepository, ['config', 'user.name', 'Test']);
    for (final entry in _source().files.entries) {
      File('${sourceRepository.path}/${entry.key}')
        ..createSync(recursive: true)
        ..writeAsStringSync(entry.value);
    }
    File('${sourceRepository.path}/README.md')
        .writeAsStringSync('# Original\n');
    _git(sourceRepository, ['add', '-A']);
    _git(sourceRepository, ['commit', '-qm', 'release source']);
    final head = _git(sourceRepository, ['rev-parse', 'HEAD']);
    final tree = _git(sourceRepository, ['rev-parse', 'HEAD^{tree}']);
    final gitSource = GitSourceTree(sourceRepository.path);
    final gitUnit = _resolveUnit(gitSource);
    final committedRelease = ReleaseStage(
      unit: gitUnit,
      source: gitSource,
      directory: StageDirectory(
        repositoryRoot: repository.path,
        identity: StageIdentity.forPlan(
          headCommit: head,
          headTree: tree,
          resolvedPlan: {'unit': 'tool', 'version': '1.2.3'},
        ),
      ),
    );

    // Models a worktree edit racing after HEAD and HEAD^{tree} were read.
    File('${sourceRepository.path}/README.md').writeAsStringSync('# Changed\n');
    committedRelease.materializeSource();

    expect(
      File(committedRelease.directory.resolve('source/README.md'))
          .readAsStringSync(),
      '# Original\n',
    );
  });

  test('preserves regular and executable Git modes in the staged source', () {
    final sourceRepository = _gitRepository(_source());
    addTearDown(() => sourceRepository.deleteSync(recursive: true));
    final executable = File('${sourceRepository.path}/tool.sh')
      ..writeAsStringSync('#!/bin/sh\nexit 0\n');
    _git(sourceRepository, ['add', 'tool.sh']);
    _git(sourceRepository, ['update-index', '--chmod=+x', 'tool.sh']);
    _git(sourceRepository, ['commit', '-qm', 'add executable']);

    final staged = _gitRelease(sourceRepository, repository);
    final artifacts = staged.materializeSource();
    final regular = artifacts.singleWhere(
      (artifact) => artifact.path == 'source/README.md',
    );
    final script = artifacts.singleWhere(
      (artifact) => artifact.path == 'source/tool.sh',
    );

    expect(regular.mode, '0644');
    expect(script.mode, '0755');
    expect(executable.existsSync(), isTrue);
  });

  test('refuses a tracked symbolic link instead of changing its type', () {
    final sourceRepository = _gitRepository(_source());
    addTearDown(() => sourceRepository.deleteSync(recursive: true));
    Link('${sourceRepository.path}/README-link').createSync('README.md');
    _git(sourceRepository, ['add', 'README-link']);
    _git(sourceRepository, ['commit', '-qm', 'add link']);

    final staged = _gitRelease(sourceRepository, repository);
    expect(
      staged.materializeSource,
      throwsA(
        isA<StateError>().having(
          (error) => '$error',
          'message',
          allOf(contains('README-link'), contains('symbolic link')),
        ),
      ),
    );
  });

  test('refuses a tracked gitlink instead of writing its object id', () {
    final sourceRepository = _gitRepository(_source());
    addTearDown(() => sourceRepository.deleteSync(recursive: true));
    final nested = Directory.systemTemp.createTempSync('rk-gitlink-source-');
    addTearDown(() => nested.deleteSync(recursive: true));
    _git(nested, ['init', '-q']);
    _git(nested, ['config', 'user.email', 'test@example.com']);
    _git(nested, ['config', 'user.name', 'Test']);
    File('${nested.path}/tracked.txt').writeAsStringSync('nested\n');
    _git(nested, ['add', 'tracked.txt']);
    _git(nested, ['commit', '-qm', 'nested']);
    final nestedHead = _git(nested, ['rev-parse', 'HEAD']);
    _git(sourceRepository, [
      'update-index',
      '--add',
      '--cacheinfo',
      '160000,$nestedHead,vendor/dependency',
    ]);
    _git(sourceRepository, ['commit', '-qm', 'add gitlink']);

    final staged = _gitRelease(sourceRepository, repository);
    expect(
      staged.materializeSource,
      throwsA(
        isA<StateError>().having(
          (error) => '$error',
          'message',
          allOf(contains('vendor/dependency'), contains('gitlink/submodule')),
        ),
      ),
    );
  });

  test('complete receipt and public manifest are reusable as exact bytes', () {
    _recordArchives(release, {_asset: 'archive'});

    final receipt = release.finalize(
      publicArtifacts: {_asset},
      evidence: {
        'smoke': {'status': 'passed'},
      },
    );
    final manifest = ReleaseManifest.parse(
      File(release.directory.resolve('release-manifest.json'))
          .readAsStringSync(),
    );
    final resumed = ReleaseStage(
      unit: unit,
      source: _source(),
      directory: release.directory,
    );

    expect(receipt.complete, isTrue);
    expect(
      receipt.artifacts.map((artifact) => artifact.path),
      containsAll([
        'source/pubspec.yaml',
        _asset,
        'release-manifest.json',
      ]),
    );
    expect(manifest.commit, identity.headCommit);
    expect(manifest.artifacts.map((artifact) => artifact.name), [_asset]);
    expect(manifest.encode(), isNot(contains(repository.path)));
    expect(resumed.inspect().reusable, isTrue);
    expect(resumed.requireReceipt().identity.id, identity.id);
  });

  test('final receipt preserves producer input and evidence records', () {
    _recordArchives(release, {_asset: 'archive'});

    final finalized = release.finalize(publicArtifacts: {_asset});

    expect(
      finalized.steps.map((step) => step.name),
      contains('archive:$_asset'),
    );
    final archive = finalized.steps.singleWhere(
      (step) => step.name == 'archive:$_asset',
    );
    expect(archive.inputs.single.name, 'macos-arm64/tool');
    expect(archive.evidence['inventory'], isNotEmpty);
  });

  test('tampering with a completed artifact invalidates reuse', () {
    _complete(release);
    File(release.directory.resolve(_asset)).writeAsStringSync('tampered');

    final inspected = release.inspect();
    expect(inspected.reusable, isFalse);
    expect(
      inspected.issues.map((issue) => issue.kind),
      contains(StageIssueKind.changedArtifact),
    );
    expect(() => release.requireReceipt(), throwsStateError);
  });

  test('a complete filesystem fixture records every artifact type', () {
    final receipt = _completeEveryArtifactType(release);

    expect(
      receipt.artifacts.map((artifact) => artifact.type).toSet(),
      {
        'source',
        'executable',
        'notary-input',
        'notary',
        'archive',
        'checksums',
        'notes',
        'formula',
        'manifest',
      },
    );
    expect(release.inspect().reusable, isTrue);
  });

  test('every recorded artifact is bound to its exact filesystem bytes', () {
    final receipt = _completeEveryArtifactType(release);

    for (final artifact in receipt.artifacts) {
      final file = File(release.directory.resolve(artifact.path));
      final original = file.readAsBytesSync();
      file.writeAsBytesSync([...original, 0x7f], flush: true);

      final inspected = release.inspect();
      expect(inspected.reusable, isFalse, reason: artifact.path);
      expect(
        inspected.issues.where(
          (issue) =>
              issue.kind == StageIssueKind.changedArtifact &&
              issue.path == artifact.path,
        ),
        isNotEmpty,
        reason: artifact.path,
      );

      file.writeAsBytesSync(original, flush: true);
      expect(
        release.inspect().reusable,
        isTrue,
        reason: '${artifact.path} must be reusable again only at exact bytes',
      );
    }
  });

  test(
      'each producer output stays untrusted until the receipt replacement '
      'names its exact bytes', () {
    for (final nextName in [
      'build:macos-arm64',
      'notarize:macos-arm64',
      'archive:$_asset',
      'checksums',
      'release-notes',
      'homebrew-formula',
      'complete-stage',
    ]) {
      release.reset();
      final complete = _completeEveryArtifactType(release);
      final nextIndex = complete.steps.indexWhere(
        (step) => step.name == nextName,
      );
      expect(nextIndex, greaterThan(0), reason: nextName);
      final prefix = complete.steps.take(nextIndex).toList();
      final next = complete.steps[nextIndex];
      final originalBytes = {
        for (final artifact in next.outputs)
          artifact.path:
              File(release.directory.resolve(artifact.path)).readAsBytesSync(),
      };
      final retained = prefix
          .expand((step) => step.outputs)
          .map((artifact) => artifact.path)
          .toSet();
      for (final artifact in complete.artifacts) {
        if (retained.contains(artifact.path)) continue;
        final file = File(release.directory.resolve(artifact.path));
        if (file.existsSync()) file.deleteSync();
      }
      StageReceiptStore(release.directory).write(StageReceipt(
        identity: complete.identity,
        steps: prefix,
      ));
      final prefixReceipt =
          File(release.directory.resolve('stage.json')).readAsBytesSync();

      for (final artifact in next.outputs) {
        release.directory.writeBytesAtomically(
          artifact.path,
          utf8.encode('wrong bytes for ${artifact.path}'),
        );
      }
      final candidate = StageReceipt(
        identity: complete.identity,
        steps: [...prefix, next],
      );

      expect(
        () => StageReceiptStore(release.directory).write(candidate),
        throwsStateError,
        reason: nextName,
      );
      expect(
        File(release.directory.resolve('stage.json')).readAsBytesSync(),
        prefixReceipt,
        reason: '$nextName must not replace the last validated prefix',
      );

      for (final artifact in next.outputs) {
        File(release.directory.resolve(artifact.path)).deleteSync();
        release.directory.writeBytesAtomically(
          artifact.path,
          originalBytes[artifact.path]!,
        );
      }
      StageReceiptStore(release.directory).write(candidate);
      final inspected = release.inspect();
      expect(
        nextName == 'complete-stage'
            ? inspected.reusable
            : inspected.validProgress,
        isTrue,
        reason: '$nextName resumes only after its exact bytes are restored: '
            '${inspected.issues.join('; ')}',
      );
      expect(
        Directory(release.directory.path)
            .listSync(recursive: true)
            .where((entity) => entity.path.contains('.tmp.')),
        isEmpty,
        reason: nextName,
      );
    }
  });

  for (final crash in <_CrashBoundary>[
    _CrashBoundary(
      'unreceipted artifacts',
      StageIssueKind.missingReceipt,
      (release, _) =>
          File(release.directory.resolve('stage.json')).deleteSync(),
    ),
    _CrashBoundary(
      'orphan artifact',
      StageIssueKind.extraArtifact,
      (release, _) => release.directory.writeBytesAtomically(
        'orphan.tmp',
        utf8.encode('producer bytes whose receipt rename never happened'),
      ),
    ),
    _CrashBoundary(
      'truncated receipt',
      StageIssueKind.invalidReceipt,
      (release, _) => File(release.directory.resolve('stage.json'))
          .writeAsStringSync('{"schema":1', flush: true),
    ),
    _CrashBoundary(
      'receipt ahead of artifact bytes',
      StageIssueKind.missingArtifact,
      (release, receipt) => File(release.directory.resolve(
        receipt.artifacts
            .singleWhere((artifact) => artifact.type == 'archive')
            .path,
      )).deleteSync(),
    ),
  ]) {
    test('crash boundary never reuses ${crash.name}', () {
      final receipt = _completeEveryArtifactType(release);
      crash.mutate(release, receipt);

      final inspected = release.inspect();
      expect(inspected.reusable, isFalse);
      expect(
        inspected.issues.map((issue) => issue.kind),
        contains(crash.issue),
      );
    });
  }

  test('an extra file after completion invalidates reuse', () {
    _complete(release);
    release.directory.writeBytesAtomically(
      'planted-after-finalize.txt',
      utf8.encode('not receipted'),
    );

    final inspected = release.inspect();
    expect(inspected.reusable, isFalse);
    expect(
      inspected.issues.map((issue) => issue.kind),
      contains(StageIssueKind.extraArtifact),
    );
  });

  test('finalize refuses to bless a planted pre-existing file', () {
    _recordArchives(release, {_asset: 'archive'});
    release.directory.writeBytesAtomically(
      'planted-before-finalize.txt',
      utf8.encode('must not become trusted merely by being present'),
    );

    expect(
      () => release.finalize(publicArtifacts: {_asset}),
      throwsStateError,
    );
    expect(
      StageReceiptStore(release.directory).read()!.complete,
      isFalse,
      reason: 'the validated producer progress remains resumable',
    );
  });

  test('missing public artifact is refused before manifest or receipt writes',
      () {
    _recordArchives(release, const {});

    expect(
      () => release.finalize(publicArtifacts: {_asset}),
      throwsStateError,
    );
    expect(
      File(release.directory.resolve('release-manifest.json')).existsSync(),
      isFalse,
    );
    expect(StageReceiptStore(release.directory).read()!.complete, isFalse);
  });

  test('reset deletes only this stage and never follows artifact symlinks', () {
    release.materializeSource();
    final siblingIdentity = StageIdentity.forPlan(
      headCommit: _commit,
      headTree: _tree,
      resolvedPlan: {'unit': 'sibling'},
    );
    final sibling = StageDirectory(
      repositoryRoot: repository.path,
      identity: siblingIdentity,
    )..writeBytesAtomically('keep.txt', utf8.encode('keep'));
    final outside = Directory.systemTemp.createTempSync('rk-reset-outside-');
    addTearDown(() => outside.deleteSync(recursive: true));
    final outsideFile = File('${outside.path}/keep.txt')
      ..writeAsStringSync('outside');
    Link(release.directory.resolve('outside-link'))
        .createSync(outsideFile.path);

    release.reset();

    expect(Directory(release.directory.path).existsSync(), isFalse);
    expect(File(sibling.resolve('keep.txt')).readAsStringSync(), 'keep');
    expect(outsideFile.readAsStringSync(), 'outside');
  });

  test('reset refuses a symlinked fixed stage path', () {
    final outside = Directory.systemTemp.createTempSync('rk-reset-fixed-');
    addTearDown(() => outside.deleteSync(recursive: true));
    Link('${repository.path}/.rk').createSync(outside.path);
    final redirectedStage = Directory(
      '${outside.path}/work/stages/${identity.id}',
    )..createSync(recursive: true);
    final sentinel = File('${redirectedStage.path}/keep.txt')
      ..writeAsStringSync('keep');

    expect(() => release.reset(), throwsA(isA<FileSystemException>()));
    expect(sentinel.readAsStringSync(), 'keep');
  });

  test('public manifest inventory is deterministic across insertion order', () {
    _recordArchives(release, {'z.tar.gz': 'z', 'a.tar.gz': 'a'});
    release.finalize(publicArtifacts: {'z.tar.gz', 'a.tar.gz'});
    final first = File(release.directory.resolve('release-manifest.json'))
        .readAsStringSync();

    release.finalize(publicArtifacts: {'a.tar.gz', 'z.tar.gz'});
    final second = File(release.directory.resolve('release-manifest.json'))
        .readAsStringSync();
    final manifest = ReleaseManifest.parse(second);

    expect(second, first);
    expect(
      manifest.artifacts.map((artifact) => artifact.name),
      ['a.tar.gz', 'z.tar.gz'],
    );
  });

  test('an input digest cannot be detached from its earlier producer', () {
    _recordArchives(release, {_asset: 'archive'});
    final receipt = StageReceiptStore(release.directory).read()!;
    final archive = receipt.steps.singleWhere(
      (step) => step.name == 'archive:$_asset',
    );
    final detached = StageStep(
      name: archive.name,
      inputs: [
        StageInput(name: archive.inputs.single.name, sha256: 'f' * 64),
      ],
      outputs: archive.outputs,
      evidence: archive.evidence,
    );
    StageReceiptStore(release.directory).write(StageReceipt(
      identity: identity,
      steps: [
        for (final step in receipt.steps)
          if (step.name == archive.name) detached else step,
      ],
    ));

    final inspected = release.inspect();
    expect(inspected.validProgress, isFalse);
    expect(
      inspected.issues.map((issue) => issue.kind),
      contains(StageIssueKind.invalidStructure),
    );
  });

  test('archive inventory evidence is re-derived from the archive bytes', () {
    _recordArchives(release, {_asset: 'archive'});
    final receipt = StageReceiptStore(release.directory).read()!;
    final archive = receipt.steps.singleWhere(
      (step) => step.name == 'archive:$_asset',
    );
    final inventory = (archive.evidence['inventory'] as List)
        .map((entry) => Map<String, Object?>.from(entry as Map))
        .toList();
    inventory.single['sha256'] = 'f' * 64;
    final falseClaim = StageStep(
      name: archive.name,
      inputs: archive.inputs,
      outputs: archive.outputs,
      evidence: {'inventory': inventory},
    );
    StageReceiptStore(release.directory).write(StageReceipt(
      identity: identity,
      steps: [
        for (final step in receipt.steps)
          if (step.name == archive.name) falseClaim else step,
      ],
    ));

    final inspected = release.inspect();
    expect(inspected.validProgress, isFalse);
    expect(
      inspected.issues.map((issue) => issue.kind),
      contains(StageIssueKind.invalidArchive),
    );
  });

  test('manifest metadata is checked against the producer relation', () {
    _recordArchives(release, {_asset: 'archive'});
    final progress = StageReceiptStore(release.directory).read()!;
    final archive = progress.artifacts.singleWhere((a) => a.path == _asset);
    ReleaseManifest(
      unit: unit.name,
      version: unit.version.canonical,
      tag: unit.tag,
      commit: identity.headCommit,
      artifacts: [
        ReleaseManifestArtifact(
          name: _asset,
          type: archive.type,
          size: archive.size,
          sha256: 'f' * 64,
        ),
      ],
    ).writeTo(release.directory);
    final manifest = StageArtifact.capture(
      stage: release.directory,
      path: 'release-manifest.json',
      type: 'manifest',
    );
    StageReceiptStore(release.directory).write(StageReceipt(
      identity: identity,
      steps: [
        ...progress.steps,
        StageStep(
          name: 'complete-stage',
          inputs: [StageInput.artifact(archive)],
          outputs: [manifest],
        ),
      ],
    ));

    expect(
      release.inspect().issues.map((issue) => issue.kind),
      contains(StageIssueKind.invalidManifest),
    );
  });

  test('SHA256SUMS is parsed and must exactly cover archive digests', () {
    _recordArchives(release, {_asset: 'archive'});
    final progress = StageReceiptStore(release.directory).read()!;
    final archive = progress.artifacts.singleWhere((a) => a.path == _asset);
    release.directory.writeBytesAtomically(
      'SHA256SUMS',
      utf8.encode('${'f' * 64}  $_asset\n'),
    );
    final checksums = StageArtifact.capture(
      stage: release.directory,
      path: 'SHA256SUMS',
      type: 'checksums',
    );
    final checksumStep = StageStep(
      name: 'checksums',
      inputs: [StageInput.artifact(archive)],
      outputs: [checksums],
    );
    ReleaseManifest(
      unit: unit.name,
      version: unit.version.canonical,
      tag: unit.tag,
      commit: identity.headCommit,
      artifacts: [
        ReleaseManifestArtifact.fromStage(
          publicName: _asset,
          artifact: archive,
        ),
        ReleaseManifestArtifact.fromStage(
          publicName: 'SHA256SUMS',
          artifact: checksums,
        ),
      ],
    ).writeTo(release.directory);
    final manifest = StageArtifact.capture(
      stage: release.directory,
      path: 'release-manifest.json',
      type: 'manifest',
    );
    StageReceiptStore(release.directory).write(StageReceipt(
      identity: identity,
      steps: [
        ...progress.steps,
        checksumStep,
        StageStep(
          name: 'complete-stage',
          inputs: [
            StageInput.artifact(archive),
            StageInput.artifact(checksums),
          ],
          outputs: [manifest],
        ),
      ],
    ));

    expect(
      release.inspect().issues.map((issue) => issue.kind),
      contains(StageIssueKind.invalidChecksums),
    );
  });
}

MemorySourceTree _source() => MemorySourceTree({
      'release.toml': _config,
      'pubspec.yaml': '''
name: tool
version: 1.2.3
executables:
  tool: tool
''',
      'bin/tool.dart': 'void main() => print("hello");\n',
      'README.md': '# Tool\n',
    });

ResolvedUnit _resolveUnit(SourceTree source) {
  final diagnostics = Diagnostics();
  final config = ReleaseConfig.parse(_config, 'release.toml', diagnostics);
  if (config == null) {
    fail('fixture config did not parse: ${diagnostics.found.join('\n')}');
  }
  final resolution = Resolution.resolve(config, source, diagnostics);
  if (resolution == null) {
    fail('fixture did not resolve: ${diagnostics.found.join('\n')}');
  }
  return resolution.unit('tool')!;
}

void _complete(ReleaseStage release) {
  _recordArchives(release, {_asset: 'archive'});
  release.finalize(publicArtifacts: {_asset});
}

StageReceipt _completeEveryArtifactType(ReleaseStage release) {
  final sourceArtifacts = release.materializeSource();
  final source = StageStep(
    name: 'source-snapshot',
    inputs: [
      StageInput.commit(release.directory.identity),
      StageInput.tree(release.directory.identity),
      StageInput.plan(release.directory.identity),
    ],
    outputs: sourceArtifacts,
    evidence: {
      'commit': release.directory.identity.headCommit,
      'tree': release.directory.identity.headTree,
    },
  );

  final binaryBytes = utf8.encode('signed tool binary');
  release.directory.writeBytesAtomically('macos-arm64/tool', binaryBytes);
  final binary = StageArtifact.capture(
    stage: release.directory,
    path: 'macos-arm64/tool',
    type: 'executable',
  );
  final sign = StageStep(
    name: 'build:macos-arm64',
    inputs: [StageInput.step(source)],
    outputs: [binary],
    evidence: {
      'smoke': {'status': 'passed'},
      'signature': {
        'certificate': 'Developer ID Application: Test (TEAM123456)',
        'certificate_sha256': 'a' * 64,
        'first_identity': true,
        'published_requirement': null,
        'code_id': 'io.example.tool',
        'unsigned_sha256': 'b' * 64,
        'signed_sha256': binary.sha256,
      },
    },
  );

  release.directory.writeBytesAtomically(
    _notaryInput,
    utf8.encode('notary submission containing the signed tool'),
  );
  release.directory.writeBytesAtomically(
    _notaryResult,
    utf8.encode('{"id":"fixture-submission","status":"Accepted"}'),
  );
  release.directory.writeBytesAtomically(
    _notaryLog,
    utf8.encode('{"id":"fixture-submission","issues":[]}'),
  );
  final notaryResult = StageArtifact.capture(
    stage: release.directory,
    path: _notaryResult,
    type: 'notary',
  );
  final notaryLog = StageArtifact.capture(
    stage: release.directory,
    path: _notaryLog,
    type: 'notary',
  );
  final notarize = StageStep(
    name: 'notarize:macos-arm64',
    inputs: [StageInput.artifact(binary)],
    outputs: [
      StageArtifact.capture(
        stage: release.directory,
        path: _notaryInput,
        type: 'notary-input',
      ),
      notaryResult,
      notaryLog,
    ],
    evidence: {
      'notary': {
        'status': 'Accepted',
        'submission_id': 'fixture-submission',
        'result_sha256': notaryResult.sha256,
        'log_sha256': notaryLog.sha256,
      },
    },
  );

  final archiveBytes = ArchiveBuilder.gzip(ArchiveBuilder.tar([
    ArchiveEntry(name: 'tool', bytes: binaryBytes, executable: true),
  ]));
  release.directory.writeBytesAtomically(_asset, archiveBytes);
  final archive = StageArtifact.capture(
    stage: release.directory,
    path: _asset,
    type: 'archive',
  );
  final archiveStep = StageStep(
    name: 'archive:$_asset',
    inputs: [StageInput.artifact(binary)],
    outputs: [archive],
    evidence: {
      'inventory': StageArchiveInventory.evidence(
        StageArchiveInventory.parse(archiveBytes),
      ),
    },
  );

  release.directory.writeBytesAtomically(
    'SHA256SUMS',
    utf8.encode('${archive.sha256}  $_asset\n'),
  );
  final checksums = StageStep(
    name: 'checksums',
    inputs: [StageInput.artifact(archive)],
    outputs: [
      StageArtifact.capture(
        stage: release.directory,
        path: 'SHA256SUMS',
        type: 'checksums',
      ),
    ],
  );

  release.directory.writeBytesAtomically(
    'release-notes.md',
    utf8.encode('## 1.2.3\n\n- production alpha fixture\n'),
  );
  final notes = StageStep(
    name: 'release-notes',
    inputs: [StageInput.step(source)],
    outputs: [
      StageArtifact.capture(
        stage: release.directory,
        path: 'release-notes.md',
        type: 'notes',
      ),
    ],
  );

  release.directory.writeBytesAtomically(
    'tool.rb',
    utf8.encode('class Tool < Formula\nend\n'),
  );
  final formula = StageStep(
    name: 'homebrew-formula',
    inputs: [StageInput.artifact(archive)],
    outputs: [
      StageArtifact.capture(
        stage: release.directory,
        path: 'tool.rb',
        type: 'formula',
      ),
    ],
  );

  release.writeProgress([
    source,
    sign,
    notarize,
    archiveStep,
    checksums,
    notes,
    formula,
  ]);
  return release.finalize(publicArtifacts: {
    _asset,
    'SHA256SUMS',
    _notaryResult,
    _notaryLog,
    'tool.rb',
  });
}

void _recordArchives(ReleaseStage release, Map<String, String> archives) {
  final sourceArtifacts = release.materializeSource();
  final source = StageStep(
    name: 'source-snapshot',
    inputs: [
      StageInput.commit(release.directory.identity),
      StageInput.tree(release.directory.identity),
      StageInput.plan(release.directory.identity),
    ],
    outputs: sourceArtifacts,
    evidence: {
      'commit': release.directory.identity.headCommit,
      'tree': release.directory.identity.headTree,
    },
  );
  release.directory.writeBytesAtomically(
    'macos-arm64/tool',
    utf8.encode('binary'),
  );
  final binary = StageArtifact.capture(
    stage: release.directory,
    path: 'macos-arm64/tool',
    type: 'executable',
  );
  final build = StageStep(
    name: 'build:macos-arm64',
    inputs: [StageInput.step(source)],
    outputs: [binary],
    evidence: {
      'smoke': const {'status': 'passed'},
      'signature': {
        'certificate': 'Developer ID Application: Test (TEAM123456)',
        'certificate_sha256': 'a' * 64,
        'first_identity': true,
        'published_requirement': null,
        'code_id': 'io.example.tool',
        'unsigned_sha256': 'b' * 64,
        'signed_sha256': binary.sha256,
      },
    },
  );
  final steps = <StageStep>[source, build];
  for (final entry in archives.entries) {
    final bytes = ArchiveBuilder.gzip(ArchiveBuilder.tar([
      ArchiveEntry(
        name: 'tool',
        bytes: utf8.encode(entry.value),
        executable: true,
      ),
    ]));
    release.directory.writeBytesAtomically(entry.key, bytes);
    final artifact = StageArtifact.capture(
      stage: release.directory,
      path: entry.key,
      type: 'archive',
    );
    steps.add(StageStep(
      name: 'archive:${entry.key}',
      inputs: [StageInput.artifact(binary)],
      outputs: [artifact],
      evidence: {
        'inventory': StageArchiveInventory.evidence(
          StageArchiveInventory.parse(bytes),
        ),
      },
    ));
  }
  release.writeProgress(steps);
}

String _git(Directory repository, List<String> arguments) {
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: repository.path,
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return (result.stdout as String).trim();
}

Directory _gitRepository(MemorySourceTree contents) {
  final repository = Directory.systemTemp.createTempSync('rk-git-source-');
  _git(repository, ['init', '-q']);
  _git(repository, ['config', 'user.email', 'test@example.com']);
  _git(repository, ['config', 'user.name', 'Test']);
  for (final entry in contents.files.entries) {
    File('${repository.path}/${entry.key}')
      ..createSync(recursive: true)
      ..writeAsStringSync(entry.value);
  }
  _git(repository, ['add', '-A']);
  _git(repository, ['commit', '-qm', 'release source']);
  return repository;
}

ReleaseStage _gitRelease(Directory source, Directory stageRoot) {
  final tree = GitSourceTree(source.path);
  final unit = _resolveUnit(tree);
  return ReleaseStage(
    unit: unit,
    source: tree,
    directory: StageDirectory(
      repositoryRoot: stageRoot.path,
      identity: StageIdentity.forPlan(
        headCommit: _git(source, ['rev-parse', 'HEAD']),
        headTree: _git(source, ['rev-parse', 'HEAD^{tree}']),
        resolvedPlan: {'unit': unit.name, 'version': unit.version.canonical},
      ),
    ),
  );
}

class _CrashBoundary {
  const _CrashBoundary(this.name, this.issue, this.mutate);

  final String name;
  final StageIssueKind issue;
  final void Function(ReleaseStage release, StageReceipt receipt) mutate;
}
