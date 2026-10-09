import 'dart:io';
import 'bundle_tools.dart';

import 'dart:convert';

import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/commands/release.dart';
import 'package:rk/src/targets/pub_dev/client.dart';
import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/file_mode.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/inspect.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/release_stage.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/engine/stage_plan.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/unit_release.dart';
import 'package:rk/src/transforms/archive.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

import 'pub_resolution_double.dart';
import 'rk_process.dart';
import 'status_test.dart' show FakeRegistry;
import 'support/compiled_rk.dart';
import 'support/memory_source_tree.dart';

/// rk run end to end: against the example repositories, through its
/// machine surface, and through whole releases with scripted tools.
void main() {
  Iterable<Object?> problemCodes(Map<String, Object?> report) =>
      (report['problems'] as List).cast<Map>().map(
        (problem) => problem['code'],
      );

  group('example repositories', () {
    test('every example plans its units, but the one rk must refuse', () {
      // Planning reads no destination, so this is the same on any machine.
      final scratch = Directory.systemTemp.createTempSync('rk-examples-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final shapes = [
        for (final entry in Directory('examples').listSync())
          if (entry is Directory) entry.path.split(Platform.pathSeparator).last,
      ]..remove('escapes-repository');
      expect(shapes, hasLength(greaterThanOrEqualTo(4)));

      for (final shape in shapes) {
        final run = Rk.example(scratch, shape)(['plan', '--json']);
        expect(run.code, 0, reason: '$shape: ${run.all}');
        final units = ((run.json['plan'] as Map)['units'] as List).cast<Map>();
        expect(units, isNotEmpty, reason: shape);
        for (final unit in units) {
          expect(unit['nodes'], isNotEmpty, reason: '$shape: ${unit['name']}');
        }
      }

      final refused = Rk.example(scratch, 'escapes-repository')(['plan']);
      expect(refused.code, 1, reason: refused.all);
      expect(refused.all, contains('does not contain'));
    });
  });

  group('output', () {
    // The compiled rk, run against a real repository: what a pipe, a caller
    // reading --json and an operator after a crash actually receive.
    late Directory scratch;
    late Rk repo;

    setUpAll(() {
      scratch = Directory.systemTemp.createTempSync('rk-output-');
      repo = Rk.example(scratch, 'workspace-with-dependent');
    });

    tearDownAll(() => scratch.deleteSync(recursive: true));

    test('non-TTY output is append-only: no cursor movement, ever', () {
      final run = repo(['status'], environment: _offline);
      expect(run.all, isNot(contains('\r')));
      expect(
        run.all,
        isNot(contains('\x1b')),
        reason: 'a pipe is not a terminal',
      );
    });

    test('--json carries the checklist, keyed by step id', () {
      final run = repo(['status', '--json'], environment: _offline);
      final steps = run.stepsOf('cli');
      expect(steps, isNotEmpty, reason: 'an empty checklist is not a surface');
      expect(steps.map((s) => s['id']), contains('cli/stage/complete'));
      for (final step in steps) {
        expect(
          step['verdict'],
          isNotNull,
          reason: 'an omitted verdict reads as "nothing is there"',
        );
      }
      // Public targets appear once, in targets[] — the canonical
      // observation an agent keys on. steps[] no longer repeats them.
      expect(
        steps.map((s) => s['id']),
        isNot(contains('cli/pub.dev/example_cli@0.3.0')),
      );
      expect(
        run.targetsOf('cli').map((t) => t['id']),
        contains('cli/pub.dev/example_cli@0.3.0'),
      );
    });

    test('every non-zero exit carries a problem a caller can read', () {
      for (final command in ['status', 'release']) {
        final run = repo([command, 'nosuch', '--json']);
        expect(run.code, ExitCodes.usage, reason: '$command: ${run.all}');
        expect(
          run.problems.map((problem) => problem['code']),
          ['RK-CLI-003'],
          reason:
              'a non-zero exit a caller cannot read is, to that caller, '
              'a non-zero exit that did not happen: $command',
        );
      }
    });

    group('a crash', () {
      late Rk broken;
      late Run run;

      setUpAll(() {
        // A release definition that is not UTF-8. This is a real, currently
        // unhandled decoding failure rather than an injected one — which is
        // the point:
        // the crash path has to be proved against something that actually
        // crashes. When rk learns to report this one, this test must be
        // pointed at another genuine crash, and if none can be found that is
        // a decision worth making deliberately rather than by deletion.
        final directory = Directory('${scratch.path}/broken')..createSync();
        File('${directory.path}/release.toml').writeAsBytesSync([0xff]);
        broken = Rk(directory.path);
        run = broken(['status', '--json']);
      });

      test('exits non-zero rather than pretending it worked', () {
        expect(run.code, isNot(0), reason: run.all);
      });

      test('still produces the document --json promises', () {
        expect(run.json['exit'], run.code);
      });

      test('is honest that a read-only verb changed nothing', () {
        expect((run.json['halt'] as Map?)?['kind'], 'beforeActing');
      });

      test('writes its evidence, and says where', () {
        final written = broken.diagnoses();
        expect(written, isNotEmpty, reason: 'nothing recorded what happened');
        expect(written.single['exit'], run.code);
        expect(run.json['diagnosis'], isNotNull);
      });
    });

    test('the report renders identically to a terminal and a '
        'pipe', () {
      // A pty, so this is the real comparison rather than a replay of it.
      // A bare repository answers deterministically without reading any
      // target, so the comparison is byte-stable on any machine.
      final bare = Rk.repository(scratch, 'pty', {'README.md': 'nothing\n'});
      final piped = bare(['status']).stdout;

      ProcessResult runInPty(Map<String, String> environment) {
        final command = [compiledRk(), 'status'];
        // BSD script(1) accepts the command as trailing arguments. The
        // util-linux implementation used by Ubuntu accepts it through -c.
        final arguments = Platform.isLinux
            ? [
                '-q',
                '-e',
                '-c',
                command.map(_shellQuote).join(' '),
                '/dev/null',
              ]
            : ['-q', '/dev/null', ...command];
        return Process.runSync(
          'script',
          arguments,
          workingDirectory: bare.root,
          environment: environment,
        );
      }

      final pty = runInPty({'NO_COLOR': '1'});

      String settle(String raw) {
        // script(1) echoes the EOF it sends on this platform. That is the
        // harness talking, not rk.
        raw = raw.replaceAll('^D', '').replaceAll('\b', '');
        final out = StringBuffer();
        var line = StringBuffer();
        for (var i = 0; i < raw.length; i++) {
          if (raw.startsWith('\r\x1b[2K', i)) {
            line = StringBuffer();
            i += 4;
            continue;
          }
          final ch = raw[i];
          if (ch == '\n') {
            out.writeln(line.toString().trimRight());
            line = StringBuffer();
          } else if (ch != '\r') {
            line.write(ch);
          }
        }
        return out.toString();
      }

      expect(pty.exitCode, 0, reason: '${pty.stdout}\n${pty.stderr}');
      expect(
        settle(pty.stdout as String),
        settle(piped),
        reason:
            'a log, a pipe and an agent see what the terminal ended up '
            'showing',
      );

      final dumbPty = runInPty({'TERM': 'dumb'});
      final dumb = dumbPty.stdout as String;
      expect(dumbPty.exitCode, 0, reason: dumb);
      expect(
        dumb,
        isNot(contains('\x1b')),
        reason: 'TERM=dumb disables colour, cursor movement, and spinners',
      );
      expect(settle(dumb), settle(piped));
    });
  });

  group('status', () {
    late Directory scratch;

    setUpAll(() => scratch = Directory.systemTemp.createTempSync('rk-status-'));
    tearDownAll(() => scratch.deleteSync(recursive: true));

    test('the engine imports only the Dart team\'s own packages', () {
      // Pub's own version and YAML semantics, and its digest, rather than
      // second implementations of them. The UI stays in the TUI.
      const standard = {
        'package:crypto/',
        'package:pub_semver/',
        'package:yaml/',
      };
      final foreign = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        for (final line in entity.readAsLinesSync()) {
          final match = RegExp("^import '([^']+)'").firstMatch(line.trim());
          final target = match?.group(1);
          if (target == null) continue;
          if (target.startsWith('dart:')) continue;
          if (target.startsWith('package:rk/')) continue;
          if (!target.contains(':')) continue; // relative
          if (standard.any(target.startsWith)) continue;
          if (entity.path.startsWith('lib/src/tui/') &&
              target.startsWith('package:fleury/')) {
            continue;
          }
          foreign.add('${entity.path}: $target');
        }
      }
      expect(foreign, isEmpty);
    });

    test('the forge is read, and being unable to read it is not absence', () {
      final repo = Rk.example(scratch, 'binary-cli', as: 'forge');
      Process.runSync('git', [
        'remote',
        'add',
        'origin',
        'https://github.com/example/nothing.git',
      ], workingDirectory: repo.root);

      // The real gh, with nowhere to connect: its failure is not a fact
      // about whether the release is there.
      final run = repo(['status', '--json'], environment: _offline);
      final release = run
          .targetsOf('cli')
          .where((s) => (s['id'] as String).contains('github-release'))
          .toList();

      expect(release, hasLength(1), reason: 'the forge must be inspected');
      expect(
        release.single['verdict'],
        'unknown',
        reason:
            'a forge rk could not read is not a forge with nothing in it; '
            'absent is what lets a release proceed',
      );
    });
  });

  group('releasing to pub.dev', () {
    // Executed at the command layer with an evolving world: the acts change
    // the same fake registry and tag set the next inspection reads, which is
    // what lets a re-run be the resume. native_publication_test runs the real
    // `dart pub` against a local pub.dev.
    List<int> archiveOfTree() => ArchiveBuilder.gzip(
      ArchiveBuilder.tar([
        ArchiveEntry(
          name: 'pubspec.yaml',
          bytes: 'name: keybay\nversion: 0.2.0\n'.codeUnits,
        ),
        ArchiveEntry(name: 'CHANGELOG.md', bytes: '## 0.2.0\n'.codeUnits),
      ]),
    );

    Future<
      ({
        int code,
        String text,
        List<String> calls,
        Map<String, Object?> report,
        Object? died,
      })
    >
    drive({
      required Map<String, List<String>> published,
      required Map<String, List<int>> archives,
      required Set<String> tags,
      Directory? retainedStageRoot,
      bool stageOnly = false,
      Map<String, ToolResult> results = const {},
      Map<String, String> sourceFiles = const {},
      String? config,
      void Function(String key)? onRun,
      DartSdk Function()? sdk,
      PubResolution pub = const PubResolution(),
      void Function(String key, String workingDirectory)? inspect,
    }) async {
      // A fresh registry per drive is a fresh process: the world — what is
      // published, what archives exist, what tags exist — persists between
      // runs, and the per-process cache does not. A cache that survived
      // "restarts" hid a double publish in this very test.
      final registry = FakeRegistry(published, archives: archives);
      final buffer = StringBuffer();
      final diagnostics = Diagnostics();
      final parsed = ReleaseConfig.parse(
        config ??
            '''
schema = 2

[release.core]
path = "packages/keybay"
publish = ["git-tag", "pub.dev"]
''',
        'release.toml',
        diagnostics,
      )!;
      final tree = MemorySourceTree({
        'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
        'packages/keybay/CHANGELOG.md': '## 0.2.0\n',
        ...sourceFiles,
      }, description: '/repo/keybay');
      final resolution = Resolution.resolve(parsed, tree, diagnostics)!;
      const tagObject = '3333333333333333333333333333333333333333';
      final git = GitState(
        root: '/repo',
        head: '1111111111111111111111111111111111111111',
        branch: 'main',
        isClean: true,
        uncommitted: const [],
        headIsPushed: true,
        tags: tags.toList(),
        tagObjects: {for (final t in tags) t: tagObject},
        tagTargets: {
          for (final t in tags) t: '1111111111111111111111111111111111111111',
        },
        signingConfigured: true,
        originUrl: 'example/keybay',
      );
      late ReleaseStages stages;
      String normalizedPubKey(String key) {
        if (key.contains('pub publish --to-archive ')) {
          return 'dart pub publish --to-archive <archive>';
        }
        if (key.contains('pub publish --from-archive ')) {
          return 'dart pub publish --from-archive <archive> --force';
        }
        return key;
      }

      void materializePubArchive(String key) {
        const marker = 'pub publish --to-archive ';
        final offset = key.indexOf(marker);
        if (offset < 0) return;
        final path = key.substring(offset + marker.length);
        File(path)
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(archiveOfTree());
      }

      final pubAnswers = <String, ToolResult>{};
      late final RecordingTools tools;
      tools = RecordingTools(
        probe: (key, workingDirectory) {
          if (workingDirectory == null) return;
          inspect?.call(normalizedPubKey(key), workingDirectory);
          if (normalizedPubKey(key) ==
              'dart pub publish --to-archive <archive>') {
            pubAnswers[key] = pubPublishIn(
              workingDirectory,
              resolution: pub,
              environment: tools.environments[key],
            );
          }
        },
        onRun: (key) {
          materializePubArchive(key);
          // A successful push is what puts a tag on origin — the same set
          // feeds the next run's local tags and the remote's answer, which
          // is exactly the world after a push: everyone can see it.
          if (key == 'git push origin $tagObject:refs/tags/v0.2.0' &&
              (results[key]?.exitCode ?? 0) == 0) {
            tags.add('v0.2.0');
          }
          onRun?.call(normalizedPubKey(key));
        },
        // Origin answers from the world: a tag the world holds is listed,
        // one it does not is not — the remote leg reads reality, and this is
        // the reality the drive maintains.
        answers: (key) {
          final scripted = results[normalizedPubKey(key)];
          if (scripted != null) return scripted;
          if (pubAnswers[key] case final answer?) return answer;
          if (key == 'git rev-parse --verify refs/tags/v0.2.0^{tag}') {
            return ToolResult(exitCode: 0, stdout: '$tagObject\n', stderr: '');
          }
          if (key == 'git ls-remote --tags origin') {
            return ToolResult(
              exitCode: 0,
              stdout: [
                for (final tag in tags) ...[
                  '$tagObject refs/tags/$tag',
                  '${git.head} refs/tags/$tag^{}',
                ],
              ].join('\n'),
              stderr: '',
            );
          }
          if (key.startsWith('git ls-remote origin refs/tags/v0.2.0')) {
            return ToolResult(
              exitCode: 0,
              stdout: tags.contains('v0.2.0')
                  ? '$tagObject refs/tags/v0.2.0\n'
                        '${git.head} refs/tags/v0.2.0^{}'
                  : '',
              stderr: '',
            );
          }
          if (key == 'git cat-file tag $tagObject') {
            final stage = stages.call(resolution.unit('core')!);
            final manifest = File(
              stage.directory.resolve('release-manifest.json'),
            );
            final digest = manifest.existsSync()
                ? Sha256.hex(manifest.readAsBytesSync())
                : 'b' * 64;
            return ToolResult(
              exitCode: 0,
              stdout:
                  'object ${git.head}\n'
                  'type commit\n'
                  'tag v0.2.0\n\n'
                  'core 0.2.0\n\n'
                  'release-manifest-sha256: $digest\n',
              stderr: '',
            );
          }
          return null;
        },
      );
      final output = Output(
        sink: buffer.write,
        isTerminal: false,
        useColor: false,
      );

      var code = ExitCodes.refused;
      Object? died;
      try {
        final stageRoot =
            retainedStageRoot ??
            Directory.systemTemp.createTempSync('rk-drive-');
        addTearDown(() {
          if (stageRoot.existsSync()) stageRoot.deleteSync(recursive: true);
        });
        stages = ReleaseStages(
          source: tree,
          git: git,
          resolution: resolution,
          repositoryRoot: stageRoot.path,
          sdk: sdk,
        );
        code = await ReleaseCommand(
          allowInteractiveTools: true,
          stageOnly: stageOnly,
          resolution: resolution,
          tree: tree,
          git: git,
          // The same tools the command gets, which is what `bin/rk.dart`
          // does — release never builds a toolless inspector. Without them
          // the tag step could not reach the `answers:` leg above, so the
          // drive maintained a faithful remote and then inspected a
          // different reality than the one it acted on.
          inspector: Inspector(
            registry: registry,
            pubDev: PubDevTarget(registry: registry),
            git: git,
            tools: tools,
            repository: 'example/keybay',
            stageFor: stages.call,
          ),
          tools: tools,
          output: output,
          confirm: (_) async => 'yes',
          wait: (_) async {},
          capabilities: HostCapabilities(
            hostPlatform: 'linux-x64',
            containerRuntime: null,
          ),
          // A conformance run must not read the pub session of whoever is
          // running it.
          refreshEnvironment: () => const {'HOME': '/nowhere'},
          stageFor: stages.call,
        ).run(only: 'core');
      } on Object catch (error) {
        died = error;
      }
      return (
        code: code,
        text: buffer.toString(),
        calls: tools.calls.map(normalizedPubKey).toList(),
        report:
            jsonDecode(output.report.encode(exit: code))
                as Map<String, Object?>,
        died: died,
      );
    }

    /// Drives to a completed release: pub.dev lists what was published.
    Future<
      ({
        int code,
        String text,
        List<String> calls,
        Map<String, Object?> report,
        Object? died,
      })
    >
    release({
      Map<String, ToolResult> results = const {},
      Map<String, String> sourceFiles = const {},
      String? config,
      DartSdk Function()? sdk,
      PubResolution pub = const PubResolution(),
      void Function(String key, String workingDirectory)? inspect,
    }) {
      final published = {
        'keybay': ['0.1.0'],
      };
      final archives = <String, List<int>>{};
      return drive(
        published: published,
        archives: archives,
        tags: {},
        results: results,
        sourceFiles: sourceFiles,
        config: config,
        sdk: sdk,
        pub: pub,
        inspect: inspect,
        onRun: (key) {
          if (key == 'dart pub publish --from-archive <archive> --force') {
            published['keybay']!.add('0.2.0');
            archives['keybay@0.2.0'] = archiveOfTree();
          }
        },
      );
    }

    test(
      'a tracked pubspec_overrides.yaml stays out of what Pub validates',
      () async {
        // Pub honours a tracked override where it resolves, and leaves it
        // out of the archive. The stage resolves in a mirror where its own
        // pubspec_overrides.yaml replaces every tracked one, so what Pub
        // validates is what consumers get.
        final seen = <String?>[];
        final run = await release(
          sourceFiles: {
            'packages/keybay/pubspec_overrides.yaml':
                'dependency_overrides:\n  transitive:\n    path: ../other\n',
          },
          inspect: (key, directory) {
            if (key != 'dart pub publish --to-archive <archive>') return;
            final file = File('$directory/pubspec_overrides.yaml');
            seen.add(file.existsSync() ? file.readAsStringSync() : null);
          },
        );

        expect(run.code, ExitCodes.ok, reason: run.text);
        expect(seen, [
          '# Written by rk: resolve this package the way its consumers do.\n'
              'dependency_overrides: {}\n',
        ]);
      },
    );

    group('a workspace', () {
      const members = {
        'pubspec.yaml':
            'name: ws\n'
            'publish_to: none\n'
            'environment:\n'
            '  sdk: ^3.11.0\n'
            'workspace:\n'
            '  - packages/*\n',
        'packages/keybay/pubspec.yaml':
            'name: keybay\n'
            'version: 0.2.0\n'
            'resolution: workspace\n'
            'dependencies:\n'
            '  leaf: ^1.0.0\n',
        'packages/host/pubspec.yaml':
            'name: host\n'
            'publish_to: none\n'
            'resolution: workspace\n'
            'dependencies:\n'
            '  pinned: ^1.0.0\n',
      };

      test('stages past overrides that other members and the root declare, '
          'which consumers never get', () async {
        // Pub applies any member's overrides to the whole workspace, so
        // keybay's own tests may run against host's fork of leaf. Consumers
        // get leaf from pub.dev, and so does the resolution Pub validates.
        String? written;
        final run = await release(
          sourceFiles: {
            ...members,
            'pubspec.yaml':
                '${members['pubspec.yaml']}'
                'dependency_overrides:\n'
                '  pinned:\n'
                '    git: https://example.com/pinned.git\n',
            'packages/host/pubspec.yaml':
                '${members['packages/host/pubspec.yaml']}'
                'dependency_overrides:\n'
                '  leaf:\n'
                '    path: ../fork\n',
          },
          inspect: (key, directory) {
            if (key != 'dart pub publish --to-archive <archive>') return;
            written = File(
              '$directory/pubspec_overrides.yaml',
            ).readAsStringSync();
          },
        );

        expect(run.code, ExitCodes.ok, reason: run.text);
        expect(
          written,
          '# Written by rk: resolve this package the way its consumers do.\n'
          'resolution: null\n'
          'workspace: []\n'
          'dependency_overrides: {}\n',
        );
      });

      test(
        'stages a workspace rk cannot read when Pub overrides nothing',
        () async {
          // rk's reading only names declarations; a pubspec it does not read
          // (an anchor, here) no longer refuses a package Pub resolves plainly.
          final run = await release(
            sourceFiles: {
              ...members,
              'packages/host/pubspec.yaml':
                  '${members['packages/host/pubspec.yaml']}'
                  'x: &anchor 1\n',
            },
          );

          expect(run.code, ExitCodes.ok, reason: run.text);
        },
      );

      group('validates keybay as its consumers resolve it', () {
        // keybay depends on base, a sibling another unit publishes, and
        // develops with testkit, a sibling nothing publishes; host is a
        // sibling keybay never reaches.
        final siblings = {
          ...members,
          'packages/keybay/pubspec.yaml':
              'name: keybay\n'
              'version: 0.2.0\n'
              'resolution: workspace\n'
              'dependencies:\n'
              '  base: ^1.0.0\n'
              '  leaf: ^1.0.0\n'
              'dev_dependencies:\n'
              '  testkit: any\n',
          'packages/base/pubspec.yaml':
              'name: base\n'
              'version: 1.0.0\n'
              'resolution: workspace\n'
              'dependencies:\n'
              '  leaf: ^1.0.0\n',
          'packages/testkit/pubspec.yaml':
              'name: testkit\n'
              'publish_to: none\n'
              'resolution: workspace\n'
              'dependencies:\n'
              '  base: ^1.0.0\n',
        };
        test('alone, with only what it develops with from the source', () async {
          final overridesFiles = <String, String?>{};
          String? publishedFrom;
          final run = await release(
            sourceFiles: siblings,
            inspect: (key, directory) {
              final file = File('$directory/pubspec_overrides.yaml');
              if (key == 'dart pub publish --to-archive <archive>') {
                overridesFiles[directory] = file.existsSync()
                    ? file.readAsStringSync()
                    : null;
                publishedFrom = directory;
              }
            },
          );

          expect(run.code, ExitCodes.ok, reason: run.text);
          final [consumer] = overridesFiles.keys.toList();
          expect(
            overridesFiles[consumer],
            '# Written by rk: resolve this package the way its consumers '
            'do.\n'
            'resolution: null\n'
            'workspace: []\n'
            'dependency_overrides:\n'
            '  testkit:\n'
            '    path: "../testkit"\n',
            reason:
                "keybay's consumers take base from pub.dev, where its unit "
                'has published it; nothing publishes testkit, which only '
                'keybay\'s development needs',
          );
          expect(
            publishedFrom,
            consumer,
            reason: 'Pub validates and archives where it resolved keybay',
          );
          expect(
            run.report['attachments'],
            containsPair(
              'pub-package-keybay.txt',
              startsWith(
                'Pub validated keybay the way its consumers resolve it: as a '
                'root of its own, with no lockfile and no dependency override '
                'but testkit from this source',
              ),
            ),
          );
        });

        test('from a mirror of what Pub reads, and nothing else', () async {
          // The mirror grew with the repository: every tracked file, for
          // every package, on every stage.
          late List<String> mirrored;
          final run = await release(
            sourceFiles: {
              ...siblings,
              'README.md': '# The repository\n',
              'analysis_options.yaml': 'linter:\n  rules: []\n',
              'docs/guide.md': '# A guide nothing builds\n',
              'packages/keybay/lib/keybay.dart': 'library;\n',
              'packages/testkit/lib/testkit.dart': 'library;\n',
              'packages/base/lib/base.dart': 'library;\n',
              'packages/host/lib/host.dart': 'library;\n',
            },
            inspect: (key, directory) {
              if (key != 'dart pub publish --to-archive <archive>') return;
              final source = Directory(directory).parent.parent;
              mirrored = [
                for (final entry in source.listSync(recursive: true))
                  if (entry is File &&
                      !entry.path.endsWith('pubspec_overrides.yaml'))
                    entry.path.substring(source.path.length + 1),
              ]..sort();
            },
          );

          expect(run.code, ExitCodes.ok, reason: run.text);
          expect(
            mirrored,
            [
              'README.md',
              'analysis_options.yaml',
              'packages/base/lib/base.dart',
              'packages/base/pubspec.yaml',
              'packages/host/lib/host.dart',
              'packages/host/pubspec.yaml',
              'packages/keybay/CHANGELOG.md',
              'packages/keybay/lib/keybay.dart',
              'packages/keybay/pubspec.yaml',
              'packages/testkit/lib/testkit.dart',
              'packages/testkit/pubspec.yaml',
              'pubspec.yaml',
            ],
            reason:
                'every package, and the files beside the directories above '
                'keybay; the workspace root adds its pubspec, not docs',
          );
        });

        test('without the lockfiles the snapshot tracks', () async {
          // A lockfile holds the versions an earlier resolution picked, and
          // its consumers resolve without it.
          final lockfiles = <List<String>>[];
          final run = await release(
            sourceFiles: {
              ...siblings,
              'pubspec.lock': '# Generated by pub\npackages: {}\n',
              'packages/keybay/pubspec.lock':
                  '# Generated by pub\npackages: {}\n',
            },
            inspect: (key, directory) {
              if (key != 'dart pub publish --to-archive <archive>') return;
              final source = Directory(directory).parent.parent;
              lockfiles.add([
                for (final entry in source.listSync(recursive: true))
                  if (entry.path.endsWith('pubspec.lock')) entry.path,
              ]);
            },
          );

          expect(run.code, ExitCodes.ok, reason: run.text);
          expect(lockfiles, [isEmpty]);
        });

        test('and refuses what Pub cannot resolve that way', () async {
          final run = await release(
            sourceFiles: siblings,
            pub: PubResolution(
              consumerFailure:
                  "Because keybay depends on leaf ^1.0.0 which doesn't match "
                  'any versions, version solving failed.',
            ),
          );

          expect(run.code, ExitCodes.refused);
          expect(
            (run.report['problems'] as List).map((p) => (p as Map)['code']),
            contains('RK-PUB-017'),
          );
          expect(run.text, contains('version solving failed'));
          expect(
            run.calls.where(
              (c) => c.startsWith('dart pub publish --from-archive'),
            ),
            isEmpty,
          );
        });

        test(
          'and refuses an override Pub applies that rk did not write',
          () async {
            final run = await release(
              sourceFiles: siblings,
              pub: PubResolution(consumerAlsoReports: {'leaf'}),
            );

            expect(run.code, ExitCodes.refused);
            expect(
              (run.report['problems'] as List).map((p) => (p as Map)['code']),
              contains('RK-PUB-017'),
            );
            expect(
              run.text,
              contains('Pub applied overrides rk did not write: leaf'),
            );
            expect(
              run.calls.where(
                (c) => c.startsWith('dart pub publish --from-archive'),
              ),
              isEmpty,
            );
          },
        );
      });
    });

    group('a workspace with Flutter packages', () {
      late Directory sdks;
      setUp(() => sdks = Directory.systemTemp.createTempSync('rk-sdks-'));
      tearDown(() => sdks.deleteSync(recursive: true));

      String file(String path) {
        File('${sdks.path}/$path')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('');
        return '${sdks.path}/$path';
      }

      DartSdk Function() dart(String executable) =>
          () => DartSdk(
            executable: executable,
            version: 'Dart SDK version: 3.12.2',
          );

      const workspace = {
        'dart/pubspec.yaml':
            'name: dart_workspace\n'
            'publish_to: none\n'
            'environment:\n'
            '  sdk: ^3.6.0\n'
            'workspace:\n'
            '  - packages/keybay\n'
            '  - packages/app\n',
        'dart/packages/keybay/pubspec.yaml':
            'name: keybay\n'
            'version: 0.2.0\n'
            'resolution: workspace\n',
        'dart/packages/keybay/CHANGELOG.md': '## 0.2.0\n',
        'dart/packages/app/pubspec.yaml':
            'name: app\n'
            'publish_to: none\n'
            'resolution: workspace\n'
            'dependencies:\n'
            '  flutter:\n'
            '    sdk: flutter\n',
      };
      const config = '''
schema = 2

[release.core]
path = "dart/packages/keybay"
publish = ["git-tag", "pub.dev"]
''';

      // keybay itself develops with Flutter here.
      final flutterKeybay = {
        ...workspace,
        'dart/packages/keybay/pubspec.yaml':
            '${workspace['dart/packages/keybay/pubspec.yaml']}'
            'dev_dependencies:\n'
            '  flutter_test:\n'
            '    sdk: flutter\n',
      };

      test('leave a Dart package to a standalone Dart', () async {
        // The stage resolves keybay apart from the workspace, so app's
        // Flutter never reaches it.
        final run = await release(
          config: config,
          sourceFiles: workspace,
          sdk: dart(file('dart-sdk/bin/dart')),
        );

        expect(run.code, ExitCodes.ok, reason: run.text);
      });

      test('are refused by a standalone Dart before Pub runs', () async {
        final run = await release(
          config: config,
          sourceFiles: flutterKeybay,
          sdk: dart(file('dart-sdk/bin/dart')),
        );

        expect(run.code, ExitCodes.refused);
        expect(
          (run.report['problems'] as List).map((p) => (p as Map)['code']),
          contains('RK-PUB-014'),
        );
        expect(run.text, contains('not part of a Flutter SDK'));
        expect(run.calls.where((c) => c.startsWith('dart pub')), isEmpty);
      });

      test("are staged and published with a Flutter SDK's Dart", () async {
        file('flutter/bin/flutter');
        file('flutter/bin/cache/dart-sdk/bin/dart');
        final run = await release(
          config: config,
          sourceFiles: flutterKeybay,
          sdk: dart(file('flutter/bin/dart')),
        );

        expect(run.code, ExitCodes.ok, reason: run.text);
        expect(
          run.calls,
          contains(startsWith('dart pub publish --from-archive ')),
        );
      });
    });

    test('resume half: killed after the tag, a re-run finishes '
        'without re-tagging', () async {
      final retained = Directory.systemTemp.createTempSync('rk-resume-');
      final published = {
        'keybay': ['0.1.0'],
      };
      final archives = <String, List<int>>{};
      final tags = <String>{};

      final first = await drive(
        retainedStageRoot: retained,
        published: published,
        archives: archives,
        tags: tags,
        results: {
          'dart pub publish --from-archive <archive> --force': ToolResult(
            exitCode: 137,
            stdout: '',
            stderr: 'Killed: 9',
          ),
        },
        onRun: (key) {
          if (key.startsWith('git tag')) tags.add('v0.2.0');
        },
      );
      expect(first.code, ExitCodes.refused, reason: first.text);
      expect(tags, contains('v0.2.0'), reason: 'the tag landed before death');

      final second = await drive(
        retainedStageRoot: retained,
        published: published,
        archives: archives,
        tags: tags,
        onRun: (key) {
          if (key == 'dart pub publish --from-archive <archive> --force') {
            published['keybay']!.add('0.2.0');
            archives['keybay@0.2.0'] = archiveOfTree();
          }
        },
      );

      expect(second.code, ExitCodes.ok, reason: second.text);
      expect(
        second.calls.where((c) => c.startsWith('git tag')),
        isEmpty,
        reason: 're-running is the resume: reality says the tag exists',
      );
      expect(
        second.calls.where(
          (c) => c == 'dart pub publish --from-archive <archive> --force',
        ),
        hasLength(1),
      );
      expect(second.text, contains('archive matches the staged package'));
    });

    test('resume half: killed after the publish, a re-run '
        'confirms without publishing twice', () async {
      final retained = Directory.systemTemp.createTempSync('rk-resume-');
      final published = {
        'keybay': ['0.1.0'],
      };
      final archives = <String, List<int>>{};
      final tags = <String>{};
      final staged = await drive(
        retainedStageRoot: retained,
        stageOnly: true,
        published: published,
        archives: archives,
        tags: tags,
      );
      expect(staged.code, ExitCodes.ok, reason: staged.text);
      tags.add('v0.2.0');

      final first = await drive(
        retainedStageRoot: retained,
        published: published,
        archives: archives,
        tags: tags,
        onRun: (key) {
          if (key == 'dart pub publish --from-archive <archive> --force') {
            published['keybay']!.add('0.2.0');
            archives['keybay@0.2.0'] = archiveOfTree();
            throw StateError('killed between the act and the confirmation');
          }
        },
      );
      expect(first.died, isNull, reason: first.text);
      expect(first.code, ExitCodes.ok, reason: first.text);

      final second = await drive(
        retainedStageRoot: retained,
        published: published,
        archives: archives,
        tags: tags,
      );

      expect(second.code, ExitCodes.ok, reason: second.text);
      expect(
        second.calls.where((c) => c.contains('publish --force')),
        isEmpty,
        reason:
            'pub.dev already lists it; publishing again would be the '
            'permanent mistake',
      );
      expect(second.text, contains('already released'));
    });
  });

  test('no shipped document names a flag rk does not accept', () {
    // CHANGELOG.md is not just documentation: `Changelog.entry` reads it,
    // `_releaseNotes` writes it to the workspace, and `GithubRelease` passes
    // it as `--notes-file`. So its text *becomes* the published release body,
    // and it ships in the pub.dev tarball to render on the Changelog tab.
    // Neither can be edited afterwards.
    //
    // It advertised `--rehearse` for a whole branch after that flag started
    // exiting 2 — the one document the cut never touched, and the one where
    // being wrong is permanent.
    final accepted = RegExp('r?\'(--[a-z-]+)')
        .allMatches(File('bin/rk.dart').readAsStringSync())
        .map((m) => m.group(1)!)
        .toSet();
    expect(accepted, contains('--json'), reason: 'the scrape still works');

    // Exactly the documents that describe rk's *current* surface. Widening
    // this to every shipped markdown was tried and is wrong: the archived
    // plan is a history that legitimately records `--rehearse` and `--verbose` as
    // flags that were cut, and both RFCs quote other tools' flags
    // (`gh --generate-notes`, `--paginate`, `--limit`) and flags that were
    // proposed and never built. A gate that fails on those trains people to
    // silence it.
    for (final path in ['CHANGELOG.md', 'README.md', 'doc/json.md']) {
      final file = File(path);
      // "no `--force`" is a promise about what rk deliberately lacks, which
      // is the opposite of advertising it. Everything else is a claim that
      // the flag works.
      final named = RegExp(r'(no )?`(--[a-z-]+)')
          .allMatches(file.readAsStringSync())
          .where((m) => m.group(1) == null)
          .map((m) => m.group(2)!)
          .toSet();
      for (final flag in named) {
        expect(
          accepted,
          contains(flag),
          reason: '$path names $flag, which rk refuses with RK-CLI-005',
        );
      }
    }
  });

  group('rk init', () {
    late Directory scratch;

    setUpAll(() => scratch = Directory.systemTemp.createTempSync('rk-init-'));
    tearDownAll(() => scratch.deleteSync(recursive: true));

    test(
      'scans, classifies, proposes — and writes nothing without a human',
      () {
        final repo = Rk.example(
          scratch,
          'workspace-with-dependent',
          as: 'scan',
        );
        File('${repo.root}/release.toml').deleteSync();
        repo.commit(); // the scan reads tracked files, and rightly so
        final run = repo(['init']);

        expect(run.code, 0, reason: run.all);
        expect(run.all, contains('2 selected units'));
        expect(
          run.all,
          contains('example_workspace: workspace root — select its packages'),
        );
        expect(run.all, contains('publish = ["pub.dev"]'));
        expect(
          run.all,
          contains('nothing was written — there is no terminal to confirm in'),
        );
        expect(
          File('${repo.root}/release.toml').existsSync(),
          isFalse,
          reason: 'proposing is not writing',
        );
      },
    );

    test('the proposal round-trips through the machine surface '
        'into a releasable repository', () {
      // The dogfood loop, entirely through the CLI: init emits the proposal
      // as data, the caller writes it, and rk itself must then accept it —
      // a written config rk refuses would be rk debugging its own output.
      final repo = Rk.example(scratch, 'multi-project-unit', as: 'loop');
      File('${repo.root}/release.toml').deleteSync();
      repo.commit();

      final proposal = repo(['init', '--json']);
      expect(proposal.code, 0, reason: proposal.all);
      final config =
          ((proposal.json['attachments'] as Map?) ?? const {})['release.toml']
              as String?;
      expect(
        config,
        isNotNull,
        reason:
            'an agent reads the proposal from the document; a human '
            'writes it at a terminal',
      );

      File('${repo.root}/release.toml').writeAsStringSync(config!);
      final status = repo(['status', '--json']);
      expect(
        status.units,
        hasLength(3),
        reason: 'what init proposed, status derives and releases',
      );
      expect(
        status.problems.map((problem) => problem['code']),
        isNot(anyElement(startsWith('RK-CONF'))),
        reason:
            'a written config rk refuses would be rk debugging its own '
            'output',
      );
    });
  });

  // Shared by the binary chain and destination groups: one scratch, one
  // command-layer drive.
  late Directory scratch;
  setUpAll(
    () => scratch = Directory.systemTemp.createTempSync('rk-binary-drive-'),
  );
  tearDownAll(() => scratch.deleteSync(recursive: true));

  /// Drives a full binary-unit release at the command layer, with tools
  /// scripted by prefix and the compiler's output written where the
  /// workspace says. The world moves the way the real one would: the tag
  /// set grows on push, the forge lists the release after the create with
  /// exactly the assets the create named, and the tap read-back answers
  /// with the bytes the push put there.
  Future<
    ({
      int code,
      String text,
      List<String> calls,
      Map<String, Object?> json,
      String? notes,
      Set<String> expected,
    })
  >
  binaryDrive({
    required bool stageOnly,
    Set<String> remoteTags = const {},
    bool notaryRejects = false,
    bool notaryProfileRejects = false,
    List<String> platforms = const ['macos-arm64'],
    bool homebrew = false,
    String label = '',
    String? containerRuntime = 'docker',
    int certificates = 1,
    List<String>? certTeams,
    bool keychainReadable = true,
    String? previousTag,
    bool publishedNamesTeam = true,
    bool publishStaged = false,
    bool baselineChangesBeforeConsent = false,
  }) async {
    final root = Directory(
      '${scratch.path}/drive-${stageOnly ? 'd' : 'f'}'
      '${notaryRejects ? '-nr' : ''}'
      '${notaryProfileRejects ? '-np' : ''}$label',
    )..createSync(recursive: true);
    final buffer = StringBuffer();
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse(
      '''
schema = 2

[release.cli]
path = "packages/tool"
publish = ["git-tag", "github-release"${homebrew ? ', "homebrew"' : ''}]
binary_platforms = [${platforms.map((p) => '"$p"').join(', ')}]
''',
      'release.toml',
      diagnostics,
    )!;
    final tree = MemorySourceTree({
      'packages/tool/pubspec.yaml': '''
name: tool
version: 1.0.0
publish_to: none
executables:
  tool: tool
''',
      'packages/tool/CHANGELOG.md': '## 1.0.0\n\nFirst release.\n',
    }, description: '$root/tool');
    final resolution = Resolution.resolve(config, tree, diagnostics)!;
    final git = GitState(
      root: root.path,
      head: '1111111111111111111111111111111111111111',
      branch: 'main',
      isClean: true,
      uncommitted: const [],
      headIsPushed: true,
      // An earlier tag is what makes this a *later* release: the signing
      // baseline is read from the release published at it.
      tags: [if (previousTag != null) previousTag],
      // Stated, like the fixtures in status_test and release_test: an unread
      // target is not "at HEAD". Inert while previousTag is never the unit's
      // own tag, and the collapse comes back the moment that changes.
      tagTargets: {
        if (previousTag != null)
          previousTag: '1111111111111111111111111111111111111111',
      },
      signingConfigured: true,
      originUrl: 'example/tool',
    );
    final stageCache = <String, ReleaseStage>{};
    ReleaseStage stageFor(ResolvedUnit unit) =>
        stageCache.putIfAbsent(unit.name, () {
          final plan = <String, Object?>{
            'unit': unit.name,
            'version': unit.version.canonical,
            'fixture': label,
          };
          final directory = StageDirectory(
            repositoryRoot: root.path,
            identity: StageIdentity.forPlan(
              headCommit: git.head,
              headTree: '2222222222222222222222222222222222222222',
              resolvedPlan: plan,
            ),
          );
          return ReleaseStage(
            unit: unit,
            source: tree,
            // The scripted tools answer `dart compile`, not this machine's
            // SDK.
            sdk: () =>
                DartSdk(executable: fixtureDartSdk(root), version: 'fixture'),
            repository: git.originUrl,
            directory: directory,
            release: UnitRelease.derive(
              unit,
              resolution,
              repository: git.originUrl,
              problems: Diagnostics(),
            ),
            resolvedPlan: plan,
          );
        });
    const releaseTagObject = '4444444444444444444444444444444444444444';
    final pushed = <String>{...remoteTags};
    final uploaded = <String>{};
    var draftCreated = false;
    var released = false;
    String? notesAtCreate;
    List<int>? publishedFormula;
    var publishedIdentityReads = 0;
    File stagedPublicAsset(String name) {
      final stage = stageFor(resolution.unit('cli')!);
      final artifact = name == ReleaseAssets.manifest
          ? stage.requireReceipt().artifacts.singleWhere(
              (item) => item.path == ReleaseAssets.manifest,
            )
          : stage.releaseAssets()[name]!;
      return File(stage.directory.resolve(artifact.path));
    }

    List<Map<String, Object?>> uploadedAssets() => [
      for (final (index, name) in uploaded.indexed)
        {
          'id': 100 + index,
          'name': name,
          'state': 'uploaded',
          'size': stagedPublicAsset(name).lengthSync(),
          'digest':
              'sha256:'
              '${Sha256.hex(stagedPublicAsset(name).readAsBytesSync())}',
        },
    ];
    final signingTeams =
        certTeams ??
        [for (var i = 0; i < certificates; i++) 'TEAM12345${i + 6}'];
    String certificateSha1(int index) => '${index + 1}' * 40;
    String certificateSha256(int index) =>
        String.fromCharCode('a'.codeUnitAt(0) + index) * 64;
    final tools = BundleRecordingTools(
      probe: (key, workingDirectory) {
        if (key == 'git push' && workingDirectory != null) {
          final formula = File('$workingDirectory/Formula/tool.rb');
          if (formula.existsSync()) {
            publishedFormula = formula.readAsBytesSync();
          }
        }
      },
      onRun: (key) {
        if (key.startsWith('gh release download ') &&
            key.contains('--pattern tool-0.9.0-macos-arm64.tar.gz')) {
          final into = key.split(' --dir ').last.split(' ').first;
          File('$into/tool-0.9.0-macos-arm64.tar.gz')
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync(
              ArchiveBuilder.gzip(
                ArchiveBuilder.tar([
                  ArchiveEntry(
                    name: 'tool',
                    bytes: [1, 2, 3],
                    executable: true,
                  ),
                ]),
              ),
            );
        }
        if (key.startsWith('git push origin ')) {
          final refspec = key.substring('git push origin '.length);
          const marker = ':refs/tags/';
          if (refspec.contains(marker)) {
            pushed.add(refspec.split(marker).last);
          }
        }
        if (key.contains(' -X POST repos/example/tool/releases --input ')) {
          final input = key.split(' --input ').last;
          final body =
              jsonDecode(File(input).readAsStringSync())
                  as Map<String, Object?>;
          draftCreated = true;
          notesAtCreate = body['body'] as String?;
        }
        if (key.contains('uploads.github.com')) {
          uploaded.add(
            Uri.decodeQueryComponent(key.split('assets?name=').last),
          );
        }
        if (key.contains(' -X PATCH repos/example/tool/releases/7 ')) {
          released = true;
        }
        if (key.startsWith('gh release download v1.0.0 ')) {
          final words = key.split(' ');
          final name = words[words.indexOf('--pattern') + 1];
          final destination = words[words.indexOf('--output') + 1];
          File(destination)
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync(stagedPublicAsset(name).readAsBytesSync());
        }
        if (key.startsWith('dart compile')) {
          final out = key.split(' -o ').last.split(' ').first;
          File(out)
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync('BINARY 1.0.0'.codeUnits);
          setFileModes({out: '0755'});
        }
        if (key.startsWith('ditto')) {
          final zip = key.split(' ').last;
          File(zip)
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync('ZIP'.codeUnits);
        }
        if (key.startsWith('git clone') && key.contains('homebrew-tap')) {
          Directory(key.split(' ').last).createSync(recursive: true);
        }
      },
      answers: (key) {
        if (key == 'git rev-parse --verify refs/tags/v1.0.0^{tag}') {
          return ToolResult(
            exitCode: 0,
            stdout: '$releaseTagObject\n',
            stderr: '',
          );
        }
        if (key == 'git ls-remote --tags origin') {
          return ToolResult(
            exitCode: 0,
            stdout: [
              for (final tag in pushed) ...[
                '$releaseTagObject refs/tags/$tag',
                '${git.head} refs/tags/$tag^{}',
              ],
            ].join('\n'),
            stderr: '',
          );
        }
        if (key.startsWith('git ls-remote origin refs/tags/')) {
          final tag = key
              .substring('git ls-remote origin refs/tags/'.length)
              .split(' ')
              .first;
          return ToolResult(
            exitCode: 0,
            stdout: pushed.contains(tag)
                ? '$releaseTagObject refs/tags/$tag\n'
                      '${git.head} refs/tags/$tag^{}'
                : '',
            stderr: '',
          );
        }
        if (key == 'git cat-file tag $releaseTagObject') {
          final manifest = stagedPublicAsset(ReleaseAssets.manifest);
          final digest = Sha256.hex(manifest.readAsBytesSync());
          return ToolResult(
            exitCode: 0,
            stdout:
                'object ${git.head}\n'
                'type commit\n'
                'tag v1.0.0\n\n'
                'cli 1.0.0\n\n'
                'release-manifest-sha256: $digest\n',
            stderr: '',
          );
        }
        if (key.startsWith('codesign --test-requirement')) {
          return ToolResult(exitCode: 1, stdout: '', stderr: 'no');
        }
        if (key.startsWith('codesign -d -r-') &&
            key.contains('published-identity')) {
          publishedIdentityReads++;
          if (!publishedNamesTeam) {
            // A published requirement rk cannot read a team out of. Only the
            // published read loses its OU — the freshly-signed binary keeps
            // one, so this models an unreadable baseline rather than a
            // codesign that has stopped working.
            return ToolResult(
              exitCode: 0,
              stdout: 'designated => identifier "io.github.example.tool"',
              stderr: '',
            );
          }
          if (baselineChangesBeforeConsent && publishedIdentityReads > 1) {
            return ToolResult(
              exitCode: 0,
              stdout:
                  'designated => identifier "io.github.example.tool" '
                  'and certificate leaf[subject.OU] = "TEAM654321"',
              stderr: '',
            );
          }
        }
        if (key.startsWith('codesign -d -r-')) {
          // A real designated requirement, carrying the identifier and the
          // team OU that signing continuity is derived from. The version
          // that read `designated => leaf "A"` carried neither, so any
          // drive with a published baseline refused at RK-SIGN-001 — which
          // is why no drive had ever modelled a later release.
          return ToolResult(
            exitCode: 0,
            stdout:
                'designated => identifier "io.github.example.tool" and '
                'certificate leaf[subject.OU] = "TEAM123456"',
            stderr: '',
          );
        }
        if (key.startsWith('security find-identity')) {
          // A non-zero exit is an unreadable keychain, which is not the
          // same fact as one holding no certificate.
          if (!keychainReadable) {
            return ToolResult(
              exitCode: 1,
              stdout: '',
              stderr: 'security: failed to open the login keychain',
            );
          }
          // Teams are scriptable so a keychain can hold a certificate that
          // is not the one the published release names — the likeliest
          // signing failure of all, and the one the preflight learned last.
          return ToolResult(
            exitCode: 0,
            stdout: [
              for (var i = 0; i < signingTeams.length; i++)
                '${i + 1}) ${certificateSha1(i)} '
                    '"Developer ID Application: D (${signingTeams[i]})"',
            ].join('\n'),
            stderr: '',
          );
        }
        if (key.startsWith('security find-certificate')) {
          final index = signingTeams.indexWhere(key.contains);
          if (index < 0) {
            return ToolResult(
              exitCode: 1,
              stdout: '',
              stderr: 'certificate not found',
            );
          }
          return ToolResult(
            exitCode: 0,
            stdout:
                'SHA-256 hash: ${certificateSha256(index)}\n'
                'SHA-1 hash: ${certificateSha1(index)}\n',
            stderr: '',
          );
        }
        if (key.startsWith('xcrun notarytool history')) {
          return notaryProfileRejects
              ? ToolResult(
                  exitCode: 1,
                  stdout: '',
                  stderr:
                      'No Keychain password item found for profile: '
                      'rk-notary',
                )
              : ToolResult(exitCode: 0, stdout: '{"history": []}', stderr: '');
        }
        if (key.startsWith('xcrun notarytool submit')) {
          return notaryRejects
              ? ToolResult(
                  exitCode: 0,
                  stdout: '{"id": "s-1", "status": "Invalid"}',
                  stderr: '',
                )
              : ToolResult(
                  exitCode: 0,
                  stdout: '{"id": "s-1", "status": "Accepted"}',
                  stderr: '',
                );
        }
        if (key.startsWith('xcrun notarytool log')) {
          return ToolResult(
            exitCode: 0,
            stdout: '{"status": "Accepted", "issues": []}',
            stderr: '',
          );
        }
        if (key.contains('--version')) {
          return ToolResult(exitCode: 0, stdout: '1.0.0', stderr: '');
        }
        if (key == 'gh api --paginate --slurp repos/example/tool/releases') {
          return ToolResult(
            exitCode: 0,
            stdout: jsonEncode([
              [
                if (previousTag != null)
                  {
                    'tag_name': previousTag,
                    'draft': false,
                    'prerelease': false,
                    'id': 6,
                  },
                if (draftCreated)
                  {
                    'tag_name': 'v1.0.0',
                    'draft': !released,
                    'prerelease': false,
                    'id': 7,
                  },
              ],
            ]),
            stderr: '',
          );
        }
        if (key.contains(' -X POST repos/example/tool/releases --input ')) {
          return ToolResult(
            exitCode: 0,
            stdout: jsonEncode({'id': 7}),
            stderr: '',
          );
        }
        if (key.contains('uploads.github.com')) {
          return ToolResult(exitCode: 0, stdout: '', stderr: '');
        }
        if (key == 'gh api repos/example/tool/releases/7') {
          return ToolResult(
            exitCode: draftCreated ? 0 : 1,
            stdout: draftCreated
                ? jsonEncode({
                    'tag_name': 'v1.0.0',
                    'draft': !released,
                    'prerelease': false,
                    'id': 7,
                    'name': 'cli 1.0.0',
                    'body': notesAtCreate,
                    'assets': uploadedAssets(),
                  })
                : '',
            stderr: draftCreated ? '' : 'gh: Not Found (HTTP 404)',
          );
        }
        if (key.contains(' -X PATCH repos/example/tool/releases/7 ')) {
          return ToolResult(exitCode: 0, stdout: '', stderr: '');
        }
        if (previousTag != null) {
          // The release the identity baseline is read from: its asset list,
          // then the exact named download. Extraction and `codesign -d -r-`
          // fall through to the defaults above, which is where the
          // requirement comes from.
          if (key == 'gh api repos/example/tool/releases/tags/$previousTag') {
            return ToolResult(
              exitCode: 0,
              stdout: jsonEncode({
                'tag_name': previousTag,
                'draft': false,
                'prerelease': false,
                'id': 6,
                'assets': [
                  {'name': 'tool-0.9.0-macos-arm64.tar.gz'},
                ],
              }),
              stderr: '',
            );
          }
        }
        if (key == 'gh api repos/example/tool/releases/tags/v1.0.0') {
          // The forge answers from the world: 404 before the create, the
          // finished release — with exactly the created assets — after.
          return released
              ? ToolResult(
                  exitCode: 0,
                  stdout: jsonEncode({
                    'tag_name': 'v1.0.0',
                    'name': 'cli 1.0.0',
                    'body': notesAtCreate,
                    'draft': false,
                    'prerelease': false,
                    'id': 7,
                    'assets': uploadedAssets(),
                  }),
                  stderr: '',
                )
              : ToolResult(
                  exitCode: 1,
                  stdout: '',
                  stderr: 'gh: Not Found (HTTP 404)',
                );
        }
        if (key.startsWith(
          'gh api repos/example/homebrew-tap/contents/Formula/tool.rb',
        )) {
          // The public tap answers with what the push actually put there.
          return publishedFormula != null
              ? ToolResult(
                  exitCode: 0,
                  stdout: jsonEncode({
                    'content': base64Encode(publishedFormula!),
                  }),
                  stderr: '',
                )
              : ToolResult(
                  exitCode: 1,
                  stdout: '',
                  stderr: 'gh: Not Found (HTTP 404)',
                );
        }
        if (key.startsWith('gh repo view')) {
          return ToolResult(exitCode: 0, stdout: '{"name":"tool"}', stderr: '');
        }
        return null;
      },
    );

    final registry = FakeRegistry({});
    Future<({int code, Output output})> execute(bool stageOnly) async {
      final output = Output(
        sink: buffer.write,
        isTerminal: false,
        useColor: false,
      );
      final code = await ReleaseCommand(
        allowInteractiveTools: true,
        resolution: resolution,
        tree: tree,
        git: git,
        inspector: Inspector(
          registry: registry,
          pubDev: PubDevTarget(registry: registry),
          git: git,
          tools: tools,
          repository: 'example/tool',
          stageFor: stageFor,
        ),
        tools: tools,
        output: output,
        confirm: (_) async => 'yes',
        stageOnly: stageOnly,
        stageFor: stageFor,
        wait: (_) => Future<void>.delayed(Duration.zero),
        // A conformance run must not read the pub session of whoever is
        // running it.
        refreshEnvironment: () => const {'HOME': '/nowhere'},
        capabilities: HostCapabilities(
          hostPlatform: 'macos-arm64',
          containerRuntime: containerRuntime,
        ),
      ).run(only: 'cli');
      return (code: code, output: output);
    }

    var execution = await execute(stageOnly);
    if (publishStaged && execution.code == ExitCodes.ok) {
      if (!stageOnly) {
        fail('publishStaged requires an initial stage-only run');
      }
      execution = await execute(false);
    }
    final code = execution.code;
    final output = execution.output;
    return (
      code: code,
      text: buffer.toString(),
      calls: tools.calls,
      json:
          jsonDecode(output.report.encode(exit: code)) as Map<String, Object?>,
      notes: notesAtCreate,
      expected: ReleaseAssets.expectedForUnit(resolution.unit('cli')!),
    );
  }

  group('the binary chain', () {
    test(
      'the notarization profile is verified before any build starts',
      () async {
        final run = await binaryDrive(
          stageOnly: true,
          notaryProfileRejects: true,
          label: '-notary-preflight',
        );

        expect(run.code, ExitCodes.refused, reason: run.text);
        expect(
          ((run.json['problems'] as List).cast<Map>()).map(
            (problem) => problem['code'],
          ),
          contains('RK-NOTARY-004'),
        );
        expect(
          run.calls.where((call) => call.startsWith('dart compile')),
          isEmpty,
        );
        expect(
          run.calls.where((call) => call.startsWith('xcrun notarytool submit')),
          isEmpty,
        );
        expect((run.json['halt'] as Map?)?['kind'], 'beforeActing');
      },
    );

    test('a chain failure halts with its sentence — partway, not "nothing '
        'changed" and not "lost sight"', () async {
      // A failure in the chain ends with a halt, both as a sentence for a
      // person and as the `halt` key for a caller. A rejected notarization
      // is the everyday one.
      final run = await binaryDrive(
        stageOnly: false,
        notaryRejects: true,
        label: '-notary-failure-boundary',
      );

      expect(run.code, ExitCodes.refused, reason: run.text);
      expect(run.text, contains('rk stopped partway.'));
      expect(
        (run.json['halt'] as Map?)?['kind'],
        'stoppedPartway',
        reason: 'the sentence is data too',
      );
      expect(
        run.json['rerun_helps'],
        isTrue,
        reason:
            'a rejected submission is fixed and re-run; nothing here is '
            'terminal',
      );
      expect(
        run.text,
        contains('notarization did not complete'),
        reason: 'the problem itself is still named beside the sentence',
      );
      expect(
        run.calls.where(
          (call) =>
              call.startsWith('git push origin') ||
              call.contains(' -X POST repos/example/tool/releases --input '),
        ),
        isEmpty,
        reason: 'the complete private stage precedes every public act',
      );
    });

    test(
      'stage spans every platform and still touches nothing public',
      () async {
        final run = await binaryDrive(
          stageOnly: true,
          platforms: ['macos-arm64', 'linux-x64', 'linux-arm64'],
          homebrew: true,
          label: '-3pr',
        );
        expect(run.code, 0, reason: run.text);
        expect(run.calls.where((c) => c.startsWith('dart compile')).length, 3);
        for (final local in [
          'codesign --force',
          'ditto',
          'xcrun notarytool submit',
        ]) {
          expect(
            run.calls.any((c) => c.startsWith(local)),
            isTrue,
            reason:
                '$local ran for real — staging exists so an expired '
                'certificate is found on a quiet afternoon',
          );
        }
        for (final public in [
          'git tag',
          'git push',
          'gh api -X POST repos/example/tool/releases --input',
          'git clone', // the tap
        ]) {
          expect(
            run.calls.any((c) => c.startsWith(public)),
            isFalse,
            reason: '$public is public and staging never touches it',
          );
        }
        expect(run.text, contains('1.0.0 · staged'));
      },
    );

    test('a platform nothing can run still ships — built, not executed, and '
        'disclosed before the release is authorized', () async {
      // Optional evidence degrades honestly. A container runtime that is not
      // running must not block shipping: the smoke test does not earn that
      // weight.
      final run = await binaryDrive(
        stageOnly: false,
        platforms: ['macos-arm64', 'linux-x64'],
        label: '-unproven',
        containerRuntime: null,
      );

      expect(run.code, 0, reason: run.text);
      expect(
        run.calls.any((c) => c.startsWith('docker run')),
        isFalse,
        reason: 'nothing here could run it, so nothing pretended to',
      );
      final disclosed =
          (run.json['attachments'] as Map?)?['authorization-disclosures/cli']
              as String?;
      expect(
        disclosed,
        contains('built but never executed'),
        reason:
            'the durable record travels with the yes that accepted the '
            'weaker assurance',
      );
      expect(disclosed, contains('linux-x64'));
      expect(
        disclosed,
        isNot(contains('macos-arm64 — no container runtime')),
        reason:
            'the host runs its own binaries for free; only the '
            'cross-compiled target is unproven',
      );
      expect(run.text, contains('Warnings'));
      expect(run.text, contains('linux-x64 was built but not executed'));
      expect(
        (run.json['warnings'] as List).map(
          (warning) => (warning as Map)['code'],
        ),
        contains('RK-BUILD-002'),
      );
      expect(run.text, contains('released'));
    });
  });

  /// The destinations, driven through the same command-layer world as the
  /// chain: the release carries the full asset shape, the body is the
  /// changelog entry, and the tap moves only after the release is public.
  ///
  /// The producer and inspector consume one derived GitHub inventory
  /// (`engine/assets.dart`), while the formula is bound to its tap through
  /// the manifest; the drive proves both destinations and the
  /// changelog-derived body through the command layer.
  group('binary destinations', () {
    test(
      'drive half: what the release publishes is exactly what '
      'the inspector will expect, and the body is the changelog entry',
      () async {
        final run = await binaryDrive(
          stageOnly: false,
          platforms: ['macos-arm64', 'linux-x64', 'linux-arm64'],
          homebrew: true,
          label: '-3p',
        );
        expect(run.code, 0, reason: run.text);
        expect(
          run.calls,
          isNot(contains('dart pub login')),
          reason: 'a unit with no pub.dev target has no pub session to acquire',
        );

        // Three builds, two of them cross-compiled for linux.
        expect(run.calls.where((c) => c.startsWith('dart compile')).length, 3);
        expect(
          run.calls
              .where(
                (c) =>
                    c.startsWith('dart compile') &&
                    c.contains('--target-os=linux'),
              )
              .length,
          2,
        );

        // Set equality against the derivation, not against a literal list.
        // A literal would pin the producer to a spelling; this pins it to the
        // inspector, which is the party it has to agree with. Both sides move
        // together or this fails.
        final uploaded = run.calls
            .where((call) => call.contains('uploads.github.com'))
            .map(
              (call) =>
                  Uri.decodeQueryComponent(call.split('assets?name=').last),
            )
            .toSet();

        expect(
          uploaded,
          equals(run.expected),
          reason:
              'the release publishes exactly the set ReleaseAssets.'
              'expectedForUnit derives — any difference is a conflict verdict '
              'on the next run, and a published release cannot be edited',
        );
        expect(
          run.expected,
          isNot(contains('tool.rb')),
          reason:
              'the formula belongs only in its tap; the release manifest '
              'binds its destination and digest',
        );
        expect(
          ((run.json['units'] as List)
              .cast<Map<String, Object?>>()
              .expand((unit) => (unit['steps'] as List).cast<Map>())
              .map((step) => step['summary'])),
          contains('publish 4 assets to the v1.0.0 release'),
          reason: run.text,
        );

        // The body is the changelog entry — one source of release prose.
        expect(
          run.notes,
          'First release.',
          reason:
              'the release body must be the CHANGELOG entry, not a '
              'commit-log digest',
        );

        // The formula moves only after the release is public, and what the
        // public tap serves is read back and proven.
        final publishAt = run.calls.indexWhere(
          (c) => c.contains(' -X PATCH repos/example/tool/releases/7 '),
        );
        final tapCloneAt = run.calls.indexWhere(
          (c) => c.startsWith('git clone') && c.contains('homebrew-tap'),
        );
        expect(
          tapCloneAt,
          greaterThan(publishAt),
          reason:
              'a formula pointing at an unpublished release would brew '
              'a 404',
        );
        expect(
          run.calls.any(
            (call) =>
                call.startsWith('gh api repos/example/homebrew-tap/contents/'),
          ),
          isTrue,
          reason: 'the formula is proven from the public tap after its push',
        );
        expect(run.text, contains('released'));
      },
    );

    // This unit publishes to no registry, so nothing in it is permanent by
    // `Step.isPermanent`. That is exactly the shape the old gating was
    // silent on: it required `permanent.isNotEmpty`, which is "a pub.dev
    // publish remains" — a fact about pub.dev, not about signing.
    test(
      'a genuine first signing names the certificate before the yes',
      () async {
        final run = await binaryDrive(stageOnly: false, label: '-first');

        expect(run.code, 0, reason: run.text);
        expect(
          run.text,
          contains('first claim'),
          reason:
              'the identity about to become permanent is disclosed at the '
              'prompt, and this unit has nothing permanent in the pub.dev '
              'sense — which is what used to silence it',
        );
        // Anchored to the disclosure sentence, contiguously. Matching the two
        // strings separately over the whole buffer was satisfied by the sign
        // step's own note, which prints the identifier *after* consent — the
        // one place it is too late to matter.
        expect(
          run.text,
          contains('tool signed by D (TEAM123456)'),
          reason:
              'the identifier is what becomes permanent, and it is on its '
              'own line beside who signed it, so a wrong one is seen rather '
              'than hunted for',
        );
        expect(
          (run.json['attachments'] as Map?)?['authorization-disclosures/cli'],
          contains('Developer ID Application: D (TEAM123456)'),
          reason:
              'the row names the certificate; the record keeps its full '
              'form, which is what an unattended --yes consents to',
        );
      },
    );

    test('a later release does not claim to be a first one', () async {
      // The common false positive, and rk's own shape: one certificate
      // installed, a release already published. The old gate asked
      // `permanent.isNotEmpty && certificates.length == 1` — neither of
      // which is first-ness — so rk downloaded the published archive, read
      // its identity, and then told the operator that identity did not
      // exist yet.
      final run = await binaryDrive(
        stageOnly: false,
        label: '-later',
        previousTag: 'v0.9.0',
      );

      expect(run.code, 0, reason: run.text);
      expect(
        run.calls.any((c) => c.startsWith('codesign -d -r-')),
        isTrue,
        reason: 'the baseline was read, so there is a published identity',
      );
      expect(
        run.text,
        isNot(contains('first claim')),
        reason: 'there is an identity to reproduce, and it was just read',
      );
    });

    test(
      'reusing a later signed stage does not turn it into a first claim',
      () async {
        final run = await binaryDrive(
          stageOnly: true,
          publishStaged: true,
          label: '-later-stage-reuse',
          previousTag: 'v0.9.0',
        );

        expect(run.code, 0, reason: run.text);
        expect(
          run.calls.where((call) => call.startsWith('codesign --force')),
          hasLength(3),
          reason: 'the release invocation reuses the staged signed bytes',
        );
        expect(
          run.text,
          isNot(contains('first claim')),
          reason:
              'first-identity is receipt data, not inferred from the mere '
              'presence of a signing certificate',
        );
      },
    );

    group('the keychain is read before anything acts, not midway', () {
      test('an unreadable keychain is not an absent certificate', () async {
        final run = await binaryDrive(
          stageOnly: false,
          label: '-nokc',
          keychainReadable: false,
        );

        expect(run.code, ExitCodes.refused, reason: run.text);
        expect(problemCodes(run.json), contains('RK-SIGN-006'));
        expect(
          run.text,
          isNot(contains('no Developer ID Application certificate')),
          reason:
              'telling an operator to install a certificate is wrong '
              'advice when rk never managed to look',
        );
        expect((run.json['halt']! as Map)['kind'], 'beforeActing');
        expect(
          run.calls.any((c) => c.startsWith('git push origin')),
          isFalse,
          reason: 'the whole point is refusing before the tag is public',
        );
      });

      test('no certificate refuses before the tag, not after', () async {
        final run = await binaryDrive(
          stageOnly: false,
          label: '-nocert',
          certificates: 0,
        );

        expect(run.code, ExitCodes.refused, reason: run.text);
        expect(problemCodes(run.json), contains('RK-SIGN-007'));
        expect((run.json['halt']! as Map)['kind'], 'beforeActing');
        expect(run.calls.any((c) => c.startsWith('git push origin')), isFalse);
      });

      test(
        'a published release naming no readable team refuses before acting',
        () async {
          // The sign step refuses this as RK-SIGN-001 — after the tag is
          // public. The requirement is in hand during preflight, and the
          // answer does not change by waiting.
          final run = await binaryDrive(
            stageOnly: false,
            label: '-noteam',
            previousTag: 'v0.9.0',
            publishedNamesTeam: false,
          );

          expect(run.code, ExitCodes.refused, reason: run.text);
          expect(problemCodes(run.json), contains('RK-SIGN-001'));
          expect((run.json['halt']! as Map)['kind'], 'beforeActing');
          expect(
            run.calls.any((c) => c.startsWith('git push origin')),
            isFalse,
          );
        },
      );

      test('staging shows the names the release will claim', () async {
        // Staging is where they can be read before they become
        // unreclaimable, rather than first at the release's prompt.
        final run = await binaryDrive(stageOnly: true, label: '-stageclaim');

        expect(run.code, ExitCodes.ok, reason: run.text);
        expect(run.text, contains('First release · permanent once published'));
        expect(
          run.text,
          matches(RegExp(r'macOS code identifier\s+tool')),
          reason: 'each name on its own row, beside its label',
        );
        expect(run.text, matches(RegExp(r'Apple team\s+D \(TEAM123456\)')));
      });

      test(
        'a certificate for the wrong team refuses before the publish',
        () async {
          // The likeliest signing failure there is: the preflight chooses
          // the certificate, and refuses before any work when none is for
          // the team users installed.
          final run = await binaryDrive(
            stageOnly: false,
            label: '-wrongteam',
            previousTag: 'v0.9.0',
            certTeams: ['TEAMZZZZZZ'],
          );

          expect(run.code, ExitCodes.refused, reason: run.text);
          expect(problemCodes(run.json), contains('RK-SIGN-010'));
          expect(
            run.text,
            contains('TEAM123456'),
            reason: 'the team users installed',
          );
          expect(run.text, contains('TEAMZZZZZZ'), reason: 'and the one here');
          expect((run.json['halt']! as Map)['kind'], 'beforeActing');
          expect(
            run.calls.any((c) => c.startsWith('git push origin')),
            isFalse,
          );
        },
      );

      test('several certificates for the published team refuses too', () async {
        final run = await binaryDrive(
          stageOnly: false,
          label: '-dupeteam',
          previousTag: 'v0.9.0',
          certTeams: ['TEAM123456', 'TEAM123456'],
        );

        expect(run.code, ExitCodes.refused, reason: run.text);
        expect(problemCodes(run.json), contains('RK-SIGN-011'));
        expect((run.json['halt']! as Map)['kind'], 'beforeActing');
        expect(run.calls.any((c) => c.startsWith('git push origin')), isFalse);
      });

      test('an ambiguous first signing refuses, naming the teams', () async {
        final run = await binaryDrive(
          stageOnly: false,
          label: '-twocerts',
          certificates: 2,
        );

        expect(run.code, ExitCodes.refused, reason: run.text);
        expect(problemCodes(run.json), contains('RK-SIGN-008'));
        expect(run.text, contains('TEAM123456'));
        expect(run.text, contains('TEAM123457'));
        expect((run.json['halt']! as Map)['kind'], 'beforeActing');
        expect(run.calls.any((c) => c.startsWith('git push origin')), isFalse);
      });
    });
  });
}

String _shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

/// Every read rk makes over HTTPS (pub.dev, and git and gh against GitHub)
/// goes to a closed loopback port, so it fails at once and the same way on
/// any machine, network or not.
const _offline = {
  'https_proxy': 'http://127.0.0.1:9',
  'HTTPS_PROXY': 'http://127.0.0.1:9',
  'no_proxy': '',
  'NO_PROXY': '',
};
