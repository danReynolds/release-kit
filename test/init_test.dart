import 'package:rk/src/commands/init.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/output.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:test/test.dart';

void main() {
  dogfoodRegressions();
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

/// Phase 6 hardening: the proposal is validated against rk itself.
void dogfoodRegressions() {
  test('colliding unit names are refused, not written', () async {
    // Two package names that sanitize onto one table: the generated config
    // would define [release.foobar] twice, and rk's own parser refuses a
    // duplicate table — so init must refuse first, not hand the operator a
    // file that rk then rejects as if they had written it.
    final buffer = StringBuffer();
    final written = <String, String>{};
    final code = await InitCommand(
      tree: MemorySourceTree({
        'packages/a/pubspec.yaml': 'name: foo.bar\nversion: 1.0.0\n',
        'packages/b/pubspec.yaml': 'name: foobar\nversion: 1.0.0\n',
      }, description: '/repo/collide'),
      output: Output(sink: buffer.write, isTerminal: false, useColor: false),
      write: written.putIfAbsent2,
      confirm: (_) async => true,
    ).run();

    expect(code, ExitCodes.refused);
    expect(written, isEmpty, reason: 'nothing rk refuses may be written');
    expect(buffer.toString(), contains('rk itself refuses'));
  });

  test('the accepted proposal resolves end to end', () async {
    // The dogfood loop: init writes, and what it wrote must release — parsed
    // by rk's parser, resolved against the same tree, checklist derivable.
    final tree = MemorySourceTree({
      'pubspec.yaml': '''
name: keybay_workspace
publish_to: none
workspace:
  - packages/keybay
''',
      'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
    }, description: '/repo/keybay');

    final written = <String, String>{};
    final code = await InitCommand(
      tree: tree,
      output: Output(sink: (_) {}, isTerminal: false, useColor: false),
      write: (path, contents) => written[path] = contents,
      confirm: (_) async => true,
    ).run();
    expect(code, ExitCodes.ok);

    final diagnostics = Diagnostics();
    final parsed = ReleaseConfig.parse(
        written['release.toml']!, 'release.toml', diagnostics)!;
    final resolution = Resolution.resolve(parsed, tree, diagnostics);
    expect(resolution, isNotNull, reason: diagnostics.found.join('\n'));
    expect(resolution!.units.single.projects.single.name, 'keybay');
  });

  test('the proposal reaches the machine surface as an attachment', () async {
    final output = Output(sink: (_) {}, isTerminal: false, useColor: false);
    await InitCommand(
      tree: MemorySourceTree({
        'pubspec.yaml': 'name: solo\nversion: 1.0.0\n',
      }, description: '/repo/solo'),
      output: output,
      write: (_, __) {},
      confirm: null, // nobody at a terminal — the fleet-sweep case
    ).run();

    expect(
      output.report.attachments['release.toml'],
      contains('publish = ["pub.dev"]'),
      reason: 'an agent reads the proposal from the document; a human writes '
          'it at a terminal',
    );
  });
}

extension on Map<String, String> {
  void putIfAbsent2(String key, String value) => this[key] = value;
}
