import 'dart:convert';

import 'package:rk/src/commands/status.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/inspect.dart';
import 'package:rk/src/engine/output.dart';
import 'package:rk/src/engine/registry.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/engine/version.dart';
import 'package:test/test.dart';

import 'scripted_tools.dart';

/// A registry with a fixed idea of what is published, so status can be
/// exercised without a network.
class FakeRegistry implements RegistryReader {
  FakeRegistry(this.published,
      {this.unreachable = false, this.conflicting = const {}});

  /// Package name to the versions live on the registry.
  final Map<String, List<String>> published;
  final bool unreachable;

  /// Packages whose published content differs from this source.
  final Set<String> conflicting;

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
              archiveUrl: null,
              archiveSha256: null,
            ),
          )
          .toList(),
    );
  }

  @override
  Future<Inspection> inspect(String name, Version version) async {
    if (unreachable) {
      return const Inspection.unknown('pub.dev could not be reached');
    }
    if (conflicting.contains(name)) {
      return const Inspection.conflict('differs from this source');
    }
    final package = await lookup(name);
    if (package == null) {
      return const Inspection.absent(detail: 'the package does not exist yet');
    }
    return package.at(version) == null
        ? const Inspection.absent()
        : const Inspection.exact(detail: 'published 6 months ago');
  }
}

GitState git({
  bool clean = true,
  bool pushed = true,
  List<String> tags = const [],
}) =>
    GitState(
      root: '/repo',
      head: '9f2c1abcdef',
      branch: 'main',
      isClean: clean,
      uncommitted: clean ? const [] : const ['lib/src/args.dart'],
      headIsPushed: pushed,
      tags: tags,
      signingConfigured: true,
      originUrl: 'danReynolds/keybay',
    );

MemorySourceTree tree({
  String coreVersion = '0.2.0',
  String changelog = '## 0.2.0\n',
}) =>
    MemorySourceTree({
      'packages/keybay/pubspec.yaml': 'name: keybay\nversion: $coreVersion\n',
      'packages/keybay/CHANGELOG.md': changelog,
    }, description: '/repo/keybay');

const config = '''
schema = 1

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]
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
}) async {
  final buffer = StringBuffer();
  final diagnostics = Diagnostics();
  final parsed = ReleaseConfig.parse(withConfig, 'release.toml', diagnostics)!;
  final resolution = Resolution.resolve(parsed, source, diagnostics);
  expect(resolution, isNotNull, reason: diagnostics.found.join('\n'));

  final output = Output(
    sink: buffer.write,
    isTerminal: false,
    useColor: false,
  );
  final code = await StatusCommand(
    resolution: resolution!,
    tree: source,
    git: state,
    registry: registry,
    // Without tools and a repository the forge reports as unread, which is
    // what rk says when it has not been given a way to look.
    inspector: Inspector(
      registry: registry,
      git: state,
      tools: tools,
      repository: repository,
    ),
    output: output,
  ).run();
  return (
    text: buffer.toString(),
    report:
        jsonDecode(output.report.encode(exit: code)) as Map<String, Object?>,
  );
}

void main() {
  statusReviewRegressions();

  test('says nothing to release when local matches live', () async {
    final text = await statusOf(
      source: tree(),
      state: git(tags: ['v0.2.0']),
      registry: FakeRegistry({
        'keybay': ['0.1.0', '0.2.0']
      }),
    );
    expect(text, contains('nothing to release'));
    expect(text, isNot(contains('rk release')));
  });

  test('says ready, and names the next command, when local is ahead', () async {
    final text = await statusOf(
      source: tree(),
      state: git(tags: ['v0.2.0']),
      registry: FakeRegistry({
        'keybay': ['0.1.0']
      }),
    );
    expect(text, contains('0.2.0 ready'));
    expect(text, contains('rk release core'));
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

  test('blocks on a commit no remote has', () async {
    final text = await statusOf(
      source: tree(),
      state: git(pushed: false),
      registry: FakeRegistry({
        'keybay': ['0.1.0']
      }),
    );
    expect(text, contains('not on any remote'));
    expect(text, contains('git push'));
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

  test('a package that has never been published reads as ready', () async {
    final text = await statusOf(
      source: tree(),
      state: git(),
      registry: FakeRegistry(const {}),
    );
    expect(text, contains('not published'));
    expect(text, contains('0.2.0 ready'));
  });
}

// Regressions from the phase 2-3 review.
void _reviewFixes() {
  test('publishing behind what is live is refused', () async {
    final text = await statusOf(
      source: tree(coreVersion: '0.2.0'),
      state: git(tags: ['v0.2.0']),
      registry: FakeRegistry({
        'keybay': ['0.1.0', '0.5.0']
      }),
    );
    expect(text, contains('0.5.0 is already published'));
    expect(text, isNot(contains('rk release')));
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
    expect(text, isNot(contains('0.2.0 ready')));
  });

  test('the live line names the published version, not the local one',
      () async {
    final text = await statusOf(
      source: tree(),
      state: git(tags: ['v0.2.0']),
      registry: FakeRegistry({
        'keybay': ['0.1.0']
      }),
    );
    expect(text, contains('0.1.0 published'),
        reason: 'local is 0.2.0; live is 0.1.0');
    expect(text, contains('0.2.0 ready'));
  });

  test('a clean unit with nothing to release ignores worktree state', () async {
    final text = await statusOf(
      source: tree(),
      state: git(clean: false, tags: ['v0.2.0']),
      registry: FakeRegistry({
        'keybay': ['0.2.0']
      }),
    );
    expect(text, contains('nothing to release'));
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
    expect(
      run.text,
      isNot(contains('not published')),
      reason: 'the step lines were honest all along; this line was '
          'concluding a definitive negative from a socket error',
    );
    expect(run.text, contains('could not be read'));
  });

  test(
      'an absent prerequisite blocks readiness and points at the '
      'unit that must go first', () async {
    final run = await statusRun(
      withConfig: '''
schema = 1

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]

[release.cli]
path = "packages/cli"
publish = ["pub.dev"]
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

  test('moot steps leave the terminal but never the document', () async {
    final run = await statusRun(
      withConfig: '''
schema = 1

[release.cli]
path = "packages/keybay"
publish = ["pub.dev", "github-release"]
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
      tools: ScriptedTools({
        'gh': ok('{"tagName":"v0.2.0","isDraft":false,"name":"v0.2.0",'
            '"assets":[{"name":"keybay-0.2.0-macos-arm64.tar.gz"},'
            '{"name":"SHA256SUMS"}]}'),
      }),
      repository: 'example/keybay',
    );

    expect(run.text, contains('nothing to release'));
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
      contains('cli/build/macos-arm64'),
      reason: 'the document may carry more than the terminal shows — a '
          'caller keying on step ids wants the whole checklist',
    );
  });
}
