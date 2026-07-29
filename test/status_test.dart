import 'package:rk/src/commands/status.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/output.dart';
import 'package:rk/src/engine/registry.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/engine/version.dart';
import 'package:test/test.dart';

/// A registry with a fixed idea of what is published, so status can be
/// exercised without a network.
class FakeRegistry implements RegistryReader {
  FakeRegistry(this.published, {this.unreachable = false});

  /// Package name to the versions live on the registry.
  final Map<String, List<String>> published;
  final bool unreachable;

  @override
  Future<RegistryPackage?> lookup(String name) async {
    final versions = published[name];
    if (versions == null) return null;
    return RegistryPackage(
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
}) async {
  final buffer = StringBuffer();
  final diagnostics = Diagnostics();
  final parsed = ReleaseConfig.parse(config, 'release.toml', diagnostics)!;
  final resolution = Resolution.resolve(parsed, source, diagnostics);
  expect(resolution, isNotNull, reason: diagnostics.found.join('\n'));

  await StatusCommand(
    resolution: resolution!,
    tree: source,
    git: state,
    registry: registry,
    output: Output(
      sink: buffer.write,
      isTerminal: false,
      useColor: false,
    ),
  ).run();
  return buffer.toString();
}

void main() {
  test('says nothing to release when local matches live', () async {
    final text = await statusOf(
      source: tree(),
      state: git(),
      registry: FakeRegistry({'keybay': ['0.1.0', '0.2.0']}),
    );
    expect(text, contains('nothing to release'));
    expect(text, isNot(contains('rk release')));
  });

  test('says ready, and names the next command, when local is ahead',
      () async {
    final text = await statusOf(
      source: tree(),
      state: git(),
      registry: FakeRegistry({'keybay': ['0.1.0']}),
    );
    expect(text, contains('0.2.0 ready'));
    expect(text, contains('rk release core'));
  });

  test('blocks on a missing changelog entry, naming the heading to add',
      () async {
    final text = await statusOf(
      source: tree(changelog: '## 0.1.0\n'),
      state: git(),
      registry: FakeRegistry({'keybay': ['0.1.0']}),
    );
    expect(text, contains('no entry for 0.2.0'));
    expect(text, contains('## 0.2.0'));
    expect(text, isNot(contains('rk release')));
  });

  test('blocks on an unclean worktree, naming a file', () async {
    final text = await statusOf(
      source: tree(),
      state: git(clean: false),
      registry: FakeRegistry({'keybay': ['0.1.0']}),
    );
    expect(text, contains('uncommitted'));
    expect(text, contains('lib/src/args.dart'));
  });

  test('blocks on a commit no remote has', () async {
    final text = await statusOf(
      source: tree(),
      state: git(pushed: false),
      registry: FakeRegistry({'keybay': ['0.1.0']}),
    );
    expect(text, contains('not on any remote'));
    expect(text, contains('git push'));
  });

  test('blocks when a later tag already exists', () async {
    final text = await statusOf(
      source: tree(),
      state: git(tags: const ['v0.3.0']),
      registry: FakeRegistry({'keybay': ['0.1.0']}),
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
      state: git(),
      registry: FakeRegistry({'keybay': ['0.1.0', '0.5.0']}),
    );
    expect(text, contains('0.5.0 is already published'));
    expect(text, isNot(contains('rk release')));
  });
}

// Regressions from the phase 2-3 review.
void _phase23Fixes() {
  test('an unreachable registry never reads as ready, even with other '
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
      state: git(),
      registry: FakeRegistry({'keybay': ['0.1.0']}),
    );
    expect(text, contains('0.1.0 published'),
        reason: 'local is 0.2.0; live is 0.1.0');
    expect(text, contains('0.2.0 ready'));
  });

  test('a clean unit with nothing to release ignores worktree state',
      () async {
    final text = await statusOf(
      source: tree(),
      state: git(clean: false),
      registry: FakeRegistry({'keybay': ['0.2.0']}),
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
