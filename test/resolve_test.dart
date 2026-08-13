import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:test/test.dart';

/// A keybay-shaped repository: a workspace root and two published packages.
MemorySourceTree keybayTree({
  String coreVersion = '0.2.0',
  String cliVersion = '0.2.0',
}) =>
    MemorySourceTree({
      'pubspec.yaml': '''
name: keybay_workspace
publish_to: none
environment:
  sdk: ^3.6.0
workspace:
  - packages/keybay
  - packages/keybay_cli
''',
      'packages/keybay/pubspec.yaml': '''
name: keybay
version: $coreVersion
environment:
  sdk: ^3.6.0
''',
      'packages/keybay_cli/pubspec.yaml': '''
name: keybay_cli
version: $cliVersion
environment:
  sdk: ^3.10.0
dependencies:
  keybay: $coreVersion
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

Resolution resolved(String config, SourceTree tree) {
  final diagnostics = Diagnostics();
  final parsed = ReleaseConfig.parse(config, 'release.toml', diagnostics);
  expect(parsed, isNotNull, reason: diagnostics.found.join('\n'));
  final resolution = Resolution.resolve(parsed!, tree, diagnostics);
  expect(resolution, isNotNull, reason: diagnostics.found.join('\n'));
  return resolution!;
}

String refusedWith(String config, SourceTree tree) {
  final diagnostics = Diagnostics();
  final parsed = ReleaseConfig.parse(config, 'release.toml', diagnostics);
  if (parsed == null) return diagnostics.found.first.code;
  final resolution = Resolution.resolve(parsed, tree, diagnostics);
  expect(resolution, isNull, reason: 'should have been refused');
  return diagnostics.found.first.code;
}

void main() {
  test('resolves keybay against its manifests', () {
    final resolution = resolved(keybayConfig, keybayTree());

    final core = resolution.unit('core')!;
    expect(core.projects.single.name, 'keybay');
    expect(core.version.canonical, '0.2.0');

    final cli = resolution.unit('cli')!;
    expect(cli.projects.single.executable, 'keybay');
    expect(cli.shipsBinaries, isTrue);
  });

  test('uses explicit stable tags where the repository publishes several', () {
    final resolution = resolved(keybayConfig, keybayTree());
    expect(resolution.unit('core')!.tagPattern, 'keybay-v{version}');
    expect(resolution.unit('cli')!.tagPattern, 'keybay_cli-v{version}');
    expect(resolution.unit('core')!.tag, 'keybay-v0.2.0');
  });

  test('several tagged units cannot derive topology-dependent names', () {
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse('''
schema = 2

[release.core]
path = "packages/keybay"
publish = ["git-tag", "pub.dev"]

[release.cli]
path = "packages/keybay_cli"
publish = ["git-tag", "pub.dev"]
''', 'release.toml', diagnostics)!;
    final resolution = Resolution.resolve(config, keybayTree(), diagnostics);

    expect(resolution, isNull);
    expect(
      diagnostics.found.where((item) => item.code == 'RK-RES-012'),
      hasLength(2),
    );
  });

  test('derives a bare tag where the repository publishes one package', () {
    final resolution = resolved(
        '''
schema = 2

[release.lib]
publish = ["git-tag", "pub.dev"]
''',
        MemorySourceTree({
          'pubspec.yaml': 'name: dart_retry_helper\nversion: 1.5.0\n',
        }));
    expect(resolution.unit('lib')!.tagPattern, 'v{version}');
    expect(resolution.unit('lib')!.tag, 'v1.5.0');
  });

  test('a declared tag always wins over the convention', () {
    final resolution = resolved('''
schema = 2

[release.core]
tag = "release-{version}"
path = "packages/keybay"
publish = ["git-tag", "pub.dev"]
''', keybayTree());
    expect(resolution.unit('core')!.tagPattern, 'release-{version}');
    expect(resolution.unit('core')!.tagWasDeclared, isTrue);
  });

  test('reads the first-party identity map across every unit', () {
    final resolution = resolved(keybayConfig, keybayTree());
    expect(
      resolution.allProjects.map((p) => p.name),
      ['keybay', 'keybay_cli'],
    );
  });

  group('refuses', () {
    test('a project directory that does not exist', () {
      expect(
        refusedWith('''
schema = 2

[release.core]
path = "packages/missing"
publish = ["pub.dev"]
''', keybayTree()),
        'RK-RES-001',
      );
    });

    test('a manifest with no version, such as a workspace root', () {
      expect(
        refusedWith('''
schema = 2

[release.root]
publish = ["pub.dev"]
''', keybayTree()),
        // The workspace root vetoes pub.dev before its missing version is
        // reached; either refusal is correct and both are reported.
        anyOf('RK-RES-002', 'RK-RES-003'),
      );
    });

    test('publishing a package whose manifest vetoes the registry', () {
      expect(
        refusedWith(
            '''
schema = 2

[release.cli]
publish = ["pub.dev"]
''',
            MemorySourceTree({
              'pubspec.yaml':
                  'name: dune_cli\nversion: 0.0.1\npublish_to: none\n',
            })),
        'RK-RES-003',
      );
    });

    test('a custom native Dart registry is not mislabeled pub.dev', () {
      expect(
        refusedWith(
            '''
schema = 2

[release.cli]
publish = ["pub.dev"]
''',
            MemorySourceTree({
              'pubspec.yaml': 'name: dune_cli\nversion: 0.0.1\n'
                  'publish_to: https://packages.example.invalid\n',
            })),
        'RK-RES-014',
      );
    });

    test('binary channels for a package with no executable', () {
      expect(
        refusedWith('''
schema = 2

[release.core]
path = "packages/keybay"
publish = ["git-tag", "github-release"]
binary_platforms = ["macos-arm64"]
''', keybayTree()),
        'RK-RES-004',
      );
    });

    test('binary channels where the package declares several executables', () {
      expect(
        refusedWith(
            '''
schema = 2

[release.tools]
publish = ["git-tag", "github-release"]
binary_platforms = ["macos-arm64"]
''',
            MemorySourceTree({
              'pubspec.yaml': '''
name: tools
version: 1.0.0
executables:
  one: one
  two: two
''',
            })),
        'RK-RES-005',
      );
    });

    test('two projects at the same path', () {
      expect(
        refusedWith('''
schema = 2

[release.a]
path = "packages/keybay"
publish = ["pub.dev"]

[release.b]
path = "packages/keybay"
publish = ["pub.dev"]
''', keybayTree()),
        'RK-RES-006',
      );
    });

    test('a project nested inside another', () {
      expect(
        refusedWith(
            '''
schema = 2

[release.outer]
path = "packages"
publish = ["pub.dev"]

[release.inner]
path = "packages/keybay"
publish = ["pub.dev"]
''',
            MemorySourceTree({
              'packages/pubspec.yaml': 'name: outer\nversion: 1.0.0\n',
              'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 1.0.0\n',
            })),
        'RK-RES-006',
      );
    });

    test('a unit whose projects are at different versions', () {
      expect(
        refusedWith(
            '''
schema = 2

[release.framework]
tag = "fleury-v{version}"
publish = ["git-tag"]

[[release.framework.project]]
path = "packages/a"
publish = ["pub.dev"]

[[release.framework.project]]
path = "packages/b"
publish = ["pub.dev"]
''',
            MemorySourceTree({
              'packages/a/pubspec.yaml': 'name: a\nversion: 0.1.0\n',
              'packages/b/pubspec.yaml': 'name: b\nversion: 0.2.0\n',
            })),
        'RK-RES-008',
      );
    });
  });

  test('a multi-project unit resolves every member', () {
    final resolution = resolved(
        '''
schema = 2

[release.framework]
tag = "fleury-v{version}"
publish = ["git-tag"]

[[release.framework.project]]
path = "packages/fleury"
publish = ["pub.dev"]

[[release.framework.project]]
path = "packages/fleury_test"
publish = ["pub.dev"]
''',
        MemorySourceTree({
          'packages/fleury/pubspec.yaml': 'name: fleury\nversion: 0.1.0\n',
          'packages/fleury_test/pubspec.yaml': '''
name: fleury_test
version: 0.1.0
dependencies:
  fleury: ^0.1.0
''',
        }));

    final framework = resolution.unit('framework')!;
    expect(framework.projects, hasLength(2));
    expect(framework.tag, 'fleury-v0.1.0');
  });
}
