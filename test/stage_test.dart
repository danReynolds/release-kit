import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/atomic_file.dart';
import 'package:rk/src/engine/canonical_json.dart';
import 'package:rk/src/engine/release_manifest.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/engine/stage_inspection.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

String _sha(String text) => Sha256.hex(utf8.encode(text));

/// Rewrites [file], after letting the clock move.
///
/// Timestamps are microseconds, and two writes in the same microsecond are
/// indistinguishable by size, mode, and time — the collision the file-level
/// memo documents and cannot see. A test that rewrites a file immediately
/// after digesting it lands in exactly that window and passes or fails on
/// how fast the machine is; the wait is what makes these tests about the
/// guard rather than about the clock.
void _rewriteAfterAMoment(File file, String text) {
  sleep(const Duration(milliseconds: 5));
  file.writeAsBytesSync(utf8.encode(text));
}

const _commit = '1111111111111111111111111111111111111111';
const _tree = '2222222222222222222222222222222222222222';

void main() {
  group('atomic file replacement', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('rk-atomic-'));
    tearDown(() => root.deleteSync(recursive: true));

    test('an interrupted sibling leaves the destination at its old bytes', () {
      final destination = File('${root.path}/artifact');
      AtomicFile.write(destination.path, utf8.encode('old'));

      // This is the only filesystem state between the helper's flush and
      // rename: the destination is still old and the new bytes are a private
      // sibling. It carries no authority if the process stops here.
      final interrupted = File('${destination.path}.tmp.$pid.interrupted')
        ..writeAsBytesSync(utf8.encode('new'), flush: true);

      expect(destination.readAsStringSync(), 'old');
      expect(interrupted.readAsStringSync(), 'new');

      interrupted.deleteSync();
      AtomicFile.write(destination.path, utf8.encode('new'));

      expect(destination.readAsStringSync(), 'new');
      expect(
        root.listSync().where((entity) => entity.path.contains('.tmp.')),
        isEmpty,
      );
    });

    test('a failed rename removes its private sibling', () {
      final destination = Directory('${root.path}/artifact')..createSync();
      final sentinel = File('${destination.path}/keep')..writeAsStringSync('x');

      expect(
        () => AtomicFile.write(destination.path, utf8.encode('new')),
        throwsA(isA<FileSystemException>()),
      );
      expect(destination.existsSync(), isTrue);
      expect(sentinel.readAsStringSync(), 'x');
      expect(
        root.listSync().where((entity) => entity.path.contains('.tmp.')),
        isEmpty,
      );
    });
  });

  group('stage identity', () {
    test('canonical plan order does not change the identity', () {
      final left = _identity({
        'unit': 'rk',
        'targets': ['pub.dev', 'github'],
        'build': {'platform': 'macos-arm64', 'toolchain': 'dart-3.9'},
      });
      final right = _identity({
        'build': {'toolchain': 'dart-3.9', 'platform': 'macos-arm64'},
        'targets': ['pub.dev', 'github'],
        'unit': 'rk',
      });

      expect(left.id, right.id);
      expect(left.planSha256, right.planSha256);
      expect(left.id, hasLength(64));
    });

    test('commit, tree, and any resolved plan input change the identity', () {
      final baseline = _identity({'toolchain': 'dart-3.9'});
      final differentCommit = StageIdentity.forPlan(
        headCommit: '3' * 40,
        headTree: _tree,
        resolvedPlan: {'toolchain': 'dart-3.9'},
      );
      final differentTree = StageIdentity.forPlan(
        headCommit: _commit,
        headTree: '4' * 40,
        resolvedPlan: {'toolchain': 'dart-3.9'},
      );
      final differentPlan = _identity({'toolchain': 'dart-3.10'});

      expect(
        {baseline.id, differentCommit.id, differentTree.id, differentPlan.id},
        hasLength(4),
      );
    });

    test('abbreviated and mismatched Git object IDs are refused', () {
      expect(
        () => StageIdentity.forPlan(
          headCommit: '1' * 12,
          headTree: _tree,
          resolvedPlan: const {},
        ),
        throwsArgumentError,
      );
      expect(
        () => StageIdentity.forPlan(
          headCommit: _commit,
          headTree: '2' * 64,
          resolvedPlan: const {},
        ),
        throwsArgumentError,
      );
    });

    test('only JSON data can enter the canonical plan', () {
      expect(
        () => _identity({'bad': DateTime(2026)}),
        throwsFormatException,
      );
      expect(
        () => _identity({'bad': double.nan}),
        throwsFormatException,
      );
    });

    test('unbound identities are invocation-scoped and claim no revision', () {
      final first = StageIdentity.forUnboundPlan(
        runId: 'run-a',
        resolvedPlan: const {'unit': 'tool'},
      );
      final sameRun = StageIdentity.forUnboundPlan(
        runId: 'run-a',
        resolvedPlan: const {'unit': 'tool'},
      );
      final laterRun = StageIdentity.forUnboundPlan(
        runId: 'run-b',
        resolvedPlan: const {'unit': 'tool'},
      );

      expect(first.id, sameRun.id);
      expect(first.id, isNot(laterRun.id));
      expect(first.isGitBound, isFalse);
      expect(first.headCommit, isNull);
      expect(first.headTree, isNull);
      expect(StageIdentity.fromJson(first.toJson()).id, first.id);
    });
  });

  group('stage receipt and inspection', () {
    late Directory repository;
    late StageDirectory stage;

    setUp(() {
      repository = Directory.systemTemp.createTempSync('rk-stage-');
      stage = StageDirectory(
        repositoryRoot: repository.path,
        identity: _identity({
          'unit': 'rk',
          'platforms': ['macos-arm64'],
          'toolchain': {'dart': '3.9.0'},
        }),
      );
    });

    tearDown(() => repository.deleteSync(recursive: true));

    test('a file that moved while being read is not remembered', () {
      stage.ensureExists();
      final artifact = File(stage.resolve('out/tool'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(utf8.encode('one'));
      // How the file looked when a read would have begun.
      final beforeReading = artifact.statSync();

      // Rewritten before the digest was recorded: whatever was read is not
      // what is on disk now, so nothing may be remembered about it.
      _rewriteAfterAMoment(artifact, 'two');
      stage.noteDigested('out/tool', beforeReading, _sha('one'));

      expect(
        stage.digestStillStands('out/tool', _sha('one')),
        isFalse,
        reason: 'remembering this would vouch for bytes nobody digested',
      );
    });

    test('a path that became a link is read again, whatever it points at', () {
      stage.ensureExists();
      final artifact = File(stage.resolve('out/tool'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(utf8.encode('one'));
      final recorded = StageArtifact.capture(
        stage: stage,
        path: 'out/tool',
        type: 'executable',
      );
      expect(stage.digestStillStands('out/tool', recorded.sha256), isTrue);

      // stat follows a link and would describe its target, so the type is
      // checked without following. A test cannot forge a target whose stat
      // matches — change time is not settable — so this pins the mechanism
      // rather than the collision it exists for.
      final elsewhere = File('${repository.path}/elsewhere')
        ..writeAsBytesSync(utf8.encode('one'));
      artifact.deleteSync();
      Link(stage.resolve('out/tool')).createSync(elsewhere.path);

      expect(stage.digestStillStands('out/tool', recorded.sha256), isFalse);
    });

    test('a refused confirmation is refused again, not remembered', () {
      stage.ensureExists();
      final artifact = File(stage.resolve('out/tool'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(utf8.encode('one'));
      final recorded = StageArtifact.capture(
        stage: stage,
        path: 'out/tool',
        type: 'executable',
      );

      // The file is now something else. Confirming it reads the new bytes
      // and hands back a different artifact — and, having read them, knows
      // them.
      _rewriteAfterAMoment(artifact, 'two');
      final first = StageArtifact.confirm(recorded, stage: stage);
      expect(first.sha256, isNot(recorded.sha256));

      // The second confirmation must reach the same verdict. Answering it
      // from what the first read would vouch for bytes the caller already
      // refused.
      final second = StageArtifact.confirm(recorded, stage: stage);
      expect(
        second.sha256,
        isNot(recorded.sha256),
        reason: 'a check that passes on its second run is not a check',
      );
    });

    test('a receipt refuses to record bytes that changed under it', () {
      stage.ensureExists();
      final artifact = File(stage.resolve('out/tool'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(utf8.encode('one'));
      final recorded = StageArtifact.capture(
        stage: stage,
        path: 'out/tool',
        type: 'executable',
      );
      final receipt = StageReceipt(
        identity: stage.identity,
        steps: [
          StageStep(name: 'build', inputs: const [], outputs: [recorded]),
        ],
      );
      // Writing the receipt straight away is the ordinary case, and the
      // bytes were digested a moment ago.
      StageReceiptStore(stage).write(receipt);

      // Same length, so only the timestamps separate these bytes from the
      // ones that were digested. A confirmation that trusts its own memory
      // records a digest for bytes that are no longer there.
      _rewriteAfterAMoment(artifact, 'two');

      expect(
        () => StageReceiptStore(stage).write(receipt),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('artifact changed before receipt write'),
          ),
        ),
      );
    });

    test('lives at the content-addressed stages path', () {
      expect(
        stage.path,
        '${repository.path}/.rk/work/stages/${stage.identity.id}',
      );
    });

    test('round-trips strict step, input, signature, and notary evidence', () {
      final receipt = _writeCompleteStage(stage);
      final document = File(stage.resolve('stage.json')).readAsStringSync();
      final parsed = StageReceipt.parse(document);

      expect(parsed.identity.id, stage.identity.id);
      expect(parsed.complete, isTrue);
      final build = parsed.steps.singleWhere(
        (step) => step.name == 'build:rk:macos-arm64',
      );
      expect(build.inputs.single.name, 'step:source-snapshot');
      expect(
        (build.evidence['signature']! as Map)['certificate_sha256'],
        'a' * 64,
      );
      expect(
        build.evidence['notary'],
        {'log_sha256': 'b' * 64, 'status': 'accepted'},
      );
      expect(
        Directory(stage.path)
            .listSync()
            .where((entity) => entity.path.contains('.tmp.')),
        isEmpty,
        reason: 'the atomic rename leaves no writer temporary behind',
      );
      expect(StageInspector().inspect(stage).reusable, isTrue);
      expect(
          receipt.artifacts.map((artifact) => artifact.path), contains('rk'));
    });

    test('an earlier schema refuses by version, not by field shape', () {
      final receipt = _writeCompleteStage(stage);
      final old = Map<String, Object?>.from(receipt.toJson())
        ..['schema'] = stageSchemaVersion - 1
        ..['complete'] = true;
      expect(
        () => StageReceipt.parse('${CanonicalJson.encode(old)}\n'),
        throwsA(isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('unsupported stage schema'),
        )),
        reason: 'the schema message is the one a reader can act on; the '
            'field error it used to get named a symptom',
      );
    });

    test('receipt parser rejects unknown fields and non-canonical bytes', () {
      final receipt = _writeCompleteStage(stage);
      final withUnknown = Map<String, Object?>.from(receipt.toJson())
        ..['local_path'] = '/Users/example/repo';
      expect(
        () => StageReceipt.parse('${CanonicalJson.encode(withUnknown)}\n'),
        throwsFormatException,
      );
      expect(
        () => StageReceipt.parse(jsonEncode(receipt.toJson())),
        throwsFormatException,
        reason: 'even otherwise-valid receipt JSON has one canonical form',
      );
    });

    test('a receipt cannot bless bytes changed after capture', () {
      stage.writeBytesAtomically('rk', utf8.encode('original'));
      final artifact = StageArtifact.capture(
        stage: stage,
        path: 'rk',
        type: 'executable',
      );
      File(stage.resolve('rk')).writeAsStringSync('changed');
      final receipt = StageReceipt(
        identity: stage.identity,
        steps: [
          StageStep(name: 'build', outputs: [artifact])
        ],
      );

      expect(
        () => StageReceiptStore(stage).write(receipt),
        throwsStateError,
      );
      expect(File(stage.resolve('stage.json')).existsSync(), isFalse);
    });

    test('a failed receipt replacement preserves the previous receipt', () {
      final previous = _writeCompleteStage(stage);
      final previousBytes = File(stage.resolve('stage.json')).readAsBytesSync();
      stage.writeBytesAtomically('candidate', utf8.encode('captured'));
      final candidate = StageArtifact.capture(
        stage: stage,
        path: 'candidate',
        type: 'test',
      );
      File(stage.resolve('candidate')).writeAsStringSync('changed');

      expect(
        () => StageReceiptStore(stage).write(StageReceipt(
          identity: previous.identity,
          steps: [
            ...previous.steps,
            StageStep(name: 'candidate', outputs: [candidate]),
          ],
        )),
        throwsStateError,
      );
      expect(
        File(stage.resolve('stage.json')).readAsBytesSync(),
        previousBytes,
        reason: 'validation fails before the receipt rename boundary',
      );
      File(stage.resolve('candidate')).deleteSync();
      expect(StageInspector().inspect(stage).reusable, isTrue);
    });

    test('correctly named but unreceipted files are never reusable', () {
      stage.writeBytesAtomically('rk', utf8.encode('binary'));

      final result = StageInspector().inspect(stage);
      expect(result.reusable, isFalse);
      expect(
        result.issues.map((issue) => issue.kind),
        containsAll([
          StageIssueKind.missingReceipt,
          StageIssueKind.extraArtifact,
        ]),
      );
    });

    test('missing artifacts are rejected', () {
      _writeCompleteStage(stage);
      File(stage.resolve('rk')).deleteSync();

      _expectIssue(stage, StageIssueKind.missingArtifact);
    });

    test('changed bytes, size, or mode are rejected', () {
      _writeCompleteStage(stage);
      File(stage.resolve('rk')).writeAsStringSync('tampered');

      final result = StageInspector().inspect(stage);
      expect(result.reusable, isFalse);
      expect(
        result.issues
            .singleWhere(
              (issue) => issue.kind == StageIssueKind.changedArtifact,
            )
            .message,
        contains('sha256'),
      );
    });

    test('extra files and empty directories are rejected', () {
      _writeCompleteStage(stage);
      stage.writeBytesAtomically('planted.txt', utf8.encode('planted'));
      Directory(stage.resolve('empty')).createSync();

      final result = StageInspector().inspect(stage);
      expect(result.reusable, isFalse);
      expect(
        result.issues
            .where((issue) => issue.kind == StageIssueKind.extraArtifact)
            .map((issue) => issue.path),
        containsAll(['planted.txt', 'empty']),
      );
    });

    test('artifact and ancestor symlinks are rejected without following them',
        () {
      _writeCompleteStage(stage);
      File(stage.resolve('rk')).deleteSync();
      Link(stage.resolve('rk')).createSync('/private/tmp/outside');

      _expectIssue(stage, StageIssueKind.symlink);
    });

    test('a symlink in the fixed stage path is an unsafe path', () {
      final elsewhere =
          Directory.systemTemp.createTempSync('rk-stage-outside-');
      addTearDown(() => elsewhere.deleteSync(recursive: true));
      Link('${repository.path}/.rk').createSync(elsewhere.path);

      final result = StageInspector().inspect(stage);
      expect(result.reusable, isFalse);
      expect(result.issues.single.kind, StageIssueKind.unsafePath);
      expect(Directory('${elsewhere.path}/work').existsSync(), isFalse);
    });

    test('path-escaping records invalidate the receipt', () {
      final receipt = _writeCompleteStage(stage);
      final malformed = receipt.toJson();
      final steps = (malformed['steps']! as List).cast<Map<String, Object?>>();
      final outputs =
          (steps[1]['outputs']! as List).cast<Map<String, Object?>>();
      outputs.single['path'] = '../outside';
      File(stage.resolve('stage.json')).writeAsStringSync(
        '${CanonicalJson.encode(malformed)}\n',
        flush: true,
      );

      _expectIssue(stage, StageIssueKind.unsafePath);
    });

    test('incomplete receipts preserve progress but cannot be reused', () {
      stage.writeBytesAtomically('rk', utf8.encode('binary'));
      final artifact = StageArtifact.capture(
        stage: stage,
        path: 'rk',
        type: 'executable',
      );
      StageReceiptStore(stage).write(StageReceipt(
        identity: stage.identity,
        steps: [
          StageStep(name: 'build', outputs: [artifact])
        ],
      ));

      _expectIssue(stage, StageIssueKind.incompleteReceipt);
    });

    test('a signed macOS build requires a certificate SHA-256 binding', () {
      final receipt = _writeCompleteStage(stage);
      final build = receipt.steps.singleWhere(
        (step) => step.name == 'build:rk:macos-arm64',
      );
      final binary = build.outputs.single;
      final sign = StageStep(
        name: 'build:rk:macos-arm64',
        inputs: build.inputs,
        outputs: build.outputs,
        evidence: {
          'signed_smoke': {'status': 'pass', 'command': '--version'},
          'signature': {
            'certificate': 'Developer ID Application: Test (TEAM123456)',
            'code_id': 'io.example.rk',
            'unsigned_sha256': 'c' * 64,
            'signed_sha256': binary.sha256,
            'verified_after_smoke': true,
          },
        },
      );
      StageReceiptStore(stage).write(StageReceipt(
        identity: receipt.identity,
        steps: [receipt.steps.first, sign, receipt.steps.last],
      ));

      final inspected = StageInspector().inspect(stage);
      expect(inspected.reusable, isFalse);
      expect(
        inspected.issues.map((issue) => issue.kind),
        contains(StageIssueKind.invalidStructure),
      );
      expect(
        inspected.issues.map((issue) => issue.message).join('\n'),
        contains('certificate SHA-256 fingerprint'),
      );
    });

    test('a signed macOS build states whether the identity is first', () {
      final receipt = _writeCompleteStage(stage);
      final build = receipt.steps.singleWhere(
        (step) => step.name == 'build:rk:macos-arm64',
      );
      final binary = build.outputs.single;
      final sign = StageStep(
        name: 'build:rk:macos-arm64',
        inputs: build.inputs,
        outputs: build.outputs,
        evidence: {
          'signed_smoke': {'status': 'pass', 'command': '--version'},
          'signature': {
            'certificate': 'Developer ID Application: Test (TEAM123456)',
            'certificate_sha256': 'a' * 64,
            'code_id': 'io.example.rk',
            'unsigned_sha256': 'c' * 64,
            'signed_sha256': binary.sha256,
            'verified_after_smoke': true,
          },
        },
      );
      StageReceiptStore(stage).write(StageReceipt(
        identity: receipt.identity,
        steps: [receipt.steps.first, sign, receipt.steps.last],
      ));

      final inspected = StageInspector().inspect(stage);
      expect(inspected.reusable, isFalse);
      expect(
        inspected.issues.map((issue) => issue.message).join('\n'),
        contains('whether identity is first'),
      );
    });

    test('inspection is read-only and does not create an absent stage', () {
      final before = _snapshot(repository);
      final absent = StageInspector().inspect(stage);
      final afterAbsent = _snapshot(repository);

      expect(absent.reusable, isFalse);
      expect(before, afterAbsent);
      expect(Directory('${repository.path}/.rk').existsSync(), isFalse);

      _writeCompleteStage(stage);
      final beforeValid = _snapshot(repository);
      final valid = StageInspector().inspect(stage);
      final afterValid = _snapshot(repository);
      expect(valid.reusable, isTrue);
      expect(beforeValid, afterValid);
    });

    test('public manifest exposes provenance and digests, not local evidence',
        () {
      stage.writeBytesAtomically('artifacts/rk.tar.gz', utf8.encode('archive'));
      final archive = StageArtifact.capture(
        stage: stage,
        path: 'artifacts/rk.tar.gz',
        type: 'archive',
      );
      final manifest = ReleaseManifest(
        unit: 'rk',
        version: '1.2.3',
        tag: 'v1.2.3',
        commit: stage.identity.headCommit,
        artifacts: [
          ReleaseManifestArtifact.fromStage(
            publicName: 'rk-1.2.3-macos-arm64.tar.gz',
            artifact: archive,
          ),
        ],
        homebrew: ReleaseManifestHomebrew.fromStage(
          project: 'rk',
          tap: 'example/homebrew-tap',
          path: 'Formula/rk.rb',
          artifact: archive,
        ),
      );
      manifest.writeTo(stage);
      final document =
          File(stage.resolve('release-manifest.json')).readAsStringSync();
      final parsed = ReleaseManifest.parse(document);

      expect(parsed.commit, stage.identity.headCommit);
      expect(parsed.artifacts.single.sha256, archive.sha256);
      expect(parsed.homebrew!.sha256, archive.sha256);
      expect(parsed.homebrew!.path, 'Formula/rk.rb');
      expect(document, contains(_commit));
      expect(
        document,
        isNot(contains(stage.identity.planSha256)),
        reason: 'the plan is local evidence no external reader can verify',
      );
      expect(document, isNot(contains(repository.path)));
      expect(document, isNot(contains('artifacts/rk.tar.gz')));
      expect(document, isNot(contains('Developer ID')));
      expect(document, isNot(contains('notary')));
    });

    test('schema 6 cask manifests remain readable after the formula migration',
        () {
      final legacy = '${CanonicalJson.encode({
            'artifacts': <Object?>[],
            'cask': {
              'path': 'Casks/rk.rb',
              'project': 'rk',
              'sha256': 'a' * 64,
              'size': 42,
              'tap': 'example/homebrew-tap',
            },
            'schema': 6,
            'source': {'commit': _commit},
            'tag': 'v1.2.3',
            'unit': 'rk',
            'version': '1.2.3',
          })}\n';

      final parsed = ReleaseManifest.parse(legacy);
      expect(parsed.homebrew!.path, 'Casks/rk.rb');
      expect(parsed.homebrew!.sha256, 'a' * 64);
      expect(parsed.toJson()['schema'], releaseManifestSchemaVersion);
      expect(parsed.toJson(), contains('homebrew'));
      expect(parsed.toJson(), isNot(contains('cask')));
    });

    test('public artifact names cannot carry a local path', () {
      expect(
        () => ReleaseManifestArtifact(
          name: '/tmp/rk.tar.gz',
          type: 'archive',
          size: 1,
          sha256: 'a' * 64,
        ),
        throwsArgumentError,
      );
      expect(
        () => ReleaseManifestArtifact(
          name: r'..\secret',
          type: 'archive',
          size: 1,
          sha256: 'a' * 64,
        ),
        throwsArgumentError,
      );
    });
  });
}

StageIdentity _identity(Object? plan) => StageIdentity.forPlan(
      headCommit: _commit,
      headTree: _tree,
      resolvedPlan: plan,
    );

StageReceipt _writeCompleteStage(StageDirectory stage) {
  stage.writeBytesAtomically('source/pubspec.yaml', utf8.encode('name: rk\n'));
  final sourceArtifact = StageArtifact.capture(
    stage: stage,
    path: 'source/pubspec.yaml',
    type: 'source',
  );
  final sourceStep = StageStep(
    name: 'source-snapshot',
    inputs: [
      StageInput.commit(stage.identity),
      StageInput.tree(stage.identity),
      StageInput.plan(stage.identity),
    ],
    outputs: [sourceArtifact],
    evidence: {'commit': _commit, 'tree': _tree},
  );
  stage.writeBytesAtomically('rk', utf8.encode('binary'));
  final artifact = StageArtifact.capture(
    stage: stage,
    path: 'rk',
    type: 'executable',
  );
  final build = StageStep(
    name: 'build:rk:macos-arm64',
    inputs: [StageInput.step(sourceStep)],
    outputs: [artifact],
    evidence: {
      'signed_smoke': {'status': 'pass', 'command': '--version'},
      'signature': {
        'certificate': 'Developer ID Application: Test (TEAM123456)',
        'certificate_sha256': 'a' * 64,
        'first_identity': true,
        'published_requirement': null,
        'designated_requirement': 'designated => identifier "io.example.rk"',
        'code_id': 'io.example.rk',
        'unsigned_sha256': 'c' * 64,
        'signed_sha256': artifact.sha256,
        'verified_after_smoke': true,
      },
      'notary': {'status': 'accepted', 'log_sha256': 'b' * 64},
    },
  );
  ReleaseManifest(
    unit: 'rk',
    version: '1.0.0',
    tag: 'v1.0.0',
    commit: stage.identity.headCommit,
    artifacts: [
      ReleaseManifestArtifact.fromStage(
        publicName: 'rk',
        artifact: artifact,
      ),
    ],
  ).writeTo(stage);
  final manifest = StageArtifact.capture(
    stage: stage,
    path: 'release-manifest.json',
    type: 'manifest',
  );
  final receipt = StageReceipt(
    identity: stage.identity,
    steps: [
      sourceStep,
      build,
      StageStep(
        name: 'complete-stage',
        inputs: [StageInput.artifact(artifact)],
        outputs: [manifest],
        evidence: const {
          'release_assets': {'rk': 'rk'},
          'homebrew_binding': null,
        },
      ),
    ],
  );
  StageReceiptStore(stage).write(receipt);
  return receipt;
}

void _expectIssue(StageDirectory stage, StageIssueKind kind) {
  final result = StageInspector().inspect(stage);
  expect(result.reusable, isFalse);
  expect(result.issues.map((issue) => issue.kind), contains(kind));
}

Map<String, String> _snapshot(Directory root) {
  if (!root.existsSync()) return const {};
  final result = <String, String>{};
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    final relative = entity.path.substring(root.path.length + 1);
    final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      final file = File(entity.path);
      result[relative] =
          'file:${file.statSync().mode}:${base64.encode(file.readAsBytesSync())}';
    } else if (type == FileSystemEntityType.link) {
      result[relative] = 'link:${Link(entity.path).targetSync()}';
    } else {
      result[relative] = type.toString();
    }
  }
  return result;
}
