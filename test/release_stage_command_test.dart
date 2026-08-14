import 'dart:convert';
import 'dart:io';

import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/commands/release.dart';
import 'package:rk/src/destinations/pub_dev.dart';
import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/inspect.dart';
import 'package:rk/src/engine/release_stage.dart';
import 'package:rk/src/engine/registry.dart';
import 'package:rk/src/engine/release_manifest.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/stage_inspection.dart';
import 'package:rk/src/engine/stage_plan.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/targets/catalog.dart';
import 'package:rk/src/transforms/archive.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

import 'status_test.dart' show FakeRegistry;

const _head = '1111111111111111111111111111111111111111';
const _headTree = '2222222222222222222222222222222222222222';
const _tagObject = '3333333333333333333333333333333333333333';
const _otherHead = '4444444444444444444444444444444444444444';
const _otherTree = '5555555555555555555555555555555555555555';

const _config = '''
schema = 2

[release.tool]
path = "packages/tool"
publish = ["git-tag", "pub.dev", "github-release", "homebrew"]
binary_platforms = ["linux-x64"]
''';

const _pubOnlyConfig = '''
schema = 2

[release.tool]
path = "packages/tool"
publish = ["pub.dev"]
''';

const _localBinaryConfig = '''
schema = 2

[release.tool]
path = "packages/tool"
binary_platforms = ["linux-x64"]
''';

const _pubspec = '''
name: tool
version: 1.2.3
executables:
  tool: tool
''';

const _changelog = '''
## 1.2.3

Production alpha.
''';

const _entrypoint = '''
void main(List<String> arguments) {
  if (arguments.contains('--version')) print('1.2.3');
}
''';

void main() {
  late _Harness harness;

  setUp(() => harness = _Harness());
  tearDown(() => harness.close());

  test('a non-Git one-shot release binds bytes but claims no revision',
      () async {
    final unbound = _Harness(unbound: true);
    addTearDown(unbound.close);

    final run = await unbound.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );

    expect(run.code, ExitCodes.ok, reason: run.text);
    expect(
      run.publicMutations.map((call) => call.publicKind),
      ['pub.dev'],
    );
    final receipt = unbound.stage.requireReceipt();
    expect(receipt.identity.isGitBound, isFalse);
    expect(receipt.identity.headCommit, isNull);
    expect(
      receipt.steps.first.evidence,
      const {'source_binding': 'unbound'},
    );
    final manifest = ReleaseManifest.parse(
      File(unbound.stage.directory.resolve(ReleaseAssets.manifest))
          .readAsStringSync(),
    );
    expect(manifest.commit, isNull);
  });

  test('a dirty registry-only snapshot warns and still releases', () async {
    final unbound = _Harness(unbound: true);
    addTearDown(unbound.close);
    final repository = unbound.gitAt(
      isClean: false,
      uncommitted: const ['packages/tool/pubspec.yaml'],
    );

    final run = await unbound.run(
      stageOnly: false,
      confirm: (_) async => 'yes',
      repositoryGit: repository,
      sourceWarning: repository.uncommittedSnapshotWarning(),
    );

    expect(run.code, ExitCodes.ok, reason: run.text);
    expect(run.publicMutations.map((call) => call.publicKind), ['pub.dev']);
    expect(run.problemCodes, isEmpty);
    expect(run.warningCodes, ['RK-GIT-001']);
    expect(run.text, contains('will be captured in the source snapshot'));
    expect(run.text, isNot(contains('RK-GIT-001')));
    expect(unbound.stage.requireReceipt().identity.isGitBound, isFalse);
  });

  test('non-Git stage-only refuses the unusable handoff', () async {
    final unbound = _Harness(unbound: true);
    addTearDown(unbound.close);

    final run = await unbound.run(
      stageOnly: true,
      confirm: (_) async => fail('the refusal needs no authorization'),
    );

    expect(run.code, ExitCodes.refused, reason: run.text);
    expect(run.problemCodes, ['RK-SRC-002']);
    expect(run.publicMutations, isEmpty);
    expect(unbound.stage.inspect().receipt, isNull);
  });

  test('a binary-only release writes local archives without authorization',
      () async {
    for (final unbound in [false, true]) {
      final local = _Harness(localBinaryOnly: true, unbound: unbound);
      addTearDown(local.close);

      final run = await local.run(
        stageOnly: false,
        confirm: (_) async => fail('local output needs no authorization'),
      );

      expect(run.code, ExitCodes.ok, reason: run.text);
      expect(run.publicMutations, isEmpty);
      expect(run.text, contains('tool 1.2.3 · staged'));
      expect(run.text, contains('Local binaries'));
      expect(
        run.text,
        contains('producers/tool/archives/tool-1.2.3-linux-x64.tar.gz'),
      );
      expect(run.text, contains('Written to'));
      expect(run.report['next'], isEmpty);
      expect(local.stage.inspect().reusable, isTrue);
    }
  });

  test('non-Git existing version skips without rebuilding historical bytes',
      () async {
    final unbound = _Harness(unbound: true);
    addTearDown(unbound.close);
    unbound.registry.published['tool']!.add('1.2.3');
    unbound.registry.archives['tool@1.2.3'] = _publishedPackage();

    final run = await unbound.run(
      stageOnly: false,
      confirm: (_) async => fail('an exact release needs no authorization'),
    );

    expect(run.code, ExitCodes.ok, reason: run.text);
    expect(run.publicMutations, isEmpty);
    expect(run.text, contains('already released'));
    expect(unbound.stage.inspect().reusable, isFalse);
    expect(
        run.keys, isNot(contains('dart pub publish --to-archive <archive>')));
  });

  test(
      'stage-only seals a reusable receipt after package preflight and never '
      'authorizes or mutates a public target', () async {
    var authorizationPrompts = 0;
    final run = await harness.run(
      stageOnly: true,
      confirm: (_) async {
        authorizationPrompts++;
        return '1.2.3';
      },
    );

    expect(run.code, ExitCodes.ok, reason: run.text);
    final inspected = harness.stage.inspect();
    expect(inspected.reusable, isTrue, reason: inspected.issues.join('\n'));
    expect(inspected.receipt!.complete, isTrue);
    expect(
      inspected.receipt!.steps.map((step) => step.name),
      contains('pub-archive:tool'),
    );
    expect(run.keys, contains('dart pub publish --to-archive <archive>'));
    final packaged = run.invocations.singleWhere(
      (call) => call.arguments.contains('--to-archive'),
    );
    expect(
      packaged.arguments,
      [
        'pub',
        'publish',
        '--to-archive',
        harness.stage.directory.workspace.pathOf(
          ReleaseAssets.pubArchivePath(harness.unit.projects.single),
        ),
      ],
    );
    expect(run.keys, isNot(contains('dart pub login')));
    expect(authorizationPrompts, 0);
    expect(
      run.publicMutations,
      isEmpty,
      reason: 'stage mode may inspect targets, but cannot mutate any of them',
    );
  });

  test(
      'normal release reuses the exact stage without producers or preflight '
      'and publishes from its source snapshot', () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    final receipt =
        File(harness.stage.directory.resolve('stage.json')).readAsStringSync();

    final released = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );

    expect(released.code, ExitCodes.ok, reason: released.text);
    expect(
      released.keys.where((key) => key == 'dart pub login'),
      hasLength(1),
    );
    expect(
      released.keys.where((key) => key.startsWith('dart compile exe')),
      isEmpty,
      reason: 'the completed stage already proves the binary producer',
    );
    expect(released.keys,
        isNot(contains('dart pub publish --to-archive <archive>')));

    final publish = released.invocations.singleWhere(
      (call) => call.arguments.contains('--from-archive'),
    );
    expect(
      publish.arguments,
      [
        'pub',
        'publish',
        '--from-archive',
        harness.stage.directory.workspace.pathOf(
          ReleaseAssets.pubArchivePath(harness.unit.projects.single),
        ),
        '--force',
      ],
    );
    expect(
      publish.workingDirectory,
      '${harness.stage.sourceRoot}/packages/tool',
      reason: 'the registry must receive the reviewed snapshot, not mutable '
          'worktree bytes',
    );
    expect(
      File(harness.stage.directory.resolve('stage.json')).readAsStringSync(),
      receipt,
      reason: 'publishing a reusable stage is read-only with respect to it',
    );
    expect(
      released.publicMutations.map((call) => call.publicKind),
      containsAllInOrder(['tag', 'pub.dev', 'github-release', 'homebrew']),
    );
  });

  test('public acts never borrow the bounded target-read tools', () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);

    final reads = _ForwardingReadTools(harness.tools);
    final released = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
      readTools: reads,
    );

    expect(released.code, ExitCodes.ok, reason: released.text);
    expect(
      reads.invocations.where((call) => call.publicKind != null),
      isEmpty,
      reason: 'read tools may reconcile public truth but cannot mutate it',
    );
    expect(
      reads.invocations.where((call) => call.interactive),
      isEmpty,
      reason: 'login and publish use the operator-facing release tools',
    );
  });

  test(
      'a failed pub session check keeps the exact stage but stops before '
      'authorization or public work', () async {
    harness.tools.failPubLogin = true;
    var authorizationPrompts = 0;

    final refused = await harness.run(
      stageOnly: false,
      confirm: (_) async {
        authorizationPrompts++;
        return '1.2.3';
      },
    );

    expect(refused.code, ExitCodes.refused, reason: refused.text);
    expect(refused.problemCodes, ['RK-PUB-007']);
    expect((refused.report['halt'] as Map?)?['kind'], 'beforeActing');
    expect(refused.keys, contains('dart pub login'));
    expect(refused.keys, contains('dart pub publish --to-archive <archive>'));
    expect(
      refused.keys.where((key) => key.startsWith('dart compile exe')),
      hasLength(1),
    );
    expect(refused.publicMutations, isEmpty);
    expect(
      'not attempted'.allMatches(refused.text).length,
      greaterThanOrEqualTo(4),
    );
    expect(authorizationPrompts, 0);
    expect(harness.stage.inspect().reusable, isTrue,
        reason: 'credentials are acquired only after the exact stage exists');
  });

  test('a second identical stage performs no producer work', () async {
    final first = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(first.code, ExitCodes.ok, reason: first.text);
    final receipt =
        File(harness.stage.directory.resolve('stage.json')).readAsBytesSync();

    final second = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );

    expect(second.code, ExitCodes.ok, reason: second.text);
    expect(
      second.keys.where((key) =>
          key.startsWith('dart compile exe') ||
          key.startsWith('codesign ') ||
          key.startsWith('xcrun notarytool ') ||
          key.startsWith('ditto ')),
      isEmpty,
    );
    expect(second.keys,
        isNot(contains('dart pub publish --to-archive <archive>')));
    expect(
      File(harness.stage.directory.resolve('stage.json')).readAsBytesSync(),
      receipt,
      reason: 'archive, checksum, notes, cask, and manifest producers are '
          'behind the same complete-stage short circuit',
    );
    expect(second.publicMutations, isEmpty);
  });

  test('the staged cask links the public archive name, not its stage path',
      () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);

    final cask = File(harness.stage.directory.resolve(
      ReleaseAssets.caskPath(harness.unit.binaryProject!),
    )).readAsStringSync();
    expect(
      cask,
      contains(
        'releases/download/v1.2.3/tool-1.2.3-linux-x64.tar.gz',
      ),
    );
    expect(cask, isNot(contains('producers/tool/archives')));
  });

  test(
      'a lost GitHub final-publish response reconciles from exact public bytes',
      () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    harness.tools.loseGithubFinalResponse = true;

    final released = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );

    expect(released.code, ExitCodes.ok, reason: released.text);
    expect(released.problemCodes, isEmpty);
    expect(released.text, contains('public target confirmed exact'));
    expect(harness.tools.githubReleaseExists, isTrue);
    expect(harness.tools.githubDraft, isFalse);
  });

  test('a lost tag-push response reconciles from the exact release binding',
      () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    harness.tools.loseTagPushResponse = true;

    final released = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );

    expect(released.code, ExitCodes.ok, reason: released.text);
    expect(released.problemCodes, isEmpty);
    expect(released.text, contains('origin confirmed exact'));
    expect(harness.tools.remoteTags, contains('v1.2.3'));
  });

  test('an unreadable tag readback is lost-track and stops before pub',
      () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    harness.tools.unreadTagAfterPush = true;

    final released = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );

    expect(released.code, ExitCodes.refused);
    expect(released.problemCodes, contains('RK-TAG-003'));
    expect((released.report['halt'] as Map?)?['kind'], 'lostTrack');
    expect(
      released.publicMutations.map((call) => call.publicKind),
      isNot(contains('pub.dev')),
    );
  });

  test('an ambiguous pub response can reconcile after delayed exact bytes',
      () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    harness.tools.losePubPublishResponse = true;
    harness.registry.hideCandidateLookups = 1;

    final released = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );

    expect(released.code, ExitCodes.ok, reason: released.text);
    expect(released.problemCodes, isEmpty);
    expect(released.text, contains('archive matches the staged package'));
    expect(harness.registry.hideCandidateLookups, 0);
  });

  test('a newly pushed tag with the wrong binding is terminal before pub',
      () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    harness.tools.wrongTagBindingAfterPush = true;

    final released = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );

    expect(released.code, ExitCodes.refused);
    expect(released.problemCodes, contains('RK-TAG-004'));
    expect((released.report['halt'] as Map?)?['kind'], 'actedAndUnfixable');
    expect(released.report['rerun_helps'], isFalse);
    expect(
      released.publicMutations.map((call) => call.publicKind),
      isNot(contains('pub.dev')),
    );
  });

  test('a malformed local tag is refused before it can be pushed', () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    harness.git = harness.gitAt(
      tags: const ['v1.2.3'],
      tagObjects: const {'v1.2.3': _tagObject},
      tagTargets: const {'v1.2.3': _head},
    );
    harness.tools
      ..tagManifestSha256 = '0' * 64
      ..wrongTagBinding = true;

    final released = await harness.run(
      stageOnly: false,
      confirm: (_) async => fail('the malformed local tag must block consent'),
    );

    expect(released.code, ExitCodes.refused);
    expect(released.text, contains('local release tag binds a different'));
    expect(released.publicMutations, isEmpty);
  });

  test('a lost Homebrew push response reconciles from exact public bytes',
      () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    harness.tools.loseHomebrewPushResponse = true;

    final released = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );

    expect(released.code, ExitCodes.ok, reason: released.text);
    expect(released.problemCodes, isEmpty);
    expect(released.text, contains('public target confirmed exact'));
    expect(harness.tools.publicCask, isNotNull);
  });

  for (final race in <({String name, List<int> cask})>[
    (
      name: 'hand edit',
      cask: utf8.encode(
        '# Generated by rk.\n'
        '  version "1.2.3"\n'
        '  sha256 "hand-edited"\n',
      ),
    ),
    (
      name: 'newer cask',
      cask: utf8.encode(
        '# Generated by rk.\n'
        '  version "2.0.0"\n'
        '  sha256 "newer"\n',
      ),
    ),
  ]) {
    test('${race.name} appearing between inspect and clone is not overwritten',
        () async {
      final staged = await harness.run(
        stageOnly: true,
        confirm: (_) async => fail('stage mode must not authorize'),
      );
      expect(staged.code, ExitCodes.ok, reason: staged.text);
      harness.tools.caskAtNextClone = race.cask;

      final released = await harness.run(
        stageOnly: false,
        confirm: (_) async => '1.2.3',
      );

      expect(released.code, ExitCodes.refused);
      expect(released.problemCodes, contains('RK-BREW-003'));
      expect(released.text, contains('changed after rk inspected it'));
      expect(harness.tools.publicCask, orderedEquals(race.cask));
      expect(
        released.publicMutations.where(
          (call) => call.publicKind == 'homebrew',
        ),
        isEmpty,
        reason: 'the changed clone must be refused before a tap push',
      );
      expect(
        released.keys.where((key) => key == 'git add Casks/tool.rb'),
        isEmpty,
        reason: 'the changed clone must be refused before git add or push',
      );
    });
  }

  test('rerunning skips every public lane already published', () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    final first = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );
    expect(first.code, ExitCodes.ok, reason: first.text);
    harness.git = harness.gitAt(
      tags: const ['v1.2.3'],
      tagObjects: const {'v1.2.3': _tagObject},
      tagTargets: const {'v1.2.3': _head},
    );

    final rerun = await harness.run(
      stageOnly: false,
      confirm: (_) async => fail('an exact release needs no authorization'),
    );

    expect(rerun.code, ExitCodes.ok, reason: rerun.text);
    expect(rerun.publicMutations, isEmpty);
    expect(rerun.text, contains('already released'));
    final unit = (rerun.report['units'] as List).single as Map;
    final actions = {
      for (final step in (unit['steps'] as List).cast<Map>())
        if (step['public'] == true) step['kind']: step['action'],
    };
    expect(actions, {
      'tag': 'already_published',
      'publishRegistry': 'already_published',
      'publishRelease': 'already_published',
      'publishCask': 'already_published',
    });

    harness.stage.reset();
    final stateless = await harness.run(
      stageOnly: false,
      confirm: (_) async => fail('published coordinates need no authorization'),
    );
    expect(stateless.code, ExitCodes.ok, reason: stateless.text);
    expect(stateless.publicMutations, isEmpty);
    expect(stateless.text, contains('already released'));
    expect(
      harness.stage.inspect().reusable,
      isFalse,
      reason: 'recognizing completed public coordinates must not rebuild '
          'historical artifacts',
    );
  });

  test('authorization growth after an earlier act is stopped partway',
      () async {
    final first = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );
    expect(first.code, ExitCodes.ok, reason: first.text);

    // Start a resumable release with tag and pub.dev absent, while GitHub and
    // Homebrew are initially exact and therefore omitted from consent.
    harness.tools.remoteTags.clear();
    harness.registry.published['tool']!.remove('1.2.3');
    harness.registry.forget('tool');

    final rerun = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
      onInvocation: (call) {
        if (call.publicKind == 'pub.dev') {
          harness.tools.githubReleaseExists = false;
        }
      },
    );

    expect(rerun.code, ExitCodes.refused, reason: rerun.text);
    expect(rerun.problemCodes, contains('RK-AUTH-003'));
    expect((rerun.report['halt'] as Map)['kind'], 'stoppedPartway');
    final github =
        ((rerun.report['units'] as List).single as Map)['steps'] as List;
    expect(
      (github
          .cast<Map>()
          .singleWhere((step) => step['kind'] == 'publishRelease'))['action'],
      'not_attempted',
    );
  });

  test('a partial binary release refuses to rebuild a lost exact stage',
      () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    harness.tools.failPubPublish = true;

    final partial = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );
    expect(partial.code, ExitCodes.refused);
    expect(partial.problemCodes, contains('RK-PUB-003'));
    expect(partial.keys, contains('dart pub login'));
    expect(harness.tools.remoteTags, contains('v1.2.3'));
    expect(
      partial.publicMutations.map((call) => call.publicKind),
      containsAllInOrder(['tag', 'pub.dev']),
    );

    harness.stage.reset();
    harness.git = harness.gitAt(
      tags: const ['v1.2.3'],
      tagObjects: const {'v1.2.3': _tagObject},
      tagTargets: const {'v1.2.3': _head},
    );
    harness.tools.failPubPublish = false;

    final retry = await harness.run(
      stageOnly: false,
      confirm: (_) async => fail('a lost exact stage must block consent'),
    );

    expect(retry.code, ExitCodes.refused);
    expect(retry.problemCodes, contains('RK-STAGE-005'), reason: retry.text);
    expect((retry.report['halt'] as Map?)?['kind'], 'unfixableByRerun');
    expect(retry.report['rerun_helps'], isFalse);
    expect(retry.publicMutations, isEmpty);
    expect(
      retry.keys,
      isNot(contains('dart compile exe')),
      reason: 'rebuilding could create different bytes under the bound tag',
    );
  });

  test('an unread partial binary release also refuses to rebuild a lost stage',
      () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    harness.tools
      ..loseGithubFinalResponse = true
      ..unreadGithubAfterPublish = true;

    final partial = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );
    expect(partial.code, ExitCodes.refused, reason: partial.text);
    expect((partial.report['halt'] as Map?)?['kind'], 'lostTrack');
    expect(harness.tools.remoteTags, contains('v1.2.3'));
    expect(harness.tools.githubReleaseExists, isTrue);

    harness.stage.reset();
    harness.git = harness.gitAt(
      tags: const ['v1.2.3'],
      tagObjects: const {'v1.2.3': _tagObject},
      tagTargets: const {'v1.2.3': _head},
    );
    harness.tools
      ..loseGithubFinalResponse = false
      ..unreadGithubAfterPublish = false;

    final callsBeforeRetry = harness.tools.invocations.length;
    final retry = await harness.run(
      stageOnly: false,
      confirm: (_) async =>
          fail('an unread partial release must block consent'),
    );

    expect(retry.code, ExitCodes.refused, reason: retry.text);
    expect(retry.problemCodes, contains('RK-STAGE-005'), reason: retry.text);
    expect((retry.report['halt'] as Map?)?['kind'], 'unfixableByRerun');
    expect(retry.publicMutations, isEmpty);
    expect(
      harness.tools.invocations.skip(callsBeforeRetry).map((call) => call.key),
      isNot(contains('dart compile exe')),
      reason: 'unknown public state is not permission to replace bound bytes',
    );
  });

  test('a definite private GitHub failure leaves Homebrew unattempted',
      () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    harness.tools.failGithubDraftCreate = true;

    final released = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );

    expect(released.code, ExitCodes.refused);
    expect(released.problemCodes, contains('RK-REL-003'));
    expect((released.report['halt'] as Map?)?['kind'], 'stoppedPartway');
    expect(
      released.publicMutations.map((call) => call.publicKind),
      isNot(contains('homebrew')),
    );
    final unit = (released.report['units'] as List).single as Map;
    final steps = (unit['steps'] as List).cast<Map>();
    final actions = {
      for (final step in steps)
        if (step['public'] == true) step['kind']: step['action'],
    };
    expect(actions, {
      'tag': 'completed',
      'publishRegistry': 'completed',
      'publishRelease': 'failed',
      'publishCask': 'not_attempted',
    });
    expect(released.text, contains('tool 1.2.3 · releasing'));
    expect(released.text, contains('draft failed'));
    expect(released.text, contains('failed'));
    expect(released.text, contains('not attempted'));
  });

  test(
      'a private draft failure is not reported as nothing acted when no public '
      'target changed this run', () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);

    harness.tools.remoteTags.add('v1.2.3');
    harness.registry.published['tool']!.add('1.2.3');
    harness.registry.archives['tool@1.2.3'] = _publishedPackage();
    harness.registry.forget('tool');
    harness.git = harness.gitAt(
      tags: const ['v1.2.3'],
      tagObjects: const {'v1.2.3': _tagObject},
      tagTargets: const {'v1.2.3': _head},
    );
    harness.tools.failGithubUpload = true;

    final released = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );

    expect(released.code, ExitCodes.refused, reason: released.text);
    expect((released.report['halt'] as Map?)?['kind'], 'stoppedPartway');
    expect(released.text, isNot(contains('no public target changed')));
    expect(released.text, contains('GitHub private draft state changed'));
    expect(released.text, contains('did not publish a GitHub Release'));
    expect(
      released.publicMutations,
      isEmpty,
      reason: 'the tag and package were already published, and failed GitHub '
          'transaction changed only private draft state',
    );
  });

  test('retry after a middle-target failure skips exact lanes and resumes',
      () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    harness.tools.failGithubDraftCreate = true;

    final first = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );
    expect(first.code, ExitCodes.refused, reason: first.text);
    expect(
      first.publicMutations.map((call) => call.publicKind),
      containsAllInOrder(['tag', 'pub.dev']),
    );
    expect(harness.stage.inspect().reusable, isTrue);

    harness.tools.failGithubDraftCreate = false;
    harness.git = harness.gitAt(
      tags: const ['v1.2.3'],
      tagObjects: const {'v1.2.3': _tagObject},
      tagTargets: const {'v1.2.3': _head},
    );
    final resumed = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );

    expect(resumed.code, ExitCodes.ok, reason: resumed.text);
    expect(
      resumed.publicMutations.map((call) => call.publicKind),
      containsAllInOrder(['github-release', 'homebrew']),
    );
    expect(
      resumed.publicMutations.map((call) => call.publicKind),
      isNot(contains(anyOf('tag', 'pub.dev'))),
    );
    expect(resumed.keys, isNot(contains('dart pub login')),
        reason: 'pub.dev is already published, so only later targets resume');
    expect(
      resumed.keys.where((key) => key.startsWith('dart compile exe')),
      isEmpty,
      reason: 'the exact retained stage is reused during public recovery',
    );
  });

  test(
      'a lost stage can finish only the Homebrew channel from the public '
      'release', () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    harness.tools.rejectHomebrewPush = true;

    final partial = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );
    expect(partial.code, ExitCodes.refused, reason: partial.text);
    expect(harness.tools.githubReleaseExists, isTrue);
    expect(harness.tools.publicCask, isNull);

    harness.stage.reset();
    final staleCask = utf8.encode('stale local cask');
    harness.stage.directory.workspace.write(
      ReleaseAssets.caskPath(harness.unit.projects.single),
      staleCask,
    );
    harness.git = harness.gitAt(
      tags: const ['v1.2.3'],
      tagObjects: const {'v1.2.3': _tagObject},
      tagTargets: const {'v1.2.3': _head},
    );
    harness.tools.rejectHomebrewPush = false;

    final resumed = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );

    expect(resumed.code, ExitCodes.ok, reason: resumed.text);
    expect(
      resumed.publicMutations.map((call) => call.publicKind),
      ['homebrew'],
    );
    expect(harness.tools.publicCask, isNotNull);
    expect(
      harness.tools.publicCask,
      isNot(staleCask),
      reason: 'authenticated public asset digests outrank leftovers in a '
          'non-reusable stage',
    );
    expect(
      resumed.keys.where((key) => key.startsWith('dart compile exe')),
      isEmpty,
      reason: 'the channel is rendered from authenticated public archive '
          'digests, not rebuilt binaries',
    );
    expect(resumed.keys,
        isNot(contains('dart pub publish --to-archive <archive>')));
    expect(harness.stage.inspect().reusable, isFalse);
  });

  test('lost-stage recovery freezes public asset digests before consent',
      () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    harness.tools.rejectHomebrewPush = true;

    final partial = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );
    expect(partial.code, ExitCodes.refused, reason: partial.text);
    harness.stage.reset();
    harness.git = harness.gitAt(
      tags: const ['v1.2.3'],
      tagObjects: const {'v1.2.3': _tagObject},
      tagTargets: const {'v1.2.3': _head},
    );
    harness.tools.rejectHomebrewPush = false;
    final archive = ReleaseAssets.archiveName('tool', '1.2.3', 'linux-x64');

    final resumed = await harness.run(
      stageOnly: false,
      confirm: (_) async {
        harness.tools.uploadedAssets[archive] = utf8.encode('changed archive');
        return '1.2.3';
      },
    );

    expect(resumed.code, ExitCodes.refused, reason: resumed.text);
    expect(resumed.problemCodes, contains('RK-STAGE-005'));
    expect(
      resumed.publicMutations.map((call) => call.publicKind),
      isNot(contains('homebrew')),
    );
  });

  test('an unreadable GitHub readback remains lost-track', () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    harness.tools
      ..loseGithubFinalResponse = true
      ..unreadGithubAfterPublish = true;

    final released = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );

    expect(released.code, ExitCodes.refused);
    expect(released.problemCodes, contains('RK-REL-003'));
    expect((released.report['halt'] as Map?)?['kind'], 'lostTrack');
    expect(
      released.publicMutations.map((call) => call.publicKind),
      isNot(contains('homebrew')),
    );
  });

  test('an immutable GitHub conflict is terminal', () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    harness.tools.conflictGithubAfterPublish = true;

    final released = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );

    expect(released.code, ExitCodes.refused);
    expect(released.problemCodes, contains('RK-REL-003'));
    expect(
      (released.report['halt'] as Map?)?['kind'],
      'actedAndUnfixable',
    );
    expect(released.report['rerun_helps'], isFalse);
  });

  for (final scenario in [
    (
      name: 'absent after a rejected Homebrew push',
      configure: (_WorldTools tools) => tools.rejectHomebrewPush = true,
      code: 'RK-BREW-001',
      halt: 'stoppedPartway',
    ),
    (
      name: 'unreadable after a Homebrew push',
      configure: (_WorldTools tools) => tools.unreadHomebrewAfterPush = true,
      code: 'RK-BREW-002',
      halt: 'lostTrack',
    ),
    (
      name: 'conflict after a Homebrew push',
      configure: (_WorldTools tools) => tools.conflictHomebrewAfterPush = true,
      code: 'RK-BREW-003',
      halt: 'stoppedPartway',
    ),
  ]) {
    test(scenario.name, () async {
      final staged = await harness.run(
        stageOnly: true,
        confirm: (_) async => fail('stage mode must not authorize'),
      );
      expect(staged.code, ExitCodes.ok, reason: staged.text);
      scenario.configure(harness.tools);

      final released = await harness.run(
        stageOnly: false,
        confirm: (_) async => '1.2.3',
      );

      expect(released.code, ExitCodes.refused);
      expect(released.problemCodes, contains(scenario.code));
      expect((released.report['halt'] as Map?)?['kind'], scenario.halt);
    });
  }

  test(
      'a weaker publishing host can release an exact stage without producing '
      'its platform again', () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);

    final released = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
      capabilities: HostCapabilities(
        hostPlatform: 'macos-arm64',
        containerRuntime: null,
        hasNativeAssets: false,
      ),
    );

    expect(released.code, ExitCodes.ok, reason: released.text);
    expect(
      released.keys.where((key) => key.startsWith('dart compile exe')),
      isEmpty,
    );
    expect(released.keys,
        isNot(contains('dart pub publish --to-archive <archive>')));
    expect(
      released.publicMutations.map((call) => call.publicKind),
      containsAllInOrder(['tag', 'pub.dev', 'github-release', 'homebrew']),
    );
  });

  test(
      'normal release refuses a tampered completed artifact while explicit '
      'stage mode can rebuild it', () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);

    final archive = harness.stage.directory.resolve(
      'producers/tool/archives/'
      '${ReleaseAssets.archiveName('tool', '1.2.3', 'linux-x64')}',
    );
    final original = File(archive).readAsBytesSync();
    File(archive).writeAsStringSync('tampered after review');

    var authorizationPrompts = 0;
    final refused = await harness.run(
      stageOnly: false,
      confirm: (_) async {
        authorizationPrompts++;
        return '1.2.3';
      },
    );

    expect(refused.code, ExitCodes.refused, reason: refused.text);
    expect(refused.problemCodes, contains('RK-STAGE-002'));
    expect(authorizationPrompts, 0);
    expect(
      refused.keys,
      isNot(contains('dart pub login')),
      reason: 'known invalid stage facts refuse before native auth',
    );
    expect(refused.publicMutations, isEmpty);

    final rebuilt = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(rebuilt.code, ExitCodes.ok, reason: rebuilt.text);
    expect(rebuilt.keys, contains('dart pub publish --to-archive <archive>'));
    expect(
      rebuilt.keys.where((key) => key.startsWith('dart compile exe')),
      hasLength(1),
    );
    expect(harness.stage.inspect().reusable, isTrue);
    expect(File(archive).readAsBytesSync(), original);
    expect(rebuilt.publicMutations, isEmpty);
  });

  for (final failure in <({
    String name,
    bool Function(_Invocation) matches,
    String code,
  })>[
    (
      name: 'package preflight',
      matches: (call) => call.key == 'dart pub publish --to-archive <archive>',
      code: 'RK-PUB-001',
    ),
    (
      name: 'binary compile',
      matches: (call) => call.key.startsWith('dart compile exe'),
      code: 'RK-BUILD-001',
    ),
    (
      name: 'binary smoke test',
      matches: (call) =>
          call.arguments.length == 1 &&
          call.arguments.single == '--version' &&
          call.executable.endsWith('/linux-x64/tool'),
      code: 'RK-BUILD-001',
    ),
  ]) {
    test('${failure.name} failure cannot reach a public target', () async {
      harness.tools.runFailure = (call) => failure.matches(call)
          ? ToolResult(
              exitCode: 1,
              stdout: '',
              stderr: failure.name == 'package preflight'
                  ? 'Package has 1 error.'
                  : '${failure.name} failed',
            )
          : null;
      var prompts = 0;

      final failed = await harness.run(
        stageOnly: false,
        confirm: (_) async {
          prompts++;
          return '1.2.3';
        },
      );

      expect(failed.code, ExitCodes.refused, reason: failed.text);
      expect(failed.problemCodes, contains(failure.code));
      expect(failed.text, isNot(contains(failure.code)));
      expect(
        failed.text,
        contains(failure.name == 'package preflight'
            ? 'pub refuses to publish tool'
            : 'did not produce a working binary'),
        reason: 'the human surface keeps the cause while the machine surface '
            'owns its stable code',
      );
      expect(prompts, 0, reason: 'authorization follows complete staging');
      expect(failed.publicMutations, isEmpty);
      expect(harness.stage.inspect().reusable, isFalse);
      expect(failed.text, contains('Release targets'));

      expect(
        'not attempted'.allMatches(failed.text).length,
        greaterThanOrEqualTo(4),
      );
      final unit = (failed.report['units'] as List).single as Map;
      final actions = {
        for (final step in (unit['steps'] as List).cast<Map>())
          if (step['public'] == true) step['kind']: step['action'],
      };
      expect(actions.values.toSet(), {'not_attempted'});

      harness.tools.runFailure = null;
      final recovered = await harness.run(
        stageOnly: true,
        confirm: (_) async => fail('stage mode must not authorize'),
      );
      expect(recovered.code, ExitCodes.ok, reason: recovered.text);
      expect(harness.stage.inspect().reusable, isTrue);
      expect(recovered.publicMutations, isEmpty);
    });
  }

  test(
      'a missing GitHub session refuses after staging and before authorization',
      () async {
    harness.tools.runFailure =
        (call) => call.key == 'gh auth status --active --hostname github.com'
            ? ToolResult(
                exitCode: 1,
                stdout: '',
                stderr: 'expired credential details that must stay private',
              )
            : null;
    var authorizationPrompts = 0;

    final failed = await harness.run(
      stageOnly: false,
      confirm: (_) async {
        authorizationPrompts++;
        return '1.2.3';
      },
    );

    expect(failed.code, ExitCodes.refused, reason: failed.text);
    expect(failed.problemCodes, contains('RK-GITHUB-010'));
    expect(
      failed.keys,
      contains('gh auth status --active --hostname github.com'),
    );
    expect(failed.keys, contains('dart pub publish --to-archive <archive>'));
    expect(harness.stage.inspect().reusable, isTrue);
    expect(authorizationPrompts, 0);
    expect(failed.publicMutations, isEmpty);
    expect(failed.text, isNot(contains('expired credential details')));
  });

  test('an SDK without native Pub archive staging refuses clearly', () async {
    harness.tools.runFailure = (call) => call.arguments.contains('--to-archive')
        ? ToolResult(
            exitCode: 64,
            stdout: '',
            stderr: 'Could not find an option named "to-archive".',
          )
        : null;

    final run = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );

    expect(run.code, ExitCodes.refused, reason: run.text);
    expect(run.problemCodes, contains('RK-PUB-011'));
    expect(run.publicMutations, isEmpty);
  });

  test('Pub success without its promised archive refuses clearly', () async {
    harness.tools.runFailure =
        (call) => call.arguments.contains('--to-archive') ? _ok() : null;

    final run = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );

    expect(run.code, ExitCodes.refused, reason: run.text);
    expect(run.problemCodes, contains('RK-PUB-011'));
    expect(run.publicMutations, isEmpty);
  });

  test('an SDK without native Pub archive publication refuses clearly',
      () async {
    harness.tools.failPubArchiveCapability = true;
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);

    final run = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
    );

    expect(run.code, ExitCodes.refused, reason: run.text);
    expect(run.problemCodes, contains('RK-PUB-011'));
  });

  for (final failure in [
    (name: 'release-note write', path: 'release-notes.md'),
    (
      name: 'archive write',
      path: 'producers/tool/archives/tool-1.2.3-linux-x64.tar.gz',
    ),
    (
      name: 'cask write',
      path: 'producers/tool/homebrew/tool.rb',
    ),
    (name: 'manifest write', path: ReleaseAssets.manifest),
  ]) {
    test('${failure.name} refuses cleanly before every public target',
        () async {
      var planted = false;
      var prompts = 0;

      final failed = await harness.run(
        stageOnly: false,
        confirm: (_) async {
          prompts++;
          return '1.2.3';
        },
        onInvocation: (call) {
          if (planted ||
              call.key != 'dart pub publish --to-archive <archive>') {
            return;
          }
          Directory(harness.stage.directory.resolve(failure.path))
              .createSync(recursive: true);
          planted = true;
        },
      );

      expect(planted, isTrue);
      expect(failed.code, ExitCodes.refused, reason: failed.text);
      expect(failed.problemCodes, contains('RK-STAGE-003'));
      expect(failed.problemCodes, isNot(contains('RK-INT-001')));
      expect(prompts, 0, reason: 'authorization follows complete staging');
      expect(failed.publicMutations, isEmpty);
      expect(harness.stage.inspect().reusable, isFalse);
      expect(failed.text, contains('Release targets'));

      expect(
        'not attempted'.allMatches(failed.text).length,
        greaterThanOrEqualTo(4),
      );

      Directory(harness.stage.directory.resolve(failure.path)).deleteSync();
      final recovered = await harness.run(
        stageOnly: true,
        confirm: (_) async => fail('stage mode must not authorize'),
      );
      expect(recovered.code, ExitCodes.ok, reason: recovered.text);
      expect(harness.stage.inspect().reusable, isTrue);
      expect(recovered.publicMutations, isEmpty);
    });
  }

  for (final boundary in [
    (step: 'source-snapshot', preflightDone: false, buildDone: false),
    (step: 'pub-archive:tool', preflightDone: true, buildDone: false),
    (step: 'release-notes', preflightDone: true, buildDone: false),
    (step: 'build:tool:linux-x64', preflightDone: true, buildDone: true),
    (step: 'archive:tool:linux-x64', preflightDone: true, buildDone: true),
    (step: 'homebrew-cask:tool', preflightDone: true, buildDone: true),
  ]) {
    test('an interrupted ${boundary.step} prefix resumes from exact bytes',
        () async {
      final first = await harness.run(
        stageOnly: true,
        confirm: (_) async => fail('stage mode must not authorize'),
      );
      expect(first.code, ExitCodes.ok, reason: first.text);
      _interruptAfter(harness.stage, boundary.step);
      final before = harness.stage.inspect();
      expect(before.validProgress, isTrue, reason: before.issues.join('\n'));
      final retained = {
        for (final artifact in before.receipt!.artifacts)
          artifact.path: File(harness.stage.directory.resolve(artifact.path))
              .readAsBytesSync(),
      };

      final resumed = await harness.run(
        stageOnly: true,
        confirm: (_) async => fail('stage mode must not authorize'),
      );

      expect(resumed.code, ExitCodes.ok, reason: resumed.text);
      if (boundary.preflightDone) {
        expect(resumed.keys,
            isNot(contains('dart pub publish --to-archive <archive>')));
      }
      if (boundary.buildDone) {
        expect(
          resumed.keys.where((key) => key.startsWith('dart compile exe')),
          isEmpty,
          reason: 'the exact recorded binary dependency is reused',
        );
      }
      for (final entry in retained.entries) {
        expect(
          File(harness.stage.directory.resolve(entry.key)).readAsBytesSync(),
          entry.value,
          reason: '${boundary.step} retained ${entry.key}',
        );
      }
      expect(harness.stage.inspect().reusable, isTrue);
      expect(resumed.publicMutations, isEmpty);
    });
  }

  test('a changed dependency in an interrupted prefix is rebuilt, not reused',
      () async {
    final first = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(first.code, ExitCodes.ok, reason: first.text);
    _interruptAfter(harness.stage, 'build:tool:linux-x64');
    File(harness.stage.directory.resolve('producers/tool/linux-x64/tool'))
        .writeAsStringSync('planted binary');
    expect(harness.stage.inspect().validProgress, isFalse);

    final rebuilt = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );

    expect(rebuilt.code, ExitCodes.ok, reason: rebuilt.text);
    expect(
      rebuilt.keys.where((key) => key.startsWith('dart compile exe')),
      hasLength(1),
    );
    expect(rebuilt.keys, contains('dart pub publish --to-archive <archive>'));
    expect(harness.stage.inspect().reusable, isTrue);
  });

  test('a complete receipt cannot omit its package preflight', () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    final receipt = harness.stage.requireReceipt();
    StageReceiptStore(harness.stage.directory).write(StageReceipt(
      identity: receipt.identity,
      steps: receipt.steps.where((step) => step.name != 'pub-archive:tool'),
    ));

    final inspected = harness.stage.inspect();
    expect(inspected.reusable, isFalse);
    expect(
      inspected.issues.map((issue) => issue.kind),
      contains(StageIssueKind.invalidStructure),
    );
  });

  test('a digest-consistent receipt cannot rename a required producer',
      () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    final receipt = harness.stage.requireReceipt();
    final build = receipt.steps.singleWhere(
      (step) => step.name == 'build:tool:linux-x64',
    );
    final renamed = StageStep(
      name: 'compiled-something',
      inputs: build.inputs,
      outputs: build.outputs,
      evidence: build.evidence,
    );
    StageReceiptStore(harness.stage.directory).write(StageReceipt(
      identity: receipt.identity,
      steps: [
        for (final step in receipt.steps)
          if (step.name == build.name) renamed else step,
      ],
    ));

    final inspected = harness.stage.inspect();
    expect(inspected.reusable, isFalse);
    expect(
      inspected.issues.map((issue) => issue.kind),
      contains(StageIssueKind.invalidStructure),
    );
  });

  test(
      'a finalized receipt whose terminal step was displaced still refuses '
      'silent replacement', () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    final receipt = harness.stage.requireReceipt();
    final steps = [...receipt.steps];
    final terminal = steps.removeLast();
    expect(terminal.name, 'complete-stage');
    steps.insert(steps.length - 1, terminal);
    StageReceiptStore(harness.stage.directory)
        .write(StageReceipt(identity: receipt.identity, steps: steps));

    final released = await harness.run(
      stageOnly: false,
      confirm: (_) async => fail('a damaged reviewed stage must refuse '
          'before authorization'),
    );

    expect(released.code, ExitCodes.refused, reason: released.text);
    expect(released.problemCodes, contains('RK-STAGE-002'));
    expect(
      harness.stage.inspect().receipt,
      isNotNull,
      reason: 'the reviewed bytes were kept for the operator, not reset',
    );
    expect(
      released.keys.where((key) => key.startsWith('dart compile exe')),
      isEmpty,
      reason: 'a reviewed stage is never silently rebuilt',
    );
  });

  test('a digest-consistent receipt cannot invent smoke evidence', () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    final receipt = harness.stage.requireReceipt();
    final build = receipt.steps.singleWhere(
      (step) => step.name == 'build:tool:linux-x64',
    );
    final noSmoke = StageStep(
      name: build.name,
      inputs: build.inputs,
      outputs: build.outputs,
    );
    StageReceiptStore(harness.stage.directory).write(StageReceipt(
      identity: receipt.identity,
      steps: [
        for (final step in receipt.steps)
          if (step.name == build.name) noSmoke else step,
      ],
    ));

    final inspected = harness.stage.inspect();
    expect(inspected.reusable, isFalse);
    expect(
      inspected.issues.map((issue) => issue.toString()),
      contains(contains('invalid smoke-test evidence')),
    );
  });

  test('stage tampering during refreshed target reads is caught before consent',
      () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    var releaseReads = 0;
    var prompts = 0;
    final archive = harness.stage.directory.resolve(
      ReleaseAssets.archiveName('tool', '1.2.3', 'linux-x64'),
    );

    final refused = await harness.run(
      stageOnly: false,
      confirm: (_) async {
        prompts++;
        return '1.2.3';
      },
      onInvocation: (call) {
        if (call.executable == 'gh' &&
            _starts(call.arguments, [
              'api',
              'repos/example/tool/releases/tags/',
            ])) {
          releaseReads++;
          if (releaseReads == 2) {
            File(archive).writeAsStringSync('changed before consent');
          }
        }
      },
    );

    expect(refused.code, ExitCodes.refused, reason: refused.text);
    expect(refused.problemCodes, contains('RK-STAGE-002'));
    expect(prompts, 0);
    expect(refused.publicMutations, isEmpty);
  });

  test('stage tampering at the authorization prompt blocks the first act',
      () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    final archive = harness.stage.directory.resolve(
      ReleaseAssets.archiveName('tool', '1.2.3', 'linux-x64'),
    );
    var prompts = 0;

    final refused = await harness.run(
      stageOnly: false,
      confirm: (_) async {
        prompts++;
        File(archive).writeAsStringSync('changed while consent waited');
        return '1.2.3';
      },
    );

    expect(refused.code, ExitCodes.refused, reason: refused.text);
    expect(prompts, 1);
    expect(refused.problemCodes, contains('RK-STAGE-002'));
    expect(refused.publicMutations, isEmpty);
  });

  test('stage tampering after one target blocks the next public act', () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);
    final archive = harness.stage.directory.resolve(
      ReleaseAssets.archiveName('tool', '1.2.3', 'linux-x64'),
    );

    final refused = await harness.run(
      stageOnly: false,
      confirm: (_) async => '1.2.3',
      onRegistryRead: () {
        if (harness.tools.remoteTags.contains('v1.2.3')) {
          File(archive).writeAsStringSync('changed after the tag');
        }
      },
    );

    expect(refused.code, ExitCodes.refused, reason: refused.text);
    expect(refused.problemCodes, contains('RK-STAGE-002'));
    expect(
      refused.publicMutations.map((call) => call.publicKind).toSet(),
      {'tag'},
      reason: 'the already-pushed tag remains real, but pub.dev and every '
          'later destination are untouched',
    );
    expect(refused.keys,
        isNot(contains('dart pub publish --from-archive <archive> --force')));
  });

  test('a refreshed HEAD commit drift refuses before consent or public acts',
      () async {
    await _expectRefreshDriftRefused(
      harness,
      harness.gitAt(head: _otherHead),
    );
  });

  test('a refreshed HEAD tree drift refuses before consent or public acts',
      () async {
    await _expectRefreshDriftRefused(
      harness,
      harness.gitAt(headTree: _otherTree),
    );
  });

  test('a newly dirty worktree refuses before consent or public acts',
      () async {
    await _expectRefreshDriftRefused(
      harness,
      harness.gitAt(isClean: false),
    );
  });

  test('a HEAD no longer present on origin refuses before public acts',
      () async {
    await _expectRefreshDriftRefused(
      harness,
      harness.gitAt(headIsPushed: false),
    );
  });

  test('an origin change refuses before consent or public acts', () async {
    await _expectRefreshDriftRefused(
      harness,
      harness.gitAt(originUrl: 'other/tool'),
    );
  });

  test('a tag-signing policy change refuses before consent or public acts',
      () async {
    await _expectRefreshDriftRefused(
      harness,
      harness.gitAt(signingConfigured: true),
    );
  });

  test('a changed compiler plan refuses before consent or public acts',
      () async {
    final staged = await harness.run(
      stageOnly: true,
      confirm: (_) async => fail('stage mode must not authorize'),
    );
    expect(staged.code, ExitCodes.ok, reason: staged.text);

    var authorizationPrompts = 0;
    final drifted = await harness.run(
      stageOnly: false,
      refreshStage: (unit, currentGit) => ReleaseStages(
        source: harness.source,
        git: currentGit,
        stageContracts:
            TargetCatalog.builtIn().stageContractResolver(harness.resolution),
        repositoryRoot: harness.root.path,
        compilerIdentity: () => DartCompilerIdentity.recorded(
          executable: '/different/dart',
          version: 'different Dart compiler',
          sha256: 'd' * 64,
        ),
      ).call(unit),
      confirm: (_) async {
        authorizationPrompts++;
        return '1.2.3';
      },
    );

    expect(drifted.code, ExitCodes.refused, reason: drifted.text);
    expect(drifted.problemCodes, contains('RK-STAGE-004'));
    expect(authorizationPrompts, 0);
    expect(drifted.publicMutations, isEmpty);
  });

  test('stage-only refuses if its compiler plan changed while building',
      () async {
    final drifted = await harness.run(
      stageOnly: true,
      refreshStage: (unit, currentGit) => ReleaseStages(
        source: harness.source,
        git: currentGit,
        stageContracts:
            TargetCatalog.builtIn().stageContractResolver(harness.resolution),
        repositoryRoot: harness.root.path,
        compilerIdentity: () => DartCompilerIdentity.recorded(
          executable: '/different/dart',
          version: 'different Dart compiler',
          sha256: 'd' * 64,
        ),
      ).call(unit),
      confirm: (_) async => fail('stage mode must not authorize'),
    );

    expect(drifted.code, ExitCodes.refused, reason: drifted.text);
    expect(drifted.problemCodes, contains('RK-STAGE-004'));
    expect(drifted.publicMutations, isEmpty);
    expect(drifted.text, isNot(contains('tool 1.2.3 staged')));
  });
}

Future<void> _expectRefreshDriftRefused(
  _Harness harness,
  GitState refreshed,
) async {
  final staged = await harness.run(
    stageOnly: true,
    confirm: (_) async => fail('stage mode must not authorize'),
  );
  expect(staged.code, ExitCodes.ok, reason: staged.text);

  var authorizationPrompts = 0;
  final drifted = await harness.run(
    stageOnly: false,
    refreshGit: () => refreshed,
    confirm: (_) async {
      authorizationPrompts++;
      return '1.2.3';
    },
  );

  expect(drifted.code, ExitCodes.refused, reason: drifted.text);
  expect(drifted.problemCodes, contains('RK-STAGE-004'));
  expect(authorizationPrompts, 0);
  expect(drifted.publicMutations, isEmpty);
}

void _interruptAfter(ReleaseStage stage, String stepName) {
  final complete = stage.requireReceipt();
  final through = complete.steps.indexWhere((step) => step.name == stepName);
  if (through < 0) fail('fixture receipt has no $stepName');
  final kept = complete.steps.take(through + 1).toList();
  final keptPaths =
      kept.expand((step) => step.outputs).map((a) => a.path).toSet();
  for (final artifact in complete.artifacts) {
    if (keptPaths.contains(artifact.path)) continue;
    final file = File(stage.directory.resolve(artifact.path));
    if (file.existsSync()) file.deleteSync();
  }
  final directories = Directory(stage.directory.path)
      .listSync(recursive: true, followLinks: false)
      .whereType<Directory>()
      .toList()
    ..sort((left, right) => right.path.length.compareTo(left.path.length));
  for (final directory in directories) {
    if (directory.listSync(followLinks: false).isEmpty) directory.deleteSync();
  }
  StageReceiptStore(stage.directory).write(StageReceipt(
    identity: complete.identity,
    steps: kept,
  ));
}

class _Harness {
  _Harness({bool unbound = false, bool localBinaryOnly = false}) {
    root = Directory.systemTemp.createTempSync('rk-stage-command-');
    final config = localBinaryOnly
        ? _localBinaryConfig
        : unbound
            ? _pubOnlyConfig
            : _config;
    source = MemorySourceTree({
      'release.toml': config,
      'packages/tool/pubspec.yaml': _pubspec,
      'packages/tool/CHANGELOG.md': _changelog,
      'packages/tool/bin/tool.dart': _entrypoint,
      'packages/tool/README.md': '# Tool\n',
    }, description: '${root.path}/worktree');

    final diagnostics = Diagnostics();
    final parsed = ReleaseConfig.parse(config, 'release.toml', diagnostics);
    if (parsed == null) {
      throw StateError('fixture configuration failed: ${diagnostics.found}');
    }
    final resolved = Resolution.resolve(parsed, source, diagnostics);
    if (resolved == null) {
      throw StateError('fixture resolution failed: ${diagnostics.found}');
    }
    resolution = resolved;
    unit = resolution.unit('tool')!;
    git = unbound ? GitState.unbound(root.path) : gitAt();
    stages = ReleaseStages(
      source: source,
      git: git,
      stageContracts: TargetCatalog.builtIn().stageContractResolver(resolution),
      repositoryRoot: root.path,
    );
    registry = _ReleaseRegistry({
      'tool': ['1.0.0'],
    });
    tools = _WorldTools(
      registry: registry,
      stageFor: () => stage,
    );
  }

  late final Directory root;
  late final MemorySourceTree source;
  late final Resolution resolution;
  late final ResolvedUnit unit;
  late GitState git;
  late final ReleaseStages stages;
  late final _ReleaseRegistry registry;
  late final _WorldTools tools;

  ReleaseStage get stage => stages(unit);

  GitState gitAt({
    String head = _head,
    String headTree = _headTree,
    bool isClean = true,
    List<String> uncommitted = const [],
    bool headIsPushed = true,
    bool signingConfigured = false,
    String? originUrl = 'example/tool',
    List<String> tags = const [],
    Map<String, String> tagObjects = const {},
    Map<String, String> tagTargets = const {},
  }) =>
      GitState(
        root: root.path,
        head: head,
        headTree: headTree,
        branch: 'main',
        isClean: isClean,
        uncommitted: uncommitted,
        headIsPushed: headIsPushed,
        tags: tags,
        tagObjects: tagObjects,
        tagTargets: tagTargets,
        signingConfigured: signingConfigured,
        originUrl: originUrl,
      );

  Future<_Run> run({
    required bool stageOnly,
    required Future<String?> Function(String prompt)? confirm,
    GitState Function()? refreshGit,
    ReleaseStage Function(ResolvedUnit unit, GitState git)? refreshStage,
    HostCapabilities? capabilities,
    void Function(_Invocation call)? onInvocation,
    void Function()? onRegistryRead,
    Tools? readTools,
    GitState? repositoryGit,
    Diagnostic? sourceWarning,
  }) async {
    final start = tools.invocations.length;
    final buffer = StringBuffer();
    final output = Output(
      sink: buffer.write,
      isTerminal: false,
      useColor: false,
    );
    final runRegistry = onRegistryRead == null
        ? registry
        : _ObservedRegistry(registry, onRegistryRead);
    final inspector = Inspector(
      registry: runRegistry,
      pubDev: PubDevTarget(
        registry: runRegistry,
      ),
      git: git,
      tools: readTools ?? tools,
      repository: git.originUrl,
      stageFor: stages.call,
    );
    tools.onInvocation = onInvocation;
    final command = ReleaseCommand(
      resolution: resolution,
      tree: source,
      git: git,
      repositoryGit: repositoryGit,
      sourceWarning: sourceWarning,
      inspector: inspector,
      tools: tools,
      output: output,
      // Most of this long-lived safety suite predates ordinary yes/no and
      // returns the fixture version after performing its prompt-time hook.
      // Preserve those hooks while adapting the old fixture answer at this
      // single boundary.
      confirm: confirm == null
          ? null
          : (prompt) async {
              final answer = await confirm(prompt);
              return answer == '1.2.3' ? 'yes' : answer;
            },
      stageOnly: stageOnly,
      stageFor: stages.call,
      refreshStage: refreshStage ?? stages.refresh,
      refreshGit: refreshGit ?? () => git,
      wait: (_) => Future<void>.delayed(Duration.zero),
      capabilities: capabilities ??
          HostCapabilities(
            hostPlatform: 'linux-x64',
            containerRuntime: null,
            hasNativeAssets: false,
          ),
    );
    final code = await command.run(only: 'tool');
    tools.onInvocation = null;
    return _Run(
      code: code,
      text: buffer.toString(),
      invocations: tools.invocations.sublist(start),
      report:
          jsonDecode(output.report.encode(exit: code)) as Map<String, Object?>,
    );
  }

  void close() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

class _ObservedRegistry implements RegistryReader {
  _ObservedRegistry(this.delegate, this.onRead);

  final RegistryReader delegate;
  final void Function() onRead;

  @override
  Future<RegistryPackage?> lookup(String name) {
    onRead();
    return delegate.lookup(name);
  }

  @override
  void forget(String name) => delegate.forget(name);
}

class _Run {
  const _Run({
    required this.code,
    required this.text,
    required this.invocations,
    required this.report,
  });

  final int code;
  final String text;
  final List<_Invocation> invocations;
  final Map<String, Object?> report;

  List<String> get keys => [for (final call in invocations) call.key];

  List<_Invocation> get publicMutations =>
      invocations.where((call) => call.publicKind != null).toList();

  List<String> get problemCodes => [
        for (final problem in (report['problems'] as List? ?? const []))
          '${(problem as Map)['code']}',
      ];

  List<String> get warningCodes => [
        for (final warning in (report['warnings'] as List? ?? const []))
          '${(warning as Map)['code']}',
      ];
}

class _Invocation {
  const _Invocation({
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
    required this.interactive,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final bool interactive;

  String get key {
    if (_isDart(executable) && _starts(arguments, ['pub', 'publish'])) {
      if (arguments.contains('--to-archive')) {
        return 'dart pub publish --to-archive <archive>';
      }
      if (arguments.contains('--from-archive')) {
        return 'dart pub publish --from-archive <archive> --force';
      }
    }
    return '${_isDart(executable) ? 'dart' : executable} '
        '${arguments.join(' ')}';
  }

  String? get publicKind {
    if (executable == 'git' && arguments.firstOrNull == 'tag') return 'tag';
    if (executable == 'git' &&
        arguments.length >= 3 &&
        arguments[0] == 'push' &&
        arguments[1] == 'origin') {
      return 'tag';
    }
    if (interactive &&
        _isDart(executable) &&
        _starts(arguments, ['pub', 'publish']) &&
        arguments.contains('--from-archive')) {
      return 'pub.dev';
    }
    if (executable == 'gh' &&
        arguments.length >= 2 &&
        arguments[0] == 'api' &&
        arguments.contains('PATCH') &&
        arguments
            .any((argument) => argument == 'repos/example/tool/releases/7')) {
      return 'github-release';
    }
    if (executable == 'gh' && arguments.contains('DELETE')) {
      return 'github-release';
    }
    if (executable == 'git' &&
        arguments.length == 1 &&
        arguments.single == 'push') {
      return 'homebrew';
    }
    return null;
  }
}

class _ForwardingReadTools implements Tools {
  _ForwardingReadTools(this.delegate);

  final Tools delegate;
  final List<_Invocation> invocations = [];

  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    invocations.add(_Invocation(
      executable: executable,
      arguments: List.unmodifiable(arguments),
      workingDirectory: workingDirectory,
      interactive: false,
    ));
    return delegate.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
  }

  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) {
    invocations.add(_Invocation(
      executable: executable,
      arguments: List.unmodifiable(arguments),
      workingDirectory: workingDirectory,
      interactive: true,
    ));
    return delegate.runInteractive(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
  }
}

class _ReleaseRegistry extends FakeRegistry {
  _ReleaseRegistry(super.published);

  int hideCandidateLookups = 0;

  @override
  Future<RegistryPackage?> lookup(String name) async {
    final versions = published[name];
    final index = versions?.indexOf('1.2.3') ?? -1;
    if (hideCandidateLookups <= 0 || versions == null || index < 0) {
      return super.lookup(name);
    }

    hideCandidateLookups--;
    final hidden = versions.removeAt(index);
    super.forget(name);
    try {
      return await super.lookup(name);
    } finally {
      versions.insert(index, hidden);
      super.forget(name);
    }
  }
}

class _WorldTools implements Tools {
  _WorldTools({
    required this.registry,
    required this.stageFor,
  });

  final FakeRegistry registry;
  final ReleaseStage Function() stageFor;
  final List<_Invocation> invocations = [];
  final Set<String> remoteTags = {};
  final Map<String, List<int>> uploadedAssets = {};
  void Function(_Invocation call)? onInvocation;
  ToolResult? Function(_Invocation call)? runFailure;

  bool githubReleaseExists = false;
  bool githubDraft = false;
  bool loseGithubFinalResponse = false;
  bool _loseGithubReadByIdOnce = false;
  bool failGithubDraftCreate = false;
  bool failGithubUpload = false;
  bool unreadGithubAfterPublish = false;
  bool conflictGithubAfterPublish = false;
  bool loseTagPushResponse = false;
  bool unreadTagAfterPush = false;
  bool wrongTagBinding = false;
  bool wrongTagBindingAfterPush = false;
  bool loseHomebrewPushResponse = false;
  bool rejectHomebrewPush = false;
  bool unreadHomebrewAfterPush = false;
  bool conflictHomebrewAfterPush = false;
  List<int>? caskAtNextClone;
  bool failPubPublish = false;
  bool failPubArchiveCapability = false;
  bool failPubLogin = false;
  bool losePubPublishResponse = false;
  bool _githubPublicUnreadable = false;
  bool _tagPublicUnreadable = false;
  bool _homebrewPublicUnreadable = false;
  String? githubTitle;
  String? githubBody;
  String? tagManifestSha256;
  List<int>? publicCask;

  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final invocation = _Invocation(
      executable: executable,
      arguments: List.unmodifiable(arguments),
      workingDirectory: workingDirectory,
      interactive: false,
    );
    invocations.add(invocation);
    onInvocation?.call(invocation);
    final failure = runFailure?.call(invocation);
    if (failure != null) return failure;

    if (_isDart(executable) && _starts(arguments, ['compile', 'exe'])) {
      final output = arguments[arguments.indexOf('-o') + 1];
      File(output)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(utf8.encode('BINARY tool 1.2.3'));
      return _ok();
    }
    if (_isDart(executable) &&
        _starts(arguments, ['pub', 'publish']) &&
        arguments.contains('--to-archive')) {
      final output = arguments[arguments.indexOf('--to-archive') + 1];
      File(output)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(_publishedPackage());
      return _ok();
    }
    if (arguments.length == 1 &&
        arguments.single == '--version' &&
        executable.endsWith('/linux-x64/tool')) {
      return _ok(stdout: 'tool 1.2.3\n');
    }

    if (executable == 'git' &&
        arguments.firstOrNull == 'tag' &&
        arguments.contains('-m')) {
      final message = arguments[arguments.indexOf('-m') + 1];
      tagManifestSha256 = RegExp(
        r'release-manifest-sha256: ([0-9a-f]{64})',
      ).firstMatch(message)?.group(1);
      return _ok();
    }

    if (executable == 'git' &&
        _starts(arguments, ['ls-remote', '--tags', 'origin'])) {
      if (_tagPublicUnreadable) {
        return ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: 'origin could not be reached',
        );
      }
      return _ok(
        stdout: [
          for (final tag in remoteTags) ...[
            '$_tagObject\trefs/tags/$tag',
            '$_head\trefs/tags/$tag^{}',
          ],
        ].join('\n'),
      );
    }
    if (executable == 'git' && arguments.firstOrNull == 'ls-remote') {
      if (_tagPublicUnreadable) {
        return ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: 'origin could not be reached',
        );
      }
      final ref = arguments[2];
      final tag = ref.substring('refs/tags/'.length);
      if (!remoteTags.contains(tag)) return _ok();
      final direct = '$_tagObject\trefs/tags/$tag';
      if (arguments.length == 3) return _ok(stdout: '$direct\n');
      return _ok(stdout: '$direct\n$_head\trefs/tags/$tag^{}\n');
    }
    if (executable == 'git' &&
        arguments.length == 3 &&
        arguments[0] == 'rev-parse' &&
        arguments[1] == '--verify' &&
        arguments[2].endsWith('^{tag}')) {
      return _ok(stdout: '$_tagObject\n');
    }
    if (executable == 'git' &&
        arguments.length == 3 &&
        arguments[0] == 'cat-file' &&
        arguments[1] == 'tag' &&
        arguments[2] == _tagObject) {
      final digest = wrongTagBinding ||
              (wrongTagBindingAfterPush && remoteTags.contains('v1.2.3'))
          ? '0' * 64
          : tagManifestSha256 ??
              stageFor()
                  .requireReceipt()
                  .artifacts
                  .singleWhere(
                    (artifact) => artifact.path == ReleaseAssets.manifest,
                  )
                  .sha256;
      return _ok(
        stdout: 'object $_head\n'
            'type commit\n'
            'tag v1.2.3\n'
            'tagger Release Kit <rk@example.invalid> 0 +0000\n'
            '\n'
            'tool 1.2.3\n'
            '\n'
            'release-manifest-sha256: $digest\n',
      );
    }
    if (executable == 'git' &&
        arguments.length >= 3 &&
        arguments[0] == 'push' &&
        arguments[1] == 'origin') {
      const marker = ':refs/tags/';
      final refspec = arguments[2];
      if (refspec.contains(marker)) {
        remoteTags.add(refspec.split(marker).last);
      }
      if (unreadTagAfterPush) _tagPublicUnreadable = true;
      if (loseTagPushResponse) {
        return ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: 'connection closed before the response',
        );
      }
      return _ok();
    }

    if (executable == 'gh' &&
        _starts(arguments, ['api', 'repos/example/tool/releases/tags/'])) {
      if (_githubPublicUnreadable) {
        return ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: 'GitHub could not be reached',
        );
      }
      return _githubReleaseView();
    }
    if (executable == 'gh' &&
        arguments.join(' ') ==
            'api --paginate --slurp repos/example/tool/releases') {
      return _ok(
        stdout: jsonEncode([
          [if (githubReleaseExists) _githubReleaseJson()],
        ]),
      );
    }
    if (executable == 'gh' &&
        _starts(arguments, [
          'api',
          '-X',
          'POST',
          'repos/example/tool/releases',
        ])) {
      if (failGithubDraftCreate) {
        return ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: 'draft creation was rejected',
        );
      }
      final input = File(arguments[arguments.indexOf('--input') + 1]);
      final request = jsonDecode(input.readAsStringSync()) as Map;
      uploadedAssets.clear();
      githubTitle = request['name'] as String?;
      githubBody = request['body'] as String?;
      githubReleaseExists = true;
      githubDraft = true;
      return _ok(stdout: jsonEncode(_githubReleaseJson()));
    }
    if (executable == 'gh' &&
        arguments.any((argument) => argument.contains('uploads.github.com')) &&
        arguments.any((argument) => argument.startsWith(
              'https://uploads.github.com/repos/example/tool/releases/7/'
              'assets?name=',
            ))) {
      final coordinate = arguments.singleWhere(
        (argument) => argument.startsWith(
          'https://uploads.github.com/repos/example/tool/releases/7/'
          'assets?name=',
        ),
      );
      if (failGithubUpload) {
        return ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: 'upload connection lost',
        );
      }
      final name = Uri.decodeQueryComponent(coordinate.split('?name=').last);
      final input = File(arguments[arguments.indexOf('--input') + 1]);
      uploadedAssets[name] = input.readAsBytesSync();
      return _ok(stdout: '{}');
    }
    if (executable == 'gh' &&
        arguments.join(' ') == 'api repos/example/tool/releases/7') {
      if (_loseGithubReadByIdOnce) {
        _loseGithubReadByIdOnce = false;
        return ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: 'connection closed before the response',
        );
      }
      return githubReleaseExists
          ? _ok(stdout: jsonEncode(_githubReleaseJson()))
          : _notFound();
    }
    if (executable == 'gh' &&
        _starts(arguments, [
          'api',
          '-X',
          'PATCH',
          'repos/example/tool/releases/7',
        ])) {
      githubDraft = false;
      if (conflictGithubAfterPublish) githubTitle = 'wrong public title';
      if (loseGithubFinalResponse) {
        _loseGithubReadByIdOnce = true;
        if (unreadGithubAfterPublish) _githubPublicUnreadable = true;
        return ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: 'connection closed before the response',
        );
      }
      return _githubReleaseView();
    }
    if (executable == 'gh' &&
        _starts(arguments, ['release', 'download', 'v1.2.3'])) {
      final name = arguments[arguments.indexOf('--pattern') + 1];
      final output = arguments[arguments.indexOf('--output') + 1];
      File(output)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(uploadedAssets[name]!);
      return _ok();
    }

    if (executable == 'gh' &&
        _starts(
          arguments,
          ['api', 'repos/example/homebrew-tap/contents/Casks/tool.rb'],
        )) {
      if (_homebrewPublicUnreadable) {
        return ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: 'the tap could not be reached',
        );
      }
      final cask = publicCask;
      return cask == null
          ? _notFound()
          : _ok(stdout: jsonEncode({'content': base64Encode(cask)}));
    }
    if (executable == 'gh' && _starts(arguments, ['repo', 'view'])) {
      return _ok(stdout: '{"name":"tool"}');
    }

    if (executable == 'git' && arguments.firstOrNull == 'clone') {
      final checkout = Directory(arguments.last)..createSync(recursive: true);
      final raced = caskAtNextClone;
      final cask = raced ?? publicCask;
      if (raced != null) {
        publicCask = raced;
        caskAtNextClone = null;
      }
      if (cask != null) {
        File('${checkout.path}/Casks/tool.rb')
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(cask);
      }
      return _ok();
    }
    if (executable == 'git' &&
        arguments.length == 1 &&
        arguments.single == 'push' &&
        workingDirectory != null) {
      if (rejectHomebrewPush) {
        return ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: 'rejected (non-fast-forward)',
        );
      }
      publicCask = File('$workingDirectory/Casks/tool.rb').readAsBytesSync();
      if (conflictHomebrewAfterPush) {
        publicCask = utf8.encode('not the generated cask');
      }
      if (unreadHomebrewAfterPush) _homebrewPublicUnreadable = true;
      if (loseHomebrewPushResponse) {
        return ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: 'connection closed before the response',
        );
      }
      return _ok();
    }

    return _ok();
  }

  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    final invocation = _Invocation(
      executable: executable,
      arguments: List.unmodifiable(arguments),
      workingDirectory: workingDirectory,
      interactive: true,
    );
    invocations.add(invocation);
    onInvocation?.call(invocation);
    if (_isDart(executable) && arguments.join(' ') == 'pub login') {
      if (failPubLogin) return 1;
    }
    if (_isDart(executable) &&
        _starts(arguments, ['pub', 'publish']) &&
        arguments.contains('--from-archive')) {
      if (failPubArchiveCapability) return 64;
      if (failPubPublish) return 1;
      final archive = arguments[arguments.indexOf('--from-archive') + 1];
      registry.archives['tool@1.2.3'] = File(archive).readAsBytesSync();
      (registry.published['tool'] ??= <String>[]).add('1.2.3');
      if (losePubPublishResponse) return 1;
    }
    return 0;
  }

  ToolResult _githubReleaseView() {
    if (!githubReleaseExists) return _notFound();
    if (githubDraft) return _notFound();
    return _ok(stdout: jsonEncode(_githubReleaseJson()));
  }

  Map<String, Object?> _githubReleaseJson() => {
        'tag_name': 'v1.2.3',
        'name': githubTitle,
        'body': githubBody,
        'draft': githubDraft,
        'prerelease': false,
        'id': 7,
        'assets': [
          for (var index = 0; index < uploadedAssets.length; index++)
            {
              'name': uploadedAssets.keys.elementAt(index),
              'id': 100 + index,
              'state': 'uploaded',
              'size': uploadedAssets.values.elementAt(index).length,
              'digest':
                  'sha256:${Sha256.hex(uploadedAssets.values.elementAt(index))}',
            },
        ],
      };
}

bool _isDart(String executable) =>
    executable == 'dart' ||
    executable.endsWith('${Platform.pathSeparator}dart') ||
    executable.endsWith('${Platform.pathSeparator}dart.exe');

List<int> _publishedPackage() => ArchiveBuilder.gzip(ArchiveBuilder.tar([
      ArchiveEntry(name: 'pubspec.yaml', bytes: utf8.encode(_pubspec)),
      ArchiveEntry(name: 'CHANGELOG.md', bytes: utf8.encode(_changelog)),
      ArchiveEntry(name: 'bin/tool.dart', bytes: utf8.encode(_entrypoint)),
      ArchiveEntry(name: 'README.md', bytes: utf8.encode('# Tool\n')),
    ]));

bool _starts(List<String> actual, List<String> prefix) {
  if (actual.length < prefix.length) return false;
  for (var index = 0; index < prefix.length; index++) {
    if (actual[index] != prefix[index] &&
        !(prefix[index].endsWith('/') &&
            actual[index].startsWith(prefix[index]))) {
      return false;
    }
  }
  return true;
}

ToolResult _ok({String stdout = ''}) =>
    ToolResult(exitCode: 0, stdout: stdout, stderr: '');

ToolResult _notFound() => ToolResult(
      exitCode: 1,
      stdout: '',
      stderr: 'gh: Not Found (HTTP 404)',
    );
