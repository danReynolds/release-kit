import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/release_bundle.dart';
import 'package:rk/src/engine/release_manifest.dart';
import 'package:rk/src/engine/release_stage.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/engine/stage_inspection.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:rk/src/transforms/archive.dart';
import 'package:test/test.dart';
import 'support/memory_source_tree.dart';

const _commit = '1111111111111111111111111111111111111111';
const _tree = '2222222222222222222222222222222222222222';
const _config = '''
schema = 2

[release.tool]
publish = ["git-tag", "github-release"]
binary_platforms = ["macos-arm64"]
''';
const _homebrewConfig = '''
schema = 2

[release.tool]
publish = ["git-tag", "github-release", "homebrew"]
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

  test(
    'release bundle exposes the exact public names and receipt artifacts',
    () async {
      final project = unit.binaryProject!;
      final stagedPath = ReleaseAssets.archivePath(project, 'macos-arm64');
      final publicName = ReleaseAssets.archiveName(
        'tool',
        '1.2.3',
        'macos-arm64',
      );
      await _recordArchives(release, {stagedPath: 'archive'});
      release.finalize(releaseAssets: ReleaseAssets.bundleFor(unit));

      final resolved = ReleaseBundle.resolve(release, unit);

      expect(resolved, isA<ReleaseBundleAvailable>());
      final bundle = (resolved as ReleaseBundleAvailable).bundle;
      expect(bundle.publicNames, {publicName, ReleaseAssets.manifest});
      expect(bundle.assets.map((asset) => asset.publicName), [
        publicName,
        ReleaseAssets.manifest,
      ]);
      expect(
        bundle.assets
            .singleWhere((asset) => asset.publicName == publicName)
            .artifact
            .path,
        stagedPath,
      );
      expect(bundle.sha256ByPublicName.keys, {
        publicName,
        ReleaseAssets.manifest,
      });
    },
  );

  test(
    'release bundle refuses a completed stage with another inventory',
    () async {
      await _recordArchives(release, const {});
      release.finalize(releaseAssets: const []);

      final resolved = ReleaseBundle.resolve(release, unit);

      expect(resolved, isA<ReleaseBundleInvalid>());
      final invalid = resolved as ReleaseBundleInvalid;
      expect(invalid.message, contains('different release-asset inventory'));
      expect(invalid.evidence[_asset], 'missing from stage');
    },
  );

  test(
    'complete receipt and public manifest are reusable as exact bytes',
    () async {
      await _recordArchives(release, {_asset: 'archive'});

      final receipt = release.finalize(
        releaseAssets: _fixtureReleaseAssets({_asset}),
        evidence: {
          'smoke': {'status': 'passed'},
        },
      );
      final manifest = ReleaseManifest.parse(
        File(
          release.directory.resolve('release-manifest.json'),
        ).readAsStringSync(),
      );
      final resumed = ReleaseStage(
        unit: unit,
        source: _source(),
        directory: release.directory,
      );

      expect(receipt.complete, isTrue);
      expect(
        receipt.artifacts.map((artifact) => artifact.path),
        containsAll([_asset, 'release-manifest.json']),
      );
      expect(manifest.commit, identity.headCommit);
      expect(manifest.artifacts.map((artifact) => artifact.name), [_asset]);
      expect(manifest.encode(), isNot(contains(repository.path)));
      expect(resumed.inspect().reusable, isTrue);
      expect(resumed.requireReceipt().identity.id, identity.id);
    },
  );

  test(
    'finalization binds a private formula only to its tap destination',
    () async {
      final homebrewSource = MemorySourceTree({...source.files});
      homebrewSource.files['release.toml'] = _homebrewConfig;
      final homebrewUnit = _resolveUnit(
        homebrewSource,
        configDocument: _homebrewConfig,
      );
      final homebrewStage = ReleaseStage(
        unit: homebrewUnit,
        source: homebrewSource,
        repository: 'owner/repo',
        directory: StageDirectory(
          repositoryRoot: repository.path,
          identity: identity,
        ),
      );
      await _recordArchives(homebrewStage, {_asset: 'archive'});
      final progress = StageReceiptStore(homebrewStage.directory).read()!;
      final project = homebrewUnit.project('tool');
      final formulaPath = ReleaseAssets.formulaPath(project);
      homebrewStage.directory.writeBytesAtomically(
        formulaPath,
        utf8.encode('class Tool < Formula\nend\n'),
      );
      final formula = StageArtifact.capture(
        stage: homebrewStage.directory,
        path: formulaPath,
        type: 'formula',
      );
      homebrewStage.writeProgress([
        ...progress.steps,
        StageStep(name: 'homebrew-formula:tool', outputs: [formula]),
      ]);

      final receipt = homebrewStage.finalize(
        releaseAssets: _fixtureReleaseAssets({_asset}),
      );
      final manifest = ReleaseManifest.parse(
        File(
          homebrewStage.directory.resolve(ReleaseAssets.manifest),
        ).readAsStringSync(),
      );
      final homebrewBinding = manifest.homebrew!;

      expect(manifest.artifacts.map((artifact) => artifact.name), [_asset]);
      expect(homebrewBinding.project, 'tool');
      expect(homebrewBinding.tap, 'owner/homebrew-tap');
      expect(homebrewBinding.path, 'Formula/tool.rb');
      expect(homebrewBinding.sha256, formula.sha256);
      expect(manifest.encode(), isNot(contains(formulaPath)));
      expect(receipt.steps.last.evidence['homebrew_binding'], isNotNull);
      expect(homebrewStage.releaseAssets(), isNot(contains(formulaPath)));
      expect(homebrewStage.inspect().reusable, isTrue);
    },
  );

  test('the final receipt keeps each producer\'s evidence', () async {
    await _recordArchives(release, {_asset: 'archive'});

    final finalized = release.finalize(
      releaseAssets: _fixtureReleaseAssets({_asset}),
    );

    final archive = finalized.steps.singleWhere(
      (step) => step.name == 'archive:$_asset',
    );
    expect(archive.evidence['smoke'], {'status': 'passed'});
  });

  test('a complete filesystem fixture records every artifact type', () async {
    final receipt = await _completeEveryArtifactType(release);

    expect(receipt.artifacts.map((artifact) => artifact.type).toSet(), {
      'executable',
      'notary-input',
      'notary',
      'archive',
      'notes',
      'formula',
      'manifest',
    });
    expect(release.inspect().reusable, isTrue);
  });

  test(
    'every published artifact is bound to its exact filesystem bytes',
    () async {
      final receipt = await _completeEveryArtifactType(release);

      for (final artifact in receipt.artifacts) {
        final file = File(release.directory.resolve(artifact.path));
        final original = file.readAsBytesSync();
        file.writeAsBytesSync([...original, 0x7f], flush: true);

        final inspected = release.inspect();
        if (publishedArtifactTypes.contains(artifact.type)) {
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
        } else {
          // An intermediate reaches the public only inside an archive
          // whose own bytes are checked.
          expect(inspected.reusable, isTrue, reason: artifact.path);
        }

        file.writeAsBytesSync(original, flush: true);
        expect(release.inspect().reusable, isTrue, reason: artifact.path);
      }
    },
  );

  test('a step resumes only from the exact bytes it recorded', () async {
    for (final nextName in [
      'build:tool:macos-arm64',
      'notarize:macos-arm64',
      'archive:$_asset',
      'release-notes',
      'homebrew-formula',
      'complete-stage',
    ]) {
      release.reset();
      final complete = await _completeEveryArtifactType(release);
      final nextIndex = complete.steps.indexWhere(
        (step) => step.name == nextName,
      );
      expect(nextIndex, greaterThanOrEqualTo(0), reason: nextName);
      final prefix = complete.steps.take(nextIndex).toList();
      final next = complete.steps[nextIndex];
      final originalBytes = {
        for (final artifact in next.outputs)
          artifact.path: File(
            release.directory.resolve(artifact.path),
          ).readAsBytesSync(),
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
      StageReceiptStore(release.directory).write(
        StageReceipt(
          identity: complete.identity,
          plan: complete.plan,
          steps: prefix,
        ),
      );

      for (final artifact in next.outputs) {
        release.directory.writeBytesAtomically(
          artifact.path,
          utf8.encode('wrong bytes for ${artifact.path}'),
        );
      }
      final candidate = StageReceipt(
        identity: complete.identity,
        plan: complete.plan,
        steps: [...prefix, next],
      );

      StageReceiptStore(release.directory).write(candidate);
      final wrong = release.inspect();
      expect(
        wrong.reusable || wrong.validProgress,
        isFalse,
        reason: '$nextName must not resume from bytes it did not record',
      );
      expect(
        wrong.issues.map((issue) => issue.kind),
        contains(StageIssueKind.changedArtifact),
        reason: nextName,
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
        reason:
            '$nextName resumes only after its exact bytes are restored: '
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

  test('finalize records only what producers recorded', () async {
    await _recordArchives(release, {_asset: 'archive'});
    release.directory.writeBytesAtomically(
      'planted-before-finalize.txt',
      utf8.encode('present, never recorded'),
    );

    final receipt = release.finalize(
      releaseAssets: _fixtureReleaseAssets({_asset}),
    );

    expect(
      receipt.artifacts.map((artifact) => artifact.path),
      isNot(contains('planted-before-finalize.txt')),
    );
  });

  test(
    'missing public artifact is refused before manifest or receipt writes',
    () async {
      await _recordArchives(release, const {});

      expect(
        () => release.finalize(releaseAssets: _fixtureReleaseAssets({_asset})),
        throwsStateError,
      );
      expect(
        File(release.directory.resolve('release-manifest.json')).existsSync(),
        isFalse,
      );
      expect(StageReceiptStore(release.directory).read()!.complete, isFalse);
    },
  );

  test(
    'reset deletes only this stage and never follows artifact symlinks',
    () async {
      release.writeProgress(const []);
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
      Link(
        release.directory.resolve('outside-link'),
      ).createSync(outsideFile.path);

      release.reset();

      expect(Directory(release.directory.path).existsSync(), isFalse);
      expect(File(sibling.resolve('keep.txt')).readAsStringSync(), 'keep');
      expect(outsideFile.readAsStringSync(), 'outside');
    },
  );

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

  test(
    'public manifest inventory is deterministic across insertion order',
    () async {
      await _recordArchives(release, {'z.tar.gz': 'z', 'a.tar.gz': 'a'});
      release.finalize(
        releaseAssets: _fixtureReleaseAssets({'z.tar.gz', 'a.tar.gz'}),
      );
      final first = File(
        release.directory.resolve('release-manifest.json'),
      ).readAsStringSync();

      release.finalize(
        releaseAssets: _fixtureReleaseAssets({'a.tar.gz', 'z.tar.gz'}),
      );
      final second = File(
        release.directory.resolve('release-manifest.json'),
      ).readAsStringSync();
      final manifest = ReleaseManifest.parse(second);

      expect(second, first);
      expect(manifest.artifacts.map((artifact) => artifact.name), [
        'a.tar.gz',
        'z.tar.gz',
      ]);
    },
  );
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

ResolvedUnit _resolveUnit(
  SourceTree source, {
  String configDocument = _config,
}) {
  final diagnostics = Diagnostics();
  final config = ReleaseConfig.parse(
    configDocument,
    'release.toml',
    diagnostics,
  );
  if (config == null) {
    fail('fixture config did not parse: ${diagnostics.found.join('\n')}');
  }
  final resolution = Resolution.resolve(config, source, diagnostics);
  if (resolution == null) {
    fail('fixture did not resolve: ${diagnostics.found.join('\n')}');
  }
  return resolution.unit('tool')!;
}

Future<StageReceipt> _completeEveryArtifactType(ReleaseStage release) async {
  final binaryBytes = utf8.encode('signed tool binary');
  release.directory.writeBytesAtomically('macos-arm64/tool', binaryBytes);
  final binary = StageArtifact.capture(
    stage: release.directory,
    path: 'macos-arm64/tool',
    type: 'executable',
  );
  final sign = StageStep(
    name: 'build:tool:macos-arm64',
    outputs: [binary],
    evidence: {
      'smoke': {'status': 'passed'},
      'signed_smoke': {'status': 'pass', 'command': '--version'},
      'signature': {
        'certificate': 'Developer ID Application: Test (TEAM123456)',
        'certificate_sha256': 'a' * 64,
        'first_identity': true,
        'published_requirement': null,
        'designated_requirement': 'designated => identifier "io.example.tool"',
        'code_id': 'io.example.tool',
        'unsigned_sha256': 'b' * 64,
        'signed_sha256': binary.sha256,
        'verified_after_smoke': true,
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

  final archiveBytes = ArchiveBuilder.gzip(
    ArchiveBuilder.tar([
      ArchiveEntry(name: 'tool', bytes: binaryBytes, executable: true),
    ]),
  );
  release.directory.writeBytesAtomically(_asset, archiveBytes);
  final archive = StageArtifact.capture(
    stage: release.directory,
    path: _asset,
    type: 'archive',
  );
  final archiveStep = StageStep(name: 'archive:$_asset', outputs: [archive]);

  release.directory.writeBytesAtomically(
    'release-notes.md',
    utf8.encode('## 1.2.3\n\n- production alpha fixture\n'),
  );
  final notes = StageStep(
    name: 'release-notes',
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
    outputs: [
      StageArtifact.capture(
        stage: release.directory,
        path: 'tool.rb',
        type: 'formula',
      ),
    ],
  );

  release.writeProgress([sign, notarize, archiveStep, notes, formula]);
  return release.finalize(
    releaseAssets: _fixtureReleaseAssets({
      _asset,
      _notaryResult,
      _notaryLog,
      'tool.rb',
    }),
  );
}

List<ReleaseAsset> _fixtureReleaseAssets(Iterable<String> paths) => [
  for (final path in paths) (publicName: path, stagedPath: path),
];

Future<void> _recordArchives(
  ReleaseStage release,
  Map<String, String> archives,
) async {
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
    name: 'build:tool:macos-arm64',
    outputs: [binary],
    evidence: {
      'smoke': const {'status': 'passed'},
      'signed_smoke': const {'status': 'pass', 'command': '--version'},
      'signature': {
        'certificate': 'Developer ID Application: Test (TEAM123456)',
        'certificate_sha256': 'a' * 64,
        'first_identity': true,
        'published_requirement': null,
        'designated_requirement': 'designated => identifier "io.example.tool"',
        'code_id': 'io.example.tool',
        'unsigned_sha256': 'b' * 64,
        'signed_sha256': binary.sha256,
        'verified_after_smoke': true,
      },
    },
  );
  final steps = <StageStep>[build];
  for (final entry in archives.entries) {
    final bytes = ArchiveBuilder.gzip(
      ArchiveBuilder.tar([
        ArchiveEntry(
          name: 'tool',
          bytes: utf8.encode(entry.value),
          executable: true,
        ),
      ]),
    );
    release.directory.writeBytesAtomically(entry.key, bytes);
    final artifact = StageArtifact.capture(
      stage: release.directory,
      path: entry.key,
      type: 'archive',
    );
    steps.add(
      StageStep(
        name: 'archive:${entry.key}',
        outputs: [artifact],
        evidence: {
          'smoke': {'status': 'passed'},
        },
      ),
    );
  }
  release.writeProgress(steps);
}
