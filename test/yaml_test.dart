import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/yaml.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart' as yaml;

/// A document as plain Dart values, the way rk reads it.
Object? _fromRk(YamlNode node) => switch (node) {
  YamlScalar(:final value) => value,
  YamlList(:final items) => [for (final item in items) _fromRk(item)],
  YamlMap(:final entries) => {
    for (final entry in entries.entries) entry.key: _fromRk(entry.value),
  },
};

/// A document as plain Dart values, the way YAML reads it, with scalars as
/// the text rk keeps (rk types nothing; its accessors do).
Object? _fromYaml(Object? node) => switch (node) {
  null => '',
  yaml.YamlList() => [for (final item in node) _fromYaml(item)],
  yaml.YamlMap() => {
    for (final entry in node.entries) '${entry.key}': _fromYaml(entry.value),
  },
  _ => '$node',
};

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

  group('flow collections', () {
    test('topics and asset platforms, as pubspecs write them', () {
      final doc = parse('''
name: flark
topics: [markdown, editor, parser]
flutter:
  assets:
    - path: lib/assets/wasm/flark_parse.wasm
      platforms: [web]
version: 0.5.0
''');
      expect(doc.list('topics')!.strings, ['markdown', 'editor', 'parser']);
      final asset = doc.map('flutter')!.list('assets')!.items.single as YamlMap;
      expect(asset.list('platforms')!.strings, ['web']);
      expect(doc.string('version'), '0.5.0');
    });

    test('nested maps and lists, quoted scalars and a trailing comma', () {
      final doc = parse('''
dependencies: {core: {path: ../core}, http: "^1.0.0", url: {hosted: https://x.dev/pub}}
list: ['a, b', "c]d", [e, f], {g: h},]
''');
      final dependencies = doc.map('dependencies')!;
      expect(dependencies.map('core')!.string('path'), '../core');
      expect(dependencies.string('http'), '^1.0.0');
      expect(dependencies.map('url')!.string('hosted'), 'https://x.dev/pub');
      final items = doc.list('list')!.items;
      expect(items.length, 4);
      expect(doc.list('list')!.strings, ['a, b', 'c]d']);
      expect((items[2] as YamlList).strings, ['e', 'f']);
      expect((items[3] as YamlMap).string('g'), 'h');
    });

    test('continued over several lines', () {
      final doc = parse('''
topics: [
  markdown,   # the format
  editor,
]
version: 1.0.0
''');
      expect(doc.list('topics')!.strings, ['markdown', 'editor']);
      expect(doc.string('version'), '1.0.0');
    });

    test('escapes inside quoted flow scalars', () {
      final doc = parse('''
list: ['it''s', "a \\"b\\""]
''');
      expect(doc.list('list')!.strings, ["it's", 'a "b"']);
    });

    test('a quote inside a plain scalar does not hold a collection open', () {
      final doc = parse('''
list: [it's,
  fine]
version: 1.0.0
''');
      expect(doc.list('list')!.strings, ["it's", 'fine']);
      expect(doc.string('version'), '1.0.0');
    });

    for (final (label, source, reason) in [
      ('an anchor', 'list: [&a x]\n', 'anchors'),
      ('an alias', 'list: [*a]\n', 'anchors'),
      ('a duplicate key', 'map: {a: 1, a: 2}\n', 'more than once'),
      ('text after the collection', 'list: [a] b\n', 'unexpected'),
      ('mismatched brackets', 'list: [a, b}\n', 'expected "," or "]"'),
    ]) {
      test('$label is refused', () {
        final diagnostics = Diagnostics();
        expect(parseYaml(source, 'p.yaml', diagnostics), isNull);
        expect(diagnostics.found.single.message, contains(reason));
      });
    }
  });

  group('agrees with the YAML parser', () {
    // Each is valid YAML that an earlier reader either refused or read as
    // something else; a path dependency hidden that way is what rk refuses.
    for (final (label, source) in [
      (
        'a flow map below its key',
        'dependencies:\n  core:\n    {path: ../core}\n',
      ),
      (
        'a flow map that opens a block',
        'dependencies:\n  {core:\n    {path: ../core}}\nname: x\n',
      ),
      (
        'an escaped quote before a comment sign',
        'false_secrets: ["a\\" # b"]\ndescription: x"]\n'
            'dependencies:\n  core:\n    path: ../core\n',
      ),
      (
        'a plain scalar with an apostrophe beside a quoted one',
        "topics: [it's, 'a # b']\ndescription: x']\n"
            'dependencies:\n  core:\n    path: ../core\n',
      ),
      ('a doubled quote before a bracket', "topics: ['it''s [x']\n"),
      ('a quoted scalar across lines', 'list: ["a\n  b # c"]\nname: x\n'),
      ('JSON-style adjacent values', 'map: {"a":"b # c", "d":[1,2]}\n'),
      ('an apostrophe before a comment', "description: don't # comment\n"),
      (
        'a wrapped description',
        'description: A long\n  description, wrapped.\nversion: 1.0.0\n',
      ),
      (
        'a description below its key',
        'description:\n  A long description\n\n  over lines.\nversion: 1.0.0\n',
      ),
      (
        'a path below its key',
        'dependencies:\n  core:\n    path:\n      ../core\n',
      ),
      ('a document marker', '---\nname: x\n'),
      ("a doubled quote in a single-quoted key", "'it''s': 'a''b'\n"),
      ('escapes in a double-quoted value', 'resolution: "work\\x73pace"\n'),
      (
        'escapes in a double-quoted key',
        'dependency_overrides:\n  "le\\x61f": 1.0.0\n',
      ),
      ('a quoted value over two lines', 'description: "a\n  b"\nname: x\n'),
      (
        'a quoted value over a blank line',
        "description: 'a\n\n  b'\nname: x\n",
      ),
      ('an escaped line break', 'description: "a\\\n  b"\nname: x\n'),
      (
        'a plain continuation that starts with a quote',
        "description: a\n  'b # c\nname: x\n",
      ),
      ('a bare dash item', 'list:\n  -\n  - x\n'),
      ('a tab after the colon', 'dependency_overrides:\t{leaf: 1.0.0}\n'),
      (
        'a plain key with a colon before a quote',
        "k: [a:'b, 'a # }']\nresolution: workspace\n",
      ),
      (
        'a quoted flow scalar over a blank line',
        "k: [ 'a #\n\n   b', c ]\nname: x\n",
      ),
      (
        'lone carriage returns breaking lines',
        'description: a\rdependency_overrides:\r  leaf: 1.0.0\r',
      ),
      ('an escaped space before a line break', 'k: "a\\ \n  b"\n'),
      ('an escaped tab before a line break', 'k: "a\\\t\n  b"\n'),
      ("a question mark inside a plain scalar", "k: a ? 'b # c'\n"),
      ('a dash inside a plain scalar', "k: a - 'b # c'\n"),
      ('a flow line ending in spaces', 'k: [a  \n  b]\n'),
      (
        'a comment line in a flow at its key\'s column',
        'topics: [\n  a,\n# b,\n  c,\n]\n',
      ),
    ]) {
      test(label, () {
        expect(_fromRk(parse(source)), _fromYaml(yaml.loadYaml(source)));
      });
    }
  });

  test('white space is spaces and tabs, not every Unicode space', () {
    // A no-break space starts the key's text in YAML, so this is not the
    // dependency_overrides key rk would find with Dart's trim.
    final nbsp = String.fromCharCode(0xA0);
    final source = 'name: x\n${nbsp}dependency_overrides: 1\n';
    final diagnostics = Diagnostics();
    final document = parseYaml(source, 'p.yaml', diagnostics);
    if (document != null) {
      expect(_fromRk(document), _fromYaml(yaml.loadYaml(source)));
      expect(document.has('dependency_overrides'), isFalse);
    }
  });

  group('refuses what it would misread', () {
    for (final (label, source) in [
      (
        'an anchor on a block',
        'dependencies: &deps\n  core:\n    path: ../core\n',
      ),
      ('a tag on a flow map', 'dependencies: !!map {core: {path: ../core}}\n'),
      ('an alias item', 'topics:\n  - *topic\n'),
      ('a complex key', '? name\n: x\n'),
      ('a second document', 'name: x\n---\nname: y\n'),
      ('a list document', '- name: x\n'),
      (
        'a key under a scalar',
        'dependencies: none\n  core:\n    path: ../core\n',
      ),
      ('entries after a flow value', 'core:\n  {path: ../core}\n  extra: 1\n'),
      ('a tag below its key', 'resolution:\n  !!str workspace\n'),
      ('an anchor below its key', 'x:\n  &w workspace\nresolution: y\n'),
      ('an alias below its key', 'resolution:\n  *w\n'),
      ('a block scalar header below its key', 'description:\n  |\n    text\n'),
      ('a sequence nested on its item line', 'list:\n  - - x\n'),
      ('a complex key in a sequence item', 'list:\n  - ? x\n'),
      ('a pair in a flow sequence', 'list: [a: b]\n'),
      ('an explicit key in a flow map', 'map: {? leaf : 1}\n'),
      ('an explicit key in a flow sequence', "x: [? 'a # ]']\n"),
      ('an escape YAML does not define', 'name: "a\\qb"\n'),
      ('text after a quoted value', 'name: "a" b\n'),
      ('a flow line at its key\'s column', 'k: [a,\nresolution: workspace]\n'),
      ('a quoted value left open', 'name: "a\nversion: 1.0.0\n'),
    ]) {
      test(label, () {
        final diagnostics = Diagnostics();
        expect(parseYaml(source, 'p.yaml', diagnostics), isNull);
        expect(diagnostics.found, isNotEmpty);
      });
    }
  });
}
