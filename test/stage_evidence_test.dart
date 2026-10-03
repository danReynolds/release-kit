import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/producers.dart';
import 'package:rk/src/engine/release_stage.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/engine/stage_contract.dart';
import 'package:rk/src/engine/stage_dependencies.dart';
import 'package:rk/src/engine/stage_inspection.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:rk/src/targets/catalog.dart';
import 'package:rk/src/targets/homebrew/client.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

void main() {
  late _Fixture f;
  setUp(() => f = _Fixture());
  tearDown(() => f.root.deleteSync(recursive: true));

  test('full validation runs both callbacks after dependency decoration', () {
    final calls = <String>[];
    final declared = StageStepContract(
      'probe',
      validateEvidence: (context, step) {
        calls.add('evidence');
        expect(context.source.read('CHANGELOG.md'), 'snapshot');
        return const [
          StageIssue(StageIssueKind.invalidStructure, 'evidence finding'),
        ];
      },
      validate: (context, step) {
        calls.add('artifacts');
        expect(context.stage, same(f.stage));
        return const [
          StageIssue(StageIssueKind.invalidStructure, 'artifact finding'),
        ];
      },
    );
    final decorated = StageDependencies().decorate(declared);
    expect(decorated.validateEvidence, same(declared.validateEvidence));
    expect(decorated.validate, same(declared.validate));
    f.stage.writeBytesAtomically(
      'source/CHANGELOG.md',
      utf8.encode('snapshot'),
    );
    final contract = f.contract(local: [decorated]);
    final receipt = f.receipt([
      StageStep(name: 'source-snapshot'),
      StageStep(name: 'probe'),
    ]);
    expect(contract.validate(f.stage, receipt).map((issue) => issue.message), [
      'evidence finding',
      'artifact finding',
    ]);
    expect(calls, ['evidence', 'artifacts']);
  });

  test('notes validate from supplied source after stage cleanup', () {
    final contract = f.target('release-notes');
    final step = StageStep(
      name: contract.name,
      outputs: [_artifact('release-notes.md', 'notes', 'Portable release.')],
    );
    expect(f.evidence(contract, [step]), isEmpty);
    expect(Directory(f.stage.path).existsSync(), isFalse);
    f.source.files['CHANGELOG.md'] = '## 1.2.3\n\nChanged entry.\n';
    expect(f.evidence(contract, [step]), isNotEmpty);
  });

  test(
    'renderer commitment does not replace actual stage byte checks',
    () async {
      final contribution = StageContributionContract(
        step: f.target('release-notes'),
      );
      final release = ReleaseStage(
        unit: f.unit,
        source: f.source,
        directory: f.stage,
        repository: 'example/tool',
        enforceUnitContract: true,
        resolvedPlan: f.plan,
        targetContributions: [contribution],
      );
      release.writeProgress(const []);
      final source = f.sourceStep(await release.materializeSource());
      f.stage.writeBytesAtomically(
        'release-notes.md',
        utf8.encode('Portable release.'),
      );
      final notes = StageStep(
        name: 'release-notes',
        inputs: [StageInput.step(source)],
        outputs: [
          StageArtifact.capture(
            stage: f.stage,
            path: 'release-notes.md',
            type: 'notes',
          ),
        ],
      );
      release.writeProgress([source, notes]);
      expect(release.inspect().validProgress, isTrue);
      File(f.stage.resolve('release-notes.md')).writeAsStringSync('tampered');
      expect(f.evidence(contribution.step, [source, notes]), isEmpty);
      expect(
        release.inspect().issues.any(
          (issue) => issue.kind == StageIssueKind.changedArtifact,
        ),
        isTrue,
      );
      expect(release.inspect().validProgress, isFalse);
    },
  );

  test('formula evidence binds its rendered bytes to the archive digests', () {
    final project = f.unit.projects.single;
    const platform = 'macos-arm64';
    final archive = _artifact(
      ReleaseAssets.archivePath(project, platform),
      'archive',
      'archive',
    );
    final producer = StageStep(
      name: archiveReceiptName(project.name, platform),
      outputs: [archive],
    );
    final expected = HomebrewFormula.renderRelease(
      className: ReleaseAssets.formulaClass(project.executable!),
      version: project.version.canonical,
      repository: 'example/tool',
      tag: f.unit.tag!,
      executable: project.executable!,
      assets: {
        platform: PlatformAsset(
          name: ReleaseAssets.archiveName(
            project.executable!,
            project.version.canonical,
            platform,
          ),
          sha256: archive.sha256,
        ),
      },
    );
    final contract = f.target('homebrew-formula:tool');
    final formula = StageStep(
      name: contract.name,
      outputs: [
        _artifact(ReleaseAssets.formulaPath(project), 'formula', expected),
      ],
    );
    expect(f.evidence(contract, [producer, formula]), isEmpty);
    expect(Directory(f.stage.path).existsSync(), isFalse);
    expect(f.evidence(contract, [formula]), isNotEmpty);
    final changed = StageStep(
      name: producer.name,
      outputs: [_artifact(archive.path, archive.type, 'different archive')],
    );
    expect(f.evidence(contract, [changed, formula]), isNotEmpty);
    for (final mutation in [
      {'sha256': 'f' * 64},
      {'size': formula.outputs.single.size + 1},
    ]) {
      final changedFormula = StageStep(
        name: formula.name,
        outputs: [
          StageArtifact.fromJson({
            ...formula.outputs.single.toJson(),
            ...mutation,
          }),
        ],
      );
      expect(f.evidence(contract, [producer, changedFormula]), isNotEmpty);
    }
  });

  test(
    'notary metadata is portable but full validation still reads result and log',
    () {
      final project = f.unit.projects.single;
      const platform = 'macos-arm64';
      final resultText = jsonEncode({'status': 'Accepted', 'id': 'submission'});
      final logText = jsonEncode({'jobId': 'submission'});
      final result = _artifact(
        ReleaseAssets.notaryResultPath(project, platform),
        'notary',
        resultText,
      );
      final log = _artifact(
        ReleaseAssets.notaryLogPath(project, platform),
        'notary',
        logText,
      );
      final input = _artifact(
        ReleaseAssets.notaryInputPath(project, platform),
        'notary-input',
        'zip',
      );
      final contract = f.local(StepKind.notarize);
      final step = StageStep(
        name: contract.name,
        outputs: [result, log, input],
        evidence: {
          'notary': {
            'status': 'Accepted',
            'submission_id': 'submission',
            'result_sha256': result.sha256,
            'log_sha256': log.sha256,
          },
        },
      );
      expect(f.evidence(contract, [step]), isEmpty);
      expect(Directory(f.stage.path).existsSync(), isFalse);
      final disk = StageContractContext(
        unit: f.unit,
        repository: 'example/tool',
        sourceRoot: f.stage.resolve('source'),
        stage: f.stage,
        receipt: f.receipt([step]),
      );
      expect(
        contract.validate!(disk, step).single.kind,
        StageIssueKind.invalidNotary,
      );
      f.stage.writeBytesAtomically(result.path, utf8.encode(resultText));
      f.stage.writeBytesAtomically(log.path, utf8.encode(logText));
      expect(contract.validate!(disk, step), isEmpty);
      for (final changed in [
        (
          path: result.path,
          text: jsonEncode({'status': 'Rejected', 'id': 'submission'}),
        ),
        (path: log.path, text: jsonEncode({'jobId': 'different submission'})),
      ]) {
        f.stage.writeBytesAtomically(changed.path, utf8.encode(changed.text));
        expect(f.evidence(contract, [step]), isEmpty);
        expect(
          contract.validate!(disk, step).single.kind,
          StageIssueKind.invalidNotary,
        );
        f.stage.writeBytesAtomically(result.path, utf8.encode(resultText));
        f.stage.writeBytesAtomically(log.path, utf8.encode(logText));
      }
      final forged = StageStep(
        name: step.name,
        outputs: step.outputs,
        evidence: {
          'notary': {
            ...step.evidence['notary'] as Map,
            'result_sha256': 'f' * 64,
          },
        },
      );
      expect(
        f.evidence(contract, [forged]).single.kind,
        StageIssueKind.invalidNotary,
      );
    },
  );

  for (final kind in [StepKind.build, StepKind.archive, StepKind.buildAssets]) {
    test('${kind.name} evidence is checked without artifact files', () {
      final contract = f.local(kind);
      final good = switch (kind) {
        StepKind.build => <String, Object?>{
          'smoke': {'status': 'passed'},
          'signed_smoke': {'status': 'pass', 'command': '--version'},
          'signature': {'verified_after_smoke': true},
        },
        StepKind.archive => <String, Object?>{
          'signature': {'status': 'valid', 'scope': 'archive-extracted'},
        },
        _ => <String, Object?>{
          'command': ['dart', 'run', 'build.dart'],
        },
      };
      expect(
        f.evidence(contract, [StageStep(name: contract.name, evidence: good)]),
        isEmpty,
      );
      expect(
        f.evidence(contract, [StageStep(name: contract.name)]),
        isNotEmpty,
      );
      expect(Directory(f.stage.path).existsSync(), isFalse);
    });
  }

  test('Pub archive evidence requires the native staging marker', () {
    final contract = f.target('pub-archive:tool');
    for (final marker in [null, 'downloaded', 'staged']) {
      final step = StageStep(
        name: contract.name,
        evidence: {if (marker != null) 'package_archive': marker},
      );
      expect(f.evidence(contract, [step]).isEmpty, marker == 'staged');
    }
    expect(Directory(f.stage.path).existsSync(), isFalse);
  });
}

StageArtifact _artifact(String path, String type, String text) {
  final bytes = utf8.encode(text);
  return StageArtifact(
    path: path,
    type: type,
    mode: '0644',
    size: bytes.length,
    sha256: Sha256.hex(bytes),
  );
}

final class _Fixture {
  _Fixture() {
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse(
      source.files['release.toml']!,
      'release.toml',
      diagnostics,
    )!;
    resolution = Resolution.resolve(config, source, diagnostics)!;
    expect(diagnostics.isEmpty, isTrue, reason: '${diagnostics.found}');
    unit = resolution.units.single;
    plan = {
      'unit': {'name': unit.name, 'version': unit.version.canonical},
    };
    identity = StageIdentity.forPlan(
      headCommit: '1' * 40,
      headTree: '2' * 40,
      resolvedPlan: plan,
    );
    stage = StageDirectory(repositoryRoot: root.path, identity: identity);
    final catalog = TargetCatalog.builtIn();
    final checklist = Checklist.derive(unit, resolution, diagnostics);
    final targets = catalog.derive(unit, checklist, repository: 'example/tool');
    contributions = [
      for (final target in catalog.stages(unit: unit, targets: targets))
        target.contract,
    ];
    expect(diagnostics.isEmpty, isTrue, reason: '${diagnostics.found}');
  }

  final root = Directory.systemTemp.createTempSync('rk-stage-evidence-');
  final source = MemorySourceTree({
    'release.toml': '''
schema = 2
[release.tool]
publish = ["git-tag", "github-release", "homebrew", "pub.dev"]
binary_platforms = ["macos-arm64"]
''',
    'pubspec.yaml': '''
name: tool
version: 1.2.3
environment:
  sdk: ^3.10.4
executables:
  tool: tool
''',
    'CHANGELOG.md': '## 1.2.3\n\nPortable release.\n',
    'bin/tool.dart': 'void main() {}\n',
  });
  late final Resolution resolution;
  late final ResolvedUnit unit;
  late final Map<String, Object?> plan;
  late final StageIdentity identity;
  late final StageDirectory stage;
  late final List<StageContributionContract> contributions;

  StageReceipt receipt(List<StageStep> steps) =>
      StageReceipt(identity: identity, plan: plan, steps: steps);

  StageStepContract target(String name) =>
      contributions.singleWhere((value) => value.step.name == name).step;

  StageStepContract local(StepKind kind) => contractFor(
    unit,
    Step(
      id: 'fixture',
      kind: kind,
      unit: unit.name,
      summary: 'fixture',
      needs: const [],
      project: 'tool',
      platform: kind == StepKind.buildAssets ? null : 'macos-arm64',
    ),
  );

  StageReceiptContract contract({
    List<StageStepContract> local = const [],
    List<StageContributionContract> targets = const [],
  }) => StageReceiptContract.forUnit(
    unit: unit,
    repository: 'example/tool',
    sourceRoot: stage.resolve('source'),
    targetContributions: targets,
    localProducers: local,
  );

  List<StageIssue> evidence(
    StageStepContract contract,
    List<StageStep> steps,
  ) => contract
      .validateEvidence!(
        StageEvidenceContext(
          unit: unit,
          repository: 'example/tool',
          source: source,
          receipt: receipt(steps),
        ),
        steps.singleWhere((step) => step.name == contract.name),
      )
      .toList();

  StageStep sourceStep(List<StageArtifact> artifacts) => StageStep(
    name: 'source-snapshot',
    inputs: [
      StageInput.commit(identity),
      StageInput.tree(identity),
      StageInput.plan(identity),
    ],
    outputs: artifacts,
    evidence: {'commit': identity.headCommit, 'tree': identity.headTree},
  );
}
