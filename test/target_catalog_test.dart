import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/publish_target.dart';
import 'package:rk/src/engine/release_manifest.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/targets/catalog.dart';
import 'package:rk/src/engine/producers.dart';
import 'package:rk/src/engine/stage_contract.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/targets/target_module.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

void main() {
  test('the closed catalog covers every public target exactly once', () {
    final catalog = TargetCatalog.builtIn();

    expect(
      catalog.modules.map((module) => module.target).toSet(),
      PublishTarget.values.toSet(),
    );
    expect(
      TargetCatalog.targetStepKinds,
      StepKind.values.where((kind) => kind.phase == StepPhase.publish).toSet(),
    );
  });

  test('built-in modules preserve target identity, artifacts, and order', () {
    final catalog = TargetCatalog.builtIn();
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse('''
schema = 2

[release.cli]
tag = "v{version}"
homebrew_tap = "example/homebrew-tools"
publish = ["git-tag", "pub.dev", "github-release", "homebrew"]
binary_platforms = ["linux-x64"]
''', 'release.toml', diagnostics)!;
    final resolution = Resolution.resolve(
      config,
      MemorySourceTree({
        'pubspec.yaml': '''
name: example_tool
version: 1.2.3
executables:
  tool: tool
''',
      }),
      diagnostics,
    );
    expect(resolution, isNotNull, reason: diagnostics.found.join('\n'));
    final unit = resolution!.unit('cli')!;
    final checklist = Checklist.derive(unit, resolution, diagnostics);

    final targets = catalog.derive(
      unit,
      checklist,
      repository: 'example/tool',
    );

    expect(
      {
        ...unit.publish,
        ...unit.projects.expand((project) => project.publish),
      },
      PublishTarget.values.toSet(),
      reason: 'the fixture must exercise every accepted publish target',
    );
    expect(
      targets.map((target) => target.kind).toSet(),
      {'gitTag', 'pubDev', 'githubRelease', 'homebrew'},
      reason: 'every accepted channel must emit its catalog target',
    );
    expect(
      targets.map((target) => target.step.id),
      checklist.steps.where((step) => step.isPublic).map((step) => step.id),
    );
    for (final target in targets) {
      expect(
        catalog.moduleForStep(target.step),
        same(catalog.moduleForTarget(target)),
      );
      final conflict = catalog.moduleForTarget(target).diagnoseConflict(
            unit,
            target,
            const Inspection.conflict('provider state differs'),
          );
      expect(conflict.message, contains(target.label));
      expect(conflict.remedy, isNotEmpty);
      expect(conflict.remedy, isNot(contains('push -f')));
      expect(conflict.remedy, isNot(contains('force-push')));
    }
    expect(
      [
        for (final target in targets)
          (
            target.step.isPermanent,
            target.permanenceNotice != null,
          ),
      ],
      const [(false, false), (true, true), (false, false), (false, false)],
    );

    expect(
      targets
          .map(
            (target) => (
              kind: target.kind,
              id: target.step.id,
              label: target.label,
              coordinate: target.coordinate,
              version: target.targetVersion,
              artifacts: target.artifacts.join(','),
              uses: target.uses,
              planNote: target.planNote,
            ),
          )
          .toList(),
      [
        (
          kind: 'gitTag',
          id: 'cli/tag/v1.2.3',
          label: 'Git tag',
          coordinate: 'v1.2.3',
          version: '1.2.3',
          artifacts: '',
          uses: 'release-manifest.json from GitHub Release',
          planNote: 'v1.2.3',
        ),
        (
          kind: 'pubDev',
          id: 'cli/pub.dev/example_tool@1.2.3',
          label: 'pub.dev · example_tool',
          coordinate: 'example_tool',
          version: '1.2.3',
          artifacts: '',
          uses: null,
          planNote: 'example_tool 1.2.3',
        ),
        (
          kind: 'githubRelease',
          id: 'cli/github-release/v1.2.3',
          label: 'GitHub Release · example/tool',
          coordinate: 'example/tool/releases/tag/v1.2.3',
          version: '1.2.3',
          artifacts: 'release-manifest.json,'
              'tool-1.2.3-linux-x64.tar.gz',
          uses: null,
          planNote: '2 assets to example/tool/releases/tag/v1.2.3',
        ),
        (
          kind: 'homebrew',
          id: 'cli/homebrew/example_tool/tool',
          label: 'Homebrew · example/homebrew-tools',
          coordinate: 'example/homebrew-tools/Formula/tool.rb',
          version: '1.2.3',
          artifacts: 'tool.rb',
          uses: 'tool.rb bound in the release manifest',
          planNote: 'tool formula',
        ),
      ],
    );

    final contributions = catalog.stages(
      unit: unit,
      targets: targets,
    );
    expect(
      contributions
          .map((binding) => (
                binding.contract.step.name,
                binding.contract.step.inputs.join(','),
                binding.contract.step.outputs.entries
                    .map((entry) => '${entry.key}:${entry.value}')
                    .join(','),
              ))
          .toList(),
      [
        (
          'homebrew-formula:example_tool',
          'producers/example_tool/archives/tool-1.2.3-linux-x64.tar.gz',
          'producers/example_tool/homebrew/tool.rb:formula',
        ),
        (
          'pub-archive:example_tool',
          'step:source-snapshot',
          'producers/example_tool/pub/example_tool-1.2.3.tar.gz:pub-archive',
        ),
        (
          'release-notes',
          'step:source-snapshot',
          'release-notes.md:notes',
        ),
      ],
    );

    expect(
      () => StageReceiptContract.forUnit(
        unit: unit,
        repository: 'example/tool',
        sourceRoot: '/stage/source',
        targetContributions: const [
          StageContributionContract(
            step: StageStepContract(
              'bad-target',
              outputs: {ReleaseAssets.manifest: 'wrong'},
            ),
          ),
        ],
        localProducers: localProducerContracts(unit),
      ),
      throwsStateError,
      reason: 'a target cannot claim a core stage artifact',
    );
  });

  test('Homebrew verifies historical renderer bytes from the bound manifest',
      () async {
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse('''
schema = 2

[release.cli]
tag = "v{version}"
homebrew_tap = "example/homebrew-tools"
publish = ["git-tag", "github-release", "homebrew"]
binary_platforms = ["linux-x64"]
''', 'release.toml', diagnostics)!;
    final resolution = Resolution.resolve(
      config,
      MemorySourceTree({
        'pubspec.yaml': '''
name: example_tool
version: 1.2.3
executables:
  tool: tool
''',
      }),
      diagnostics,
    )!;
    final unit = resolution.unit('cli')!;
    final project = unit.project('example_tool');
    final archive = ReleaseAssets.archiveName('tool', '1.2.3', 'linux-x64');
    final historicalFormula = utf8.encode('''
# Generated by rk. Do not edit by hand.
class Tool < Formula
  version "1.2.3"
end
''');
    const releasedCommit = '1111111111111111111111111111111111111111';
    const currentCommit = '2222222222222222222222222222222222222222';
    const tagObject = '3333333333333333333333333333333333333333';
    final manifest = ReleaseManifest(
      unit: unit.name,
      version: unit.version.canonical,
      tag: 'v1.2.3',
      commit: releasedCommit,
      artifacts: [
        ReleaseManifestArtifact(
          name: archive,
          type: 'archive',
          size: 7,
          sha256: 'a' * 64,
        ),
      ],
      homebrew: ReleaseManifestHomebrew(
        project: project.name,
        tap: 'example/homebrew-tools',
        path: 'Formula/tool.rb',
        size: historicalFormula.length,
        sha256: Sha256.hex(historicalFormula),
      ),
    );
    final manifestBytes = utf8.encode(manifest.encode());
    final tools = _HistoricalFormulaTools(
      formulaBytes: historicalFormula,
      manifestBytes: manifestBytes,
      archive: archive,
      tagObject: tagObject,
      releasedCommit: releasedCommit,
    );
    final catalog = TargetCatalog.builtIn();
    final target = catalog
        .derive(
          unit,
          Checklist.derive(unit, resolution, diagnostics),
          repository: 'example/tool',
        )
        .singleWhere((target) => target.target == PublishTarget.homebrew);

    final inspected = await catalog.moduleForTarget(target).inspectCandidate(
          TargetReadContext(
            registry: null,
            pubDev: null,
            git: GitState(
              root: '/repo',
              head: currentCommit,
              branch: 'main',
              isClean: true,
              uncommitted: const [],
              headIsPushed: true,
              tags: const ['v1.2.3'],
              tagObjects: const {'v1.2.3': tagObject},
              tagTargets: const {'v1.2.3': releasedCommit},
              signingConfigured: false,
              originUrl: 'example/tool',
            ),
            tools: tools,
            repository: 'example/tool',
            stageFor: null,
          ),
          unit,
          target,
        );

    expect(inspected.verdict, Verdict.exact, reason: inspected.detail);
    expect(tools.manifestDownloads, 1);
    expect(
      tools.archiveDownloads,
      0,
      reason: 'an already-published Formula is checked against historical '
          'manifest evidence, not reconstructed by the current renderer',
    );
  });

  test('pub staging follows the receipt contract, not dependency order', () {
    final catalog = TargetCatalog.builtIn();
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse('''
schema = 2

[release.apps]
tag = "apps-v{version}"
publish = ["git-tag"]

[[release.apps.project]]
path = "packages/a_app"
publish = ["pub.dev"]

[[release.apps.project]]
path = "packages/z_core"
publish = ["pub.dev"]
''', 'release.toml', diagnostics)!;
    final resolution = Resolution.resolve(
      config,
      MemorySourceTree({
        'packages/a_app/pubspec.yaml': '''
name: a_app
version: 1.2.3
dependencies:
  z_core: ^1.2.3
''',
        'packages/z_core/pubspec.yaml': '''
name: z_core
version: 1.2.3
''',
      }),
      diagnostics,
    );
    expect(resolution, isNotNull, reason: diagnostics.found.join('\n'));
    final unit = resolution!.unit('apps')!;
    final checklist = Checklist.derive(unit, resolution, diagnostics);
    final pubTargets = catalog
        .derive(unit, checklist)
        .where((target) => target.kind == 'pubDev')
        .toList();

    expect(
      pubTargets.map((target) => target.coordinate),
      ['z_core', 'a_app'],
      reason: 'the release graph keeps dependency order',
    );

    final staged = catalog.stages(
      unit: unit,
      targets: pubTargets,
    );

    expect(
      staged.map((binding) => binding.target.coordinate),
      ['a_app', 'z_core'],
      reason: 'stage receipts require package-name order',
    );
  });

  test('a pub-only graph derives no Git tag target', () {
    final catalog = TargetCatalog.builtIn();
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse('''
schema = 2

[release.core]
publish = ["pub.dev"]
''', 'release.toml', diagnostics)!;
    final resolution = Resolution.resolve(
      config,
      MemorySourceTree({
        'pubspec.yaml': 'name: example\nversion: 1.2.3\n',
      }),
      diagnostics,
    );
    expect(resolution, isNotNull, reason: diagnostics.found.join('\n'));
    final unit = resolution!.unit('core')!;
    final checklist = Checklist.derive(unit, resolution, diagnostics);

    expect(
      catalog.derive(unit, checklist).map((target) => target.kind),
      ['pubDev'],
    );
  });

  test('stage contributions have simple stable order and unique claims', () {
    const z = StageContributionContract(
      step: StageStepContract('z-before'),
    );
    const a = StageContributionContract(
      step: StageStepContract('a-before'),
    );
    const after = StageContributionContract(
      step: StageStepContract('after'),
    );
    expect(
      orderStageContributions(
        const [after, z, a],
        (contract) => contract,
      ).map((contract) => contract.step.name),
      const ['a-before', 'after', 'z-before'],
    );

    const duplicateOutputA = StageContributionContract(
      step: StageStepContract(
        'first',
        outputs: {'same.txt': 'test'},
      ),
    );
    const duplicateOutputB = StageContributionContract(
      step: StageStepContract(
        'second',
        outputs: {'same.txt': 'test'},
      ),
    );
    expect(
      () => orderStageContributions(
        const [duplicateOutputA, duplicateOutputB],
        (contract) => contract,
      ),
      throwsStateError,
    );

    const producer = StageContributionContract(
      step: StageStepContract(
        'producer',
        outputs: {'shared.txt': 'test'},
      ),
    );
    const consumer = StageContributionContract(
      step: StageStepContract(
        'consumer',
        inputs: {'shared.txt'},
      ),
    );
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse('''
schema = 2

[release.example]
publish = ["pub.dev"]
''', 'release.toml', diagnostics)!;
    final resolution = Resolution.resolve(
      config,
      MemorySourceTree({
        'pubspec.yaml': 'name: example\nversion: 1.0.0\n',
      }),
      diagnostics,
    )!;
    final contract = StageReceiptContract.forUnit(
      unit: resolution.unit('example')!,
      repository: null,
      sourceRoot: '/stage/source',
      targetContributions: const [consumer, producer],
      localProducers: const [],
    );
    expect(
      contract.producerNames,
      ['source-snapshot', 'producer', 'consumer', 'complete-stage'],
      reason: 'artifact inputs are dependency edges, not lifecycle phases',
    );

    const missingInput = StageContributionContract(
      step: StageStepContract(
        'broken-consumer',
        inputs: {'missing.txt'},
      ),
    );
    expect(
      () => StageReceiptContract.forUnit(
        unit: resolution.unit('example')!,
        repository: null,
        sourceRoot: '/stage/source',
        targetContributions: const [missingInput],
        localProducers: const [],
      ),
      throwsA(
        isA<StateError>().having(
          (error) => '$error',
          'message',
          contains('needs unknown artifact "missing.txt"'),
        ),
      ),
    );
  });

  test('commands coordinate targets without provider branches', () {
    for (final path in [
      'lib/src/commands/status.dart',
      'lib/src/commands/release.dart',
      'lib/src/engine/inspect.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains("../destinations/")), reason: path);
      expect(source, isNot(contains('ReleaseTargetKind.')), reason: path);
      if (path.contains('/commands/')) {
        for (final kind in const [
          'StepKind.tag',
          'StepKind.publishRegistry',
          'StepKind.publishRelease',
          'StepKind.publishHomebrew',
        ]) {
          expect(source, isNot(contains(kind)), reason: path);
        }
      }
    }
    final chain = File('lib/src/binary_chain.dart').readAsStringSync();
    expect(chain, isNot(contains("import 'destinations/")));
    expect(chain, isNot(contains('publishRelease(')));
    expect(chain, isNot(contains('updateFormula(')));
    final contract =
        File('lib/src/engine/stage_contract.dart').readAsStringSync();
    expect(contract, isNot(contains("../destinations/")));
    expect(contract, isNot(contains("'pub.dev'")));
    expect(contract, isNot(contains("'github-release'")));
    expect(contract, isNot(contains("'homebrew'")));
  });
}

final class _HistoricalFormulaTools implements Tools {
  _HistoricalFormulaTools({
    required this.formulaBytes,
    required this.manifestBytes,
    required this.archive,
    required this.tagObject,
    required this.releasedCommit,
  });

  final List<int> formulaBytes;
  final List<int> manifestBytes;
  final String archive;
  final String tagObject;
  final String releasedCommit;
  var manifestDownloads = 0;
  var archiveDownloads = 0;

  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    if (executable == 'gh' &&
        arguments.join(' ') ==
            'api repos/example/homebrew-tools/contents/Formula/tool.rb') {
      return _ok(jsonEncode({'content': base64Encode(formulaBytes)}));
    }
    if (executable == 'git' && arguments.first == 'ls-remote') {
      return _ok('$tagObject refs/tags/v1.2.3\n'
          '$releasedCommit refs/tags/v1.2.3^{}\n');
    }
    if (executable == 'git' && arguments.first == 'cat-file') {
      return _ok('object $releasedCommit\n'
          'type commit\n'
          'tag v1.2.3\n\n'
          'cli 1.2.3\n\n'
          'release-manifest-sha256: ${Sha256.hex(manifestBytes)}\n');
    }
    if (executable == 'gh' &&
        arguments.join(' ') == 'api repos/example/tool/releases/tags/v1.2.3') {
      return _ok(jsonEncode({
        'tag_name': 'v1.2.3',
        'draft': false,
        'prerelease': false,
        'id': 7,
        'assets': [
          {'name': archive, 'digest': 'sha256:${'a' * 64}'},
          {
            'name': ReleaseAssets.manifest,
            'digest': 'sha256:${Sha256.hex(manifestBytes)}',
          },
        ],
      }));
    }
    if (executable == 'gh' &&
        arguments.length >= 2 &&
        arguments[0] == 'release' &&
        arguments[1] == 'download') {
      final name = arguments[arguments.indexOf('--pattern') + 1];
      final output = arguments[arguments.indexOf('--output') + 1];
      if (name == ReleaseAssets.manifest) {
        manifestDownloads++;
        File(output).writeAsBytesSync(manifestBytes);
      } else {
        archiveDownloads++;
      }
      return _ok('');
    }
    return ToolResult(
      exitCode: 127,
      stdout: '',
      stderr: 'not scripted: $executable ${arguments.join(' ')}',
    );
  }

  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async =>
      0;

  ToolResult _ok(String stdout) =>
      ToolResult(exitCode: 0, stdout: stdout, stderr: '');
}
