import 'dart:convert';

import 'package:rk/src/commands/release.dart';
import 'package:rk/src/engine/compare.dart';
import 'package:rk/src/transforms/archive.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/inspect.dart';
import 'package:rk/src/engine/output.dart';
import 'package:rk/src/engine/registry.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:test/test.dart';

import 'status_test.dart' show FakeRegistry;

const _config = '''
schema = 1

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]
''';

MemorySourceTree _tree({String changelog = '## 0.2.0\n'}) => MemorySourceTree({
      'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
      'packages/keybay/CHANGELOG.md': changelog,
    }, description: '/repo/keybay');

/// The archive a faithful publish of `_tree()`'s package would produce.
List<int> publishedBytes({String version = '0.2.0'}) =>
    ArchiveBuilder.gzip(ArchiveBuilder.tar([
      ArchiveEntry(
        name: 'pubspec.yaml',
        bytes: 'name: keybay\nversion: $version\n'.codeUnits,
      ),
      ArchiveEntry(name: 'CHANGELOG.md', bytes: '## $version\n'.codeUnits),
    ]));

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
      originUrl: 'danReynolds/keybay',
    );

extension _TagPlacement on GitState {
  /// The same state with [tag] pointing at [sha].
  GitState withTagAt(String tag, String sha) => GitState(
        root: root,
        head: head,
        branch: branch,
        isClean: isClean,
        uncommitted: uncommitted,
        headIsPushed: headIsPushed,
        tags: tags,
        tagTargets: {...tagTargets, tag: sha},
        signingConfigured: signingConfigured,
        originUrl: originUrl,
      );
}

class Ran {
  Ran(this.exitCode, this.text, this.calls, this.report);
  final int exitCode;
  final String text;
  final List<String> calls;

  /// The machine surface, decoded — what a --json caller would get.
  final Map<String, Object?> report;

  List<Map<String, Object?>> get steps => [
        for (final unit in (report['units'] as List? ?? const []))
          ...((unit as Map)['steps'] as List? ?? const [])
              .cast<Map<String, Object?>>(),
      ];

  List<Map<String, Object?>> get problems =>
      ((report['problems'] as List?) ?? const []).cast<Map<String, Object?>>();
}

Future<Ran> release({
  MemorySourceTree? source,
  GitState? state,
  RegistryReader? registry,
  String? typed = '0.2.0',
  bool dryRun = false,
  RecordingTools? tools,
  RegistryReader? afterPublish,
  String config = _config,
  String only = 'core',
}) async {
  final buffer = StringBuffer();
  final diagnostics = Diagnostics();
  final tree = source ?? _tree();
  final parsed = ReleaseConfig.parse(config, 'release.toml', diagnostics)!;
  final resolution = Resolution.resolve(parsed, tree, diagnostics)!;
  final recorder = tools ?? RecordingTools();

  final effectiveGit = state ?? _git();
  final effectiveRegistry = registry ??
      FakeRegistry({
        'keybay': ['0.1.0']
      });
  final command = ReleaseCommand(
    resolution: resolution,
    tree: tree,
    git: effectiveGit,
    registry: effectiveRegistry,
    // The same reader the command gets, or the inspection would consult a
    // different reality than the act.
    inspector: Inspector(registry: effectiveRegistry, git: effectiveGit),
    // Real tar over fake-served bytes: the confirming compare extracts what
    // the fake registry serves and proves it against the memory tree.
    comparator: Comparator(tools: const SystemTools()),
    tools: recorder,
    wait: (_) async {},
    output: Output(sink: buffer.write, isTerminal: false, useColor: false),
    confirm: typed == null ? null : (_) async => typed,
    dryRun: dryRun,
  );
  final code = await command.run(only: only);

  return Ran(
    code,
    buffer.toString(),
    recorder.calls,
    jsonDecode(command.output.report.encode(exit: code))
        as Map<String, Object?>,
  );
}

void main() {
  reviewRegressions();

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
    final registry = _MutableRegistry(<String>['0.1.0']);
    // Publishing changes the registry, the way the real command does: the
    // version goes live and the registry starts serving its archive. The
    // confirming read sees both only through the invalidated cache — if
    // release stops forgetting first, this test fails with "does not report
    // it yet" — and then proves the served bytes against this very tree.
    final tools = RecordingTools(
      onRun: (key) {
        if (key == 'dart pub publish --force') {
          registry.goLive('0.2.0');
          registry.archives['keybay@0.2.0'] = publishedBytes();
        }
      },
    );

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
        'dart pub get --no-precompile',
        'dart pub publish --force',
      ]),
      reason: 'the tag records the release before anything is published, and '
          'the consumer resolve runs before the permanent act',
    );
    expect(ran.text, contains('released'));
    expect(
      ran.text,
      contains('byte-identical'),
      reason: 'the version existing is not the right bytes existing',
    );
  });

  test('a version the registry never lists hits the deadline, honestly',
      () async {
    // Publish succeeds but the world never changes — the registry keeps
    // answering absent. The confirming read must give up at the deadline and
    // say an effect may exist, not spin forever and not report success.
    final ran = await release(
      registry: _MutableRegistry(<String>['0.1.0']),
      tools: RecordingTools(), // publish "succeeds", nothing goes live
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.text, contains('does not report it after'));
    expect(
      ran.text,
      contains('an effect may exist'),
      reason: 'rk acted and could not confirm — lostTrack, not failure',
    );
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
      registry: FakeRegistry({
        'keybay': ['0.1.0', '0.2.0']
      }),
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
/// A registry whose *world* changes when publish runs.
///
/// The answers still go through FakeRegistry's memoization — the same cache
/// the real client has — so the new version is visible only after the caller
/// forgets what it knew. The fake this replaced flipped to exact on its
/// second inspection, a behavior the real client cannot exhibit, and it hid
/// the bug where the confirming read answered from the pre-act memo and
/// every successful publish reported failure.
class _MutableRegistry extends FakeRegistry {
  _MutableRegistry(List<String> live) : super({'keybay': live});

  /// What `dart pub publish` does at the registry.
  void goLive(String version) => published['keybay']!.add(version);
}

/// Regressions for the phase 3 independent reviews: every halting rule was
/// documentation, protected by zero tests in either direction, and a halted
/// release was prose-only under --json.
void reviewRegressions() {
  const twoUnits = '''
schema = 1

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]

[release.cli]
path = "packages/cli"
publish = ["pub.dev"]
''';

  MemorySourceTree twoUnitTree() => MemorySourceTree({
        'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
        'packages/keybay/CHANGELOG.md': '## 0.2.0\n',
        'packages/cli/pubspec.yaml': '''
name: keybay_cli
version: 0.2.0
dependencies:
  keybay: 0.2.0
''',
        'packages/cli/CHANGELOG.md': '## 0.2.0\n',
      }, description: '/repo/keybay');

  test('a prerequisite that is not live halts before acting', () async {
    final ran = await release(
      config: twoUnits,
      source: twoUnitTree(),
      only: 'cli',
      registry: FakeRegistry({
        'keybay': ['0.1.0'], // 0.2.0 is not out
        'keybay_cli': ['0.1.0'], // exists, so first-publish is not the issue
      }),
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.calls, isEmpty, reason: 'nothing acted');
    expect(ran.text, contains('nothing changed'), reason: 'beforeActing');
    expect(ran.text, contains('not published yet'));
  });

  test('and the halt is data, not only prose', () async {
    final ran = await release(
      config: twoUnits,
      source: twoUnitTree(),
      only: 'cli',
      registry: FakeRegistry({
        'keybay': ['0.1.0'],
        'keybay_cli': ['0.1.0'],
      }),
    );

    expect(
      ran.steps,
      isNotEmpty,
      reason: 'a --json caller gets the checklist with verdicts, not an '
          'empty document with a halt in it',
    );
    expect(
      ran.steps.map((s) => s['verdict']),
      contains('absent'),
    );
    expect(ran.problems.map((p) => p['code']), contains('RK-REL-001'));
  });

  test('a first publish is the author\'s ceremony, not rk\'s', () async {
    final ran = await release(
      registry: FakeRegistry({}), // keybay has never been published
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.calls, isEmpty, reason: 'no publish was attempted');
    expect(ran.problems.map((p) => p['code']), contains('RK-REG-003'));
    expect(
      ran.text,
      contains('dart pub publish'),
      reason: 'refusing to act is not refusing to instruct',
    );
  });

  test('publishing a back-version is refused by release itself', () async {
    final ran = await release(
      registry: FakeRegistry({
        'keybay': ['0.5.0'], // ahead of the 0.2.0 in the manifest
      }),
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.calls, isEmpty);
    expect(
      ran.problems.map((p) => p['code']),
      contains('RK-MONO-002'),
      reason: 'the top-ranked failure was checked only by the verb that '
          'does not act',
    );
  });

  test('a fully published version with no tag is not tagged after the fact',
      () async {
    final ran = await release(
      registry: FakeRegistry({
        'keybay': ['0.2.0'], // already out; only the tag step is absent
      }),
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.calls, isEmpty, reason: 'no retroactive tag was minted');
    expect(ran.problems.map((p) => p['code']), contains('RK-GIT-004'));
    expect(
      ran.text,
      contains('git tag'),
      reason: 'refusing to act is not refusing to instruct',
    );
  });

  test('a tag at another commit with registry work remaining is a conflict',
      () async {
    final ran = await release(
      state: _git(tags: const ['v0.2.0']).withTagAt('v0.2.0', 'aaaaaaaaaaaa'),
      registry: FakeRegistry({
        'keybay': ['0.1.0'], // 0.2.0 still to publish
      }),
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.calls, isEmpty);
    expect(ran.problems.map((p) => p['code']), contains('RK-GIT-005'));
  });

  test('an unreadable public destination halts; local unknowns do not',
      () async {
    // A forge unit with no way to read the forge: publishRelease answers
    // unknown, which blocks. The build steps also answer unknown, which must
    // not — a release that halted on its own work could never start.
    final ran = await release(
      config: '''
schema = 1

[release.cli]
path = "packages/keybay"
publish = ["github-release"]
binary_platforms = ["macos-arm64"]
''',
      source: MemorySourceTree({
        'packages/keybay/pubspec.yaml': '''
name: keybay
version: 0.2.0
publish_to: none
executables:
  keybay: keybay
''',
        'packages/keybay/CHANGELOG.md': '## 0.2.0\n',
      }, description: '/repo/keybay'),
      only: 'cli',
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.text, contains('nothing changed'));
    expect(
      ran.text,
      isNot(contains('local work')),
      reason: 'the halt names the unreadable destination, not the work',
    );
  });
}
