import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/publish_target.dart';
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

/// Parses configuration rk must refuse, returning its first problem as
/// `<code> <line> <message>`: the kind of mistake, and where and what it is.
String refusal(String source) {
  final diagnostics = Diagnostics();
  final config = ReleaseConfig.parse(source, 'release.toml', diagnostics);
  expect(config, isNull, reason: 'should have been refused');
  expect(diagnostics.isNotEmpty, isTrue);
  final first = diagnostics.found.first;
  return '${first.code} ${first.source?.line} ${first.message}';
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
    test('a custom Homebrew tap is an owner/repository coordinate', () {
      for (final tap in [
        'https://github.com/example/homebrew-tools',
        '../homebrew-tools',
        'example/..',
      ]) {
        expect(
          refusal('''
schema = 2

[release.cli]
publish = ["git-tag", "github-release", "homebrew"]
binary_platforms = ["macos-arm64"]
homebrew_tap = "$tap"
'''),
          'RK-CONF-005 6 homebrew_tap: must be a GitHub owner/repository',
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
      expect(unit.publish, {PublishTarget.gitTag, PublishTarget.githubRelease});
      expect(unit.projects.single.publish, {
        PublishTarget.pubDev,
        PublishTarget.homebrew,
      });
    });

    test('a project target on a multi-project unit is refused', () {
      expect(
        refusal('''
schema = 2

[release.framework]
tag = "framework-v{version}"
publish = ["git-tag", "pub.dev"]

[[release.framework.project]]
path = "packages/a"

[[release.framework.project]]
path = "packages/b"
'''),
        'RK-CONF-003 5 "pub.dev" belongs to a project in "framework"',
      );
    });

    test('a unit target on a project row is refused', () {
      expect(
        refusal('''
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
'''),
        'RK-CONF-003 9 "github-release" belongs to the unit "framework"',
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
      expect(
        refusal('''
schema = 2
[release.core]
tag = "v{version}"
publish = ["pub.dev"]
'''),
        'RK-CONF-009 3 unit "core" declares a tag but does not publish a Git '
        'tag',
      );
      expect(
        refusal('''
schema = 2
[release.cli]
publish = ["github-release"]
binary_platforms = ["linux-x64"]
'''),
        'RK-CONF-009 3 github-release needs git-tag',
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
        refusal(
          'schema = 2\n[release.cli]\n'
          'publish = ["git-tag", "github-release"]\n'
          'binary_platforms = ["macos-arm64"]\n'
          'homebrew_tap = "danReynolds/homebrew-tools"\n',
        ),
        'RK-CONF-009 5 unit "cli" declares homebrew_tap but does not publish '
        'to homebrew',
      );
    });
  });

  test('platforms may accompany a registry without GitHub Release', () {
    final config = accepted(
      'schema = 2\n[release.core]\npublish = ["pub.dev"]\n'
      'binary_platforms = ["macos-arm64"]',
    );
    expect(config.units.single.projects.single.binaryPlatforms, [
      'macos-arm64',
    ]);
  });

  group('refuses', () {
    test('a missing schema', () {
      expect(
        refusal('[release.core]\npublish = ["pub.dev"]'),
        'RK-CONF-002 1 release.toml must declare its schema version',
      );
    });

    test('an unsupported schema', () {
      expect(
        refusal('schema = 3\n[release.core]\npublish = ["pub.dev"]'),
        startsWith('RK-CONF-002 1 this rk understands schema 2'),
      );
    });

    test('an unknown top-level setting', () {
      expect(
        refusal(
          'schema = 2\ntoolchain = "3.12.2"\n'
          '[release.core]\npublish = ["pub.dev"]',
        ),
        'RK-CONF-003 2 unknown setting "toolchain"',
      );
    });

    test('no units at all', () {
      expect(
        refusal('schema = 2'),
        'RK-CONF-005 1 release.toml declares no release units',
      );
    });

    test('an unknown setting inside a unit', () {
      expect(
        refusal(
          'schema = 2\n[release.core]\n'
          'publish = ["pub.dev"]\nlinux_deps = ["libsecret"]',
        ),
        'RK-CONF-003 4 unknown setting "linux_deps" in unit "core"',
      );
    });

    test('a unit declaring a project both inline and as rows', () {
      expect(
        refusal(
          'schema = 2\n[release.core]\npath = "a"\n'
          'publish = ["pub.dev"]\n\n[[release.core.project]]\npath = "b"\n'
          'publish = ["pub.dev"]',
        ),
        'RK-CONF-009 2 unit "core" declares a project inline and also as rows',
      );
    });

    test('a multi-project unit without an explicit tag', () {
      expect(
        refusal(
          'schema = 2\n[release.framework]\n'
          'publish = ["git-tag"]\n'
          '[[release.framework.project]]\n'
          'path = "a"\npublish = ["pub.dev"]\n\n'
          '[[release.framework.project]]\npath = "b"\npublish = ["pub.dev"]',
        ),
        'RK-CONF-009 2 unit "framework" releases several projects, so its tag '
        'cannot be derived',
      );
    });

    test('a tag pattern without {version}', () {
      expect(
        refusal(
          'schema = 2\n[release.core]\ntag = "release"\n'
          'path = "a"\npublish = ["git-tag", "pub.dev"]',
        ),
        'RK-CONF-005 3 tag: must contain {version} exactly once',
      );
    });

    test('a tag pattern with an invented placeholder', () {
      expect(
        refusal(
          'schema = 2\n[release.core]\n'
          'tag = "{unit}-v{version}"\npath = "a"\n'
          'publish = ["git-tag", "pub.dev"]',
        ),
        startsWith('RK-CONF-005 3 tag: uses a placeholder rk does not have'),
      );
    });

    test('a tag pattern git cannot create', () {
      for (final tag in ['v{version} rc', 'v{version}.lock', 'v..{version}']) {
        expect(
          refusal(
            'schema = 2\n[release.core]\ntag = "$tag"\n'
            'path = "a"\npublish = ["git-tag", "pub.dev"]',
          ),
          startsWith('RK-CONF-005 3 tag: git will not accept it'),
          reason: tag,
        );
      }
      accepted(
        'schema = 2\n[release.core]\ntag = "releases/cli-v{version}"\n'
        'path = "a"\npublish = ["git-tag", "pub.dev"]',
      );
    });

    test('a tag on a project row, which belongs to its unit', () {
      expect(
        refusal(
          'schema = 2\n[release.framework]\ntag = "fleury-v{version}"\n'
          'publish = ["git-tag"]\n'
          '[[release.framework.project]]\npath = "packages/a"\n'
          'publish = ["pub.dev"]\ntag = "a-v{version}"',
        ),
        'RK-CONF-003 8 "tag" belongs to the unit "framework", not to one of '
        'its projects',
      );
    });

    test('a path escaping the repository', () {
      expect(
        refusal(
          'schema = 2\n[release.core]\npath = "../other"\n'
          'publish = ["pub.dev"]',
        ),
        startsWith('RK-CONF-005 3 path: "../other" leaves the repository'),
      );
    });

    test('a project that publishes nowhere', () {
      expect(
        refusal('schema = 2\n[release.core]\npath = "a"'),
        'RK-CONF-009 2 unit "core" selects no release output',
      );
    });

    test('an empty publish list', () {
      expect(
        refusal('schema = 2\n[release.core]\npublish = []'),
        'RK-CONF-009 2 unit "core" selects no release output',
      );
    });

    test('an unknown channel', () {
      expect(
        refusal('schema = 2\n[release.core]\npublish = ["npm"]'),
        'RK-CONF-005 3 publish: "npm" is not one of git-tag, pub.dev, '
        'github-release, homebrew',
      );
    });

    test('a duplicated channel', () {
      expect(
        refusal(
          'schema = 2\n[release.core]\n'
          'publish = ["pub.dev", "pub.dev"]',
        ),
        'RK-CONF-005 3 publish: "pub.dev" is listed twice',
      );
    });

    test('homebrew without github-release', () {
      expect(
        refusal(
          'schema = 2\n[release.cli]\n'
          'publish = ["pub.dev", "homebrew"]\n'
          'binary_platforms = ["macos-arm64"]',
        ),
        'RK-CONF-009 2 homebrew needs github-release',
      );
    });

    test('Homebrew requested with no platforms named', () {
      expect(
        refusal(
          'schema = 2\n[release.cli]\n'
          'publish = ["git-tag", "github-release", "homebrew"]',
        ),
        'RK-CONF-009 2 a Homebrew project in "cli" names no binary platforms',
      );
    });

    test('an unknown platform', () {
      expect(
        refusal(
          'schema = 2\n[release.cli]\n'
          'publish = ["git-tag", "github-release"]\n'
          'binary_platforms = ["macos-x64"]',
        ),
        'RK-CONF-005 4 binary_platforms: "macos-x64" is not one of '
        'linux-x64, linux-arm64, macos-arm64',
      );
    });
  });

  test('reports every problem in one pass', () {
    final diagnostics = Diagnostics();
    ReleaseConfig.parse(
      '''
schema = 2
toolchain = "3.12.2"

[release.core]
publish = ["pub.dev"]
linux_deps = ["libsecret"]
''',
      'release.toml',
      diagnostics,
    );
    expect(
      diagnostics.found.map((d) => '${d.code} ${d.source?.line} ${d.message}'),
      [
        'RK-CONF-003 2 unknown setting "toolchain"',
        'RK-CONF-003 6 unknown setting "linux_deps" in unit "core"',
      ],
      reason: 'a fix cycle should be one edit round',
    );
  });
  group('a project that builds its own release assets', () {
    String unit(
      String settings, {
      String publish = '"git-tag", "github-release"',
    }) =>
        '''
schema = 2

[release.parser]
tag = "parser-v{version}"
path = "native/parser"
publish = [$publish]
$settings
''';
    const declared =
        'build = ["tool/build.sh", "{out}"]\n'
        'assets = ["assets/parser-linux-x64.so", "parser-macos-arm64.dylib"]\n';

    test('declares its command and the files it writes', () {
      final project = accepted(unit(declared)).units.single.projects.single;
      expect(project.build, ['tool/build.sh', '{out}']);
      expect(project.assets, [
        'assets/parser-linux-x64.so',
        'parser-macos-arm64.dylib',
      ]);
      expect(project.buildsAssets, isTrue);
      expect(project.binaryPlatforms, isEmpty);
    });

    test('as a project row too', () {
      final config = accepted('''
schema = 2

[release.parser]
tag = "parser-v{version}"
publish = ["git-tag", "github-release"]

[[release.parser.project]]
path = "native/parser"
build = ["make", "OUT={out}"]
assets = ["libparser.so"]
''');
      expect(config.units.single.projects.single.build, ['make', 'OUT={out}']);
    });

    test('names a command, not an empty one', () {
      expect(
        refusal(unit('build = []\nassets = ["a.so"]\n')),
        'RK-CONF-005 7 build: is empty',
      );
      expect(
        refusal(unit('build = ["tool/build.sh", ""]\nassets = ["a.so"]\n')),
        'RK-CONF-005 7 build: an argument is empty',
      );
      expect(
        refusal(unit('build = "tool/build.sh"\nassets = ["a.so"]\n')),
        'RK-CONF-005 7 build: must be a list of text',
      );
    });

    test('has no placeholder but {out}', () {
      expect(
        refusal(
          unit('build = ["tool/build.sh", "{version}"]\nassets = ["a.so"]\n'),
        ),
        startsWith(
          'RK-CONF-005 7 build: "{version}" uses a placeholder rk does not '
          'have',
        ),
      );
    });

    test('names each asset inside the build output', () {
      for (final asset in [
        '/abs/a.so',
        '../a.so',
        'x/../a.so',
        'x//a.so',
        'x/',
      ]) {
        expect(
          refusal(unit('build = ["b"]\nassets = ["$asset"]\n')),
          startsWith(
            'RK-CONF-005 8 assets: "$asset" is not a file inside the build\'s '
            'output',
          ),
          reason: asset,
        );
      }
      expect(
        refusal(unit('build = ["b"]\nassets = []\n')),
        'RK-CONF-005 8 assets: is empty',
      );
    });

    test('publishes each asset under a name of its own', () {
      expect(
        refusal(unit('build = ["b"]\nassets = ["x/a.so", "y/A.so"]\n')),
        'RK-CONF-005 8 assets: "x/a.so" and "y/A.so" would be published under '
        'one name',
        reason: 'GitHub compares asset names without case',
      );
      expect(
        refusal(unit('build = ["b"]\nassets = ["x/release-manifest.json"]\n')),
        'RK-CONF-005 8 assets: "x/release-manifest.json" would be published as '
        "release-manifest.json, which is rk's own",
      );
    });

    test('declares the command and the assets together', () {
      expect(
        refusal(unit('build = ["b"]\n')),
        'RK-CONF-009 7 a project of "parser" declares a build without assets',
      );
      expect(
        refusal(unit('assets = ["a.so"]\n')),
        'RK-CONF-009 7 a project of "parser" declares assets without a build',
      );
    });

    test('does not also ask rk for binaries', () {
      expect(
        refusal(unit('${declared}binary_platforms = ["linux-x64"]\n')),
        'RK-CONF-009 7 a project of "parser" declares both a build and '
        'binary_platforms',
      );
    });

    test('publishes its assets as a GitHub release', () {
      expect(
        refusal(unit(declared, publish: '"git-tag"')),
        'RK-CONF-009 3 unit "parser" builds release assets but does not '
        'publish a GitHub release',
      );
    });

    test('keeps its settings on its own row when the unit has rows', () {
      expect(
        refusal('''
schema = 2

[release.parser]
tag = "parser-v{version}"
publish = ["git-tag", "github-release"]
build = ["b"]

[[release.parser.project]]
path = "native/parser"
assets = ["a.so"]
'''),
        'RK-CONF-009 3 unit "parser" declares a project inline and also as '
        'rows',
      );
    });
  });
}
