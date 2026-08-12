import 'package:release_kit/src/engine/init_plan.dart';
import 'package:release_kit/src/engine/source_tree.dart';
import 'package:test/test.dart';

InitPlan discover(
  Map<String, String> files, {
  bool gitBound = true,
  bool hasRemote = true,
  String? githubRepository = 'owner/repo',
}) =>
    InitPlan.discover(
      tree: MemorySourceTree(files),
      gitBound: gitBound,
      hasRemote: hasRemote,
      githubRepository: githubRepository,
    );

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

    expect(tool.selected, {InitOption.gitTag, InitOption.pubDev});
    expect(tool.availability[InitOption.binary]!.available, isTrue);
    expect(tool.availability[InitOption.githubRelease]!.available, isTrue);
    expect(tool.availability[InitOption.homebrew]!.available, isTrue);
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
    final enabled = plan.toggle(0, InitOption.homebrew);
    plan = enabled.plan;

    expect(
      plan.candidates.single.selected,
      containsAll({
        InitOption.pubDev,
        InitOption.gitTag,
        InitOption.githubRelease,
        InitOption.binary,
        InitOption.homebrew,
      }),
    );
    expect(enabled.message, contains('Homebrew'));
    expect(plan.renderToml(), contains('"github-release", "homebrew"'));
    expect(plan.renderToml(), contains('binary_platforms = ['));

    final disabled = plan.toggle(0, InitOption.gitTag);
    expect(disabled.plan.candidates.single.selected, {InitOption.pubDev});
    expect(disabled.message, contains('disabled'));
  });

  test('a unit is included exactly when it has a selected target', () {
    var plan = discover({'pubspec.yaml': 'name: a\nversion: 1.0.0\n'});

    plan = plan.toggle(0, InitOption.gitTag).plan;
    plan = plan.toggle(0, InitOption.pubDev).plan;
    expect(plan.candidates.single.selected, isEmpty);
    expect(plan.included, isEmpty);

    plan = plan.toggle(0, InitOption.gitTag).plan;
    expect(plan.included.single.name, 'a');
  });

  test('several units expose tags but do not invent their grouping', () {
    var plan = discover({
      'a/pubspec.yaml': 'name: a\nversion: 1.0.0\n',
      'b/pubspec.yaml': 'name: b\nversion: 2.0.0\n',
    });
    expect(
      plan.candidates.every(
        (candidate) => !candidate.selected.contains(InitOption.gitTag),
      ),
      isTrue,
    );

    plan = plan.toggle(0, InitOption.gitTag).plan;
    plan = plan.toggle(1, InitOption.gitTag).plan;
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
    expect(a.selected, {InitOption.pubDev});
    expect(a.availability[InitOption.gitTag]!.available, isFalse);
    expect(a.availability[InitOption.githubRelease]!.available, isFalse);
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
    expect(
        internal.availability[InitOption.pubDev]!.reason, contains('vetoes'));

    plan = plan.toggle(0, InitOption.gitTag).plan;
    expect(plan.candidates.single.selected, {InitOption.gitTag});
  });

  test('one public package does not silently tag neighboring private ones', () {
    final plan = discover({
      'public/pubspec.yaml': 'name: public\nversion: 1.0.0\n',
      'internal/pubspec.yaml':
          'name: internal\nversion: 1.0.0\npublish_to: none\n',
    });

    expect(
      plan.candidates.singleWhere((item) => item.name == 'public').selected,
      {InitOption.pubDev, InitOption.gitTag},
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
    expect(declared.candidates.single.availability[InitOption.pubDev]!.reason,
        contains('custom registry'));

    final mixed = discover({
      'public/pubspec.yaml': 'name: public\nversion: 1.0.0\n',
      'private/pubspec.yaml': 'name: private\nversion: 1.0.0\n'
          'publish_to: https://packages.example.invalid\n',
    });
    expect(
      mixed.candidates.singleWhere((item) => item.name == 'public').selected,
      {InitOption.pubDev, InitOption.gitTag},
    );

    final ambient = InitPlan.discover(
      tree: MemorySourceTree({
        'pubspec.yaml': 'name: ambient\nversion: 1.0.0\n',
      }),
      gitBound: true,
      hasRemote: true,
      githubRepository: 'owner/repo',
      ambientPubHostedUrl: 'https://token@packages.example.invalid',
    );
    expect(ambient.candidates.single.selected, isEmpty);
    expect(ambient.toJson().toString(), isNot(contains('token')));
    expect(ambient.toJson().toString(), isNot(contains('packages.example')));
  });

  test('tracked examples stay visible without becoming release intent', () {
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
    expect(root.selected, {InitOption.pubDev, InitOption.gitTag});
    for (final name in ['example_tool', 'fixture_package']) {
      final candidate =
          plan.candidates.singleWhere((item) => item.name == name);
      expect(candidate.selected, isEmpty);
      expect(candidate.availability[InitOption.pubDev]!.available, isTrue);
      expect(candidate.availability[InitOption.pubDev]!.reason,
          contains('start unselected'));
    }
    expect(plan.renderToml(), isNot(contains('release.example_tool')));
  });
}
