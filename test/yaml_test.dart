import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/yaml.dart';
import 'package:test/test.dart';

// package:yaml parses; these pin what rk's adapter adds on top of it: text
// kept as written, the lines diagnostics point at, and rk's own refusals.

YamlMap parse(String source) {
  final diagnostics = Diagnostics();
  final document = parseYaml(source, 'pubspec.yaml', diagnostics);
  expect(
    document,
    isNotNull,
    reason: diagnostics.found.map((d) => d.toString()).join('\n'),
  );
  return document!;
}

void main() {
  test('reads keybay_cli\'s pubspec', () {
    final doc = parse('''
name: keybay_cli
description: Austere, local secret injection backed by Keybay.
version: 0.1.0
repository: https://github.com/danReynolds/keybay/tree/main/packages/keybay_cli
homepage: https://danreynolds.github.io/keybay/#cli

environment:
  sdk: ^3.10.0

resolution: workspace

dependencies:
  ffi: 2.2.0
  keybay: 0.1.0

dev_dependencies:
  lints: ^5.0.0
  test: ^1.25.0

executables:
  keybay: keybay
''');

    expect(doc.string('name'), 'keybay_cli');
    expect(doc.string('version'), '0.1.0');
    expect(doc.string('resolution'), 'workspace');
    expect(doc.map('environment')!.string('sdk'), '^3.10.0');
    expect(doc.map('dependencies')!.string('keybay'), '0.1.0');
    expect(doc.map('dev_dependencies')!.keys, contains('lints'));
    expect(doc.map('executables')!.string('keybay'), 'keybay');
  });

  test('an executable with no explicit script is still a key', () {
    final doc = parse('''
executables:
  rk:
''');
    expect(doc.map('executables')!.keys, ['rk']);
  });

  test('remembers the line a key was written on', () {
    final doc = parse('name: keybay\n\nversion: 0.1.0');
    expect(doc.lineOf('version'), 3);
  });

  test('a version keeps the text it was written as', () {
    // YAML would read 1.10 as a number; rk types nothing itself.
    final doc = parse('version: 1.10\nsdk: ^3.6.0\nflag: true\n');
    expect(doc.string('version'), '1.10');
    expect(doc.string('flag'), 'true');
  });

  test('reads what Pub reads: anchors, aliases, tags, explicit keys', () {
    final doc = parse('''
base: &base
  path: ../core
dependencies:
  core: *base
resolution: !!str workspace
? name
: keybay
''');
    expect(doc.map('dependencies')!.map('core')!.string('path'), '../core');
    expect(doc.string('resolution'), 'workspace');
    expect(doc.string('name'), 'keybay');
  });

  test('a nested key remembers its own line', () {
    final doc = parse('dependencies:\n  core:\n    path: ../core\n');
    expect(doc.lineOf('dependencies'), 1);
    expect(doc.map('dependencies')!.lineOf('core'), 2);
  });

  group('refuses what YAML refuses, at its line', () {
    for (final (label, source, line) in [
      ('a duplicate key', 'name: x\nversion: 0.1.0\nversion: 9.9.9\n', 3),
      ('a key under a scalar', 'dependencies: none\n  core:\n    path: x\n', 2),
      ('a list document', '- name: x\n', 1),
    ]) {
      test(label, () {
        final diagnostics = Diagnostics();
        expect(parseYaml(source, 'p.yaml', diagnostics), isNull);
        final found = diagnostics.found.single;
        expect(found.code, 'RK-YAML-001');
        expect(found.source?.line, line, reason: found.message);
      });
    }
  });
}
