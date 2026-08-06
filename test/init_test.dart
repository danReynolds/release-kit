import 'dart:convert';
import 'dart:io';

import 'package:release_kit/src/commands/init.dart';
import 'package:release_kit/src/output/report.dart';
import 'package:release_kit/src/engine/config.dart';
import 'package:release_kit/src/engine/diagnostic.dart';
import 'package:release_kit/src/engine/resolve.dart';
import 'package:release_kit/src/output/output.dart';
import 'package:release_kit/src/engine/source_tree.dart';
import 'package:test/test.dart';

void main() {
  dogfoodRegressions();
  closeoutRegressions();
  realRepositoryRegressions();
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
      confirm: (_) async => true,
    ).run();

    final config = written['release.toml']!;
    expect(config, contains('[release.a]'));
    expect(config, contains('[release.b]'));
    expect(config, contains('path = "packages/a"'));
    expect(
      config,
      isNot(contains('binary_platforms =')),
      reason: 'an executable is not a request for signed binaries; the '
          'comment offers the option, the config does not take it',
    );
    expect(
      config,
      isNot(contains('publish = ["pub.dev", "github-release"')),
      reason: 'binary channels are the human\'s decision',
    );
    expect(buffer.toString(), contains('workspace root'));
  });

  test('never edits an existing config', () async {
    final buffer = StringBuffer();
    final written = <String, String>{};
    await InitCommand(
      tree: MemorySourceTree({'release.toml': 'schema = 1\n'}),
      output: Output(sink: buffer.write, isTerminal: false, useColor: false),
      write: (path, contents) => written[path] = contents,
      confirm: (_) async => true,
    ).run();
    expect(written, isEmpty);
    expect(buffer.toString(), contains('already exists'));
  });

  test('declining writes nothing', () async {
    final buffer = StringBuffer();
    final written = <String, String>{};
    await InitCommand(
      tree: MemorySourceTree({'pubspec.yaml': 'name: a\nversion: 1.0.0\n'}),
      output: Output(sink: buffer.write, isTerminal: false, useColor: false),
      write: (path, contents) => written[path] = contents,
      confirm: (_) async => false,
    ).run();
    expect(written, isEmpty);
    expect(buffer.toString(), contains('nothing was written'));
  });

  test('a repository with nothing releasable is not a failure', () async {
    final buffer = StringBuffer();
    final code = await InitCommand(
      tree: MemorySourceTree({
        'pubspec.yaml': 'name: fixtures\nversion: 1.0.0\npublish_to: none\n',
      }),
      output: Output(sink: buffer.write, isTerminal: false, useColor: false),
      write: (path, contents) {},
      confirm: (_) async => true,
    ).run();
    expect(code, ExitCodes.ok);
    expect(buffer.toString(), contains('nothing here can be released'));
  });

  test('a single package gets the bare tag convention', () async {
    final written = <String, String>{};
    await InitCommand(
      tree: MemorySourceTree({'pubspec.yaml': 'name: solo\nversion: 1.0.0\n'}),
      output: Output(sink: (_) {}, isTerminal: false, useColor: false),
      write: (path, contents) => written[path] = contents,
      confirm: (_) async => true,
    ).run();
    expect(written['release.toml'], contains('# tag v{version}'));
    expect(written['release.toml'], isNot(contains('solo-v')));
  });
}

/// Phase 6 hardening: the proposal is validated against rk itself.
void dogfoodRegressions() {
  test('colliding unit names are refused, not written', () async {
    // Two package names that sanitize onto one table: the generated config
    // would define [release.foobar] twice, and rk's own parser refuses a
    // duplicate table — so init must refuse first, not hand the operator a
    // file that rk then rejects as if they had written it.
    final buffer = StringBuffer();
    final written = <String, String>{};
    final code = await InitCommand(
      tree: MemorySourceTree({
        'packages/a/pubspec.yaml': 'name: foo.bar\nversion: 1.0.0\n',
        'packages/b/pubspec.yaml': 'name: foobar\nversion: 1.0.0\n',
      }, description: '/repo/collide'),
      output: Output(sink: buffer.write, isTerminal: false, useColor: false),
      write: written.putIfAbsent2,
      confirm: (_) async => true,
    ).run();

    expect(code, ExitCodes.refused);
    expect(written, isEmpty, reason: 'nothing rk refuses may be written');
    expect(buffer.toString(), contains('rk itself refuses'));
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
      confirm: (_) async => true,
    ).run();
    expect(code, ExitCodes.ok);

    final diagnostics = Diagnostics();
    final parsed = ReleaseConfig.parse(
        written['release.toml']!, 'release.toml', diagnostics)!;
    final resolution = Resolution.resolve(parsed, tree, diagnostics);
    expect(resolution, isNotNull, reason: diagnostics.found.join('\n'));
    expect(resolution!.units.single.projects.single.name, 'keybay');
  });

  test('the proposal reaches the machine surface as an attachment', () async {
    final output = Output(sink: (_) {}, isTerminal: false, useColor: false);
    await InitCommand(
      tree: MemorySourceTree({
        'pubspec.yaml': 'name: solo\nversion: 1.0.0\n',
      }, description: '/repo/solo'),
      output: output,
      write: (_, __) {},
      confirm: null, // nobody at a terminal — the fleet-sweep case
    ).run();

    expect(
      output.report.attachments['release.toml'],
      contains('publish = ["pub.dev"]'),
      reason: 'an agent reads the proposal from the document; a human writes '
          'it at a terminal',
    );
  });
}

/// The problems list as a --json caller reads it: decoded from the encoded
/// document, not reached through the report's internals.
Iterable<Object?> problemCodes(Report report, {int exit = 0}) {
  final doc = jsonDecode(report.encode(exit: exit)) as Map<String, Object?>;
  return (doc['problems'] as List)
      .map((p) => (p as Map<String, Object?>)['code']);
}

Map<String, Object?> problemNamed(Report report, String code, {int exit = 0}) {
  final doc = jsonDecode(report.encode(exit: exit)) as Map<String, Object?>;
  return (doc['problems'] as List)
      .cast<Map<String, Object?>>()
      .firstWhere((p) => p['code'] == code);
}

/// Phase 6 review closeout: the findings, each pinned where it bit.
void closeoutRegressions() {
  test('EOF is not consent; enter at a real prompt is', () {
    // `rk init < /dev/null` used to write the file: EOF read as null,
    // null collapsed to the empty string, and empty means Yes. macOS
    // reports a terminal for /dev/null, so hasTerminal never guarded it.
    expect(InitCommand.consented(null), isFalse,
        reason: 'nobody answering is not an answer');
    expect(InitCommand.consented(''), isTrue,
        reason: 'a bare enter takes the [Y/n] default');
    expect(InitCommand.consented('  '), isTrue);
    expect(InitCommand.consented('y'), isTrue);
    expect(InitCommand.consented('Y'), isTrue);
    expect(InitCommand.consented('yes'), isTrue);
    expect(InitCommand.consented('n'), isFalse);
    expect(InitCommand.consented('no'), isFalse);
    expect(InitCommand.consented('q'), isFalse);
    expect(InitCommand.consented('yolo'), isFalse,
        reason: 'anything that is not a yes is a no');
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
      confirm: (_) async => true,
    ).run();

    expect(code, ExitCodes.refused);
    expect(
      problemCodes(output.report, exit: code),
      contains('RK-INIT-001'),
    );
    expect(
      output.report.attachments['release.toml.refused'],
      contains('[release.foobar]'),
      reason: 'the problems name lines in a document; the document must be '
          'in the report for those references to have a referent',
    );
    expect(
      output.report.attachments.containsKey('release.toml'),
      isFalse,
      reason: 'the unqualified name is the accepted proposal only — a caller '
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
      await InitCommand(
        tree: MemorySourceTree(files, description: '/repo/x'),
        output: output,
        write: (_, __) {},
        confirm: null,
      ).run();
      return output.report;
    }

    final exists = await run({'release.toml': 'schema = 1\n'});
    final nothing = await run({
      'pubspec.yaml': 'name: x\nversion: 1.0.0\npublish_to: none\n',
    });
    final proposal = await run({'pubspec.yaml': 'name: x\nversion: 1.0.0\n'});

    expect(problemCodes(exists), contains('RK-INIT-002'));
    expect(problemCodes(nothing), contains('RK-INIT-003'));
    expect(problemCodes(proposal), isEmpty);
    expect(proposal.attachments['release.toml'], isNotNull);
  });

  test('the skip reasons travel in the document, not only the terminal',
      () async {
    final output = Output(sink: (_) {}, isTerminal: false, useColor: false);
    await InitCommand(
      tree: MemorySourceTree({
        'pubspec.yaml': 'name: x\nversion: 1.0.0\npublish_to: none\n',
        'packages/bad/pubspec.yaml': 'name: [broken\n',
      }, description: '/repo/x'),
      output: output,
      write: (_, __) {},
      confirm: null,
    ).run();

    final remedy =
        problemNamed(output.report, 'RK-INIT-003')['remedy']! as String;
    expect(remedy, contains('packages/bad/pubspec.yaml'));
    expect(remedy, contains('could not be parsed'));
    expect(remedy, contains('publish_to: none'));
  });

  test('the executable comment appears exactly when an executable exists',
      () async {
    Future<String> proposalFor(Map<String, String> files) async {
      final output = Output(sink: (_) {}, isTerminal: false, useColor: false);
      await InitCommand(
        tree: MemorySourceTree(files, description: '/repo/x'),
        output: output,
        write: (_, __) {},
        confirm: null,
      ).run();
      return output.report.attachments['release.toml']!;
    }

    expect(
      await proposalFor({
        'pubspec.yaml': 'name: cli\nversion: 1.0.0\nexecutables:\n  cli: cli\n',
      }),
      contains('# A package here declares an executable'),
    );
    expect(
      await proposalFor({'pubspec.yaml': 'name: lib\nversion: 1.0.0\n'}),
      isNot(contains('# A package here declares an executable')),
      reason: 'a comment about executables over a repository with none reads '
          'as a bug in the scanner',
    );
  });

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
      confirm: null,
    ).run();
    expect(
      output.report.attachments['release.toml'],
      contains('[release.mycool-package_2]'),
    );
  });

  group('.gitignore', () {
    Future<(Map<String, String>, String)> writeAccepting(
        Map<String, String> files) async {
      final written = <String, String>{};
      String prompt = '';
      await InitCommand(
        tree: MemorySourceTree(files, description: '/repo/x'),
        output: Output(sink: (_) {}, isTerminal: false, useColor: false),
        write: (path, contents) => written[path] = contents,
        confirm: (p) async {
          prompt = p;
          return true;
        },
      ).run();
      return (written, prompt);
    }

    test('is created when absent, and the prompt says so', () async {
      final (written, prompt) =
          await writeAccepting({'pubspec.yaml': 'name: a\nversion: 1.0.0\n'});
      expect(written['.gitignore'], '.rk/\n');
      expect(prompt, contains('add .rk/ to .gitignore'));
    });

    test('is appended without eating the last line', () async {
      final (written, _) = await writeAccepting({
        'pubspec.yaml': 'name: a\nversion: 1.0.0\n',
        '.gitignore': 'build/', // no trailing newline
      });
      expect(written['.gitignore'], 'build/\n.rk/\n');
    });

    test('is left alone when .rk/ is already ignored', () async {
      final (written, prompt) = await writeAccepting({
        'pubspec.yaml': 'name: a\nversion: 1.0.0\n',
        '.gitignore': 'build/\n.rk/\n',
      });
      expect(written.containsKey('.gitignore'), isFalse);
      expect(prompt, isNot(contains('.gitignore')),
          reason: 'the prompt names what the Yes will do, and nothing else');
    });
  });
}

/// Against real repositories: what git tracks versus what the disk holds is
/// exactly the distinction MemorySourceTree cannot model.
void realRepositoryRegressions() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('rk-init-');
    Process.runSync('git', ['init', '-q'], workingDirectory: root.path);
    Process.runSync('git', ['config', 'user.email', 'a@b.c'],
        workingDirectory: root.path);
    Process.runSync('git', ['config', 'user.name', 'T'],
        workingDirectory: root.path);
  });

  tearDown(() => root.deleteSync(recursive: true));

  void write(String path, String contents) {
    File('${root.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
  }

  void commit() {
    Process.runSync('git', ['add', '-A'], workingDirectory: root.path);
    Process.runSync('git', ['commit', '-qm', 'x'], workingDirectory: root.path);
  }

  Future<(int, Report, String)> init() async {
    final buffer = StringBuffer();
    final output =
        Output(sink: buffer.write, isTerminal: false, useColor: false);
    final code = await InitCommand(
      tree: GitSourceTree(root.path),
      output: output,
      write: (_, __) {},
      confirm: null,
    ).run();
    return (code, output.report, buffer.toString());
  }

  test('an untracked manifest is named with its command, never proposed from',
      () async {
    write('pubspec.yaml', 'name: tracked\nversion: 1.0.0\n');
    commit();
    write('packages/extra/pubspec.yaml', 'name: extra\nversion: 2.0.0\n');
    // Deliberately not committed: this is the forgot-to-add case.

    final (code, report, text) = await init();
    expect(code, ExitCodes.ok);
    expect(report.attachments['release.toml'], contains('[release.tracked]'));
    expect(
      report.attachments['release.toml'],
      isNot(contains('extra')),
      reason: 'tracked-only is the rule; a proposal from an untracked file '
          'would release what git cannot reproduce',
    );
    expect(text, contains('not tracked by git'));
    expect(text, contains('git add packages/extra/pubspec.yaml'));
  });

  test('a tracked manifest missing from disk is named, not skipped silently',
      () async {
    write('pubspec.yaml', 'name: root\nversion: 1.0.0\n');
    write('packages/gone/pubspec.yaml', 'name: gone\nversion: 1.0.0\n');
    commit();
    File('${root.path}/packages/gone/pubspec.yaml').deleteSync();

    final (_, _, text) = await init();
    expect(
        text,
        contains('packages/gone/pubspec.yaml is tracked but not on '
            'disk'));
  });

  test('a directory git cannot list is a named refusal, not a bug in rk',
      () async {
    final bare = Directory.systemTemp.createTempSync('rk-notrepo-');
    addTearDown(() => bare.deleteSync(recursive: true));

    final output = Output(sink: (_) {}, isTerminal: false, useColor: false);
    final code = await InitCommand(
      tree: GitSourceTree(bare.path),
      output: output,
      write: (_, __) {},
      confirm: null,
    ).run();

    expect(code, ExitCodes.refused);
    expect(
      problemCodes(output.report, exit: code),
      contains('RK-GIT-006'),
      reason: 'ls-files failing used to read as "this repository tracks '
          'nothing", which proposed nothing and called that an answer',
    );
  });
}

extension on Map<String, String> {
  void putIfAbsent2(String key, String value) => this[key] = value;
}
