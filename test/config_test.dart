import 'package:release_kit/src/engine/config.dart';
import 'package:release_kit/src/engine/diagnostic.dart';
import 'package:release_kit/src/engine/publish_target.dart';
import 'package:test/test.dart';

ReleaseConfig accepted(String source) {
  final diagnostics = Diagnostics();
  final config = ReleaseConfig.parse(source, 'release.toml', diagnostics);
  expect(
    config,
    isNotNull,
    reason: diagnostics.found.map((d) => d.toString()).join('\n'),
  );
  return config!;
}

/// Parses configuration rk must refuse, returning the code it refused with.
String refusedWith(String source) {
  final diagnostics = Diagnostics();
  final config = ReleaseConfig.parse(source, 'release.toml', diagnostics);
  expect(config, isNull, reason: 'should have been refused');
  expect(diagnostics.isNotEmpty, isTrue);
  return diagnostics.found.first.code;
}

const keybay = '''
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
  group('schema 2 target contracts', () {
    test('schema 1 is unsupported without a compatibility layer', () {
      final diagnostics = Diagnostics();
      final config = ReleaseConfig.parse('''
schema = 1

[release.core]
publish = ["pub.dev"]
''', 'release.toml', diagnostics);

      expect(config, isNull);
      expect(diagnostics.found.single.code, 'RK-CONF-002');
      expect(
        diagnostics.found.single.remedy,
        'upgrade rk, or use schema 2',
      );
    });

    test('a custom Homebrew tap is an owner/repository coordinate', () {
      for (final tap in [
        'https://github.com/example/homebrew-tools',
        '../homebrew-tools',
        'example/..',
      ]) {
        expect(
          refusedWith('''
schema = 2

[release.cli]
publish = ["git-tag", "github-release", "homebrew"]
binary_platforms = ["macos-arm64"]
homebrew_tap = "$tap"
'''),
          'RK-CONF-040',
          reason: tap,
        );
      }
    });

    test('an inline list splits into typed unit and project targets', () {
      final config = accepted('''
schema = 2

[release.cli]
path = "packages/cli"
publish = ["git-tag", "pub.dev", "github-release", "homebrew"]
binary_platforms = ["linux-x64"]
''');

      final unit = config.units.single;
      expect(
        unit.publish,
        {PublishTarget.gitTag, PublishTarget.githubRelease},
      );
      expect(
        unit.projects.single.publish,
        {PublishTarget.pubDev, PublishTarget.homebrew},
      );
    });

    test('a project target on a multi-project unit is refused', () {
      final diagnostics = Diagnostics();
      ReleaseConfig.parse('''
schema = 2

[release.framework]
tag = "framework-v{version}"
publish = ["git-tag", "pub.dev"]

[[release.framework.project]]
path = "packages/a"

[[release.framework.project]]
path = "packages/b"
''', 'release.toml', diagnostics);

      expect(
        diagnostics.found.map((diagnostic) => diagnostic.code),
        contains('RK-CONF-038'),
      );
    });

    test('a unit target on a project row is refused', () {
      final diagnostics = Diagnostics();
      ReleaseConfig.parse('''
schema = 2

[release.framework]
tag = "framework-v{version}"
publish = ["git-tag"]

[[release.framework.project]]
path = "packages/a"
publish = ["github-release"]

[[release.framework.project]]
path = "packages/b"
publish = ["pub.dev"]
''', 'release.toml', diagnostics);

      expect(
        diagnostics.found.map((diagnostic) => diagnostic.code),
        contains('RK-CONF-038'),
      );
    });

    test('a targetless unit is refused', () {
      expect(
        refusedWith('schema = 2\n[release.core]\npath = "packages/core"'),
        'RK-CONF-019',
      );
    });

    test('standalone binaries are a complete local release output', () {
      final config = accepted('''
schema = 2

[release.cli]
path = "packages/cli"
binary_platforms = ["linux-x64"]
''');

      final unit = config.units.single;
      expect(unit.publish, isEmpty);
      expect(unit.projects.single.publish, isEmpty);
      expect(unit.projects.single.binaryPlatforms, ['linux-x64']);
    });

    test('tag and GitHub declarations require git-tag', () {
      final tagDiagnostics = Diagnostics();
      ReleaseConfig.parse('''
schema = 2
[release.core]
tag = "v{version}"
publish = ["pub.dev"]
''', 'release.toml', tagDiagnostics);
      expect(
        tagDiagnostics.found.map((diagnostic) => diagnostic.code),
        contains('RK-CONF-039'),
      );

      final githubDiagnostics = Diagnostics();
      ReleaseConfig.parse('''
schema = 2
[release.cli]
publish = ["github-release"]
binary_platforms = ["linux-x64"]
''', 'release.toml', githubDiagnostics);
      expect(
        githubDiagnostics.found.map((diagnostic) => diagnostic.code),
        contains('RK-CONF-024'),
      );
    });
  });

  test('reads keybay\'s configuration', () {
    final config = accepted(keybay);
    expect(config.units.map((u) => u.name), ['core', 'cli']);

    final core = config.units.first;
    expect(core.projects, hasLength(1));
    expect(core.tagPattern, 'keybay-v{version}');
    expect(core.projects.single.path, 'packages/keybay');
    expect(core.projects.single.publish, {PublishTarget.pubDev});
    expect(core.projects.single.wantsBinaries, isFalse);

    final cli = config.units.last;
    expect(cli.projects.single.binaryPlatforms, hasLength(3));
    expect(cli.projects.single.wantsBinaries, isTrue);
  });

  test('reads a multi-project unit alongside a single one', () {
    final config = accepted('''
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

[release.mcp]
path = "packages/fleury_mcp"
publish = ["pub.dev"]
''');
    final framework = config.units.first;
    expect(framework.projects, hasLength(2));
    expect(framework.tagPattern, 'fleury-v{version}');
    expect(config.units.last.projects.single.path, 'packages/fleury_mcp');
  });

  test('an omitted path means the repository root', () {
    final config = accepted('''
schema = 2

[release.cli]
publish = ["pub.dev"]
''');
    expect(config.units.single.projects.single.path, '.');
  });

  test('paths are canonicalized', () {
    final config = accepted('''
schema = 2

[release.core]
path = "./packages/keybay/"
publish = ["pub.dev"]
''');
    expect(config.units.single.projects.single.path, 'packages/keybay');
  });

  test('a custom Homebrew tap lives on its release unit', () {
    final config = accepted('''
schema = 2

[release.cli]
publish = ["git-tag", "github-release", "homebrew"]
binary_platforms = ["macos-arm64"]
homebrew_tap = "danReynolds/homebrew-tools"
''');
    expect(config.units.single.homebrewTap, 'danReynolds/homebrew-tools');
  });

  group('a setting nothing in the unit can read is refused', () {
    test('homebrew_tap on a unit that does not publish to homebrew', () {
      expect(
        refusedWith('schema = 2\n[release.cli]\n'
            'publish = ["git-tag", "github-release"]\n'
            'binary_platforms = ["macos-arm64"]\n'
            'homebrew_tap = "danReynolds/homebrew-tools"\n'),
        'RK-CONF-036',
      );
    });
  });

  test('there is no team to declare, and no identity table to declare it in',
      () {
    // apple_team was discoverable all along — a machine with one Developer
    // ID certificate has nothing to say — and tag_signer was accepted,
    // stored, and read by nothing at all.
    expect(
      refusedWith('schema = 2\n[release.core]\npublish = ["pub.dev"]\n'
          '[identity]\napple_team = "5AHFA9FUZG"\n'),
      'RK-CONF-003',
    );
  });

  test('platforms may accompany a registry without GitHub Release', () {
    final config = accepted(
      'schema = 2\n[release.core]\npublish = ["pub.dev"]\n'
      'binary_platforms = ["macos-arm64"]',
    );
    expect(
        config.units.single.projects.single.binaryPlatforms, ['macos-arm64']);
  });

  group('refuses', () {
    test('a missing schema', () {
      expect(
          refusedWith('[release.core]\npublish = ["pub.dev"]'), 'RK-CONF-001');
    });

    test('an unsupported schema', () {
      expect(refusedWith('schema = 3\n[release.core]\npublish = ["pub.dev"]'),
          'RK-CONF-002');
    });

    test('an unknown top-level setting', () {
      expect(
        refusedWith('schema = 2\ntoolchain = "3.12.2"\n'
            '[release.core]\npublish = ["pub.dev"]'),
        'RK-CONF-003',
      );
    });

    test('no units at all', () {
      expect(refusedWith('schema = 2'), 'RK-CONF-004');
    });

    test('an unknown setting inside a unit', () {
      expect(
        refusedWith('schema = 2\n[release.core]\n'
            'publish = ["pub.dev"]\nlinux_deps = ["libsecret"]'),
        'RK-CONF-008',
      );
    });

    test('a unit declaring a project both inline and as rows', () {
      expect(
        refusedWith('schema = 2\n[release.core]\npath = "a"\n'
            'publish = ["pub.dev"]\n\n[[release.core.project]]\npath = "b"\n'
            'publish = ["pub.dev"]'),
        'RK-CONF-009',
      );
    });

    test('a multi-project unit without an explicit tag', () {
      expect(
        refusedWith('schema = 2\n[release.framework]\n'
            'publish = ["git-tag"]\n'
            '[[release.framework.project]]\n'
            'path = "a"\npublish = ["pub.dev"]\n\n'
            '[[release.framework.project]]\npath = "b"\npublish = ["pub.dev"]'),
        'RK-CONF-012',
      );
    });

    test('a tag pattern without {version}', () {
      expect(
        refusedWith('schema = 2\n[release.core]\ntag = "release"\n'
            'path = "a"\npublish = ["git-tag", "pub.dev"]'),
        'RK-CONF-014',
      );
    });

    test('a tag pattern with an invented placeholder', () {
      expect(
        refusedWith('schema = 2\n[release.core]\n'
            'tag = "{unit}-v{version}"\npath = "a"\n'
            'publish = ["git-tag", "pub.dev"]'),
        'RK-CONF-015',
      );
    });

    test('a path escaping the repository', () {
      expect(
        refusedWith('schema = 2\n[release.core]\npath = "../other"\n'
            'publish = ["pub.dev"]'),
        'RK-CONF-018',
      );
    });

    test('a project that publishes nowhere', () {
      expect(
          refusedWith('schema = 2\n[release.core]\npath = "a"'), 'RK-CONF-019');
    });

    test('an empty publish list', () {
      expect(refusedWith('schema = 2\n[release.core]\npublish = []'),
          'RK-CONF-019');
    });

    test('an unknown channel', () {
      expect(refusedWith('schema = 2\n[release.core]\npublish = ["npm"]'),
          'RK-CONF-022');
    });

    test('a duplicated channel', () {
      expect(
        refusedWith('schema = 2\n[release.core]\n'
            'publish = ["pub.dev", "pub.dev"]'),
        'RK-CONF-023',
      );
    });

    test('homebrew without github-release', () {
      expect(
        refusedWith('schema = 2\n[release.cli]\n'
            'publish = ["pub.dev", "homebrew"]\n'
            'binary_platforms = ["macos-arm64"]'),
        'RK-CONF-024',
      );
    });

    test('Homebrew requested with no platforms named', () {
      expect(
        refusedWith('schema = 2\n[release.cli]\n'
            'publish = ["git-tag", "github-release", "homebrew"]'),
        'RK-CONF-025',
      );
    });

    test('an unknown platform', () {
      expect(
        refusedWith('schema = 2\n[release.cli]\n'
            'publish = ["git-tag", "github-release"]\n'
            'binary_platforms = ["macos-x64"]'),
        'RK-CONF-028',
      );
    });

    test('an unknown setting on a unit', () {
      expect(
        refusedWith('schema = 2\n[release.core]\npublish = ["pub.dev"]\n'
            'signing_key = "x"'),
        'RK-CONF-008',
      );
    });
  });

  test('reports every problem in one pass', () {
    final diagnostics = Diagnostics();
    ReleaseConfig.parse('''
schema = 2
toolchain = "3.12.2"

[release.core]
publish = ["pub.dev"]
linux_deps = ["libsecret"]
''', 'release.toml', diagnostics);
    expect(
      diagnostics.found.map((d) => d.code),
      containsAll(['RK-CONF-003', 'RK-CONF-008']),
      reason: 'a fix cycle should be one edit round',
    );
  });
}
