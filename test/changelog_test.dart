import 'package:rk/src/engine/changelog.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/version.dart';
import 'package:test/test.dart';

Version v(String text) => Version.tryParse(text)!;

void main() {
  group('finds an entry', () {
    for (final heading in [
      '## 0.2.0',
      '# 0.2.0',
      '### 0.2.0',
      '## 0.2.0 - 2026-07-29',
      '## [0.2.0]',
      '## [0.2.0] - 2026-07-29',
      '##0.2.0',
      '  ## 0.2.0',
    ]) {
      test('"$heading"', () {
        expect(
            Changelog.mentions('$heading\n\n- a change\n', v('0.2.0')), isTrue);
      });
    }

    test('among other entries', () {
      expect(
        Changelog.mentions('''
## 0.3.0

- later work

## 0.2.0

- the release being made
''', v('0.2.0')),
        isTrue,
      );
    });

    test('for a prerelease', () {
      expect(
        Changelog.mentions('## 0.2.0-beta.1\n', v('0.2.0-beta.1')),
        isTrue,
      );
    });
  });

  group('does not find one', () {
    test('when the version is only a prefix of another', () {
      expect(
        Changelog.mentions('## 0.2.01\n', v('0.2.0')),
        isFalse,
        reason: '0.2.01 is a different version',
      );
    });

    test('when a longer version starts with it', () {
      expect(Changelog.mentions('## 0.2.0-beta.1\n', v('0.2.0')), isFalse);
    });

    test('when the release is a prerelease and only the release is written',
        () {
      expect(Changelog.mentions('## 0.2.0\n', v('0.2.0-beta.1')), isFalse);
    });

    test('when the version appears in prose rather than a heading', () {
      expect(
        Changelog.mentions('Upgrading to 0.2.0 is recommended.\n', v('0.2.0')),
        isFalse,
        reason: 'a mention is not an entry',
      );
    });

    test('when the changelog is empty', () {
      expect(Changelog.mentions('', v('0.2.0')), isFalse);
    });
  });

  group('checking a package', () {
    test('passes when the entry is there', () {
      final diagnostics = Diagnostics();
      Changelog.check(
        tree: MemorySourceTree({
          'packages/keybay/CHANGELOG.md': '## 0.2.0\n\n- a change\n',
        }),
        manifestDirectory: 'packages/keybay',
        packageName: 'keybay',
        version: v('0.2.0'),
        diagnostics: diagnostics,
      );
      expect(diagnostics.isEmpty, isTrue);
    });

    test('reports a missing file with the path to create', () {
      final diagnostics = Diagnostics();
      Changelog.check(
        tree: MemorySourceTree({}),
        manifestDirectory: 'packages/keybay',
        packageName: 'keybay',
        version: v('0.2.0'),
        diagnostics: diagnostics,
      );
      expect(diagnostics.found.single.code, 'RK-CHG-001');
      expect(
        diagnostics.found.single.remedy,
        contains('packages/keybay/CHANGELOG.md'),
      );
    });

    test('reports a missing entry with the heading to add', () {
      final diagnostics = Diagnostics();
      Changelog.check(
        tree: MemorySourceTree({'CHANGELOG.md': '## 0.1.0\n'}),
        manifestDirectory: '.',
        packageName: 'keybay',
        version: v('0.2.0'),
        diagnostics: diagnostics,
      );
      expect(diagnostics.found.single.code, 'RK-CHG-002');
      expect(diagnostics.found.single.remedy, contains('## 0.2.0'));
    });
  });
}
