import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/pubspec.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/version.dart';
import 'package:rk/src/engine/yaml.dart';
import 'package:test/test.dart';

/// Regressions for findings from the phase 1 review. Each names the wrong
/// behaviour it prevents, because a test that only asserts the right answer
/// does not say why the answer is easy to get wrong.
void main() {
  group('a list of maps stays inside the list', () {
    test('a later key cannot overwrite the package version', () {
      final diagnostics = Diagnostics();
      final doc = parseYaml('''
name: keybay
version: 0.1.0
screenshots:
  - description: a shot
    version: 9.9.9
''', 'pubspec.yaml', diagnostics)!;

      expect(
        doc.string('version'),
        '0.1.0',
        reason: 'the screenshot\'s own version must not become the package\'s',
      );
      final shots = doc.list('screenshots')!;
      expect(shots.items.single, isA<YamlMap>());
      expect((shots.items.single as YamlMap).string('version'), '9.9.9');
    });

    test('several map entries are read, not refused', () {
      final diagnostics = Diagnostics();
      final doc = parseYaml('''
name: keybay
screenshots:
  - description: The CLI
    path: doc/cli.png
  - description: The TUI
    path: doc/tui.png
version: 0.1.0
''', 'pubspec.yaml', diagnostics);

      expect(doc, isNotNull, reason: diagnostics.found.join('\n'));
      final shots = doc!.list('screenshots')!;
      expect(shots.items, hasLength(2));
      expect((shots.items[1] as YamlMap).string('path'), 'doc/tui.png');
      expect(doc.string('version'), '0.1.0');
    });
  });

  test('a key set twice is refused rather than last-wins', () {
    final diagnostics = Diagnostics();
    final doc = parseYaml(
      'name: keybay\nversion: 0.1.0\nversion: 9.9.9\n',
      'pubspec.yaml',
      diagnostics,
    );
    expect(doc, isNull);
    expect(diagnostics.found.single.message, contains('more than once'));
  });

  group('versions wider than the platform integer', () {
    test('are refused rather than crashing the parse', () {
      expect(Version.tryParse('99999999999999999999.0.0'), isNull);
    });

    test('order in a prerelease rather than throwing', () {
      final small = Version.tryParse('1.0.0-1')!;
      final huge = Version.tryParse('1.0.0-99999999999999999999')!;
      expect(small < huge, isTrue);
    });
  });

  group('a constraint rk cannot evaluate is not treated as satisfied', () {
    test('a range pin refuses instead of publishing unchecked', () {
      final resolution = _resolve('''
schema = 1

[release.framework]
path = "packages/fleury"
publish = ["pub.dev"]

[release.mcp]
path = "packages/fleury_mcp"
publish = ["pub.dev"]
''', MemorySourceTree({
        'packages/fleury/pubspec.yaml': 'name: fleury\nversion: 0.2.0\n',
        'packages/fleury_mcp/pubspec.yaml': '''
name: fleury_mcp
version: 0.1.0
dependencies:
  fleury: ">=0.1.0 <0.3.0"
''',
      }));

      final diagnostics = Diagnostics();
      externalPrerequisites(resolution.unit('mcp')!, resolution, diagnostics);
      expect(diagnostics.found.single.code, 'RK-DEP-002');
    });

    test('an exact pin is still evaluated', () {
      expect(
        const Dependency.hosted('1.2.3', 1)
            .satisfiedBy(Version.tryParse('1.2.3')!),
        isTrue,
      );
    });

    test('a caret pin follows pub\'s rule for a leading zero', () {
      final caret = const Dependency.hosted('^0.1.0', 1);
      expect(caret.satisfiedBy(Version.tryParse('0.1.9')!), isTrue);
      expect(caret.satisfiedBy(Version.tryParse('0.2.0')!), isFalse);
    });
  });

  test('a project built from outside the repository is refused', () {
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse('''
schema = 1

[release.cli]
publish = ["github-release"]
binary_platforms = ["macos-arm64"]
''', 'release.toml', diagnostics)!;

    final resolution = Resolution.resolve(
      config,
      MemorySourceTree({
        'pubspec.yaml': '''
name: dune_cli
version: 0.0.1
publish_to: none
executables:
  dune: dune
dependencies:
  dune_core:
    path: ../dune_core
  stdio:
    path: ../stdio
''',
      }),
      diagnostics,
    );

    expect(resolution, isNull);
    final problem = diagnostics.found.single;
    expect(problem.code, 'RK-DART-201');
    expect(problem.remedy, contains('dune_core'));
    expect(problem.remedy, contains('stdio'));
  });

  test('two binary projects in one unit are refused, not collided', () {
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse('''
schema = 1

[release.tools]
tag = "tools-v{version}"

[[release.tools.project]]
path = "packages/one"
publish = ["github-release"]
binary_platforms = ["macos-arm64"]

[[release.tools.project]]
path = "packages/two"
publish = ["github-release"]
binary_platforms = ["macos-arm64"]
''', 'release.toml', diagnostics)!;

    final resolution = Resolution.resolve(
      config,
      MemorySourceTree({
        'packages/one/pubspec.yaml':
            'name: one\nversion: 1.0.0\nexecutables:\n  one: one\n',
        'packages/two/pubspec.yaml':
            'name: two\nversion: 1.0.0\nexecutables:\n  two: two\n',
      }),
      diagnostics,
    );

    expect(resolution, isNull);
    expect(diagnostics.found.single.code, 'RK-RES-009');
  });

  test('the tag convention counts registry packages, not projects', () {
    // One library on pub.dev and one binary-only CLI: the repository publishes
    // one package to pub.dev, so pub.dev's single-package form applies.
    final resolution = _resolve('''
schema = 1

[release.lib]
path = "packages/mylib"
publish = ["pub.dev"]

[release.cli]
path = "packages/mycli"
publish = ["github-release"]
binary_platforms = ["macos-arm64"]
''', MemorySourceTree({
      'packages/mylib/pubspec.yaml': 'name: mylib\nversion: 1.0.0\n',
      'packages/mycli/pubspec.yaml': '''
name: mycli
version: 1.0.0
publish_to: none
executables:
  mycli: mycli
''',
    }));

    expect(resolution.unit('lib')!.tagPattern, 'v{version}');
  });

  test('a cross-unit prerequisite becomes a step rather than being lost', () {
    final resolution = _resolve('''
schema = 1

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]

[release.cli]
path = "packages/keybay_cli"
publish = ["pub.dev"]
''', MemorySourceTree({
      'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
      'packages/keybay_cli/pubspec.yaml': '''
name: keybay_cli
version: 0.2.0
dependencies:
  keybay: 0.2.0
''',
    }));

    final checklist = Checklist.derive(resolution.unit('cli')!, resolution);
    final requires = checklist['cli/requires/pub.dev/keybay/0.2.0'];

    expect(requires, isNotNull, reason: 'it must be visible in the checklist');
    expect(requires!.kind, StepKind.prerequisite);
    expect(
      checklist['cli/pub.dev/keybay_cli@0.2.0']!.needs,
      contains(requires.id),
    );
  });

  test('a dependency circle is refused rather than silently ordered', () {
    final resolution = _resolve('''
schema = 1

[release.pair]
tag = "pair-v{version}"

[[release.pair.project]]
path = "packages/a"
publish = ["pub.dev"]

[[release.pair.project]]
path = "packages/b"
publish = ["pub.dev"]
''', MemorySourceTree({
      'packages/a/pubspec.yaml':
          'name: a\nversion: 1.0.0\ndependencies:\n  b: 1.0.0\n',
      'packages/b/pubspec.yaml':
          'name: b\nversion: 1.0.0\ndependencies:\n  a: 1.0.0\n',
    }));

    final diagnostics = Diagnostics();
    Checklist.derive(resolution.unit('pair')!, resolution, diagnostics);
    expect(
      diagnostics.found.map((d) => d.code),
      contains('RK-DEP-003'),
    );
  });

  test('every step waits only on steps that come before it', () {
    final resolution = _resolve('''
schema = 1

[release.cli]
path = "packages/keybay_cli"
publish = ["pub.dev", "github-release", "homebrew"]
binary_platforms = ["linux-x64", "macos-arm64"]
''', MemorySourceTree({
      'packages/keybay_cli/pubspec.yaml': '''
name: keybay_cli
version: 0.2.0
executables:
  keybay: keybay
''',
    }));

    final checklist = Checklist.derive(resolution.unit('cli')!, resolution);
    final ids = checklist.steps.map((s) => s.id).toList();

    expect(ids.toSet(), hasLength(ids.length), reason: 'ids are unique');
    for (var i = 0; i < checklist.steps.length; i++) {
      for (final need in checklist.steps[i].needs) {
        expect(ids.indexOf(need), lessThan(i), reason: '$need precedes it');
      }
    }
  });

  test('a step names what it acts on without parsing its own id', () {
    final resolution = _resolve('''
schema = 1

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]
''', MemorySourceTree({
      'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
    }));

    final checklist = Checklist.derive(resolution.unit('core')!, resolution);
    expect(
      checklist['core/pub.dev/keybay@0.2.0']!.coordinate,
      'keybay@0.2.0',
    );
  });
}

Resolution _resolve(String config, MemorySourceTree tree) {
  final diagnostics = Diagnostics();
  final parsed = ReleaseConfig.parse(config, 'release.toml', diagnostics)!;
  final resolution = Resolution.resolve(parsed, tree, diagnostics);
  expect(resolution, isNotNull, reason: diagnostics.found.join('\n'));
  return resolution!;
}
