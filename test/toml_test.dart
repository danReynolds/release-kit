import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/toml.dart';
import 'package:test/test.dart';

TomlTable? parse(String source, [Diagnostics? into]) {
  final diagnostics = into ?? Diagnostics();
  return parseToml(source, 'release.toml', diagnostics);
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
schema = 3

[release.core]                 # tag keybay-v{version}
path = "packages/keybay"
publish = ["pub.dev"]

[release.cli]                  # tag keybay_cli-v{version}
path = "packages/keybay_cli"
publish = ["pub.dev", "github-release", "homebrew"]
binary.platforms = ["linux-x64", "linux-arm64", "macos-arm64"]
''')!;

    expect(document['schema'], 3);

    final release = document['release'] as TomlTable;
    final core = release['core'] as TomlTable;
    expect(core['path'], 'packages/keybay');
    expect(core['publish'], ['pub.dev']);

    final cli = release['cli'] as TomlTable;
    expect(cli['publish'], ['pub.dev', 'github-release', 'homebrew']);
    expect((cli['binary'] as TomlTable)['platforms'], [
      'linux-x64',
      'linux-arm64',
      'macos-arm64',
    ]);
  });

  test('a dotted key makes a table of its own, in a table or a row', () {
    final document = parse('''
[release.cli]
binary.platforms = ["macos-arm64"]
homebrew.description = "Fast tool"
homebrew . tap = "owner/tools"

[[release.suite.project]]
binary.platforms = ["linux-x64"]
''')!;

    final release = document['release'] as TomlTable;
    final cli = release['cli'] as TomlTable;
    final homebrew = cli['homebrew'] as TomlTable;
    expect(homebrew.dotted, isTrue);
    expect(homebrew['description'], 'Fast tool');
    expect(homebrew['tap'], 'owner/tools');
    expect(homebrew.locationOf('tap').line, 4);
    expect(cli.locationOf('homebrew').line, 3);
    final row =
        ((release['suite'] as TomlTable)['project'] as TomlArray).tables.single;
    expect((row['binary'] as TomlTable)['platforms'], ['linux-x64']);
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

    final release = document['release'] as TomlTable;
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
    expect(document['binary_platforms'], hasLength(3));
    expect(document['schema'], 2, reason: 'parsing resumes after the list');
  });

  test('remembers where each key was written', () {
    final document = parse('''
schema = 2

[release.core]
path = "packages/keybay"
''')!;
    final core = (document['release'] as TomlTable)['core'] as TomlTable;
    expect(core.locationOf('path').line, 4);
  });

  test('a comment inside a string is not a comment', () {
    final document = parse('tag = "v{version}#1"')!;
    expect(document['tag'], 'v{version}#1');
  });

  test('a comma inside a string does not split the list', () {
    final document = parse(
      'build = ["tool/build.sh", "--targets=a,b", "{out}"]',
    )!;
    expect(document['build'], ['tool/build.sh', '--targets=a,b', '{out}']);
  });

  test('an empty list is allowed by the parser', () {
    // Emptiness is a schema question, refused later with a better message.
    expect(parse('publish = []')!['publish'], isEmpty);
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
      expect(rejected('"my key" = 1'), isNotEmpty);
      expect(rejected('my..key = 1'), isNotEmpty);
    });

    test('a dotted key assigned twice', () {
      expect(
        rejected('a.b = 1\na.b = 2').single.message,
        '"a.b" is assigned more than once in this table',
      );
    });

    test('a dotted key adding to a value', () {
      expect(
        rejected('a = 1\na.b = 2').single.message,
        '"a.b" cannot add to "a", already defined on line 1',
      );
    });

    test('a header reopening a table dotted keys made', () {
      final found = rejected('[x]\na.b = 1\n[x.a]\nc = 2');
      expect(
        found.single.message,
        '"x.a" is made by dotted keys on line 2, so a header cannot reopen it',
      );
      expect(found.single.source?.line, 3);
    });

    test('an unterminated array-of-tables header', () {
      expect(
        rejected('[[release.core.project]').single.message,
        'unterminated array-of-tables header',
      );
    });

    test('a table inside an array of tables', () {
      final found = rejected(
        '[[release.core.project]]\npath = "a"\n[release.core.project.x]',
      );
      expect(found.single.code, 'RK-TOML-001');
      expect(found.single.source?.line, 3);
    });
  });

  test('reports the line a problem is on', () {
    final found = rejected('schema = 2\n\npath = true');
    expect(found.single.source?.line, 3);
  });
}
