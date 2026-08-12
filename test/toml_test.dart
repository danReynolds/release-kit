import 'package:release_kit/src/engine/diagnostic.dart';
import 'package:release_kit/src/engine/toml.dart';
import 'package:test/test.dart';

TomlDocument? parse(String source, [Diagnostics? into]) {
  final diagnostics = into ?? Diagnostics();
  return TomlDocument.parse(source, 'release.toml', diagnostics);
}

/// Parses input the schema must reject, returning the problems found.
List<Diagnostic> rejected(String source) {
  final diagnostics = Diagnostics();
  final document = parse(source, diagnostics);
  expect(document, isNull, reason: 'should have been refused');
  expect(diagnostics.isNotEmpty, isTrue, reason: 'refusal needs a reason');
  return diagnostics.found;
}

void main() {
  test('parses keybay\'s complete configuration', () {
    final document = parse('''
schema = 2

[release.core]                 # tag keybay-v{version}
path = "packages/keybay"
publish = ["pub.dev"]

[release.cli]                  # tag keybay_cli-v{version}
path = "packages/keybay_cli"
publish = ["pub.dev", "github-release", "homebrew"]
binary_platforms = ["linux-x64", "linux-arm64", "macos-arm64"]
''')!;

    expect(document.root['schema'], 2);

    final release = document.root['release'] as TomlTable;
    final core = release['core'] as TomlTable;
    expect(core['path'], 'packages/keybay');
    expect(core['publish'], ['pub.dev']);

    final cli = release['cli'] as TomlTable;
    expect(cli['publish'], ['pub.dev', 'github-release', 'homebrew']);
    expect(
        cli['binary_platforms'], ['linux-x64', 'linux-arm64', 'macos-arm64']);
  });

  test('parses a multi-project unit as an array of tables', () {
    final document = parse('''
schema = 2

[release.framework]
tag = "fleury-v{version}"

[[release.framework.project]]
path = "packages/fleury"
publish = ["pub.dev"]

[[release.framework.project]]
path = "packages/fleury_test"
publish = ["pub.dev"]

[release.mcp]
path = "packages/fleury_mcp"
publish = ["pub.dev"]
''')!;

    final release = document.root['release'] as TomlTable;
    final framework = release['framework'] as TomlTable;
    expect(framework['tag'], 'fleury-v{version}');

    final projects = framework['project'] as TomlArray;
    expect(projects.tables.length, 2);
    expect(projects.tables[0]['path'], 'packages/fleury');
    expect(projects.tables[1]['path'], 'packages/fleury_test');

    // A later table header must not be swallowed by the array above it.
    expect((release['mcp'] as TomlTable)['path'], 'packages/fleury_mcp');
  });

  test('parses a list spread over several lines with a trailing comma', () {
    final document = parse('''
binary_platforms = [
  "linux-x64",
  "linux-arm64",
  "macos-arm64",
]
schema = 2
''')!;
    expect(document.root['binary_platforms'], hasLength(3));
    expect(document.root['schema'], 2,
        reason: 'parsing resumes after the list');
  });

  test('remembers where each key was written', () {
    final document = parse('''
schema = 2

[release.core]
path = "packages/keybay"
''')!;
    final core = (document.root['release'] as TomlTable)['core'] as TomlTable;
    expect(core.locationOf('path').line, 4);
  });

  test('a comment inside a string is not a comment', () {
    final document = parse('tag = "v{version}#1"')!;
    expect(document.root['tag'], 'v{version}#1');
  });

  test('an empty list is allowed by the parser', () {
    // Emptiness is a schema question, refused later with a better message.
    expect(parse('publish = []')!.root['publish'], isEmpty);
  });

  group('refuses what the schema has no representation for', () {
    test('inline tables', () {
      expect(rejected('install = { prefix = "README.md" }'), isNotEmpty);
    });

    test('booleans', () {
      expect(rejected('immutable = true'), isNotEmpty);
    });

    test('floats', () {
      expect(rejected('schema = 2.5'), isNotEmpty);
    });

    test('negative integers', () {
      expect(rejected('schema = -1'), isNotEmpty);
    });

    test('quoted keys', () {
      expect(rejected('"schema" = 1'), isNotEmpty);
    });

    test('literal strings', () {
      expect(rejected("path = 'packages/keybay'"), isNotEmpty);
    });

    test('escape sequences', () {
      expect(rejected(r'path = "packages\keybay"'), isNotEmpty);
    });

    test('nested lists', () {
      expect(rejected('publish = [["pub.dev"]]'), isNotEmpty);
    });

    test('bare values in a list', () {
      expect(rejected('publish = [pub.dev]'), isNotEmpty);
    });

    test('a line that is neither header nor assignment', () {
      expect(rejected('publish'), isNotEmpty);
    });

    test('an unterminated string', () {
      expect(rejected('path = "packages/keybay'), isNotEmpty);
    });

    test('an unterminated list', () {
      expect(rejected('publish = ["pub.dev",'), isNotEmpty);
    });

    test('an unterminated table header', () {
      expect(rejected('[release.core'), isNotEmpty);
    });

    test('a duplicated key in one table', () {
      expect(rejected('schema = 2\nschema = 2'), isNotEmpty);
    });

    test('a table defined twice', () {
      expect(
        rejected('[release.core]\npath = "a"\n\n[release.core]\npath = "b"'),
        isNotEmpty,
      );
    });

    test('a key that is not bare', () {
      expect(rejected('my.key = 1'), isNotEmpty);
    });
  });

  test('reports the line a problem is on', () {
    final found = rejected('schema = 2\n\npath = true');
    expect(found.single.source?.line, 3);
  });
}
