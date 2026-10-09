import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/publish_target.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/targets/catalog.dart';
import 'package:test/test.dart';

/// The unit [name] that [config] declares over [files], and its checklist.
(ResolvedUnit, Checklist) _unit(
  String name,
  String config,
  Map<String, String> files,
) {
  final diagnostics = Diagnostics();
  final resolution = Resolution.resolve(
    ReleaseConfig.parse(config, 'release.toml', diagnostics)!,
    MemorySourceTree(files),
    diagnostics,
  );
  expect(resolution, isNotNull, reason: diagnostics.found.join('\n'));
  final unit = resolution!.unit(name)!;
  return (unit, Checklist.derive(unit, resolution, diagnostics));
}

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

  test('each public step derives its target, in checklist order', () {
    final (unit, checklist) = _unit(
      'cli',
      '''
schema = 2

[release.cli]
tag = "v{version}"
homebrew_tap = "example/homebrew-tools"
publish = ["git-tag", "pub.dev", "github-release", "homebrew"]
binary_platforms = ["linux-x64"]
''',
      {
        'pubspec.yaml': '''
name: example_tool
version: 1.2.3
executables:
  tool: tool
''',
      },
    );

    expect(
      TargetCatalog.builtIn()
          .derive(unit, checklist, repository: 'example/tool')
          .map((target) => (target.kind, target.step.id)),
      [
        ('gitTag', 'cli/tag/v1.2.3'),
        ('pubDev', 'cli/pub.dev/example_tool@1.2.3'),
        ('githubRelease', 'cli/github-release/v1.2.3'),
        ('homebrew', 'cli/homebrew/example_tool/tool'),
      ],
    );
  });

  test('pub staging follows the receipt contract, not dependency order', () {
    final catalog = TargetCatalog.builtIn();
    final (unit, checklist) = _unit(
      'apps',
      '''
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
''',
      {
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
      },
    );
    final pubTargets = catalog
        .derive(unit, checklist)
        .where((target) => target.kind == 'pubDev')
        .toList();

    expect(
      pubTargets.map((target) => target.coordinate),
      ['z_core', 'a_app'],
      reason: 'the release graph keeps dependency order',
    );

    final staged = catalog.stages(unit: unit, targets: pubTargets);

    expect(
      {
        for (final target in pubTargets)
          target.coordinate: target.packageProducer,
      },
      {'a_app': 'pub-archive:a_app', 'z_core': 'pub-archive:z_core'},
    );
    for (final binding in staged) {
      expect(binding.target.packageProducer, binding.contract.name);
    }

    expect(
      staged.map((binding) => binding.target.coordinate),
      ['a_app', 'z_core'],
      reason: 'stage receipts require package-name order',
    );
  });

  test('a pub-only graph derives no Git tag target', () {
    final (unit, checklist) = _unit(
      'core',
      'schema = 2\n\n[release.core]\npublish = ["pub.dev"]\n',
      {'pubspec.yaml': 'name: example\nversion: 1.2.3\n'},
    );

    expect(
      TargetCatalog.builtIn()
          .derive(unit, checklist)
          .map((target) => target.kind),
      ['pubDev'],
    );
  });
}
