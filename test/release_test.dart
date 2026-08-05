import 'dart:convert';
import 'dart:io';

import 'package:release_kit/src/commands/release.dart';
import 'package:release_kit/src/engine/compare.dart';
import 'package:release_kit/src/transforms/archive.dart';
import 'package:release_kit/src/engine/config.dart';
import 'package:release_kit/src/engine/diagnostic.dart';
import 'package:release_kit/src/engine/git.dart';
import 'package:release_kit/src/engine/inspect.dart';
import 'package:release_kit/src/engine/output.dart';
import 'package:release_kit/src/engine/registry.dart';
import 'package:release_kit/src/engine/resolve.dart';
import 'package:release_kit/src/engine/source_tree.dart';
import 'package:release_kit/src/engine/tools.dart';
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
  String root = '/repo',
}) =>
    GitState(
      root: root,
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
  Map<String, ToolResult> results = const {},
  void Function(String key)? onRun,
  void Function(String key, String? workingDirectory)? probe,
  ToolResult? Function(String key)? answers,
  Iterable<String> onRemote = const [],
  String config = _config,
  String only = 'core',
}) async {
  final buffer = StringBuffer();
  final diagnostics = Diagnostics();
  final tree = source ?? _tree();
  final parsed = ReleaseConfig.parse(config, 'release.toml', diagnostics)!;
  final resolution = Resolution.resolve(parsed, tree, diagnostics)!;

  // Origin lists what has been pushed — before this run ([onRemote]) or
  // during it. A static script cannot say that, and the remote-verify leg
  // reads it, so the harness models the one moving fact itself.
  final remoteTags = <String>{...onRemote};
  final recorder = RecordingTools(
    results: results,
    probe: probe,
    onRun: (key) {
      const push = 'git push origin ';
      if (key.startsWith(push)) {
        final scripted = results[key];
        if (scripted == null || scripted.exitCode == 0) {
          remoteTags.add(key.substring(push.length));
        }
      }
      onRun?.call(key);
    },
    answers: (key) {
      const prefix = 'git ls-remote origin refs/tags/';
      if (key.startsWith(prefix)) {
        final tag = key.substring(prefix.length);
        return ToolResult(
          exitCode: 0,
          stdout: remoteTags.contains(tag) ? 'deadbeef refs/tags/$tag' : '',
          stderr: '',
        );
      }
      // The test's own world model, after the harness's: a binary unit's
      // forge and identity reads live here.
      return answers?.call(key);
    },
  );

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
    // different reality than the act — and the same tools, so the tag
    // step's remote half reads the harness's remote.
    inspector: Inspector(
      registry: effectiveRegistry,
      git: effectiveGit,
      tools: recorder,
      repository: 'example/keybay',
    ),
    // Real tar over fake-served bytes: the confirming compare extracts what
    // the fake registry serves and proves it against the memory tree.
    comparator: Comparator(tools: const SystemTools()),
    tools: recorder,
    // Yields to the event queue rather than completing in a microtask: a
    // mutation that unbounded the confirm poll wedged the whole test runner
    // instead of failing, because even the framework's timeout timer starved.
    wait: (_) => Future<void>.delayed(Duration.zero),
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

/// Phase 7a closeout: `_signingBaseline` — the identity read the whole sign
/// step depends on — had no test at all. Four of the review's surviving
/// mutations lived in it.
void signingBaselineRegressions() {
  const binaryConfig = '''
schema = 1

[release.cli]
path = "packages/tool"
publish = ["github-release"]
binary_platforms = ["macos-arm64"]
code_id = "com.example.tool"
''';

  MemorySourceTree binaryTree() => MemorySourceTree({
        'packages/tool/pubspec.yaml': '''
name: tool
version: 1.0.0
publish_to: none
executables:
  tool: tool
''',
        'packages/tool/CHANGELOG.md': '## 1.0.0\n\nFirst release.\n',
      }, description: '/repo/tool');

  /// The forge as a first-releaseable world: no release at the new tag,
  /// the repository readable — answered in `gh api` status codes, which is
  /// how the reader now asks.
  ToolResult? forge(String key) {
    if (key.startsWith('gh api --paginate --slurp')) {
      return ToolResult(exitCode: 0, stdout: '[[]]', stderr: '');
    }
    if (key.startsWith('gh api repos/') && key.contains('/releases/tags/')) {
      return ToolResult(
          exitCode: 1, stdout: '', stderr: 'gh: Not Found (HTTP 404)');
    }
    if (key.startsWith('gh repo view')) {
      return ToolResult(exitCode: 0, stdout: '{"name":"keybay"}', stderr: '');
    }
    return null;
  }

  test(
      'an unreadable published identity refuses before anything acts — '
      'not as a bug in rk after the tag is public', () async {
    final ran = await release(
      config: binaryConfig,
      source: binaryTree(),
      state: _git(tags: ['v0.8.0', 'v0.9.0']),
      registry: FakeRegistry({}),
      typed: '1.0.0',
      only: 'cli',
      answers: (key) {
        // The baseline release (v0.9.0) is there and lists its archive; the
        // download of it is what fails. The new tag (v1.0.0) stays 404.
        if (key.contains('/releases/tags/v0.9.0')) {
          return ToolResult(
            exitCode: 0,
            stdout: '{"assets":[{"name":"tool-0.9.0-macos-arm64.tar.gz"}]}',
            stderr: '',
          );
        }
        if (key.startsWith('gh release download')) {
          return ToolResult(
              exitCode: 1, stdout: '', stderr: 'could not resolve host');
        }
        return forge(key);
      },
    );

    expect(ran.exitCode, ExitCodes.refused, reason: ran.text);
    expect(
      ran.problems.map((p) => p['code']),
      contains('RK-SIGN-004'),
      reason: 'not knowing the baseline has a name and a remedy; it is not '
          'RK-INT-001',
    );
    expect(
      (ran.report['halt'] as Map?)?['kind'],
      'beforeActing',
      reason: 'resolved in preflight — the version of this that resolved '
          'inside the sign step surfaced after the tag was public',
    );
    expect(
      ran.calls.where((c) => c.startsWith('git tag')),
      isEmpty,
      reason: 'nothing may act before the baseline is known',
    );
    expect(ran.text, isNot(contains('RK-INT-001')));
  });

  test(
      'a declared identity that disagrees with the published release is '
      'refused before anything acts', () async {
    // The declaration says com.example.tool; the release users installed
    // says io.github.other.tool. Left to the sign step, this surfaced as a
    // signature mismatch after the tag was public, blaming the keychain.
    final ran = await release(
      config: binaryConfig,
      source: binaryTree(),
      state: _git(tags: ['v0.9.0']),
      registry: FakeRegistry({}),
      typed: '1.0.0',
      only: 'cli',
      answers: (key) {
        if (key.contains('/releases/tags/v0.9.0')) {
          return ToolResult(
            exitCode: 0,
            stdout: '{"assets":[{"name":"tool-0.9.0-macos-arm64.tar.gz"}]}',
            stderr: '',
          );
        }
        if (key.startsWith('gh release download')) {
          return ToolResult(exitCode: 0, stdout: '', stderr: '');
        }
        if (key.startsWith('sh -c ls ')) {
          final dir =
              key.substring('sh -c ls '.length).split('/*.tar.gz').first;
          return ToolResult(
            exitCode: 0,
            stdout: '$dir/tool-0.9.0-macos-arm64.tar.gz\n',
            stderr: '',
          );
        }
        if (key.startsWith('codesign -d -r-')) {
          return ToolResult(
            exitCode: 0,
            stdout: 'designated => identifier "io.github.other.tool" and '
                'certificate leaf[subject.OU] = "TEAM123456"',
            stderr: '',
          );
        }
        return forge(key);
      },
    );

    expect(ran.exitCode, ExitCodes.refused, reason: ran.text);
    expect(ran.problems.map((p) => p['code']), contains('RK-SIGN-005'));
    expect(ran.text, contains('io.github.other.tool'));
    expect(ran.text, contains('com.example.tool'));
    expect(
      ran.calls.where((c) => c.startsWith('git tag')),
      isEmpty,
      reason: 'the disagreement is knowable before the first act',
    );
  });

  test('the baseline is read from the newest lower version, not the oldest',
      () async {
    // A writable root: preflight writes the release body into the workspace
    // before anything acts, so even a run that stops at authorize touches
    // the filesystem.
    final root = Directory.systemTemp.createTempSync('rk-baseline-');
    addTearDown(() => root.deleteSync(recursive: true));
    final downloads = <String>[];
    final ran = await release(
      config: binaryConfig,
      source: binaryTree(),
      state: _git(tags: ['v0.8.0', 'v0.9.0'], root: root.path),
      registry: FakeRegistry({}),
      // Nobody to authorize: the baseline is resolved in preflight, so the
      // read this test is about has already happened when the run stops.
      // (--dry-run would run the whole local chain now, which is a
      // different test.)
      typed: null,
      only: 'cli',
      answers: (key) {
        if (key.contains('/releases/tags/v0.9.0')) {
          return ToolResult(
            exitCode: 0,
            stdout: '{"assets":[{"name":"tool-0.9.0-macos-arm64.tar.gz"}]}',
            stderr: '',
          );
        }
        if (key.contains('/releases/tags/v0.8.0')) {
          fail('the baseline is the newest lower version; v0.8.0 is not it');
        }
        if (key.startsWith('gh release download')) {
          downloads.add(key);
          return ToolResult(exitCode: 0, stdout: '', stderr: '');
        }
        if (key.startsWith('sh -c ls ')) {
          final dir =
              key.substring('sh -c ls '.length).split('/*.tar.gz').first;
          return ToolResult(
            exitCode: 0,
            stdout: '$dir/tool-0.9.0-macos-arm64.tar.gz\n',
            stderr: '',
          );
        }
        if (key.startsWith('codesign -d -r-')) {
          return ToolResult(
            exitCode: 0,
            stdout: 'designated => certificate '
                'leaf[subject.OU] = "TEAM123456"',
            stderr: '',
          );
        }
        return forge(key);
      },
    );

    expect(ran.exitCode, ExitCodes.refused, reason: 'nobody authorized it');
    expect(downloads, hasLength(1));
    expect(
      downloads.single,
      contains(' v0.9.0 '),
      reason: 'the release users most recently installed is the identity '
          'this one must be continuous with',
    );
  });
}

void main() {
  reviewRegressions();
  mutationCloseout();
  signingBaselineRegressions();

  test('a dry run does every local act and nothing public', () async {
    final ran = await release(dryRun: true);
    expect(ran.exitCode, ExitCodes.ok, reason: ran.text);
    expect(ran.text, contains('dry run complete'));
    expect(ran.text, contains('nothing public changed'));
    expect(
      ran.calls.where((c) => c.startsWith('git tag')),
      isEmpty,
      reason: 'nothing public',
    );
    expect(ran.calls.where((c) => c.contains('publish --force')), isEmpty);
    expect(
      ran.calls,
      contains('dart pub publish --dry-run'),
      reason: 'the rehearsal rehearses: the first real run once discovered '
          'a validation refusal only after the signed tag was public',
    );
    expect(ran.calls, contains('dart pub get --no-precompile'));
  });

  test('an unconfirmed release publishes nothing', () async {
    final ran = await release(typed: 'yes');
    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.text, contains('nothing was published'));
    expect(
      ran.calls.where(
          (c) => c.startsWith('git tag') || c.contains('publish --force')),
      isEmpty,
      reason: 'read-only preflight may run; nothing public may',
    );
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
    final ran = await release(
      registry: registry,
      onRun: (key) {
        if (key == 'dart pub publish --force') {
          registry.goLive('0.2.0');
          registry.archives['keybay@0.2.0'] = publishedBytes();
        }
      },
      typed: '0.2.0',
    );

    expect(ran.exitCode, ExitCodes.ok, reason: ran.text);
    expect(
      ran.calls,
      containsAllInOrder([
        'dart pub publish --dry-run',
        'dart pub get --no-precompile',
        'git tag -s v0.2.0 -m core 0.2.0',
        'git push origin v0.2.0',
        'dart pub publish --force',
      ]),
      reason: 'everything read-only runs before anything public: the first '
          'real run once discovered a validation refusal only after the '
          'signed tag was pushed',
    );
    expect(ran.text, contains('released'));
    expect(
      ran.text,
      contains('byte-identical'),
      reason: 'the version existing is not the right bytes existing',
    );
  });

  test('warnings-only validation publishes, with the warnings shown first',
      () async {
    // The day-one scenario, verbatim: keybay's deliberate exact pins are
    // "warnings" to pub, pub exits 65 for warnings and errors alike, and
    // --force — the actual act — publishes past warnings. Gating on the exit
    // code alone made rk stricter than the registry it publishes to, and the
    // refusal landed after the signed tag was public.
    final registry = _MutableRegistry(<String>['0.1.0']);
    final ran = await release(
      registry: registry,
      results: {
        'dart pub publish --dry-run': ToolResult(
          exitCode: 65,
          stdout: 'Package validation found the following potential issue:\n'
              '* Your dependency on keybay is pinned to an exact version.\n'
              '* Your dependency on ffi is pinned to an exact version.\n'
              'Package has 2 warnings.',
          stderr: '',
        ),
      },
      onRun: (key) {
        if (key == 'dart pub publish --force') {
          registry.goLive('0.2.0');
          registry.archives['keybay@0.2.0'] = publishedBytes();
        }
      },
    );

    expect(ran.exitCode, ExitCodes.ok, reason: ran.text);
    expect(
      ran.text,
      contains('pinned to an exact version'),
      reason: 'the operator confirms the permanent act having seen the '
          'warnings pub would have shown',
    );
    expect(ran.calls, contains('dart pub publish --force'));
  });

  test('validation errors block before anything public exists', () async {
    final ran = await release(
      results: {
        'dart pub publish --dry-run': ToolResult(
          exitCode: 65,
          stdout: 'Package has 1 warning and 1 error.',
          stderr: '',
        ),
      },
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.problems.map((p) => p['code']), contains('RK-PUB-001'));
    expect(
      ran.calls.where((c) => c.startsWith('git tag')),
      isEmpty,
      reason: 'the refusal costs nothing public — it used to land after the '
          'signed tag was pushed',
    );
    expect(ran.text, contains('nothing changed'));
  });

  test('a summary rk cannot classify blocks, because it is unrecognised',
      () async {
    final ran = await release(
      results: {
        'dart pub publish --dry-run':
            ToolResult(exitCode: 65, stdout: 'something novel', stderr: ''),
      },
    );
    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.problems.map((p) => p['code']), contains('RK-PUB-001'));
  });

  test('a failed push removes the local tag, so re-running starts clean',
      () async {
    final ran = await release(
      registry: _MutableRegistry(<String>['0.1.0']),
      results: {
        'git push origin v0.2.0': ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: 'fatal: unable to access origin',
        ),
      },
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(
      ran.calls,
      contains('git tag -d v0.2.0'),
      reason: 'a local tag nobody else can see is a trap: the next run '
          'would inspect it as done and publish a version bound to a commit '
          'only this machine knows about',
    );
    expect(ran.text, contains('nothing changed'));
    expect(ran.problems.map((p) => p['code']), contains('RK-TAG-002'));
    expect(
      ran.calls.where((c) => c.contains('publish --force')),
      isEmpty,
    );
  });

  test('a version the registry never lists hits the deadline, honestly',
      () async {
    // Publish succeeds but the world never changes — the registry keeps
    // answering absent. The confirming read must give up at the deadline and
    // say an effect may exist, not spin forever and not report success.
    final ran = await release(
      registry: _MutableRegistry(<String>['0.1.0']),
      // publish "succeeds", nothing goes live
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
    final ran = await release(
      state: _git(signing: false),
      registry: _MutableRegistry(<String>['0.1.0']),
    );
    expect(
      ran.calls.firstWhere((c) => c.startsWith('git tag')),
      contains('git tag -a'),
    );
  });

  test('an existing tag is not created twice', () async {
    final ran = await release(
      state: _git(tags: const ['v0.2.0']),
      onRemote: const ['v0.2.0'],
      registry: _MutableRegistry(<String>['0.1.0']),
    );
    expect(
      ran.calls.where((c) => c.startsWith('git tag')),
      isEmpty,
      reason: 'inspect saw it locally and on origin, and skipped the step',
    );
  });

  test('a failed dry run stops before anything public', () async {
    final ran = await release(results: {
      'dart pub publish --dry-run': ToolResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Package validation found the following error:\n'
            'lib/src/private.dart is not in the package',
      ),
    });
    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.text, contains('not in the package'));
    expect(ran.calls, isNot(contains('dart pub publish --force')));
    expect(ran.calls.where((c) => c.startsWith('git tag')), isEmpty);
  });

  test('a release already published does nothing', () async {
    final ran = await release(
      registry: FakeRegistry({
        'keybay': ['0.1.0', '0.2.0']
      }),
      state: _git(tags: const ['v0.2.0']),
      onRemote: const ['v0.2.0'],
    );
    expect(ran.exitCode, ExitCodes.ok);
    expect(ran.text, contains('already released'));
    expect(
      ran.calls.where((c) => !c.startsWith('git ls-remote')),
      isEmpty,
      reason: 'reading the remote is inspection; nothing acted',
    );
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
    expect(
      ran.problems.map((p) => p['code']),
      contains('RK-AUTH-001'),
      reason: 'the refusal was prose-only under --json, against the '
          'project\'s own rule that every non-zero exit carries a problem',
    );
    expect(
      ran.calls.where(
          (c) => c.startsWith('git tag') || c.contains('publish --force')),
      isEmpty,
    );
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
    expect(
      ran.calls.where((c) => !c.startsWith('git ls-remote')),
      isEmpty,
      reason: 'reading the remote is inspection; nothing acted',
    );
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

/// Closeout for the phase 5 mutation review: nine survivors, clustered on
/// interruption and reporting.
void mutationCloseout() {
  test('a local tag origin lacks is pushed, not skipped', () async {
    // The reviewer's top finding, reproduced with real git: a push that died
    // mid-process left a local tag, the next run inspected it as done from
    // `git tag --list` alone, skipped the step — push included — and
    // completed the release with the authorizing tag absent from origin,
    // silently. The inspection now asks origin, and the act pushes what
    // exists.
    final registry = _MutableRegistry(<String>['0.1.0']);
    final ran = await release(
      state: _git(tags: const ['v0.2.0']), // local tag, no onRemote
      registry: registry,
      onRun: (key) {
        if (key == 'dart pub publish --force') {
          registry.goLive('0.2.0');
          registry.archives['keybay@0.2.0'] = publishedBytes();
        }
      },
    );

    expect(ran.exitCode, ExitCodes.ok, reason: ran.text);
    expect(
      ran.calls.where((c) => c.startsWith('git tag -s')),
      isEmpty,
      reason: 'the tag exists; re-creating it would fail',
    );
    expect(
      ran.calls,
      contains('git push origin v0.2.0'),
      reason: 'the half-done step is finished, not skipped',
    );
    expect(ran.text, contains('pre-existing local tag'));
  });

  test('a push that origin does not confirm is lostTrack, not success',
      () async {
    // The push exits 0 and ls-remote still lists nothing: the verify leg the
    // RFC names, which trusting the exit code alone skipped.
    final ran = await release(
      registry: _MutableRegistry(<String>['0.1.0']),
      results: {
        // A push the harness's world-model does not believe: script the
        // remote read directly to answer empty despite the "successful" push.
        'git ls-remote origin refs/tags/v0.2.0':
            ToolResult(exitCode: 0, stdout: '', stderr: ''),
      },
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.problems.map((p) => p['code']), contains('RK-TAG-003'));
    expect(ran.text, contains('an effect may exist'));
  });

  test(
      'an unreadable archive after a real publish is lostTrack with the '
      'proof one command away', () async {
    final registry = _MutableRegistry(<String>['0.1.0']);
    final ran = await release(
      registry: registry,
      onRun: (key) {
        if (key == 'dart pub publish --force') {
          registry.goLive('0.2.0');
          // No archive is ever served: the confirming read finds the
          // version listed and the bytes unreadable.
        }
      },
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.problems.map((p) => p['code']), contains('RK-PUB-004'));
    expect(ran.text, contains('an effect may exist'));
    expect(
      (ran.report['next'] as List),
      contains('rk verify core'),
      reason: 'the byte proof exists; the caller is pointed at it',
    );
  });

  test('tampered bytes after a real publish are acted-and-unfixable', () async {
    final registry = _MutableRegistry(<String>['0.1.0']);
    final ran = await release(
      registry: registry,
      onRun: (key) {
        if (key == 'dart pub publish --force') {
          registry.goLive('0.2.0');
          registry.archives['keybay@0.2.0'] = publishedBytes();
          registry.tampered.add('keybay@0.2.0');
        }
      },
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.problems.map((p) => p['code']), contains('RK-VER-004'));
    expect(
      ran.text,
      contains('rk acted, and what it read back cannot be fixed'),
      reason: 'the pre-act sentence said "rk did not act" about the worst '
          'path rk has',
    );
    expect(ran.report['rerun_helps'], false);
  });

  test('the consumer probe is written where and how the check demands',
      () async {
    // Three mutations survived because nothing could see the probe: written
    // without the override, pointed at the wrong path, or run in the package
    // directory — where pub honours pubspec_overrides.yaml, the exact
    // failure the check exists for.
    String? probeCwd;
    String? probePubspec;
    final registry = _MutableRegistry(<String>['0.1.0']);
    final ran = await release(
      registry: registry,
      probe: (key, cwd) {
        if (key == 'dart pub get --no-precompile') {
          probeCwd = cwd;
          probePubspec = File('$cwd/pubspec.yaml').readAsStringSync();
        }
      },
      onRun: (key) {
        if (key == 'dart pub publish --force') {
          registry.goLive('0.2.0');
          registry.archives['keybay@0.2.0'] = publishedBytes();
        }
      },
    );

    expect(ran.exitCode, ExitCodes.ok, reason: ran.text);
    expect(probeCwd, isNotNull);
    expect(
      probeCwd,
      isNot(contains('/repo')),
      reason: 'run in the package directory, pub honours '
          'pubspec_overrides.yaml — the exact failure the check exists for',
    );
    expect(probePubspec, contains('dependency_overrides'));
    expect(
      probePubspec,
      contains('path: /repo/packages/keybay'),
      reason: 'the override supplies the not-yet-published root by path',
    );
    expect(probePubspec, contains('keybay: 0.2.0'));
  });

  test('a first publish is refused with its diagnosis even unattended',
      () async {
    final ran = await release(
      registry: FakeRegistry({}),
      typed: null, // nobody at the terminal
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(
      ran.problems.map((p) => p['code']),
      contains('RK-REG-003'),
      reason: 'the guard runs before authorization, so a --json caller '
          'learns the real reason, not merely "nobody authorized"',
    );
  });
}
