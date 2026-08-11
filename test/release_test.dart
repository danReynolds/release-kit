import 'dart:convert';
import 'dart:io';

import 'package:release_kit/src/commands/release.dart';
import 'package:release_kit/src/destinations/pub_dev.dart';
import 'package:release_kit/src/engine/compare.dart';
import 'package:release_kit/src/engine/assets.dart';
import 'package:release_kit/src/transforms/archive.dart';
import 'package:release_kit/src/engine/config.dart';
import 'package:release_kit/src/engine/diagnostic.dart';
import 'package:release_kit/src/engine/git.dart';
import 'package:release_kit/src/engine/inspect.dart';
import 'package:release_kit/src/output/output.dart';
import 'package:release_kit/src/engine/registry.dart';
import 'package:release_kit/src/engine/release_stage.dart';
import 'package:release_kit/src/engine/resolve.dart';
import 'package:release_kit/src/engine/source_tree.dart';
import 'package:release_kit/src/engine/tools.dart';
import 'package:release_kit/src/engine/stage.dart';
import 'package:release_kit/src/transforms/digest.dart';
import 'package:test/test.dart';

import 'status_test.dart' show FakeRegistry;

const _config = '''
schema = 1

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]
''';

const _tagObject = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _tagPush = 'git push origin $_tagObject:refs/tags/v0.2.0';

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
      head: '1111111111111111111111111111111111111111',
      branch: 'main',
      isClean: clean,
      uncommitted: clean ? const [] : const ['lib/x.dart'],
      headIsPushed: pushed,
      tags: tags,
      // Stated, not omitted. These fixtures used to leave it empty and lean
      // on `tagTarget` answering null reading as "at HEAD" — the very
      // collapse RK-GIT-007 now refuses. A fixture that means "the tag is at
      // HEAD" should say so.
      tagTargets: {
        for (final t in tags) t: '1111111111111111111111111111111111111111'
      },
      tagObjects: {
        for (final t in tags) t: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      },
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
  String? preauthorized,
  bool dryRun = false,
  Map<String, ToolResult> results = const {},
  void Function(String key)? onRun,
  ToolResult? Function(String key)? answers,
  Iterable<String> onRemote = const [],
  String config = _config,
  String? only = 'core',
}) async {
  final buffer = StringBuffer();
  final diagnostics = Diagnostics();
  final tree = source ?? _tree();
  final parsed = ReleaseConfig.parse(config, 'release.toml', diagnostics)!;
  final resolution = Resolution.resolve(parsed, tree, diagnostics)!;
  final effectiveGit = state ?? _git();
  final stageRoot = Directory.systemTemp.createTempSync('rk-release-test-');
  addTearDown(() {
    if (stageRoot.existsSync()) stageRoot.deleteSync(recursive: true);
  });
  final stageCache = <String, ReleaseStage>{};
  ReleaseStage stageFor(ResolvedUnit unit) =>
      stageCache.putIfAbsent(unit.name, () {
        final identity = StageIdentity.forPlan(
          headCommit: '1111111111111111111111111111111111111111',
          headTree: '2222222222222222222222222222222222222222',
          resolvedPlan: {
            'unit': unit.name,
            'version': unit.version.canonical,
            'fixture_head': effectiveGit.head,
          },
        );
        return ReleaseStage(
          unit: unit,
          source: tree,
          directory: StageDirectory(
            repositoryRoot: stageRoot.path,
            identity: identity,
          ),
        );
      });

  // Origin lists what has been pushed — before this run ([onRemote]) or
  // during it. A static script cannot say that, and the remote-verify leg
  // reads it, so the harness models the one moving fact itself.
  final remoteTags = <String>{...onRemote};
  final localTags = <String>{...effectiveGit.tags};
  final tagObjects = <String, String>{
    for (final tag in effectiveGit.tags)
      tag: effectiveGit.tagObject(tag) ?? _tagObject,
  };
  final recorder = RecordingTools(
    results: results,
    onRun: (key) {
      if (key.startsWith('git tag -s ') || key.startsWith('git tag -a ')) {
        final scripted = results[key];
        if (scripted == null || scripted.exitCode == 0) {
          final tag = key.split(' ')[3];
          localTags.add(tag);
          tagObjects[tag] = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        }
      }
      if (key.startsWith('git update-ref -d refs/tags/')) {
        final parts = key.split(' ');
        final tag = parts[3].substring('refs/tags/'.length);
        final object = parts[4];
        final scripted = results[key];
        if ((scripted == null || scripted.exitCode == 0) &&
            tagObjects[tag] == object) {
          localTags.remove(tag);
          tagObjects.remove(tag);
        }
      }
      const push = 'git push origin ';
      if (key.startsWith(push)) {
        final scripted = results[key];
        if (scripted == null || scripted.exitCode == 0) {
          final refspec = key.substring(push.length);
          const marker = ':refs/tags/';
          if (refspec.contains(marker)) {
            remoteTags.add(refspec.split(marker).last);
          }
        }
      }
      onRun?.call(key);
    },
    answers: (key) {
      const objectPrefix = 'git rev-parse --verify refs/tags/';
      if (key.startsWith(objectPrefix) && key.endsWith('^{tag}')) {
        final tag =
            key.substring(objectPrefix.length, key.length - '^{tag}'.length);
        final object = tagObjects[tag];
        if (localTags.contains(tag) && object != null) {
          return ToolResult(exitCode: 0, stdout: '$object\n', stderr: '');
        }
        return ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: 'unknown tag',
        );
      }
      const prefix = 'git ls-remote origin refs/tags/';
      if (key.startsWith(prefix)) {
        final tag = key.substring(prefix.length).split(' ').first;
        final object = tagObjects[tag] ?? effectiveGit.head;
        final commit = effectiveGit.tagTarget(tag) ?? effectiveGit.head;
        return ToolResult(
          exitCode: 0,
          stdout: remoteTags.contains(tag)
              ? object == commit
                  ? '$commit refs/tags/$tag'
                  : '$object refs/tags/$tag\n'
                      '$commit refs/tags/$tag^{}'
              : '',
          stderr: '',
        );
      }
      if (key.startsWith('git cat-file tag ')) {
        final object = key.substring('git cat-file tag '.length);
        final tag = tagObjects.entries
            .where((entry) => entry.value == object)
            .map((entry) => entry.key)
            .firstOrNull;
        if (tag != null && localTags.contains(tag)) {
          final unit = resolution.units.firstWhere((unit) => unit.tag == tag);
          final manifest = File(
            stageFor(unit).directory.resolve(ReleaseAssets.manifest),
          );
          // Before release has rebuilt a missing stage, only structural
          // binding is knowable. Once the stage exists, model the interrupted
          // tag as binding those deterministic bytes.
          final digest = manifest.existsSync()
              ? Sha256.hex(manifest.readAsBytesSync())
              : 'b' * 64;
          return ToolResult(
            exitCode: 0,
            stdout: 'object ${effectiveGit.head}\n'
                'type commit\n'
                'tag $tag\n'
                'tagger Test <test@example.com> 0 +0000\n\n'
                '${unit.name} ${unit.version}\n\n'
                'release-manifest-sha256: $digest\n',
            stderr: '',
          );
        }
      }
      // The test's own world model, after the harness's: a binary unit's
      // forge and identity reads live here.
      return answers?.call(key);
    },
  );

  final effectiveRegistry = registry ??
      FakeRegistry({
        'keybay': ['0.1.0']
      });
  final command = ReleaseCommand(
    resolution: resolution,
    tree: tree,
    git: effectiveGit,
    // The same reader the command gets, or the inspection would consult a
    // different reality than the act — and the same tools, so the tag
    // step's remote half reads the harness's remote.
    inspector: Inspector(
      registry: effectiveRegistry,
      git: effectiveGit,
      pubDev: PubDevTarget(
        registry: effectiveRegistry,
        comparator: Comparator(tools: const SystemTools()),
        source: tree,
      ),
      tools: recorder,
      repository: 'example/keybay',
      stageFor: stageFor,
    ),
    tools: recorder,
    // Yields to the event queue rather than completing in a microtask: a
    // mutation that unbounded the confirm poll wedged the whole test runner
    // instead of failing, because even the framework's timeout timer starved.
    wait: (_) => Future<void>.delayed(Duration.zero),
    output: Output(sink: buffer.write, isTerminal: false, useColor: false),
    confirm: typed == null ? null : (_) async => typed,
    preauthorized: preauthorized,
    stageOnly: dryRun,
    stageFor: stageFor,
    refreshStage: (unit, _) => stageFor(unit),
    refreshGit: () => effectiveGit,
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

void releaseCommandContract() {
  test('the only unit a repository has needs no naming', () async {
    // A unit is what ships together, so one unit is the whole release and
    // there is nothing to disambiguate — the same resolution `rk status`
    // performs when it is given no unit either.
    final registry = _MutableRegistry(<String>['0.1.0']);
    final ran = await release(
      only: null,
      registry: registry,
      onRun: (key) {
        if (key == 'dart pub publish --force') {
          registry.goLive('0.2.0');
          registry.archives['keybay@0.2.0'] = publishedBytes();
        }
      },
    );

    expect(ran.exitCode, ExitCodes.ok, reason: ran.text);
    expect(ran.calls, contains('dart pub publish --force'));
  });

  test('two units are two releases, and rk will not pick one', () async {
    final ran = await release(
      only: null,
      config: '''
schema = 1

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]

[release.other]
path = "packages/other"
publish = ["pub.dev"]
''',
      source: MemorySourceTree({
        'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
        'packages/keybay/CHANGELOG.md': '## 0.2.0\n',
        'packages/other/pubspec.yaml': 'name: other\nversion: 0.2.0\n',
        'packages/other/CHANGELOG.md': '## 0.2.0\n',
      }, description: '/repo/keybay'),
    );

    expect(ran.exitCode, ExitCodes.usage);
    expect(ran.problems.map((problem) => problem['code']), ['RK-CLI-004']);
    expect(ran.text, contains('core, other'));
    expect(
      ran.calls,
      isEmpty,
      reason: 'an ambiguous release must not start work',
    );
  });
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
  ToolResult? forge(String key, {List<String> publishedTags = const []}) {
    if (key.startsWith('gh api --paginate --slurp')) {
      return ToolResult(
        exitCode: 0,
        stdout: jsonEncode([
          [
            for (final tag in publishedTags) {'tag_name': tag, 'draft': false},
          ],
        ]),
        stderr: '',
      );
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
        return forge(key, publishedTags: const ['v0.8.0', 'v0.9.0']);
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
        if (key.startsWith('codesign -d -r-')) {
          return ToolResult(
            exitCode: 0,
            stdout: 'designated => identifier "io.github.other.tool" and '
                'certificate leaf[subject.OU] = "TEAM123456"',
            stderr: '',
          );
        }
        return forge(key, publishedTags: const ['v0.9.0']);
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
      state: _git(tags: const [], root: root.path),
      registry: FakeRegistry({}),
      // An operator is present so the release reaches the stage and baseline
      // reads this test exercises, then declines the final authorization.
      typed: 'stop',
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
        if (key.startsWith('codesign -d -r-')) {
          return ToolResult(
            exitCode: 0,
            stdout: 'designated => certificate '
                'leaf[subject.OU] = "TEAM123456"',
            stderr: '',
          );
        }
        return forge(key, publishedTags: const ['v0.8.0', 'v0.9.0']);
      },
    );

    expect(ran.exitCode, ExitCodes.refused, reason: 'the operator declined');
    expect(downloads, hasLength(1));
    expect(
      downloads.single,
      contains(' v0.9.0 '),
      reason: 'the release users most recently installed is the identity '
          'this one must be continuous with',
    );
  });

  test('a newer source-only release does not hide an older signed baseline',
      () async {
    final root = Directory.systemTemp.createTempSync('rk-baseline-history-');
    addTearDown(() => root.deleteSync(recursive: true));
    final releasesRead = <String>[];
    final downloads = <String>[];
    final ran = await release(
      config: binaryConfig,
      source: binaryTree(),
      state: _git(tags: const [], root: root.path),
      registry: FakeRegistry({}),
      typed: 'stop',
      only: 'cli',
      answers: (key) {
        if (key.contains('/releases/tags/v0.9.0')) {
          releasesRead.add('v0.9.0');
          return ToolResult(
            exitCode: 0,
            stdout: '{"assets":[{"name":"source.tar.gz"}]}',
            stderr: '',
          );
        }
        if (key.contains('/releases/tags/v0.8.0')) {
          releasesRead.add('v0.8.0');
          return ToolResult(
            exitCode: 0,
            stdout: '{"assets":[{'
                '"name":"tool-0.8.0-macos-arm64.tar.gz"}]}',
            stderr: '',
          );
        }
        if (key.startsWith('gh release download')) {
          downloads.add(key);
          return ToolResult(exitCode: 0, stdout: '', stderr: '');
        }
        if (key.startsWith('codesign -d -r-')) {
          return ToolResult(
            exitCode: 0,
            stdout: 'designated => identifier "com.example.tool" and '
                'certificate leaf[subject.OU] = "TEAM123456"',
            stderr: '',
          );
        }
        if (key.startsWith('security find-identity')) {
          return ToolResult(
            exitCode: 0,
            stdout: '1) ${'a' * 40} "Developer ID Application: D '
                '(TEAM123456)"',
            stderr: '',
          );
        }
        if (key.startsWith('security find-certificate')) {
          return ToolResult(
            exitCode: 0,
            stdout: 'SHA-256 hash: ${'b' * 64}\n'
                'SHA-1 hash: ${'a' * 40}\n',
            stderr: '',
          );
        }
        return forge(key, publishedTags: const ['v0.8.0', 'v0.9.0']);
      },
    );

    expect(ran.exitCode, ExitCodes.refused, reason: 'the operator declined');
    expect(releasesRead, ['v0.9.0', 'v0.8.0']);
    expect(downloads, hasLength(1));
    expect(downloads.single, contains(' v0.8.0 '));
    expect(
      ran.text,
      isNot(contains('this release claims, for the first time:')),
    );
  });
}

void main() {
  releaseCommandContract();
  reviewRegressions();
  mutationCloseout();
  signingBaselineRegressions();

  test('stage prepares every local input and nothing public', () async {
    final ran = await release(dryRun: true);
    expect(ran.exitCode, ExitCodes.ok, reason: ran.text);
    expect(ran.text, contains('0.2.0 staged'));
    expect(
      ran.calls.where((c) => c.startsWith('git tag')),
      isEmpty,
      reason: 'nothing public',
    );
    expect(ran.calls.where((c) => c.contains('publish --force')), isEmpty);
    expect(
      ran.calls,
      isNot(contains('dart pub login')),
      reason: 'staging validates package contents but does not acquire a '
          'publishing session',
    );
    expect(
      ran.calls,
      contains('dart pub publish --dry-run'),
      reason: 'the rehearsal rehearses: the first real run once discovered '
          'a validation refusal only after the signed tag was public',
    );
  });

  test('a missing pub session refuses before staging or any public act',
      () async {
    final ran = await release(
      results: {
        'dart pub login': ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: 'authentication failed',
        ),
      },
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.problems.map((problem) => problem['code']), ['RK-PUB-007']);
    expect(
      (ran.report['halt'] as Map?)?['kind'],
      'beforeActing',
    );
    expect(ran.text, contains('dart pub login did not complete'));
    expect(ran.text, contains('no public target changed'));
    expect(ran.calls, contains('dart pub login'));
    expect(ran.calls, isNot(contains('dart pub publish --dry-run')));
    expect(ran.calls.where((call) => call.startsWith('git tag ')), isEmpty);
    expect(ran.calls, isNot(contains('dart pub publish --force')));
    expect('not attempted'.allMatches(ran.text), hasLength(2));
  });

  test('a pub login launch error is a release refusal, not an rk crash',
      () async {
    final ran = await release(
      onRun: (key) {
        if (key == 'dart pub login') {
          throw ProcessException(
            'dart',
            const ['pub', 'login'],
            'could not start dart',
          );
        }
      },
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.problems.map((problem) => problem['code']), ['RK-PUB-007']);
    expect(ran.problems.map((problem) => problem['code']),
        isNot(contains('RK-INT-001')));
    expect(ran.calls, isNot(contains('dart pub publish --dry-run')));
    expect(ran.calls.where((call) => call.startsWith('git tag ')), isEmpty);
  });

  test('an unexpected pub login adapter error remains an rk crash', () async {
    await expectLater(
      () => release(
        onRun: (key) {
          if (key == 'dart pub login') throw StateError('adapter broke');
        },
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('an unconfirmed release publishes nothing, and says so as data',
      () async {
    final ran = await release(typed: 'yes');
    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.text, contains('nothing was published'));
    expect(
      ran.problems.map((p) => p['code']),
      contains('RK-AUTH-002'),
      reason: 'every refusal carries a code — an exit-1 document with empty '
          'problems and rerun_helps true tells an agent to loop forever',
    );
    expect((ran.report['halt'] as Map?)?['kind'], 'beforeActing');
    expect(
      ran.calls.where(
          (c) => c.startsWith('git tag') || c.contains('publish --force')),
      isEmpty,
      reason: 'read-only preflight may run; nothing public may',
    );
  });

  test('a wrong --confirm refuses before any credential is touched', () async {
    final ran = await release(typed: '9.9.9', preauthorized: '9.9.9');
    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.problems.map((p) => p['code']), ['RK-AUTH-002']);
    expect(
      ran.calls,
      isNot(contains('dart pub login')),
      reason: 'a value that cannot authorize this release must not acquire '
          'a publishing session or spend signing and notary work',
    );
    expect(ran.calls, isNot(contains('dart pub publish --dry-run')));
    expect((ran.report['halt'] as Map?)?['kind'], 'beforeActing');
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
      (ran.report['repository'] as Map)['head'],
      isNotNull,
      reason: 'doc/json.md promises repository on every verb, and the '
          'production-alpha retry checkpoint reads its head',
    );
    final unitDocument = (ran.report['units'] as List).cast<Map>().single;
    expect(unitDocument['version'], '0.2.0');
    expect(unitDocument['tag'], 'v0.2.0');
    expect(
      (ran.report['attachments'] as Map?)?['authorization-disclosures'],
      contains('pub.dev never deletes a version'),
      reason: 'what the prompt disclosed travels with the yes, so a --json '
          '--confirm caller reads it on the surface that carries the yes',
    );
    expect(
      ran.calls.where((call) => call == 'dart pub login'),
      hasLength(1),
      reason: 'the unit acquires its native pub session once',
    );
    final pubLogin = ran.calls.indexOf('dart pub login');
    final pubValidation = ran.calls.indexOf('dart pub publish --dry-run');
    final tag = ran.calls.indexWhere(
      (call) => call.startsWith('git tag -s v0.2.0 -m core 0.2.0'),
    );
    final push = ran.calls.indexOf(_tagPush);
    final publish = ran.calls.indexOf('dart pub publish --force');
    final orderedCalls = [
      pubLogin,
      pubValidation,
      tag,
      push,
      publish,
    ];
    expect(orderedCalls, everyElement(greaterThanOrEqualTo(0)));
    expect(
      orderedCalls,
      orderedEquals([...orderedCalls]..sort()),
      reason: 'everything read-only runs before anything public: the first '
          'real run once discovered a validation refusal only after the '
          'signed tag was pushed',
    );
    expect(
      ran.calls[tag],
      contains('release-manifest-sha256:'),
      reason: 'the signed tag binds the immutable manifest it names',
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
    expect(ran.text, contains('no public target changed'));
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
        _tagPush: ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: 'fatal: unable to access origin',
        ),
      },
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(
      ran.calls,
      contains('git update-ref -d refs/tags/v0.2.0 $_tagObject'),
      reason: 'a local tag nobody else can see is a trap: the next run '
          'would inspect it as done and publish a version bound to a commit '
          'only this machine knows about',
    );
    expect(ran.text, contains('no public target changed'));
    expect(ran.problems.map((p) => p['code']), contains('RK-TAG-002'));
    expect(
      ran.calls.where((c) => c.contains('publish --force')),
      isEmpty,
    );
  });

  test('a failed tag cleanup is a known partial state, not before publishing',
      () async {
    final ran = await release(
      registry: _MutableRegistry(<String>['0.1.0']),
      results: {
        _tagPush: ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: 'fatal: unable to access origin',
        ),
        'git update-ref -d refs/tags/v0.2.0 $_tagObject': ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: 'could not update refs',
        ),
      },
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect((ran.report['halt'] as Map?)?['kind'], 'stoppedPartway');
    expect(ran.text, isNot(contains('no public target changed')));
    expect(ran.text, contains('local tag could not be removed'));
    expect(
        ran.calls.where((call) => call.contains('publish --force')), isEmpty);
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
      }, archives: {
        'keybay@0.2.0': publishedBytes(),
      }),
      state: _git(tags: const ['v0.2.0']),
      onRemote: const ['v0.2.0'],
    );
    expect(ran.exitCode, ExitCodes.ok);
    expect(ran.text, contains('already released'));
    expect(
      ran.calls.where(
        (call) =>
            call.startsWith('git tag -s ') ||
            call.startsWith('git tag -a ') ||
            call.startsWith('git push ') ||
            call.contains('pub publish --force'),
      ),
      isEmpty,
      reason: 'object/signature authentication is inspection; nothing acted',
    );
    expect(ran.calls, isNot(contains('dart pub login')),
        reason: 'no pub.dev act remains');
  });

  test('an unclean worktree halts before acting', () async {
    final ran = await release(state: _git(clean: false));
    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.text, contains('no public target changed'));
    expect(ran.text, contains('uncommitted'));
    expect(ran.calls, everyElement(startsWith('git ls-remote')));
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
    expect(ran.calls, everyElement(startsWith('git ls-remote')));
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
    expect(ran.calls, isNot(contains('dart pub login')));
    expect(ran.calls, isNot(contains('dart pub publish --dry-run')),
        reason: 'normal release refuses before acquiring credentials or '
            'preparing a stage when no operator can authorize it');
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

  /// The registry before the package exists at all, so `lookup` answers
  /// null — "has never been published", and nothing else.
  _MutableRegistry.unpublished() : super({});

  /// What `dart pub publish` does at the registry. A first publish creates
  /// the package, so the key may not be there yet.
  void goLive(String version) =>
      (published['keybay'] ??= <String>[]).add(version);
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
    expect(
      ran.calls,
      everyElement(startsWith('git ls-remote')),
      reason: 'only the read-only tag observation ran',
    );
    expect(ran.text, contains('no public target changed'),
        reason: 'beforeActing');
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

  test('a first publish states the name it claims, then performs it', () async {
    // rk refused this outright as RK-REG-003, saying a first publish
    // "accepts the terms and names a publisher". pub's own publish command
    // has no first-time branch: --force skips only the confirmation prompt,
    // the prompt text is identical for a new name, and there is no terms
    // acceptance in the flow. The refusal was justified by a ceremony that
    // does not exist.
    final registry = _MutableRegistry.unpublished();
    final ran = await release(
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
      ran.calls.any((c) => c == 'dart pub publish --force'),
      isTrue,
      reason: 'the release rk was asked for is the release it performs',
    );
    expect(
      ran.text,
      contains('this release claims, for the first time:'),
      reason: 'what a first publish really takes is the NAME, permanently — '
          'so the operator reads it before consenting',
    );
    expect(
      ran.text,
      contains('pub.dev          keybay'),
      reason: 'the name itself is on the line, because a typo claiming a '
          'name nobody meant to own is the accident this guards against',
    );
  });

  test('publishing a back-version is refused by release itself', () async {
    final ran = await release(
      registry: FakeRegistry({
        'keybay': ['0.5.0'], // ahead of the 0.2.0 in the manifest
      }),
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.calls, everyElement(startsWith('git ls-remote')));
    expect(
      ran.problems.map((p) => p['code']),
      contains('RK-MONO-002'),
      reason: 'the top-ranked failure was checked only by the verb that '
          'does not act',
    );
  });

  test('a shallow checkout cannot release behind the newest origin tag',
      () async {
    final ran = await release(
      results: {
        'git ls-remote --tags origin': ToolResult(
          exitCode: 0,
          stdout: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa '
              'refs/tags/v0.5.0\n',
          stderr: '',
        ),
      },
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.problems.map((problem) => problem['code']),
        contains('RK-MONO-003'));
    expect(ran.text, allOf(contains('Git tag'), contains('0.5.0')));
    expect(
      ran.calls,
      isNot(contains('dart pub publish --dry-run')),
      reason: 'the public-history gate runs before private production',
    );
    expect(ran.calls.where((call) => call.startsWith('git tag ')), isEmpty);
  });

  test('an unreadable origin history refuses before staging', () async {
    final ran = await release(
      results: {
        'git ls-remote --tags origin': ToolResult(
          exitCode: 128,
          stdout: '',
          stderr: 'could not resolve host',
        ),
      },
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(
      ran.problems.map((problem) => problem['code']),
      contains('RK-REL-001'),
    );
    expect(ran.text, contains('origin tags could not be read'));
    expect(ran.calls, isNot(contains('dart pub publish --dry-run')));
    expect(ran.calls.where((call) => call.startsWith('git tag ')), isEmpty);
  });

  test('public history is refreshed after staging and before authorization',
      () async {
    var inventories = 0;
    final ran = await release(
      answers: (key) {
        if (key != 'git ls-remote --tags origin') return null;
        inventories++;
        return ToolResult(
          exitCode: 0,
          stdout: inventories == 1
              ? ''
              : 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa '
                  'refs/tags/v0.5.0\n',
          stderr: '',
        );
      },
    );

    expect(inventories, 2);
    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.problems.map((problem) => problem['code']),
        contains('RK-MONO-003'));
    expect(
      ran.calls,
      contains('dart pub publish --dry-run'),
      reason: 'the newer tag appeared only after the private stage was made',
    );
    expect(ran.calls.where((call) => call.startsWith('git tag ')), isEmpty,
        reason: 'the refreshed gate still runs before authorization or act');
  });

  test('history advancing after authorization refuses before the first act',
      () async {
    var inventories = 0;
    final ran = await release(
      answers: (key) {
        if (key != 'git ls-remote --tags origin') return null;
        inventories++;
        return ToolResult(
          exitCode: 0,
          stdout: inventories < 4
              ? ''
              : 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa '
                  'refs/tags/v0.5.0\n',
          stderr: '',
        );
      },
    );

    expect(inventories, 4,
        reason: 'initial, post-stage, authorization, and immediate pre-act '
            'reads');
    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.problems.map((problem) => problem['code']),
        contains('RK-MONO-003'));
    expect(ran.calls.where((call) => call.startsWith('git tag ')), isEmpty);
    expect(
      ran.calls,
      isNot(contains('dart pub publish --force')),
      reason: 'no later public step can run after the first lane advances',
    );
  });

  test('the authorization snapshot refreshes public history last', () async {
    var inventories = 0;
    final ran = await release(
      typed: 'stop',
      answers: (key) {
        if (key != 'git ls-remote --tags origin') return null;
        inventories++;
        return ToolResult(
          exitCode: 0,
          stdout: inventories < 3
              ? ''
              : 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa '
                  'refs/tags/v0.5.0\n',
          stderr: '',
        );
      },
    );

    expect(inventories, 3);
    expect(ran.exitCode, ExitCodes.refused);
    expect(
      ran.problems.map((problem) => problem['code']),
      contains('RK-MONO-003'),
    );
    expect(
      ran.problems.map((problem) => problem['code']),
      isNot(contains('RK-AUTH-001')),
      reason: 'the final public snapshot runs before authorization is asked',
    );
    expect(ran.calls.where((call) => call.startsWith('git tag ')), isEmpty);
  });

  test('a fully published version with no tag is not tagged after the fact',
      () async {
    final ran = await release(
      registry: FakeRegistry({
        'keybay': ['0.2.0'], // already out; only the tag step is absent
      }, archives: {
        'keybay@0.2.0': publishedBytes(),
      }),
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(
      ran.calls,
      everyElement(startsWith('git ls-remote')),
      reason: 'no retroactive tag was minted',
    );
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
    expect(ran.text, contains('no public target changed'));
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
      contains(_tagPush),
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
        'git ls-remote origin refs/tags/v0.2.0 refs/tags/v0.2.0^{}':
            ToolResult(exitCode: 0, stdout: '', stderr: ''),
      },
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(ran.problems.map((p) => p['code']), contains('RK-TAG-003'));
    expect(ran.text, contains('an effect may exist'));
  });

  test('an unreadable archive after a real publish is lostTrack', () async {
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
    expect(ran.problems.map((p) => p['code']), contains('RK-PUB-005'));
    expect(ran.text, contains('an effect may exist'));
    expect(
      (ran.report['next'] as List),
      contains('rk status core'),
      reason: 'status and release use the same exact read',
    );
  });

  test('a non-zero publish reconciles when the exact archive landed', () async {
    final registry = _MutableRegistry(<String>['0.1.0']);
    final ran = await release(
      registry: registry,
      results: {
        'dart pub publish --force': ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: 'connection closed before the response',
        ),
      },
      onRun: (key) {
        if (key == 'dart pub publish --force') {
          // The server committed the act before the client observed its lost
          // response. The shared exact inspector, not exit 1, decides this.
          registry.goLive('0.2.0');
          registry.archives['keybay@0.2.0'] = publishedBytes();
        }
      },
    );

    expect(ran.exitCode, ExitCodes.ok, reason: ran.text);
    expect(ran.text, contains('public archive confirmed exact'));
    expect(ran.problems, isEmpty);
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
    expect(ran.problems.map((p) => p['code']), contains('RK-PUB-006'));
    expect(
      ran.text,
      contains('rk acted, and what it read back cannot be fixed'),
      reason: 'the pre-act sentence said "rk did not act" about the worst '
          'path rk has',
    );
    expect(ran.report['rerun_helps'], false);
  });

  test('a later publish claims nothing, and says so by saying nothing',
      () async {
    // The negative direction. Announcing a first-time claim for a name that
    // is already published is the same false-consent bug the first-signing
    // disclosure had — it told the operator an identity did not exist yet
    // while reading it off the binary users had installed.
    final registry = _MutableRegistry(<String>['0.1.0']);
    final ran = await release(
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
      ran.text,
      isNot(contains('claims, for the first time')),
      reason: 'keybay is published; this release takes no new name',
    );
  });

  test('a first publish unattended is refused for want of a human, not a rule',
      () async {
    final ran = await release(
      registry: FakeRegistry({}),
      typed: null, // nobody at the terminal
    );

    expect(ran.exitCode, ExitCodes.refused);
    expect(
      ran.problems.map((p) => p['code']),
      contains('RK-AUTH-001'),
      reason: 'claiming a name permanently is exactly what wants a human — '
          'and with nobody there, that is the honest reason to refuse',
    );
    // `--force` is the act; `--dry-run` is the validation leg, which runs
    // before authorization by design.
    expect(ran.calls.any((c) => c == 'dart pub publish --force'), isFalse);
  });
}
