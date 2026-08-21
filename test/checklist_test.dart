import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/release_dependencies.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:test/test.dart';

Resolution resolve(String config, MemorySourceTree tree) {
  final diagnostics = Diagnostics();
  final parsed = ReleaseConfig.parse(config, 'release.toml', diagnostics)!;
  final resolution = Resolution.resolve(parsed, tree, diagnostics);
  expect(resolution, isNotNull, reason: diagnostics.found.join('\n'));
  return resolution!;
}

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
  frozenIdVectors();

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
      final checklist = Checklist.derive(unit, resolution, Diagnostics());

      expect(unit.tag, isNull);
      expect(checklist.steps.map((step) => step.id), [
        'core/stage/complete',
        'core/pub.dev/example@1.2.3',
      ]);
      expect(
        checklist['core/pub.dev/example@1.2.3']!.needs,
        ['core/stage/complete'],
      );
    });

    test('an explicit tag sits between stage and registry publication', () {
      final resolution = resolve('''
schema = 2

[release.core]
tag = "release-v{version}"
publish = ["git-tag", "pub.dev"]
''', tree);
      final unit = resolution.unit('core')!;
      final checklist = Checklist.derive(unit, resolution, Diagnostics());

      expect(unit.tag, 'release-v1.2.3');
      expect(checklist.steps.map((step) => step.id), [
        'core/stage/complete',
        'core/tag/release-v1.2.3',
        'core/pub.dev/example@1.2.3',
      ]);
      expect(
        checklist['core/tag/release-v1.2.3']!.needs,
        ['core/stage/complete'],
      );
      expect(
        checklist['core/pub.dev/example@1.2.3']!.needs,
        ['core/tag/release-v1.2.3'],
      );
    });

    test('a metadata-only GitHub release has notes and a manifest', () {
      final resolution = resolve('''
schema = 2

[release.core]
publish = ["git-tag", "github-release"]
''', tree);
      final unit = resolution.unit('core')!;
      final checklist = Checklist.derive(unit, resolution, Diagnostics());

      expect(checklist.steps.map((step) => step.id), [
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
      final checklist = Checklist.derive(unit, resolution, Diagnostics());
      final ids = checklist.steps.map((step) => step.id).toList();

      expect(ids, contains('cli/github-release/v1.3.0-beta.1'));
      expect(ids.where((id) => id.contains('/homebrew/')), isEmpty);
    });
  });

  test('a registry-only unit stages before its tag and publish', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final checklist =
        Checklist.derive(resolution.unit('core')!, resolution, Diagnostics());

    expect(checklist.steps.map((s) => s.id), [
      'core/stage/complete',
      'core/tag/keybay-v0.2.0',
      'core/pub.dev/keybay@0.2.0',
    ]);
    expect(checklist['core/stage/complete']!.needs, isEmpty);
    expect(
      checklist['core/tag/keybay-v0.2.0']!.needs,
      ['core/stage/complete'],
    );
    expect(
      checklist['core/pub.dev/keybay@0.2.0']!.needs,
      ['core/tag/keybay-v0.2.0'],
    );
  });

  test('a unit refuses several standalone producers', () {
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse('''
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
''', 'release.toml', diagnostics)!;
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
        diagnostics);

    expect(resolution, isNull);
    expect(diagnostics.found.single.code, 'RK-RES-009');
  });

  test('the binary chain covers every declared platform', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final checklist =
        Checklist.derive(resolution.unit('cli')!, resolution, Diagnostics());
    final ids = checklist.steps.map((s) => s.id).toList();

    expect(ids, contains('cli/build/keybay_cli/linux-x64'));
    expect(ids, contains('cli/build/keybay_cli/macos-arm64'));
    expect(
      checklist['cli/build/keybay_cli/macos-arm64']!.summary,
      contains('build and sign'),
      reason: 'only macOS binaries are signed, inside their build step',
    );
    expect(
      checklist['cli/build/keybay_cli/linux-x64']!.summary,
      isNot(contains('sign')),
    );
    expect(ids, contains('cli/notarize/keybay_cli/macos-arm64'));
    expect(ids, contains('cli/archive/keybay_cli/linux-x64'));
    expect(ids, contains('cli/stage/complete'));
    expect(ids, contains('cli/github-release/keybay_cli-v0.2.0'));
    expect(ids, contains('cli/homebrew/keybay_cli/keybay'));
  });

  test('notarization sits between the signed build and its archive', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final checklist =
        Checklist.derive(resolution.unit('cli')!, resolution, Diagnostics());

    expect(
      checklist['cli/sign/macos-arm64'],
      isNull,
      reason: 'compiling and signing are one build step, so the checklist, '
          'the receipt, and the validators speak the same producer names',
    );
    expect(
      checklist['cli/build/keybay_cli/macos-arm64']!.summary,
      contains('build and sign'),
    );
    expect(
      checklist['cli/notarize/keybay_cli/macos-arm64']!.needs,
      ['cli/build/keybay_cli/macos-arm64'],
    );
    expect(
      checklist['cli/archive/keybay_cli/macos-arm64']!.needs,
      ['cli/notarize/keybay_cli/macos-arm64'],
    );
    expect(
      checklist['cli/archive/keybay_cli/linux-x64']!.needs,
      ['cli/build/keybay_cli/linux-x64'],
      reason: 'a Linux archive follows its build directly',
    );
  });

  test('the complete-stage barrier waits for every local producer', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final checklist =
        Checklist.derive(resolution.unit('cli')!, resolution, Diagnostics());
    final producers = checklist.steps
        .where((step) => const {
              StepKind.build,
              StepKind.notarize,
              StepKind.archive,
            }.contains(step.kind))
        .map((step) => step.id)
        .toList();

    expect(checklist['cli/stage/complete']!.needs, producers);
    expect(
      checklist['cli/github-release/keybay_cli-v0.2.0']!.needs,
      ['cli/tag/keybay_cli-v0.2.0'],
      reason: 'the tag already carries the complete-stage dependency',
    );
  });

  test('every public act transitively depends on the complete stage', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final checklist =
        Checklist.derive(resolution.unit('cli')!, resolution, Diagnostics());
    const barrier = 'cli/stage/complete';

    for (final step in checklist.steps.where((step) => step.isPublic)) {
      expect(
        _transitivelyNeeds(checklist, step, barrier),
        isTrue,
        reason: '${step.id} can act publicly without $barrier',
      );
    }
  });

  test('the explicit safety phases never move backwards', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final checklist =
        Checklist.derive(resolution.unit('cli')!, resolution, Diagnostics());
    var phase = StepPhase.inspect;
    for (final step in checklist.steps) {
      expect(
        step.phase.index,
        greaterThanOrEqualTo(phase.index),
        reason: '${step.id} moved from ${phase.name} back to '
            '${step.phase.name}',
      );
      phase = step.phase;
    }
    expect(checklist['cli/stage/complete']!.phase, StepPhase.stage);
    expect(checklist['cli/tag/keybay_cli-v0.2.0']!.phase, StepPhase.publish);
  });

  test('the cask waits for the release to be public', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final checklist =
        Checklist.derive(resolution.unit('cli')!, resolution, Diagnostics());
    expect(
      checklist['cli/homebrew/keybay_cli/keybay']!.needs,
      ['cli/github-release/keybay_cli-v0.2.0'],
    );
  });

  test('permanent and public steps are marked', () {
    final resolution = resolve(keybayConfig, keybayTree);
    final checklist =
        Checklist.derive(resolution.unit('cli')!, resolution, Diagnostics());

    expect(checklist['cli/pub.dev/keybay_cli@0.2.0']!.isPermanent, isTrue);
    expect(checklist['cli/build/keybay_cli/linux-x64']!.isPermanent, isFalse);
    expect(checklist['cli/build/keybay_cli/linux-x64']!.isPublic, isFalse);
    expect(checklist['cli/homebrew/keybay_cli/keybay']!.isPublic, isTrue);
    expect(
      checklist['cli/homebrew/keybay_cli/keybay']!.isPermanent,
      isFalse,
      reason: 'a cask moves forward again; a published version cannot',
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
      final checklist = Checklist.derive(
          resolution.unit('framework')!, resolution, Diagnostics());
      final published = checklist.steps
          .where((s) => s.kind == StepKind.publishRegistry)
          .map((s) => s.project)
          .toList();

      expect(
        published,
        ['fleury', 'fleury_test', 'fleury_widgets'],
        reason: 'declaration order was the reverse',
      );
    });

    test('a dependent names its sibling as a prerequisite', () {
      final resolution = resolve(config, tree);
      final checklist = Checklist.derive(
          resolution.unit('framework')!, resolution, Diagnostics());
      expect(
        checklist['framework/pub.dev/fleury_test@0.1.0']!.needs,
        [
          'framework/tag/fleury-v0.1.0',
          'framework/pub.dev/fleury@0.1.0',
        ],
      );
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
      final prerequisites = ReleaseDependencyPlan(resolution)
          .prerequisites(resolution.unit('mcp')!, diagnostics);

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
      final prerequisites = ReleaseDependencyPlan(resolution)
          .prerequisites(resolution.unit('cli')!, diagnostics);
      expect(prerequisites.single.coordinate, 'pub.dev/keybay/0.2.0');

      final checklist = Checklist.derive(
        resolution.unit('cli')!,
        resolution,
        Diagnostics(),
      );
      expect(
        checklist['cli/pub.dev/keybay_cli@0.2.0']!.needs,
        [
          'cli/tag/keybay_cli-v0.2.0',
          'cli/requires/pub.dev/keybay/0.2.0',
        ],
      );
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
          }));
      final diagnostics = Diagnostics();
      expect(
        ReleaseDependencyPlan(resolution)
            .prerequisites(resolution.unit('lib')!, diagnostics),
        isEmpty,
      );
    });

    test('a constraint the release cannot satisfy is refused', () {
      final resolution = resolve(
          '''
schema = 2

[release.framework]
path = "packages/fleury"
publish = ["pub.dev"]

[release.mcp]
path = "packages/fleury_mcp"
publish = ["pub.dev"]
''',
          MemorySourceTree({
            'packages/fleury/pubspec.yaml': 'name: fleury\nversion: 0.2.0\n',
            'packages/fleury_mcp/pubspec.yaml': '''
name: fleury_mcp
version: 0.1.0
dependencies:
  fleury: ^0.1.0
''',
          }));

      final diagnostics = Diagnostics();
      ReleaseDependencyPlan(resolution)
          .prerequisites(resolution.unit('mcp')!, diagnostics);
      expect(diagnostics.found.single.code, 'RK-DEP-001');
    });
  });
}

/// The step-id grammar, frozen the way the version vectors are.
///
/// Ids are the machine surface's keys: an agent that polled yesterday and
/// diffs against today must see the same id for the same fact. A change here
/// is a wire-format break and gets made deliberately or not at all.
void frozenIdVectors() {
  test('every id form, spelled out and frozen', () {
    final tree = MemorySourceTree({
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
    final resolution = resolve(keybayConfig, tree);
    final checklist =
        Checklist.derive(resolution.unit('cli')!, resolution, Diagnostics());

    expect(checklist.steps.map((s) => s.id).toList(), [
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
      final checklist =
          Checklist.derive(resolution.unit('tools')!, resolution, diagnostics);

      expect(diagnostics.found.map((d) => d.code), contains('RK-DEP-003'));
      // The diagnostic refuses the release; the rows still describe it, so
      // status keeps showing what the cycle blocks.
      expect(
        checklist.steps.map((step) => step.id),
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
      resolution.dependencyPlan
          .projects(resolution.unit('tools')!, diagnostics);

      final remedy =
          diagnostics.found.singleWhere((d) => d.code == 'RK-DEP-003').remedy!;
      expect(remedy, contains('alpha'));
      expect(remedy, contains('beta'));
      expect(remedy, isNot(contains('gamma')));
    });

    test('a devDependency edge appears on the publish step graph', () {
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
            'packages/lib/pubspec.yaml': 'name: lib\nversion: 1.0.0\n'
                'dev_dependencies:\n  lib_test: 1.0.0\n',
            'packages/lib_test/pubspec.yaml':
                'name: lib_test\nversion: 1.0.0\n',
          }));
      final diagnostics = Diagnostics();
      final checklist =
          Checklist.derive(resolution.unit('tools')!, resolution, diagnostics);

      expect(diagnostics.found, isEmpty);
      final publish = checklist['tools/pub.dev/lib@1.0.0']!;
      // The edge that ordered publication is recorded on the step, so a
      // graph-driven consumer sees the same constraint the order obeys.
      expect(publish.needs, contains('tools/pub.dev/lib_test@1.0.0'));
    });
  });
}

bool _transitivelyNeeds(Checklist checklist, Step step, String requiredId) {
  final pending = [...step.needs];
  final seen = <String>{};
  while (pending.isNotEmpty) {
    final id = pending.removeLast();
    if (id == requiredId) return true;
    if (!seen.add(id)) continue;
    final dependency = checklist[id];
    if (dependency != null) pending.addAll(dependency.needs);
  }
  return false;
}
