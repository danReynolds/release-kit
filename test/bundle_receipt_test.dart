import 'dart:convert';
import 'dart:io';

import 'package:rk/src/builds/binary_artifact.dart';
import 'package:rk/src/engine/file_mode.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/engine/stage_inspection.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late StageDirectory stage;
  late StageStep source;
  late List<StageArtifact> outputs;
  late Map<String, Object?> evidence;
  final artifact = BinaryArtifact.dartBundle('tool');
  const prefix = 'producers/tool/macos-arm64';

  StageArtifact write(String path, String contents, String type, String mode) {
    stage.writeBytesAtomically(path, utf8.encode(contents));
    setFileModes({stage.resolve(path): mode});
    return StageArtifact.capture(stage: stage, path: path, type: type);
  }

  void record() {
    StageReceiptStore(stage)
        .write(StageReceipt(identity: stage.identity, steps: [
      source,
      StageStep(
          name: 'build:tool:macos-arm64',
          inputs: [StageInput.step(source)],
          outputs: outputs,
          evidence: evidence),
    ]));
  }

  StageInspection inspect() => const StageInspector().inspect(stage);

  setUp(() {
    root = Directory.systemTemp.createTempSync('rk-bundle-receipt-');
    stage = StageDirectory(
        repositoryRoot: root.path,
        identity: StageIdentity.forUnboundPlan(
            runId: 'fixture', resolvedPlan: {'unit': 'tool'}));
    source = StageStep(name: 'source-snapshot', inputs: [
      StageInput.plan(stage.identity)
    ], outputs: [
      write('source/bin/tool.dart', 'void main() {}', 'source', '0644')
    ], evidence: {
      'source_binding': 'unbound'
    });
    outputs = [
      for (final file in artifact.files)
        write(
            '$prefix/${file.path}',
            file.path == BinaryArtifact.manifestName
                ? artifact.manifest
                : file.path,
            file.type,
            file.mode)
    ];
    final signatures = <String, Map<String, Object?>>{
      for (final file in artifact.signedFiles)
        file.path: {
          'first_identity': true,
          'published_requirement': null,
          'designated_requirement':
              'designated => identifier "io.example.tool${file.codeSuffix}"',
          'code_id': 'io.example.tool${file.codeSuffix}',
          'certificate': 'Developer ID Application: Fixture (TEAM123456)',
          'certificate_sha256': 'a' * 64,
          'unsigned_sha256': 'b' * 64,
          'signed_sha256': outputs
              .singleWhere((output) => output.path == '$prefix/${file.path}')
              .sha256,
          'verified_after_smoke': true,
        },
    };
    evidence = {
      'artifact': artifact.toJson(),
      'smoke': {'status': 'passed'},
      'signed_smoke': {'status': 'pass', 'command': '--version'},
      'signature': signatures[artifact.identityFile],
      'signatures': signatures,
    };
    record();
    expect(inspect().validProgress, isTrue, reason: '${inspect().issues}');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('an intact multi-file build is resumable',
      () => expect(inspect().validProgress, isTrue));
  test('a changed companion cannot reuse the signed build', () {
    File(stage.resolve('$prefix/lib/tool/app.aot'))
        .writeAsStringSync('changed');
    expect(inspect().issues.map((issue) => issue.kind),
        contains(StageIssueKind.changedArtifact));
    expect(inspect().validProgress, isFalse);
  });
  test('even a recaptured companion must match its signature digest', () {
    outputs = [
      for (final output in outputs)
        output.path.endsWith('app.aot')
            ? write(output.path, 'changed', output.type, output.mode)
            : output
    ];
    record();
    expect(inspect().issues.map((issue) => issue.message).join('\n'),
        contains('not bound to its bytes'));
  });
  test('a missing companion signature cannot claim a complete signed build',
      () {
    (evidence['signatures'] as Map).remove('lib/tool/app.aot');
    record();
    expect(inspect().issues.map((issue) => issue.message).join('\n'),
        contains('complete per-file'));
  });
  test('a companion signed by another certificate is refused', () {
    ((evidence['signatures'] as Map)['lib/tool/app.aot']
        as Map)['certificate_sha256'] = 'f' * 64;
    record();
    expect(inspect().validProgress, isFalse);
  });
  test('altering the manifest and its captured digest cannot change the layout',
      () {
    outputs = [
      for (final output in outputs)
        output.path.endsWith(BinaryArtifact.manifestName)
            ? write(output.path, BinaryArtifact.single('tool').manifest,
                output.type, output.mode)
            : output
    ];
    record();
    expect(inspect().issues.map((issue) => issue.message).join('\n'),
        contains('manifest differs'));
  });
}
