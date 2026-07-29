import 'package:rk/src/commands/init.dart';
import 'package:rk/src/engine/output.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:test/test.dart';

void main() {
  test('proposes one unit per releasable package', () async {
    final buffer = StringBuffer();
    final written = <String, String>{};
    await InitCommand(
      tree: MemorySourceTree({
        'pubspec.yaml': 'name: root\npublish_to: none\nworkspace:\n  - a\n',
        'packages/a/pubspec.yaml': 'name: a\nversion: 1.0.0\n',
        'packages/b/pubspec.yaml':
            'name: b\nversion: 1.0.0\nexecutables:\n  b: b\n',
      }, description: '/repo/demo'),
      output: Output(sink: buffer.write, isTerminal: false, useColor: false),
      write: (path, contents) => written[path] = contents,
      confirm: (_) async => true,
    ).run();

    final config = written['release.toml']!;
    expect(config, contains('[release.a]'));
    expect(config, contains('[release.b]'));
    expect(config, contains('path = "packages/a"'));
    expect(
      config,
      isNot(contains('binary_platforms =')),
      reason: 'an executable is not a request for signed binaries; the '
          'comment offers the option, the config does not take it',
    );
    expect(
      config,
      isNot(contains('publish = ["pub.dev", "github-release"')),
      reason: 'binary channels are the human\'s decision',
    );
    expect(buffer.toString(), contains('workspace root'));
  });

  test('never edits an existing config', () async {
    final buffer = StringBuffer();
    final written = <String, String>{};
    await InitCommand(
      tree: MemorySourceTree({'release.toml': 'schema = 1\n'}),
      output: Output(sink: buffer.write, isTerminal: false, useColor: false),
      write: (path, contents) => written[path] = contents,
      confirm: (_) async => true,
    ).run();
    expect(written, isEmpty);
    expect(buffer.toString(), contains('already exists'));
  });

  test('declining writes nothing', () async {
    final buffer = StringBuffer();
    final written = <String, String>{};
    await InitCommand(
      tree: MemorySourceTree({'pubspec.yaml': 'name: a\nversion: 1.0.0\n'}),
      output: Output(sink: buffer.write, isTerminal: false, useColor: false),
      write: (path, contents) => written[path] = contents,
      confirm: (_) async => false,
    ).run();
    expect(written, isEmpty);
    expect(buffer.toString(), contains('nothing was written'));
  });

  test('a repository with nothing releasable is not a failure', () async {
    final buffer = StringBuffer();
    final code = await InitCommand(
      tree: MemorySourceTree({
        'pubspec.yaml': 'name: fixtures\nversion: 1.0.0\npublish_to: none\n',
      }),
      output: Output(sink: buffer.write, isTerminal: false, useColor: false),
      write: (path, contents) {},
      confirm: (_) async => true,
    ).run();
    expect(code, ExitCodes.ok);
    expect(buffer.toString(), contains('nothing here can be released'));
  });

  test('a single package gets the bare tag convention', () async {
    final written = <String, String>{};
    await InitCommand(
      tree: MemorySourceTree({'pubspec.yaml': 'name: solo\nversion: 1.0.0\n'}),
      output: Output(sink: (_) {}, isTerminal: false, useColor: false),
      write: (path, contents) => written[path] = contents,
      confirm: (_) async => true,
    ).run();
    expect(written['release.toml'], contains('# tag v{version}'));
    expect(written['release.toml'], isNot(contains('solo-v')));
  });
}
