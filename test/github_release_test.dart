import 'dart:convert';

import 'package:rk/src/destinations/github_release.dart';
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

  String view({
    bool draft = false,
    List<String> assets = const ['tool-1.0.0-macos-arm64.tar.gz'],
  }) =>
      jsonEncode({
        'tagName': 'v1.0.0',
        'isDraft': draft,
        'name': 'v1.0.0',
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
    test('release not found + repository readable → absent', () async {
      final state = await inspect([
        (code: 1, out: '', err: 'release not found'),
        (code: 0, out: '{"name":"tool"}', err: ''),
      ]);
      expect(state.verdict, Verdict.absent);
    });

    test('release not found + repository unreadable → unknown', () async {
      final state = await inspect([
        (code: 1, out: '', err: 'release not found'),
        (code: 1, out: '', err: 'Could not resolve to a Repository'),
      ]);
      expect(
        state.verdict,
        Verdict.unknown,
        reason: 'gh says the same words for a missing release and a typo in '
            'the origin, and absent is what lets a release proceed',
      );
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
}
