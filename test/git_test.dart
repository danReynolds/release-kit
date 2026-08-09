import 'dart:io';

import 'package:release_kit/src/destinations/git_tag.dart';
import 'package:release_kit/src/engine/git.dart';
import 'package:release_kit/src/engine/source_tree.dart';
import 'package:release_kit/src/engine/tools.dart';
import 'package:release_kit/src/engine/verdict.dart';
import 'package:release_kit/src/transforms/digest.dart';
import 'package:test/test.dart';

/// `GitState.read` against real repositories.
///
/// It had no test: `status_test.dart` fakes the whole object, so the parsing
/// of `git status --porcelain` — which decides whether rk will release at all
/// — was never exercised by anything.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('rk-git-');
    Process.runSync('git', ['init', '-q'], workingDirectory: root.path);
    Process.runSync('git', ['config', 'user.email', 'a@b.c'],
        workingDirectory: root.path);
    Process.runSync('git', ['config', 'user.name', 'T'],
        workingDirectory: root.path);
  });

  tearDown(() => root.deleteSync(recursive: true));

  void write(String path, String contents) {
    File('${root.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
  }

  void commit() {
    Process.runSync('git', ['add', '-A'], workingDirectory: root.path);
    Process.runSync('git', ['commit', '-qm', 'x'], workingDirectory: root.path);
  }

  test('a committed tree is clean', () {
    write('a.txt', 'one\n');
    commit();
    expect(GitState.read(root.path).isClean, isTrue);
  });

  test('a dirty tree is not clean', () {
    // The false direction: a mutation hardcoding isClean true survived,
    // because every test read the list and none read the bit that gates a
    // release.
    write('a.txt', 'one\n');
    commit();
    write('a.txt', 'two\n');
    expect(GitState.read(root.path).isClean, isFalse);
  });

  test('an unreadable worktree status never becomes a clean release', () {
    write('a.txt', 'one\n');
    commit();
    File('${root.path}/.git/index').writeAsBytesSync([0, 1, 2, 3]);

    final state = GitState.read(root.path);
    final problem = state.uncommittedProblem();

    expect(state.isClean, isFalse);
    expect(state.worktreeStatusError, isNotNull);
    expect(problem?.code, 'RK-GIT-008');
    expect(problem?.message, contains('could not be read'));
    expect(problem?.remedy, contains('git status --porcelain'));
  });

  test('a lightweight tag points at its commit', () {
    write('a.txt', 'one\n');
    commit();
    Process.runSync('git', ['tag', 'v1.0.0'], workingDirectory: root.path);
    final state = GitState.read(root.path);
    expect(state.tagTarget('v1.0.0'), state.head);
    expect(state.tagObject('v1.0.0'), state.head);
  });

  test('an annotated tag is peeled to the commit, not the tag object', () {
    write('a.txt', 'one\n');
    commit();
    Process.runSync(
      'git',
      ['tag', '-a', 'v1.0.0', '-m', 'release'],
      workingDirectory: root.path,
    );
    final state = GitState.read(root.path);
    expect(
      state.tagTarget('v1.0.0'),
      state.head,
      reason: 'the question rk asks is which source the tag names, and an '
          'annotated tag object is not a commit',
    );
    expect(
      state.tagObject('v1.0.0'),
      isNot(state.head),
      reason: 'the direct object is the signed or annotated release record; '
          'the peeled target is its source commit',
    );
  });

  test('a tag left behind by history points where it was made', () {
    write('a.txt', 'one\n');
    commit();
    final first = GitState.read(root.path).head;
    Process.runSync('git', ['tag', 'v1.0.0'], workingDirectory: root.path);
    write('a.txt', 'two\n');
    commit();

    final state = GitState.read(root.path);
    expect(state.tagTarget('v1.0.0'), first);
    expect(state.tagTarget('v1.0.0'), isNot(state.head));
  });

  test('a modified file keeps its whole name', () {
    write('packages/keybay/CHANGELOG.md', 'one\n');
    commit();
    write('packages/keybay/CHANGELOG.md', 'two\n');

    expect(
      GitState.read(root.path).uncommitted,
      ['packages/keybay/CHANGELOG.md'],
      reason: 'porcelain writes " M path" for a worktree-only change, so '
          'trimming the block ate the first line\'s status column and rk '
          'named a file that does not exist',
    );
  });

  test('the first of several modified files is not the odd one out', () {
    write('a.txt', 'one\n');
    write('b.txt', 'one\n');
    commit();
    write('a.txt', 'two\n');
    write('b.txt', 'two\n');

    final uncommitted = GitState.read(root.path).uncommitted;
    expect(uncommitted, ['a.txt', 'b.txt']);
  });

  test('an untracked file is uncommitted', () {
    write('a.txt', 'one\n');
    commit();
    write('b.txt', 'new\n');
    expect(GitState.read(root.path).uncommitted, ['b.txt']);
  });

  test('rk\'s own workspace is not the operator\'s uncommitted work', () {
    write('a.txt', 'one\n');
    commit();
    write('.rk/diagnosis/2026-01-01/run.json', '{}');
    write('.rk/work/cli-v1.0.0-abc/keybay', 'binary');

    final state = GitState.read(root.path);
    expect(
      state.uncommitted,
      isEmpty,
      reason: 'a failed release left this behind, and counting it made the '
          'next run refuse itself — which breaks the resume',
    );
    expect(state.isClean, isTrue);
  });

  test('a repository with no commits does not crash', () {
    write('a.txt', 'one\n');
    final state = GitState.read(root.path);
    expect(state.uncommitted, ['a.txt']);
  });

  test('tags are read', () {
    write('a.txt', 'one\n');
    commit();
    Process.runSync('git', ['tag', 'v1.0.0'], workingDirectory: root.path);
    expect(GitState.read(root.path).hasTag('v1.0.0'), isTrue);
    expect(GitState.read(root.path).hasTag('v2.0.0'), isFalse);
  });

  test('a commit source tree ignores later worktree edits', () {
    write('packages/tool/pubspec.yaml', 'name: tool\nversion: 1.0.0\n');
    commit();
    final head = GitState.read(root.path).head;
    final source = GitCommitSourceTree(root.path, head);

    write('packages/tool/pubspec.yaml', 'name: tool\nversion: 9.9.9\n');
    write('packages/tool/untracked.txt', 'not released\n');

    expect(
      source.read('packages/tool/pubspec.yaml'),
      'name: tool\nversion: 1.0.0\n',
    );
    expect(source.exists('packages/tool'), isTrue);
    expect(source.exists('packages/tool/untracked.txt'), isFalse);
    expect(source.trackedFiles(), ['packages/tool/pubspec.yaml']);
  });

  test('a commit source tree preserves arbitrary blob bytes', () {
    const bytes = [0x00, 0xff, 0xfe, 0x0d, 0x0a, 0x1a];
    File('${root.path}/blob.bin').writeAsBytesSync(bytes);
    commit();
    final source =
        GitCommitSourceTree(root.path, GitState.read(root.path).head);

    File('${root.path}/blob.bin').writeAsBytesSync([0x01]);

    expect(
      source.readBytes('blob.bin'),
      bytes,
      reason: 'the immutable staging source must not decode or read the '
          'later worktree bytes',
    );
  });

  test('a commit source tree rejects every escaping read path', () {
    write('a.txt', 'one\n');
    commit();
    final source =
        GitCommitSourceTree(root.path, GitState.read(root.path).head);

    for (final operation in <Object? Function()>[
      () => source.read('../outside'),
      () => source.readBytes('../outside'),
      () => source.exists('../outside'),
    ]) {
      expect(operation, throwsArgumentError);
    }
  });

  group('exact remote tag observation', () {
    const object = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const commit = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

    Future<Inspection> inspect(
      ToolResult answer, {
      String expectedObject = object,
      String expectedCommit = commit,
    }) =>
        GitTag(
          tools: RecordingTools(answers: (_) => answer),
          root: '/repo',
        ).inspect(
          tag: 'v1.0.0',
          expectedObject: expectedObject,
          expectedCommit: expectedCommit,
        );

    ToolResult answered(String stdout) =>
        ToolResult(exitCode: 0, stdout: stdout, stderr: '');

    test('an annotated tag compares both its object and peeled commit',
        () async {
      final state = await inspect(answered(
        '$object\trefs/tags/v1.0.0\n'
        '$commit\trefs/tags/v1.0.0^{}\n',
      ));
      expect(state.verdict, Verdict.exact);
      expect(state.detail, contains('peeled'));
      expect(state.evidence['tag object'], object);
      expect(state.evidence['source commit'], commit);
    });

    test('a lightweight tag is exact without a synthetic peeled line',
        () async {
      final state = await inspect(
        answered('$commit\trefs/tags/v1.0.0\n'),
        expectedObject: commit,
      );
      expect(state.verdict, Verdict.exact);
    });

    test('a definitive empty answer is absent', () async {
      final state = await inspect(answered(''));
      expect(state.verdict, Verdict.absent);
    });

    test('a different direct tag object is a conflict with evidence', () async {
      const other = 'cccccccccccccccccccccccccccccccccccccccc';
      final state = await inspect(answered(
        '$other\trefs/tags/v1.0.0\n'
        '$commit\trefs/tags/v1.0.0^{}\n',
      ));
      expect(state.verdict, Verdict.conflict);
      expect(state.evidence['tag object'], contains(other));
      expect(state.evidence['tag object'], contains(object));
    });

    test('a tag peeled to different source is a conflict', () async {
      const other = 'cccccccccccccccccccccccccccccccccccccccc';
      final state = await inspect(answered(
        '$object\trefs/tags/v1.0.0\n'
        '$other\trefs/tags/v1.0.0^{}\n',
      ));
      expect(state.verdict, Verdict.conflict);
      expect(state.evidence['source commit'], contains(other));
      expect(state.evidence['source commit'], contains(commit));
    });

    test('a failed read is unknown, never absent', () async {
      final state = await inspect(ToolResult(
        exitCode: 1,
        stdout: '',
        stderr: 'operation timed out',
      ));
      expect(state.verdict, Verdict.unknown);
      expect(state.detail, contains('timed out'));
    });

    test('a tool exception is unknown, never allowed to escape', () async {
      final state = await GitTag(
        tools: RecordingTools(
          answers: (_) => throw StateError('git executable disappeared'),
        ),
        root: '/repo',
      ).inspect(
        tag: 'v1.0.0',
        expectedObject: object,
        expectedCommit: commit,
      );
      expect(state.verdict, Verdict.unknown);
      expect(state.detail, contains('git executable disappeared'));
    });

    test('a malformed successful answer is unknown, never absent', () async {
      final state = await inspect(answered('not-an-object refs/tags/v1.0.0'));
      expect(state.verdict, Verdict.unknown);
    });

    test('a peeled answer without its direct ref is unknown', () async {
      final state = await inspect(
        answered('$commit\trefs/tags/v1.0.0^{}\n'),
      );
      expect(state.verdict, Verdict.unknown);
    });
  });

  group('latest release tag on origin', () {
    Future<Inspection> latest(ToolResult result) => GitTag(
          tools: RecordingTools(results: {
            'git ls-remote --tags origin': result,
          }),
          root: '/repo',
        ).inspectLatestVersion('v{version}');

    test('reads every direct tag and ignores annotated peel records', () async {
      const one = '1111111111111111111111111111111111111111';
      const two = '2222222222222222222222222222222222222222';
      const three = '3333333333333333333333333333333333333333';
      final result = await latest(ToolResult(
        exitCode: 0,
        stdout: '$one\trefs/tags/v1.9.0\n'
            '$two\trefs/tags/v1.10.0\n'
            '$three\trefs/tags/v1.10.0^{}\n'
            '$one\trefs/tags/docs\n',
        stderr: '',
      ));
      expect(result.verdict, Verdict.exact);
      expect(result.evidence['version'], '1.10.0');
    });

    test('an empty matching history is absent', () async {
      final result = await latest(ToolResult(
        exitCode: 0,
        stdout: '',
        stderr: '',
      ));
      expect(result.verdict, Verdict.absent);
    });

    test('a malformed matching semantic tag is unknown', () async {
      final result = await latest(ToolResult(
        exitCode: 0,
        stdout: '1111111111111111111111111111111111111111\trefs/tags/vnext\n',
        stderr: '',
      ));
      expect(result.verdict, Verdict.unknown);
    });

    test('an unreadable origin is unknown', () async {
      final result = await latest(ToolResult(
        exitCode: 1,
        stdout: '',
        stderr: 'network unavailable',
      ));
      expect(result.verdict, Verdict.unknown);
    });
  });

  group('annotated tag manifest binding', () {
    const object = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const commit = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const other = 'cccccccccccccccccccccccccccccccccccccccc';
    const digest =
        'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';

    String annotated(String message) => 'object $commit\n'
        'type commit\n'
        'tag v1.0.0\n'
        'tagger T <a@b.c> 0 +0000\n'
        '\n'
        '$message';

    Future<({TagManifestBinding binding, RecordingTools tools})> read({
      ToolResult? remote,
      ToolResult? localObject,
      String expectedObject = object,
      String expectedCommit = commit,
    }) async {
      final tools = RecordingTools(answers: (key) {
        if (key.startsWith('git ls-remote')) {
          return remote ??
              ToolResult(
                exitCode: 0,
                stdout: '$object\trefs/tags/v1.0.0\n'
                    '$commit\trefs/tags/v1.0.0^{}\n',
                stderr: '',
              );
        }
        if (key.startsWith('git cat-file tag')) {
          return localObject ??
              ToolResult(
                exitCode: 0,
                stdout: annotated(
                  'cli 1.0.0\n\nrelease-manifest-sha256: $digest\n',
                ),
                stderr: '',
              );
        }
        return null;
      });
      final binding = await GitTag(tools: tools, root: '/repo').manifestBinding(
        tag: 'v1.0.0',
        expectedObject: expectedObject,
        expectedCommit: expectedCommit,
      );
      return (binding: binding, tools: tools);
    }

    test('an unsigned annotated tag returns its exact binding', () async {
      final result = await read();
      expect(result.binding, isA<TagManifestBound>());
      expect(result.binding.sha256, digest);
      expect(result.tools.calls, hasLength(2));
      expect(result.tools.calls.last, 'git cat-file tag $object');
    });

    test('a signed annotated tag keeps the same valid message binding',
        () async {
      final result = await read(
          localObject: ToolResult(
        exitCode: 0,
        stdout: annotated(
          'cli 1.0.0\n\n'
          'release-manifest-sha256: $digest\n'
          '-----BEGIN PGP SIGNATURE-----\n'
          'signed bytes\n'
          '-----END PGP SIGNATURE-----\n',
        ),
        stderr: '',
      ));
      expect(result.binding, isA<TagManifestBound>());
      expect(result.binding.sha256, digest);
    });

    test('a missing binding is distinct from an unreadable tag', () async {
      final result = await read(
          localObject: ToolResult(
        exitCode: 0,
        stdout: annotated('cli 1.0.0\n'),
        stderr: '',
      ));
      expect(result.binding, isA<TagManifestMissing>());
      expect(result.binding.sha256, isNull);
    });

    test('an invalid digest is a malformed binding', () async {
      final result = await read(
          localObject: ToolResult(
        exitCode: 0,
        stdout: annotated('release-manifest-sha256: not-a-digest\n'),
        stderr: '',
      ));
      expect(result.binding, isA<TagManifestMalformed>());
    });

    test('duplicate binding lines are malformed', () async {
      final result = await read(
          localObject: ToolResult(
        exitCode: 0,
        stdout: annotated(
          'release-manifest-sha256: $digest\n'
          'release-manifest-sha256: $digest\n',
        ),
        stderr: '',
      ));
      expect(result.binding, isA<TagManifestMalformed>());
    });

    test('a remote identity conflict prevents reading the message', () async {
      final result = await read(
          remote: ToolResult(
        exitCode: 0,
        stdout: '$other\trefs/tags/v1.0.0\n'
            '$commit\trefs/tags/v1.0.0^{}\n',
        stderr: '',
      ));
      expect(result.binding, isA<TagManifestConflict>());
      expect(result.tools.calls, hasLength(1));
      expect(result.tools.calls.single, startsWith('git ls-remote'));
    });

    test('an absent remote tag is distinct from unreadable', () async {
      final result = await read(
          remote: ToolResult(
        exitCode: 0,
        stdout: '',
        stderr: '',
      ));
      expect(result.binding, isA<TagManifestAbsent>());
      expect(result.tools.calls, hasLength(1));
    });

    test('an unreadable remote never becomes absence', () async {
      final result = await read(
          remote: ToolResult(
        exitCode: 1,
        stdout: '',
        stderr: 'operation timed out',
      ));
      expect(result.binding, isA<TagManifestUnreadable>());
      expect((result.binding as TagManifestUnreadable).why, contains('timed'));
      expect(result.tools.calls, hasLength(1));
    });

    test('an unreadable local tag object remains unreadable', () async {
      final result = await read(
          localObject: ToolResult(
        exitCode: 1,
        stdout: '',
        stderr: 'object unavailable',
      ));
      expect(result.binding, isA<TagManifestUnreadable>());
      expect(
        (result.binding as TagManifestUnreadable).why,
        contains('object unavailable'),
      );
    });

    test('a lightweight tag is exact but has no message binding', () async {
      final result = await read(
        expectedObject: commit,
        remote: ToolResult(
          exitCode: 0,
          stdout: '$commit\trefs/tags/v1.0.0\n',
          stderr: '',
        ),
      );
      expect(result.binding, isA<TagManifestUnbound>());
      expect(result.binding.sha256, isNull);
      expect(result.tools.calls, hasLength(1));
    });
  });

  group('post-push release tag proof', () {
    const object = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const commit = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const digest =
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
    const remote = '$object\trefs/tags/v1.0.0\n'
        '$commit\trefs/tags/v1.0.0^{}\n';
    const tagObject = 'object $commit\n'
        'type commit\n'
        'tag v1.0.0\n'
        'tagger Test <test@example.com> 0 +0000\n\n'
        'tool 1.0.0\n\n'
        'release-manifest-sha256: $digest\n';

    Future<({Inspection state, RecordingTools tools})> prove({
      String objectBytes = tagObject,
      bool signed = true,
      ToolResult? signature,
    }) async {
      final tools = RecordingTools(results: {
        'git ls-remote origin refs/tags/v1.0.0 refs/tags/v1.0.0^{}':
            ToolResult(exitCode: 0, stdout: remote, stderr: ''),
        'git cat-file tag $object':
            ToolResult(exitCode: 0, stdout: objectBytes, stderr: ''),
        if (signed)
          'git verify-tag $object':
              signature ?? ToolResult(exitCode: 0, stdout: 'Good', stderr: ''),
      });
      final state =
          await GitTag(tools: tools, root: '/repo').inspectReleaseBinding(
        tag: 'v1.0.0',
        expectedCommit: commit,
        expectedManifestSha256: digest,
        requireSignature: signed,
      );
      return (state: state, tools: tools);
    }

    test('proves origin object, peel, manifest digest, and signature',
        () async {
      final result = await prove();
      expect(result.state.verdict, Verdict.exact);
      expect(result.state.evidence['manifest sha256'], digest);
      expect(result.state.evidence['signature'], 'verified');
      expect(result.tools.calls, contains('git verify-tag $object'));
    });

    test('an intentionally unsigned annotated tag still binds the manifest',
        () async {
      final result = await prove(signed: false);
      expect(result.state.verdict, Verdict.exact);
      expect(result.state.evidence['signature'], 'not required');
      expect(
        result.tools.calls.where((call) => call.startsWith('git verify-tag')),
        isEmpty,
      );
    });

    test('a different manifest binding is a public conflict', () async {
      final result = await prove(
        objectBytes:
            tagObject.replaceFirst(digest, List.filled(64, 'd').join()),
      );
      expect(result.state.verdict, Verdict.conflict);
      expect(result.state.evidence['manifest sha256'], contains(digest));
    });

    test('a promised signature must verify on the remote object id', () async {
      final result = await prove(
        signature: ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: 'BAD signature',
        ),
      );
      expect(result.state.verdict, Verdict.conflict);
      expect(result.state.evidence['signature'], contains('BAD signature'));
    });
  });

  test('a real bare origin preserves the manifest-bound tag transition',
      () async {
    const tag = 'v1.0.0';
    const tools = SystemTools();
    final remote = Directory.systemTemp.createTempSync('rk-git-remote-');
    addTearDown(() => remote.deleteSync(recursive: true));

    void expectOk(ToolResult result, String action) {
      expect(
        result.ok,
        isTrue,
        reason: '$action failed: ${result.summary}',
      );
    }

    expectOk(
      await tools.run(
        'git',
        const ['init', '--bare', '-q'],
        workingDirectory: remote.path,
      ),
      'bare origin initialization',
    );
    write('source.txt', 'the released source\n');
    commit();
    final sourceCommit = GitState.read(root.path).head;
    expectOk(
      await tools.run(
        'git',
        ['remote', 'add', 'origin', remote.path],
        workingDirectory: root.path,
      ),
      'origin configuration',
    );
    expectOk(
      await tools.run(
        'git',
        const ['push', '-u', 'origin', 'HEAD:refs/heads/main'],
        workingDirectory: root.path,
      ),
      'source branch push',
    );
    expect(GitState.read(root.path).headIsPushed, isTrue);

    const manifestBytes = '{"unit":"tool","version":"1.0.0"}\n';
    final manifest = File('${root.path}/.rk/work/release-manifest.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(manifestBytes);
    final manifestDigest = Sha256.hex(manifest.readAsBytesSync());
    final destination = GitTag(tools: tools, root: root.path);

    expect(await destination.onOrigin(tag), isA<TagNotListed>());
    final absent = await destination.inspectReleaseBinding(
      tag: tag,
      expectedCommit: sourceCommit,
      expectedManifestSha256: manifestDigest,
      requireSignature: false,
    );
    expect(absent.verdict, Verdict.absent);

    expectOk(
      await destination.create(
        tag,
        signed: false,
        message: 'tool 1.0.0\n\n'
            'release-manifest-sha256: $manifestDigest',
      ),
      'annotated tag creation',
    );
    final local = GitState.read(root.path);
    final tagObject = local.tagObject(tag)!;
    expect(tagObject, isNot(sourceCommit));
    expect(local.tagTarget(tag), sourceCommit);

    final localProof = await destination.inspectLocalReleaseBinding(
      tag: tag,
      expectedObject: tagObject,
      expectedCommit: sourceCommit,
      expectedManifestSha256: manifestDigest,
      requireSignature: false,
    );
    expect(localProof.verdict, Verdict.exact);

    expectOk(await destination.push(tag), 'release tag push');
    final firstReadback = await destination.inspectReleaseBinding(
      tag: tag,
      expectedCommit: sourceCommit,
      expectedManifestSha256: manifestDigest,
      requireSignature: false,
    );
    expect(firstReadback.verdict, Verdict.exact);
    expect(firstReadback.evidence, {
      'tag object': tagObject,
      'source commit': sourceCommit,
      'manifest sha256': manifestDigest,
      'signature': 'not required',
    });

    expectOk(await destination.push(tag), 'idempotent release tag re-push');
    expect(await destination.onOrigin(tag), isA<TagListed>());
    final secondReadback = await destination.inspectReleaseBinding(
      tag: tag,
      expectedCommit: sourceCommit,
      expectedManifestSha256: manifestDigest,
      requireSignature: false,
    );
    expect(secondReadback.verdict, Verdict.exact);
    expect(secondReadback.evidence, firstReadback.evidence);
  });
}
