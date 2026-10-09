import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/publish_target.dart';
import 'package:rk/src/engine/release_dependencies.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/unit_release.dart';
import 'package:rk/src/targets/catalog.dart';
import 'package:test/test.dart';

Resolution resolve(String config, MemorySourceTree tree) {
  final diagnostics = Diagnostics();
  final parsed = ReleaseConfig.parse(config, 'release.toml', diagnostics)!;
  final resolution = Resolution.resolve(parsed, tree, diagnostics);
  expect(resolution, isNotNull, reason: diagnostics.found.join('\n'));
  return resolution!;
}

/// [unit]'s release, as every command derives it.
UnitRelease derive(
  ResolvedUnit unit,
  Resolution resolution, {
  Diagnostics? problems,
  String? repository,
}) => UnitRelease.derive(
  unit,
  resolution,
  repository: repository,
  problems: problems ?? Diagnostics(),
);

List<String> ids(Iterable<Step> steps) => [for (final step in steps) step.id];

final keybayTree = MemorySourceTree({
  'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
  'packages/keybay_cli/pubspec.yaml': '''
name: keybay_cli
version: 0.2.0
dependencies:
  keybay: 0.2.0
executables:
  keybay: keybay
''',
});

const keybayConfig = '''
schema = 2

[release.core]
tag = "keybay-v{version}"
path = "packages/keybay"
publish = ["git-tag", "pub.dev"]

[release.cli]
tag = "keybay_cli-v{version}"
path = "packages/keybay_cli"
publish = ["git-tag", "pub.dev", "github-release", "homebrew"]
binary_platforms = ["linux-x64", "linux-arm64", "macos-arm64"]
''';

void main() {
  group('schema 2 tag dependency rules', () {
    final tree = MemorySourceTree({
      'pubspec.yaml': 'name: example\nversion: 1.2.3\n',
    });

    test('a pub-only unit has no tag graph', () {
      final resolution = resolve('''
schema = 2

[release.core]
publish = ["pub.dev"]
''', tree);
      final unit = resolution.unit('core')!;
      final release = derive(unit, resolution);

      expect(unit.tag, isNull);
      expect(release.steps.map((step) => step.id), [
        'core/stage/complete',
        'core/pub.dev/example@1.2.3',
      ]);
      expect(ids(release.step('core/pub.dev/example@1.2.3')!.needs), [
        'core/stage/complete',
      ]);
    });

    test('an explicit tag sits between stage and registry publication', () {
      final resolution = resolve('''
schema = 2

[release.core]
tag = "release-v{version}"
publish = ["git-tag", "pub.dev"]
''', tree);
      final unit = resolution.unit('core')!;
      final release = derive(unit, resolution);

      expect(unit.tag, 'release-v1.2.3');
      expect(release.steps.map((step) => step.id), [
        'core/stage/complete',
        'core/tag/release-v1.2.3',
        'core/pub.dev/example@1.2.3',
      ]);
      expect(ids(release.step('core/tag/release-v1.2.3')!.needs), [
        'core/stage/complete',
      ]);
      expect(ids(release.step('core/pub.dev/example@1.2.3')!.needs), [
        'core/tag/release-v1.2.3',
      ]);
    });

    test('a metadata-only GitHub release has notes and a manifest', () {
      final resolution = resolve('''
schema = 2

[release.core]
publish = ["git-tag", "github-release"]
''', tree);
      final unit = resolution.unit('core')!;
      final release = derive(unit, resolution);

      expect(release.steps.map((step) => step.id), [
        'core/stage/complete',
        'core/tag/v1.2.3',
        'core/github-release/v1.2.3',
      ]);
    });

    test('a prerelease publishes GitHub assets without advancing Homebrew', () {
      final prereleaseTree = MemorySourceTree({
        'pubspec.yaml': '''
name: example
version: 1.3.0-beta.1
executables:
  example: example
''',
      });
      final resolution = resolve('''
schema = 2

[release.cli]
publish = ["git-tag", "github-release", "homebrew"]
binary_platforms = ["linux-x64"]
''', prereleaseTree);
      final unit = resolution.unit('cli')!;
      final release = derive(unit, resolution);
      final ids = release.steps.map((step) => step.id).toList();

      expect(ids, contains('cli/github-release/v1.3.0-beta.1'));
      expect(ids.where((id) => id.contains('/homebrew/')), isEmpty);
    });
  });

  test('a unit refuses several standalone producers', () {
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse(
      '''
schema = 2

[release.tools]
tag = "tools-v{version}"
publish = ["git-tag", "github-release"]

[[release.tools.project]]
path = "packages/server"
binary_platforms = ["linux-x64"]

[[release.tools.project]]
path = "packages/admin"
binary_platforms = ["linux-x64"]
''',
      'release.toml',
      diagnostics,
    )!;
    final resolution = Resolution.resolve(
      config,
      MemorySourceTree({
        'packages/server/pubspec.yaml': '''
name: server_cli
version: 1.0.0
executables:
  server: server
''',
        'packages/admin/pubspec.yaml': '''
name: admin_cli
version: 1.0.0
executables:
  admin: admin
''',
      }),
      diagnostics,
    );

    expect(resolution, isNull);
    expect(diagnostics.found.single.code, 'RK-RES-009');
  });

  test('the checklist names every step the same way, in order', () {
    // Step ids are what a --json caller keys on, run after run.
    final resolution = resolve(keybayConfig, keybayTree);
    final release = derive(resolution.unit('cli')!, resolution);

    expect(release.steps.map((s) => s.id).toList(), [
      'cli/requires/pub.dev/keybay/0.2.0',
      'cli/build/keybay_cli/linux-arm64',
      'cli/archive/keybay_cli/linux-arm64',
      'cli/build/keybay_cli/linux-x64',
      'cli/archive/keybay_cli/linux-x64',
      'cli/build/keybay_cli/macos-arm64',
      'cli/notarize/keybay_cli/macos-arm64',
      'cli/archive/keybay_cli/macos-arm64',
      'cli/stage/complete',
      'cli/tag/keybay_cli-v0.2.0',
      'cli/pub.dev/keybay_cli@0.2.0',
      'cli/github-release/keybay_cli-v0.2.0',
      'cli/homebrew/keybay_cli/keybay',
    ]);
  });

  test('notarization sits between the signed build and its archive', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final release = derive(resolution.unit('cli')!, resolution);

    expect(
      release.step('cli/build/keybay_cli/macos-arm64')!.summary,
      contains('build and sign'),
      reason: 'compiling and signing are one build step',
    );
    expect(ids(release.step('cli/notarize/keybay_cli/macos-arm64')!.needs), [
      'cli/build/keybay_cli/macos-arm64',
    ]);
    expect(ids(release.step('cli/archive/keybay_cli/macos-arm64')!.needs), [
      'cli/notarize/keybay_cli/macos-arm64',
    ]);
    expect(
      ids(release.step('cli/archive/keybay_cli/linux-x64')!.needs),
      ['cli/build/keybay_cli/linux-x64'],
      reason: 'a Linux archive follows its build directly',
    );
  });

  test('the complete-stage barrier waits for every local producer', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final release = derive(resolution.unit('cli')!, resolution);
    final producers = release.steps
        .where(
          (step) => const {
            StepKind.build,
            StepKind.notarize,
            StepKind.archive,
          }.contains(step.kind),
        )
        .map((step) => step.id)
        .toList();

    expect(ids(release.step('cli/stage/complete')!.needs), producers);
    expect(
      ids(release.step('cli/github-release/keybay_cli-v0.2.0')!.needs),
      ['cli/tag/keybay_cli-v0.2.0'],
      reason: 'the tag already carries the complete-stage dependency',
    );
  });

  test('every public act transitively depends on the complete stage', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final release = derive(resolution.unit('cli')!, resolution);
    const barrier = 'cli/stage/complete';

    for (final step in release.steps.where((step) => step.isPublic)) {
      expect(
        _transitivelyNeeds(step, barrier),
        isTrue,
        reason: '${step.id} can act publicly without $barrier',
      );
    }
  });

  test('the explicit safety phases never move backwards', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final release = derive(resolution.unit('cli')!, resolution);
    var phase = StepPhase.inspect;
    for (final step in release.steps) {
      expect(
        step.phase.index,
        greaterThanOrEqualTo(phase.index),
        reason:
            '${step.id} moved from ${phase.name} back to '
            '${step.phase.name}',
      );
      phase = step.phase;
    }
    expect(release.step('cli/stage/complete')!.phase, StepPhase.stage);
    expect(release.step('cli/tag/keybay_cli-v0.2.0')!.phase, StepPhase.publish);
  });

  test('every step waits only on steps listed before it', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final release = derive(resolution.unit('cli')!, resolution);
    final all = ids(release.steps);
    expect(all.toSet(), hasLength(all.length), reason: 'ids are unique');
    for (final (index, step) in release.steps.indexed) {
      for (final need in step.needs) {
        expect(
          all.indexOf(need.id),
          inInclusiveRange(0, index - 1),
          reason: '${step.id} needs $need',
        );
      }
    }
  });

  test('the formula waits for the release to be public', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final release = derive(resolution.unit('cli')!, resolution);
    expect(ids(release.step('cli/homebrew/keybay_cli/keybay')!.needs), [
      'cli/github-release/keybay_cli-v0.2.0',
    ]);
  });

  test('permanent and public steps are marked', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final release = derive(resolution.unit('cli')!, resolution);

    expect(release.step('cli/pub.dev/keybay_cli@0.2.0')!.isPermanent, isTrue);
    expect(
      release.step('cli/build/keybay_cli/linux-x64')!.isPermanent,
      isFalse,
    );
    expect(release.step('cli/build/keybay_cli/linux-x64')!.isPublic, isFalse);
    expect(release.step('cli/homebrew/keybay_cli/keybay')!.isPublic, isTrue);
    expect(
      release.step('cli/homebrew/keybay_cli/keybay')!.isPermanent,
      isFalse,
      reason: 'a formula moves forward again; a published version cannot',
    );
  });

  group('within a unit, a dependency publishes first', () {
    final tree = MemorySourceTree({
      'packages/fleury/pubspec.yaml': 'name: fleury\nversion: 0.1.0\n',
      'packages/fleury_test/pubspec.yaml': '''
name: fleury_test
version: 0.1.0
dependencies:
  fleury: ^0.1.0
''',
      'packages/fleury_widgets/pubspec.yaml': '''
name: fleury_widgets
version: 0.1.0
dependencies:
  fleury: ^0.1.0
dev_dependencies:
  fleury_test: ^0.1.0
''',
    });

    const config = '''
schema = 2

[release.framework]
tag = "fleury-v{version}"
publish = ["git-tag"]

[[release.framework.project]]
path = "packages/fleury_widgets"
publish = ["pub.dev"]

[[release.framework.project]]
path = "packages/fleury_test"
publish = ["pub.dev"]

[[release.framework.project]]
path = "packages/fleury"
publish = ["pub.dev"]
''';

    test('order comes from the manifests, not the file', () {
      final resolution = resolve(config, tree);
      final release = derive(resolution.unit('framework')!, resolution);
      final published = release.steps
          .where((s) => s.kind == StepKind.publishRegistry)
          .map((s) => (s as Target).project!.name)
          .toList();

      expect(
        published,
        ['fleury', 'fleury_widgets', 'fleury_test'],
        reason:
            'runtime providers publish first; development does not order publication',
      );
    });

    test('a dependent names its sibling as a prerequisite', () {
      final resolution = resolve(config, tree);
      final release = derive(resolution.unit('framework')!, resolution);
      expect(ids(release.step('framework/pub.dev/fleury_test@0.1.0')!.needs), [
        'framework/tag/fleury-v0.1.0',
        'framework/pub.dev/fleury@0.1.0',
      ]);
    });
  });

  group('across units', () {
    final tree = MemorySourceTree({
      'packages/fleury/pubspec.yaml': 'name: fleury\nversion: 0.1.0\n',
      'packages/fleury_mcp/pubspec.yaml': '''
name: fleury_mcp
version: 0.1.0
dependencies:
  fleury: ^0.1.0
''',
    });

    const config = '''
schema = 2

[release.framework]
path = "packages/fleury"
publish = ["pub.dev"]

[release.mcp]
path = "packages/fleury_mcp"
publish = ["pub.dev"]
''';

    test('an ordinary caret pin still derives a prerequisite', () {
      final resolution = resolve(config, tree);
      final diagnostics = Diagnostics();
      final prerequisites = ReleaseDependencyPlan(
        resolution,
      ).prerequisites(resolution.unit('mcp')!, diagnostics);

      expect(prerequisites, hasLength(1));
      expect(prerequisites.single.package, 'fleury');
      expect(
        prerequisites.single.version.canonical,
        '0.1.0',
        reason: 'the version comes from the released project, not the pin',
      );
      expect(prerequisites.single.coordinate, 'pub.dev/fleury/0.1.0');
      expect(prerequisites.single.declaredBy, 'framework');
    });

    test('an exact pin derives one too', () {
      final resolution = resolve(keybayConfig, keybayTree);
      final diagnostics = Diagnostics();
      final prerequisites = ReleaseDependencyPlan(
        resolution,
      ).prerequisites(resolution.unit('cli')!, diagnostics);
      expect(prerequisites.single.coordinate, 'pub.dev/keybay/0.2.0');

      final release = derive(resolution.unit('cli')!, resolution);
      expect(ids(release.step('cli/pub.dev/keybay_cli@0.2.0')!.needs), [
        'cli/tag/keybay_cli-v0.2.0',
        'cli/requires/pub.dev/keybay/0.2.0',
      ]);
    });

    test('a third-party dependency is not a prerequisite', () {
      final resolution = resolve(
        '''
schema = 2

[release.lib]
publish = ["pub.dev"]
''',
        MemorySourceTree({
          'pubspec.yaml': '''
name: lib
version: 1.0.0
dependencies:
  ffi: 2.2.0
''',
        }),
      );
      final diagnostics = Diagnostics();
      expect(
        ReleaseDependencyPlan(
          resolution,
        ).prerequisites(resolution.unit('lib')!, diagnostics),
        isEmpty,
      );
    });
  });

  group("a project's own build", () {
    Resolution parser() => resolve(
      '''
schema = 2

[release.parser]
tag = "flark_parse-v{version}"
path = "native/parser"
publish = ["git-tag", "github-release"]
build = ["tool/build.sh", "{out}"]
assets = ["assets/parser-macos-arm64.dylib", "parser-linux-x64.so", "src.tar.gz"]
''',
      MemorySourceTree({
        'native/parser/Cargo.toml':
            '[package]\nname = "flark_parse"\nversion = "0.1.0"\n',
      }),
    );
    ResolvedUnit unitOf(Resolution resolution) => resolution.unit('parser')!;

    test('is one local step, before the stage completes', () {
      final resolution = parser();
      final unit = unitOf(resolution);
      final release = derive(unit, resolution);
      expect(release.steps.map((step) => (step.id, step.kind)), [
        ('parser/build/flark_parse', StepKind.buildAssets),
        ('parser/stage/complete', StepKind.completeStage),
        ('parser/tag/flark_parse-v0.1.0', StepKind.tag),
        ('parser/github-release/flark_parse-v0.1.0', StepKind.publishRelease),
      ]);
      final build = release.steps.first;
      expect((build as Work).project!.name, 'flark_parse');
      expect(build.platform, isNull);
      expect(build.kind.phase, StepPhase.stage);
      expect(ids(release.steps.elementAt(1).needs), [build.id]);
    });

    test('stages each asset under its file name, and publishes them', () {
      final unit = unitOf(parser());
      expect(
        [
          for (final asset in ReleaseAssets.bundleFor(unit))
            (asset.publicName, asset.stagedPath),
        ],
        [
          (
            'parser-linux-x64.so',
            'producers/flark_parse/assets/parser-linux-x64.so',
          ),
          (
            'parser-macos-arm64.dylib',
            'producers/flark_parse/assets/parser-macos-arm64.dylib',
          ),
          ('src.tar.gz', 'producers/flark_parse/assets/src.tar.gz'),
        ],
      );
      expect(ReleaseAssets.expectedForUnit(unit), {
        'parser-linux-x64.so',
        'parser-macos-arm64.dylib',
        'src.tar.gz',
        'release-manifest.json',
      });
    });

    test('leaves a receipt of the assets it wrote', () {
      final resolution = parser();
      final work = derive(
        unitOf(resolution),
        resolution,
      ).work.singleWhere((work) => work.kind == StepKind.buildAssets);
      expect(work.name, 'assets:flark_parse');
      expect(work.inputs, isEmpty);
      expect(work.outputs, {
        'producers/flark_parse/assets/parser-macos-arm64.dylib': 'asset',
        'producers/flark_parse/assets/parser-linux-x64.so': 'asset',
        'producers/flark_parse/assets/src.tar.gz': 'asset',
      });
    });
  });

  group('dependency ordering under refusal', () {
    const cycleWithDownstream = '''
schema = 2

[release.tools]
tag = "tools-v{version}"
publish = ["git-tag"]

[[release.tools.project]]
path = "packages/a"
publish = ["pub.dev"]

[[release.tools.project]]
path = "packages/b"
publish = ["pub.dev"]

[[release.tools.project]]
path = "packages/c"
publish = ["pub.dev"]
''';

    final cycleTree = MemorySourceTree({
      'packages/a/pubspec.yaml':
          'name: alpha\nversion: 1.0.0\ndependencies:\n  beta: 1.0.0\n',
      'packages/b/pubspec.yaml':
          'name: beta\nversion: 1.0.0\ndependencies:\n  alpha: 1.0.0\n',
      'packages/c/pubspec.yaml':
          'name: gamma\nversion: 1.0.0\ndependencies:\n  alpha: 1.0.0\n',
    });

    test('a cyclic unit still derives every publish step', () {
      final resolution = resolve(cycleWithDownstream, cycleTree);
      final diagnostics = Diagnostics();
      final release = derive(
        resolution.unit('tools')!,
        resolution,
        problems: diagnostics,
      );

      expect(diagnostics.found.map((d) => d.code), contains('RK-DEP-003'));
      // The diagnostic refuses the release; the rows still describe it, so
      // status keeps showing what the cycle blocks.
      expect(
        release.steps.map((step) => step.id),
        containsAll([
          'tools/pub.dev/alpha@1.0.0',
          'tools/pub.dev/beta@1.0.0',
          'tools/pub.dev/gamma@1.0.0',
        ]),
      );
    });

    test('the cycle remedy names the circle, not its dependents', () {
      final resolution = resolve(cycleWithDownstream, cycleTree);
      final diagnostics = Diagnostics();
      resolution.dependencyPlan.projects(
        resolution.unit('tools')!,
        diagnostics,
      );

      final remedy = diagnostics.found
          .singleWhere((d) => d.code == 'RK-DEP-003')
          .remedy!;
      expect(remedy, contains('alpha'));
      expect(remedy, contains('beta'));
      expect(remedy, isNot(contains('gamma')));
    });

    test('a devDependency does not become a publication prerequisite', () {
      final resolution = resolve(
        '''
schema = 2

[release.tools]
tag = "tools-v{version}"
publish = ["git-tag"]

[[release.tools.project]]
path = "packages/lib"
publish = ["pub.dev"]

[[release.tools.project]]
path = "packages/lib_test"
publish = ["pub.dev"]
''',
        MemorySourceTree({
          'packages/lib/pubspec.yaml':
              'name: lib\nversion: 1.0.0\n'
              'dev_dependencies:\n  lib_test: 1.0.0\n',
          'packages/lib_test/pubspec.yaml': 'name: lib_test\nversion: 1.0.0\n',
        }),
      );
      final diagnostics = Diagnostics();
      final release = derive(
        resolution.unit('tools')!,
        resolution,
        problems: diagnostics,
      );

      expect(diagnostics.found, isEmpty);
      final publish = release.step('tools/pub.dev/lib@1.0.0')!;
      expect(publish.needs, isNot(contains('tools/pub.dev/lib_test@1.0.0')));
    });
  });

  test('the plan and steps[] keep their own edges into an archive', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final release = derive(resolution.unit('cli')!, resolution);
    final archive = release.step('cli/archive/keybay_cli/macos-arm64')! as Work;

    expect(ids(archive.needs), ['cli/notarize/keybay_cli/macos-arm64']);
    expect(ids(archive.inputs), [
      'cli/build/keybay_cli/macos-arm64',
      'cli/notarize/keybay_cli/macos-arm64',
    ]);
  });

  test('the stage works in one order, with each piece named for its '
      'receipt', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final release = derive(
      resolution.unit('cli')!,
      resolution,
      repository: 'danReynolds/keybay',
    );

    expect(
      [for (final work in release.work) work.name],
      [
        'pub-archive:keybay_cli',
        'release-notes',
        'build:keybay_cli:linux-arm64',
        'archive:keybay_cli:linux-arm64',
        'build:keybay_cli:linux-x64',
        'archive:keybay_cli:linux-x64',
        'build:keybay_cli:macos-arm64',
        'notarize:keybay_cli:macos-arm64',
        'archive:keybay_cli:macos-arm64',
        'homebrew-formula:keybay_cli',
        'complete-stage',
      ],
    );
    expect(
      ids(release.work[9].inputs),
      [
        'cli/archive/keybay_cli/linux-x64',
        'cli/archive/keybay_cli/linux-arm64',
        'cli/archive/keybay_cli/macos-arm64',
      ],
      reason: 'the formula waits for its archives in configured order',
    );
    expect(
      [for (final work in release.barrier.inputs) work.name],
      [
        'homebrew-formula:keybay_cli',
        'pub-archive:keybay_cli',
        'release-notes',
        for (final work in release.work.sublist(2, 9)) work.name,
      ],
      reason: 'target work by name, then local work',
    );
  });

  group('targets', () {
    test('the closed catalog has one module for every target', () {
      final catalog = TargetCatalog.builtIn();
      for (final target in PublishTarget.values) {
        expect(catalog.moduleFor(target).target, target);
      }
    });

    test('each public step is a target, in release order', () {
      final resolution = resolve(
        '''
schema = 2

[release.cli]
tag = "v{version}"
homebrew_tap = "example/homebrew-tools"
publish = ["git-tag", "pub.dev", "github-release", "homebrew"]
binary_platforms = ["linux-x64"]
''',
        MemorySourceTree({
          'pubspec.yaml': '''
name: example_tool
version: 1.2.3
executables:
  tool: tool
''',
        }),
      );
      final release = derive(
        resolution.unit('cli')!,
        resolution,
        repository: 'example/tool',
      );

      expect(
        release.targets.map((target) => (target.target.wireName, target.id)),
        [
          ('gitTag', 'cli/tag/v1.2.3'),
          ('pubDev', 'cli/pub.dev/example_tool@1.2.3'),
          ('githubRelease', 'cli/github-release/v1.2.3'),
          ('homebrew', 'cli/homebrew/example_tool/tool'),
        ],
      );
      expect(
        release.targets.map((target) => target.kind).toSet(),
        StepKind.values
            .where((kind) => kind.phase == StepPhase.publish)
            .toSet(),
      );
      expect(
        release.steps.where((step) => step.isPublic),
        release.targets,
        reason: 'every public step is a target',
      );
    });

    test('pub staging follows the receipt contract, not dependency order', () {
      final resolution = resolve(
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
      );
      final release = derive(resolution.unit('apps')!, resolution);

      expect(
        release.packages.map((target) => target.coordinate),
        ['z_core', 'a_app'],
        reason: 'the release graph keeps dependency order',
      );
      expect(
        {
          for (final target in release.packages)
            target.coordinate: target.preparedBy!.name,
        },
        {'a_app': 'pub-archive:a_app', 'z_core': 'pub-archive:z_core'},
      );
      expect(
        [
          for (final work in release.work)
            if (work.kind == StepKind.targetStage) work.project!.name,
        ],
        ['a_app', 'z_core'],
        reason: 'stage receipts require package-name order',
      );
    });

    test('a pub-only release has no Git tag target', () {
      final resolution = resolve(
        'schema = 2\n\n[release.core]\npublish = ["pub.dev"]\n',
        MemorySourceTree({'pubspec.yaml': 'name: example\nversion: 1.2.3\n'}),
      );
      final release = derive(resolution.unit('core')!, resolution);

      expect(release.tag, isNull);
      expect(release.targets.map((target) => target.target), [
        PublishTarget.pubDev,
      ]);
    });
  });
}

bool _transitivelyNeeds(Step step, String requiredId) {
  final pending = [...step.needs];
  final seen = <String>{};
  while (pending.isNotEmpty) {
    final dependency = pending.removeLast();
    if (dependency.id == requiredId) return true;
    if (!seen.add(dependency.id)) continue;
    pending.addAll(dependency.needs);
  }
  return false;
}
