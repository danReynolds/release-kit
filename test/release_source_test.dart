import 'dart:io';

import 'package:release_kit/src/engine/config.dart';
import 'package:release_kit/src/engine/diagnostic.dart';
import 'package:release_kit/src/engine/git.dart';
import 'package:release_kit/src/engine/release_source.dart';
import 'package:release_kit/src/engine/resolve.dart';
import 'package:release_kit/src/engine/source_tree.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('rk-release-source-');
    _write(root, 'release.toml', '''
schema = 2

[release.tool]
publish = ["pub.dev"]
''');
    _write(root, 'pubspec.yaml', 'name: tool\nversion: 1.0.0\n');
    _write(root, 'CHANGELOG.md', '## 1.0.0\n');
    for (final args in const [
      ['init', '-q'],
      ['config', 'user.email', 'rk@example.test'],
      ['config', 'user.name', 'rk tests'],
      ['add', '-A'],
      ['commit', '-qm', 'initial'],
    ]) {
      final result = Process.runSync('git', args, workingDirectory: root.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    }
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('dirty registry-only source includes working-tree and untracked bytes',
      () {
    _write(root, 'notes.txt', 'untracked release note\n');
    final tree = GitSourceTree(root.path);
    final git = GitState.read(root.path);
    final resolution = _resolve(tree);
    _write(root, 'pubspec.yaml', 'name: tool\nversion: 1.1.0\n');
    final diagnostics = Diagnostics();

    final source = ReleaseSource.select(
      tree: tree,
      git: git,
      resolution: resolution,
      only: null,
      diagnostics: diagnostics,
    )!;

    expect(source.binding.isBound, isFalse);
    expect(source.repository.root, git.root);
    expect(source.warning?.code, 'RK-GIT-001');
    expect(source.tree.read('pubspec.yaml'), contains('version: 1.1.0'));
    expect(source.tree.read('notes.txt'), 'untracked release note\n');
    expect(source.tree.trackedFiles(), contains('notes.txt'));
    expect(source.resolution.unit('tool')!.version.canonical, '1.1.0');
    _write(root, 'appeared-later.txt', 'drift\n');
    expect(
      source.tree.trackedFiles(),
      isNot(contains('appeared-later.txt')),
      reason: 'resolution and staging use the same immutable capture',
    );
  });

  test('a Git-bound target keeps dirty source blocking and commit-bound', () {
    _write(root, 'release.toml', '''
schema = 2

[release.tool]
publish = ["git-tag", "pub.dev"]
''');
    final tree = GitSourceTree(root.path);
    final git = GitState.read(root.path);
    final resolution = _resolve(tree);
    final diagnostics = Diagnostics();

    final source = ReleaseSource.select(
      tree: tree,
      git: git,
      resolution: resolution,
      only: null,
      diagnostics: diagnostics,
    )!;

    expect(source.binding.isBound, isTrue);
    expect(source.warning, isNull);
    expect(source.binding.uncommittedProblem(), isNotNull);
  });

  test('a Git target added before freezing remains blocking', () {
    _write(root, 'pubspec.yaml', 'name: tool\nversion: 1.1.0\n');
    final tree = GitSourceTree(root.path);
    final git = GitState.read(root.path);
    final resolution = _resolve(tree);
    _write(root, 'release.toml', '''
schema = 2

[release.tool]
publish = ["git-tag", "pub.dev"]
''');
    final diagnostics = Diagnostics();

    final source = ReleaseSource.select(
      tree: tree,
      git: git,
      resolution: resolution,
      only: null,
      diagnostics: diagnostics,
    );

    expect(source, isNotNull);
    expect(source!.binding.isBound, isTrue);
    expect(source.warning, isNull);
    expect(source.resolution.unit('tool')!.requiresGit, isTrue);
    expect(source.repository.uncommittedProblem()?.code, 'RK-GIT-001');
  });

  test('freezing refuses bytes that move during capture', () {
    expect(
      () => FrozenSourceTree.capture(_DriftingSourceTree()),
      throwsA(isA<SourceUnreadable>()),
    );
  });
}

final class _DriftingSourceTree implements SourceTree {
  var reads = 0;

  @override
  String get description => 'drifting';

  @override
  bool exists(String path) => path == 'pubspec.yaml';

  @override
  String? read(String path) => null;

  @override
  List<int>? readBytes(String path) => [reads++];

  @override
  List<String> trackedFiles() => const ['pubspec.yaml'];
}

Resolution _resolve(SourceTree tree) {
  final diagnostics = Diagnostics();
  final config = ReleaseConfig.parse(
    tree.read('release.toml')!,
    'release.toml',
    diagnostics,
  );
  final resolution =
      config == null ? null : Resolution.resolve(config, tree, diagnostics);
  expect(resolution, isNotNull, reason: diagnostics.found.join('\n'));
  return resolution!;
}

void _write(Directory root, String path, String contents) {
  File('${root.path}/$path')
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);
}
