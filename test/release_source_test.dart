import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/release_source.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/stage_source.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:test/test.dart';

/// Where status, plan, stage and release read release.toml from, against
/// real repositories.
void main() {
  late Directory root;

  void git(List<String> args) {
    final result = Process.runSync('git', args, workingDirectory: root.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('rk-release-source-');
    _write(root, 'release.toml', '''
schema = 2

[release.tool]
publish = ["pub.dev"]
''');
    _write(root, 'pubspec.yaml', 'name: tool\nversion: 1.0.0\n');
    _write(root, 'CHANGELOG.md', '## 1.0.0\n');
  });

  tearDown(() => root.deleteSync(recursive: true));

  void commitAll() {
    git(['init', '-q']);
    git(['config', 'user.email', 'rk@example.test']);
    git(['config', 'user.name', 'rk tests']);
    git(['add', '-A']);
    git(['commit', '-qm', 'initial']);
  }

  test('a clean repository is read at its commit, and can be staged', () async {
    commitAll();
    final source = await ReleaseSource.open(root.path);
    // An edit after Git said clean does not reach what is staged.
    _write(root, 'pubspec.yaml', 'name: tool\nversion: 9.9.9\n');
    _write(root, 'CHANGELOG.md', '## 9.9.9\n');

    final read = await source.readConfig() as ConfigResolved;

    expect(source.inRepository, isTrue);
    final unit = read.resolution.unit('tool')!;
    expect(unit.version.canonical, '1.0.0');
    expect(unit.projects.single.changelog?.text, '## 1.0.0\n');
    expect(source.git.stagingProblem(), isNull);
  });

  test(
    'a clean repository\'s release inputs are read in two batches',
    () async {
      _write(root, 'packages/a/pubspec.yaml', 'name: a\nversion: 1.0.0\n');
      _write(
        root,
        'packages/b/Cargo.toml',
        '[package]\nname = "b"\nversion = "2.0.0"\n',
      );
      _write(root, 'release.toml', '''
schema = 2

[release.tool]
publish = ["pub.dev"]

[release.a]
path = "packages/a"
publish = ["pub.dev"]

[release.b]
path = "packages/b"
build = ["tool/build.sh", "{out}"]
assets = ["b.tar.gz"]
publish = ["git-tag", "github-release"]
''');
      commitAll();
      final asked = <String>[];
      final source = await ReleaseSource.open(root.path, tools: _Asked(asked));
      asked.clear();

      final read = await source.readConfig() as ConfigResolved;

      expect(read.resolution.units.map((unit) => unit.version.canonical), [
        '1.0.0',
        '1.0.0',
        '2.0.0',
      ]);
      // The root tree and release.toml, then each project's directory and
      // the files in it: never a process per file, nor the whole tree.
      expect(asked, ['git cat-file --batch', 'git cat-file --batch']);
    },
  );

  test(
    'a committed changelog reads as a stage reads it, link by link',
    () async {
      if (Platform.isWindows) return;
      final links = {
        'one': '../../CHANGELOG.md',
        'chain': '../../docs/CHANGELOG.md',
        'directory': '../../notes/CHANGELOG.md',
        'out': '../../../outside.md',
        'absolute': '/etc/hosts',
        'circle': 'CHANGELOG.md',
        'dangling': 'gone.md',
      };
      _write(
        root,
        'release.toml',
        [
          'schema = 2',
          for (final name in links.keys)
            '[release.$name]\npath = "packages/$name"\npublish = ["pub.dev"]',
        ].join('\n\n'),
      );
      _write(root, 'docs/real.md', '## 1.0.0\n');
      _write(root, 'docs/notes/CHANGELOG.md', '## 1.0.0\n');
      Link('${root.path}/docs/CHANGELOG.md').createSync('real.md');
      Link('${root.path}/notes').createSync('docs/notes');
      links.forEach((name, target) {
        _write(
          root,
          'packages/$name/pubspec.yaml',
          'name: $name\nversion: 1.0.0\n',
        );
        Link('${root.path}/packages/$name/CHANGELOG.md').createSync(target);
      });
      commitAll();
      final source = await ReleaseSource.open(root.path);

      final read = await source.readConfig() as ConfigResolved;
      final stage = await StageSourceSnapshot.capture(
        source.tree,
        commit: source.git.head,
      );

      for (final name in links.keys) {
        final changelog = read.resolution
            .unit(name)!
            .projects
            .single
            .changelog!;
        final staged = stage.read('packages/$name/CHANGELOG.md');
        expect(changelog.text, staged, reason: name);
        expect(
          changelog.unreadable,
          staged == null
              ? 'it is a symbolic link to no file in the commit'
              : null,
          reason: name,
        );
      }
      expect(
        stage.read('packages/chain/CHANGELOG.md'),
        '## 1.0.0\n',
        reason: 'the stage reads through a chain of links',
      );
      expect(stage.read('packages/directory/CHANGELOG.md'), '## 1.0.0\n');
    },
  );

  test('a changelog that cannot be read is its own unit\'s problem', () async {
    _write(root, 'packages/a/pubspec.yaml', 'name: a\nversion: 1.0.0\n');
    File(
      '${root.path}/packages/a/CHANGELOG.md',
    ).writeAsBytesSync(latin1.encode('## 1.0.0\n- caf\u00e9\n'));
    _write(root, 'release.toml', '''
schema = 2

[release.tool]
publish = ["pub.dev"]

[release.a]
path = "packages/a"
publish = ["pub.dev"]
''');
    Future<void> expectRead(String where) async {
      final read =
          await (await ReleaseSource.open(root.path)).readConfig()
              as ConfigResolved;
      final changelogs = {
        for (final unit in read.resolution.units)
          unit.name: unit.projects.single.changelog!,
      };
      expect(changelogs['tool']!.text, '## 1.0.0\n', reason: where);
      expect(changelogs['a']!.text, isNull, reason: where);
      expect(
        changelogs['a']!.unreadable,
        'it is not UTF-8 text',
        reason: where,
      );
    }

    await expectRead('outside Git');
    commitAll();
    await expectRead('at the commit');
    _write(root, 'pubspec.yaml', 'name: tool\nversion: 1.0.0\n# edited\n');
    await expectRead('in the working tree');
  });

  test('installing reads no changelog: a link to one is never refused', () {
    if (Platform.isWindows) return;
    File('${root.path}/CHANGELOG.md').renameSync('${root.path}/NEWS.md');
    Link('${root.path}/CHANGELOG.md').createSync('NEWS.md');
    final tree = WorkingTree(root.path, git: false);
    final config = ReleaseConfig.parse(
      tree.read('release.toml')!,
      'release.toml',
      Diagnostics(),
    )!;

    expect(
      Manifests.pathsFor(config, releasing: false),
      isNot(contains('CHANGELOG.md')),
    );
    final installing = Resolution.resolve(
      config,
      tree,
      Diagnostics(),
      releasing: false,
    );
    expect(installing!.unit('tool')!.projects.single.changelog, isNull);
    // A release reads it, and its unit is told it cannot.
    final releasing = Resolution.resolve(config, tree, Diagnostics())!;
    expect(
      releasing.unit('tool')!.projects.single.changelog!.unreadable,
      contains('symbolic link'),
    );
  });

  test('a dirty repository is read as it is, and cannot be staged', () async {
    commitAll();
    _write(root, 'pubspec.yaml', 'name: tool\nversion: 1.1.0\n');

    final source = await ReleaseSource.open(root.path);
    final read = await source.readConfig() as ConfigResolved;

    expect(read.resolution.unit('tool')!.version.canonical, '1.1.0');
    final problem = source.git.stagingProblem()!;
    expect(problem.code, 'RK-GIT-001');
    expect(problem.remedy, contains('commit first'));
    expect(problem.remedy, contains('pubspec.yaml'));
  });

  test('right after rk init, an uncommitted release.toml is read', () async {
    git(['init', '-q']);

    final source = await ReleaseSource.open(root.path);
    final read = await source.readConfig() as ConfigResolved;

    expect(read.resolution.units.map((unit) => unit.name), ['tool']);
    expect(source.git.hasCommit, isFalse);
    expect(source.git.stagingProblem()?.code, 'RK-GIT-001');
  });

  test(
    'outside Git the directory is read, and nothing can be staged',
    () async {
      final source = await ReleaseSource.open(root.path);
      final read = await source.readConfig() as ConfigResolved;

      expect(source.inRepository, isFalse);
      expect(read.resolution.units.map((unit) => unit.name), ['tool']);
      expect(source.git.stagingProblem()?.code, 'RK-GIT-001');
      expect(source.git.unpushedProblem(), isNull);
    },
  );

  test(
    'the working tree follows a link in Git, and refuses one outside it',
    () {
      if (Platform.isWindows) return;
      Link('${root.path}/linked.md').createSync('CHANGELOG.md');
      Directory('${root.path}/docs').createSync();
      final inGit = WorkingTree(root.path, git: true);
      final outside = WorkingTree(root.path, git: false);

      expect(inGit.read('linked.md'), '## 1.0.0\n');
      expect(inGit.read('docs'), isNull);
      for (final path in ['linked.md', 'docs']) {
        expect(() => outside.read(path), throwsA(isA<SourceUnreadable>()));
      }
      for (final tree in [inGit, outside]) {
        expect(() => tree.read('../escape'), throwsArgumentError);
        expect(tree.read('CHANGELOG.md'), '## 1.0.0\n');
      }
    },
  );

  test('a project path is a POSIX path: a colon is part of a name', () async {
    _write(root, 'release.toml', '''
schema = 2

[release.tool]
path = "c:tool"
publish = ["pub.dev"]
''');
    _write(root, 'c:tool/pubspec.yaml', 'name: tool\nversion: 1.0.0\n');
    Future<void> expectResolved(String where) async {
      final read = await (await ReleaseSource.open(root.path)).readConfig();
      expect(
        read,
        isA<ConfigResolved>(),
        reason: '$where: ${read is ConfigProblems ? read.problems : ''}',
      );
    }

    await expectResolved('outside Git');
    commitAll();
    await expectResolved('at the commit');
    _write(root, 'README.md', 'uncommitted\n');
    await expectResolved('in the working tree');
    expect(relativeSegments(r'a\b:c'), [r'a\b:c'], reason: 'so is a backslash');
  });

  test('a repository without release.toml is not onboarded', () async {
    File('${root.path}/release.toml').deleteSync();
    commitAll();

    final source = await ReleaseSource.open(root.path);

    expect(await source.readConfig(), isA<ConfigMissing>());
  });
}

void _write(Directory root, String path, String contents) {
  File('${root.path}/$path')
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);
}

/// Real tools that write down what they were asked.
final class _Asked implements Tools {
  _Asked(this.asked);

  final List<String> asked;

  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
    List<int>? stdin,
  }) {
    asked.add('$executable ${arguments.join(' ')}');
    return const SystemTools().run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      timeout: timeout,
      stdin: stdin,
    );
  }

  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) => throw UnimplementedError();
}
