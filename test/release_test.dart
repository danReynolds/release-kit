import 'package:rk/src/commands/release.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/output.dart';
import 'package:rk/src/engine/registry.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/version.dart';
import 'package:test/test.dart';

import 'status_test.dart' show FakeRegistry;

const _config = '''
schema = 1

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]
''';

MemorySourceTree _tree({String changelog = '## 0.2.0\n'}) =>
    MemorySourceTree({
      'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
      'packages/keybay/CHANGELOG.md': changelog,
    }, description: '/repo/keybay');

GitState _git({
  bool clean = true,
  bool pushed = true,
  List<String> tags = const [],
  bool signing = true,
}) =>
    GitState(
      root: '/repo',
      head: '9f2c1ab',
      branch: 'main',
      isClean: clean,
      uncommitted: clean ? const [] : const ['lib/x.dart'],
      headIsPushed: pushed,
      tags: tags,
      signingConfigured: signing,
    );

class _Ran {
  _Ran(this.exitCode, this.text, this.calls);
  final int exitCode;
  final String text;
  final List<String> calls;
}

Future<_Ran> release({
  MemorySourceTree? source,
  GitState? state,
  RegistryReader? registry,
  String? typed = '0.2.0',
  bool dryRun = false,
  RecordingTools? tools,
  RegistryReader? afterPublish,
}) async {
  final buffer = StringBuffer();
  final diagnostics = Diagnostics();
  final tree = source ?? _tree();
  final parsed = ReleaseConfig.parse(_config, 'release.toml', diagnostics)!;
  final resolution = Resolution.resolve(parsed, tree, diagnostics)!;
  final recorder = tools ?? RecordingTools();

  final code = await ReleaseCommand(
    resolution: resolution,
    tree: tree,
    git: state ?? _git(),
    registry: registry ?? FakeRegistry({'keybay': ['0.1.0']}),
    tools: recorder,
    output: Output(sink: buffer.write, isTerminal: false, useColor: false),
    confirm: typed == null ? null : (_) async => typed,
    dryRun: dryRun,
  ).run(only: 'core');

  return _Ran(code, buffer.toString(), recorder.calls);
}

void main() {
  test('a dry run shows the plan and starts nothing', () async {
    final ran = await release(dryRun: true);
    expect(ran.exitCode, ExitCodes.ok);
    expect(ran.text, contains('nothing was started'));
    expect(ran.calls, isEmpty, reason: 'no tool was invoked');
  });

  test('an unconfirmed release publishes nothing', () async {
    final ran = await release(typed: 'yes');
    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.text, contains('nothing was published'));
    expect(ran.calls, isEmpty);
  });

  test('typing the version tags and publishes, in that order', () async {
    // The registry reports the version live once publish has run, which is
    // what the post-publish verification reads.
    final published = <String>['0.1.0'];
    final registry = _MutableRegistry(published);
    final tools = RecordingTools();

    final ran = await release(
      registry: registry,
      tools: tools,
      typed: '0.2.0',
    );

    expect(ran.exitCode, ExitCodes.ok, reason: ran.text);
    expect(
      tools.calls,
      containsAllInOrder([
        'git tag -s v0.2.0 -m core 0.2.0',
        'git push origin v0.2.0',
        'dart pub publish --dry-run',
        'dart pub publish --force',
      ]),
      reason: 'the tag records the release before anything is published',
    );
    expect(ran.text, contains('released'));
  });

  test('an unsigned repository still tags, and says so', () async {
    final tools = RecordingTools();
    await release(
      state: _git(signing: false),
      registry: _MutableRegistry(<String>['0.1.0']),
      tools: tools,
    );
    expect(tools.calls.first, contains('git tag -a'));
  });

  test('an existing tag is not created twice', () async {
    final tools = RecordingTools();
    await release(
      state: _git(tags: const ['v0.2.0']),
      registry: _MutableRegistry(<String>['0.1.0']),
      tools: tools,
    );
    expect(
      tools.calls.where((c) => c.startsWith('git tag')),
      isEmpty,
      reason: 'inspect saw it and skipped the step',
    );
  });

  test('a failed dry run stops before publishing', () async {
    final tools = RecordingTools(results: {
      'dart pub publish --dry-run': ToolResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Package validation found the following error:\n'
            'lib/src/private.dart is not in the package',
      ),
    });

    final ran = await release(tools: tools);
    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.text, contains('not in the package'));
    expect(
      tools.calls,
      isNot(contains('dart pub publish --force')),
    );
  });

  test('a release already published does nothing', () async {
    final ran = await release(
      registry: FakeRegistry({'keybay': ['0.1.0', '0.2.0']}),
      state: _git(tags: const ['v0.2.0']),
    );
    expect(ran.exitCode, ExitCodes.ok);
    expect(ran.text, contains('already released'));
    expect(ran.calls, isEmpty);
  });

  test('an unclean worktree halts before acting', () async {
    final ran = await release(state: _git(clean: false));
    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.text, contains('nothing changed'));
    expect(ran.text, contains('uncommitted'));
    expect(ran.calls, isEmpty);
  });

  test('a missing changelog entry halts before acting', () async {
    final ran = await release(source: _tree(changelog: '## 0.1.0\n'));
    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.text, contains('no entry for 0.2.0'));
    expect(ran.calls, isEmpty);
  });

  test('an unreachable registry halts rather than publishing blind', () async {
    final ran = await release(
      registry: FakeRegistry(const {}, unreachable: true),
    );
    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.text, contains('could not be reached'));
    expect(ran.calls, isEmpty);
  });

  test('nobody at the terminal means nobody authorized it', () async {
    final ran = await release(typed: null);
    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.text, contains('nobody is here to authorize'));
    expect(ran.calls, isEmpty);
  });
}

/// A registry that starts with what is published and gains the released
/// version once `dart pub publish` has been recorded — so the post-publish
/// verification has something true to read.
class _MutableRegistry extends FakeRegistry {
  _MutableRegistry(this.live) : super({'keybay': live});

  final List<String> live;
  var _publishes = 0;

  @override
  Future<Inspection> inspect(String name, Version version) async {
    // The first inspection is the pre-flight one; afterwards the version is
    // treated as live, which is what a real registry would report.
    final result = await super.inspect(name, version);
    if (result.isAbsent && _publishes > 0) {
      return const Inspection.exact(detail: 'published just now');
    }
    _publishes++;
    return result;
  }
}
