import 'dart:io';

import 'package:test/test.dart';

import 'rk_process.dart';

/// The CLI surface, run rather than inspected — argument parsing, usage
/// refusals, and the paths that answer before any target is read. Each test
/// copies a repository out of `examples/` (or builds a minimal one), makes it
/// a repository, and runs the real executable against it.
///
/// Checklist derivation itself is proved in `checklist_test.dart` and
/// `resolve_test.dart`; nothing here needs a network to answer.
///
/// The examples are named for the shape they are, never for a real project —
/// see examples/README.md for why that rule exists.
void main() {
  late Directory scratch;

  setUpAll(() => scratch = Directory.systemTemp.createTempSync('rk-cli-'));
  tearDownAll(() => scratch.deleteSync(recursive: true));

  group('a release the repository cannot build is refused at resolve', () {
    late Run run;
    setUpAll(
      () => run = Rk.example(scratch, 'escapes-repository')(['status']),
    );

    test('it is refused, not released', () {
      expect(run.code, 1, reason: run.all);
    });

    test('the refusal says what is wrong and names both dependencies', () {
      expect(
        run.all,
        contains('built from sources this repository does not contain'),
      );
      expect(run.all, contains('sibling_core'));
      expect(run.all, contains('sibling_io'));
    });

    test('no checklist is printed for something rk will not release', () {
      expect(run.all, isNot(contains('checksums')));
      expect(run.all, isNot(contains('macos-arm64')));
    });
  });

  group('flags that carry no meaning here are refused, not repaired', () {
    late Rk repo;
    setUpAll(() => repo = Rk.example(scratch, 'single-package', as: 'flags'));

    test('--at is not a supported flag', () {
      final run = repo(['status', '--at=v1.0.0', '--json']);
      expect(run.code, 2, reason: run.all);
      expect(run.problems.map((p) => p['code']), contains('RK-CLI-001'));
      expect(run.all, contains('rk does not have --at=v1.0.0'));
    });

    test('--offline is not a supported flag', () {
      final run = repo(['status', '--offline', '--json']);
      expect(run.code, 2, reason: run.all);
      expect(run.problems.map((p) => p['code']), contains('RK-CLI-001'));
    });

    test('verify is not a command', () {
      final run = repo(['verify', '--json']);
      expect(run.code, 2);
      expect(run.problems.map((p) => p['code']), contains('RK-CLI-008'));
      expect(
          run.problems.single['message'], 'rk has no command named "verify"');
    });

    test('a unit name is scoped through status, not inferred as a command', () {
      final run = repo(['lib', '--json']);
      expect(run.code, 2);
      expect(run.problems.map((p) => p['code']), contains('RK-CLI-008'));
      expect(run.all, contains('rk status [unit]'));
    });

    test('a third word is refused, not silently dropped', () {
      final run = repo(['status', 'lib', 'bogus', '--json']);
      expect(run.code, 2);
      expect(run.problems.map((p) => p['code']), contains('RK-CLI-007'));
    });

    test('release help names its required unit without requiring one', () {
      final run = repo(['release', '--help']);
      expect(run.code, 0, reason: run.all);
      expect(run.all, contains('rk release <unit>'));
      expect(run.all, contains('rk release <unit> --stage'));
    });
  });

  test('--version identifies the binary without repository preparation', () {
    final loose = Directory('${scratch.path}/version-only')..createSync();
    final run = Rk(loose.path)(['--version']);
    final manifestVersion = RegExp(
      r'^version: *([^ ]+) *$',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1);

    expect(run.code, 0, reason: run.all);
    expect(run.stdout, 'rk $manifestVersion\n');
    expect(run.stderr, isEmpty);
    expect(Directory('${loose.path}/.rk').existsSync(), isFalse);
  });

  test('release without a unit is refused before repository preparation', () {
    final broken = Rk.repository(scratch, 'missing-release-unit', {
      'release.toml': 'this is deliberately not release config\n',
    });

    final run = broken(['release', '--json']);

    expect(run.code, 2, reason: run.all);
    expect(run.problems.map((problem) => problem['code']), ['RK-CLI-004']);
    expect(run.problems.single['message'], 'name the unit to release');
    expect(
      run.all,
      isNot(contains('release.toml:')),
      reason: 'the parser must refuse before it reads repository state',
    );
  });

  group('a repository rk has nothing to say about', () {
    test('no release.toml is not an error', () {
      final bare = Rk.repository(scratch, 'bare', {'README.md': 'nothing\n'});
      final run = bare(['status']);
      expect(run.code, 0, reason: 'absence of intent is not a failure');
      expect(run.all, contains('release.toml'));
    });

    test('outside a repository is a usage error', () {
      final loose = Directory('${scratch.path}/loose')..createSync();
      File('${loose.path}/release.toml').writeAsStringSync('schema = 1\n');
      final run = Rk(loose.path)(['status']);
      expect(run.code, 2, reason: run.all);
    });
  });
}
