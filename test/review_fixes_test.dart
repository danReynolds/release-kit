import 'package:release_kit/src/engine/checklist.dart';
import 'package:release_kit/src/engine/config.dart';
import 'package:release_kit/src/engine/diagnostic.dart';
import 'package:release_kit/src/engine/pubspec.dart';
import 'package:release_kit/src/engine/resolve.dart';
import 'package:release_kit/src/engine/source_tree.dart';
import 'package:release_kit/src/engine/version.dart';
import 'package:release_kit/src/engine/yaml.dart';
import 'package:test/test.dart';

/// Regressions for findings from the phase 1 review. Each names the wrong
/// behaviour it prevents, because a test that only asserts the right answer
/// does not say why the answer is easy to get wrong.
void main() {
  yamlAndOrdering();

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
      final resolution = _resolve(
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
schema = 2

[release.cli]
publish = ["git-tag", "github-release"]
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

  test('two binary projects must be declared as separate release units', () {
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse('''
schema = 2

[release.tools]
tag = "tools-v{version}"
publish = ["git-tag", "github-release"]

[[release.tools.project]]
path = "packages/one"
binary_platforms = ["macos-arm64"]

[[release.tools.project]]
path = "packages/two"
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
    expect(diagnostics.found.single.remedy, contains('separate units'));
  });

  test('two tagged units keep explicit, distinct namespaces', () {
    // Multi-unit repositories declare the namespace so adding or removing a
    // sibling can never silently rename an existing unit's release history.
    final resolution = _resolve(
        '''
schema = 2

[release.lib]
tag = "mylib-v{version}"
path = "packages/mylib"
publish = ["git-tag", "pub.dev"]

[release.cli]
tag = "mycli-v{version}"
path = "packages/mycli"
publish = ["git-tag", "github-release"]
binary_platforms = ["macos-arm64"]
''',
        MemorySourceTree({
          'packages/mylib/pubspec.yaml': 'name: mylib\nversion: 1.0.0\n',
          'packages/mycli/pubspec.yaml': '''
name: mycli
version: 1.0.0
publish_to: none
executables:
  mycli: mycli
''',
        }));

    expect(resolution.unit('lib')!.tag, 'mylib-v1.0.0');
    expect(resolution.unit('cli')!.tag, 'mycli-v1.0.0');
  });

  test('a repository releasing one unit still gets the bare tag', () {
    final resolution = _resolve(
        '''
schema = 2

[release.lib]
publish = ["git-tag", "pub.dev"]
''',
        MemorySourceTree({
          'pubspec.yaml': 'name: mylib\nversion: 1.5.0\n',
        }));
    expect(resolution.unit('lib')!.tag, 'v1.5.0');
  });

  test('two units declaring one tag are refused', () {
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse('''
schema = 2

[release.a]
tag = "v{version}"
path = "packages/a"
publish = ["git-tag", "pub.dev"]

[release.b]
tag = "v{version}"
path = "packages/b"
publish = ["git-tag", "pub.dev"]
''', 'release.toml', diagnostics)!;
    final resolution = Resolution.resolve(
      config,
      MemorySourceTree({
        'packages/a/pubspec.yaml': 'name: a\nversion: 1.0.0\n',
        'packages/b/pubspec.yaml': 'name: b\nversion: 1.0.0\n',
      }),
      diagnostics,
    );
    expect(resolution, isNull);
    expect(diagnostics.found.single.code, 'RK-RES-010');
  });

  group('a tag rk would not be able to create', () {
    String? refuse(String tag) {
      final diagnostics = Diagnostics();
      final config = ReleaseConfig.parse(
        'schema = 2\n\n[release.a]\ntag = "$tag"\n'
            'path = "packages/a"\npublish = ["git-tag", "pub.dev"]\n',
        'release.toml',
        diagnostics,
      );
      if (config != null) return null;
      return diagnostics.found.first.code;
    }

    for (final tag in [
      'v{version} rc',
      'v{version}~1',
      'v{version}^',
      'v{version}:a',
      '.v{version}',
      'v{version}.lock',
      'v{version}.',
      'v..{version}',
      '/v{version}',
    ]) {
      test('"$tag" is refused before any work', () {
        expect(refuse(tag), 'RK-CONF-033');
      });
    }

    test('"@{" is caught earlier, as a placeholder rk does not have', () {
      expect(refuse('v{version}@{a}'), 'RK-CONF-015');
    });

    test('an ordinary nested tag is still allowed', () {
      expect(refuse('releases/cli-v{version}'), isNull);
    });
  });

  test('a tag on a project row is refused, not ignored', () {
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse('''
schema = 2

[release.framework]
tag = "fleury-v{version}"
publish = ["git-tag"]

[[release.framework.project]]
path = "packages/a"
publish = ["pub.dev"]
tag = "a-v{version}"
''', 'release.toml', diagnostics);

    expect(config, isNull, reason: 'silently ignored, it tags the wrong name');
    expect(diagnostics.found.single.code, 'RK-CONF-016');
    expect(diagnostics.found.single.message, contains('belongs to the unit'));
  });

  test('a cross-unit prerequisite becomes a step rather than being lost', () {
    final resolution = _resolve(
        '''
schema = 2

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]

[release.cli]
path = "packages/keybay_cli"
publish = ["pub.dev"]
''',
        MemorySourceTree({
          'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
          'packages/keybay_cli/pubspec.yaml': '''
name: keybay_cli
version: 0.2.0
dependencies:
  keybay: 0.2.0
''',
        }));

    final checklist =
        Checklist.derive(resolution.unit('cli')!, resolution, Diagnostics());
    final requires = checklist['cli/requires/pub.dev/keybay/0.2.0'];

    expect(requires, isNotNull, reason: 'it must be visible in the checklist');
    expect(requires!.kind, StepKind.prerequisite);
    expect(
      checklist['cli/pub.dev/keybay_cli@0.2.0']!.needs,
      contains(requires.id),
    );
  });

  test('a dependency circle is refused rather than silently ordered', () {
    final resolution = _resolve(
        '''
schema = 2

[release.pair]
tag = "pair-v{version}"
publish = ["git-tag"]

[[release.pair.project]]
path = "packages/a"
publish = ["pub.dev"]

[[release.pair.project]]
path = "packages/b"
publish = ["pub.dev"]
''',
        MemorySourceTree({
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
    final resolution = _resolve(
        '''
schema = 2

[release.cli]
path = "packages/keybay_cli"
publish = ["git-tag", "pub.dev", "github-release", "homebrew"]
binary_platforms = ["linux-x64", "macos-arm64"]
''',
        MemorySourceTree({
          'packages/keybay_cli/pubspec.yaml': '''
name: keybay_cli
version: 0.2.0
executables:
  keybay: keybay
''',
        }));

    final checklist =
        Checklist.derive(resolution.unit('cli')!, resolution, Diagnostics());
    final ids = checklist.steps.map((s) => s.id).toList();

    expect(ids.toSet(), hasLength(ids.length), reason: 'ids are unique');
    for (var i = 0; i < checklist.steps.length; i++) {
      for (final need in checklist.steps[i].needs) {
        expect(ids.indexOf(need), lessThan(i), reason: '$need precedes it');
      }
    }
  });

  test('a step names what it acts on without parsing its own id', () {
    final resolution = _resolve(
        '''
schema = 2

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]
''',
        MemorySourceTree({
          'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
        }));

    final checklist =
        Checklist.derive(resolution.unit('core')!, resolution, Diagnostics());
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

/// Round two of the phase 1 review: the YAML holes and the ordering rules.
void yamlAndOrdering() {
  group('a flow collection is refused, never read as an empty map', () {
    test('a path dependency written inline still refuses the repository', () {
      final diagnostics = Diagnostics();
      final doc = parseYaml(
        'name: dune_cli\ndependencies: {dune_core: {path: ../dune_core}}\n',
        'pubspec.yaml',
        diagnostics,
      );
      expect(
        doc,
        isNull,
        reason: 'read as a scalar, the path dependency becomes invisible',
      );
      expect(diagnostics.found.single.message, contains('flow collections'));
    });

    test('a flow sequence is refused too', () {
      final diagnostics = Diagnostics();
      expect(parseYaml('topics: [a, b]\n', 'p.yaml', diagnostics), isNull);
    });

    test('a flow collection as a list item is refused', () {
      final diagnostics = Diagnostics();
      expect(
        parseYaml('screenshots:\n  - {path: a}\n', 'p.yaml', diagnostics),
        isNull,
      );
    });

    test('a value that merely contains a brace is fine', () {
      final doc = parseYaml('tag: "v{version}"\n', 'p.yaml', Diagnostics())!;
      expect(doc.string('tag'), 'v{version}');
    });
  });

  group('a sequence at its parent key\'s column', () {
    test('is read, because pubspecs are written that way', () {
      final doc = parseYaml('''
name: keybay
topics:
- security
- secrets
version: 0.1.0
''', 'pubspec.yaml', Diagnostics());
      expect(doc, isNotNull);
      expect(doc!.list('topics')!.strings, ['security', 'secrets']);
      expect(doc.string('version'), '0.1.0', reason: 'the list closes');
    });

    test('a key indented into it cannot become a root key', () {
      final diagnostics = Diagnostics();
      final doc = parseYaml('''
name: keybay
topics:
  - security
  version: 9.9.9
''', 'pubspec.yaml', diagnostics);
      expect(
        doc,
        isNull,
        reason: 'hoisted to the root it would be the released version',
      );
      expect(diagnostics.found.single.message, contains('mix'));
    });
  });
}
