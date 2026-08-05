import 'package:release_kit/src/engine/config.dart';
import 'package:release_kit/src/engine/diagnostic.dart';
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
schema = 1

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]

[release.cli]
path = "packages/keybay_cli"
publish = ["pub.dev", "github-release", "homebrew"]
binary_platforms = ["linux-x64", "linux-arm64", "macos-arm64"]
''';

void main() {
  test('reads keybay\'s configuration', () {
    final config = accepted(keybay);
    expect(config.units.map((u) => u.name), ['core', 'cli']);

    final core = config.units.first;
    expect(core.projects, hasLength(1));
    expect(core.tagPattern, isNull, reason: 'derived, not declared');
    expect(core.projects.single.path, 'packages/keybay');
    expect(core.projects.single.channels, {'pub.dev'});
    expect(core.projects.single.wantsBinaries, isFalse);

    final cli = config.units.last;
    expect(cli.projects.single.binaryPlatforms, hasLength(3));
    expect(cli.projects.single.wantsBinaries, isTrue);
  });

  test('reads a multi-project unit alongside a single one', () {
    final config = accepted('''
schema = 1

[release.framework]
tag = "fleury-v{version}"

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
schema = 1

[release.cli]
publish = ["pub.dev"]
''');
    expect(config.units.single.projects.single.path, '.');
  });

  test('paths are canonicalized', () {
    final config = accepted('''
schema = 1

[release.core]
path = "./packages/keybay/"
publish = ["pub.dev"]
''');
    expect(config.units.single.projects.single.path, 'packages/keybay');
  });

  test('the two identity overrides live on the unit that owns them', () {
    // Per unit, not per repository: a repository with two binary units has
    // two program identities and possibly two taps, and the global
    // [identity] table this replaced would have signed both as one program.
    final config = accepted('''
schema = 1

[release.cli]
publish = ["pub.dev"]
code_id = "io.github.danreynolds.keybay.cli"
homebrew_tap = "danReynolds/homebrew-tools"
''');
    expect(config.units.single.codeId, 'io.github.danreynolds.keybay.cli');
    expect(config.units.single.homebrewTap, 'danReynolds/homebrew-tools');
  });

  test('there is no team to declare, and no identity table to declare it in',
      () {
    // apple_team was discoverable all along — a machine with one Developer
    // ID certificate has nothing to say — and tag_signer was accepted,
    // stored, and read by nothing at all.
    expect(
      refusedWith('schema = 1\n[release.core]\npublish = ["pub.dev"]\n'
          '[identity]\napple_team = "5AHFA9FUZG"\n'),
      'RK-CONF-003',
    );
  });

  group('refuses', () {
    test('a missing schema', () {
      expect(
          refusedWith('[release.core]\npublish = ["pub.dev"]'), 'RK-CONF-001');
    });

    test('an unsupported schema', () {
      expect(refusedWith('schema = 2\n[release.core]\npublish = ["pub.dev"]'),
          'RK-CONF-002');
    });

    test('an unknown top-level setting', () {
      expect(
        refusedWith('schema = 1\ntoolchain = "3.12.2"\n'
            '[release.core]\npublish = ["pub.dev"]'),
        'RK-CONF-003',
      );
    });

    test('no units at all', () {
      expect(refusedWith('schema = 1'), 'RK-CONF-004');
    });

    test('an unknown setting inside a unit', () {
      expect(
        refusedWith('schema = 1\n[release.core]\n'
            'publish = ["pub.dev"]\nlinux_deps = ["libsecret"]'),
        'RK-CONF-008',
      );
    });

    test('a unit declaring a project both inline and as rows', () {
      expect(
        refusedWith('schema = 1\n[release.core]\npath = "a"\n'
            'publish = ["pub.dev"]\n\n[[release.core.project]]\npath = "b"\n'
            'publish = ["pub.dev"]'),
        'RK-CONF-009',
      );
    });

    test('a unit with no projects', () {
      expect(refusedWith('schema = 1\n[release.core]\ntag = "v{version}"'),
          'RK-CONF-011');
    });

    test('a multi-project unit without an explicit tag', () {
      expect(
        refusedWith('schema = 1\n[[release.framework.project]]\n'
            'path = "a"\npublish = ["pub.dev"]\n\n'
            '[[release.framework.project]]\npath = "b"\npublish = ["pub.dev"]'),
        'RK-CONF-012',
      );
    });

    test('a tag pattern without {version}', () {
      expect(
        refusedWith('schema = 1\n[release.core]\ntag = "release"\n'
            'path = "a"\npublish = ["pub.dev"]'),
        'RK-CONF-014',
      );
    });

    test('a tag pattern with an invented placeholder', () {
      expect(
        refusedWith('schema = 1\n[release.core]\n'
            'tag = "{unit}-v{version}"\npath = "a"\npublish = ["pub.dev"]'),
        'RK-CONF-015',
      );
    });

    test('a path escaping the repository', () {
      expect(
        refusedWith('schema = 1\n[release.core]\npath = "../other"\n'
            'publish = ["pub.dev"]'),
        'RK-CONF-018',
      );
    });

    test('a project that publishes nowhere', () {
      expect(
          refusedWith('schema = 1\n[release.core]\npath = "a"'), 'RK-CONF-019');
    });

    test('an empty publish list', () {
      expect(refusedWith('schema = 1\n[release.core]\npublish = []'),
          'RK-CONF-021');
    });

    test('an unknown channel', () {
      expect(refusedWith('schema = 1\n[release.core]\npublish = ["npm"]'),
          'RK-CONF-022');
    });

    test('a duplicated channel', () {
      expect(
        refusedWith('schema = 1\n[release.core]\n'
            'publish = ["pub.dev", "pub.dev"]'),
        'RK-CONF-023',
      );
    });

    test('homebrew without github-release', () {
      expect(
        refusedWith('schema = 1\n[release.cli]\n'
            'publish = ["pub.dev", "homebrew"]\n'
            'binary_platforms = ["macos-arm64"]'),
        'RK-CONF-024',
      );
    });

    test('binaries requested with no platforms named', () {
      expect(
        refusedWith('schema = 1\n[release.cli]\npublish = ["github-release"]'),
        'RK-CONF-025',
      );
    });

    test('platforms named with no binary channel', () {
      expect(
        refusedWith('schema = 1\n[release.core]\npublish = ["pub.dev"]\n'
            'binary_platforms = ["macos-arm64"]'),
        'RK-CONF-026',
      );
    });

    test('an unknown platform', () {
      expect(
        refusedWith('schema = 1\n[release.cli]\n'
            'publish = ["github-release"]\n'
            'binary_platforms = ["macos-x64"]'),
        'RK-CONF-028',
      );
    });

    test('an unknown setting on a unit', () {
      expect(
        refusedWith('schema = 1\n[release.core]\npublish = ["pub.dev"]\n'
            'signing_key = "x"'),
        'RK-CONF-008',
      );
    });
  });

  test('reports every problem in one pass', () {
    final diagnostics = Diagnostics();
    ReleaseConfig.parse('''
schema = 1
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
