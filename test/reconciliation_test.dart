import 'package:rk/src/engine/reconciliation.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/engine/version.dart';
import 'package:test/test.dart';

void main() {
  group('append-only publication', () {
    test('verifies every comparable digest', () {
      final result = PublicReconciliation.appendOnly(
        label: 'package',
        expected: const {'archive'},
        published: const {'archive'},
        expectedProofs: const {'archive': 'sha256:$_a'},
        publishedProofs: const {'archive': 'sha256:$_a'},
      );

      expect(result.verdict, Verdict.exact);
      expect(result.evidence['comparison'], 'exact');
    });

    test('an occupied coordinate skips without inventing provenance', () {
      final result = PublicReconciliation.appendOnly(
        label: 'package',
        expected: const {'archive'},
        published: const {'archive'},
      );

      expect(result.verdict, Verdict.exact);
      expect(result.detail, 'already published');
      expect(result.evidence['comparison'], 'unavailable');
    });

    test('a known digest mismatch blocks', () {
      final result = PublicReconciliation.appendOnly(
        label: 'package',
        expected: const {'archive'},
        published: const {'archive'},
        expectedProofs: const {'archive': 'sha256:$_a'},
        publishedProofs: const {'archive': 'sha256:$_b'},
      );

      expect(result.verdict, Verdict.conflict);
      expect(result.evidence['archive'], contains(_b));
    });

    test('proof algorithms remain adapter-owned', () {
      final result = PublicReconciliation.appendOnly(
        label: 'package',
        expected: const {'archive'},
        published: const {'archive'},
        expectedProofs: const {'archive': 'sha512:abc'},
        publishedProofs: const {'archive': 'sha512:abc'},
      );

      expect(result.verdict, Verdict.exact);
      expect(result.evidence['archive'], 'sha512:abc');
    });

    test('missing or extra immutable members block', () {
      final result = PublicReconciliation.appendOnly(
        label: 'release',
        expected: const {'one', 'two'},
        published: const {'one', 'extra'},
      );

      expect(result.verdict, Verdict.conflict);
      expect(result.evidence, {'two': 'missing', 'extra': 'not expected'});
    });
  });

  group('moving channel', () {
    final intended = Version.tryParse('2.0.0')!;
    final authority = Object();

    test('matching bytes are complete', () {
      final result = PublicReconciliation.movingChannel(
        label: 'Homebrew cask',
        intendedVersion: intended,
        publishedVersion: intended,
        payloadMatches: true,
        publishedIdentity: 'sha256:$_a',
        unrecognizedDetail: 'not a recognizable channel',
        advanceAuthority: authority,
      );

      expect(result.verdict, Verdict.exact);
    });

    test('a recognizable older value authorizes one forward update', () {
      final result = PublicReconciliation.movingChannel(
        label: 'Homebrew cask',
        intendedVersion: intended,
        publishedVersion: Version.tryParse('1.0.0'),
        payloadMatches: false,
        publishedIdentity: 'sha256:$_a',
        unrecognizedDetail: 'not a recognizable channel',
        advanceAuthority: authority,
      );

      expect(result.verdict, Verdict.absent);
      expect(result.authority, same(authority));
    });

    test('same-version different bytes block', () {
      final result = PublicReconciliation.movingChannel(
        label: 'Homebrew cask',
        intendedVersion: intended,
        publishedVersion: intended,
        payloadMatches: false,
        publishedIdentity: 'sha256:$_a',
        unrecognizedDetail: 'not a recognizable channel',
        advanceAuthority: authority,
      );

      expect(result.verdict, Verdict.conflict);
      expect(result.detail, contains('different bytes'));
    });

    test('newer and unrecognized values block', () {
      final newer = PublicReconciliation.movingChannel(
        label: 'Homebrew cask',
        intendedVersion: intended,
        publishedVersion: Version.tryParse('3.0.0'),
        payloadMatches: false,
        publishedIdentity: 'sha256:$_a',
        unrecognizedDetail: 'not a recognizable channel',
        advanceAuthority: authority,
      );
      final unrecognized = PublicReconciliation.movingChannel(
        label: 'Homebrew cask',
        intendedVersion: intended,
        publishedVersion: null,
        payloadMatches: false,
        publishedIdentity: 'sha256:$_a',
        unrecognizedDetail: 'not a recognizable channel',
        advanceAuthority: authority,
      );

      expect(newer.verdict, Verdict.conflict);
      expect(unrecognized.verdict, Verdict.conflict);
    });
  });
}

const _a = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _b = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
