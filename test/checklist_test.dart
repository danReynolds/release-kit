import 'package:release_kit/src/engine/checklist.dart';
import 'package:release_kit/src/engine/config.dart';
import 'package:release_kit/src/engine/diagnostic.dart';
import 'package:release_kit/src/engine/resolve.dart';
import 'package:release_kit/src/engine/source_tree.dart';
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
      [
        'cli/tag/keybay_cli-v0.2.0',
        'cli/stage/complete',
      ],
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

  test('the formula waits for the release to be public', () {
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
      final prerequisites = externalPrerequisites(
        resolution.unit('mcp')!,
        resolution,
        diagnostics,
      );

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
      final prerequisites = externalPrerequisites(
        resolution.unit('cli')!,
        resolution,
        diagnostics,
      );
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
        externalPrerequisites(
          resolution.unit('lib')!,
          resolution,
          diagnostics,
        ),
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
      externalPrerequisites(resolution.unit('mcp')!, resolution, diagnostics);
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
