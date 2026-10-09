import 'dart:io';

import 'package:rk/src/targets/git_tag/client.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

/// `GitState.read` against real repositories.
///
/// It had no test: `status_test.dart` fakes the whole object, so the parsing
/// of `git status --porcelain` — which decides whether rk will release at all
/// — was never exercised by anything.
void main() {
  group('in a real repository', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('rk-git-');
      Process.runSync('git', ['init', '-q'], workingDirectory: root.path);
      // Written rather than set with git config: two fewer processes a test.
      File('${root.path}/.git/config').writeAsStringSync(
        '[user]\n\temail = a@b.c\n\tname = T\n',
        mode: FileMode.append,
      );
    });

    tearDown(() => root.deleteSync(recursive: true));

    void write(String path, String contents) {
      File('${root.path}/$path')
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);
    }

    void commit() {
      Process.runSync('git', ['add', '-A'], workingDirectory: root.path);
      Process.runSync('git', [
        'commit',
        '-qm',
        'x',
      ], workingDirectory: root.path);
    }

    test(
      'origin lookup works without a commit and ignores a broken index',
      () async {
        expect(await GitState.readOrigin(root.path), isNull);
        for (final url in [
          'git@github.com:owner/repo.git',
          'https://github.com/owner/repo.git',
        ]) {
          Process.runSync('git', [
            'remote',
            'remove',
            'origin',
          ], workingDirectory: root.path);
          Process.runSync('git', [
            'remote',
            'add',
            'origin',
            url,
          ], workingDirectory: root.path);
          File('${root.path}/.git/index').writeAsBytesSync([0, 1, 2, 3]);
          final nested = Directory('${root.path}/nested')..createSync();
          expect(await GitState.readOrigin(nested.path), 'owner/repo');
          nested.deleteSync();
        }
      },
    );

    test('a committed tree is clean, whatever rk keeps in .rk', () async {
      write('a.txt', 'one\n');
      commit();
      // A failed release leaves this behind, and counting it made the next run
      // refuse itself, which breaks the resume.
      write('.rk/diagnosis/2026-01-01/run.json', '{}');
      write('.rk/work/cli-v1.0.0-abc/keybay', 'binary');

      final state = await GitState.read(root.path);
      expect(state.isClean, isTrue);
      expect(state.uncommitted, isEmpty);
    });

    test(
      'every uncommitted path is named whole, and dirties the tree',
      () async {
        write('a.txt', 'one\n');
        write('packages/keybay/CHANGELOG.md', 'one\n');
        write('z.txt', 'one\n');
        commit();
        write('a.txt', 'two\n');
        write('packages/keybay/CHANGELOG.md', 'two\n');
        Process.runSync('git', [
          'mv',
          'z.txt',
          'y z.txt',
        ], workingDirectory: root.path);
        write('new.txt', 'new\n');

        final state = await GitState.read(root.path);
        expect(state.isClean, isFalse);
        expect(
          state.uncommitted,
          unorderedEquals([
            'a.txt',
            'packages/keybay/CHANGELOG.md',
            'y z.txt',
            'new.txt',
          ]),
          reason: 'modified, renamed with a space, and untracked',
        );
      },
    );

    test(
      'an unreadable worktree status never becomes a clean release',
      () async {
        write('a.txt', 'one\n');
        commit();
        File('${root.path}/.git/index').writeAsBytesSync([0, 1, 2, 3]);

        final state = await GitState.read(root.path);
        final problem = state.uncommittedProblem();

        expect(state.isClean, isFalse);
        expect(state.worktreeStatusError, isNotNull);
        expect(problem?.code, 'RK-GIT-008');
        expect(problem?.message, contains('could not be read'));
        expect(problem?.remedy, contains('git status --porcelain'));
      },
    );

    test('a repository with no commit has no HEAD, and its files are '
        'uncommitted', () async {
      write('a.txt', 'one\n');
      final state = await GitState.read(root.path);
      expect(state.uncommitted, ['a.txt']);
      expect(state.hasCommit, isFalse);
      expect(state.headTree, isEmpty);
      expect(state.stagingProblem()?.code, 'RK-GIT-001');
    });

    test('tags are read, each pointing where it was made', () async {
      String git(List<String> args) =>
          (Process.runSync('git', args, workingDirectory: root.path).stdout
                  as String)
              .trim();
      write('a.txt', 'one\n');
      commit();
      final first = git(['rev-parse', 'HEAD']);
      git(['tag', 'v1.0.0']);
      write('a.txt', 'two\n');
      commit();
      git(['tag', '-a', 'v2.0.0', '-m', 'release']);

      final state = await GitState.read(root.path);
      expect(state.hasTag('v1.0.0'), isTrue);
      expect(state.hasTag('v3.0.0'), isFalse);
      // A lightweight tag is its commit, left where history made it.
      expect(state.tagTarget('v1.0.0'), first);
      expect(state.tagObject('v1.0.0'), first);
      expect(
        state.tagTarget('v2.0.0'),
        state.head,
        reason:
            'the question rk asks is which source the tag names, and an '
            'annotated tag object is not a commit',
      );
      expect(
        state.tagObject('v2.0.0'),
        isNot(state.head),
        reason:
            'the direct object is the signed or annotated release record; '
            'the peeled target is its source commit',
      );
    });

    test('one status read says the branch and how far it is ahead', () async {
      void git(List<String> args, [String? directory]) => expect(
        Process.runSync(
          'git',
          args,
          workingDirectory: directory ?? root.path,
        ).exitCode,
        0,
        reason: args.join(' '),
      );
      final origin = Directory.systemTemp.createTempSync('rk-git-origin-');
      addTearDown(() => origin.deleteSync(recursive: true));
      git(['init', '-q', '--bare'], origin.path);
      write('a.txt', 'one\n');
      commit();
      git(['checkout', '-q', '-B', 'main']);
      git(['remote', 'add', 'origin', origin.path]);
      git(['push', '-q', '-u', 'origin', 'main']);

      final pushed = await GitState.read(root.path);
      expect(pushed.branch, 'main');
      expect(pushed.aheadOfUpstream, 0);
      expect(pushed.headIsPushed, isTrue);
      expect(pushed.hasRemote, isTrue);

      write('a.txt', 'two\n');
      commit();
      final ahead = await GitState.read(root.path);
      expect(ahead.aheadOfUpstream, 1);
      expect(ahead.headIsPushed, isFalse);
      expect(ahead.headTree, isNot(pushed.headTree));
      expect(ahead.head, isNot(pushed.head));

      git(['checkout', '-q', '--detach']);
      final detached = await GitState.read(root.path);
      expect(detached.branch, isNull);
      expect(detached.head, ahead.head);
    });

    test('tag.gpgSign is read as git reads a boolean', () async {
      expect((await GitState.read(root.path)).tagSigningRequested, isFalse);
      for (final (value, expected) in [
        ('true', true),
        ('yes', true),
        ('On', true),
        ('1', true),
        ('false', false),
        ('0', false),
      ]) {
        Process.runSync('git', [
          'config',
          'tag.gpgSign',
          value,
        ], workingDirectory: root.path);
        expect(
          (await GitState.read(root.path)).tagSigningRequested,
          expected,
          reason: value,
        );
      }
    });

    test('git is asked six things at once, through the given tools', () async {
      final asked = <String>[];
      await GitState.read(root.path, tools: _Asked(asked));
      expect(asked, hasLength(6));
      expect(asked, everyElement(startsWith('git ')));
    });

    test(
      'a commit source tree holds the commit\'s paths, not the worktree\'s',
      () async {
        write('packages/tool/pubspec.yaml', 'name: tool\nversion: 1.0.0\n');
        commit();
        final source = GitCommitSourceTree(
          root.path,
          (await GitState.read(root.path)).head,
        );
        write('packages/tool/untracked.txt', 'not released\n');

        expect(source.exists('packages/tool'), isTrue);
        expect(source.exists('packages/tool/untracked.txt'), isFalse);
      },
    );

    test('repeated reads of a commit hand out copies', () async {
      write('a.txt', 'one\n');
      commit();
      final head = (await GitState.read(root.path)).head;
      final tree = GitSourceTree(root.path);

      // Each reader scribbles on what it got back.
      tree.readBytesAt(head, 'a.txt')[0] = 0x58;
      (await tree.readBytesBatchAt(head, ['a.txt']))['a.txt']![1] = 0x58;
      tree.trackedEntriesAt(head).clear();

      expect(String.fromCharCodes(tree.readBytesAt(head, 'a.txt')), 'one\n');
      expect(
        String.fromCharCodes(
          (await tree.readBytesBatchAt(head, ['a.txt']))['a.txt']!,
        ),
        'one\n',
      );
      expect(tree.trackedFilesAt(head), ['a.txt']);
    });

    test('a symbolic commit is read afresh after it moves', () async {
      write('a.txt', 'one\n');
      commit();
      final tree = GitSourceTree(root.path);
      expect(String.fromCharCodes(tree.readBytesAt('HEAD', 'a.txt')), 'one\n');
      expect(tree.trackedFilesAt('HEAD'), ['a.txt']);

      write('a.txt', 'two\n');
      write('b.txt', 'new\n');
      commit();

      expect(String.fromCharCodes(tree.readBytesAt('HEAD', 'a.txt')), 'two\n');
      expect(tree.trackedFilesAt('HEAD'), ['a.txt', 'b.txt']);
    });

    test(
      'a real bare origin preserves the manifest-bound tag transition',
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
          await tools.run('git', const [
            'init',
            '--bare',
            '-q',
          ], workingDirectory: remote.path),
          'bare origin initialization',
        );
        write('source.txt', 'the released source\n');
        commit();
        final sourceCommit = (await GitState.read(root.path)).head;
        expectOk(
          await tools.run('git', [
            'remote',
            'add',
            'origin',
            remote.path,
          ], workingDirectory: root.path),
          'origin configuration',
        );
        expectOk(
          await tools.run('git', const [
            'push',
            '-u',
            'origin',
            'HEAD:refs/heads/main',
          ], workingDirectory: root.path),
          'source branch push',
        );
        expect((await GitState.read(root.path)).headIsPushed, isTrue);

        const manifestBytes = '{"unit":"tool","version":"1.0.0"}\n';
        final manifest = File('${root.path}/.rk/work/release-manifest.json')
          ..createSync(recursive: true)
          ..writeAsStringSync(manifestBytes);
        final manifestDigest = Sha256.hex(manifest.readAsBytesSync());
        final destination = GitTag(tools: tools, root: root.path);
        final absent = await destination.inspectReleaseBinding(
          tag: tag,
          expectedCommit: sourceCommit,
          expectedManifestSha256: manifestDigest,
        );
        expect(absent.verdict, Verdict.absent);

        expectOk(
          await destination.create(
            tag,
            commit: sourceCommit,
            signed: false,
            message:
                'tool 1.0.0\n\n'
                'release-manifest-sha256: $manifestDigest',
          ),
          'annotated tag creation',
        );
        final local = await GitState.read(root.path);
        final tagObject = local.tagObject(tag)!;
        expect(tagObject, isNot(sourceCommit));
        expect(local.tagTarget(tag), sourceCommit);
        expect((await destination.localObject(tag)).object, tagObject);

        final localProof = await destination.inspectLocalReleaseBinding(
          tag: tag,
          expectedObject: tagObject,
          expectedCommit: sourceCommit,
          expectedManifestSha256: manifestDigest,
        );
        expect(localProof.verdict, Verdict.exact);

        // Move the mutable local ref after validation. The push must still send
        // the exact object that was proved above, never whatever the name happens
        // to resolve to at push time.
        expectOk(
          await tools.run('git', [
            'tag',
            '-fa',
            tag,
            '-m',
            'replacement tag object',
          ], workingDirectory: root.path),
          'local tag replacement',
        );
        final replacementObject = (await GitState.read(
          root.path,
        )).tagObject(tag)!;
        expect(replacementObject, isNot(tagObject));

        final staleCleanup = await destination.deleteLocalIfExact(
          tag,
          tagObject,
        );
        expect(staleCleanup.ok, isFalse);
        expect(
          (await GitState.read(root.path)).tagObject(tag),
          replacementObject,
        );

        expectOk(
          await destination.pushExact(tag, tagObject),
          'release tag push',
        );
        final firstReadback = await destination.inspectReleaseBinding(
          tag: tag,
          expectedCommit: sourceCommit,
          expectedManifestSha256: manifestDigest,
        );
        expect(firstReadback.verdict, Verdict.exact);
        expect(firstReadback.evidence, {
          'tag object': tagObject,
          'source commit': sourceCommit,
          'manifest sha256': manifestDigest,
        });

        expectOk(
          await destination.pushExact(tag, tagObject),
          'idempotent release tag re-push',
        );
        final secondReadback = await destination.inspectReleaseBinding(
          tag: tag,
          expectedCommit: sourceCommit,
          expectedManifestSha256: manifestDigest,
        );
        expect(secondReadback.verdict, Verdict.exact);
        expect(secondReadback.evidence, firstReadback.evidence);

        // Git refuses to replace the tag origin has, which is why a push's
        // answer settles it with no read before or after.
        final replaced = await destination.pushExact(tag, replacementObject);
        expect(replaced.ok, isFalse);
        expect(replaced.stderr, contains('already exists'));
        final origin = await destination.onOrigin(tag);
        expect(origin.object, tagObject);
        expect(origin.commit, sourceCommit);
      },
    );
  });

  test('a commit source tree rejects every escaping read path', () {
    final source = GitCommitSourceTree('/repo', 'a' * 40);
    for (final operation in <Object? Function()>[
      () => source.read('../outside'),
      () => source.readBytes('../outside'),
      () => source.exists('../outside'),
    ]) {
      expect(operation, throwsArgumentError);
    }
  });

  group('latest release tag on origin', () {
    Future<Inspection> latest(ToolResult result) => GitTag(
      tools: RecordingTools(results: {'git ls-remote --tags origin': result}),
      root: '/repo',
    ).inspectLatestVersion('v{version}');

    test('reads every direct tag and ignores annotated peel records', () async {
      const one = '1111111111111111111111111111111111111111';
      const two = '2222222222222222222222222222222222222222';
      const three = '3333333333333333333333333333333333333333';
      final result = await latest(
        ToolResult(
          exitCode: 0,
          stdout:
              '$one\trefs/tags/v1.9.0\n'
              '$two\trefs/tags/v1.10.0\n'
              '$three\trefs/tags/v1.10.0^{}\n'
              '$one\trefs/tags/docs\n',
          stderr: '',
        ),
      );
      expect(result.verdict, Verdict.exact);
      expect(result.evidence['version'], '1.10.0');
    });

    test('an empty matching history is absent', () async {
      final result = await latest(
        ToolResult(exitCode: 0, stdout: '', stderr: ''),
      );
      expect(result.verdict, Verdict.absent);
    });

    test(
      'a matching tag that is no semantic version is not a release',
      () async {
        // `v1.0` and `vnext` match `v{version}` and name no version: an old
        // or hand-made tag, which must not block every release after it.
        const one = '1111111111111111111111111111111111111111';
        final result = await latest(
          ToolResult(
            exitCode: 0,
            stdout:
                '$one\trefs/tags/vnext\n'
                '$one\trefs/tags/v1.0\n'
                '$one\trefs/tags/v0.9.0\n',
            stderr: '',
          ),
        );
        expect(result.verdict, Verdict.exact, reason: result.detail);
        expect(result.evidence['version'], '0.9.0');

        final none = await latest(
          ToolResult(exitCode: 0, stdout: '$one\trefs/tags/v1.0\n', stderr: ''),
        );
        expect(none.verdict, Verdict.absent, reason: none.detail);
      },
    );

    test('an unreadable origin is unknown', () async {
      final result = await latest(
        ToolResult(exitCode: 1, stdout: '', stderr: 'network unavailable'),
      );
      expect(result.verdict, Verdict.unknown);
    });
  });

  group('post-push release tag proof', () {
    const object = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const commit = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const digest =
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
    const remote =
        '$object\trefs/tags/v1.0.0\n'
        '$commit\trefs/tags/v1.0.0^{}\n';
    const tagObject =
        'object $commit\n'
        'type commit\n'
        'tag v1.0.0\n'
        'tagger Test <test@example.com> 0 +0000\n\n'
        'tool 1.0.0\n\n'
        'release-manifest-sha256: $digest\n';

    Future<({Inspection state, RecordingTools tools})> prove({
      String objectBytes = tagObject,
      String expectedCommit = commit,
      List<String> sourcePaths = const [],
      ToolResult? diff,
    }) async {
      final tools = RecordingTools(
        results: {
          'git ls-remote --tags origin': ToolResult(
            exitCode: 0,
            stdout: '$remote$commit\trefs/tags/v0.9.0\n',
            stderr: '',
          ),
          'git cat-file tag $object': ToolResult(
            exitCode: 0,
            stdout: objectBytes,
            stderr: '',
          ),
          if (diff != null)
            'git --literal-pathspecs diff-tree --quiet -r $commit^{commit} '
                    '$expectedCommit -- ${sourcePaths.join(' ')}':
                diff,
        },
      );
      final state = await GitTag(tools: tools, root: '/repo')
          .inspectReleaseBinding(
            tag: 'v1.0.0',
            expectedCommit: expectedCommit,
            expectedManifestSha256: digest,
            sourcePaths: sourcePaths,
          );
      return (state: state, tools: tools);
    }

    group('a tag on an earlier commit', () {
      const later = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
      ToolResult exit(int code) =>
          ToolResult(exitCode: code, stdout: '', stderr: '');

      test('still releases this version while the unit is unchanged', () async {
        // The tag's manifest describes its own commit, not a stage of this
        // one, so a different expected digest is no conflict here.
        final result = await prove(
          expectedCommit: later,
          sourcePaths: ['packages/tool'],
          diff: exit(0),
          objectBytes: tagObject.replaceFirst(
            digest,
            List.filled(64, 'd').join(),
          ),
        );
        expect(result.state.verdict, Verdict.exact);
        expect(
          result.state.detail,
          'origin tag binds bbbbbbb, and nothing this unit releases has '
          'changed since',
        );
        expect(result.state.evidence['source commit'], commit);
        expect(result.state.releasedFrom, commit);
      });

      test('is a different source once the unit has changed', () async {
        final result = await prove(
          expectedCommit: later,
          sourcePaths: ['packages/tool'],
          diff: exit(1),
        );
        expect(result.state.verdict, Verdict.conflict);
        expect(result.state.sourceMismatch?.releasedCommit, commit);
        expect(result.state.sourceMismatch?.currentCommit, later);
      });

      test('asks for the tagged commit when this clone lacks it', () async {
        final result = await prove(
          expectedCommit: later,
          sourcePaths: ['packages/tool'],
          diff: exit(128),
        );
        expect(
          result.state.verdict,
          Verdict.unknown,
          reason: 'a commit rk cannot read is not a different source',
        );
        expect(result.state.detail, contains('git fetch origin tag v1.0.0'));
        expect(result.state.releasedFrom, commit);
      });

      test('is a different source when no directory is named', () async {
        // As once this commit is staged: its bytes need a tag of its own.
        final result = await prove(expectedCommit: later);
        expect(result.state.verdict, Verdict.conflict);
        expect(
          result.tools.calls.where((call) => call.contains('diff-tree')),
          isEmpty,
        );
      });
    });

    test('proves origin object, peel, and manifest digest', () async {
      final result = await prove();
      expect(result.state.verdict, Verdict.exact);
      expect(
        result.state.releasedFrom,
        isNull,
        reason: 'a tag on this commit is released from here',
      );
      expect(result.state.evidence, {
        'tag object': object,
        'source commit': commit,
        'manifest sha256': digest,
      });
      expect(
        result.tools.calls,
        ['git ls-remote --tags origin', 'git cat-file tag $object'],
        reason: 'the tag is read from the listing of every tag',
      );
    });

    test('a different manifest binding is a public conflict', () async {
      final result = await prove(
        objectBytes: tagObject.replaceFirst(
          digest,
          List.filled(64, 'd').join(),
        ),
      );
      expect(result.state.verdict, Verdict.conflict);
      expect(result.state.evidence['manifest sha256'], contains(digest));
    });

    test(
      'a historical release remains proven when current source moved',
      () async {
        const current = 'dddddddddddddddddddddddddddddddddddddddd';
        final result = await prove(expectedCommit: current);

        expect(result.state.verdict, Verdict.conflict);
        expect(
          result.state.detail,
          contains('released from a different source'),
        );
        expect(result.state.evidence['released source commit'], commit);
        expect(result.state.evidence['current source commit'], current);
        expect(result.state.evidence['manifest sha256'], digest);
        expect(result.tools.calls, contains('git cat-file tag $object'));
      },
    );
  });
}

/// Real tools that write down what they were asked.
final class _Asked implements Tools {
  _Asked(this.asked);

  final List<String> asked;

  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) {
    asked.add('$executable ${arguments.join(' ')}');
    return const SystemTools().run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      timeout: timeout,
    );
  }

  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) => throw UnimplementedError();
}
