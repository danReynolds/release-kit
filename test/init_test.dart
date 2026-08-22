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
      isNot(contains('publish = ["git-tag", "pub.dev", "github-release"')),
      reason: 'binary channels are the human\'s decision',
    );
    expect(buffer.toString(), contains('workspace root'));
  });

  test('a Linux proposal is finishable on Linux when binaries are selected',
      () async {
    final buffer = StringBuffer();
    final written = <String, String>{};
    final output =
        Output(sink: buffer.write, isTerminal: false, useColor: false);
    final code = await InitCommand(
      tree: MemorySourceTree({
        'pubspec.yaml': '''
name: tool
version: 1.0.0
executables:
  tool: tool
''',
      }, description: '/repo/tool'),
      output: output,
      origin: 'owner/tool',
      capabilities: HostCapabilities(
        hostPlatform: 'linux-x64',
        containerRuntime: null,
        hasNativeAssets: false,
      ),
      select: (plan) async => plan.toggle(0, ReleaseChoice.homebrew).plan,
      write: (path, contents) => written[path] = contents,
      confirm: (_) async => true,
    ).run();

    expect(code, ExitCodes.ok);
    expect(written['release.toml'], contains('"linux-x64"'));
    expect(written['release.toml'], isNot(contains('"linux-arm64"')));
    expect(written['release.toml'], isNot(contains('"macos-arm64"')));
    expect(buffer.toString(), contains('macos-arm64 was not selected'));
    final document = jsonDecode(output.report.encode(exit: code)) as Map;
    final platforms =
        ((document['init'] as Map)['binary_platforms'] as List).cast<Map>();
    expect(
      platforms.singleWhere((item) => item['name'] == 'macos-arm64'),
      containsPair('selected_by_default', false),
    );
  });

  test('never edits an existing config', () async {
    final buffer = StringBuffer();
    final written = <String, String>{};
    await InitCommand(
      tree: MemorySourceTree({'release.toml': 'schema = 2\n'}),
      output: Output(sink: buffer.write, isTerminal: false, useColor: false),
      write: (path, contents) => written[path] = contents,
      confirm: (_) async => true,
    ).run();
    expect(written, isEmpty);
    expect(buffer.toString(), contains('already exists'));
  });

  test('an empty repository skips the selector and reports no candidates',
      () async {
    var selections = 0;
    final output = Output(
      sink: (_) {},
      isTerminal: true,
      useColor: false,
    );
    final code = await InitCommand(
      tree: MemorySourceTree(const {}),
      output: output,
      gitBound: false,
      select: (plan) async {
        selections++;
        return plan;
      },
      write: (_, __) {},
      confirm: (_) async => true,
    ).run();

    expect(code, ExitCodes.ok);
    expect(selections, 0);
    expect(problemCodes(output.report), contains('RK-INIT-003'));
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

  test('a concurrent .gitignore edit is never overwritten', () async {
    final files = <String, String>{
      'pubspec.yaml': 'name: a\nversion: 1.0.0\n',
      '.gitignore': 'build/\n',
    };
    final written = <String, String>{};
    final output = Output(
      sink: (_) {},
      isTerminal: false,
      useColor: false,
    );
    final code = await InitCommand(
      tree: MemorySourceTree(files),
      output: output,
      write: (path, contents) => written[path] = contents,
      confirm: (_) async {
        files['.gitignore'] = 'build/\ncoverage/\n';
        return true;
      },
    ).run();

    expect(code, ExitCodes.refused);
    expect(written, isEmpty);
    expect(problemCodes(output.report), contains('RK-INIT-005'));
  });

  test('proposal and prompt remain readable on a narrow terminal', () async {
    const width = 36;
    final buffer = StringBuffer();
    late Output output;
    output = Output(
      sink: buffer.write,
      isTerminal: true,
      useColor: true,
      terminalWidth: width,
    );
    await InitCommand(
      tree: MemorySourceTree({
        'pubspec.yaml':
            'name: command_line_application\nversion: 1.0.0\nexecutables:\n  app: app\n',
      }, description: '/repo/command-line-application'),
      output: output,
      write: (_, __) {},
      confirm: (prompt) async {
        output.prompt(prompt);
        buffer.writeln(); // the terminal echoes Enter before init continues
        return false;
      },
    ).run();

    final visible = buffer
        .toString()
        .replaceAll(RegExp('\x1b\\[[0-9;]*[A-Za-z]'), '')
        .replaceAll('\r', '')
        .split('\n')
        .where((line) => line.isNotEmpty)
        .toList();
    expect(visible.every((line) => line.runes.length <= width), isTrue);
    expect(visible.join('\n'), contains('write release.toml'));
    expect(visible.join('\n'), contains('[Y/n/b]'));
    expect(visible.join('\n'), contains('nothing was written'));
    expect(buffer.toString(), isNot(contains('…')));
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

  test('a repository without a usable remote does not infer Git tagging',
      () async {
    final written = <String, String>{};
    await InitCommand(
      tree: MemorySourceTree({'pubspec.yaml': 'name: solo\nversion: 1.0.0\n'}),
      output: Output(sink: (_) {}, isTerminal: false, useColor: false),
      write: (path, contents) => written[path] = contents,
      confirm: (_) async => true,
    ).run();
    expect(written['release.toml'], contains('publish = ["pub.dev"]'));
    expect(written['release.toml'], isNot(contains('git-tag')));
  });

  test('non-Git discovery follows only native workspace membership', () async {
    final written = <String, String>{};
    await InitCommand(
      tree: MemorySourceTree({
        'pubspec.yaml': 'name: root\npublish_to: none\nworkspace:\n'
            '  - packages/member\n',
        'packages/member/pubspec.yaml': 'name: member\nversion: 1.0.0\n',
        'vendor/accidental/pubspec.yaml': 'name: accidental\nversion: 9.9.9\n',
      }),
      gitBound: false,
      output: Output(sink: (_) {}, isTerminal: false, useColor: false),
      write: (path, contents) => written[path] = contents,
      confirm: (_) async => true,
    ).run();

    expect(written['release.toml'], contains('[release.member]'));
    expect(written['release.toml'], isNot(contains('accidental')));
    expect(written.containsKey('.gitignore'), isFalse);
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
      origin: 'example/solo',
      write: (_, __) {},
      confirm: null, // nobody at a terminal — the fleet-sweep case
    ).run();

    expect(
      output.report.attachments['release.toml'],
      contains('publish = ["git-tag", "pub.dev"]'),
      reason: 'an agent reads the proposal from the document; a human writes '
          'it at a terminal',
    );
    final document = jsonDecode(output.report.encode(exit: ExitCodes.ok))
        as Map<String, Object?>;
    expect((document['repository'] as Map)['remote'], 'example/solo');
    expect(document['next'], ['rk init --write']);
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

    final exists = await run({'release.toml': 'schema = 2\n'});
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

  test('real init JSON reports its origin and proposal next action', () {
    write('pubspec.yaml', 'name: origin_fixture\nversion: 1.0.0\n');
    commit();
    Process.runSync(
      'git',
      [
        'remote',
        'add',
        'origin',
        'git@github.com:example/origin-fixture.git',
      ],
      workingDirectory: root.path,
    );

    final run = Rk(root.path)(['init', '--json']);
    expect(run.code, ExitCodes.ok, reason: run.all);
    expect((run.json['repository'] as Map)['remote'], 'example/origin-fixture');
    expect(run.json['next'], ['rk init --write']);
    expect(run.json['attachments'], contains('release.toml'));
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
