import 'dart:convert';

import 'package:rk/src/builds/binary_artifact.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/engine/stage_archive.dart';
import 'package:rk/src/engine/stage_binary_evidence.dart';
import 'package:rk/src/engine/stage_inspection.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

void main() {
  test('consistent bundle and legacy single evidence needs no files', () {
    for (final fixture in [_Fixture(bundle: true), _Fixture(bundle: false)]) {
      expect(StageBinaryEvidence.validate(fixture.receipt), isEmpty);
    }
    final legacy = _Fixture(bundle: false);
    legacy.buildEvidence.remove('artifact');
    legacy.buildEvidence.remove('signatures');
    expect(StageBinaryEvidence.validate(legacy.receipt), isEmpty);
  });

  test('generic short archive names do not invent producer coordinates', () {
    final fixture = _Fixture(bundle: false);
    final archive = fixture.archive;
    final receipt = StageReceipt(
      identity: fixture.receipt.identity,
      steps: [
        StageStep(
          name: 'archive:tool-macos-arm64.tar.gz',
          outputs: archive.outputs,
          evidence: {'inventory': fixture.archiveEvidence['inventory']},
        ),
      ],
    );
    expect(StageBinaryEvidence.validate(receipt), isEmpty);
  });

  test('portable signature checks retain certificate and smoke bindings', () {
    for (final change in ['certificate', 'smoke', 'signed digest']) {
      final fixture = _Fixture(bundle: false);
      switch (change) {
        case 'certificate':
          (fixture.buildEvidence['signature'] as Map).remove(
            'certificate_sha256',
          );
        case 'smoke':
          fixture.buildEvidence.remove('signed_smoke');
        case 'signed digest':
          (fixture.buildEvidence['signature'] as Map)['signed_sha256'] =
              'f' * 64;
      }
      expect(_messages(fixture), isNotEmpty, reason: change);
    }
  });

  test(
    'bundle signatures bind each file and exactly the shipped library pins',
    () {
      for (final change in [
        'file digest',
        'missing signature',
        'pins',
        'code hash',
      ]) {
        final fixture = _Fixture(bundle: true);
        final signatures = fixture.buildEvidence['signatures'] as Map;
        final library = signatures['lib/tool/app.aot'] as Map;
        switch (change) {
          case 'file digest':
            library['signed_sha256'] = 'f' * 64;
          case 'missing signature':
            signatures.remove('lib/tool/app.aot');
          case 'pins':
            (signatures[fixture.artifact.identityFile]
                as Map)['pinned_library_cdhashes'] = [
              '6' * 40,
            ];
          case 'code hash':
            library['cdhashes'] = ['invalid'];
        }
        expect(_messages(fixture), isNotEmpty, reason: change);
      }
    },
  );

  test(
    'bundle manifest recorded size and digest must describe canonical bytes',
    () {
      for (final field in ['size', 'sha256']) {
        final fixture = _Fixture(bundle: true);
        final index = fixture.outputs.indexWhere(
          (output) => output.path.endsWith(BinaryArtifact.manifestName),
        );
        final document = fixture.outputs[index].toJson();
        document[field] = field == 'size' ? 0 : 'f' * 64;
        fixture.outputs[index] = StageArtifact.fromJson(document);
        expect(_messages(fixture), contains('manifest differs'), reason: field);
      }
    },
  );

  test('a signed bundle cannot omit a companion output', () {
    final fixture = _Fixture(bundle: true);
    fixture.outputs.removeWhere((output) => output.type == 'license');
    expect(_messages(fixture), contains('incomplete artifact inventory'));
  });

  test('archive evidence binds inputs for single and bundle layouts', () {
    for (final bundle in [false, true]) {
      final fixture = _Fixture(bundle: bundle);
      fixture.archiveInputs[0] = StageInput(
        name: fixture.archiveInputs[0].name,
        sha256: 'f' * 64,
      );
      expect(_messages(fixture), contains('differs from its producer input'));
    }
  });

  test('archive inventory sizes must match available build outputs', () {
    for (final bundle in [false, true]) {
      final fixture = _Fixture(bundle: bundle);
      final inventory = fixture.archiveEvidence['inventory'] as List;
      final executable = inventory.cast<Map>().singleWhere(
        (entry) => entry['name'] == fixture.artifact.entryPoint,
      );
      executable['size'] = (executable['size'] as int) + 1;
      expect(_messages(fixture), contains('differs from its recorded build'));
    }
  });

  test('archive inventory binds all available build output metadata', () {
    for (final change in ['missing', 'mode', 'type', 'hash']) {
      final fixture = _Fixture(bundle: false);
      final document = fixture.outputs.single.toJson();
      switch (change) {
        case 'missing':
          fixture.outputs.clear();
        case 'mode':
          document['mode'] = '0644';
          fixture.outputs[0] = StageArtifact.fromJson(document);
        case 'type':
          document['type'] = 'asset';
          fixture.outputs[0] = StageArtifact.fromJson(document);
        case 'hash':
          document['sha256'] = 'f' * 64;
          fixture.outputs[0] = StageArtifact.fromJson(document);
      }
      expect(
        _messages(fixture),
        contains('differs from its recorded build'),
        reason: change,
      );
    }
  });

  test('archive inventory rejects missing, extra and wrongly-moded files', () {
    for (final change in ['missing', 'extra', 'mode', 'layout']) {
      final fixture = _Fixture(bundle: true);
      final inventory = fixture.archiveEvidence['inventory'] as List;
      switch (change) {
        case 'missing':
          inventory.removeLast();
        case 'extra':
          inventory.add({
            'name': 'unrelated',
            'mode': '0644',
            'size': 1,
            'sha256': 'f' * 64,
          });
        case 'mode':
          (inventory.first as Map)['mode'] = '0644';
        case 'layout':
          fixture.buildEvidence['artifact'] = BinaryArtifact.single(
            'other',
          ).toJson();
      }
      expect(
        StageBinaryEvidence.validate(
          fixture.receipt,
        ).any((issue) => issue.kind == StageIssueKind.invalidArchive),
        isTrue,
        reason: change,
      );
    }
  });

  test(
    'archive manifest must match the layout even with matching build hashes',
    () {
      final fixture = _Fixture(bundle: true);
      final inventory = fixture.archiveEvidence['inventory'] as List;
      final manifest = inventory.cast<Map>().singleWhere(
        (entry) => entry['name'] == BinaryArtifact.manifestName,
      );
      manifest['sha256'] = 'f' * 64;
      final index = fixture.archiveInputs.indexWhere(
        (input) => input.name.endsWith(BinaryArtifact.manifestName),
      );
      fixture.archiveInputs[index] = StageInput(
        name: fixture.archiveInputs[index].name,
        sha256: 'f' * 64,
      );
      final outputIndex = fixture.outputs.indexWhere(
        (output) => output.path.endsWith(BinaryArtifact.manifestName),
      );
      fixture.outputs[outputIndex] = StageArtifact.fromJson({
        ...fixture.outputs[outputIndex].toJson(),
        'sha256': 'f' * 64,
      });
      expect(_messages(fixture), contains('archived bundle manifest differs'));
    },
  );

  test('macOS archive evidence names all verified files and final smoke', () {
    for (final change in ['scope', 'files', 'smoke']) {
      final fixture = _Fixture(bundle: true);
      final signature = fixture.archiveEvidence['signature'] as Map;
      signature[change] = change == 'files' ? <String>[] : 'wrong';
      expect(
        _messages(fixture),
        contains('final signature verification evidence'),
      );
    }
  });

  test('legacy inventory selects only the known bundle layout', () {
    final fixture = _Fixture(bundle: true);
    // The archive's portable proof can be checked even without build metadata.
    final receipt = StageReceipt(
      identity: fixture.receipt.identity,
      steps: [fixture.archive],
    );
    expect(StageBinaryEvidence.validate(receipt), isEmpty);
    final inventory = fixture.archiveEvidence['inventory'] as List;
    inventory.add({
      'name': 'other',
      'mode': '0755',
      'size': 1,
      'sha256': 'f' * 64,
    });
    expect(
      StageBinaryEvidence.validate(
        StageReceipt(identity: receipt.identity, steps: [fixture.archive]),
      ),
      isNotEmpty,
    );
  });
}

String _messages(_Fixture fixture) => StageBinaryEvidence.validate(
  fixture.receipt,
).map((issue) => issue.message).join('\n');

final class _Fixture {
  _Fixture({required bool bundle})
    : artifact = bundle
          ? BinaryArtifact.dartBundle('tool')
          : BinaryArtifact.single('tool') {
    outputs = [
      for (final file in artifact.files)
        StageArtifact(
          path: '$prefix/${file.path}',
          type: file.type,
          mode: file.mode,
          size: utf8
              .encode(
                file.path == BinaryArtifact.manifestName
                    ? artifact.manifest
                    : file.path,
              )
              .length,
          sha256: Sha256.hex(
            utf8.encode(
              file.path == BinaryArtifact.manifestName
                  ? artifact.manifest
                  : file.path,
            ),
          ),
        ),
    ];
    final signatures = <String, Map<String, Object?>>{
      for (final file in artifact.signedFiles)
        file.path: {
          'first_identity': true,
          'published_requirement': null,
          'designated_requirement': 'designated => ${file.path}',
          'code_id': 'io.example.tool${file.codeSuffix}',
          'certificate': 'Developer ID Application: Fixture',
          'certificate_sha256': 'a' * 64,
          'unsigned_sha256': 'b' * 64,
          'signed_sha256': outputs
              .singleWhere((o) => o.path == '$prefix/${file.path}')
              .sha256,
          'verified_after_smoke': true,
          if (file.loadedByIdentity) 'cdhashes': ['5' * 40],
          if (file.path == artifact.identityFile && bundle)
            'pinned_library_cdhashes': ['5' * 40],
        },
    };
    buildEvidence = {
      'artifact': artifact.toJson(),
      'signature': signatures[artifact.identityFile],
      'signatures': signatures,
      'signed_smoke': {'status': 'pass', 'command': '--version'},
    };
    archiveInputs = [for (final output in outputs) StageInput.artifact(output)];
    archiveEvidence = {
      'inventory': StageArchiveInventory.evidence([
        for (final output in outputs)
          StageArchiveEntry(
            name: output.path.substring(prefix.length + 1),
            mode: output.mode,
            size: output.size,
            sha256: output.sha256,
          ),
      ]),
      'signature': {
        'status': 'valid',
        'scope': 'archive-extracted',
        'smoke': 'passed',
        'files': [for (final file in artifact.signedFiles) file.path],
      },
    };
  }

  static const prefix = 'producers/tool/macos-arm64';
  final BinaryArtifact artifact;
  final buildInputs = <StageInput>[];
  late final List<StageArtifact> outputs;
  late final Map<String, Object?> buildEvidence;
  late final List<StageInput> archiveInputs;
  late final Map<String, Object?> archiveEvidence;

  StageStep get archive => StageStep(
    name: 'archive:tool:macos-arm64',
    inputs: archiveInputs,
    outputs: [
      // No payload accompanies this declaration. Pure evidence validation
      // cannot establish that an archive actually has these contents.
      StageArtifact(
        path: 'release/tool.tar.gz',
        type: 'archive',
        mode: '0644',
        size: 99,
        sha256: 'c' * 64,
      ),
    ],
    evidence: archiveEvidence,
  );
  StageReceipt get receipt => StageReceipt(
    identity: StageIdentity.forUnboundPlan(
      runId: 'binary-proof',
      resolvedPlan: {'unit': 'tool'},
    ),
    steps: [
      StageStep(
        name: 'build:tool:macos-arm64',
        inputs: buildInputs,
        outputs: outputs,
        evidence: buildEvidence,
      ),
      archive,
    ],
  );
}
