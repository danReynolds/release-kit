import 'dart:io';

import 'package:release_kit/src/engine/checklist.dart';
import 'package:release_kit/src/engine/config.dart';
import 'package:release_kit/src/engine/diagnostic.dart';
import 'package:release_kit/src/engine/resolve.dart';
import 'package:release_kit/src/engine/source_tree.dart';
import 'package:release_kit/src/engine/targets.dart';
import 'package:release_kit/src/targets/catalog.dart';
import 'package:release_kit/src/engine/stage_contract.dart';
import 'package:test/test.dart';

void main() {
  test('the closed catalog covers every public target exactly once', () {
    final catalog = TargetCatalog.builtIn();

    expect(
      catalog.modules.map((module) => module.stepKind),
      TargetCatalog.targetStepKinds,
    );
    expect(
      catalog.modules.map((module) => module.kind),
      ReleaseTargetKind.values,
    );
    expect(
      TargetCatalog.targetStepKinds,
      StepKind.values.where((kind) => kind.phase == StepPhase.publish).toSet(),
    );
  });

  test('a missing or duplicated target module is refused at construction', () {
    final modules = TargetCatalog.builtIn().modules;

    expect(() => TargetCatalog(modules.take(3)), throwsArgumentError);
    expect(
      () => TargetCatalog([...modules, modules.first]),
      throwsArgumentError,
    );
  });

  test('built-in modules preserve target identity, artifacts, and order', () {
    final catalog = TargetCatalog.builtIn();
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse('''
schema = 1

[release.cli]
tag = "v{version}"
homebrew_tap = "example/homebrew-tools"
publish = ["pub.dev", "github-release", "homebrew"]
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
      unit.projects.expand((project) => project.channels).toSet(),
      ReleaseConfig.channels,
      reason: 'the fixture must exercise every accepted publish channel',
    );
    expect(
      targets.map((target) => target.kind).toSet(),
      ReleaseTargetKind.values.toSet(),
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
            catalog.moduleForTarget(target).isPermanent,
            catalog.moduleForTarget(target).permanenceNotice(target) != null,
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
            ),
          )
          .toList(),
      [
        (
          kind: ReleaseTargetKind.gitTag,
          id: 'cli/tag/v1.2.3',
          label: 'Git tag',
          coordinate: 'v1.2.3',
          version: '1.2.3',
          artifacts: '',
          uses: 'release-manifest.json from GitHub Release',
        ),
        (
          kind: ReleaseTargetKind.pubDev,
          id: 'cli/pub.dev/example_tool@1.2.3',
          label: 'pub.dev · example_tool',
          coordinate: 'example_tool',
          version: '1.2.3',
          artifacts: '',
          uses: null,
        ),
        (
          kind: ReleaseTargetKind.githubRelease,
          id: 'cli/github-release/v1.2.3',
          label: 'GitHub Release · example/tool',
          coordinate: 'example/tool/releases/tag/v1.2.3',
          version: '1.2.3',
          artifacts: 'SHA256SUMS,release-manifest.json,'
              'tool-1.2.3-linux-x64.tar.gz,tool.rb',
          uses: null,
        ),
        (
          kind: ReleaseTargetKind.homebrew,
          id: 'cli/homebrew/tool',
          label: 'Homebrew · example/homebrew-tools',
          coordinate: 'example/homebrew-tools/Formula/tool.rb',
          version: '1.2.3',
          artifacts: '',
          uses: 'tool.rb from GitHub Release',
        ),
      ],
    );

    final contributions = catalog.stageBindings(
      unit: unit,
      targets: targets,
      repository: 'example/tool',
      sourceRoot: '/stage/source',
    );
    expect(
      contributions
          .map((binding) => (
                binding.contract.phase,
                binding.contract.step.name,
                binding.contract.step.inputs.join(','),
                binding.contract.step.outputs.entries
                    .map((entry) => '${entry.key}:${entry.value}')
                    .join(','),
              ))
          .toList(),
      [
        (
          StageContributionPhase.sourcePreflight,
          'pub-preflight:example_tool',
          'step:source-snapshot',
          '',
        ),
        (
          StageContributionPhase.beforeProducers,
          'release-notes',
          'step:source-snapshot',
          'release-notes.md:notes',
        ),
        (
          StageContributionPhase.afterProducers,
          'homebrew-formula',
          'tool-1.2.3-linux-x64.tar.gz',
          'tool.rb:formula',
        ),
      ],
    );
  });

  test('pub staging follows the receipt contract, not dependency order', () {
    final catalog = TargetCatalog.builtIn();
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse('''
schema = 1

[release.apps]
tag = "apps-v{version}"

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
        .where((target) => target.kind == ReleaseTargetKind.pubDev)
        .toList();

    expect(
      pubTargets.map((target) => target.coordinate),
      ['z_core', 'a_app'],
      reason: 'the release graph keeps dependency order',
    );

    final staged = catalog.stageBindings(
      unit: unit,
      targets: pubTargets,
      repository: null,
      sourceRoot: '/stage/source',
    );

    expect(
      staged.map((binding) => binding.target.coordinate),
      ['a_app', 'z_core'],
      reason: 'stage receipts require package-name order',
    );
  });

  test('stage contribution inputs determine stable execution order', () {
    const notes = StageContributionContract(
      phase: StageContributionPhase.beforeProducers,
      step: StageStepContract(
        'z-release-notes',
        outputs: {'release-notes.md': 'notes'},
      ),
    );
    const upload = StageContributionContract(
      phase: StageContributionPhase.beforeProducers,
      step: StageStepContract(
        'a-upload-notes',
        inputs: {'release-notes.md'},
      ),
    );
    const independent = StageContributionContract(
      phase: StageContributionPhase.beforeProducers,
      step: StageStepContract('b-independent'),
    );

    expect(
      orderStageContributions(
        const [upload, independent, notes],
        (contract) => contract,
      ).map((contract) => contract.step.name),
      const ['b-independent', 'z-release-notes', 'a-upload-notes'],
    );

    const left = StageContributionContract(
      phase: StageContributionPhase.beforeProducers,
      step: StageStepContract(
        'left',
        inputs: {'right.txt'},
        outputs: {'left.txt': 'test'},
      ),
    );
    const right = StageContributionContract(
      phase: StageContributionPhase.beforeProducers,
      step: StageStepContract(
        'right',
        inputs: {'left.txt'},
        outputs: {'right.txt': 'test'},
      ),
    );
    expect(
      () => orderStageContributions(
        const [left, right],
        (contract) => contract,
      ),
      throwsStateError,
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
