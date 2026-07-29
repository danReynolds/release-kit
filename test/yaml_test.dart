import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/yaml.dart';
import 'package:test/test.dart';

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

  test('a # inside a URL is not a comment', () {
    final doc = parse('homepage: https://danreynolds.github.io/keybay/#cli');
    expect(doc.string('homepage'), 'https://danreynolds.github.io/keybay/#cli');
  });

  test('a trailing comment is removed', () {
    final doc = parse('version: 0.1.0  # the released version');
    expect(doc.string('version'), '0.1.0');
  });

  test('a folded description does not swallow the keys after it', () {
    final doc = parse('''
name: keybay
description: >-
  Cross-platform secret storage for Dart without Flutter: native Data
  Protection Keychain items on Apple platforms where available.
version: 0.1.0
''');
    expect(doc.string('name'), 'keybay');
    expect(doc.string('version'), '0.1.0');
    expect(doc.string('description'), contains('Cross-platform'));
  });

  test('a colon inside a folded scalar does not become a key', () {
    final doc = parse('''
description: >-
  Cross-platform secret storage for Dart without Flutter: native items.
version: 0.1.0
''');
    expect(doc.keys, ['description', 'version']);
  });

  test('reads block sequences', () {
    final doc = parse('''
name: keybay
topics:
  - security
  - secrets
version: 0.1.0
''');
    expect(doc.list('topics')!.strings, ['security', 'secrets']);
    expect(doc.string('version'), '0.1.0', reason: 'the list closes properly');
  });

  test('reads a workspace list', () {
    final doc = parse('''
name: keybay_workspace
workspace:
  - packages/keybay
  - packages/keybay_cli
''');
    expect(doc.list('workspace')!.strings, hasLength(2));
  });

  test('reads a path dependency as a nested map', () {
    final doc = parse('''
dependencies:
  dune_core:
    path: ../dune_core
  stdio: ^0.4.0
''');
    final deps = doc.map('dependencies')!;
    expect(deps.map('dune_core')!.string('path'), '../dune_core');
    expect(deps.string('stdio'), '^0.4.0');
  });

  test('an executable with no explicit script is still a key', () {
    final doc = parse('''
executables:
  rk:
''');
    expect(doc.map('executables')!.keys, ['rk']);
  });

  test('quoted values are unquoted', () {
    final doc = parse('''
name: "keybay"
publish_to: 'none'
''');
    expect(doc.string('name'), 'keybay');
    expect(doc.string('publish_to'), 'none');
  });

  test('remembers the line a key was written on', () {
    final doc = parse('name: keybay\n\nversion: 0.1.0');
    expect(doc.lineOf('version'), 3);
  });

  test('unfamiliar fields are carried, not refused', () {
    final doc = parse('''
name: keybay
screenshots:
  - description: a shot
    path: doc/shot.png
false_secrets:
  - /example/**
version: 0.1.0
''');
    expect(doc.string('version'), '0.1.0');
    expect(doc.has('screenshots'), isTrue);
  });

  test('tabs for indentation are refused', () {
    final diagnostics = Diagnostics();
    final doc = parseYaml(
      'environment:\n\tsdk: ^3.6.0',
      'pubspec.yaml',
      diagnostics,
    );
    expect(doc, isNull);
    expect(diagnostics.found.single.message, contains('tabs'));
  });
}
