import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/init_plan.dart';
import 'package:rk/src/engine/release_choice.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:test/test.dart';

InitPlan discover(
  Map<String, String> files, {
  bool gitBound = true,
  bool hasRemote = true,
  String? githubRepository = 'owner/repo',
  HostCapabilities? capabilities,
}) {
  final host = capabilities ??
      HostCapabilities(
        hostPlatform: 'macos-arm64',
        containerRuntime: 'docker',
        hasNativeAssets: false,
      );
  return InitPlan.discover(
    tree: MemorySourceTree(files),
    gitBound: gitBound,
    hasRemote: hasRemote,
    githubRepository: githubRepository,
    platformCapabilities:
        ReleaseConfig.supportedPlatformsList.map(host.resolve),
  );
}

void main() {
  test('discovery selects only declared, unambiguous release intent', () {
    final plan = discover({
      'pubspec.yaml': '''
name: tool
version: 1.2.3
executables:
  tool: tool
''',
    });
    final tool = plan.candidates.single;

    expect(tool.selected, {ReleaseChoice.gitTag, ReleaseChoice.pubDev});
    expect(tool.availability[ReleaseChoice.binary]!.available, isTrue);
    expect(tool.availability[ReleaseChoice.githubRelease]!.available, isTrue);
    expect(tool.availability[ReleaseChoice.homebrew]!.available, isTrue);
    expect(plan.renderToml(), contains('publish = ["git-tag", "pub.dev"]'));
    expect(plan.renderToml(), isNot(contains('binary_platforms')));
  });

  test('Homebrew enables its producer and destination prerequisites', () {
    var plan = discover({
      'pubspec.yaml': '''
name: tool
version: 1.2.3
executables:
  tool: tool
''',
    });
    final enabled = plan.toggle(0, ReleaseChoice.homebrew);
    plan = enabled.plan;

    expect(
      plan.candidates.single.selected,
      containsAll({
        ReleaseChoice.pubDev,
        ReleaseChoice.gitTag,
        ReleaseChoice.githubRelease,
        ReleaseChoice.binary,
        ReleaseChoice.homebrew,
      }),
    );
    expect(enabled.message, contains('Homebrew'));
    expect(plan.renderToml(), contains('"github-release", "homebrew"'));
    expect(plan.renderToml(), contains('binary_platforms = ['));

    final disabled = plan.toggle(0, ReleaseChoice.gitTag);
    expect(
      disabled.plan.candidates.single.selected,
      {ReleaseChoice.pubDev, ReleaseChoice.binary},
      reason: 'removing public destinations keeps a valid local output',
    );
    expect(disabled.message, contains('disabled'));
  });

  test('Linux init proposes its native platform and no macOS binary', () {
    var plan = discover(
      {
        'pubspec.yaml': '''
name: tool
version: 1.2.3
executables:
  tool: tool
''',
      },
      capabilities: HostCapabilities(
        hostPlatform: 'linux-x64',
        containerRuntime: null,
        hasNativeAssets: false,
      ),
    );

    plan = plan.toggle(0, ReleaseChoice.homebrew).plan;
    final proposal = plan.renderToml();

    expect(proposal, contains('"linux-x64"'));
    expect(proposal, isNot(contains('"linux-arm64"')));
    expect(proposal, isNot(contains('"macos-arm64"')));
    expect(
      plan.binaryPlatformNotices,
      contains(
        startsWith('macos-arm64 was not selected:'),
      ),
    );
    expect(
      plan.binaryPlatformNotices,
      contains(
        contains('container runtime is optional'),
      ),
      reason: 'the cross-build stays available without Docker, but init '
          'does not silently opt into weaker execution evidence',
    );
  });

  test('native assets keep init on the host platform', () {
    var plan = discover(
      {
        'pubspec.yaml': '''
name: tool
version: 1.2.3
executables:
  tool: tool
''',
      },
      capabilities: HostCapabilities(
        hostPlatform: 'linux-x64',
        containerRuntime: 'docker',
        hasNativeAssets: true,
      ),
    );

    plan = plan.toggle(0, ReleaseChoice.binary).plan;

    expect(
      plan.renderToml(),
      contains('binary_platforms = ["linux-x64"]'),
    );
    expect(plan.binaryPlatformNotices, hasLength(2));
  });

  test('GitHub Release does not imply a binary', () {
    var plan = discover({
      'pubspec.yaml': '''
name: tool
version: 1.2.3
executables:
  tool: tool
''',
    });

    plan = plan.toggle(0, ReleaseChoice.githubRelease).plan;

    expect(
      plan.candidates.single.selected,
      {ReleaseChoice.gitTag, ReleaseChoice.pubDev, ReleaseChoice.githubRelease},
    );
    expect(plan.renderToml(), isNot(contains('binary_platforms')));
  });

  test('a unit is included exactly when it has a selected release output', () {
    var plan = discover({'pubspec.yaml': 'name: a\nversion: 1.0.0\n'});

    plan = plan.toggle(0, ReleaseChoice.gitTag).plan;
    plan = plan.toggle(0, ReleaseChoice.pubDev).plan;
    expect(plan.candidates.single.selected, isEmpty);
    expect(plan.included, isEmpty);

    plan = plan.toggle(0, ReleaseChoice.gitTag).plan;
    expect(plan.included.single.name, 'a');
  });

  test('Binary is an independent local output', () {
    var plan = discover(
      {
        'pubspec.yaml': '''
name: tool
version: 1.2.3
publish_to: none
executables:
  tool: tool
''',
      },
      gitBound: false,
      hasRemote: false,
      githubRepository: null,
    );

    final candidate = plan.candidates.single;
    expect(candidate.selected, isEmpty);
    expect(candidate.availability[ReleaseChoice.binary]!.available, isTrue);
    expect(candidate.availability[ReleaseChoice.githubRelease]!.available,
        isFalse);

    plan = plan.toggle(0, ReleaseChoice.binary).plan;
    expect(plan.candidates.single.selected, {ReleaseChoice.binary});
    expect(plan.included.single.name, 'tool');
    expect(plan.renderToml(), contains('binary_platforms = ['));
    expect(plan.renderToml(), isNot(contains('publish =')));
    expect(ReleaseChoice.binary.requires, isEmpty);
  });

  test('several units expose tags but do not invent their grouping', () {
    var plan = discover({
      'a/pubspec.yaml': 'name: a\nversion: 1.0.0\n',
      'b/pubspec.yaml': 'name: b\nversion: 2.0.0\n',
    });
    expect(
      plan.candidates.every(
        (candidate) => !candidate.selected.contains(ReleaseChoice.gitTag),
      ),
      isTrue,
    );

    plan = plan.toggle(0, ReleaseChoice.gitTag).plan;
    plan = plan.toggle(1, ReleaseChoice.gitTag).plan;
    final toml = plan.renderToml();
    expect(toml, contains('tag = "a-v{version}"'));
    expect(toml, contains('tag = "b-v{version}"'));
  });

  test('non-Git discovery follows only declared Dart workspace members', () {
    final plan = discover(
      {
        'pubspec.yaml': '''
name: root
workspace:
  - packages/a
''',
        'packages/a/pubspec.yaml': 'name: a\nversion: 1.0.0\n',
        'packages/stray/pubspec.yaml': 'name: stray\nversion: 1.0.0\n',
      },
      gitBound: false,
      hasRemote: false,
      githubRepository: null,
    );

    expect(plan.candidates.map((candidate) => candidate.name),
        unorderedEquals(['root', 'a']));
    final a = plan.candidates.singleWhere((candidate) => candidate.name == 'a');
    expect(a.selected, {ReleaseChoice.pubDev});
    expect(a.availability[ReleaseChoice.gitTag]!.available, isFalse);
    expect(a.availability[ReleaseChoice.githubRelease]!.available, isFalse);
    expect(plan.toJson()['source'], {
      'binding': 'unbound',
      'git_remote': false,
      'github_repository': null,
    });
  });

  test('vetoed packages remain visible and may be selected for Git tags', () {
    var plan = discover({
      'pubspec.yaml': 'name: internal\nversion: 1.0.0\npublish_to: none\n',
    });
    final internal = plan.candidates.single;
    expect(internal.selected, isEmpty);
    expect(internal.availability[ReleaseChoice.pubDev]!.reason,
        contains('vetoes'));

    plan = plan.toggle(0, ReleaseChoice.gitTag).plan;
    expect(plan.candidates.single.selected, {ReleaseChoice.gitTag});
  });

  test('one public package does not silently tag neighboring private ones', () {
    final plan = discover({
      'public/pubspec.yaml': 'name: public\nversion: 1.0.0\n',
      'internal/pubspec.yaml':
          'name: internal\nversion: 1.0.0\npublish_to: none\n',
    });

    expect(
      plan.candidates.singleWhere((item) => item.name == 'public').selected,
      {ReleaseChoice.pubDev, ReleaseChoice.gitTag},
    );
    final internal =
        plan.candidates.singleWhere((item) => item.name == 'internal');
    expect(internal.selected, isEmpty);
    expect(plan.renderToml(), isNot(contains('[release.internal]')));
  });

  test('custom and ambient Dart registries stay visible but unselected', () {
    final declared = discover({
      'pubspec.yaml': '''
name: private_package
version: 1.0.0
publish_to: https://token@packages.example.invalid
''',
    });
    expect(declared.candidates.single.selected, isEmpty);
    expect(
        declared.candidates.single.availability[ReleaseChoice.pubDev]!.reason,
        contains('custom registry'));

    final mixed = discover({
      'public/pubspec.yaml': 'name: public\nversion: 1.0.0\n',
      'private/pubspec.yaml': 'name: private\nversion: 1.0.0\n'
          'publish_to: https://packages.example.invalid\n',
    });
    expect(
      mixed.candidates.singleWhere((item) => item.name == 'public').selected,
      {ReleaseChoice.pubDev, ReleaseChoice.gitTag},
    );

    final ambient = InitPlan.discover(
      tree: MemorySourceTree({
        'pubspec.yaml': 'name: ambient\nversion: 1.0.0\n',
      }),
      gitBound: true,
      hasRemote: true,
      githubRepository: 'owner/repo',
      platformCapabilities: ReleaseConfig.supportedPlatformsList.map(
        HostCapabilities(
          hostPlatform: 'macos-arm64',
          containerRuntime: 'docker',
          hasNativeAssets: false,
        ).resolve,
      ),
      ambientPubHostedUrl: 'https://token@packages.example.invalid',
    );
    expect(ambient.candidates.single.selected, isEmpty);
    expect(ambient.toJson().toString(), isNot(contains('token')));
    expect(ambient.toJson().toString(), isNot(contains('packages.example')));
  });

  test('tracked examples and fixtures are omitted from init discovery', () {
    final plan = discover({
      'pubspec.yaml': 'name: rk\nversion: 1.0.0\n',
      'examples/tool/pubspec.yaml': '''
name: example_tool
version: 2.0.0
executables:
  tool: tool
''',
      'fixtures/package/pubspec.yaml':
          'name: fixture_package\nversion: 3.0.0\n',
    });

    final root = plan.candidates.singleWhere((item) => item.name == 'rk');
    expect(root.selected, {ReleaseChoice.pubDev, ReleaseChoice.gitTag});
    expect(plan.candidates, hasLength(1));
    expect(plan.notices, isEmpty);
    expect(plan.renderToml(), isNot(contains('release.example_tool')));
  });
}
