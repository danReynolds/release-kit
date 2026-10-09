import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/pubspec.dart';
import 'package:rk/src/output/output.dart';
import 'package:test/test.dart';

import 'release_test.dart' show release;
import 'status_test.dart' show FakeRegistry;
import 'support/memory_source_tree.dart';

Pubspec _parse(String source) {
  final diagnostics = Diagnostics();
  final pubspec = Pubspec.parse(source, 'pubspec.yaml', diagnostics);
  expect(diagnostics.found, isEmpty);
  return pubspec!;
}

void main() {
  test(
    'a dependency with no constraint allows any version, as Pub reads it',
    () {
      final pubspec = _parse('''
name: keybay
version: 0.2.0
dependencies:
  bare:
  tilde: ~
  spelled: null
dev_dependencies:
  test:
''');
      for (final name in ['bare', 'tilde', 'spelled']) {
        final dependency = pubspec.dependencies[name]!;
        expect(dependency.kind, DependencyKind.hosted, reason: name);
        expect(dependency.constraint, 'any', reason: name);
      }
      expect(pubspec.devDependencies['test']!.constraint, 'any');
    },
  );

  test('a quoted empty constraint is kept for Pub to refuse', () {
    final pubspec = _parse('name: keybay\ndependencies:\n  quoted: ""\n');
    expect(pubspec.dependencies['quoted']!.constraint, '');
  });

  test('a package with a bare dependency stages', () async {
    const config = '''
schema = 2

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]
''';
    final ran = await release(
      only: 'core',
      config: config,
      source: MemorySourceTree({
        'packages/keybay/pubspec.yaml':
            'name: keybay\nversion: 0.2.0\ndev_dependencies:\n  test:\n',
        'packages/keybay/CHANGELOG.md': '## 0.2.0\n',
      }, description: '/repo/keybay'),
      registry: FakeRegistry({
        'keybay': ['0.1.0'],
      }),
      dryRun: true,
    );
    expect(ran.exitCode, ExitCodes.ok, reason: ran.text);
  });
}
