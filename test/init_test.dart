import 'dart:convert';
import 'dart:io';

import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/commands/init.dart';
import 'package:rk/src/engine/release_choice.dart';
import 'package:rk/src/output/report.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:test/test.dart';

import 'rk_process.dart';

void main() {
  test('proposes one unit per releasable package', () async {
    final buffer = StringBuffer();
    final written = <String, String>{};
    await InitCommand(
      tree: MemorySourceTree({
        'pubspec.yaml': 'name: root\npublish_to: none\nworkspace:\n  - a\n',
        'packages/a/pubspec.yaml': 'name: a\nversion: 1.0.0\n',
        'packages/b/pubspec.yaml':
            'name: b\nversion: 1.0.0\nexecutables:\n  b: b\n',
      }, description: '/repo/demo'),
      output: Output(sink: buffer.write, isTerminal: false, useColor: false),
      write: (path, contents) => written[path] = contents,
      yes: true,
    ).run();

    final config = written['release.toml']!;
    expect(config, contains('[release.a]'));
    expect(config, contains('[release.b]'));
    expect(config, contains('path = "packages/a"'));
    expect(
      config,
      isNot(contains('binary_platforms =')),
      reason:
          'an executable is not a request for signed binaries; the '
          'comment offers the option, the config does not take it',
    );
    expect(
      config,
      isNot(contains('publish = ["git-tag", "pub.dev", "github-release"')),
      reason: 'binary channels are the human\'s decision',
    );
    expect(buffer.toString(), contains('workspace root'));
  });

  test('never edits an existing config', () async {
    final buffer = StringBuffer();
    final written = <String, String>{};
    await InitCommand(
      tree: MemorySourceTree({'release.toml': 'schema = 2\n'}),
      output: Output(sink: buffer.write, isTerminal: false, useColor: false),
      write: (path, contents) => written[path] = contents,
      yes: true,
    ).run();
    expect(written, isEmpty);
    expect(buffer.toString(), contains('already exists'));
  });

  test(
    'an empty repository skips the selector and reports no candidates',
    () async {
      var selections = 0;
      final output = Output(sink: (_) {}, isTerminal: true, useColor: false);
      final code = await InitCommand(
        tree: MemorySourceTree(const {}),
        output: output,
        gitBound: false,
        select: (plan) async {
          selections++;
          return plan;
        },
        write: (_, __) {},
        yes: true,
      ).run();

      expect(code, ExitCodes.ok);
      expect(selections, 0);
      expect(problemCodes(output.report), contains('RK-INIT-003'));
    },
  );

  test(
    'cancelling a customized review retries selection, not defaults',
    () async {
      final buffer = StringBuffer();
      final written = <String, String>{};
      final output = Output(
        sink: buffer.write,
        isTerminal: true,
        useColor: false,
      );
      String? reviewed;
      final code = await InitCommand(
        tree: MemorySourceTree({
          'pubspec.yaml':
              'name: tool\nversion: 1.0.0\nexecutables:\n  tool: tool\n',
        }),
        gitBound: false,
        capabilities: HostCapabilities(
          hostPlatform: 'linux-x64',
          containerRuntime: null,
        ),
        output: output,
        select: (plan) async => plan
            .toggle(0, ReleaseChoice.pubDev)
            .plan
            .toggle(0, ReleaseChoice.binary)
            .plan,
        review: (proposal, _) async {
          reviewed = proposal;
          return InitReviewDecision.cancel;
        },
        write: (path, contents) => written[path] = contents,
      ).run();

      expect(code, ExitCodes.ok);
      expect(reviewed, contains('binary_platforms'));
      expect(reviewed, isNot(contains('pub.dev')));
      expect(written, isEmpty);
      final document = jsonDecode(output.report.encode(exit: code)) as Map;
      expect(document['next'], ['rk init']);
      expect(buffer.toString(), contains('→ rk init'));
      expect(buffer.toString(), isNot(contains('--write')));
    },
  );

  test('a .gitignore edited during the review refuses the write', () async {
    final files = <String, String>{
      'pubspec.yaml': 'name: a\nversion: 1.0.0\n',
      '.gitignore': 'build/\n',
    };
    final written = <String, String>{};
    var ignored = 0;
    final output = Output(sink: (_) {}, isTerminal: false, useColor: false);
    final code = await InitCommand(
      tree: MemorySourceTree(files),
      output: output,
      write: (path, contents) => written[path] = contents,
      updateGitignore: () => ignored++,
      review: (_, _) async {
        files['.gitignore'] = 'build/\ncoverage/\n';
        return InitReviewDecision.write;
      },
    ).run();

    expect(code, ExitCodes.refused);
    expect(written, isEmpty);
    expect(ignored, 0);
    expect(problemCodes(output.report, exit: code), contains('RK-INIT-005'));
  });

  test(
    'a repository without a usable remote does not infer Git tagging',
    () async {
      final written = <String, String>{};
      await InitCommand(
        tree: MemorySourceTree({
          'pubspec.yaml': 'name: solo\nversion: 1.0.0\n',
        }),
        output: Output(sink: (_) {}, isTerminal: false, useColor: false),
        write: (path, contents) => written[path] = contents,
        yes: true,
      ).run();
      expect(written['release.toml'], contains('publish = ["pub.dev"]'));
      expect(written['release.toml'], isNot(contains('git-tag')));
    },
  );

  group('in a Git repository', () {
    // What git tracks against what the disk holds: exactly the distinction
    // MemorySourceTree cannot model.
    late Directory scratch;
    setUpAll(() => scratch = Directory.systemTemp.createTempSync('rk-init-'));
    tearDownAll(() => scratch.deleteSync(recursive: true));

    Future<(int, Report, String)> init(String root) async {
      final buffer = StringBuffer();
      final output = Output(
        sink: buffer.write,
        isTerminal: false,
        useColor: false,
      );
      final code = await InitCommand(
        tree: GitSourceTree(root),
        output: output,
        write: (_, __) {},
      ).run();
      return (code, output.report, buffer.toString());
    }

    test(
      'an untracked manifest is named with its command, never proposed from',
      () async {
        final repo = Rk.repository(scratch, 'untracked', {
          'pubspec.yaml': 'name: tracked\nversion: 1.0.0\n',
        })..commit();
        // Deliberately not committed: this is the forgot-to-add case.
        File('${repo.root}/packages/extra/pubspec.yaml')
          ..createSync(recursive: true)
          ..writeAsStringSync('name: extra\nversion: 2.0.0\n');

        final (code, report, text) = await init(repo.root);
        expect(code, ExitCodes.ok);
        expect(
          report.attachments['release.toml'],
          contains('[release.tracked]'),
        );
        expect(
          report.attachments['release.toml'],
          isNot(contains('extra')),
          reason:
              'tracked-only is the rule; a proposal from an untracked file '
              'would release what git cannot reproduce',
        );
        expect(text, contains('not tracked by git'));
        expect(text, contains('git add packages/extra/pubspec.yaml'));
      },
    );

    test(
      'a tracked manifest missing from disk is named, not skipped silently',
      () async {
        final repo = Rk.repository(scratch, 'missing', {
          'pubspec.yaml': 'name: root\nversion: 1.0.0\n',
          'packages/gone/pubspec.yaml': 'name: gone\nversion: 1.0.0\n',
        })..commit();
        File('${repo.root}/packages/gone/pubspec.yaml').deleteSync();

        final (_, _, text) = await init(repo.root);
        expect(
          text,
          contains('packages/gone/pubspec.yaml is tracked but not on disk'),
        );
      },
    );

    test('real init JSON reports its origin and proposal next action', () {
      final repo = Rk.repository(scratch, 'origin', {
        'pubspec.yaml': 'name: origin_fixture\nversion: 1.0.0\n',
      })..commit();
      Process.runSync('git', [
        'remote',
        'add',
        'origin',
        'git@github.com:example/origin-fixture.git',
      ], workingDirectory: repo.root);

      final run = repo(['init', '--json']);
      expect(run.code, ExitCodes.ok, reason: run.all);
      expect(
        (run.json['repository'] as Map)['remote'],
        'example/origin-fixture',
      );
      expect(run.json['next'], ['rk init --write']);
      expect(run.json['attachments'], contains('release.toml'));
    });

    test(
      'a directory git cannot list is a named refusal, not a bug in rk',
      () async {
        final bare = Directory('${scratch.path}/not-a-repository')
          ..createSync();

        final (code, report, _) = await init(bare.path);
        expect(code, ExitCodes.refused);
        expect(
          problemCodes(report, exit: code),
          contains('RK-GIT-006'),
          reason:
              'ls-files failing used to read as "this repository tracks '
              'nothing", which proposed nothing and called that an answer',
        );
      },
    );

    /// The .gitignore `rk init --write` leaves, given the one it found.
    String? ignoredAfterInit(String name, {String? gitignore}) {
      final repo = Rk.repository(scratch, name, {
        'pubspec.yaml': 'name: tool\nversion: 1.0.0\n',
        '.gitignore': ?gitignore,
      })..commit();
      final run = repo(['init', '--write']);
      expect(run.code, ExitCodes.ok, reason: run.all);
      expect(File('${repo.root}/release.toml').existsSync(), isTrue);
      final file = File('${repo.root}/.gitignore');
      return file.existsSync() ? file.readAsStringSync() : null;
    }

    test('--write adds .rk/ on a line of its own, after what was there', () {
      expect(
        ignoredAfterInit('unterminated', gitignore: 'build/'),
        'build/\n.rk/\n',
      );
      expect(ignoredAfterInit('absent'), '.rk/\n');
    });

    test('--write leaves a .gitignore that already ignores .rk/ as it was', () {
      expect(
        ignoredAfterInit('ignored', gitignore: 'build/\n.rk/\n'),
        'build/\n.rk/\n',
      );
    });
  });

  test('the accepted proposal resolves end to end', () async {
    // The dogfood loop: init writes, and what it wrote must release — parsed
    // by rk's parser, resolved against the same tree, checklist derivable.
    final tree = MemorySourceTree({
      'pubspec.yaml': '''
name: keybay_workspace
publish_to: none
workspace:
  - packages/keybay
''',
      'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
    }, description: '/repo/keybay');

    final written = <String, String>{};
    final code = await InitCommand(
      tree: tree,
      output: Output(sink: (_) {}, isTerminal: false, useColor: false),
      write: (path, contents) => written[path] = contents,
      yes: true,
    ).run();
    expect(code, ExitCodes.ok);

    final diagnostics = Diagnostics();
    final parsed = ReleaseConfig.parse(
      written['release.toml']!,
      'release.toml',
      diagnostics,
    )!;
    final resolution = Resolution.resolve(parsed, tree, diagnostics);
    expect(resolution, isNotNull, reason: diagnostics.found.join('\n'));
    expect(resolution!.units.single.projects.single.name, 'keybay');
  });

  test('a refusal carries the refused proposal and its problems', () async {
    final output = Output(sink: (_) {}, isTerminal: false, useColor: false);
    final written = <String, String>{};
    final code = await InitCommand(
      tree: MemorySourceTree({
        'packages/a/pubspec.yaml': 'name: foo.bar\nversion: 1.0.0\n',
        'packages/b/pubspec.yaml': 'name: foobar\nversion: 1.0.0\n',
      }, description: '/repo/collide'),
      output: output,
      write: (path, contents) => written[path] = contents,
      yes: true,
    ).run();

    expect(code, ExitCodes.refused);
    expect(written, isEmpty, reason: 'nothing rk refuses may be written');
    expect(problemCodes(output.report, exit: code), contains('RK-INIT-001'));
    expect(
      output.report.attachments['release.toml.refused'],
      contains('[release.foobar]'),
      reason:
          'the problems name lines in a document; the document must be '
          'in the report for those references to have a referent',
    );
    expect(
      output.report.attachments.containsKey('release.toml'),
      isFalse,
      reason:
          'the unqualified name is the accepted proposal only — a caller '
          'that writes attachments["release.toml"] must never write a '
          'refused one',
    );
    expect(
      output.report.rerunHelps,
      isFalse,
      reason: 'the same manifests derive the same refused proposal',
    );
  });

  test('the three quiet exits are three different documents', () async {
    // Already configured, nothing releasable, and awaiting-a-human all exit 0
    // and used to encode byte-identical empty reports — an agent sweeping a
    // fleet could not tell them apart without parsing prose.
    Future<Report> run(Map<String, String> files) async {
      final output = Output(sink: (_) {}, isTerminal: false, useColor: false);
      final code = await InitCommand(
        tree: MemorySourceTree(files, description: '/repo/x'),
        output: output,
        write: (_, __) {},
      ).run();
      expect(code, ExitCodes.ok, reason: 'none of the three is a failure');
      return output.report;
    }

    final exists = await run({'release.toml': 'schema = 2\n'});
    final nothing = await run({
      'pubspec.yaml': 'name: x\nversion: 1.0.0\npublish_to: none\n',
    });
    final proposal = await run({'pubspec.yaml': 'name: x\nversion: 1.0.0\n'});

    expect(problemCodes(exists), isEmpty);
    expect(
      (jsonDecode(exists.encode(exit: 0)) as Map)['next'],
      ['rk status'],
      reason: 'already configured leads to status; it is not a problem',
    );
    expect(problemCodes(nothing), contains('RK-INIT-003'));
    expect(problemCodes(proposal), isEmpty);
    expect(proposal.attachments['release.toml'], isNotNull);
  });

  test(
    'the skip reasons travel in the document, not only the terminal',
    () async {
      final output = Output(sink: (_) {}, isTerminal: false, useColor: false);
      await InitCommand(
        tree: MemorySourceTree({
          'pubspec.yaml': 'name: x\nversion: 1.0.0\npublish_to: none\n',
          'packages/bad/pubspec.yaml': 'name: [broken\n',
        }, description: '/repo/x'),
        output: output,
        write: (_, __) {},
      ).run();

      final remedy =
          problemNamed(output.report, 'RK-INIT-003')['remedy']! as String;
      expect(remedy, contains('packages/bad/pubspec.yaml'));
      expect(remedy, contains('could not be parsed'));
      expect(remedy, contains('publish_to: none'));
    },
  );

  test(
    'the executable comment appears exactly when an executable exists',
    () async {
      Future<String> proposalFor(Map<String, String> files) async {
        final output = Output(sink: (_) {}, isTerminal: false, useColor: false);
        await InitCommand(
          tree: MemorySourceTree(files, description: '/repo/x'),
          output: output,
          write: (_, __) {},
        ).run();
        return output.report.attachments['release.toml']!;
      }

      expect(
        await proposalFor({
          'pubspec.yaml':
              'name: cli\nversion: 1.0.0\nexecutables:\n  cli: cli\n',
        }),
        contains('# A package here declares an executable'),
      );
      expect(
        await proposalFor({'pubspec.yaml': 'name: lib\nversion: 1.0.0\n'}),
        isNot(contains('# A package here declares an executable')),
        reason:
            'a comment about executables over a repository with none reads '
            'as a bug in the scanner',
      );
    },
  );

  test('unit names are sanitized, and the rules are pinned', () async {
    // The unit name is what policy and step ids are written in terms of, so
    // the mapping from package name to unit name is load-bearing: lowercase,
    // drop what TOML bare keys cannot carry, keep hyphens and underscores.
    final output = Output(sink: (_) {}, isTerminal: false, useColor: false);
    await InitCommand(
      tree: MemorySourceTree({
        'pubspec.yaml': 'name: My.Cool-Package_2\nversion: 1.0.0\n',
      }, description: '/repo/x'),
      output: output,
      write: (_, __) {},
    ).run();
    expect(
      output.report.attachments['release.toml'],
      contains('[release.mycool-package_2]'),
    );
  });
}

/// The problems list as a --json caller reads it: decoded from the encoded
/// document, not reached through the report's internals.
Iterable<Object?> problemCodes(Report report, {int exit = 0}) {
  final doc = jsonDecode(report.encode(exit: exit)) as Map<String, Object?>;
  return (doc['problems'] as List).map(
    (p) => (p as Map<String, Object?>)['code'],
  );
}

Map<String, Object?> problemNamed(Report report, String code, {int exit = 0}) {
  final doc = jsonDecode(report.encode(exit: exit)) as Map<String, Object?>;
  return (doc['problems'] as List).cast<Map<String, Object?>>().firstWhere(
    (p) => p['code'] == code,
  );
}
