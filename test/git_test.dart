import 'dart:io';

import 'package:rk/src/engine/git.dart';
import 'package:test/test.dart';

/// `GitState.read` against real repositories.
///
/// It had no test: `status_test.dart` fakes the whole object, so the parsing
/// of `git status --porcelain` — which decides whether rk will release at all
/// — was never exercised by anything.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('rk-git-');
    Process.runSync('git', ['init', '-q'], workingDirectory: root.path);
    Process.runSync('git', ['config', 'user.email', 'a@b.c'],
        workingDirectory: root.path);
    Process.runSync('git', ['config', 'user.name', 'T'],
        workingDirectory: root.path);
  });

  tearDown(() => root.deleteSync(recursive: true));

  void write(String path, String contents) {
    File('${root.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
  }

  void commit() {
    Process.runSync('git', ['add', '-A'], workingDirectory: root.path);
    Process.runSync('git', ['commit', '-qm', 'x'], workingDirectory: root.path);
  }

  test('a committed tree is clean', () {
    write('a.txt', 'one\n');
    commit();
    expect(GitState.read(root.path).isClean, isTrue);
  });

  test('a modified file keeps its whole name', () {
    write('packages/keybay/CHANGELOG.md', 'one\n');
    commit();
    write('packages/keybay/CHANGELOG.md', 'two\n');

    expect(
      GitState.read(root.path).uncommitted,
      ['packages/keybay/CHANGELOG.md'],
      reason: 'porcelain writes " M path" for a worktree-only change, so '
          'trimming the block ate the first line\'s status column and rk '
          'named a file that does not exist',
    );
  });

  test('the first of several modified files is not the odd one out', () {
    write('a.txt', 'one\n');
    write('b.txt', 'one\n');
    commit();
    write('a.txt', 'two\n');
    write('b.txt', 'two\n');

    final uncommitted = GitState.read(root.path).uncommitted;
    expect(uncommitted, ['a.txt', 'b.txt']);
  });

  test('an untracked file is uncommitted', () {
    write('a.txt', 'one\n');
    commit();
    write('b.txt', 'new\n');
    expect(GitState.read(root.path).uncommitted, ['b.txt']);
  });

  test('rk\'s own workspace is not the operator\'s uncommitted work', () {
    write('a.txt', 'one\n');
    commit();
    write('.rk/diagnosis/2026-01-01/run.json', '{}');
    write('.rk/work/cli-v1.0.0-abc/keybay', 'binary');

    final state = GitState.read(root.path);
    expect(
      state.uncommitted,
      isEmpty,
      reason: 'a failed release left this behind, and counting it made the '
          'next run refuse itself — which breaks the resume',
    );
    expect(state.isClean, isTrue);
  });

  test('a repository with no commits does not crash', () {
    write('a.txt', 'one\n');
    final state = GitState.read(root.path);
    expect(state.uncommitted, ['a.txt']);
  });

  test('tags are read', () {
    write('a.txt', 'one\n');
    commit();
    Process.runSync('git', ['tag', 'v1.0.0'], workingDirectory: root.path);
    expect(GitState.read(root.path).hasTag('v1.0.0'), isTrue);
    expect(GitState.read(root.path).hasTag('v2.0.0'), isFalse);
  });
}
