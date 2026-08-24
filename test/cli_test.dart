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

    test('--yes and -y apply only to release and clean', () {
      // --help short-circuits before the verb runs, so this proves only the
      // surface: both spellings parse for release and are refused elsewhere.
      final accepted = repo(['release', '--yes', '--help']);
      expect(accepted.code, 0, reason: accepted.all);
      final alias = repo(['release', '-y', '--help']);
      expect(alias.code, 0, reason: alias.all);
      final clean = repo(['clean', '--yes', '--help']);
      expect(clean.code, 0, reason: clean.all);

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
    // `exec -a` is how a shell that passes a bare argv[0] invokes it. Use
    // bash explicitly: Ubuntu's /bin/sh is dash, which has no -a option.
    final run = Process.runSync(
      '/bin/bash',
      ['-c', 'exec -a rk "$compiled" status --json'],
      workingDirectory: repo.root,
    );
    expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
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

  group('plan is a source-only command', () {
    late Rk repo;

    setUpAll(() {
      repo = Rk.repository(scratch, 'plan-source-only', {
        'release.toml': '''
schema = 2

[release.lib]
tag = "lib-v{version}"
path = "packages/lib"
publish = ["git-tag", "pub.dev"]

[release.cli]
tag = "cli-v{version}"
path = "packages/cli"
publish = ["git-tag", "github-release"]
binary_platforms = ["linux-x64"]
''',
        'packages/lib/pubspec.yaml': '''
name: plan_lib
version: 1.0.0
''',
        'packages/cli/pubspec.yaml': '''
name: plan_cli
version: 2.0.0
publish_to: none
executables:
  plan: plan_cli
''',
      })
        ..commit();
    });

    test('reports the configured graph without creating local state', () {
      final scratchState = Directory('${repo.root}/.rk');
      expect(scratchState.existsSync(), isFalse);

      final run = repo(['plan', '--json']);

      expect(run.code, 0, reason: run.all);
      expect(run.json['rk'], 10);
      expect(run.json['command'], 'plan');
      expect(run.units, isEmpty,
          reason: 'runtime observations do not masquerade as plan steps');
      final plan = run.json['plan']! as Map<String, Object?>;
      expect(plan['source_only'], isTrue);
      expect(plan['destinations_inspected'], isFalse);
      final units = (plan['units']! as List).cast<Map<String, Object?>>();
      expect(units.map((unit) => unit['name']), ['lib', 'cli']);
      final libNodes =
          (units.first['nodes']! as List).cast<Map<String, Object?>>();
      final complete = libNodes.singleWhere(
        (node) => node['kind'] == 'completeStage',
      );
      expect(complete['summary'], 'complete and validate stage',
          reason: 'concise human copy must not weaken the JSON contract');
      expect(
        jsonEncode(plan),
        allOf(
          contains('lib/stage/pub-archive:plan_lib'),
          contains('cli/stage/release-notes'),
          contains('cli/build/plan_cli/linux-x64'),
          contains('cli/github-release/cli-v2.0.0'),
        ),
      );
      expect(jsonEncode(plan), isNot(contains('"verdict"')));
      expect(scratchState.existsSync(), isFalse,
          reason: 'planning neither stages nor records a diagnosis');
    });

    test('an unborn Git repository with no config is benign', () {
      final unborn = Rk.repository(scratch, 'plan-unborn', const {});

      final run = unborn(['plan', '--json']);

      expect(run.code, 0, reason: run.all);
      expect(run.problems, isEmpty);
      expect(run.json, isNot(contains('plan')));
      expect(Directory('${unborn.root}/.rk').existsSync(), isFalse);
    });

    test('an unborn configured plan has no empty commit identity', () {
      final unborn = Rk.repository(scratch, 'plan-unborn-configured', {
        'release.toml': '''
schema = 2

[release.lib]
publish = ["pub.dev"]
''',
        'pubspec.yaml': 'name: unborn_plan\nversion: 1.0.0\n',
      });

      final run = unborn(['plan', '--json']);

      expect(run.code, 0, reason: run.all);
      expect(run.json, contains('plan'));
      final repository = run.json['repository']! as Map<String, Object?>;
      expect(repository, isNot(contains('head')));
      expect(jsonEncode(run.json['plan']), contains('unborn_plan@1.0.0'));
    });

    test('does not let Git refresh the repository index', () {
      final stable = Rk.repository(scratch, 'plan-index-is-read-only', {
        'release.toml': '''
schema = 2

[release.lib]
publish = ["pub.dev"]
''',
        'pubspec.yaml': 'name: index_plan\nversion: 1.0.0\n',
      })
        ..commit();
      final manifest = File('${stable.root}/pubspec.yaml');
      manifest.setLastModifiedSync(DateTime.now().add(const Duration(days: 1)));
      final index = File('${stable.root}/.git/index');
      final sentinel = DateTime.utc(2001, 2, 3, 4, 5, 6);
      index.setLastModifiedSync(sentinel);
      final before = index.readAsBytesSync();
      final beforeModified = index.lastModifiedSync();

      final run = stable(['plan', '--json']);

      expect(run.code, 0, reason: run.all);
      expect(index.readAsBytesSync(), before);
      expect(index.lastModifiedSync(), beforeModified,
          reason: 'a source-only plan must not refresh or rewrite .git/index');
    });

    test('freezes and reports the current dirty topology consistently', () {
      final dirty = Rk.repository(scratch, 'plan-dirty-source', {
        'release.toml': '''
schema = 2

[release.tool]
tag = "v{version}"
publish = ["git-tag", "pub.dev"]
''',
        'pubspec.yaml': 'name: dirty_plan\nversion: 1.0.0\n',
      })
        ..commit();
      File('${dirty.root}/pubspec.yaml')
          .writeAsStringSync('name: dirty_plan\nversion: 1.1.0\n');

      final run = dirty(['plan', '--json']);

      expect(run.code, 0, reason: run.all);
      expect((run.json['repository']! as Map)['uncommitted'], 1);
      final plan = run.json['plan']! as Map<String, Object?>;
      final units = (plan['units']! as List).cast<Map<String, Object?>>();
      expect(units.single['version'], '1.1.0');
      expect(jsonEncode(plan), contains('tool/pub.dev/dirty_plan@1.1.0'));
      expect(Directory('${dirty.root}/.rk').existsSync(), isFalse);
    });

    test('a Git-clean plan resolves immutable HEAD, not hidden worktree bytes',
        () {
      final clean = Rk.repository(scratch, 'plan-clean-head', {
        'release.toml': '''
schema = 2

[release.lib]
publish = ["pub.dev"]
''',
        'pubspec.yaml': 'name: clean_head_plan\nversion: 1.0.0\n',
      })
        ..commit();
      final hidden = Process.runSync(
        'git',
        ['update-index', '--assume-unchanged', 'pubspec.yaml'],
        workingDirectory: clean.root,
      );
      expect(hidden.exitCode, 0, reason: '${hidden.stdout}${hidden.stderr}');
      File('${clean.root}/pubspec.yaml')
          .writeAsStringSync('name: clean_head_plan\nversion: 9.9.9\n');
      final status = Process.runSync(
        'git',
        ['status', '--porcelain'],
        workingDirectory: clean.root,
      );
      expect(status.exitCode, 0, reason: '${status.stdout}${status.stderr}');
      expect(status.stdout, isEmpty,
          reason: 'the fixture must exercise bytes hidden from Git status');

      final run = clean(['plan', '--json']);

      expect(run.code, 0, reason: run.all);
      expect((run.json['repository']! as Map)['uncommitted'], 0);
      final encoded = jsonEncode(run.json['plan']);
      expect(encoded, contains('clean_head_plan@1.0.0'));
      expect(encoded, isNot(contains('clean_head_plan@9.9.9')),
          reason: 'a plan Git describes as clean must use the same immutable '
              'HEAD topology that release selects');
      expect(Directory('${clean.root}/.rk').existsSync(), isFalse);
    });

    test('hidden worktree config cannot replace the clean HEAD definition', () {
      for (final replacement in <String, String?>{
        'missing': null,
        'invalid': 'this is not release configuration\n',
      }.entries) {
        final clean = Rk.repository(
          scratch,
          'plan-clean-config-${replacement.key}',
          {
            'release.toml': '''
schema = 2

[release.lib]
publish = ["pub.dev"]
''',
            'pubspec.yaml':
                'name: clean_config_${replacement.key}\nversion: 1.0.0\n',
          },
        )..commit();
        final hidden = Process.runSync(
          'git',
          ['update-index', '--skip-worktree', 'release.toml'],
          workingDirectory: clean.root,
        );
        expect(hidden.exitCode, 0, reason: '${hidden.stdout}${hidden.stderr}');
        final config = File('${clean.root}/release.toml');
        if (replacement.value == null) {
          config.deleteSync();
        } else {
          config.writeAsStringSync(replacement.value!);
        }
        final status = Process.runSync(
          'git',
          ['status', '--porcelain'],
          workingDirectory: clean.root,
        );
        expect(status.exitCode, 0, reason: '${status.stdout}${status.stderr}');
        expect(status.stdout, isEmpty,
            reason: 'the fixture must hide the ${replacement.key} config');

        final run = clean(['plan', '--json']);

        expect(run.code, 0, reason: '${replacement.key}: ${run.all}');
        final encoded = jsonEncode(run.json['plan']);
        expect(encoded, contains('clean_config_${replacement.key}@1.0.0'));
        for (final command in ['status', 'release']) {
          final scoped = clean([command, 'missing', '--json']);
          expect(
            scoped.code,
            2,
            reason: '$command/${replacement.key}: ${scoped.all}',
          );
          expect(
            scoped.problems.map((problem) => problem['code']),
            ['RK-CLI-003'],
          );
        }
      }
    });

    test('clean HEAD refuses configuration and manifest symbolic links', () {
      if (Platform.isWindows) return;
      final configLink = Rk.repository(scratch, 'plan-config-link', {
        'actual-release.toml': '''
schema = 2

[release.lib]
publish = ["pub.dev"]
''',
        'pubspec.yaml': 'name: config_link_plan\nversion: 1.0.0\n',
      });
      Link('${configLink.root}/release.toml').createSync('actual-release.toml');
      configLink.commit();

      final manifestLink = Rk.repository(scratch, 'plan-manifest-link', {
        'release.toml': '''
schema = 2

[release.lib]
publish = ["pub.dev"]
''',
        'actual-pubspec.yaml': 'name: manifest_link_plan\nversion: 1.0.0\n',
      });
      Link('${manifestLink.root}/pubspec.yaml')
          .createSync('actual-pubspec.yaml');
      manifestLink.commit();

      final configRun = configLink(['plan', '--json']);
      final manifestRun = manifestLink(['plan', '--json']);

      expect(configRun.code, 1, reason: configRun.all);
      expect(
        configRun.problems.map((problem) => problem['code']),
        ['RK-CONF-034'],
      );
      expect(configRun.all, contains('symbolic link'));
      expect(manifestRun.code, 1, reason: manifestRun.all);
      expect(
        manifestRun.problems.map((problem) => problem['code']),
        ['RK-SRC-003'],
      );
      expect(manifestRun.all, contains('symbolic link'));

      for (final (repo, expected) in [
        (configLink, 'RK-CONF-034'),
        (manifestLink, 'RK-SRC-003'),
      ]) {
        for (final command in ['status', 'release']) {
          final run = repo([command, '--json']);
          expect(run.code, 1, reason: '$command: ${run.all}');
          expect(
            run.problems.map((problem) => problem['code']),
            [expected],
          );
          expect(run.all, isNot(contains('RK-INT-001')));
        }
      }
    });

    test('shows Git-target topology before the repository has Git identity',
        () {
      final loose = Directory('${scratch.path}/plan-before-git')
        ..createSync(recursive: true);
      File('${loose.path}/release.toml').writeAsStringSync('''
schema = 2

[release.tool]
tag = "v{version}"
publish = ["git-tag", "github-release"]
''');
      File('${loose.path}/pubspec.yaml').writeAsStringSync('''
name: plan_before_git
version: 1.0.0
publish_to: none
''');

      final run = Rk(loose.path)(['plan', '--json']);

      expect(run.code, 0, reason: run.all);
      expect(run.problems, isEmpty);
      expect((run.json['repository']! as Map)['remote'], isNull);
      final plan = run.json['plan']! as Map<String, Object?>;
      expect(
        jsonEncode(plan),
        allOf(
          contains('tool/tag/v1.0.0'),
          contains('tool/stage/release-notes'),
          contains('tool/github-release/v1.0.0'),
        ),
      );
      expect(Directory('${loose.path}/.rk').existsSync(), isFalse);
    });

    test('unbound commands refuse a configured path through a symbolic link',
        () {
      if (Platform.isWindows) return;
      final outside = Directory('${scratch.path}/plan-link-outside/project')
        ..createSync(recursive: true);
      File('${outside.path}/pubspec.yaml')
          .writeAsStringSync('name: outside_plan\nversion: 1.0.0\n');
      final loose = Directory('${scratch.path}/plan-link-root')
        ..createSync(recursive: true);
      File('${loose.path}/release.toml').writeAsStringSync('''
schema = 2

[release.lib]
path = "packages/project"
publish = ["pub.dev"]
''');
      Link('${loose.path}/packages').createSync(outside.parent.path);

      for (final command in ['plan', 'status', 'release']) {
        final run = Rk(loose.path)([command, '--json']);

        expect(run.code, 1, reason: '$command: ${run.all}');
        expect(
          run.problems.map((problem) => problem['code']),
          ['RK-SRC-003'],
        );
        expect(run.json, isNot(contains('plan')));
        expect(run.all, contains('symbolic link'));
        expect(run.all, isNot(contains('RK-INT-001')));
      }
    });

    test('unbound plan preserves an existing package directory in errors', () {
      final loose = Directory('${scratch.path}/plan-empty-project')
        ..createSync(recursive: true);
      File('${loose.path}/release.toml').writeAsStringSync('''
schema = 2

[release.lib]
path = "package"
publish = ["pub.dev"]
''');
      Directory('${loose.path}/package').createSync();

      final run = Rk(loose.path)(['plan', '--json']);

      expect(run.code, 1, reason: run.all);
      expect(run.problems.map((problem) => problem['code']), ['RK-RES-001']);
      expect(run.all, contains('that directory has no pubspec.yaml'));
      expect(run.all, isNot(contains('that directory does not exist')));
    });

    test('unbound plan does not descend into a manifest directory', () {
      final loose = Directory('${scratch.path}/plan-manifest-directory')
        ..createSync(recursive: true);
      File('${loose.path}/release.toml').writeAsStringSync('''
schema = 2

[release.lib]
path = "package"
publish = ["pub.dev"]
''');
      File('${loose.path}/package/pubspec.yaml/private.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('must not become plan input\n');

      final run = Rk(loose.path)(['plan', '--json']);

      expect(run.code, 1, reason: run.all);
      expect(run.problems.map((problem) => problem['code']), ['RK-SRC-003']);
      expect(run.all, contains('pubspec.yaml'));
      expect(run.all, contains('not a regular file'));
      expect(run.json, isNot(contains('plan')));
    });

    test('a release.toml directory is an error in every source binding', () {
      final clean = Rk.repository(scratch, 'plan-config-directory-clean', {
        'release.toml/entry': 'not a configuration file\n',
      })
        ..commit();
      final dirty = Rk.repository(scratch, 'plan-config-directory-dirty', {
        'release.toml': 'schema = 2\n',
      })
        ..commit();
      File('${dirty.root}/release.toml').deleteSync();
      File('${dirty.root}/release.toml/entry')
        ..createSync(recursive: true)
        ..writeAsStringSync('not a configuration file\n');
      final unbound = Directory('${scratch.path}/plan-config-directory-unbound')
        ..createSync(recursive: true);
      File('${unbound.path}/release.toml/entry')
        ..createSync(recursive: true)
        ..writeAsStringSync('not a configuration file\n');

      for (final repo in [clean, dirty, Rk(unbound.path)]) {
        for (final command in ['plan', 'status', 'release']) {
          final run = repo([command, '--json']);

          expect(run.code, 1, reason: '$command: ${run.all}');
          expect(
            run.problems.map((problem) => problem['code']),
            ['RK-CONF-034'],
          );
          expect(run.json, isNot(contains('plan')));
        }
      }
    });

    test('a named unit narrows output but retains its whole graph', () {
      final run = repo(['plan', 'cli', '--json']);
      expect(run.code, 0, reason: run.all);

      final plan = run.json['plan']! as Map<String, Object?>;
      final units = (plan['units']! as List).cast<Map<String, Object?>>();
      expect(units.map((unit) => unit['name']), ['cli']);
      final nodes =
          (units.single['nodes']! as List).cast<Map<String, Object?>>();
      expect(nodes.map((node) => node['id']), contains('cli/stage/source'));
      expect(
        nodes.map((node) => node['id']),
        contains('cli/github-release/cli-v2.0.0'),
      );
    });

    test('an unknown unit is a usage error and carries no partial plan', () {
      final run = repo(['plan', 'missing', '--json']);

      expect(run.code, 2, reason: run.all);
      expect(run.problems.map((problem) => problem['code']), ['RK-CLI-003']);
      expect(run.json, isNot(contains('plan')));
      expect(run.all, contains('this repository releases: lib, cli'));
    });

    test('human output remains useful when stdout is a pipe', () {
      final run = repo(['plan', 'cli']);

      expect(run.code, 0, reason: run.all);
      expect(run.stdout, contains('release plan'));
      expect(run.stdout, contains('source snapshot'));
      expect(run.stdout, contains('release notes'));
      expect(run.stdout, contains('build plan for linux-x64'));
      expect(run.stdout, contains('GitHub Release'));
      expect(run.stdout, contains('no destination checks'));
      expect(run.stdout, isNot(contains('\x1b')));
    });
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
