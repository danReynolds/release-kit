import 'dart:io';

import 'package:release_kit/src/engine/source_tree.dart';
import 'package:test/test.dart';

/// `GitTreeAtRef` against real repositories.
///
/// The whole point of the class is that verify answers for the release, not
/// for today — so the tests move the worktree on after tagging and assert the
/// tree at the tag still reads what the tag names.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('rk-atref-');
    for (final args in [
      ['init', '-q'],
      ['config', 'user.email', 'a@b.c'],
      ['config', 'user.name', 'T'],
    ]) {
      Process.runSync('git', args, workingDirectory: root.path);
    }
  });

  tearDown(() => root.deleteSync(recursive: true));

  void write(String path, String contents) {
    File('${root.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
  }

  void commit([String message = 'x']) {
    Process.runSync('git', ['add', '-A'], workingDirectory: root.path);
    Process.runSync(
      'git',
      ['commit', '-qm', message],
      workingDirectory: root.path,
    );
  }

  void tag(String name) =>
      Process.runSync('git', ['tag', name], workingDirectory: root.path);

  test('reads the file as it stood at the tag, not as it is now', () {
    write('pubspec.yaml', 'name: tool\nversion: 1.0.0\n');
    commit();
    tag('v1.0.0');
    write('pubspec.yaml', 'name: tool\nversion: 2.0.0-dev\n');
    commit('moved on');

    final tree = GitTreeAtRef.at(root.path, 'v1.0.0')!;
    expect(tree.read('pubspec.yaml'), contains('1.0.0'));
    expect(tree.read('pubspec.yaml'), isNot(contains('2.0.0-dev')));
  });

  test('sees nothing uncommitted, whatever the worktree holds', () {
    write('a.txt', 'committed\n');
    commit();
    tag('v1.0.0');
    write('b.txt', 'uncommitted\n');

    final tree = GitTreeAtRef.at(root.path, 'v1.0.0')!;
    expect(tree.read('b.txt'), isNull);
    expect(tree.trackedFiles(), ['a.txt']);
  });

  test('lists what the ref tracked, not what HEAD tracks', () {
    write('a.txt', 'x\n');
    commit();
    tag('v1.0.0');
    write('later.txt', 'added after the release\n');
    commit('later');

    expect(
      GitTreeAtRef.at(root.path, 'v1.0.0')!.trackedFiles(),
      ['a.txt'],
      reason: 'reading HEAD here would report files the release never had — '
          'and the missing-from-archive direction would accuse every one',
    );
  });

  test('bytes are read byte-for-byte, not through text decoding', () {
    File('${root.path}/blob.bin')
        .writeAsBytesSync([0x00, 0xff, 0xfe, 0x0d, 0x0a, 0x1a]);
    commit();
    tag('v1.0.0');

    expect(
      GitTreeAtRef.at(root.path, 'v1.0.0')!.readBytes('blob.bin'),
      [0x00, 0xff, 0xfe, 0x0d, 0x0a, 0x1a],
      reason: 'a comparison routed through decoding erases exactly the '
          'differences comparing exists to catch',
    );
  });

  test('a ref that does not exist is one clear null, not a cascade', () {
    write('a.txt', 'x\n');
    commit();
    expect(GitTreeAtRef.at(root.path, 'v9.9.9'), isNull);
  });

  test('the commit is carried, because it is the provenance', () {
    write('a.txt', 'x\n');
    commit();
    tag('v1.0.0');
    write('a.txt', 'y\n');
    commit('later');

    final tree = GitTreeAtRef.at(root.path, 'v1.0.0')!;
    final head = Process.runSync(
      'git',
      ['rev-parse', 'HEAD'],
      workingDirectory: root.path,
    ).stdout as String;
    expect(tree.commit, isNot(head.trim()));
    expect(tree.commit, hasLength(40));
  });

  test('an annotated tag peels to its commit', () {
    write('a.txt', 'x\n');
    commit();
    Process.runSync(
      'git',
      ['tag', '-a', 'v1.0.0', '-m', 'release'],
      workingDirectory: root.path,
    );

    final tree = GitTreeAtRef.at(root.path, 'v1.0.0')!;
    final head = Process.runSync(
      'git',
      ['rev-parse', 'HEAD'],
      workingDirectory: root.path,
    ).stdout as String;
    expect(tree.commit, head.trim());
  });

  test('a missing file is null and a directory exists', () {
    write('packages/tool/pubspec.yaml', 'name: tool\nversion: 1.0.0\n');
    commit();
    tag('v1.0.0');

    final tree = GitTreeAtRef.at(root.path, 'v1.0.0')!;
    expect(tree.read('nowhere.txt'), isNull);
    expect(tree.exists('packages/tool'), isTrue);
    expect(tree.exists('packages/nowhere'), isFalse);
  });

  test('a path cannot escape the repository', () {
    write('a.txt', 'x\n');
    commit();
    tag('v1.0.0');
    expect(
      () => GitTreeAtRef.at(root.path, 'v1.0.0')!.read('../outside'),
      throwsArgumentError,
    );
  });
}
