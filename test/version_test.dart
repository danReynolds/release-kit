import 'package:release_kit/src/engine/version.dart';
import 'package:test/test.dart';

void main() {
  group('accepts canonical versions', () {
    for (final input in [
      '0.0.0',
      '1.2.3',
      '10.20.30',
      '0.1.0',
      '1.0.0-alpha',
      '1.0.0-alpha.1',
      '1.0.0-0.3.7',
      '1.0.0-x-y-z.-',
      '1.0.0+build',
      '1.0.0+21AF26D3-117B344092BD',
      '1.0.0-beta.2+exp.sha.5114f85',
    ]) {
      test(input, () {
        final version = Version.tryParse(input);
        expect(version, isNotNull, reason: 'should parse');
        expect(version!.canonical, input, reason: 'round-trips exactly');
      });
    }
  });

  group('rejects non-canonical input', () {
    for (final entry in {
      '': 'empty',
      'v1.2.3': 'leading v',
      ' 1.2.3': 'leading space',
      '1.2.3 ': 'trailing space',
      '1.2': 'omitted patch',
      '1': 'omitted minor and patch',
      '1.2.3.4': 'too many components',
      '01.2.3': 'leading zero in major',
      '1.02.3': 'leading zero in minor',
      '1.2.03': 'leading zero in patch',
      '1.2.x': 'non-numeric component',
      '-1.2.3': 'negative',
      '1.2.3-': 'empty prerelease',
      '1.2.3+': 'empty build',
      '1.2.3-alpha..1': 'empty prerelease identifier',
      '1.2.3-01': 'leading zero in numeric prerelease identifier',
      '1.2.3-alpha_1': 'underscore is not in the identifier grammar',
    }.entries) {
      test('${entry.value}: "${entry.key}"', () {
        expect(Version.tryParse(entry.key), isNull);
      });
    }
  });

  group('precedence', () {
    void ordered(List<String> ascending) {
      for (var i = 0; i < ascending.length - 1; i++) {
        final lower = Version.tryParse(ascending[i])!;
        final higher = Version.tryParse(ascending[i + 1])!;
        expect(
          lower < higher,
          isTrue,
          reason: '${ascending[i]} should precede ${ascending[i + 1]}',
        );
        expect(higher > lower, isTrue);
      }
    }

    test('numeric components', () {
      ordered(['1.0.0', '2.0.0', '2.1.0', '2.1.1']);
    });

    test('a prerelease precedes its release', () {
      ordered(['1.0.0-alpha', '1.0.0']);
    });

    test('prerelease identifiers, per SemVer 2.0.0', () {
      ordered([
        '1.0.0-alpha',
        '1.0.0-alpha.1',
        '1.0.0-alpha.beta',
        '1.0.0-beta',
        '1.0.0-beta.2',
        '1.0.0-beta.11',
        '1.0.0-rc.1',
        '1.0.0',
      ]);
    });

    test('numeric identifiers compare numerically, not as strings', () {
      ordered(['1.0.0-2', '1.0.0-11']);
    });

    test('numeric identifiers rank below alphanumeric', () {
      ordered(['1.0.0-1', '1.0.0-alpha']);
    });

    test('build metadata does not affect precedence', () {
      final a = Version.tryParse('1.0.0+one')!;
      final b = Version.tryParse('1.0.0+two')!;
      expect(a.compareTo(b), 0);
    });
  });

  group('identity is the canonical string, not precedence', () {
    test('build metadata distinguishes coordinates', () {
      final a = Version.tryParse('1.0.0+one')!;
      final b = Version.tryParse('1.0.0+two')!;
      expect(a.compareTo(b), 0, reason: 'equal precedence');
      expect(a == b, isFalse, reason: 'but different coordinates');
    });

    test('the same string is the same coordinate', () {
      expect(
        Version.tryParse('1.2.3-beta.1+exp'),
        Version.tryParse('1.2.3-beta.1+exp'),
      );
    });
  });

  test('prerelease is reported', () {
    expect(Version.tryParse('1.0.0-beta')!.isPrerelease, isTrue);
    expect(Version.tryParse('1.0.0')!.isPrerelease, isFalse);
    expect(
      Version.tryParse('1.0.0+build')!.isPrerelease,
      isFalse,
      reason: 'build metadata alone is not a prerelease',
    );
  });
}
