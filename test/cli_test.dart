import 'dart:convert';
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

    test('release help shows the unit as optional', () {
      final run = repo(['release', '--help']);
      expect(run.code, 0, reason: run.all);
      expect(run.all, contains('rk release [unit]'));
      expect(run.all, contains('rk release [unit] --stage'));
    });

    test('the removed --confirm flag is refused', () {
      final run = repo(['release', 'lib', '--confirm=1.4.0', '--json']);
      expect(run.code, 2, reason: run.all);
      expect(run.problems.map((p) => p['code']), contains('RK-CLI-001'));
    });

    test('--stage does not take an authorization', () {
      final run = repo(['release', 'lib', '--stage', '--yes', '--json']);
      expect(run.code, 2, reason: run.all);
      expect(run.problems.map((p) => p['code']), contains('RK-CLI-005'));
      expect(run.all, contains('staging publishes nothing'));
    });

    test('--yes and -y apply only to release', () {
      // --help short-circuits before the verb runs, so this proves only the
      // surface: both spellings parse for release and are refused elsewhere.
      final accepted = repo(['release', '--yes', '--help']);
      expect(accepted.code, 0, reason: accepted.all);
      final alias = repo(['release', '-y', '--help']);
      expect(alias.code, 0, reason: alias.all);

      final elsewhere = repo(['status', '--yes', '--json']);
      expect(elsewhere.code, 2, reason: elsewhere.all);
      expect(elsewhere.problems.map((p) => p['code']), contains('RK-CLI-005'));
    });
  });

  test('the shipped form — a compiled binary, invoked by bare name — works',
      () {
    // Every other test drives `dart run bin/rk.dart`, which is not what a
    // user installs. A compiled binary resolves Platform.script from
    // argv[0]: passed a bare name, Dart resolves it against the current
    // directory and names a file that is not there. rk read it anyway, so
    // every stage inspection under an installed rk answered RK-STAGE-002 —
    // and the alpha gate's consume step only runs --version and --help,
    // which never inspect a stage, so nothing here would have caught it.
    final compiled = '${scratch.path}/rk-compiled';
    final built = Process.runSync(
      Platform.resolvedExecutable,
      ['compile', 'exe', 'bin/rk.dart', '-o', compiled],
    );
    expect(built.exitCode, 0, reason: '${built.stdout}${built.stderr}');

    final repo = Rk.example(scratch, 'binary-cli', as: 'shipped')..commit();
    // Committed: without a HEAD there is no stage to inspect, so the
    // program identity is never computed and this proves nothing.
    // `exec -a` is how a shell that passes a bare argv[0] invokes it.
    final run = Process.runSync(
      '/bin/sh',
      ['-c', 'exec -a rk "$compiled" status --json'],
      workingDirectory: repo.root,
    );
    final report = jsonDecode(run.stdout as String) as Map<String, Object?>;
    final problems = ((report['problems'] as List?) ?? const [])
        .cast<Map<String, Object?>>();

    expect(
      problems.map((problem) => problem['code']),
      isNot(contains('RK-STAGE-002')),
      reason: 'the running program must be able to identify itself: '
          '${run.stdout}${run.stderr}',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

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

  group('dirty source follows the selected targets', () {
    test('a local output snapshots the worktree and warns', () {
      final platform = Platform.isMacOS ? 'macos-arm64' : 'linux-x64';
      final repo = Rk.repository(scratch, 'dirty-local-output', {
        'release.toml': '''
schema = 2

[release.tool]
binary_platforms = ["$platform"]
''',
        'pubspec.yaml': '''
name: dirty_local_output
version: 1.0.0
publish_to: none
executables:
  tool: tool
''',
        'bin/tool.dart': 'void main() {}\n',
        'CHANGELOG.md': '## 1.0.0\n\nFirst release.\n',
        'README.md': 'committed\n',
      })
        ..commit();
      File('${repo.root}/README.md').writeAsStringSync('working tree\n');

      final run = repo(['status', '--json']);

      expect(run.code, 0, reason: run.all);
      expect(run.warnings.map((warning) => warning['code']), ['RK-GIT-001']);
      expect(
        run.problems.map((problem) => problem['code']),
        isNot(contains('RK-GIT-001')),
      );
      expect((run.json['repository'] as Map)['source_binding'], 'unbound');
    });

    test('a Git target still refuses, without showing its code to a person',
        () {
      final repo = Rk.repository(scratch, 'dirty-git-target', {
        'release.toml': '''
schema = 2

[release.tool]
publish = ["git-tag"]
''',
        'pubspec.yaml': '''
name: dirty_git_target
version: 1.0.0
publish_to: none
''',
        'CHANGELOG.md': '## 1.0.0\n\nFirst release.\n',
        'README.md': 'committed\n',
      })
        ..commit();
      File('${repo.root}/README.md').writeAsStringSync('working tree\n');

      final machine = repo(['status', '--json']);
      final human = repo(['status']);

      expect(machine.code, 0, reason: machine.all);
      expect(
        machine.problems.map((problem) => problem['code']),
        contains('RK-GIT-001'),
      );
      expect(machine.warnings, isEmpty);
      expect(
          (machine.json['repository'] as Map)['source_binding'], 'gitCommit');
      expect(human.all, contains('1 path is uncommitted'));
      expect(human.all, isNot(contains('RK-GIT-001')));
    });
  });

  test('a release.toml rk cannot read reports itself', () {
    // Resolving "the only unit" means reading the config, so a config that
    // cannot be read is what a bare `rk release` now reports. That is the
    // more useful refusal anyway: naming a unit would not have helped, and
    // the same file blocks every other verb too.
    final broken = Rk.repository(scratch, 'missing-release-unit', {
      'release.toml': 'this is deliberately not release config\n',
    });

    final run = broken(['release', '--json']);

    expect(run.code, 1, reason: run.all);
    expect(run.all, contains('release.toml'));
    expect(
      run.problems.map((problem) => problem['code']),
      isNot(contains('RK-CLI-004')),
      reason: 'the unreadable file is the problem, not the missing word',
    );
  });

  test('a repository with no unit is answered by the config, not the parser',
      () {
    // There is no second answer for "no units": resolution already refuses
    // with the table to add, which is more use than any usage line.
    final empty = Rk.repository(scratch, 'no-units', {
      'release.toml': 'schema = 2\n',
    });

    final run = empty(['release', '--json']);

    expect(run.code, 1, reason: run.all);
    expect(run.problems.map((problem) => problem['code']), ['RK-CONF-004']);
    expect(run.all, contains('[release.core]'));
    expect(
      run.all,
      isNot(contains('--write')),
      reason: 'one missing word is answered with the missing word, not with '
          'every flag rk has',
    );
  });

  group('a repository rk has nothing to say about', () {
    test('no release.toml is not an error', () {
      final bare = Rk.repository(scratch, 'bare', {'README.md': 'nothing\n'});
      final run = bare(['status']);
      expect(run.code, 0, reason: 'absence of intent is not a failure');
      expect(run.all, contains('release.toml'));
    });

    test('non-Git directories are valid release roots', () {
      final loose = Directory('${scratch.path}/loose')..createSync();
      File('${loose.path}/release.toml').writeAsStringSync('schema = 2\n');
      final run = Rk(loose.path)(['status']);
      expect(run.code, 1, reason: run.all);
      expect(run.all, contains('release.toml declares no release units'));
      expect(run.all, isNot(contains('not a git repository')));
    });

    test('Git-backed targets are refused explicitly without Git', () {
      final loose = Directory('${scratch.path}/loose-git-target')..createSync();
      File('${loose.path}/release.toml').writeAsStringSync('''
schema = 2

[release.tool]
publish = ["git-tag"]
''');
      File('${loose.path}/pubspec.yaml')
          .writeAsStringSync('name: tool\nversion: 1.0.0\n');
      File('${loose.path}/CHANGELOG.md')
          .writeAsStringSync('## 1.0.0\n\n- First release.\n');

      final run = Rk(loose.path)(['status', '--json']);
      expect(run.code, 1, reason: run.all);
      expect(run.problems.map((problem) => problem['code']), ['RK-SRC-001']);
      expect(run.all, contains('initialize a Git repository'));
    });

    test('non-Git init writes no Git-only file', () {
      final loose = Directory('${scratch.path}/loose-init')..createSync();
      File('${loose.path}/pubspec.yaml')
          .writeAsStringSync('name: tool\nversion: 1.0.0\n');

      final run = Rk(loose.path)(['init', '--write']);
      expect(run.code, 0, reason: run.all);
      expect(File('${loose.path}/release.toml').readAsStringSync(),
          contains('publish = ["pub.dev"]'));
      expect(File('${loose.path}/.gitignore').existsSync(), isFalse);
    });
  });
}
