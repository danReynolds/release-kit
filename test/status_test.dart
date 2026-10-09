import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/commands/status.dart';
import 'package:rk/src/targets/pub_dev/client.dart';
import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/canonical_json.dart';
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
import 'package:rk/src/transforms/digest.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:rk/src/engine/targets.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/engine/version.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/targets/catalog.dart';
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
          .where((tag) => arguments.contains('refs/tags/$tag'))
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
        stdout:
            'object $head\n'
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
  }) async => 0;
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
        stdout:
            '$testTagObject\trefs/tags/$tag\n'
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
        stdout:
            'object $releasedHead\n'
            'type commit\n'
            'tag $tag\n\n'
            'release-manifest-sha256: $testManifestDigest\n',
        stderr: '',
      );
    }
    if (executable == 'git' && arguments.first == 'verify-tag') {
      return ToolResult(exitCode: 0, stdout: '', stderr: '');
    }
    // The unit has changed since the release.
    if (executable == 'git' && arguments.contains('diff-tree')) {
      return ToolResult(exitCode: 1, stdout: '', stderr: '');
    }
    return ToolResult(exitCode: 127, stdout: '', stderr: 'not scripted');
  }

  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async => 0;
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
    this.unavailableVersions = const {},
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

  final Set<String> unavailableVersions;

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
  Future<PublishedVersion?> lookupVersion(String name, Version version) async {
    if (unavailableVersions.contains('$name@$version')) {
      throw RegistryUnavailable('public package read unavailable: $name');
    }
    return (await lookup(name))?.at(version);
  }

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
    return PubDevTarget(
      registry: this,
    ).inspectProject(project, expectedArchiveSha256: expectedArchiveSha256);
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
    ResolvedUnit unit,
  ) async {
    final configured = latest;
    if (configured != null) {
      return TargetHistory.versioned(inspection: configured, target: target);
    }
    final targetAnswer = answers[target.step.kind] ?? answer;
    if (targetAnswer.isExact) {
      return TargetHistory.versioned(
        inspection: Inspection.exact(
          detail: targetAnswer.detail,
          evidence: {...targetAnswer.evidence, 'version': target.targetVersion},
        ),
        target: target,
      );
    }
    if (targetAnswer.isAbsent && target.kind == 'pubDev') {
      return super.inspectHistory(target, unit);
    }
    return TargetHistory.versioned(inspection: targetAnswer, target: target);
  }

  @override
  List<Diagnostic> tagGuards(
    ResolvedUnit unit,
    Checklist checklist,
    Map<String, Inspection> states,
  ) => const [];
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
  ) => [
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
    this.answers = const {},
  });

  final int expected;
  final Map<StepKind, Inspection> answers;
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
    return answers[step.kind] ?? const Inspection.absent();
  }

  void finish(StepKind kind) => _gates[kind]!.complete();

  @override
  List<Diagnostic> tagGuards(
    ResolvedUnit unit,
    Checklist checklist,
    Map<String, Inspection> states,
  ) => const [];
}

GitState git({
  bool clean = true,
  bool pushed = true,
  List<String> tags = const [],
  String? tagTarget,
}) => GitState(
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
}) => MemorySourceTree({
  'packages/keybay/pubspec.yaml':
      'name: keybay\n'
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
  String? only,
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
  final selectedInspector =
      inspectorBuilder?.call(state, resolution!) ??
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
    // Origin agrees with local unless a test says otherwise; without a
    // repository the forge still reports as unread, which is what rk says
    // when it has not been given a way to look.
    inspector: selectedInspector,
    stageFor: stageFor,
    output: output,
    capabilities:
        capabilities ??
        HostCapabilities(hostPlatform: 'macos-arm64', containerRuntime: null),
  ).run(only: only);
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
  releaseReadiness();

  test('says what its stage holds, and the warnings it recorded', () async {
    final root = Directory.systemTemp.createTempSync('rk-status-warnings-');
    addTearDown(() => root.deleteSync(recursive: true));
    const pubOnly = '''
schema = 2

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]
''';
    final source = tree();
    final diagnostics = Diagnostics();
    final resolution = Resolution.resolve(
      ReleaseConfig.parse(pubOnly, 'release.toml', diagnostics)!,
      source,
      diagnostics,
    )!;
    final state = GitState(
      root: root.path,
      head: testHead,
      headTree: testTree,
      branch: 'main',
      isClean: true,
      uncommitted: const [],
      headIsPushed: true,
      tags: const [],
      signingConfigured: true,
      originUrl: 'danReynolds/keybay',
    );
    final stages = ReleaseStages(
      source: source,
      git: state,
      stageContracts: TargetCatalog.builtIn().stageContractResolver(resolution),
    );
    // A stage as `rk stage` leaves it after Pub warned.
    final unit = resolution.units.single;
    final stage = stages(unit);
    final path = ReleaseAssets.pubArchivePath(unit.projects.single);
    stage.writeProgress(const []);
    stage.directory.writeBytesAtomically(
      path,
      ArchiveBuilder.gzip(
        ArchiveBuilder.tar([
          ArchiveEntry(
            name: 'pubspec.yaml',
            bytes: utf8.encode(source.read('packages/keybay/pubspec.yaml')!),
          ),
        ]),
      ),
    );
    stage.writeProgress([
      StageStep(
        name: 'pub-archive:keybay',
        outputs: [
          StageArtifact.capture(
            stage: stage.directory,
            path: path,
            type: 'pub-archive',
          ),
        ],
        evidence: const {
          'package_archive': 'staged',
          'rk_warnings': [
            {
              'code': 'RK-PUB-012',
              'message':
                  'pub validation for keybay: Your dependency on ffi is '
                  'pinned to an exact version.',
              'remedy': 'rk release lists pub warnings again before it asks',
            },
          ],
        },
      ),
    ]);
    stage.finalize(releaseAssets: const []);
    expect(stage.inspect().reusable, isTrue);

    final run = await statusRun(
      withConfig: pubOnly,
      source: source,
      state: state,
      registry: FakeRegistry({
        'keybay': ['0.1.0'],
      }),
      stageFor: stages.call,
    );

    expect(run.text, matches(RegExp(r'^\s+Staged$', multiLine: true)));
    expect(run.text, matches(RegExp(r'pub\.dev +keybay package archive\n')));
    expect(run.text, contains('\nWarnings\n'));
    expect(
      run.text,
      contains('pub validation for keybay: Your dependency on ffi is pinned'),
    );
    expect(
      run.text.indexOf('Warnings'),
      lessThan(run.text.indexOf('rk release')),
      reason: 'said before the next move',
    );
    final warning = (run.report['warnings'] as List).single as Map;
    expect(warning['code'], 'RK-PUB-012');
    expect(warning['unit'], 'core');
    expect(warning['target'], 'core/pub.dev/keybay@0.2.0');
    expect(run.report['next'], ['rk release core']);
  });

  test(
    'post-release commits ask for the next version, not a moved tag',
    () async {
      const releasedHead = 'dddddddddddddddddddddddddddddddddddddddd';
      final run = await statusRun(
        source: tree(),
        state: git(tags: const ['v0.2.0'], tagTarget: releasedHead),
        registry: FakeRegistry({
          'keybay': ['0.2.0'],
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
        contains('version 0.2.0 is already released from different source'),
      );
      expect(
        run.text,
        contains('bump the version and add its changelog entry'),
      );
      expect(run.text, contains('rk stage core'));
      expect(run.text, isNot(contains('Not staged')));
      expect(
        _targetLine(run.text, 'Git tag').trimLeft(),
        isNot(startsWith('✗')),
      );

      final problems = (run.report['problems'] as List).cast<Map>();
      expect(problems.map((problem) => problem['code']), ['RK-MONO-004']);
      expect(problems.single.containsKey('target'), isFalse);
      final targets =
          ((run.report['units'] as List).single as Map)['targets'] as List;
      final tag =
          targets.singleWhere((target) => (target as Map)['kind'] == 'gitTag')
              as Map;
      expect(tag['verdict'], 'exact');
    },
  );

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

  test(
    'non-Git status separates destination truth from source comparison',
    () async {
      final run = await statusRun(
        withConfig: '''
schema = 2

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]
''',
        source: tree(),
        state: GitState.none('/repo'),
        registry: FakeRegistry({
          'keybay': ['0.2.0'],
        }),
      );

      final repository = run.report['repository'] as Map;
      expect(repository['source_binding'], 'unbound');
      expect(repository['source_comparison'], 'unavailable');
      expect(repository.containsKey('head'), isFalse);
      final unit = (run.report['units'] as List).single as Map;
      final target = (unit['targets'] as List).single as Map;
      expect(target['verdict'], 'exact');
      // Said once, for the repository: every target's would be the same.
      expect(target, isNot(contains('source_binding')));
      expect(target, isNot(contains('source_comparison')));
      expect(run.text, contains('no commit yet · commit to stage or release'));
      expect(run.text, isNot(contains('unbound')));
    },
  );

  test('names staging as the next command when local is ahead', () async {
    final run = await statusRun(
      source: tree(),
      state: git(tags: ['v0.1.0']),
      registry: FakeRegistry({
        'keybay': ['0.1.0'],
      }),
    );
    final text = run.text;
    expect(text, isNot(contains('prevent')));
    expect(
      text,
      contains('core 0.1.0 › 0.2.0'),
      reason:
          'every lane agrees the current release is 0.1.0, so the movement '
          'is stated once, on the unit, and not per row',
    );
    final targets =
        ((run.report['units'] as List).single as Map)['targets'] as List;
    expect(
      [for (final target in targets) (target as Map)['current_version']],
      ['0.1.0', '0.1.0'],
      reason: 'the Git lane reads its latest older tag, not an absence',
    );
    expect(text.trimRight(), endsWith('→ rk stage core'));
    expect(
      run.report['next'],
      ['rk stage core'],
      reason:
          'an unstaged unit is staged first; a mutation collapsing this '
          'to the publish form survived the whole suite',
    );
  });

  test(
    'a binary-only unit names its local output and direct next command',
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
        ),
      );

      expect(run.text, contains('Not staged'));
      expect(run.text, contains('Local binaries'));
      expect(run.text, contains('keybay-0.2.0-linux-x64.tar.gz'));
      expect(run.text, isNot(contains('producers/')));
      expect(run.report['next'], ['rk release cli']);
    },
  );

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
        'keybay': ['0.2.0'],
      }),
      capabilities: HostCapabilities(
        hostPlatform: 'linux-x64',
        containerRuntime: null,
      ),
    );

    expect(run.text, contains('Published'));
    expect(run.text, contains('Not staged'));
    expect(run.text, contains('Local binaries'));
    expect(run.text, contains('keybay-0.2.0-linux-x64.tar.gz'));
    expect(run.text, isNot(contains('producers/')));
    expect(run.report['next'], ['rk stage cli']);
  });

  test(
    'blocks on a missing changelog entry, naming the heading to add',
    () async {
      final text = await statusOf(
        source: tree(changelog: '## 0.1.0\n'),
        state: git(tags: ['v0.2.0']),
        registry: FakeRegistry({
          'keybay': ['0.1.0'],
        }),
      );
      expect(text, contains('no entry for 0.2.0'));
      expect(text, contains('## 0.2.0'));
      expect(text, isNot(contains('rk release')));
    },
  );

  test(
    'blocks on a commit no remote has, with the branch and the fix',
    () async {
      final text = await statusOf(
        source: tree(),
        state: git(pushed: false),
        registry: FakeRegistry({
          'keybay': ['0.1.0'],
        }),
      );
      expect(text, contains('no upstream on origin'));
      expect(text, contains('git push'));
    },
  );

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
        'keybay': ['0.1.0'],
      }),
    );
    expect(text, contains('ahead of 0.2.0'));
  });

  test(
    'an unreachable registry blocks rather than reading as absent',
    () async {
      final run = await statusRun(
        source: tree(),
        state: git(),
        registry: FakeRegistry(const {}, unreachable: true),
      );
      final targets =
          ((run.report['units'] as List).single as Map)['targets'] as List;
      final pub =
          targets.singleWhere((target) => (target as Map)['kind'] == 'pubDev')
              as Map;
      expect(pub['verdict'], 'unknown');
      expect(
        run.text,
        contains('could not be reached'),
        reason: 'the lane says the read failed, in the words of the failure',
      );
      expect(
        run.report['next'],
        isEmpty,
        reason: 'not knowing is not permission to publish',
      );
    },
  );

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

  test('delayed parallel reads show every target, then settle to the pipe '
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

    await terminalInspector.allStarted.future.timeout(
      const Duration(seconds: 1),
    );
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
        matches(
          RegExp(r'^  . GitHub Release · danReynolds/keybay\s+checking$'),
        ),
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
      reason:
          'the transient list is erased before the same deterministic '
          'target report a pipe receives',
    );
  });

  for (final (answer, progress, verdict) in [
    (
      const Inspection.conflict(
        'source differs',
        sourceMismatch: SourceBindingMismatch(
          releasedCommit: 'dddddddddddddddddddddddddddddddddddddddd',
          currentCommit: testHead,
        ),
      ),
      'checked',
      'exact',
    ),
    (const Inspection.conflict('manifest differs'), 'differs', 'conflict'),
    (const Inspection.unknown('tag read failed'), 'unread', 'unknown'),
  ]) {
    test('tag $verdict agrees in live progress and the final report', () async {
      late CoordinatedInspector inspector;
      late StringBuffer buffer;
      final running = statusRun(
        source: tree(),
        state: git(),
        registry: FakeRegistry(const {}),
        isTerminal: true,
        onOutputReady: (value) => buffer = value,
        inspectorBuilder: (git, _) => inspector = CoordinatedInspector(
          registry: FakeRegistry(const {}),
          git: git,
          expected: 2,
          answers: {StepKind.tag: answer},
        ),
      );
      await inspector.allStarted.future.timeout(const Duration(seconds: 1));
      inspector.finish(StepKind.tag);
      try {
        await _waitForStatusText(
          buffer,
          (text) => RegExp(
            'Git tag\\s+$progress',
          ).hasMatch(_afterLastTransientErase(text)),
        );
        final live = _afterLastTransientErase(buffer.toString());
        expect(live, matches(RegExp(r'pub\.dev.*checking')));
        if (verdict == 'exact') expect(live, isNot(contains('differs')));
      } finally {
        inspector.finish(StepKind.publishRegistry);
      }
      final result = await running;
      final unit = (result.report['units'] as List).single as Map;
      final targets = (unit['targets'] as List).cast<Map>();
      final tag = targets.singleWhere((target) => target['kind'] == 'gitTag');
      expect(tag['verdict'], verdict);
      expect(
        (result.report['problems'] as List).cast<Map>().any(
          (problem) => problem['code'] == 'RK-MONO-004',
        ),
        answer.sourceMismatch != null,
      );
    });
  }

  test(
    'multiple units nest transient targets under semantic headings',
    () async {
      const multiUnitConfig = '''
schema = 2

[release.keybay]
path = "packages/keybay"
tag = "v{version}"
publish = ["git-tag", "pub.dev"]

[release.keybay_cli]
path = "packages/keybay_cli"
tag = "keybay_cli-v{version}"
publish = ["git-tag", "pub.dev", "github-release"]
''';
      final multiUnitTree = MemorySourceTree({
        'packages/keybay/pubspec.yaml': '''
name: keybay
version: 0.2.0
repository: https://github.com/danReynolds/keybay
''',
        'packages/keybay/CHANGELOG.md': '## 0.2.0\n',
        'packages/keybay_cli/pubspec.yaml': '''
name: keybay_cli
version: 0.2.0
repository: https://github.com/danReynolds/keybay
''',
        'packages/keybay_cli/CHANGELOG.md': '## 0.2.0\n',
      }, description: '/repo/keybay');
      late CoordinatedInspector controlled;
      late StringBuffer buffer;
      final running = statusRun(
        withConfig: multiUnitConfig,
        source: multiUnitTree,
        state: git(),
        registry: FakeRegistry(const {}),
        isTerminal: true,
        onOutputReady: (output) => buffer = output,
        inspectorBuilder: (git, _) => controlled = CoordinatedInspector(
          registry: FakeRegistry(const {}),
          git: git,
          expected: 5,
        ),
      );

      await controlled.allStarted.future.timeout(const Duration(seconds: 1));
      await _waitForStatusText(
        buffer,
        (text) => text.contains('Release targets'),
      );
      final checking = _afterLastTransientErase(buffer.toString());
      expect(checking.split('\n').where((line) => line.isNotEmpty), [
        'Release targets',
        '  keybay',
        matches(RegExp(r'^    . Git tag\s+checking$')),
        matches(RegExp(r'^    . pub\.dev · keybay\s+checking$')),
        '  keybay_cli',
        matches(RegExp(r'^    . Git tag\s+checking$')),
        matches(RegExp(r'^    . pub\.dev · keybay_cli\s+checking$')),
        matches(
          RegExp(r'^    . GitHub Release · danReynolds/keybay\s+checking$'),
        ),
      ]);

      controlled
        ..finish(StepKind.tag)
        ..finish(StepKind.publishRegistry)
        ..finish(StepKind.publishRelease);
      await running;
    },
  );

  test('the publication heading is the verdict its targets agree on', () async {
    const exact = Inspection.exact(detail: 'published exactly');
    const absent = Inspection.absent();
    const conflict = Inspection.conflict('published bytes differ');
    const unknown = Inspection.unknown('provider was unavailable');
    for (final (heading, tag, pub) in [
      ('Published', exact, exact),
      ('Not published', absent, absent),
      ('Does not match', conflict, conflict),
      ('Could not be read', unknown, unknown),
      ('Public targets', exact, absent),
    ]) {
      final registry = FakeRegistry(const {});
      final run = await statusRun(
        source: tree(),
        state: git(),
        registry: registry,
        inspectorBuilder: (git, _) => FixedInspector(
          registry: registry,
          git: git,
          answer: pub,
          answers: {StepKind.tag: tag},
        ),
      );

      expect(
        run.text,
        matches(RegExp('^    $heading\$', multiLine: true)),
        reason: run.text,
      );
      final unit = (run.report['units'] as List).single as Map;
      expect(
        (unit['targets'] as List).map((target) => (target as Map)['verdict']),
        [tag.verdict.name, pub.verdict.name],
      );
      for (final (label, answer) in [('Git tag', tag), ('pub.dev ', pub)]) {
        expect(
          _targetLine(run.text, label).trimLeft().startsWith('✗'),
          answer.verdict == Verdict.conflict ||
              answer.verdict == Verdict.unknown,
          reason: '$heading: only a target that blocks the release is marked',
        );
      }
    }
  });

  test(
    'Homebrew owns its formula without adding it to GitHub inventory',
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

      final targets =
          ((run.report['units'] as List).single as Map)['targets'] as List;
      final github =
          targets.singleWhere(
                (target) => (target as Map)['kind'] == 'githubRelease',
              )
              as Map;
      final homebrew =
          targets.singleWhere((target) => (target as Map)['kind'] == 'homebrew')
              as Map;
      final tag =
          targets.singleWhere((target) => (target as Map)['kind'] == 'gitTag')
              as Map;
      expect(
        (github['artifacts'] as List).map(
          (artifact) => (artifact as Map)['name'],
        ),
        isNot(contains('keybay.rb')),
      );
      expect(
        (homebrew['artifacts'] as List).map(
          (artifact) => (artifact as Map)['name'],
        ),
        contains('keybay.rb'),
      );
      expect(homebrew['uses'], contains('keybay.rb'));
      expect(tag['artifacts'], isEmpty);
      expect(tag['uses'], 'release-manifest.json from GitHub Release');
    },
  );

  test(
    'cheap host facts mark artifacts that cannot be produced here',
    () async {
      final run = await statusRun(
        // Without pub.dev, every staged row is a binary this host cannot make.
        withConfig: binaryConfig.replaceFirst(
          '"git-tag", "pub.dev", "github-release"',
          '"git-tag", "github-release"',
        ),
        source: binaryTree,
        state: git(),
        registry: FakeRegistry(const {}),
        capabilities: HostCapabilities(
          hostPlatform: 'linux-x64',
          containerRuntime: null,
        ),
        inspectorBuilder: (git, _) => FixedInspector(
          registry: FakeRegistry(const {}),
          git: git,
          answer: const Inspection.absent(),
        ),
      );

      expect(
        run.text,
        matches(RegExp(r'^    Cannot be staged$', multiLine: true)),
      );
      expect(run.text, contains('this machine cannot produce every platform'));
      expect(run.text, contains('Fix: stage this unit on a host'));
      expect(
        run.text,
        matches(
          RegExp(
            r'✗\s+keybay-0\.2\.0-macos-arm64\.tar\.gz\s+macos-arm64 '
            r'cannot be produced here',
          ),
        ),
      );
      final targets =
          ((run.report['units'] as List).single as Map)['targets'] as List;
      final github =
          targets.singleWhere(
                (target) => (target as Map)['kind'] == 'githubRelease',
              )
              as Map;
      final archive =
          (github['artifacts'] as List).singleWhere(
                (artifact) =>
                    (artifact as Map)['name'] ==
                    'keybay-0.2.0-macos-arm64.tar.gz',
              )
              as Map;
      expect(archive['status'], 'invalid');
      expect(archive['problem'], contains('cannot be produced here'));
    },
  );

  test(
    'an unread public history is an issue even when the candidate is absent',
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
        reason:
            'an unread history is an issue, not a row condition — the '
            'candidate coordinate really is absent',
      );
      expect(run.text, contains('provider history was unreadable'));
      expect(run.text, contains('prevent'));

      final targets =
          ((run.report['units'] as List).single as Map)['targets'] as List;
      final github =
          targets.singleWhere(
                (target) => (target as Map)['kind'] == 'githubRelease',
              )
              as Map;
      expect(
        _targetLine(run.text, 'GitHub Release ').trimLeft(),
        startsWith('✗'),
        reason:
            'the target-linked issue, not the absent verdict, marks the row',
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
      final archive =
          (github['artifacts'] as List).singleWhere(
                (artifact) => (artifact as Map)['name'] == archiveName,
              )
              as Map;
      expect(archive['status'], 'notStaged');
      expect(
        run.text
            .split('\n')
            .firstWhere((line) => line.contains('artifacts'))
            .trimLeft(),
        startsWith('GitHub Release'),
        reason: 'a target problem does not turn an unstaged artifact into one',
      );
    },
  );

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
      reason:
          '› means becomes, so an arrow here claimed rk would turn the '
          'newer published version into the older one',
    );
    expect(run.text, isNot(contains('0.3.0 › 0.2.0')));
    expect(run.text, contains('ahead of the target 0.2.0'));
    expect(run.text, isNot(contains('RK-MONO-003')));
    expect(
      (run.report['problems'] as List).cast<Map>().map(
        (problem) => problem['code'],
      ),
      contains('RK-MONO-003'),
    );
    expect(
      run.text,
      contains('Fix: a release moves forward — bump past 0.3.0'),
    );
    expect(run.text, isNot(contains('rk stage core')));

    final targets =
        ((run.report['units'] as List).single as Map)['targets'] as List;
    final pub =
        targets.singleWhere((target) => (target as Map)['kind'] == 'pubDev')
            as Map;
    expect(_targetLine(run.text, 'pub.dev ').trimLeft(), startsWith('✗'));
    expect(pub['verdict'], 'absent');
    expect(
      (run.report['problems'] as List).cast<Map>().any(
        (problem) => problem['target'] == pub['id'],
      ),
      isTrue,
    );
  });

  test('uncommitted work stops staging whatever a unit publishes', () async {
    final run = await statusRun(
      source: tree(),
      state: git(clean: false),
      withConfig: '''
schema = 2

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]
''',
      registry: FakeRegistry({
        'keybay': ['0.1.0'],
      }),
    );

    expect(
      run.text,
      contains('lib/src/args.dart'),
      reason: 'named, not counted',
    );
    expect(run.text, contains('issue prevents release'));
    expect((run.report['problems'] as List).single['code'], 'RK-GIT-001');
    expect(run.report['warnings'], isEmpty);
    expect((run.report['repository'] as Map)['source_binding'], 'gitCommit');
    expect(
      run.report['next'],
      isEmpty,
      reason: 'the instruction would sit above the reason it will not work',
    );
  });

  for (final code in const ['RK-GIT-004', 'RK-GIT-005', 'RK-GIT-007']) {
    test('$code links to and marks the Git tag lane', () async {
      final registry = FakeRegistry(const {});
      final run = await statusRun(
        source: tree(),
        state: git(),
        registry: registry,
        inspectorBuilder: (git, _) =>
            GuardInspector(registry: registry, git: git, code: code),
      );

      final targets =
          ((run.report['units'] as List).single as Map)['targets'] as List;
      final tag =
          targets.singleWhere((target) => (target as Map)['kind'] == 'gitTag')
              as Map;
      final problem = (run.report['problems'] as List).cast<Map>().singleWhere(
        (problem) => problem['code'] == code,
      );

      expect(tag['verdict'], 'absent');
      expect(problem['target'], tag['id']);
      expect(_targetLine(run.text, 'Git tag').trimLeft(), startsWith('✗'));
    });
  }

  test(
    'completed binary-only stage stays visible without a host blocker',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'rk-status-local-stage-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final config = binaryConfig.replaceFirst(
        'publish = ["git-tag", "pub.dev", "github-release"]',
        'publish = []',
      );
      final stage = await _completedBinaryStage(
        root: root,
        config: config,
        source: binaryTree,
      );
      final run = await statusRun(
        withConfig: config,
        source: binaryTree,
        state: git(),
        registry: FakeRegistry(const {}),
        stageFor: (_) => stage,
        capabilities: HostCapabilities(
          hostPlatform: 'linux-x64',
          containerRuntime: null,
        ),
      );
      expect(run.text, contains('Staged'));
      expect(run.text, contains('keybay-0.2.0-macos-arm64.tar.gz'));
      expect(run.text, isNot(contains('cannot produce')));
      expect(run.report['problems'], isEmpty);
      expect(run.report['next'], isEmpty);
    },
  );

  test('unreadable stage shows its cause before the repair', () async {
    final run = await statusRun(
      withConfig: binaryConfig,
      source: binaryTree,
      state: git(),
      registry: FakeRegistry(const {}),
      stageFor: (_) => throw StateError('receipt truncated'),
      inspectorBuilder: (git, _) => FixedInspector(
        registry: FakeRegistry(const {}),
        git: git,
        answer: const Inspection.absent(),
      ),
    );
    expect(run.text, contains('Cause:'));
    expect(run.text, contains('receipt truncated'));
    expect(run.text.indexOf('Cause:'), lessThan(run.text.indexOf('Fix:')));
    final problems = (run.report['problems'] as List).cast<Map>();
    expect(
      problems.singleWhere((p) => p['code'] == 'RK-STAGE-002')['evidence'],
      endsWith('RK-STAGE-002.txt'),
    );
  });

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
    expect(run.text, matches(RegExp('${expected.length} artifacts')));
    final targets =
        ((run.report['units'] as List).single as Map)['targets'] as List;
    final github =
        targets.singleWhere(
              (target) => (target as Map)['kind'] == 'githubRelease',
            )
            as Map;
    expect(github['current_known'], isTrue);
    expect(github['target_version'], '0.2.0');
    expect(github['verdict'], 'absent');
    final staged = (github['artifacts'] as List).cast<Map>();
    expect(staged.map((artifact) => artifact['name']).toSet(), expected);
    expect(staged.map((artifact) => artifact['status']).toSet(), {'staged'});
  });

  test(
    'an exact stage makes a partial public release safely resumable',
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
        'keybay': ['0.2.0'],
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

      expect(run.text, matches(RegExp(r'Git tag\s+v0\.2\.0')));
      expect(run.text, matches(RegExp(r'pub\.dev\s+keybay')));
      expect(run.text, matches(RegExp(r'GitHub Release\s+danReynolds/keybay')));
      expect(run.report['next'], ['rk release cli']);
      expect(
        run.text,
        contains('→ rk release cli'),
        reason: 'the same safe resume command is visible to the operator',
      );
      expect(run.report['problems'], isEmpty);
      final targets =
          ((run.report['units'] as List).single as Map)['targets'] as List;
      expect(
        [
          for (final target in targets)
            ((target as Map)['kind'], target['verdict']),
        ],
        [('gitTag', 'exact'), ('pubDev', 'exact'), ('githubRelease', 'absent')],
      );
      final github =
          targets.singleWhere(
                (target) => (target as Map)['kind'] == 'githubRelease',
              )
              as Map;
      expect(
        (github['artifacts'] as List)
            .map((artifact) => (artifact as Map)['status'])
            .toSet(),
        {'staged'},
      );
    },
  );

  test(
    'a reusable stage does not require the publishing host to reproduce it',
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
        ),
        inspectorBuilder: (git, _) => FixedInspector(
          registry: FakeRegistry(const {}),
          git: git,
          answer: const Inspection.absent(),
        ),
      );

      expect(
        run.report['problems'],
        isEmpty,
        reason: 'the stage holds the bytes; this host need not remake them',
      );
      expect(run.report['next'], ['rk release cli']);
    },
  );

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
    final archive = ReleaseAssets.archiveName('keybay', '0.2.0', 'macos-arm64');
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
      (run.report['problems'] as List).cast<Map>().where(
        (problem) => problem['code'] == 'RK-STAGE-002',
      ),
      hasLength(1),
    );
  });

  test('an interrupted stage is not described as reviewed', () async {
    final root = Directory.systemTemp.createTempSync('rk-status-incomplete-');
    addTearDown(() => root.deleteSync(recursive: true));
    final made = await _completedBinaryStage(
      root: root,
      config: binaryConfig,
      source: binaryTree,
    );
    final receipt = made.requireReceipt();
    StageReceiptStore(made.directory).write(
      StageReceipt(
        identity: receipt.identity,
        plan: receipt.plan,
        steps: receipt.steps.take(2),
      ),
    );
    // A recorded output changed since, so the progress cannot be resumed.
    File(
      made.directory.resolve(receipt.steps.first.outputs.first.path),
    ).writeAsStringSync('changed');

    final run = await statusRun(
      withConfig: binaryConfig,
      source: binaryTree,
      state: git(),
      registry: FakeRegistry(const {}),
      stageFor: (_) => made,
      inspectorBuilder: (git, _) => FixedInspector(
        registry: FakeRegistry(const {}),
        git: git,
        answer: const Inspection.absent(),
      ),
    );

    final stageProblem = (run.report['problems'] as List)
        .cast<Map>()
        .singleWhere((problem) => problem['code'] == 'RK-STAGE-002');
    expect(
      stageProblem['message'],
      'the incomplete release stage cannot be resumed safely',
    );
  });

  test(
    'a global completed-stage problem invalidates every artifact row',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'rk-status-stage-global-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final complete = await _completedBinaryStage(
        root: root,
        config: binaryConfig,
        source: binaryTree,
      );
      // A completed receipt that names another stage.
      final receipt = complete.requireReceipt();
      final another = StageReceipt(
        identity: StageIdentity.forPlan(
          headCommit: testHead,
          headTree: testTree,
          resolvedPlan: {'unit': 'another'},
        ),
        plan: receipt.plan,
        steps: receipt.steps,
      );
      File(
        complete.directory.resolve('stage.json'),
      ).writeAsStringSync('${CanonicalJson.encode(another.toJson())}\n');
      ReleaseStage stageFor(ResolvedUnit unit) => complete;

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
      expect(run.text, contains('receipt identity does not name this stage'));
      expect(run.text, isNot(contains('RK-STAGE-002')));
      expect(
        (run.report['problems'] as List).cast<Map>().map(
          (problem) => problem['code'],
        ),
        contains('RK-STAGE-002'),
      );
    },
  );

  for (final pending in [
    const Inspection.absent(),
    const Inspection.unknown('public package read unavailable'),
  ]) {
    test(
      'a public tag leaves a package stage rebuildable with ${pending.verdict.name} publication',
      () async {
        // Pub stages nothing a consumer can compare against a rebuild: the
        // version on pub.dev is what counts, so a lost stage is rebuilt.
        final registry = FakeRegistry(const {});
        final run = await statusRun(
          withConfig: config,
          source: tree(),
          state: git(),
          registry: registry,
          inspectorBuilder: (git, _) => FixedInspector(
            registry: registry,
            git: git,
            answer: pending,
            answers: const {
              StepKind.tag: Inspection.exact(detail: 'release tag is public'),
            },
          ),
        );
        expect(run.text, isNot(contains('needs its exact stage')));
        final problems = (run.report['problems'] as List).cast<Map>();
        expect(problems.map((p) => p['code']), isNot(contains('RK-STAGE-005')));
        if (pending.verdict == Verdict.absent) {
          expect(run.text, contains('rk stage core'));
        }
      },
    );
  }

  for (final unreadPrivate in [false, true]) {
    test(
      'tagless mixed packages do not imply lost stage with unread private $unreadPrivate',
      () async {
        const mixedConfig = '''
schema = 2
[release.bundle]
[[release.bundle.project]]
path = "core"
publish = ["pub.dev"]
[[release.bundle.project]]
path = "private"
publish = ["pub.dev"]
''';
        final source = MemorySourceTree({
          for (final name in ['core', 'private']) ...{
            '$name/pubspec.yaml':
                'name: rk_fixture_$name\n'
                'version: 0.2.0\n'
                'repository: https://github.com/example/mixed\n',
            '$name/CHANGELOG.md': '## 0.2.0\n\nNew release.\n',
          },
        }, description: '/repo/mixed');
        final run = await statusRun(
          withConfig: mixedConfig,
          source: source,
          state: git(),
          registry: FakeRegistry(
            {
              'rk_fixture_core': ['0.2.0'],
            },
            unavailableVersions: {
              if (unreadPrivate) 'rk_fixture_private@0.2.0',
            },
          ),
        );
        final problems = (run.report['problems'] as List).cast<Map>();
        expect(
          problems.map((problem) => problem['code']),
          isNot(contains('RK-STAGE-005')),
        );
        if (unreadPrivate) {
          expect(run.text, contains('public package read unavailable'));
          expect(run.report['next'], isEmpty);
        } else {
          expect(run.text, contains('rk stage bundle'));
        }
        final unit = (run.report['units'] as List).single as Map;
        final targets = (unit['targets'] as List).cast<Map>();
        expect(
          targets.map((target) => target['verdict']),
          containsAll(['exact', unreadPrivate ? 'unknown' : 'absent']),
        );
      },
    );
  }

  test(
    'a published package alone does not require a binary release stage',
    () async {
      // The package's version on pub.dev binds nothing; the tag and the
      // GitHub release, which bind the stage's bytes, are not public yet.
      final run = await statusRun(
        withConfig: binaryConfig,
        source: binaryTree,
        state: git(),
        registry: FakeRegistry({
          'keybay': ['0.1.0', '0.2.0'],
        }),
        inspectorBuilder: (git, _) => FixedInspector(
          registry: FakeRegistry({
            'keybay': ['0.1.0', '0.2.0'],
          }),
          git: git,
          answer: const Inspection.absent(),
          answers: const {
            StepKind.publishRegistry: Inspection.exact(detail: 'published'),
          },
        ),
      );

      expect(
        (run.report['problems'] as List).map(
          (problem) => (problem as Map)['code'],
        ),
        isNot(contains('RK-STAGE-005')),
      );
      expect(run.text, isNot(contains('needs its exact stage')));
    },
  );

  test(
    'a partial binary release without its exact stage is an issue',
    () async {
      final run = await statusRun(
        withConfig: binaryConfig,
        source: binaryTree,
        state: git(),
        registry: FakeRegistry({
          'keybay': ['0.1.0'],
        }),
        inspectorBuilder: (git, _) => FixedInspector(
          registry: FakeRegistry({
            'keybay': ['0.1.0'],
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
      expect(
        run.text,
        matches(RegExp(r'^    Stage$', multiLine: true)),
        reason:
            'the package archive can still be staged; the bound binaries '
            'cannot, so the rows share no single heading',
      );
      expect(run.text, isNot(contains('RK-STAGE-005')));
      expect(
        run.text,
        contains('Signed or notarized bytes cannot be recreated'),
      );
      expect(run.text, contains('prevent'));
      expect(run.report['next'], isEmpty);
      expect(
        (run.report['problems'] as List).map(
          (problem) => (problem as Map)['code'],
        ),
        ['RK-STAGE-005'],
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
    },
  );
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
    directory: StageDirectory(repositoryRoot: root.path, identity: identity),
  );
  final public = ReleaseAssets.expectedForUnit(unit).toSet()
    ..remove(ReleaseAssets.manifest);
  final steps = <StageStep>[];
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
    steps.add(
      StageStep(
        name: '${platform.startsWith('macos-') ? 'sign' : 'build'}:$platform',
        outputs: [binary],
        evidence: {
          'smoke': {'status': 'passed'},
          if (platform.startsWith('macos-'))
            'signature': {
              'certificate': 'Developer ID Application: Test (TEAM123456)',
              'certificate_sha256': 'c' * 64,
              'first_identity': false,
              'published_requirement':
                  'designated => identifier '
                  '"io.example.$executable" and certificate '
                  'leaf[subject.OU] = "TEAM123456"',
              'code_id': 'io.example.$executable',
              'unsigned_sha256': 'd' * 64,
              'signed_sha256': binary.sha256,
            },
        },
      ),
    );
    if (platform.startsWith('macos-')) {
      steps.add(
        StageStep(
          name: 'notarize:$platform',
          evidence: {
            'notary': {'status': 'Accepted', 'submission_id': 'status-test'},
          },
        ),
      );
    }
    final archiveName = ReleaseAssets.archiveName(
      executable,
      project.version.canonical,
      platform,
    );
    final bytes = ArchiveBuilder.gzip(
      ArchiveBuilder.tar([
        ArchiveEntry(
          name: executable,
          bytes: utf8.encode('binary:$platform'),
          executable: true,
        ),
      ]),
    );
    stage.directory.writeBytesAtomically(archiveName, bytes);
    final archive = StageArtifact.capture(
      stage: stage.directory,
      path: archiveName,
      type: 'archive',
    );
    archives.add(archive);
    steps.add(
      StageStep(
        name: 'archive:$platform',
        outputs: [archive],
        evidence: {
          'inventory': StageArchiveInventory.evidence(
            StageArchiveInventory.parse(bytes),
          ),
        },
      ),
    );
  }
  final formula = ReleaseAssets.formulaName(executable);
  if (public.contains(formula)) {
    stage.directory.writeBytesAtomically(formula, utf8.encode('formula'));
    steps.add(
      StageStep(
        name: 'homebrew-formula',
        outputs: [
          StageArtifact.capture(
            stage: stage.directory,
            path: formula,
            type: 'formula',
          ),
        ],
      ),
    );
  }
  stage.writeProgress(steps);
  stage.finalize(releaseAssets: _fixtureReleaseAssets(public));
  return stage;
}

List<ReleaseAssetSpec> _fixtureReleaseAssets(Iterable<String> paths) => [
  for (final path in paths)
    ReleaseAssetSpec(stagedPath: path, publicName: path),
];

/// Whether a unit can be released, and what status suggests doing next.
void releaseReadiness() {
  test('publishing behind what is live is refused', () async {
    final run = await statusRun(
      source: tree(coreVersion: '0.2.0'),
      state: git(tags: ['v0.2.0']),
      registry: FakeRegistry({
        'keybay': ['0.1.0', '0.5.0'],
      }),
    );
    expect(run.text, contains('0.2.0 is behind published version 0.5.0'));
    expect(run.text, isNot(contains('rk release')));

    final targets =
        ((run.report['units'] as List).single as Map)['targets'] as List;
    final pub =
        targets.singleWhere((target) => (target as Map)['kind'] == 'pubDev')
            as Map;
    final monotonicity = (run.report['problems'] as List)
        .cast<Map>()
        .singleWhere((problem) => problem['code'] == 'RK-MONO-002');
    expect(monotonicity['target'], pub['id']);
    expect(_targetLine(run.text, 'pub.dev ').trimLeft(), startsWith('✗'));
  });

  test('a package pub.dev lists under another repository is a warning: the '
      'repository may have moved', () async {
    final run = await statusRun(
      source: tree(coreVersion: '0.2.0'),
      state: git(),
      registry: FakeRegistry(
        {
          'keybay': ['0.1.0'],
        },
        repositories: const {'keybay': 'https://github.com/old/keybay'},
      ),
    );

    expect(
      run.text,
      contains(
        'keybay on pub.dev points to https://github.com/old/keybay, '
        'not https://github.com/danReynolds/keybay',
      ),
    );
    expect(run.text, contains('if the repository moved'));
    expect(run.report['problems'], isEmpty);
    final warning = (run.report['warnings'] as List).cast<Map>().singleWhere(
      (item) => item['code'] == 'RK-PUB-010',
    );
    expect(warning['target'], isNotNull);
  });

  test('an unreachable registry is still reported beside another '
      'problem', () async {
    final text = await statusOf(
      source: tree(),
      state: git(clean: false),
      registry: FakeRegistry(const {}, unreachable: true),
    );
    expect(
      text,
      contains('could not be reached'),
      reason: 'the unknown must survive alongside another problem',
    );
    expect(text, contains('is uncommitted'));
  });

  test('a fully published unit ignores worktree state', () async {
    final run = await statusRun(
      source: tree(),
      state: git(clean: false, tags: ['v0.2.0']),
      registry: FakeRegistry({
        'keybay': ['0.2.0'],
      }),
    );
    expect(run.text, matches(RegExp(r'^\s+Published$', multiLine: true)));
    expect(
      run.text,
      matches(RegExp(r'pub\.dev\s+keybay')),
      reason: 'a finished release still shows its targets',
    );
    expect(
      run.text.split('\n').first,
      endsWith('1 uncommitted'),
      reason: 'the header still reports the tree',
    );
    expect(
      run.report['problems'],
      isEmpty,
      reason:
          'the unit is not blocked by the tree, because a dirty tree only '
          'matters to a release that will happen',
    );
    expect(run.text, isNot(contains('prevents release')));
    expect(run.report['next'], isEmpty);
  });

  test('a conflict on a public step blocks the release', () async {
    final run = await statusRun(
      source: tree(),
      state: git(),
      registry: FakeRegistry(
        {
          'keybay': ['0.2.0'],
        },
        conflicting: {'keybay'},
      ),
    );
    expect(run.report['next'], isEmpty);
    expect(run.text, contains('pub.dev versions are immutable'));
    expect(run.text, contains('Bump the version and changelog'));
  });

  test(
    'several unfinished units suggest the repository command, not one unit',
    () async {
      final run = await statusRun(
        withConfig: '''
schema = 2

[release.core]
path = "packages/core"
publish = ["pub.dev"]

[release.cli]
path = "packages/cli"
publish = ["pub.dev"]
''',
        source: MemorySourceTree({
          'packages/core/pubspec.yaml': 'name: core\nversion: 1.0.0\n',
          'packages/core/CHANGELOG.md': '## 1.0.0\n',
          'packages/cli/pubspec.yaml': 'name: cli\nversion: 1.0.0\n',
          'packages/cli/CHANGELOG.md': '## 1.0.0\n',
        }, description: '/repo/stack'),
        state: git(),
        registry: FakeRegistry({}),
      );

      expect(run.report['problems'], isEmpty);
      expect(run.report['next'], ['rk stage']);
      expect(run.text, isNot(contains('rk stage core')));
      expect(run.text, isNot(contains('rk stage cli')));
    },
  );

  test('a prerequisite this repository releases orders the release '
      'rather than blocking it', () async {
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

    expect(run.text, contains('Releases after'));
    expect(run.text, contains('core 0.2.0'));
    expect(
      run.text,
      isNot(contains('prevents release')),
      reason: 'a repository release publishes core before cli',
    );
    expect(run.report['next'], ['rk stage']);
  });

  group('a unit that releases after a sibling not on pub.dev yet', () {
    const siblings = '''
schema = 2

[release.cli]
path = "packages/cli"
publish = ["pub.dev"]

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]
''';
    MemorySourceTree source() => MemorySourceTree({
      'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
      'packages/keybay/CHANGELOG.md': '## 0.2.0\n',
      'packages/cli/pubspec.yaml':
          'name: keybay_cli\nversion: 0.2.0\ndependencies:\n  keybay: 0.2.0\n',
      'packages/cli/CHANGELOG.md': '## 0.2.0\n',
    }, description: '/repo/keybay');

    test('is shown after it, in the order they release', () async {
      final run = await statusRun(
        withConfig: siblings,
        source: source(),
        state: git(),
        registry: FakeRegistry({
          'keybay': ['0.1.0'],
          'keybay_cli': ['0.1.0'],
        }),
      );

      expect(
        (run.report['units'] as List).map((unit) => (unit as Map)['name']),
        ['core', 'cli'],
      );
      expect(
        run.text.indexOf('\n  core 0.1.0'),
        allOf(isNonNegative, lessThan(run.text.indexOf('\n  cli 0.1.0'))),
      );
    });

    test('is released with it, by the repository command', () async {
      final run = await statusRun(
        withConfig: siblings,
        source: source(),
        state: git(),
        registry: FakeRegistry({
          'keybay': ['0.1.0'],
          'keybay_cli': ['0.1.0'],
        }),
        only: 'cli',
      );

      expect(run.text, contains('Releases after'));
      expect(run.report['problems'], isEmpty);
      expect(
        run.report['next'],
        ['rk stage'],
        reason: 'rk stage cli and rk release cli would wait for core',
      );
    });
  });

  test('a prerequisite rk cannot read still blocks', () async {
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
      registry: FakeRegistry({}, unreachable: true),
    );
    expect(run.text, contains('restore read access to the prerequisite'));
    expect(run.text, contains('prevent release'));
  });

  test(
    'a published binary target stays visible and keeps all JSON steps',
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
          'keybay': ['0.2.0'],
        }),
        inspectorBuilder: (git, _) => FixedInspector(
          registry: FakeRegistry({
            'keybay': ['0.2.0'],
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
        isNot(contains('macos-arm64')),
        reason: 'local work listed under a finished release is noise',
      );
      expect(
        run.text,
        isNot(contains('Not staged')),
        reason:
            'a public target already binds every binary archive, so a '
            'compiler-specific private stage is no longer pending release work',
      );
      expect(run.report['next'], isEmpty);

      final steps = [
        for (final unit in (run.report['units'] as List))
          ...((unit as Map)['steps'] as List).cast<Map<String, Object?>>(),
      ];
      expect(
        steps.map((s) => s['id']),
        contains('cli/build/keybay/macos-arm64'),
        reason:
            'the document may carry more than the terminal shows — a '
            'caller keying on step ids wants the whole checklist',
      );
    },
  );
}
