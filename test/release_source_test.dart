import 'dart:io';

import 'package:rk/src/engine/release_source.dart';
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

    final read = await source.readConfig() as ConfigResolved;

    expect(source.inRepository, isTrue);
    expect(read.resolution.unit('tool')!.version.canonical, '1.0.0');
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
      expect(source.git.stagingProblem()?.code, 'RK-SRC-004');
      expect(source.git.unpushedProblem(), isNull);
    },
  );

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
