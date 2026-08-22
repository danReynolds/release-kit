import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/commands/status.dart';
import 'package:rk/src/targets/pub_dev/client.dart';
import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/inspect.dart';
import 'package:rk/src/engine/registry.dart';
import 'package:rk/src/engine/release_asset.dart';
import 'package:rk/src/engine/release_stage.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/engine/stage_archive.dart';
import 'package:rk/src/engine/stage_plan.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:rk/src/engine/targets.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/engine/version.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/targets/target_module.dart';
import 'package:rk/src/transforms/archive.dart';
import 'package:test/test.dart';

/// An origin that lists exactly the tags git holds locally.
///
/// The ordinary world, and the default one: a tag that was created was also
/// pushed. Status used to model this by passing no [Tools] at all, which was
/// not the same thing — it meant "origin was never asked", and the tag step
/// answered `unknown`. A test asserting "nothing to release" through a
/// toolless inspector was asserting that an unread origin counts as read.
/// Tests that want a divergent world pass their own tools.
class OriginAgreeing implements Tools {
  OriginAgreeing(this.tags, this.head);

  final List<String> tags;
  final String head;

  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    if (executable == 'git' && arguments.first == 'ls-remote') {
      if (arguments.length == 3 && arguments[1] == '--tags') {
        return ToolResult(
          exitCode: 0,
          stdout: [
            for (final tag in tags) ...[
              '$testTagObject\trefs/tags/$tag',
              '$head\trefs/tags/$tag^{}',
            ],
          ].join('\n'),
          stderr: '',
        );
      }
      final tag = tags
          .where(
            (tag) => arguments.contains('refs/tags/$tag'),
          )
          .firstOrNull;
      final ref = tag == null ? null : 'refs/tags/$tag';
      return ToolResult(
        exitCode: 0,
        stdout: ref == null ? '' : '$testTagObject $ref\n$head $ref^{}',
        stderr: '',
      );
    }
    if (executable == 'git' &&
        arguments.length == 3 &&
        arguments[0] == 'cat-file' &&
        arguments[1] == 'tag' &&
        arguments[2] == testTagObject) {
      return ToolResult(
        exitCode: 0,
        stdout: 'object $head\n'
            'type commit\n'
            'tag v-test\n'
            '\n'
            'release-manifest-sha256: $testManifestDigest\n',
        stderr: '',
      );
    }
    if (executable == 'git' && arguments.first == 'verify-tag') {
      return ToolResult(exitCode: 0, stdout: '', stderr: '');
    }
    return ToolResult(exitCode: 127, stdout: '', stderr: 'not scripted');
  }

  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async =>
      0;
}

/// A valid historical release tag whose source predates the current checkout.
class ReleasedTagOrigin implements Tools {
  const ReleasedTagOrigin({required this.tag, required this.releasedHead});

  final String tag;
  final String releasedHead;

  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    if (executable == 'git' && arguments.first == 'ls-remote') {
      return ToolResult(
        exitCode: 0,
        stdout: '$testTagObject\trefs/tags/$tag\n'
            '$releasedHead\trefs/tags/$tag^{}\n',
        stderr: '',
      );
    }
    if (executable == 'git' &&
        arguments.length == 3 &&
        arguments[0] == 'cat-file' &&
        arguments[1] == 'tag' &&
        arguments[2] == testTagObject) {
      return ToolResult(
        exitCode: 0,
        stdout: 'object $releasedHead\n'
            'type commit\n'
            'tag $tag\n\n'
            'release-manifest-sha256: $testManifestDigest\n',
        stderr: '',
      );
    }
    if (executable == 'git' && arguments.first == 'verify-tag') {
      return ToolResult(exitCode: 0, stdout: '', stderr: '');
    }
    return ToolResult(exitCode: 127, stdout: '', stderr: 'not scripted');
  }

  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async =>
      0;
}

const testHead = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const testTree = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const testTagObject = 'cccccccccccccccccccccccccccccccccccccccc';
const testManifestDigest =
    '0000000000000000000000000000000000000000000000000000000000000000';

/// A registry with a fixed idea of what is published, so status can be
/// exercised without a network.
class FakeRegistry implements RegistryReader, PublicationInspector {
  FakeRegistry(
    this.published, {
    this.unreachable = false,
    this.conflicting = const {},
    this.repositories = const {},
    Map<String, List<int>>? archives,
  }) : archives = archives ?? {};

  /// Package name to the versions live on the registry.
  ///
  /// Held by reference on purpose: this map is *the world*, and a test that
  /// models a process restart builds a fresh FakeRegistry — fresh per-process
  /// memo — around the same world. A memo that survived "restarts" hid a
  /// double publish: the second run answered from the first run's cache.
  final Map<String, List<String>> published;
  final bool unreachable;

  /// Packages whose published content differs from this source.
  final Set<String> conflicting;

  /// Package name to the repository declared by its published pubspec.
  final Map<String, String> repositories;

  /// Archive bytes by "name@version", for the verify paths.
  final Map<String, List<int>> archives;

  /// Successful lookups memoized, exactly as the real client memoizes.
  ///
  /// The parity matters: the real cache is why a post-publish verification
  /// must forget before it reads, and a fake without the cache cannot
  /// reproduce that bug — which is how it shipped.
  final Map<String, RegistryPackage?> _memo = {};

  @override
  void forget(String name) => _memo.remove(name);

  @override
  Future<RegistryPackage?> lookup(String name) async {
    // The real client throws when it cannot find out — null means "has never
    // existed", and nothing else. A fake that answered null for unreachable
    // taught callers exactly the collapse the real client refuses, and hid a
    // mutation: a prerequisite read through it could never exercise the
    // unreachable path at all.
    if (unreachable) {
      throw RegistryUnavailable('pub.dev could not be reached');
    }
    if (_memo.containsKey(name)) return _memo[name];
    final versions = published[name];
    if (versions == null) return _memo[name] = null;
    return _memo[name] = RegistryPackage(
      name: name,
      versions: versions
          .map(
            (v) => PublishedVersion(
              version: Version.tryParse(v)!,
              published: DateTime.utc(2026, 1, 15),
              archiveSha256: archives['$name@$v'] == null
                  ? null
                  : Sha256.hex(archives['$name@$v']!),
              repository: repositories[name],
            ),
          )
          .toList(),
    );
  }

  @override
  Future<PublishedVersion?> lookupVersion(String name, Version version) async =>
      (await lookup(name))?.at(version);

  @override
  Future<Inspection> inspectProject(
    ResolvedProject project, {
    String? expectedArchiveSha256,
  }) {
    if (conflicting.contains(project.name)) {
      return Future.value(
        const Inspection.conflict('differs from this source'),
      );
    }
    return PubDevTarget(registry: this).inspectProject(
      project,
      expectedArchiveSha256: expectedArchiveSha256,
    );
  }
}

/// A destination-only inspector for status layout tests. It keeps provider
/// mechanics out of tests whose subject is the report contract.
class FixedInspector extends Inspector {
  FixedInspector({
    required super.registry,
    required super.git,
    required this.answer,
    this.latest,
    this.answers = const {},
  });

  final Inspection answer;
  final Inspection? latest;
  final Map<StepKind, Inspection> answers;

  @override
  Future<Inspection> inspect(Step step, ResolvedUnit unit) async =>
      answers[step.kind] ?? answer;

  @override
  Future<TargetHistory?> inspectHistory(
    TargetPlan target,
    ResolvedUnit unit, {
    bool fresh = false,
  }) async {
    final configured = latest;
    if (configured != null) {
      return TargetHistory.versioned(
        inspection: configured,
        target: target,
      );
    }
    final targetAnswer = answers[target.step.kind] ?? answer;
    if (targetAnswer.isExact) {
      return TargetHistory.versioned(
        inspection: Inspection.exact(
          detail: targetAnswer.detail,
          evidence: {
            ...targetAnswer.evidence,
            'version': target.targetVersion,
          },
        ),
        target: target,
      );
    }
    if (targetAnswer.isAbsent && target.kind == 'pubDev') {
      return super.inspectHistory(target, unit, fresh: fresh);
    }
    return TargetHistory.versioned(
      inspection: targetAnswer,
      target: target,
    );
  }

  @override
  List<Diagnostic> tagGuards(
    ResolvedUnit unit,
    Checklist checklist,
    Map<String, Inspection> states,
  ) =>
      const [];
}

class GuardInspector extends FixedInspector {
  GuardInspector({
    required super.registry,
    required super.git,
    required this.code,
  }) : super(answer: const Inspection.absent());

  final String code;

  @override
  List<Diagnostic> tagGuards(
    ResolvedUnit unit,
    Checklist checklist,
    Map<String, Inspection> states,
  ) =>
      [
        Diagnostic(
          code: code,
          message: 'the Git tag lane is blocked',
          remedy: 'repair the tag, then run status again',
        ),
      ];
}

/// Holds every target read until the test releases it independently.
class CoordinatedInspector extends Inspector {
  CoordinatedInspector({
    required super.registry,
    required super.git,
    required this.expected,
  });

  final int expected;
  final allStarted = Completer<void>();
  final Map<StepKind, Completer<void>> _gates = {};
  var active = 0;
  var maximumActive = 0;
  var started = 0;

  @override
  Future<Inspection> inspect(Step step, ResolvedUnit unit) async {
    final gate = _gates.putIfAbsent(step.kind, Completer<void>.new);
    started++;
    active++;
    if (active > maximumActive) maximumActive = active;
    if (started == expected && !allStarted.isCompleted) allStarted.complete();
    await gate.future;
    active--;
    return const Inspection.absent();
  }

  void finish(StepKind kind) => _gates[kind]!.complete();

  @override
  List<Diagnostic> tagGuards(
    ResolvedUnit unit,
    Checklist checklist,
    Map<String, Inspection> states,
  ) =>
      const [];
}

GitState git({
  bool clean = true,
  bool pushed = true,
  List<String> tags = const [],
  String? tagTarget,
}) =>
    GitState(
      root: '/repo',
      head: testHead,
      headTree: testTree,
      branch: 'main',
      isClean: clean,
      uncommitted: clean ? const [] : const ['lib/src/args.dart'],
      headIsPushed: pushed,
      tags: tags,
      // Stated rather than omitted, for the reason RK-GIT-007 exists: an
      // unread target is not "at HEAD".
      tagObjects: {for (final t in tags) t: testTagObject},
      tagTargets: {for (final t in tags) t: tagTarget ?? testHead},
      signingConfigured: true,
      originUrl: 'danReynolds/keybay',
    );

MemorySourceTree tree({
  String coreVersion = '0.2.0',
  String changelog = '## 0.2.0\n',
}) =>
    MemorySourceTree({
      'packages/keybay/pubspec.yaml': 'name: keybay\n'
          'version: $coreVersion\n'
          'repository: https://github.com/danReynolds/keybay\n',
      'packages/keybay/CHANGELOG.md': changelog,
    }, description: '/repo/keybay');

const config = '''
schema = 2

[release.core]
path = "packages/keybay"
publish = ["git-tag", "pub.dev"]
''';

Future<String> statusOf({
  required MemorySourceTree source,
  required GitState state,
  required RegistryReader registry,
}) async =>
    (await statusRun(source: source, state: state, registry: registry)).text;

Future<({String text, Map<String, Object?> report})> statusRun({
  required MemorySourceTree source,
  required GitState state,
  GitState? repositoryState,
  Diagnostic? sourceWarning,
  required RegistryReader registry,
  String withConfig = config,
  Tools? tools,
  String? repository,
  Inspector Function(GitState git, Resolution resolution)? inspectorBuilder,
  ReleaseStage Function(ResolvedUnit unit)? stageFor,
  HostCapabilities? capabilities,
  bool isTerminal = false,
  bool useColor = false,
  int? terminalWidth,
  void Function(StringBuffer buffer)? onOutputReady,
}) async {
  final buffer = StringBuffer();
  onOutputReady?.call(buffer);
  final diagnostics = Diagnostics();
  final parsed = ReleaseConfig.parse(withConfig, 'release.toml', diagnostics)!;
  final resolution = Resolution.resolve(parsed, source, diagnostics);
  expect(resolution, isNotNull, reason: diagnostics.found.join('\n'));

  final output = Output(
    sink: buffer.write,
    isTerminal: isTerminal,
    useColor: useColor,
    terminalWidth: terminalWidth ?? (isTerminal ? 500 : null),
  );
  final selectedInspector = inspectorBuilder?.call(state, resolution!) ??
      Inspector(
        registry: registry,
        // The fake serves both read contracts; production wires PubDevTarget
        // here explicitly.
        pubDev: registry as PublicationInspector,
        git: state,
        tools: tools ?? OriginAgreeing(state.tags, state.head),
        repository: repository,
        stageFor: stageFor,
      );
  final code = await StatusCommand(
    resolution: resolution!,
    tree: source,
    git: state,
    repositoryGit: repositoryState,
    sourceWarning: sourceWarning,
    // Origin agrees with local unless a test says otherwise; without a
    // repository the forge still reports as unread, which is what rk says
    // when it has not been given a way to look.
    inspector: selectedInspector,
    stageFor: stageFor,
    output: output,
    capabilities: capabilities ??
        HostCapabilities(
          hostPlatform: 'macos-arm64',
          containerRuntime: null,
          hasNativeAssets: false,
        ),
  ).run();
  return (
    text: buffer.toString(),
    report:
        jsonDecode(output.report.encode(exit: code)) as Map<String, Object?>,
  );
}

Future<void> _waitForStatusText(
  StringBuffer buffer,
  bool Function(String text) matches,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (matches(buffer.toString())) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('status output did not reach the expected transient state:\n$buffer');
}

String _afterLastTransientErase(String text) {
  const erase = '\x1b[2K';
  final last = text.lastIndexOf(erase);
  return last < 0 ? text : text.substring(last + erase.length);
}

/// The target's own row, which is above `Issues` — where the same label
/// appears again inside a remedy.
String _targetLine(String text, String label) {
  final issues = text.indexOf('\nIssues');
  final body = issues < 0 ? text : text.substring(0, issues);
  return body.split('\n').firstWhere((line) => line.contains(label));
}

void main() {
  statusTargetContract();
  statusReviewRegressions();

  test('always shows targets when local matches live', () async {
    final text = await statusOf(
      source: tree(),
      state: git(tags: ['v0.2.0']),
      registry: FakeRegistry({
        'keybay': ['0.1.0', '0.2.0']
      }),
    );
    expect(text, matches(RegExp(r'pub\.dev\s+keybay')));
    expect(text, matches(RegExp(r'^\s+Published$', multiLine: true)));
    expect(text, isNot(contains('prevent')));
    expect(text, isNot(contains('rk release')));
  });

  test('post-release commits ask for the next version, not a moved tag',
      () async {
    const releasedHead = 'dddddddddddddddddddddddddddddddddddddddd';
    final run = await statusRun(
      source: tree(),
      state: git(
        tags: const ['v0.2.0'],
        tagTarget: releasedHead,
      ),
      registry: FakeRegistry({
        'keybay': ['0.2.0']
      }),
      tools: const ReleasedTagOrigin(
        tag: 'v0.2.0',
        releasedHead: releasedHead,
      ),
    );

    expect(
      run.text,
      contains('version already released; current source differs'),
    );
    expect(run.text, contains('released from ddddddd'));
    expect(
        run.text,
        contains('current source still declares released '
            'version 0.2.0'));
    expect(run.text, contains('bump the version and changelog'));
    expect(run.text, contains('Do not move v0.2.0'));
    expect(run.text, isNot(contains('Not staged')));
    expect(_targetLine(run.text, 'Git tag').trimLeft(), isNot(startsWith('✗')));

    final problems = (run.report['problems'] as List).cast<Map>();
    expect(problems.map((problem) => problem['code']), ['RK-MONO-004']);
    expect(problems.single.containsKey('target'), isFalse);
    final targets =
        ((run.report['units'] as List).single as Map)['targets'] as List;
    final tag = targets.singleWhere(
      (target) => (target as Map)['kind'] == 'gitTag',
    ) as Map;
    expect(tag['verdict'], 'exact');
  });

  test('a pub-only tag does not invent a public manifest file', () async {
    final run = await statusRun(
      source: tree(),
      state: git(),
      registry: FakeRegistry(const {}),
    );
    final unit = (run.report['units'] as List).single as Map;
    final targets = (unit['targets'] as List).cast<Map>();
    final tag = targets.singleWhere((target) => target['kind'] == 'gitTag');

    expect(tag['artifacts'], isEmpty);
    expect(run.text, isNot(contains(ReleaseAssets.manifest)));
  });

  test('non-Git status separates destination truth from source comparison',
      () async {
    final run = await statusRun(
      withConfig: '''
schema = 2

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]
''',
      source: tree(),
      state: GitState.unbound('/repo'),
      registry: FakeRegistry({
        'keybay': ['0.2.0']
      }),
    );

    final repository = run.report['repository'] as Map;
    expect(repository['source_binding'], 'unbound');
    expect(repository['source_comparison'], 'unavailable');
    expect(repository.containsKey('head'), isFalse);
    final unit = (run.report['units'] as List).single as Map;
    final target = (unit['targets'] as List).single as Map;
    expect(target['verdict'], 'exact');
    expect(target['source_binding'], 'unbound');
    expect(target['source_comparison'], 'unavailable');
    expect(run.text, contains('unbound · comparison unavailable'));
  });

  test('names staging as the next command when local is ahead', () async {
    final run = await statusRun(
      source: tree(),
      state: git(tags: ['v0.2.0']),
      registry: FakeRegistry({
        'keybay': ['0.1.0']
      }),
    );
    final text = run.text;
    expect(text, isNot(contains('prevent')));
    expect(text, contains('0.1.0 › 0.2.0'));
    expect(text, isNot(contains('ready')));
    expect(
      run.report['next'],
      ['rk release core --stage'],
      reason: 'an unstaged unit is staged first; a mutation collapsing this '
          'to the publish form survived the whole suite',
    );
  });

  test('a binary-only unit names its local output and direct next command',
      () async {
    const localBinaryConfig = '''
schema = 2

[release.cli]
path = "packages/keybay"
binary_platforms = ["linux-x64"]
''';
    final binaryTree = MemorySourceTree({
      'packages/keybay/pubspec.yaml': '''
name: keybay
version: 0.2.0
executables:
  keybay: keybay
''',
      'packages/keybay/CHANGELOG.md': '## 0.2.0\n',
    }, description: '/repo/keybay');

    final run = await statusRun(
      withConfig: localBinaryConfig,
      source: binaryTree,
      state: git(),
      registry: FakeRegistry(const {}),
      capabilities: HostCapabilities(
        hostPlatform: 'linux-x64',
        containerRuntime: null,
        hasNativeAssets: false,
      ),
    );

    expect(run.text, contains('Not staged'));
    expect(run.text, contains('Local binaries'));
    expect(
      run.text,
      contains('producers/keybay/archives/keybay-0.2.0-linux-x64.tar.gz'),
    );
    expect(run.report['next'], ['rk release cli']);
  });

  test('an exact registry does not hide an unstaged local binary', () async {
    const config = '''
schema = 2

[release.cli]
path = "packages/keybay"
publish = ["pub.dev"]
binary_platforms = ["linux-x64"]
''';
    final binaryTree = MemorySourceTree({
      'packages/keybay/pubspec.yaml': '''
name: keybay
version: 0.2.0
executables:
  keybay: keybay
''',
      'packages/keybay/CHANGELOG.md': '## 0.2.0\n',
    }, description: '/repo/keybay');

    final run = await statusRun(
      withConfig: config,
      source: binaryTree,
      state: git(),
      registry: FakeRegistry({
        'keybay': ['0.2.0']
      }),
      capabilities: HostCapabilities(
        hostPlatform: 'linux-x64',
        containerRuntime: null,
        hasNativeAssets: false,
      ),
    );

    expect(run.text, contains('Published'));
    expect(run.text, contains('Not staged'));
    expect(run.text, contains('Local binaries'));
    expect(
      run.text,
      contains('producers/keybay/archives/keybay-0.2.0-linux-x64.tar.gz'),
    );
    expect(run.report['next'], ['rk release cli --stage']);
  });

  test('the Git lane reports the latest older tag, not an invented absence',
      () async {
    final text = await statusOf(
      source: tree(),
      state: git(tags: const ['v0.1.0']),
      registry: FakeRegistry({
        'keybay': ['0.1.0']
      }),
    );
    expect(text, contains('0.1.0 › 0.2.0'));
    expect(
      text.split('\n').first,
      isNot(contains('v0.2.0')),
      reason: 'the tag repeats the version under the default pattern',
    );
    expect(
      text,
      matches(RegExp(r'core 0\.1\.0 › 0\.2\.0')),
      reason: 'every lane agrees the current release is 0.1.0, so the '
          'movement is stated once, above them',
    );
    expect(
      text,
      isNot(contains('not published: origin has no matching release tag')),
      reason: 'how rk established absence is diagnosis, not the report',
    );
  });

  test('blocks on a missing changelog entry, naming the heading to add',
      () async {
    final text = await statusOf(
      source: tree(changelog: '## 0.1.0\n'),
      state: git(tags: ['v0.2.0']),
      registry: FakeRegistry({
        'keybay': ['0.1.0']
      }),
    );
    expect(text, contains('no entry for 0.2.0'));
    expect(text, contains('## 0.2.0'));
    expect(text, isNot(contains('rk release')));
  });

  test('blocks on an unclean worktree, naming a file', () async {
    final text = await statusOf(
      source: tree(),
      state: git(clean: false),
      registry: FakeRegistry({
        'keybay': ['0.1.0']
      }),
    );
    expect(text, contains('uncommitted'));
    expect(text, contains('lib/src/args.dart'));
  });

  test('blocks on a commit no remote has, with the branch and the fix',
      () async {
    final text = await statusOf(
      source: tree(),
      state: git(pushed: false),
      registry: FakeRegistry({
        'keybay': ['0.1.0']
      }),
    );
    expect(text, contains('no upstream on origin'));
    expect(text, contains('git push'));
  });

  test('an unpushed head names how far ahead it is', () async {
    final state = GitState(
      root: '/repo',
      head: '9f2c1ab',
      branch: 'main',
      isClean: true,
      uncommitted: const [],
      headIsPushed: false,
      aheadOfUpstream: 3,
      tags: const [],
      signingConfigured: true,
      originUrl: 'example/keybay',
    );
    final problem = state.unpushedProblem()!;
    expect(problem.message, contains('main (9f2c1ab)'));
    expect(problem.message, contains('ahead of origin/main by 3 commits'));
  });

  test('no remote at all is its own instruction, not "push"', () async {
    final state = GitState(
      root: '/repo',
      head: '9f2c1ab',
      branch: 'main',
      isClean: true,
      uncommitted: const [],
      headIsPushed: false,
      hasRemote: false,
      tags: const [],
      signingConfigured: true,
      originUrl: null,
    );
    final problem = state.unpushedProblem()!;
    expect(problem.message, contains('has no remote'));
    expect(problem.remedy, contains('git remote add origin'));
  });

  test('blocks when a later tag already exists', () async {
    final text = await statusOf(
      source: tree(),
      state: git(tags: const ['v0.3.0']),
      registry: FakeRegistry({
        'keybay': ['0.1.0']
      }),
    );
    expect(text, contains('ahead of 0.2.0'));
  });

  test('an unreachable registry blocks rather than reading as absent',
      () async {
    final text = await statusOf(
      source: tree(),
      state: git(),
      registry: FakeRegistry(const {}, unreachable: true),
    );
    expect(text, contains('could not be reached'));
    expect(
      text,
      isNot(contains('rk release')),
      reason: 'not knowing is not permission to publish',
    );
  });

  _reviewFixes();
  _phase23Fixes();

  test('a package that has never been published is safe to stage', () async {
    final text = await statusOf(
      source: tree(),
      state: git(),
      registry: FakeRegistry(const {}),
    );
    expect(text, contains('Not published'));
    expect(text, isNot(contains('prevent')));
  });
}

void statusTargetContract() {
  const binaryConfig = '''
schema = 2

[release.cli]
path = "packages/keybay"
publish = ["git-tag", "pub.dev", "github-release"]
binary_platforms = ["macos-arm64"]
''';
  final binaryTree = MemorySourceTree({
    'packages/keybay/pubspec.yaml': '''
name: keybay
version: 0.2.0
executables:
  keybay: keybay
''',
    'packages/keybay/CHANGELOG.md': '## 0.2.0\n',
  }, description: '/repo/keybay');

  test('all target completion orders render in configured order', () async {
    const tag = StepKind.tag;
    const pub = StepKind.publishRegistry;
    const github = StepKind.publishRelease;
    const completionOrders = <List<StepKind>>[
      [tag, pub, github],
      [tag, github, pub],
      [pub, tag, github],
      [pub, github, tag],
      [github, tag, pub],
      [github, pub, tag],
    ];

    for (final completionOrder in completionOrders) {
      late CoordinatedInspector controlled;
      final running = statusRun(
        withConfig: binaryConfig,
        source: binaryTree,
        state: git(),
        registry: FakeRegistry(const {}),
        inspectorBuilder: (git, _) => controlled = CoordinatedInspector(
          registry: FakeRegistry(const {}),
          git: git,
          expected: 3,
        ),
      );

      await controlled.allStarted.future.timeout(const Duration(seconds: 1));
      expect(controlled.maximumActive, 3, reason: '$completionOrder');
      for (final target in completionOrder) {
        controlled.finish(target);
      }
      final run = await running;

      final tagRow = run.text.indexOf('Git tag');
      final pubRow = run.text.indexOf('pub.dev ');
      final githubRow = run.text.indexOf('GitHub Release ');
      expect(tagRow, greaterThanOrEqualTo(0), reason: '$completionOrder');
      expect(pubRow, greaterThan(tagRow), reason: '$completionOrder');
      expect(githubRow, greaterThan(pubRow), reason: '$completionOrder');
    }
  });

  test(
      'delayed parallel reads show every target, then settle to the pipe '
      'report', () async {
    late CoordinatedInspector terminalInspector;
    late StringBuffer terminalBuffer;
    final terminalFuture = statusRun(
      withConfig: binaryConfig,
      source: binaryTree,
      state: git(),
      registry: FakeRegistry(const {}),
      isTerminal: true,
      onOutputReady: (buffer) => terminalBuffer = buffer,
      inspectorBuilder: (git, _) => terminalInspector = CoordinatedInspector(
        registry: FakeRegistry(const {}),
        git: git,
        expected: 3,
      ),
    );

    await terminalInspector.allStarted.future
        .timeout(const Duration(seconds: 1));
    await _waitForStatusText(
      terminalBuffer,
      (text) => text.contains('Release targets'),
    );
    final checking = _afterLastTransientErase(terminalBuffer.toString());
    expect(
      checking.split('\n').where((line) => line.isNotEmpty),
      [
        'Release targets',
        matches(RegExp(r'^  . Git tag\s+checking$')),
        matches(RegExp(r'^  . pub\.dev · keybay\s+checking$')),
        matches(RegExp(
          r'^  . GitHub Release · danReynolds/keybay\s+checking$',
        )),
      ],
      reason: 'one fixed list makes the parallel reads visible together',
    );

    terminalInspector.finish(StepKind.tag);
    await _waitForStatusText(
      terminalBuffer,
      (text) =>
          RegExp(r'Git tag\s+checked').hasMatch(_afterLastTransientErase(text)),
    );
    final partlyChecked = _afterLastTransientErase(terminalBuffer.toString());
    expect(partlyChecked, matches(RegExp(r'Git tag\s+checked')));
    expect('checking'.allMatches(partlyChecked), hasLength(2));

    terminalInspector
      ..finish(StepKind.publishRegistry)
      ..finish(StepKind.publishRelease);
    final terminal = await terminalFuture;
    expect(terminal.text, contains('\x1b[1A\r\x1b[2K'));

    late CoordinatedInspector pipeInspector;
    late StringBuffer pipeBuffer;
    final pipeFuture = statusRun(
      withConfig: binaryConfig,
      source: binaryTree,
      state: git(),
      registry: FakeRegistry(const {}),
      onOutputReady: (buffer) => pipeBuffer = buffer,
      inspectorBuilder: (git, _) => pipeInspector = CoordinatedInspector(
        registry: FakeRegistry(const {}),
        git: git,
        expected: 3,
      ),
    );

    await pipeInspector.allStarted.future.timeout(const Duration(seconds: 1));
    expect(
      pipeBuffer.toString(),
      isEmpty,
      reason: 'a pipe waits silently rather than receiving transient output',
    );
    pipeInspector
      ..finish(StepKind.tag)
      ..finish(StepKind.publishRegistry)
      ..finish(StepKind.publishRelease);
    final pipe = await pipeFuture;

    expect(pipe.text, isNot(contains('\x1b')));
    expect(pipe.text, isNot(contains('\r')));
    expect(
      _afterLastTransientErase(terminal.text),
      pipe.text,
      reason: 'the transient list is erased before the same deterministic '
          'target report a pipe receives',
    );
  });

  test('unstaged status uses the austere target vocabulary', () async {
    final text = await statusOf(
      source: tree(),
      state: git(),
      registry: FakeRegistry({
        'keybay': ['0.1.0']
      }),
    );

    expect(text, contains('Git tag'));
    expect(text, matches(RegExp(r'pub\.dev\s+keybay')));
    expect(text, contains('0.1.0 › 0.2.0'));
    expect(text, isNot(contains('prevent')));
    expect(text, isNot(contains('→')));
    expect(
      _targetLine(text, 'pub.dev ').trimLeft(),
      startsWith('pub.dev'),
      reason: 'ordinary absent work has no problem mark',
    );
    for (final discarded in [
      'ready',
      'partial',
      'blocked',
      'nothing to release',
      'build ›',
    ]) {
      expect(text, isNot(contains(discarded)));
    }
  });

  test('the settled target report fits a narrow terminal without truncation',
      () async {
    const width = 36;
    final run = await statusRun(
      withConfig: binaryConfig,
      source: binaryTree,
      state: git(),
      registry: FakeRegistry(const {}),
      isTerminal: true,
      useColor: true,
      terminalWidth: width,
      inspectorBuilder: (git, _) => FixedInspector(
        registry: FakeRegistry(const {}),
        git: git,
        answer: const Inspection.absent(),
      ),
    );

    final visible = run.text
        .replaceAll(RegExp('\x1b\\[[0-9;]*[A-Za-z]'), '')
        .replaceAll('\r', '')
        .split('\n')
        .where((line) => line.isNotEmpty)
        .toList();
    expect(visible.every((line) => line.runes.length <= width), isTrue);
    expect(visible.join('\n'), contains('GitHub Release'));
    expect(visible.join('\n'), contains('artifacts'));
    expect(run.text, isNot(contains('…')),
        reason: 'settled facts wrap; only transient progress may truncate');
  });

  test('Homebrew owns its cask without adding it to GitHub inventory',
      () async {
    final run = await statusRun(
      withConfig: binaryConfig.replaceFirst(
        'publish = ["git-tag", "pub.dev", "github-release"]',
        'publish = ["git-tag", "pub.dev", "github-release", "homebrew"]',
      ),
      source: binaryTree,
      state: git(),
      registry: FakeRegistry(const {}),
      inspectorBuilder: (git, _) => FixedInspector(
        registry: FakeRegistry(const {}),
        git: git,
        answer: const Inspection.absent(),
      ),
    );

    expect(
      run.text,
      isNot(contains('uses release-manifest.json')),
      reason: 'which target owns a shared artifact explains a conflict; it '
          'is not news on the happy path',
    );
    final targets =
        ((run.report['units'] as List).single as Map)['targets'] as List;
    final github = targets.singleWhere(
      (target) => (target as Map)['kind'] == 'githubRelease',
    ) as Map;
    final homebrew = targets.singleWhere(
      (target) => (target as Map)['kind'] == 'homebrew',
    ) as Map;
    final tag = targets.singleWhere(
      (target) => (target as Map)['kind'] == 'gitTag',
    ) as Map;
    expect(
      (github['artifacts'] as List)
          .map((artifact) => (artifact as Map)['name']),
      isNot(contains('keybay.rb')),
    );
    expect(
      (homebrew['artifacts'] as List)
          .map((artifact) => (artifact as Map)['name']),
      contains('keybay.rb'),
    );
    expect(homebrew['uses'], contains('keybay.rb'));
    expect(tag['artifacts'], isEmpty);
    expect(
      tag['uses'],
      'release-manifest.json from GitHub Release',
    );
  });

  test('an aggregate current version is shown only when every target agrees',
      () async {
    final agreed = await statusRun(
      withConfig: binaryConfig,
      source: binaryTree,
      state: git(tags: const ['v0.2.0']),
      registry: FakeRegistry({
        'keybay': ['0.2.0']
      }),
      inspectorBuilder: (git, _) => FixedInspector(
        registry: FakeRegistry({
          'keybay': ['0.2.0']
        }),
        git: git,
        answer: const Inspection.exact(detail: 'published exactly'),
      ),
    );
    expect(
      agreed.text,
      matches(RegExp(r'^\s+Published$', multiLine: true)),
      reason: 'an arrow to where it already is describes no movement',
    );

    final split = await statusRun(
      withConfig: binaryConfig,
      source: binaryTree,
      state: git(),
      registry: FakeRegistry({
        'keybay': ['0.1.0']
      }),
      inspectorBuilder: (git, _) => FixedInspector(
        registry: FakeRegistry({
          'keybay': ['0.1.0']
        }),
        git: git,
        answer: const Inspection.absent(),
      ),
    );
    expect(split.text, contains('0.1.0 › 0.2.0'));
    expect(
      split.text,
      isNot(matches(RegExp(r'^\s+Published$', multiLine: true))),
      reason: 'targets disagree, so the header invents no single answer',
    );
  });

  test('cheap host facts mark artifacts that cannot be produced here',
      () async {
    final run = await statusRun(
      withConfig: binaryConfig,
      source: binaryTree,
      state: git(),
      registry: FakeRegistry(const {}),
      capabilities: HostCapabilities(
        hostPlatform: 'linux-x64',
        containerRuntime: null,
        hasNativeAssets: false,
      ),
      inspectorBuilder: (git, _) => FixedInspector(
        registry: FakeRegistry(const {}),
        git: git,
        answer: const Inspection.absent(),
      ),
    );

    expect(run.text, contains('this machine cannot produce every platform'));
    expect(run.text, contains('Fix: stage this unit on a host'));
    expect(
      run.text,
      matches(RegExp(
        r'✗\s+keybay-0\.2\.0-macos-arm64\.tar\.gz\s+macos-arm64 '
        r'cannot be produced here',
      )),
    );
    final targets =
        ((run.report['units'] as List).single as Map)['targets'] as List;
    final github = targets.singleWhere(
      (target) => (target as Map)['kind'] == 'githubRelease',
    ) as Map;
    final archive = (github['artifacts'] as List).singleWhere(
      (artifact) =>
          (artifact as Map)['name'] == 'keybay-0.2.0-macos-arm64.tar.gz',
    ) as Map;
    expect(archive['status'], 'invalid');
    expect(archive['problem'], contains('cannot be produced here'));
  });

  test('an unread public history is an issue even when the candidate is absent',
      () async {
    final run = await statusRun(
      withConfig: binaryConfig,
      source: binaryTree,
      state: git(),
      registry: FakeRegistry(const {}),
      inspectorBuilder: (git, _) => FixedInspector(
        registry: FakeRegistry(const {}),
        git: git,
        answer: const Inspection.absent(),
        latest: const Inspection.unknown('provider history was unreadable'),
      ),
    );

    expect(
      run.text,
      contains('current public version could not be established'),
      reason: 'an unread history is an issue, not a row condition — the '
          'candidate coordinate really is absent',
    );
    expect(run.text, contains('provider history was unreadable'));
    expect(run.text, contains('prevent'));

    final targets =
        ((run.report['units'] as List).single as Map)['targets'] as List;
    final github = targets.singleWhere(
      (target) => (target as Map)['kind'] == 'githubRelease',
    ) as Map;
    expect(
      _targetLine(run.text, 'GitHub Release ').trimLeft(),
      startsWith('✗'),
      reason: 'the target-linked issue, not the absent verdict, marks the row',
    );
    expect(github['verdict'], 'absent');
    expect(
      (run.report['problems'] as List).cast<Map>().any(
            (problem) => problem['target'] == github['id'],
          ),
      isTrue,
      reason: 'JSON keeps the public verdict and links the separate problem',
    );

    final archiveName = 'keybay-0.2.0-macos-arm64.tar.gz';
    final archive = (github['artifacts'] as List).singleWhere(
      (artifact) => (artifact as Map)['name'] == archiveName,
    ) as Map;
    expect(archive['status'], 'notStaged');
    expect(
      run.text
          .split('\n')
          .firstWhere((line) => line.contains('artifacts'))
          .trimLeft(),
      startsWith('GitHub Release'),
      reason: 'a target problem does not turn an unstaged artifact into one',
    );
  });

  test('a public lane ahead of the target is a monotonicity issue', () async {
    final run = await statusRun(
      source: tree(),
      state: git(),
      registry: FakeRegistry(const {}),
      inspectorBuilder: (git, _) => FixedInspector(
        registry: FakeRegistry(const {}),
        git: git,
        answer: const Inspection.absent(),
        latest: const Inspection.exact(
          detail: 'latest is 0.3.0',
          evidence: {'version': '0.3.0'},
        ),
      ),
    );

    expect(
      run.text,
      contains('0.2.0 · behind 0.3.0'),
      reason: '› means becomes, so an arrow here claimed rk would turn the '
          'newer published version into the older one',
    );
    expect(run.text, isNot(contains('0.3.0 › 0.2.0')));
    expect(run.text, contains('ahead of the target 0.2.0'));
    expect(run.text, isNot(contains('RK-MONO-003')));
    expect(
      (run.report['problems'] as List)
          .cast<Map>()
          .map((problem) => problem['code']),
      contains('RK-MONO-003'),
    );
    expect(
        run.text, contains('Fix: a release moves forward — bump past 0.3.0'));
    expect(run.text, isNot(contains('rk release core --stage')));

    final targets =
        ((run.report['units'] as List).single as Map)['targets'] as List;
    final pub = targets.singleWhere(
      (target) => (target as Map)['kind'] == 'pubDev',
    ) as Map;
    expect(_targetLine(run.text, 'pub.dev ').trimLeft(), startsWith('✗'));
    expect(pub['verdict'], 'absent');
    expect(
      (run.report['problems'] as List).cast<Map>().any(
            (problem) => problem['target'] == pub['id'],
          ),
      isTrue,
    );
  });

  test('a dirty unbound snapshot is a warning, not a release issue', () async {
    final repository = git(clean: false);
    final run = await statusRun(
      source: tree(),
      state: GitState.unbound(repository.root),
      repositoryState: repository,
      sourceWarning: repository.uncommittedSnapshotWarning(),
      withConfig: '''
schema = 2

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]
''',
      registry: FakeRegistry({
        'keybay': ['0.1.0']
      }),
    );

    expect(run.text, contains('Warnings'));
    expect(run.text, contains('will be captured in the source snapshot'));
    expect(run.text, isNot(contains('issue prevents release')));
    expect(run.report['problems'], isEmpty);
    expect((run.report['warnings'] as List).single['code'], 'RK-GIT-001');
    expect((run.report['repository'] as Map)['source_binding'], 'unbound');
    expect(run.report['next'], ['rk release core']);
  });

  for (final code in const ['RK-GIT-004', 'RK-GIT-005', 'RK-GIT-007']) {
    test('$code links to and marks the Git tag lane', () async {
      final registry = FakeRegistry(const {});
      final run = await statusRun(
        source: tree(),
        state: git(),
        registry: registry,
        inspectorBuilder: (git, _) => GuardInspector(
          registry: registry,
          git: git,
          code: code,
        ),
      );

      final targets =
          ((run.report['units'] as List).single as Map)['targets'] as List;
      final tag = targets.singleWhere(
        (target) => (target as Map)['kind'] == 'gitTag',
      ) as Map;
      final problem = (run.report['problems'] as List)
          .cast<Map>()
          .singleWhere((problem) => problem['code'] == code);

      expect(tag['verdict'], 'absent');
      expect(problem['target'], tag['id']);
      expect(_targetLine(run.text, 'Git tag').trimLeft(), startsWith('✗'));
    });
  }

  test('an exact stage lists exact filenames and is good to release', () async {
    final root = Directory.systemTemp.createTempSync('rk-status-stage-');
    addTearDown(() => root.deleteSync(recursive: true));
    final made = await _completedBinaryStage(
      root: root,
      config: binaryConfig,
      source: binaryTree,
    );
    ReleaseStage stageFor(ResolvedUnit unit) => made;

    final run = await statusRun(
      withConfig: binaryConfig,
      source: binaryTree,
      state: git(),
      registry: FakeRegistry(const {}),
      stageFor: stageFor,
      inspectorBuilder: (git, _) => FixedInspector(
        registry: FakeRegistry(const {}),
        git: git,
        answer: const Inspection.absent(),
      ),
    );

    expect(run.text, isNot(contains('prevent')));
    expect(run.report['next'], ['rk release cli']);
    // The report collapses a set that agrees; the document keeps every
    // name, which is where a caller reading filenames should be reading
    // them anyway.
    final expected = ReleaseAssets.expectedForUnit(made.unit);
    expect(
      run.text,
      matches(RegExp('${expected.length} artifacts')),
    );
    final staged = (((run.report['units'] as List).single as Map)['targets']
            as List)
        .cast<Map>()
        .singleWhere(
            (target) => target['kind'] == 'githubRelease')['artifacts'] as List;
    expect(
      staged.cast<Map>().map((artifact) => artifact['name']).toSet(),
      expected,
    );
    expect(
      staged.cast<Map>().map((artifact) => artifact['status']).toSet(),
      {'staged'},
    );
    final units = run.report['units'] as List;
    final targets = (units.single as Map)['targets'] as List;
    final github = targets.singleWhere(
      (target) => (target as Map)['kind'] == 'githubRelease',
    ) as Map;
    expect(github['current_known'], isTrue);
    expect(github['target_version'], '0.2.0');
    expect(github['verdict'], 'absent');
    expect(
      (github['artifacts'] as List)
          .map((artifact) => (artifact as Map)['name']),
      contains('keybay-0.2.0-macos-arm64.tar.gz'),
    );
    expect(
      (github['artifacts'] as List)
          .map((artifact) => (artifact as Map)['status'])
          .toSet(),
      {'staged'},
    );
  });

  test('an exact stage makes a partial public release safely resumable',
      () async {
    final root = Directory.systemTemp.createTempSync('rk-status-resume-');
    addTearDown(() => root.deleteSync(recursive: true));
    final made = await _completedBinaryStage(
      root: root,
      config: binaryConfig,
      source: binaryTree,
    );
    ReleaseStage stageFor(ResolvedUnit unit) => made;
    final registry = FakeRegistry({
      'keybay': ['0.2.0']
    });

    final run = await statusRun(
      withConfig: binaryConfig,
      source: binaryTree,
      state: git(tags: const ['v0.2.0']),
      registry: registry,
      stageFor: stageFor,
      inspectorBuilder: (git, _) => FixedInspector(
        registry: registry,
        git: git,
        answer: const Inspection.absent(),
        answers: const {
          StepKind.tag: Inspection.exact(
            detail: 'the release tag is already public',
          ),
          StepKind.publishRegistry: Inspection.exact(
            detail: 'published exactly',
          ),
        },
      ),
    );

    expect(
      run.text,
      matches(RegExp(r'Git tag\s+v0\.2\.0')),
    );
    expect(
      run.text,
      matches(RegExp(r'pub\.dev\s+keybay')),
    );
    expect(
      run.text,
      matches(RegExp(
        r'GitHub Release\s+danReynolds/keybay',
      )),
    );
    expect(run.report['next'], ['rk release cli']);
    expect(
      run.text,
      isNot(contains('→')),
      reason: 'the next command is data for an agent, not a prompt for the '
          'operator who just chose it',
    );
    expect(run.text, isNot(contains('Issues')));
    expect(run.text, isNot(contains('issue prevents release')));

    expect(run.report['problems'], isEmpty);
    expect(run.report['next'], ['rk release cli']);
    final targets =
        ((run.report['units'] as List).single as Map)['targets'] as List;
    expect(
      [
        for (final target in targets)
          (
            (target as Map)['kind'],
            target['verdict'],
          ),
      ],
      [
        ('gitTag', 'exact'),
        ('pubDev', 'exact'),
        ('githubRelease', 'absent'),
      ],
    );
    final github = targets.singleWhere(
      (target) => (target as Map)['kind'] == 'githubRelease',
    ) as Map;
    expect(
      (github['artifacts'] as List)
          .map((artifact) => (artifact as Map)['status'])
          .toSet(),
      {'staged'},
    );
  });

  test('a reusable stage does not require the publishing host to reproduce it',
      () async {
    final root = Directory.systemTemp.createTempSync('rk-status-stage-host-');
    addTearDown(() => root.deleteSync(recursive: true));
    final made = await _completedBinaryStage(
      root: root,
      config: binaryConfig,
      source: binaryTree,
    );
    ReleaseStage stageFor(ResolvedUnit unit) => made;

    final run = await statusRun(
      withConfig: binaryConfig,
      source: binaryTree,
      state: git(),
      registry: FakeRegistry(const {}),
      stageFor: stageFor,
      capabilities: HostCapabilities(
        hostPlatform: 'linux-x64',
        containerRuntime: null,
        hasNativeAssets: false,
      ),
      inspectorBuilder: (git, _) => FixedInspector(
        registry: FakeRegistry(const {}),
        git: git,
        answer: const Inspection.absent(),
      ),
    );

    expect(run.text, isNot(contains('prevent')));
    expect(run.text, isNot(contains('RK-HOST-001')));
    expect(run.text, isNot(contains('cannot produce every platform')));
  });

  test('a changed staged artifact is marked and explained once', () async {
    final root = Directory.systemTemp.createTempSync('rk-status-tamper-');
    addTearDown(() => root.deleteSync(recursive: true));
    final made = await _completedBinaryStage(
      root: root,
      config: binaryConfig,
      source: binaryTree,
    );
    ReleaseStage stageFor(ResolvedUnit unit) => made;
    // The stage above is created before status inspects it.
    final stage = made;
    final archive = ReleaseAssets.archiveName(
      'keybay',
      '0.2.0',
      'macos-arm64',
    );
    File(stage.directory.resolve(archive)).writeAsStringSync('changed');

    final run = await statusRun(
      withConfig: binaryConfig,
      source: binaryTree,
      state: git(),
      registry: FakeRegistry(const {}),
      stageFor: stageFor,
      inspectorBuilder: (git, _) => FixedInspector(
        registry: FakeRegistry(const {}),
        git: git,
        answer: const Inspection.absent(),
      ),
    );

    expect(
      run.text,
      matches(RegExp('$archive\\s+artifact .* differs from the receipt')),
    );
    expect(run.text, contains('Issues'));
    expect(run.text, contains('Fix:'));
    expect(run.text, contains('1 issue prevents release'));
    expect(run.text, isNot(contains('RK-STAGE-002')));
    expect(
      (run.report['problems'] as List)
          .cast<Map>()
          .where((problem) => problem['code'] == 'RK-STAGE-002'),
      hasLength(1),
    );
  });

  test('a global completed-stage problem invalidates every artifact row',
      () async {
    final root = Directory.systemTemp.createTempSync('rk-status-stage-global-');
    addTearDown(() => root.deleteSync(recursive: true));
    final complete = await _completedBinaryStage(
      root: root,
      config: binaryConfig,
      source: binaryTree,
    );
    final made = ReleaseStage(
      unit: complete.unit,
      source: binaryTree,
      directory: complete.directory,
      compiler: DartCompilerIdentity.recorded(
        executable: '/status-test/dart',
        version: 'Dart SDK version: status test compiler',
        sha256: 'c' * 64,
      ),
    );
    ReleaseStage stageFor(ResolvedUnit unit) => made;

    final run = await statusRun(
      withConfig: binaryConfig,
      source: binaryTree,
      state: git(),
      registry: FakeRegistry(const {}),
      stageFor: stageFor,
      inspectorBuilder: (git, _) => FixedInspector(
        registry: FakeRegistry(const {}),
        git: git,
        answer: const Inspection.absent(),
      ),
    );

    final targets =
        ((run.report['units'] as List).single as Map)['targets'] as List;
    final artifacts = [
      for (final target in targets)
        ...((target as Map)['artifacts'] as List).cast<Map>(),
    ];
    expect(artifacts, isNotEmpty);
    expect(artifacts.map((artifact) => artifact['status']).toSet(), {
      'invalid',
    });
    expect(
      artifacts.map((artifact) => artifact['problem']),
      everyElement(
        allOf(contains('stage does not validate'), contains('stage.json')),
      ),
    );
    expect(run.text, isNot(matches(RegExp(r'^\s+Staged$', multiLine: true))));
    expect(run.text, contains('does not record its Dart compiler'));
    expect(run.text, isNot(contains('RK-STAGE-002')));
    expect(
      (run.report['problems'] as List)
          .cast<Map>()
          .map((problem) => problem['code']),
      contains('RK-STAGE-002'),
    );
  });

  test('a partial binary release without its exact stage is an issue',
      () async {
    final run = await statusRun(
      withConfig: binaryConfig,
      source: binaryTree,
      state: git(),
      registry: FakeRegistry({
        'keybay': ['0.1.0']
      }),
      inspectorBuilder: (git, _) => FixedInspector(
        registry: FakeRegistry({
          'keybay': ['0.1.0']
        }),
        git: git,
        answer: const Inspection.absent(),
        answers: const {
          StepKind.tag: Inspection.exact(
            detail: 'the release tag is already public',
          ),
        },
      ),
    );

    expect(
      run.text,
      contains('the partial binary release needs its exact stage'),
    );
    expect(run.text, isNot(contains('RK-STAGE-005')));
    expect(
      run.text,
      contains('Signed or notarized bytes cannot be recreated'),
    );
    expect(run.text, contains('prevent'));
    expect(run.report['next'], isEmpty);
    expect(
      (run.report['problems'] as List)
          .map((problem) => (problem as Map)['code']),
      ['RK-STAGE-005'],
    );
    final targets =
        ((run.report['units'] as List).single as Map)['targets'] as List;
    final artifacts = [
      for (final target in targets)
        ...((target as Map)['artifacts'] as List).cast<Map>(),
    ];
    expect(artifacts, isNotEmpty);
    expect(
      artifacts.map((artifact) => artifact['status']).toSet(),
      {'invalid'},
    );
    expect(
      artifacts.map((artifact) => artifact['problem']),
      everyElement(contains('exact stage')),
    );
    for (final artifact in artifacts) {
      expect(
        run.text
            .split('\n')
            .firstWhere(
              (line) =>
                  line.contains(artifact['name'] as String) &&
                  line.contains('exact stage'),
            )
            .trimLeft(),
        startsWith('✗'),
      );
    }
  });
}

/// Completes the single unit of [config] so a synchronous `stageFor` callback
/// can hand back an already-built stage.
Future<ReleaseStage> _completedBinaryStage({
  required Directory root,
  required String config,
  required MemorySourceTree source,
}) async {
  final diagnostics = Diagnostics();
  final parsed = ReleaseConfig.parse(config, 'release.toml', diagnostics)!;
  final resolution = Resolution.resolve(parsed, source, diagnostics)!;
  return _completedStage(
    root: root,
    unit: resolution.units.single,
    source: source,
  );
}

Future<ReleaseStage> _completedStage({
  required Directory root,
  required ResolvedUnit unit,
  required SourceTree source,
}) async {
  final identity = StageIdentity.forPlan(
    headCommit: testHead,
    headTree: testTree,
    resolvedPlan: {'unit': unit.name, 'test': 'status'},
  );
  final stage = ReleaseStage(
    unit: unit,
    source: source,
    directory: StageDirectory(
      repositoryRoot: root.path,
      identity: identity,
    ),
  );
  final public = ReleaseAssets.expectedForUnit(unit).toSet()
    ..remove(ReleaseAssets.manifest);
  final sourceArtifacts = await stage.materializeSource();
  final sourceStep = StageStep(
    name: 'source-snapshot',
    inputs: [
      StageInput.commit(identity),
      StageInput.tree(identity),
      StageInput.plan(identity),
    ],
    outputs: sourceArtifacts,
    evidence: {'commit': identity.headCommit, 'tree': identity.headTree},
  );
  final steps = <StageStep>[sourceStep];
  final project = unit.binaryProject!;
  final executable = project.executable!;
  final archives = <StageArtifact>[];
  for (final platform in project.binaryPlatforms) {
    final binaryName = '$platform/$executable';
    stage.directory.writeBytesAtomically(
      binaryName,
      utf8.encode('binary:$platform'),
    );
    final binary = StageArtifact.capture(
      stage: stage.directory,
      path: binaryName,
      type: 'executable',
    );
    steps.add(StageStep(
      name: '${platform.startsWith('macos-') ? 'sign' : 'build'}:$platform',
      inputs: [StageInput.step(sourceStep)],
      outputs: [binary],
      evidence: {
        'smoke': {'status': 'passed'},
        if (platform.startsWith('macos-'))
          'signature': {
            'certificate': 'Developer ID Application: Test (TEAM123456)',
            'certificate_sha256': 'c' * 64,
            'first_identity': false,
            'published_requirement': 'designated => identifier '
                '"io.example.$executable" and certificate '
                'leaf[subject.OU] = "TEAM123456"',
            'code_id': 'io.example.$executable',
            'unsigned_sha256': 'd' * 64,
            'signed_sha256': binary.sha256,
          },
      },
    ));
    if (platform.startsWith('macos-')) {
      final zip = '$platform/$executable.zip';
      final result = ReleaseAssets.notaryResultName(
        executable,
        project.version.canonical,
        platform,
      );
      final log = ReleaseAssets.notaryLogName(
        executable,
        project.version.canonical,
        platform,
      );
      stage.directory.writeBytesAtomically(zip, utf8.encode('zip:$platform'));
      stage.directory.writeBytesAtomically(
        result,
        utf8.encode('{"id":"status-test","status":"Accepted"}'),
      );
      stage.directory.writeBytesAtomically(log, utf8.encode('{"issues":[]}'));
      final resultArtifact = StageArtifact.capture(
        stage: stage.directory,
        path: result,
        type: 'notary',
      );
      final logArtifact = StageArtifact.capture(
        stage: stage.directory,
        path: log,
        type: 'notary',
      );
      steps.add(StageStep(
        name: 'notarize:$platform',
        inputs: [StageInput.artifact(binary)],
        outputs: [
          StageArtifact.capture(
            stage: stage.directory,
            path: zip,
            type: 'notary-input',
          ),
          resultArtifact,
          logArtifact,
        ],
        evidence: {
          'notary': {
            'status': 'Accepted',
            'submission_id': 'status-test',
            'result_sha256': resultArtifact.sha256,
            'log_sha256': logArtifact.sha256,
          },
        },
      ));
    }
    final archiveName = ReleaseAssets.archiveName(
      executable,
      project.version.canonical,
      platform,
    );
    final bytes = ArchiveBuilder.gzip(ArchiveBuilder.tar([
      ArchiveEntry(
        name: executable,
        bytes: utf8.encode('binary:$platform'),
        executable: true,
      ),
    ]));
    stage.directory.writeBytesAtomically(archiveName, bytes);
    final archive = StageArtifact.capture(
      stage: stage.directory,
      path: archiveName,
      type: 'archive',
    );
    archives.add(archive);
    steps.add(StageStep(
      name: 'archive:$platform',
      inputs: [StageInput.artifact(binary)],
      outputs: [archive],
      evidence: {
        'inventory': StageArchiveInventory.evidence(
          StageArchiveInventory.parse(bytes),
        ),
      },
    ));
  }
  final cask = ReleaseAssets.caskName(executable);
  if (public.contains(cask)) {
    stage.directory.writeBytesAtomically(cask, utf8.encode('cask'));
    steps.add(StageStep(
      name: 'homebrew-cask',
      inputs: [for (final archive in archives) StageInput.artifact(archive)],
      outputs: [
        StageArtifact.capture(
          stage: stage.directory,
          path: cask,
          type: 'cask',
        ),
      ],
    ));
  }
  stage.writeProgress(steps);
  stage.finalize(releaseAssets: _fixtureReleaseAssets(public));
  return stage;
}

List<ReleaseAssetSpec> _fixtureReleaseAssets(Iterable<String> paths) => [
      for (final path in paths)
        ReleaseAssetSpec(stagedPath: path, publicName: path),
    ];

// Regressions from the phase 2-3 review.
void _reviewFixes() {
  test('publishing behind what is live is refused', () async {
    final run = await statusRun(
      source: tree(coreVersion: '0.2.0'),
      state: git(tags: ['v0.2.0']),
      registry: FakeRegistry({
        'keybay': ['0.1.0', '0.5.0']
      }),
    );
    expect(run.text, contains('0.2.0 is behind published version 0.5.0'));
    expect(run.text, isNot(contains('rk release')));

    final targets =
        ((run.report['units'] as List).single as Map)['targets'] as List;
    final pub = targets.singleWhere(
      (target) => (target as Map)['kind'] == 'pubDev',
    ) as Map;
    final monotonicity = (run.report['problems'] as List)
        .cast<Map>()
        .singleWhere((problem) => problem['code'] == 'RK-MONO-002');
    expect(monotonicity['target'], pub['id']);
    expect(
      _targetLine(run.text, 'pub.dev ').trimLeft(),
      startsWith('✗'),
    );
  });

  test('a package name owned by another repository is named plainly', () async {
    final run = await statusRun(
      source: tree(coreVersion: '0.2.0'),
      state: git(tags: ['v0.2.0']),
      registry: FakeRegistry(
        {
          'keybay': ['0.5.0'],
        },
        repositories: const {
          'keybay': 'https://github.com/another/keybay',
        },
      ),
    );

    expect(
      run.text,
      contains(
        'keybay on pub.dev points to https://github.com/another/keybay, '
        'not https://github.com/danReynolds/keybay',
      ),
    );
    expect(run.text, isNot(contains('behind published version')));
    final problem = (run.report['problems'] as List)
        .cast<Map>()
        .singleWhere((item) => item['code'] == 'RK-PUB-010');
    expect(problem['target'], isNotNull);
  });
}

// Regressions from the phase 2-3 review.
void _phase23Fixes() {
  test(
      'an unreachable registry never reads as ready, even with other '
      'problems present', () async {
    final text = await statusOf(
      source: tree(),
      state: git(clean: false),
      registry: FakeRegistry(const {}, unreachable: true),
    );
    expect(text, contains('could not be reached'),
        reason: 'the unknown must survive alongside another problem');
    expect(text, contains('is uncommitted'));
    expect(text, isNot(contains('ready')));
  });

  test('the target row names the published version, not the local one',
      () async {
    final text = await statusOf(
      source: tree(),
      state: git(tags: ['v0.2.0']),
      registry: FakeRegistry({
        'keybay': ['0.1.0']
      }),
    );
    expect(text, contains('0.1.0 › 0.2.0'),
        reason: 'local is 0.2.0; live is 0.1.0');
    expect(text, isNot(contains('prevent')));
  });

  test('a fully published unit ignores worktree state', () async {
    final text = await statusOf(
      source: tree(),
      state: git(clean: false, tags: ['v0.2.0']),
      registry: FakeRegistry({
        'keybay': ['0.2.0']
      }),
    );
    expect(text, matches(RegExp(r'^\s+Published$', multiLine: true)));
    expect(
      text,
      isNot(contains('files are uncommitted')),
      reason: 'the header still reports the tree; the unit is not blocked '
          'by it, because a dirty tree only matters to a release that will '
          'happen',
    );
  });
}

/// Regressions for the phase 3 reviews: readiness, collapse, and the summary
/// line were each mutable without a test noticing.
void statusReviewRegressions() {
  test('a conflict on a public step blocks readiness', () async {
    final text = await statusOf(
      source: tree(),
      state: git(),
      registry: FakeRegistry({
        'keybay': ['0.2.0']
      }, conflicting: {
        'keybay'
      }),
    );
    expect(text, isNot(contains('ready')));
    expect(text, isNot(contains('rk release')));
    expect(text, contains('pub.dev versions are immutable'));
    expect(text, contains('Bump the version and changelog'));
  });

  test('a dirty tree suppresses the next command', () async {
    final text = await statusOf(
      source: tree(),
      state: git(clean: false),
      registry: FakeRegistry({
        'keybay': ['0.1.0']
      }),
    );
    expect(
      text,
      isNot(contains('→ rk release core')),
      reason: 'the instruction would sit above the reason it will not work',
    );
    expect(text, contains('uncommitted'));
  });

  test('the summary never concludes "not published" from a failed read',
      () async {
    final run = await statusRun(
      source: tree(),
      state: git(),
      registry: FakeRegistry({}, unreachable: true),
    );
    expect(run.text, matches(RegExp(r'pub\.dev\s+keybay')));
    expect(run.text, contains('could not be read'));
    expect(
      run.text,
      contains('could not be reached'),
      reason: 'the lane says the read failed, in the words of the failure',
    );
  });

  test(
      'an absent prerequisite blocks readiness and points at the '
      'unit that must go first', () async {
    final run = await statusRun(
      withConfig: '''
schema = 2

[release.core]
tag = "keybay-v{version}"
path = "packages/keybay"
publish = ["git-tag", "pub.dev"]

[release.cli]
tag = "keybay_cli-v{version}"
path = "packages/cli"
publish = ["git-tag", "pub.dev"]
''',
      source: MemorySourceTree({
        'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
        'packages/keybay/CHANGELOG.md': '## 0.2.0\n',
        'packages/cli/pubspec.yaml': '''
name: keybay_cli
version: 0.2.0
dependencies:
  keybay: 0.2.0
''',
        'packages/cli/CHANGELOG.md': '## 0.2.0\n',
      }, description: '/repo/keybay'),
      state: git(),
      registry: FakeRegistry({}),
    );

    expect(
      run.text,
      isNot(contains('rk release cli')),
      reason: 'release would refuse it on the spot',
    );
    expect(
      run.text,
      contains('rk release core'),
      reason: 'the honest next command is the unit that must go first',
    );
  });

  test('a published binary target stays visible and keeps all JSON steps',
      () async {
    final run = await statusRun(
      withConfig: '''
schema = 2

[release.cli]
path = "packages/keybay"
publish = ["git-tag", "pub.dev", "github-release"]
binary_platforms = ["macos-arm64"]
''',
      source: MemorySourceTree({
        'packages/keybay/pubspec.yaml': '''
name: keybay
version: 0.2.0
executables:
  keybay: keybay
''',
        'packages/keybay/CHANGELOG.md': '## 0.2.0\n',
      }, description: '/repo/keybay'),
      state: git(tags: const ['v0.2.0']),
      registry: FakeRegistry({
        'keybay': ['0.2.0']
      }),
      inspectorBuilder: (git, _) => FixedInspector(
        registry: FakeRegistry({
          'keybay': ['0.2.0']
        }),
        git: git,
        answer: const Inspection.exact(detail: 'published exactly'),
      ),
    );

    expect(run.text, contains('Git tag'));
    expect(run.text, contains('GitHub Release'));
    expect(run.text, matches(RegExp(r'^\s+Published$', multiLine: true)));
    expect(
      run.text,
      isNot(contains('build keybay')),
      reason: 'nine local lines under a finished release are noise',
    );

    final steps = [
      for (final unit in (run.report['units'] as List))
        ...((unit as Map)['steps'] as List).cast<Map<String, Object?>>(),
    ];
    expect(
      steps.map((s) => s['id']),
      contains('cli/build/keybay/macos-arm64'),
      reason: 'the document may carry more than the terminal shows — a '
          'caller keying on step ids wants the whole checklist',
    );
  });
}
