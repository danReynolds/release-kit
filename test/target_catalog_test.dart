import 'dart:io';

import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/publish_target.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/targets/catalog.dart';
import 'package:rk/src/engine/producers.dart';
import 'package:rk/src/engine/stage_contract.dart';
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
              completion: target.completionLines.join(','),
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
          completion: '',
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
          completion: 'pub.dev/packages/example_tool/versions/1.2.3',
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
          completion: '',
        ),
        (
          kind: 'homebrew',
          id: 'cli/homebrew/example_tool/tool',
          label: 'Homebrew · example/homebrew-tools',
          coordinate: 'example/homebrew-tools/Casks/tool.rb',
          version: '1.2.3',
          artifacts: 'tool.rb',
          uses: 'tool.rb bound in the release manifest',
          planNote: 'tool cask',
          completion: '',
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
          'homebrew-cask:example_tool',
          'producers/example_tool/archives/tool-1.2.3-linux-x64.tar.gz',
          'producers/example_tool/homebrew/tool.rb:cask',
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
          'StepKind.publishCask',
        ]) {
          expect(source, isNot(contains(kind)), reason: path);
        }
      }
    }
    final chain = File('lib/src/binary_chain.dart').readAsStringSync();
    expect(chain, isNot(contains("import 'destinations/")));
    expect(chain, isNot(contains('publishRelease(')));
    expect(chain, isNot(contains('updateCask(')));
    final contract =
        File('lib/src/engine/stage_contract.dart').readAsStringSync();
    expect(contract, isNot(contains("../destinations/")));
    expect(contract, isNot(contains("'pub.dev'")));
    expect(contract, isNot(contains("'github-release'")));
    expect(contract, isNot(contains("'homebrew'")));
  });
}
