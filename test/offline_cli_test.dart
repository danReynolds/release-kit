import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Phase 1's milestone, run rather than inspected.
///
/// "rk parses keybay's release.toml and prints the derived checklist offline"
/// is a claim about a program, so these build the three repository shapes on
/// disk and run the real executable against them. The earlier version of this
/// check asserted that `bin/rk.dart` *contained the string* `--offline`, which
/// is how a phase passes while its feature is unwired.
void main() {
  final rk = File('bin/rk.dart').absolute.path;
  late Directory root;

  setUpAll(() {
    root = Directory.systemTemp.createTempSync('rk-offline-');
  });

  tearDownAll(() => root.deleteSync(recursive: true));

  /// Writes [files] into a fresh git repository and returns its path.
  String repository(String name, Map<String, String> files) {
    final dir = Directory('${root.path}/$name')..createSync(recursive: true);
    files.forEach((path, contents) {
      File('${dir.path}/$path')
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);
    });
    final git =
        Process.runSync('git', ['init', '-q'], workingDirectory: dir.path);
    expect(git.exitCode, 0, reason: 'the fixture must be a repository');
    return dir.path;
  }

  ({int code, String out}) status(String dir) {
    final result = Process.runSync(
      Platform.resolvedExecutable,
      ['run', rk, 'status', '--offline'],
      workingDirectory: dir,
    );
    return (
      code: result.exitCode,
      out: '${result.stdout}${result.stderr}',
    );
  }

  group('keybay-shaped: two units, one depending on the other', () {
    late ({int code, String out}) run;

    setUpAll(() {
      run = status(repository('keybay', {
        'release.toml': '''
schema = 1

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]

[release.cli]
path = "packages/keybay_cli"
publish = ["pub.dev", "github-release", "homebrew"]
binary_platforms = ["linux-x64", "linux-arm64", "macos-arm64"]
''',
        'pubspec.yaml': '''
name: keybay_workspace
publish_to: none
environment:
  sdk: ^3.6.0
workspace:
  - packages/keybay
  - packages/keybay_cli
''',
        'packages/keybay/pubspec.yaml': '''
name: keybay
version: 0.2.0
environment:
  sdk: ^3.6.0
''',
        'packages/keybay_cli/pubspec.yaml': '''
name: keybay_cli
version: 0.2.0
environment:
  sdk: ^3.10.0
dependencies:
  keybay: 0.2.0
executables:
  keybay: keybay
''',
      }));
    });

    test('it succeeds', () {
      expect(run.code, 0, reason: run.out);
    });

    test('each unit is named with the version and tag it would release', () {
      expect(run.out, contains('keybay-v0.2.0'));
      expect(run.out, contains('keybay_cli-v0.2.0'));
    });

    test('the binary chain is shown in full', () {
      for (final expected in [
        'linux-x64',
        'linux-arm64',
        'macos-arm64',
        'sign',
        'notarize',
        'checksums',
      ]) {
        expect(run.out, contains(expected), reason: 'the checklist names it');
      }
    });

    test('the cross-unit prerequisite is stated', () {
      expect(run.out, contains('keybay 0.2.0 must be live on pub.dev'));
    });

    test('it says what it did not read, so nothing reads as done', () {
      expect(run.out, contains('derived from the manifests alone'));
      expect(run.out, contains('says what is already done'));
    });
  });

  group('fleury-shaped: one unit of several projects', () {
    late ({int code, String out}) run;

    setUpAll(() {
      run = status(repository('fleury', {
        'release.toml': '''
schema = 1

[release.framework]
tag = "fleury-v{version}"

[[release.framework.project]]
path = "packages/fleury_widgets"
publish = ["pub.dev"]

[[release.framework.project]]
path = "packages/fleury"
publish = ["pub.dev"]
''',
        'packages/fleury/pubspec.yaml': 'name: fleury\nversion: 0.1.0\n',
        'packages/fleury_widgets/pubspec.yaml': '''
name: fleury_widgets
version: 0.1.0
dependencies:
  fleury: ^0.1.0
''',
      }));
    });

    test('it succeeds', () => expect(run.code, 0, reason: run.out));

    test('the declared tag is used', () {
      expect(run.out, contains('fleury-v0.1.0'));
    });

    test('the dependency publishes before its dependent', () {
      final core = run.out.indexOf('publish fleury 0.1.0');
      final dependent = run.out.indexOf('publish fleury_widgets 0.1.0');
      expect(core, greaterThan(-1), reason: run.out);
      expect(
        core,
        lessThan(dependent),
        reason: 'declaration order was the reverse',
      );
    });
  });

  group('dune-shaped: built from sources the repository does not contain', () {
    late ({int code, String out}) run;

    setUpAll(() {
      run = status(repository('dune', {
        'release.toml': '''
schema = 1

[release.cli]
publish = ["github-release"]
binary_platforms = ["macos-arm64"]
''',
        'pubspec.yaml': '''
name: dune_cli
version: 0.0.1
publish_to: none
executables:
  dune: dune
dependencies:
  dune_core:
    path: ../dune_core
''',
      }));
    });

    test('it is refused, not released', () {
      expect(run.code, 1, reason: run.out);
    });

    test('the refusal says what is wrong and names the dependency', () {
      expect(
        run.out,
        contains('built from sources this repository does not contain'),
      );
      expect(run.out, contains('dune_core'));
    });

    test('no checklist is printed for something rk will not release', () {
      expect(run.out, isNot(contains('checksums')));
      expect(run.out, isNot(contains('macos-arm64')));
    });
  });

  group('--json is the machine surface, not an addition to the human one', () {
    ({int code, String out}) json(String dir) {
      final result = Process.runSync(
        Platform.resolvedExecutable,
        ['run', rk, 'status', '--offline', '--json'],
        workingDirectory: dir,
      );
      return (code: result.exitCode, out: result.stdout as String);
    }

    test('it parses, and carries the checklist keyed by step id', () {
      final run = json(repository('keybay-json', {
        'release.toml': '''
schema = 1

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]
''',
        'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
      }));

      expect(run.code, 0, reason: run.out);
      final document = jsonDecode(run.out) as Map<String, Object?>;
      expect(document['command'], 'status');
      expect(document['safe_to_rerun'], isTrue);

      final unit = (document['units'] as List).single as Map;
      expect(unit['tag'], 'v0.2.0');
      final ids = (unit['steps'] as List).map((s) => (s as Map)['id']);
      expect(ids, contains('core/pub.dev/keybay@0.2.0'));
    });

    test('and prose does not leak into it', () {
      final run = json(repository('keybay-json-clean', {
        'release.toml': '''
schema = 1

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]
''',
        'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
      }));
      expect(run.out.trimLeft(), startsWith('{'));
      expect(run.out, isNot(contains('derived from the manifests alone')));
    });

    test('it survives a non-zero exit', () {
      final run = json(repository('dune-json', {
        'release.toml': '''
schema = 1

[release.cli]
publish = ["github-release"]
binary_platforms = ["macos-arm64"]
''',
        'pubspec.yaml': '''
name: dune_cli
version: 0.0.1
publish_to: none
executables:
  dune: dune
dependencies:
  dune_core:
    path: ../dune_core
''',
      }));

      expect(run.code, 1);
      final document = jsonDecode(run.out) as Map<String, Object?>;
      expect(document['exit'], 1);
      expect(
        document['safe_to_rerun'],
        isTrue,
        reason: 'fixing the manifest and re-running is the whole recovery',
      );
      final problem = (document['problems'] as List).single as Map;
      expect(problem['code'], 'RK-DART-201');
    });

    test('a refusal that never reached a step writes no diagnosis', () {
      final dir = repository('no-diagnosis', {
        'release.toml': '''
schema = 1

[release.cli]
publish = ["github-release"]
binary_platforms = ["macos-arm64"]
''',
        'pubspec.yaml': '''
name: dune_cli
version: 0.0.1
publish_to: none
executables:
  dune: dune
dependencies:
  dune_core:
    path: ../dune_core
''',
      });
      expect(status(dir).code, 1);
      expect(
        Directory('$dir/.rk').existsSync(),
        isFalse,
        reason: 'the problems were already printed; a directory of copies of '
            'a typo teaches an operator to ignore the directory',
      );
    });
  });

  group('a repository rk has nothing to say about', () {
    test('no release.toml is not an error', () {
      final run = status(repository('bare', {'README.md': 'nothing here\n'}));
      expect(run.code, 0, reason: 'absence of intent is not a failure');
      expect(run.out, contains('release.toml'));
    });

    test('outside a repository is a usage error', () {
      final dir = Directory('${root.path}/loose')..createSync();
      File('${dir.path}/release.toml').writeAsStringSync('schema = 1\n');
      final result = Process.runSync(
        Platform.resolvedExecutable,
        ['run', rk, 'status', '--offline'],
        workingDirectory: dir.path,
      );
      expect(result.exitCode, 2, reason: '${result.stdout}${result.stderr}');
    });
  });
}
