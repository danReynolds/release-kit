import 'dart:convert';

import 'package:rk/src/destinations/github_release.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:test/test.dart';

import 'scripted_tools.dart';

/// The forge reader, whose whole inspect arm a mutation pass found protected
/// by nothing: a draft could read as published, a missing asset as exact, and
/// any gh failure as absent, and the suite stayed green.
void main() {
  Future<Inspection> inspect(
    List<({int code, String out, String err})> answers, {
    Set<String> expected = const {'tool-1.0.0-macos-arm64.tar.gz'},
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
    ).inspect('v1.0.0', expected);
  }

  // The REST shape, not the porcelain's: the reader asks `gh api`, whose
  // fields are snake_case and whose id is numeric.
  String view({
    bool draft = false,
    List<String> assets = const ['tool-1.0.0-macos-arm64.tar.gz'],
  }) =>
      jsonEncode({
        'tag_name': 'v1.0.0',
        'draft': draft,
        'id': 41,
        'assets': [
          for (final name in assets) {'name': name},
        ],
      });

  test('a published release with exactly the expected assets is exact',
      () async {
    final state = await inspect([(code: 0, out: view(), err: '')]);
    expect(state.verdict, Verdict.exact);
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
          'notary log or formula went missing, because nothing counted extras',
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

  group('publish: the sweep, the confirm, and the three outcomes', () {
    RecordingTools forge({
      required String slurp,
      Set<String> readBack = const {'a.tar.gz', 'SHA256SUMS'},
      bool readBackFails = false,
    }) =>
        RecordingTools(
          answers: (key) {
            if (key.startsWith('gh api --paginate --slurp')) {
              return ToolResult(exitCode: 0, stdout: slurp, stderr: '');
            }
            if (key.startsWith('gh api -X DELETE')) {
              return ToolResult(exitCode: 0, stdout: '', stderr: '');
            }
            if (key.startsWith('gh release create')) {
              return ToolResult(exitCode: 0, stdout: '', stderr: '');
            }
            if (key.startsWith('gh api repos/example/tool/releases/tags/')) {
              return readBackFails
                  ? ToolResult(exitCode: 1, stdout: '', stderr: 'HTTP 500 oops')
                  : ToolResult(
                      exitCode: 0,
                      stdout: jsonEncode({
                        'tag_name': 'v1.0.0',
                        'draft': false,
                        'id': 7,
                        'assets': [
                          for (final name in readBack) {'name': name},
                        ],
                      }),
                      stderr: '',
                    );
            }
            return null;
          },
        );

    Future<PublishOutcome> publish(RecordingTools tools) => GithubRelease(
          tools: tools,
          repository: 'example/tool',
          workingDirectory: '/repo',
        ).publish(
          tag: 'v1.0.0',
          title: 'tool 1.0.0',
          notesPath: '/notes.md',
          assetPaths: const ['/w/a.tar.gz', '/w/SHA256SUMS'],
        );

    test('same-tag drafts are deleted by id, across pages; nothing else is',
        () async {
      // Two drafts carry the tag on different pages — the porcelain delete
      // addressed whichever it found first, and a single-page read capped
      // at 100 missed the second entirely. A published release and another
      // tag's draft must both survive the sweep.
      final tools = forge(
        slurp: jsonEncode([
          [
            {'tag_name': 'v1.0.0', 'draft': true, 'id': 11},
            {'tag_name': 'v1.0.0', 'draft': false, 'id': 99},
          ],
          [
            {'tag_name': 'v1.0.0', 'draft': true, 'id': 12},
            {'tag_name': 'v2.0.0', 'draft': true, 'id': 13},
          ],
        ]),
      );
      final outcome = await publish(tools);
      expect(outcome.ok, isTrue, reason: outcome.problem ?? '');

      final deletes =
          tools.calls.where((c) => c.startsWith('gh api -X DELETE')).toList();
      expect(deletes, hasLength(2));
      expect(deletes.any((c) => c.endsWith('/releases/11')), isTrue);
      expect(deletes.any((c) => c.endsWith('/releases/12')), isTrue);
      expect(
        deletes.any((c) => c.endsWith('/releases/13')),
        isFalse,
        reason: 'another tag\'s draft is not in the way',
      );
      expect(
        deletes.any((c) => c.endsWith('/releases/99')),
        isFalse,
        reason: 'a published release is never swept',
      );
    });

    test(
        'a read-back short of its assets is terminal, with the permanent '
        'sentence', () async {
      final outcome = await publish(forge(
        slurp: '[[]]',
        readBack: const {'a.tar.gz'}, // SHA256SUMS never arrived
      ));
      expect(outcome.ok, isFalse);
      expect(
        outcome.isTerminal,
        isTrue,
        reason: 'a published release cannot be edited; sending an operator '
            'to retry it would be the worst instruction rk can give',
      );
      expect(outcome.problem, contains('SHA256SUMS'));
      expect(outcome.permanent, contains('cannot be edited'));
    });

    test('a read-back that fails is lostTrack, not failure and not success',
        () async {
      final outcome = await publish(forge(slurp: '[[]]', readBackFails: true));
      expect(outcome.ok, isFalse);
      expect(outcome.isTerminal, isFalse);
      expect(
        outcome.mayHaveActed,
        isTrue,
        reason: 'the create succeeded; something exists that rk could not '
            'read back',
      );
    });
  });
}
