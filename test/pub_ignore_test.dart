import 'package:release_kit/src/engine/pub_ignore.dart';
import 'package:test/test.dart';

/// Frozen vectors, like the version grammar's.
///
/// This matcher decides whether a file absent from a published archive was
/// excluded on purpose or lost, so a wrong answer either accuses a good
/// release or blesses a bad one. Over-matching is the dangerous direction:
/// it silences a file that is genuinely missing.
void main() {
  bool excluded(String patterns, String path) =>
      PubIgnore.parse(patterns).excludes(path);

  group('the shapes rk actually ships', () {
    test('a directory pattern takes everything beneath it', () {
      expect(excluded('test/', 'test/a_test.dart'), isTrue);
      expect(excluded('test/', 'test/deep/nested/b_test.dart'), isTrue);
      expect(
        excluded('test/', 'test'),
        isFalse,
        reason: 'the trailing slash says directory, and a file named test '
            'is not one',
      );
      expect(excluded('test/', 'lib/test/helper.dart'), isTrue,
          reason: 'unanchored, so it matches at any depth');
    });

    test('a bare name matches the file and the directory of that name', () {
      expect(excluded('tool', 'tool'), isTrue);
      expect(excluded('tool', 'tool/validate.dart'), isTrue);
      expect(excluded('tool', 'lib/tool'), isTrue);
      expect(excluded('tool', 'toolbox'), isFalse);
      expect(excluded('tool', 'lib/toolbox/x.dart'), isFalse);
    });

    test('a leading slash anchors to the package root', () {
      expect(excluded('/examples/', 'examples/demo/pubspec.yaml'), isTrue);
      expect(excluded('/examples/', 'lib/examples/demo.dart'), isFalse);
    });

    test('an embedded slash anchors too, as gitignore specifies', () {
      expect(excluded('doc/internal/', 'doc/internal/notes.md'), isTrue);
      expect(excluded('doc/internal/', 'lib/doc/internal/notes.md'), isFalse);
    });
  });

  group('wildcards stay inside one segment', () {
    test('* does not cross a separator', () {
      expect(excluded('*.dart', 'main.dart'), isTrue);
      expect(excluded('*.dart', 'lib/main.dart'), isTrue,
          reason: 'the pattern floats; the star still does not cross /');
      expect(excluded('lib/*.dart', 'lib/main.dart'), isTrue);
      expect(
        excluded('lib/*.dart', 'lib/src/main.dart'),
        isFalse,
        reason: 'a star that crossed the separator would silence every file '
            'in every subdirectory',
      );
    });

    test('? is exactly one non-separator character', () {
      expect(excluded('a?.txt', 'ab.txt'), isTrue);
      expect(excluded('a?.txt', 'a.txt'), isFalse);
      expect(excluded('a?.txt', 'a/.txt'), isFalse);
    });

    test('character classes, including negation', () {
      expect(excluded('[abc].dart', 'a.dart'), isTrue);
      expect(excluded('[a-c].dart', 'b.dart'), isTrue);
      expect(excluded('[!a].dart', 'b.dart'), isTrue);
      expect(excluded('[!a].dart', 'a.dart'), isFalse);
    });

    test('** spans directories, in each of its three legal positions', () {
      expect(excluded('**/build', 'a/b/build'), isTrue);
      expect(excluded('**/build', 'build'), isTrue);
      expect(excluded('doc/**', 'doc/a/b.md'), isTrue);
      expect(excluded('a/**/b', 'a/b'), isTrue);
      expect(excluded('a/**/b', 'a/x/y/b'), isTrue);
      expect(excluded('a/**/b', 'x/a/b'), isFalse);
    });
  });

  group('negation, last match wins', () {
    const patterns = '''
# everything under fixtures, except the one we ship
fixtures/
!fixtures/keep.json
''';

    test('the exception survives the sweep', () {
      expect(excluded(patterns, 'fixtures/big.bin'), isTrue);
      expect(excluded(patterns, 'fixtures/keep.json'), isFalse);
    });

    test('order decides, not specificity', () {
      expect(excluded('!a.txt\na.txt', 'a.txt'), isTrue);
      expect(excluded('a.txt\n!a.txt', 'a.txt'), isFalse);
    });
  });

  group('what rk refuses to guess at', () {
    test('an escape makes the whole file unjudgeable', () {
      final parsed = PubIgnore.parse('a\\#b\n');
      expect(parsed.isComplete, isFalse);
      expect(parsed.unsupported, contains('a\\#b'));
    });

    test('** used as a partial segment is refused, not approximated', () {
      // gitignore treats `a**b` as a single star; encoding that subtlety
      // silently is exactly how an over-matching parser blesses a bad
      // release, so it is declared instead.
      expect(PubIgnore.parse('a**b').isComplete, isFalse);
      expect(PubIgnore.parse('**a').isComplete, isFalse);
      expect(PubIgnore.parse('a/**b').isComplete, isFalse);
    });

    test('an unterminated character class is refused', () {
      expect(PubIgnore.parse('[abc').isComplete, isFalse);
      expect(PubIgnore.parse('[]').isComplete, isFalse);
    });

    test('comments and blank lines are neither rules nor refusals', () {
      final parsed = PubIgnore.parse('# a comment\n\n   \ntest/\n');
      expect(parsed.isComplete, isTrue);
      expect(parsed.excludes('test/x.dart'), isTrue);
    });

    test('rk\'s own .pubignore is one rk fully understands', () {
      // The dogfood check: the file shipped in this repository must never
      // be one that degrades rk's proof of its own releases.
      final parsed = PubIgnore.parse('test/\nexamples/\ntool/\n');
      expect(parsed.isComplete, isTrue);
      expect(parsed.excludes('test/status_test.dart'), isTrue);
      expect(parsed.excludes('examples/binary-cli/pubspec.yaml'), isTrue);
      expect(parsed.excludes('tool/validate.dart'), isTrue);
      expect(parsed.excludes('lib/src/engine/compare.dart'), isFalse);
      expect(parsed.excludes('bin/rk.dart'), isFalse);
      expect(parsed.excludes('doc/json.md'), isFalse);
      expect(parsed.excludes('LICENSE'), isFalse);
    });
  });
}
