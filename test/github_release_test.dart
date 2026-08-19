import 'dart:convert';
import 'dart:io';

import 'package:rk/src/destinations/github_release.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

import 'scripted_tools.dart';

/// The forge reader, whose whole inspect arm a mutation pass found protected
/// by nothing: a draft could read as published, a missing asset as exact, and
/// any gh failure as absent, and the suite stayed green.
void main() {
  Future<Inspection> inspect(
    List<({int code, String out, String err})> answers, {
    Set<String> expected = const {'tool-1.0.0-macos-arm64.tar.gz'},
    bool prerelease = false,
  }) {
    return GithubRelease(
      tools: SequencedTools([
        for (final a in answers)
          a.code == 0
              ? ok(a.out)
              : (a.err.isEmpty ? failed('exit ${a.code}') : failed(a.err)),
      ]),
      repository: 'example/tool',
      workingDirectory: '/repo',
    ).inspect('v1.0.0', expected, prerelease: prerelease);
  }

  // The REST shape, not the porcelain's: the reader asks `gh api`, whose
  // fields are snake_case and whose id is numeric.
  String view({
    bool draft = false,
    bool prerelease = false,
    String tag = 'v1.0.0',
    String? title = 'tool 1.0.0',
    String? body = 'release notes\n',
    List<String> assets = const ['tool-1.0.0-macos-arm64.tar.gz'],
  }) =>
      jsonEncode({
        'tag_name': tag,
        'draft': draft,
        'prerelease': prerelease,
        'id': 41,
        'name': title,
        'body': body,
        'assets': [
          for (final name in assets) {'name': name},
        ],
      });

  test('a published release with exactly the expected assets is exact',
      () async {
    final state = await inspect([(code: 0, out: view(), err: '')]);
    expect(state.verdict, Verdict.exact);
  });

  test('prerelease maturity is part of exact release identity', () async {
    final exact = await inspect(
      [(code: 0, out: view(prerelease: true), err: '')],
      prerelease: true,
    );
    expect(exact.verdict, Verdict.exact);

    final mismatch = await inspect([
      (code: 0, out: view(prerelease: true), err: ''),
    ]);
    expect(mismatch.verdict, Verdict.conflict);
    expect(mismatch.evidence['prerelease'], contains('expected stable'));
  });

  test('a draft is absent — it is not published — and says it exists',
      () async {
    final state = await inspect([(code: 0, out: view(draft: true), err: '')]);
    expect(state.verdict, Verdict.absent);
    expect(state.detail, contains('draft'));
  });

  test('missing assets on a published release are a conflict, with names',
      () async {
    final state = await inspect(
      [(code: 0, out: view(assets: const []), err: '')],
    );
    expect(state.verdict, Verdict.conflict);
    expect(state.evidence['tool-1.0.0-macos-arm64.tar.gz'], 'missing');
  });

  test('extra assets are a conflict too — exact means equal, not subset',
      () async {
    final state = await inspect([
      (
        code: 0,
        out: view(assets: const [
          'tool-1.0.0-macos-arm64.tar.gz',
          'tool-1.0.0-macos-x64.tar.gz',
        ]),
        err: '',
      )
    ]);
    expect(
      state.verdict,
      Verdict.conflict,
      reason: 'a superset read as exact would later bless a release whose '
          'notary log or cask went missing, because nothing counted extras',
    );
    expect(state.evidence.keys, contains('tool-1.0.0-macos-x64.tar.gz'));
  });

  group('absence needs the repository to have answered', () {
    test('HTTP 404 + repository readable → absent', () async {
      final state = await inspect([
        (code: 1, out: '', err: 'gh: Not Found (HTTP 404)'),
        (code: 0, out: '{"name":"tool"}', err: ''),
      ]);
      expect(state.verdict, Verdict.absent);
    });

    test('HTTP 404 + repository unreadable → unknown', () async {
      final state = await inspect([
        (code: 1, out: '', err: 'gh: Not Found (HTTP 404)'),
        (code: 1, out: '', err: 'Could not resolve to a Repository'),
      ]);
      expect(
        state.verdict,
        Verdict.unknown,
        reason: 'GitHub answers 404 for a repository the token cannot see, '
            'deliberately — and absent is what lets a release proceed',
      );
    });

    test('the porcelain prose alone is never absence', () async {
      // The old reader keyed on gh's "release not found" wording, which gh
      // rewords between versions and says for more than one condition. A
      // failure carrying only prose — no status — is unknown.
      final state = await inspect([
        (code: 1, out: '', err: 'release not found'),
      ]);
      expect(state.verdict, Verdict.unknown);
    });
  });

  group('everything else gh can do wrong is unknown, never absent', () {
    for (final (label, err) in [
      ('an expired token', 'HTTP 401: Bad credentials'),
      ('a rate limit', 'HTTP 403: API rate limit exceeded'),
      ('no network', 'could not resolve host: api.github.com'),
    ]) {
      test(label, () async {
        final state = await inspect([(code: 1, out: '', err: err)]);
        expect(state.verdict, Verdict.unknown, reason: err);
      });
    }

    test('a body that is not JSON', () async {
      final state =
          await inspect([(code: 0, out: '<html>login</html>', err: '')]);
      expect(state.verdict, Verdict.unknown);
    });

    test('a release whose assets cannot be read', () async {
      final state = await inspect([
        (
          code: 0,
          out: jsonEncode({
            'tagName': 'v1.0.0',
            'isDraft': false,
            'name': 'v1.0.0',
            'assets': 'not a list',
          }),
          err: '',
        )
      ]);
      expect(
        state.verdict,
        Verdict.unknown,
        reason: 'no assets and no answer about assets are different facts',
      );
    });
  });

  group('exact release identity', () {
    const asset = 'tool-1.0.0-macos-arm64.tar.gz';
    final bytes = utf8.encode('the staged archive bytes');

    GithubReleaseExpectation expectation({
      String title = 'tool 1.0.0',
      String body = 'release notes\n',
      String? digest,
      bool prerelease = false,
    }) =>
        GithubReleaseExpectation(
          tag: 'v1.0.0',
          title: title,
          body: body,
          prerelease: prerelease,
          assetSha256: {asset: digest ?? Sha256.hex(bytes)},
        );

    Future<Inspection> inspectExact(
      String response, {
      Map<String, List<int>>? downloads,
      String? downloadFailure,
      bool omitDownloadedFile = false,
      GithubReleaseExpectation? expected,
    }) =>
        GithubRelease(
          tools: _DownloadTools(
            response: response,
            downloads: downloads ?? {asset: bytes},
            downloadFailure: downloadFailure,
            omitDownloadedFile: omitDownloadedFile,
          ),
          repository: 'example/tool',
          workingDirectory: '/repo',
        ).inspectExact(expected ?? expectation());

    test('tag, title, body, inventory, and downloaded bytes can all be exact',
        () async {
      final state = await inspectExact(view());
      expect(state.verdict, Verdict.exact);
      expect(state.detail, contains('asset bytes match'));
      expect(state.evidence[asset], 'sha256:${Sha256.hex(bytes)}');
    });

    test('independent asset downloads run concurrently', () async {
      final downloads = {
        'a.tar.gz': utf8.encode('a'),
        'b.tar.gz': utf8.encode('b'),
        'c.tar.gz': utf8.encode('c'),
      };
      final tools = _ConcurrentDownloadTools(
        response: jsonEncode({
          'tag_name': 'v1.0.0',
          'draft': false,
          'prerelease': false,
          'id': 41,
          'name': 'tool 1.0.0',
          'body': 'release notes\n',
          'assets': [
            for (final name in downloads.keys) {'name': name}
          ],
        }),
        downloads: downloads,
      );
      final state = await GithubRelease(
        tools: tools,
        repository: 'example/tool',
        workingDirectory: '/repo',
      ).inspectExact(GithubReleaseExpectation(
        tag: 'v1.0.0',
        title: 'tool 1.0.0',
        body: 'release notes\n',
        prerelease: false,
        assetSha256: {
          for (final entry in downloads.entries)
            entry.key: Sha256.hex(entry.value),
        },
      ));
      expect(state.verdict, Verdict.exact);
      expect(tools.maxActive, greaterThan(1));
    });

    test('the endpoint returning a different tag is a conflict', () async {
      final state = await inspectExact(view(tag: 'v2.0.0'));
      expect(state.verdict, Verdict.conflict);
      expect(state.evidence['tag'], contains('v2.0.0'));
      expect(state.evidence['tag'], contains('v1.0.0'));
    });

    test('title and body differences are conflicts before any download',
        () async {
      final state = await inspectExact(
        view(title: 'Surprise', body: 'different notes'),
      );
      expect(state.verdict, Verdict.conflict);
      expect(state.evidence.keys, containsAll(['title', 'body']));
    });

    test('missing title/body fields are unreadable, not a mismatch', () async {
      final state = await inspectExact(jsonEncode({
        'tag_name': 'v1.0.0',
        'draft': false,
        'prerelease': false,
        'id': 41,
        'assets': [
          {'name': asset},
        ],
      }));
      expect(state.verdict, Verdict.unknown);
    });

    test('a downloaded digest mismatch is a conflict with both digests',
        () async {
      final state = await inspectExact(
        view(),
        downloads: {asset: utf8.encode('different public bytes')},
      );
      expect(state.verdict, Verdict.conflict);
      expect(state.evidence[asset], contains(Sha256.hex(bytes)));
      expect(
        state.evidence[asset],
        contains(Sha256.hex(utf8.encode('different public bytes'))),
      );
    });

    test('a failed asset download is unknown, never absent', () async {
      final state = await inspectExact(
        view(),
        downloadFailure: 'operation timed out',
      );
      expect(state.verdict, Verdict.unknown);
      expect(state.detail, contains('timed out'));
    });

    test('download success without a file is unknown, never exact', () async {
      final state = await inspectExact(view(), omitDownloadedFile: true);
      expect(state.verdict, Verdict.unknown);
      expect(state.detail, contains('produced no bytes'));
    });

    test('a malformed expected digest is unknown without querying GitHub',
        () async {
      final state = await inspectExact(
        view(),
        expected: expectation(digest: 'not-sha256'),
      );
      expect(state.verdict, Verdict.unknown);
      expect(state.detail, contains('not SHA-256'));
    });

    test('a malformed asset entry is unknown, never missing', () async {
      final state = await inspectExact(jsonEncode({
        'tag_name': 'v1.0.0',
        'draft': false,
        'prerelease': false,
        'id': 41,
        'name': 'tool 1.0.0',
        'body': 'release notes\n',
        'assets': [
          {'size': bytes.length},
        ],
      }));
      expect(state.verdict, Verdict.unknown);
    });

    test('a tool exception is unknown, never allowed to escape', () async {
      final state = await GithubRelease(
        tools: RecordingTools(
          answers: (_) => throw StateError('gh executable disappeared'),
        ),
        repository: 'example/tool',
        workingDirectory: '/repo',
      ).inspect('v1.0.0', const {asset}, prerelease: false);
      expect(state.verdict, Verdict.unknown);
      expect(state.detail, contains('gh executable disappeared'));
    });
  });

  group('public asset digests for direct consumers', () {
    const asset = 'tool-1.0.0-macos-arm64.tar.gz';
    final bytes = utf8.encode('public archive');

    test('prefers the provider digest without downloading', () async {
      final tools = _DownloadTools(
        response: jsonEncode({
          'tag_name': 'v1.0.0',
          'draft': false,
          'prerelease': false,
          'id': 41,
          'name': 'tool 1.0.0',
          'body': 'notes',
          'assets': [
            {'name': asset, 'digest': 'sha256:${Sha256.hex(bytes)}'},
          ],
        }),
        downloads: {asset: bytes},
      );

      final read = await GithubRelease(
        tools: tools,
        repository: 'example/tool',
        workingDirectory: '/repo',
      ).readAssetDigests(
        tag: 'v1.0.0',
        expectedAssets: const {asset},
        requestedAssets: const {asset},
        prerelease: false,
      );

      expect(read.inspection.verdict, Verdict.exact);
      expect(read.digests[asset], Sha256.hex(bytes));
      expect(tools.downloadRequests, isEmpty);
    });

    test('downloads and hashes when GitHub omits the digest', () async {
      final tools = _DownloadTools(
        response: view(),
        downloads: {asset: bytes},
      );

      final read = await GithubRelease(
        tools: tools,
        repository: 'example/tool',
        workingDirectory: '/repo',
      ).readAssetDigests(
        tag: 'v1.0.0',
        expectedAssets: const {asset},
        requestedAssets: const {asset},
        prerelease: false,
      );

      expect(read.inspection.verdict, Verdict.exact);
      expect(read.digests[asset], Sha256.hex(bytes));
      expect(tools.downloadRequests, [asset]);
    });
  });

  group('publish: private draft transaction', () {
    Future<
        ({
          PublishOutcome outcome,
          RecordingTools tools,
          Map<String, Object?>? createPayload,
          Map<String, Object?>? publishPayload,
        })> publish({
      String slurp = '[[]]',
      bool prerelease = false,
      bool duplicateAssetNames = false,
      List<String> initialDraftNames = const [],
      String draftTitle = 'tool 1.0.0',
      String draftBody = 'notes',
      String? createFailure,
      bool unreadDraftsAfterCreate = false,
      String? uploadFailure,
      bool failedUploadLands = false,
      bool failedUploadPublishes = false,
      bool successfulUploadLands = true,
      Map<String, List<int>> draftAssetOverrides = const {},
      bool exactSameTagDownloadAvailable = false,
      bool patchFails = false,
      bool failedPatchLands = false,
    }) async {
      final scratch =
          Directory.systemTemp.createTempSync('rk-gh-publish-test-');
      addTearDown(() {
        if (scratch.existsSync()) scratch.deleteSync(recursive: true);
      });
      final notes = File('${scratch.path}/notes.md')
        ..writeAsStringSync('notes');
      final paths = <String>[];
      for (final name in duplicateAssetNames
          ? const ['left/a.tar.gz', 'right/a.tar.gz']
          : const ['a.tar.gz', 'b.tar.gz']) {
        final file = File('${scratch.path}/$name');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(name);
        paths.add(file.path);
      }
      final stagedBytes = {
        for (final path in paths)
          path.split('/').last: File(path).readAsBytesSync(),
      };
      final assets = <String, List<int>>{
        for (final name in initialDraftNames)
          name: stagedBytes[name] ?? utf8.encode('unexpected:$name'),
      };
      Map<String, Object?> draftAssetJson(String name, int index) {
        final bytes = draftAssetOverrides[name] ?? assets[name]!;
        return {
          'name': name,
          'id': 100 + index,
          'state': 'uploaded',
          'size': bytes.length,
          'digest': 'sha256:${Sha256.hex(bytes)}',
        };
      }

      var draft = true;
      var draftReads = 0;
      var uploadCount = 0;
      Map<String, Object?>? createPayload;
      Map<String, Object?>? publishPayload;
      late final RecordingTools tools;
      tools = RecordingTools(
        onRun: (key) {
          if (key.contains('uploads.github.com')) {
            uploadCount++;
            final name = Uri.decodeQueryComponent(
              key.split('assets?name=').last,
            );
            final fails = uploadFailure != null && uploadCount == 1;
            if ((!fails && successfulUploadLands) ||
                (fails && failedUploadLands)) {
              assets[name] = stagedBytes[name]!;
            }
            if (fails && failedUploadPublishes) draft = false;
          }
          if (exactSameTagDownloadAvailable &&
              key.startsWith('gh release download ')) {
            final name = key.split('--pattern ').last.split(' ').first;
            final output = key.split('--output ').last.split(' ').first;
            File(output).writeAsBytesSync(stagedBytes[name]!);
          }
          if (key.contains(' -X PATCH ') && (!patchFails || failedPatchLands)) {
            draft = false;
          }
          if (key.contains(' -X POST repos/example/tool/releases --input ')) {
            createPayload = Map<String, Object?>.from(
              jsonDecode(File(key.split('--input ').last).readAsStringSync())
                  as Map,
            );
          }
          if (key.contains(' -X PATCH repos/example/tool/releases/7 ')) {
            publishPayload = Map<String, Object?>.from(
              jsonDecode(File(key.split('--input ').last).readAsStringSync())
                  as Map,
            );
          }
        },
        answers: (key) {
          if (key.startsWith('gh api --paginate --slurp')) {
            draftReads++;
            if (unreadDraftsAfterCreate && draftReads > 1) {
              return ToolResult(
                exitCode: 1,
                stdout: '',
                stderr: 'GitHub could not be reached',
              );
            }
            return ToolResult(exitCode: 0, stdout: slurp, stderr: '');
          }
          if (key.startsWith('gh api -X DELETE')) {
            return ToolResult(exitCode: 0, stdout: '', stderr: '');
          }
          if (key.contains(' -X POST repos/example/tool/releases --input ')) {
            return ToolResult(
              exitCode: createFailure == null ? 0 : 1,
              stdout: createFailure == null ? jsonEncode({'id': 7}) : '',
              stderr: createFailure ?? '',
            );
          }
          if (key.contains('uploads.github.com')) {
            final fails = uploadFailure != null && uploadCount == 1;
            return ToolResult(
              exitCode: fails ? 1 : 0,
              stdout: '',
              stderr: fails ? uploadFailure : '',
            );
          }
          if (exactSameTagDownloadAvailable &&
              key.startsWith('gh release download ')) {
            return ToolResult(exitCode: 0, stdout: '', stderr: '');
          }
          if (RegExp(r'^gh api repos/example/tool/releases/\d+$')
              .hasMatch(key)) {
            final id = int.parse(key.split('/').last);
            return ToolResult(
              exitCode: 0,
              stdout: jsonEncode({
                'tag_name': 'v1.0.0',
                'draft': draft,
                'prerelease': prerelease,
                'id': id,
                'name': draftTitle,
                'body': draftBody,
                'assets': [
                  for (var index = 0; index < assets.length; index++)
                    draftAssetJson(assets.keys.elementAt(index), index),
                ],
              }),
              stderr: '',
            );
          }
          if (key.contains(' -X PATCH repos/example/tool/releases/7 ')) {
            return ToolResult(
              exitCode: patchFails ? 1 : 0,
              stdout: '',
              stderr: patchFails ? 'connection lost' : '',
            );
          }
          return null;
        },
      );
      final outcome = await GithubRelease(
        tools: tools,
        repository: 'example/tool',
        workingDirectory: '/repo',
      ).publish(
        tag: 'v1.0.0',
        title: 'tool 1.0.0',
        notesPath: notes.path,
        prerelease: prerelease,
        assets: [
          for (final path in paths)
            GithubReleaseAssetUpload(
              publicName: path.split('/').last,
              stagedPath: path,
              size: File(path).lengthSync(),
              sha256: Sha256.hex(File(path).readAsBytesSync()),
            ),
        ],
      );
      return (
        outcome: outcome,
        tools: tools,
        createPayload: createPayload,
        publishPayload: publishPayload,
      );
    }

    test('prerelease metadata is frozen across draft creation and publish',
        () async {
      final run = await publish(prerelease: true);

      expect(run.outcome.ok, isTrue, reason: run.outcome.problem ?? '');
      expect(run.createPayload, containsPair('draft', true));
      expect(run.createPayload, containsPair('prerelease', true));
      expect(run.publishPayload, containsPair('draft', false));
      expect(run.publishPayload, containsPair('prerelease', true));
      expect(run.createPayload, isNot(contains('make_latest')));
      expect(run.publishPayload, isNot(contains('make_latest')));
    });

    test('multiple same-tag drafts refuse without deleting or creating',
        () async {
      final run = await publish(
        slurp: jsonEncode([
          [
            {
              'tag_name': 'v1.0.0',
              'draft': true,
              'prerelease': false,
              'id': 11,
            },
            {
              'tag_name': 'v1.0.0',
              'draft': false,
              'prerelease': false,
              'id': 99,
            },
          ],
          [
            {
              'tag_name': 'v1.0.0',
              'draft': true,
              'prerelease': false,
              'id': 12,
            },
            {
              'tag_name': 'v2.0.0',
              'draft': true,
              'prerelease': false,
              'id': 13,
            },
          ],
        ]),
      );
      expect(run.outcome.ok, isFalse);
      expect(
          run.outcome.problem, contains('will not choose, replace, or delete'));
      expect(run.outcome.draftEffect, DraftEffect.none);
      expect(
          run.tools.calls.any((call) => call.contains(' -X DELETE ')), isFalse);
      expect(
          run.tools.calls.any((call) => call.contains(' -X POST ')), isFalse);
    });

    test('a malformed draft sweep refuses before creating another draft',
        () async {
      final run = await publish(
          slurp: jsonEncode([
        {'not': 'a page'}
      ]));
      expect(run.outcome.ok, isFalse);
      expect(run.outcome.problem, contains('could not be read'));
      expect(run.outcome.draftEffect, DraftEffect.none);
      expect(
        run.tools.calls.any(
          (call) => call.contains('POST repos/example/tool/releases'),
        ),
        isFalse,
      );
    });

    test('local request validation runs before any remote read or mutation',
        () async {
      final run = await publish(
        slurp: jsonEncode([
          [
            {
              'tag_name': 'v1.0.0',
              'draft': true,
              'prerelease': false,
              'id': 11,
            },
          ],
        ]),
        duplicateAssetNames: true,
      );

      expect(run.outcome.ok, isFalse);
      expect(run.outcome.mayHaveActed, isFalse);
      expect(run.outcome.draftEffect, DraftEffect.none);
      expect(run.tools.calls, isEmpty);
    });

    test('one exact draft subset is adopted and only its difference uploads',
        () async {
      final run = await publish(
        slurp: jsonEncode([
          [
            {
              'tag_name': 'v1.0.0',
              'draft': true,
              'prerelease': false,
              'id': 11,
            },
          ],
        ]),
        initialDraftNames: const ['b.tar.gz'],
      );

      expect(run.outcome.ok, isTrue, reason: run.outcome.problem ?? '');
      expect(
        run.tools.calls.where((call) => call.contains('uploads.github.com')),
        hasLength(1),
      );
      expect(
        run.tools.calls
            .singleWhere((call) => call.contains('uploads.github.com')),
        contains('name=a.tar.gz'),
      );
      expect(
        run.tools.calls.any(
          (call) => call.contains('POST repos/example/tool/releases --input'),
        ),
        isFalse,
      );
      expect(
          run.tools.calls.any((call) => call.contains(' -X DELETE ')), isFalse);
    });

    test('a complete exact draft publishes without re-uploading assets',
        () async {
      final run = await publish(
        slurp: jsonEncode([
          [
            {
              'tag_name': 'v1.0.0',
              'draft': true,
              'prerelease': false,
              'id': 11,
            },
          ],
        ]),
        initialDraftNames: const ['b.tar.gz', 'a.tar.gz'],
      );

      expect(run.outcome.ok, isTrue, reason: run.outcome.problem ?? '');
      expect(
        run.tools.calls.any((call) => call.contains('uploads.github.com')),
        isFalse,
      );
      expect(
        run.tools.calls.any((call) => call.contains(' -X PATCH ')),
        isTrue,
      );
    });

    test('an existing subset with different bytes refuses before upload',
        () async {
      final run = await publish(
        slurp: jsonEncode([
          [
            {
              'tag_name': 'v1.0.0',
              'draft': true,
              'prerelease': false,
              'id': 11,
            },
          ],
        ]),
        initialDraftNames: const ['b.tar.gz'],
        draftAssetOverrides: {
          'b.tar.gz': utf8.encode('wrong archive bytes'),
        },
      );

      expect(run.outcome.ok, isFalse);
      expect(run.outcome.draftEffect, DraftEffect.none);
      expect(run.outcome.problem, contains('staged release'));
      expect(
        run.tools.calls.any((call) =>
            call.contains('uploads.github.com') || call.contains(' -X PATCH ')),
        isFalse,
      );
    });

    test('an extra asset or different metadata refuses without mutation',
        () async {
      for (final scenario in [
        (names: const ['extra.zip'], title: 'tool 1.0.0'),
        (names: const <String>[], title: 'Different'),
      ]) {
        final run = await publish(
          slurp: jsonEncode([
            [
              {
                'tag_name': 'v1.0.0',
                'draft': true,
                'prerelease': false,
                'id': 11,
              },
            ],
          ]),
          initialDraftNames: scenario.names,
          draftTitle: scenario.title,
        );
        expect(run.outcome.ok, isFalse, reason: '$scenario');
        expect(run.outcome.draftEffect, DraftEffect.none);
        expect(
          run.tools.calls.any((call) =>
              call.contains('uploads.github.com') ||
              call.contains(' -X PATCH ') ||
              call.contains(' -X DELETE ')),
          isFalse,
        );
      }
    });

    test('a lost create response reports uncertain private state, not public',
        () async {
      final run = await publish(
        createFailure: 'connection lost',
        unreadDraftsAfterCreate: true,
      );

      // gh is what failed, and after this returns nobody can ask it again.
      expect(run.outcome.transcript, contains('connection lost'));

      expect(run.outcome.ok, isFalse);
      expect(run.outcome.mayHaveActed, isFalse);
      expect(run.outcome.draftEffect, DraftEffect.uncertain);
      expect(run.outcome.problem, contains('could not be identified'));
    });

    test('a failed create proved absent reports no private effect', () async {
      final run = await publish(createFailure: 'request rejected');

      expect(run.outcome.ok, isFalse);
      expect(run.outcome.mayHaveActed, isFalse);
      expect(run.outcome.draftEffect, DraftEffect.none);
    });

    test('the public PATCH runs only after every upload and the draft gate',
        () async {
      final run = await publish();
      expect(run.outcome.ok, isTrue, reason: run.outcome.problem ?? '');
      expect(run.outcome.draftEffect, DraftEffect.changed);
      final create = run.tools.calls.indexWhere(
          (call) => call.contains('POST repos/example/tool/releases'));
      final uploads = [
        for (var i = 0; i < run.tools.calls.length; i++)
          if (run.tools.calls[i].contains('uploads.github.com')) i,
      ];
      final reads = [
        for (var i = 0; i < run.tools.calls.length; i++)
          if (run.tools.calls[i] == 'gh api repos/example/tool/releases/7') i,
      ];
      final patch = run.tools.calls.indexWhere(
          (call) => call.contains('PATCH repos/example/tool/releases/7'));
      expect(create, greaterThanOrEqualTo(0));
      expect(uploads, hasLength(2));
      expect(reads, hasLength(3));
      expect(create, lessThan(reads.first));
      expect(reads.first, lessThan(uploads.first));
      expect(uploads.last, lessThan(reads[1]));
      expect(reads[1], lessThan(patch));
      expect(patch, lessThan(reads.last));
      for (final index in uploads) {
        final call = run.tools.calls[index];
        expect(
          call,
          contains(
            'https://uploads.github.com/repos/example/tool/releases/7/'
            'assets?name=',
          ),
        );
        expect(
          call,
          isNot(contains('--hostname uploads.github.com')),
          reason: 'uploads use the github.com credential through gh\'s '
              'absolute-URL transport, not a nonexistent second host login',
        );
      }
      expect(
        run.tools.calls.any((call) => call.startsWith('gh release download ')),
        isFalse,
        reason: 'private proof is bound to release id 7, not a tag lookup',
      );
    });

    test('an upload failure leaves only a private draft and never PATCHes',
        () async {
      final run = await publish(uploadFailure: 'connection lost');
      expect(run.outcome.ok, isFalse);
      expect(run.outcome.mayHaveActed, isFalse);
      expect(run.outcome.draftEffect, DraftEffect.changed);
      expect(run.outcome.problem, contains('private draft'));
      expect(
        run.tools.calls.any((call) => call.contains(' -X PATCH ')),
        isFalse,
      );
    });

    test('a lost upload response reconciles only from its exact draft digest',
        () async {
      final run = await publish(
        uploadFailure: 'connection lost',
        failedUploadLands: true,
      );
      expect(run.outcome.ok, isTrue, reason: run.outcome.problem ?? '');
      expect(
        run.tools.calls.any((call) => call.contains(' -X PATCH ')),
        isTrue,
      );
      final uploads = [
        for (var i = 0; i < run.tools.calls.length; i++)
          if (run.tools.calls[i].contains('uploads.github.com')) i,
      ];
      final draftReads = [
        for (var i = 0; i < run.tools.calls.length; i++)
          if (run.tools.calls[i] == 'gh api repos/example/tool/releases/7') i,
      ];
      expect(draftReads[1], greaterThan(uploads.first));
      expect(draftReads[1], lessThan(uploads.last));
    });

    test('exact same-tag bytes cannot mask wrong bytes on the draft id',
        () async {
      final run = await publish(
        draftAssetOverrides: {
          'a.tar.gz': utf8.encode('wrong archive bytes'),
        },
        exactSameTagDownloadAvailable: true,
      );

      expect(run.outcome.ok, isFalse);
      expect(run.outcome.mayHaveActed, isFalse);
      expect(run.outcome.draftEffect, DraftEffect.changed);
      expect(
          run.outcome.problem, contains('does not contain the staged bytes'));
      expect(
        run.tools.calls.any((call) => call.contains(' -X PATCH ')),
        isFalse,
      );
      expect(
        run.tools.calls.any((call) => call.startsWith('gh release download ')),
        isFalse,
      );
    });

    test('a named truncated asset cannot reconcile a lost upload response',
        () async {
      final run = await publish(
        uploadFailure: 'connection lost',
        failedUploadLands: true,
        draftAssetOverrides: {
          'b.tar.gz': utf8.encode('truncated'),
        },
      );

      expect(run.outcome.ok, isFalse);
      expect(run.outcome.mayHaveActed, isFalse);
      expect(run.outcome.draftEffect, DraftEffect.changed);
      expect(
          run.outcome.problem, contains('does not contain the staged bytes'));
      expect(
        run.tools.calls.any((call) => call.contains(' -X PATCH ')),
        isFalse,
      );
    });

    test('a draft made public during ambiguous upload is reported as public',
        () async {
      final run = await publish(
        uploadFailure: 'connection lost',
        failedUploadLands: true,
        failedUploadPublishes: true,
      );

      expect(run.outcome.ok, isFalse);
      expect(run.outcome.mayHaveActed, isTrue);
      expect(run.outcome.draftEffect, DraftEffect.changed);
      expect(run.outcome.problem, contains('became public'));
      expect(
        run.tools.calls.any((call) => call.contains(' -X PATCH ')),
        isFalse,
      );
    });

    test('a lost final PATCH response reconciles by immutable release id',
        () async {
      final run = await publish(patchFails: true, failedPatchLands: true);
      expect(run.outcome.ok, isTrue, reason: run.outcome.problem ?? '');
    });

    test('a successful upload with a missing draft asset is never published',
        () async {
      final run = await publish(successfulUploadLands: false);
      expect(run.outcome.ok, isFalse);
      expect(run.outcome.problem, contains('incomplete'));
      expect(
        run.tools.calls.any((call) => call.contains(' -X PATCH ')),
        isFalse,
      );
    });
  });

  group('latest published GitHub Release', () {
    Future<Inspection> latest(ToolResult result) => GithubRelease(
          tools: RecordingTools(results: {
            'gh api --paginate --slurp repos/example/tool/releases': result,
          }),
          repository: 'example/tool',
          workingDirectory: '/repo',
        ).inspectLatestVersion('v{version}');

    test('reads all pages and excludes private drafts', () async {
      final result = await latest(ToolResult(
        exitCode: 0,
        stdout: jsonEncode([
          [
            {'tag_name': 'v1.9.0', 'draft': false},
            {'tag_name': 'v9.0.0', 'draft': true},
          ],
          [
            {'tag_name': 'v1.10.0', 'draft': false},
            {'tag_name': 'docs', 'draft': false},
          ],
        ]),
        stderr: '',
      ));
      expect(result.verdict, Verdict.exact);
      expect(result.evidence['version'], '1.10.0');
    });

    test('no matching published release is absent', () async {
      final result = await latest(ToolResult(
        exitCode: 0,
        stdout: jsonEncode([
          [
            {'tag_name': 'v2.0.0', 'draft': true},
            {'tag_name': 'docs', 'draft': false},
          ],
        ]),
        stderr: '',
      ));
      expect(result.verdict, Verdict.absent);
    });

    test('malformed pagination is unknown', () async {
      final result = await latest(ToolResult(
        exitCode: 0,
        stdout: jsonEncode([
          {'tag_name': 'v1.0.0', 'draft': false},
        ]),
        stderr: '',
      ));
      expect(result.verdict, Verdict.unknown);
    });

    test('an unreadable release list is unknown', () async {
      final result = await latest(ToolResult(
        exitCode: 1,
        stdout: '',
        stderr: 'network unavailable',
      ));
      expect(result.verdict, Verdict.unknown);
    });
  });
}

class _DownloadTools implements Tools {
  _DownloadTools({
    required this.response,
    required this.downloads,
    this.downloadFailure,
    this.omitDownloadedFile = false,
  });

  final String response;
  final Map<String, List<int>> downloads;
  final String? downloadFailure;
  final bool omitDownloadedFile;
  final List<String> downloadRequests = [];

  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    if (executable == 'gh' &&
        arguments.length >= 2 &&
        arguments.first == 'api') {
      return ToolResult(exitCode: 0, stdout: response, stderr: '');
    }
    if (executable == 'gh' &&
        arguments.length >= 2 &&
        arguments[0] == 'release' &&
        arguments[1] == 'download') {
      if (downloadFailure != null) {
        return ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: downloadFailure!,
        );
      }
      final name = arguments[arguments.indexOf('--pattern') + 1];
      downloadRequests.add(name);
      final output = arguments[arguments.indexOf('--output') + 1];
      final bytes = downloads[name];
      if (bytes == null) {
        return ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: '$name is not downloadable',
        );
      }
      if (!omitDownloadedFile) {
        await File(output).writeAsBytes(bytes);
      }
      return ToolResult(exitCode: 0, stdout: '', stderr: '');
    }
    return ToolResult(
      exitCode: 127,
      stdout: '',
      stderr: '$executable ${arguments.join(' ')} was not scripted',
    );
  }

  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async =>
      0;
}

class _ConcurrentDownloadTools implements Tools {
  _ConcurrentDownloadTools({required this.response, required this.downloads});

  final String response;
  final Map<String, List<int>> downloads;
  var active = 0;
  var maxActive = 0;

  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    if (executable == 'gh' && arguments.first == 'api') {
      return ToolResult(exitCode: 0, stdout: response, stderr: '');
    }
    if (executable == 'gh' &&
        arguments.length >= 2 &&
        arguments[0] == 'release' &&
        arguments[1] == 'download') {
      active++;
      if (active > maxActive) maxActive = active;
      try {
        // Long enough for every independently-started future to enter. A
        // serial implementation can never make maxActive exceed one.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final name = arguments[arguments.indexOf('--pattern') + 1];
        final output = arguments[arguments.indexOf('--output') + 1];
        await File(output).writeAsBytes(downloads[name]!);
        return ToolResult(exitCode: 0, stdout: '', stderr: '');
      } finally {
        active--;
      }
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
