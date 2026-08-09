import 'dart:io';

import 'dart:convert';

import 'package:release_kit/src/builds/capability.dart';
import 'package:release_kit/src/commands/release.dart';
import 'package:release_kit/src/destinations/pub_dev.dart';
import 'package:release_kit/src/engine/compare.dart';
import 'package:release_kit/src/engine/config.dart';
import 'package:release_kit/src/engine/diagnostic.dart';
import 'package:release_kit/src/engine/git.dart';
import 'package:release_kit/src/engine/inspect.dart';
import 'package:release_kit/src/output/output.dart';
import 'package:release_kit/src/engine/resolve.dart';
import 'package:release_kit/src/engine/release_stage.dart';
import 'package:release_kit/src/engine/source_tree.dart';
import 'package:release_kit/src/engine/stage.dart';
import 'package:release_kit/src/engine/tools.dart';
import 'package:release_kit/src/transforms/archive.dart';
import 'package:release_kit/src/transforms/digest.dart';
import 'package:test/test.dart';

import 'rk_process.dart';
import 'status_test.dart' show FakeRegistry;

/// Checks each phase against the deliverables its plan lists, so "done" is
/// something this file decides rather than something a judgement call does.
///
/// The failure this exists to prevent already happened once: three phases were
/// declared complete while missing items their own plan named, because "the
/// command runs and prints something plausible" was substituted for the plan's
/// "Done when". A phase is done when its group here passes.
///
/// Each test names the plan line it enforces. A test that cannot be written
/// without the network or a real repository asserts the code path exists and
/// leaves the live proof to the explicit lane in
/// `test/live_release_checkpoints.dart`.
void main() {
  /// Every Dart file rk ships. bin/ counts: a feature reachable only from the
  /// entry point is wired, and a check that ignored bin/ would call it dead.
  final shipped = [Directory('lib'), Directory('bin')]
      .expand((d) => d.listSync(recursive: true))
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  /// Whether any shipped source contains [pattern].
  bool sourceContains(String pattern) =>
      shipped.any((f) => f.readAsStringSync().contains(pattern));

  bool fileExists(String path) => File(path).existsSync();

  /// Whether [pattern] appears in a file other than [definedIn].
  ///
  /// A definition is not a use: matching the declaration of the very thing
  /// being checked is how a conformance test passes while the feature is
  /// unwired, which is the failure this file exists to prevent.
  ///
  /// A [definedIn] that names no shipped file is an error, not a no-op: the
  /// exclusion would stop excluding, the declaration alone would satisfy the
  /// check, and a green gate would mean nothing. That is a live trap for
  /// every file move, and this test has already suffered the failure it
  /// describes once.
  bool usedOutside(String pattern, String definedIn) {
    final others = shipped.where((f) => !f.path.endsWith(definedIn)).toList();
    expect(
      others.length,
      shipped.length - 1,
      reason: '$definedIn matches no shipped file',
    );
    return others.any((f) => f.readAsStringSync().contains(pattern));
  }

  group('phase 1 — engine core', () {
    test('strict TOML subset parser', () {
      expect(fileExists('lib/src/engine/toml.dart'), isTrue);
      expect(fileExists('test/toml_test.dart'), isTrue);
    });

    test(
        'pubspec reader covers name, version, publish_to, executables, '
        'dependencies', () {
      final source = File('lib/src/engine/pubspec.dart').readAsStringSync();
      for (final field in [
        'name',
        'version',
        'publishTo',
        'executables',
        'dependencies',
      ]) {
        expect(source, contains(field), reason: 'reads $field');
      }
    });

    test('version grammar with frozen vectors', () {
      expect(fileExists('lib/src/engine/version.dart'), isTrue);
      expect(fileExists('test/version_test.dart'), isTrue);
    });

    test('config validation and unit/tag derivation', () {
      expect(sourceContains('_derivedTagPattern'), isTrue);
      expect(
        usedOutside('refNameIssue', 'ref_name.dart'),
        isTrue,
        reason: 'a tag pattern git would refuse must be caught before work',
      );
    });

    test('checklist derivation with ordering and prerequisites', () {
      final source = File('lib/src/engine/checklist.dart').readAsStringSync();
      expect(source, contains('_publicationOrder'));
      expect(source, contains('externalPrerequisites'));
      expect(
        usedOutside('externalPrerequisites', 'checklist.dart'),
        isFalse,
        reason: 'callers get prerequisites as steps, not as a separate list',
      );
    });

    test(
        'DONE WHEN: the derived checklist is printed offline, for every '
        'repository shape', () {
      // Executed. The version this replaced asserted that a file under test/
      // contained particular strings — the same anti-pattern the phase 2
      // review found, one level along: rename a test and the phase fails,
      // delete the feature and it passes.
      final scratch = Directory.systemTemp.createTempSync('rk-phase1-');
      addTearDown(() => scratch.deleteSync(recursive: true));

      for (final shape in [
        'single-package',
        'workspace-with-dependent',
        'multi-project-unit',
        'binary-cli',
      ]) {
        final run = Rk.example(scratch, shape)(['status', '--offline']);
        expect(run.code, 0, reason: '$shape: ${run.all}');
        expect(
          run.all,
          contains('public targets were not read'),
          reason: '$shape must say what it did not read',
        );
        expect(
          run.all,
          contains('Unknown is not treated as unpublished'),
          reason: '$shape must not turn an offline unknown into an absence',
        );
      }

      // The shape that must be refused rather than released.
      final refused =
          Rk.example(scratch, 'escapes-repository')(['status', '--offline']);
      expect(refused.code, 1, reason: refused.all);
      expect(refused.all, contains('does not contain'));
    });
  });

  group('phase 2 — output', () {
    // Executed, not read. Every assertion below runs bin/rk.dart against a
    // real repository, because the version of this group that matched strings
    // inside test/ passed every one of five mutations that completely unwired
    // the phase: --json printing nothing, pipes getting cursor escapes, the
    // diagnosis never being written, and safe_to_rerun never being set.
    late Directory scratch;
    late Rk repo;

    setUpAll(() {
      scratch = Directory.systemTemp.createTempSync('rk-phase2-');
      repo = Rk.example(scratch, 'workspace-with-dependent');
    });

    tearDownAll(() => scratch.deleteSync(recursive: true));

    test('the four-glyph gutter, and colour is never the only signal', () {
      final run = repo(['status', '--offline']);
      expect(run.code, 0, reason: run.all);
      expect(
        run.all,
        isNot(contains('\x1b')),
        reason: 'a pipe is not a terminal',
      );
    });

    test('non-TTY output is append-only: no cursor movement, ever', () {
      final run = repo(['status', '--offline']);
      expect(run.all, isNot(contains('\r')));
      expect(run.all, isNot(contains('\x1b[')));
    });

    test('--json carries the checklist, keyed by step id', () {
      final run = repo(['status', '--offline', '--json']);
      final steps = run.stepsOf('cli');
      expect(steps, isNotEmpty, reason: 'an empty checklist is not a surface');
      expect(
        steps.map((s) => s['id']),
        contains('cli/pub.dev/example_cli@0.3.0'),
      );
      for (final step in steps) {
        expect(
          step['verdict'],
          isNotNull,
          reason: 'an omitted verdict reads as "nothing is there"',
        );
      }
      // Offline reads what is local — git says the tag does not exist — and
      // says "not read" only about what it did not read. The version of this
      // that expected `unknown` everywhere was asserting a renderer that
      // inspected nothing at all.
      final registryStep =
          steps.firstWhere((s) => s['kind'] == 'publishRegistry');
      expect(registryStep['verdict'], 'unknown', reason: 'pub.dev unread');
      expect(registryStep['detail'], contains('--offline'));
      final tagStep = steps.firstWhere((s) => s['kind'] == 'tag');
      expect(tagStep['verdict'], 'unknown',
          reason: 'offline mode cannot establish remote tag truth');
    });

    test('--json is only JSON', () {
      final run = repo(['status', '--offline', '--json']);
      expect(run.stdout.trimLeft(), startsWith('{'));
      expect(run.stdout, isNot(contains('derived from the manifests alone')));
      expect(run.json['safe_to_rerun'], isTrue);
      expect(run.json['rerun_helps'], isTrue);
    });

    test('a refusal a caller asked for in JSON is answered in JSON', () {
      final run = repo(['status', '--json', '--bogus']);
      expect(run.code, ExitCodes.usage);
      expect(run.problems.map((p) => p['code']), contains('RK-CLI-001'));
    });

    test('every non-zero exit carries a problem a caller can read', () {
      for (final args in [
        ['status', '--json', '--bogus'],
        ['status', 'nosuch', '--json'],
        ['release', 'nosuch', '--json'],
      ]) {
        final run = repo(args);
        expect(run.code, isNot(0),
            reason: 'precondition for ${args.join(' ')}');
        expect(
          run.problems,
          isNotEmpty,
          reason: 'a non-zero exit a caller cannot read is, to that caller, '
              'a non-zero exit that did not happen: ${args.join(' ')}',
        );
      }
    });

    group('a crash', () {
      late Rk broken;
      late Run run;

      setUpAll(() {
        // A manifest rk is not allowed to open. This is a real, currently
        // unhandled failure rather than an injected one — which is the point:
        // the crash path has to be proved against something that actually
        // crashes. When rk learns to report this one, this test must be
        // pointed at another genuine crash, and if none can be found that is
        // a decision worth making deliberately rather than by deletion.
        //
        // multi-project-unit has no root pubspec, so `dart run` does not try
        // to resolve the fixture as a package and hit the file before rk does.
        broken = Rk.example(scratch, 'multi-project-unit', as: 'broken');
        Process.runSync(
            'chmod', ['000', '${broken.root}/packages/base/pubspec.yaml']);
        addTearDown(() => Process.runSync(
            'chmod', ['644', '${broken.root}/packages/base/pubspec.yaml']));
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

    test('a clean run writes no diagnosis', () {
      final clean =
          Rk.example(scratch, 'workspace-with-dependent', as: 'clean');
      expect(clean(['status', '--offline']).code, 0);
      expect(
        clean.diagnoses(),
        isEmpty,
        reason: 'a directory that fills up on success is a directory nobody '
            'reads on failure',
      );
    });

    test('halt sentences, conflict evidence, remediation', () {
      final source = File('lib/src/output/output.dart').readAsStringSync();
      expect(source, contains('HaltKind'));
      expect(sourceContains('evidence'), isTrue);
      expect(source, contains('remedy'));
    });

    test(
        'DONE WHEN: the checklist renders identically to a terminal and a '
        'pipe', () {
      // A pty, so this is the real comparison rather than a replay of it.
      final piped = repo(['status', '--offline']).stdout;
      final pty = Process.runSync(
        'script',
        [
          '-q',
          '/dev/null',
          Platform.resolvedExecutable,
          'run',
          File('bin/rk.dart').absolute.path,
          'status',
          '--offline',
        ],
        workingDirectory: repo.root,
        environment: {'NO_COLOR': '1'},
      );

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

      expect(
        settle(pty.stdout as String),
        settle(piped),
        reason: 'a log, a pipe and an agent see what the terminal ended up '
            'showing',
      );

      final dumbPty = Process.runSync(
        'script',
        [
          '-q',
          '/dev/null',
          Platform.resolvedExecutable,
          'run',
          File('bin/rk.dart').absolute.path,
          'status',
          '--offline',
        ],
        workingDirectory: repo.root,
        environment: {'TERM': 'dumb'},
      );
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

  group('phase 3 — probes and rk status', () {
    late Directory scratch;

    setUpAll(() => scratch = Directory.systemTemp.createTempSync('rk-phase3-'));
    tearDownAll(() => scratch.deleteSync(recursive: true));

    test('pub.dev client with no dependencies', () {
      expect(fileExists('lib/src/engine/registry.dart'), isTrue);
      expect(
        File('pubspec.yaml').readAsStringSync(),
        isNot(contains('\ndependencies:')),
        reason: 'zero runtime dependencies',
      );
      // The RFC promises this held by a test over the import graph, not the
      // pubspec alone: a dependency can arrive as a path or git import too.
      final foreign = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        for (final line in entity.readAsLinesSync()) {
          final match = RegExp("^import '([^']+)'").firstMatch(line.trim());
          final target = match?.group(1);
          if (target == null) continue;
          if (target.startsWith('dart:')) continue;
          if (target.startsWith('package:release_kit/')) continue;
          if (!target.contains(':')) continue; // relative
          foreign.add('${entity.path}: $target');
        }
      }
      expect(foreign, isEmpty, reason: 'imports outside dart: and rk');
    });

    test('git state is read from a real repository, not a fake', () {
      // git_test.dart drives GitState.read against repositories it builds.
      // Before it existed, status_test faked the whole object and the
      // porcelain parsing — which decides whether rk will release at all —
      // was exercised by nothing.
      expect(fileExists('test/git_test.dart'), isTrue);
      final source = File('lib/src/engine/git.dart').readAsStringSync();
      expect(source, contains('tags'));
      expect(source, contains('isClean'));
      expect(source, contains('headIsPushed'));
    });

    test('the definitive-negative rule, proved against a server', () {
      // registry_test binds a local HTTP server and drives the real client:
      // only a 404 concludes absence, and a 500, a captive portal, a
      // truncated body and a dead socket are every one of them unknown.
      expect(fileExists('test/registry_test.dart'), isTrue);
      expect(
        File('lib/src/engine/registry.dart').readAsStringSync(),
        contains('404'),
      );
    });

    test('one inspector, so status and release cannot disagree', () {
      // Both verbs must ask it — a phase 3 commit claimed release shared the
      // inspector while release still ran its own copy, and the weaker form
      // of this test (any use outside inspect.dart) passed on status alone.
      for (final command in ['status.dart', 'release.dart']) {
        expect(
          File('lib/src/commands/$command').readAsStringSync(),
          contains('inspector.inspect('),
          reason: '$command must ask the shared inspector',
        );
      }
      expect(
        File('lib/src/commands/release.dart').readAsStringSync(),
        isNot(contains('Future<Inspection> _inspect')),
        reason: 'release grew its own inspector once, and it answered absent '
            'by default for every step kind it did not name',
      );
      // Every step kind is answered explicitly. A default clause here is how
      // "definitely not there" gets asserted about a destination nobody asked.
      expect(
        File('lib/src/engine/inspect.dart').readAsStringSync(),
        isNot(contains('default:')),
      );
    });

    test('the forge is read, and being unable to read it is not absence', () {
      final repo = Rk.example(scratch, 'binary-cli', as: 'forge');
      // An origin that does not exist: gh will fail, which is not a fact
      // about whether the release is there.
      Process.runSync(
        'git',
        ['remote', 'add', 'origin', 'https://github.com/example/nothing.git'],
        workingDirectory: repo.root,
      );

      final run = repo(['status', '--json']);
      final release = run
          .stepsOf('cli')
          .where((s) => (s['id'] as String).contains('github-release'))
          .toList();

      expect(release, hasLength(1), reason: 'the forge step must be inspected');
      expect(
        release.single['verdict'],
        isNot('absent'),
        reason: 'a forge rk could not read is not a forge with nothing in it; '
            'absent is what lets a release proceed',
      );
    });

    test('identity derivation exists as a proven component', () {
      // Phase 3 delivers the derivation; wiring it into signing is phase 7's
      // gate, which is red until it happens. The assertion this replaces
      // keyed on designatedRequirement being used outside macos.dart — which
      // identity.dart satisfies while wired to nothing, an unwired file
      // proving another file is used.
      expect(fileExists('lib/src/engine/identity.dart'), isTrue);
      expect(
        fileExists('test/identity_test.dart'),
        isTrue,
        reason: 'proven by scripted tools: the command sequence, that '
            '`security` is never consulted, and that "nothing published" '
            'and "could not read" stay separate answers',
      );
    });

    test('DONE WHEN: status reports a real repository against live reality',
        () {
      // Proved by tool/validate.dart, which runs rk against the real
      // repositories on this machine. It is not a test — real repositories
      // change — so what is asserted here is that the runner exists and that
      // status has something to say.
      expect(fileExists('tool/validate.dart'), isTrue);

      final repo = Rk.example(scratch, 'workspace-with-dependent', as: 'live');
      final run = repo(['status', '--json']);
      expect(run.units, hasLength(2), reason: 'the document carries the units');
      for (final unit in run.units) {
        expect(
          (unit['steps'] as List),
          isNotEmpty,
          reason: '${unit['name']} has no steps, so a caller sees nothing',
        );
      }
    });
  });

  group('phase 4 — published pub package comparison', () {
    test('the pub.dev target owns the one archive comparator', () {
      final target =
          File('lib/src/destinations/pub_dev.dart').readAsStringSync();
      expect(
        target,
        contains('comparator.compare('),
        reason: 'a second comparison implementation is the two-inspectors '
            'drift over again',
      );
      // Both directions exist in the engine itself — asserting them via the
      // test file's contents was the displaced-string anti-pattern the
      // doctrine's first rule bans, found by review in the first phase gated
      // after the rule was written.
      final comparator = File('lib/src/engine/compare.dart').readAsStringSync();
      expect(comparator, contains('in the archive, not in the source'));
      expect(comparator, contains('in the source, missing from the archive'));
      expect(
        target,
        contains('registry.archive('),
        reason: 'a successful publish process is not proof of published bytes',
      );
      expect(fileExists('test/pub_dev_test.dart'), isTrue);
    });
  });

  group('phase 5 — rk release for pub.dev', () {
    // Executed at the command layer with an evolving world: the acts change
    // the same fake registry and tag set the next inspection reads, which is
    // what lets a re-run be the resume. Real pub.dev cannot be published to
    // from a test, so the live half of the DONE WHEN is kept in the explicit
    // `test/live_release_checkpoints.dart` lane.
    Future<
        ({
          int code,
          String text,
          List<String> calls,
          Map<String, Object?> report,
          Object? died,
        })> drive({
      required Map<String, List<String>> published,
      required Map<String, List<int>> archives,
      required Set<String> tags,
      Map<String, ToolResult> results = const {},
      void Function(String key)? onRun,
    }) async {
      // A fresh registry per drive is a fresh process: the world — what is
      // published, what archives exist, what tags exist — persists between
      // runs, and the per-process cache does not. A cache that survived
      // "restarts" hid a double publish in this very test.
      final registry = FakeRegistry(published, archives: archives);
      final buffer = StringBuffer();
      final diagnostics = Diagnostics();
      final parsed = ReleaseConfig.parse('''
schema = 1

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]
''', 'release.toml', diagnostics)!;
      final tree = MemorySourceTree({
        'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
        'packages/keybay/CHANGELOG.md': '## 0.2.0\n',
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
          for (final t in tags) t: '1111111111111111111111111111111111111111'
        },
        signingConfigured: true,
        originUrl: 'example/keybay',
      );
      late ReleaseStages stages;
      final tools = RecordingTools(
        results: results,
        onRun: (key) {
          // A successful push is what puts a tag on origin — the same set
          // feeds the next run's local tags and the remote's answer, which
          // is exactly the world after a push: everyone can see it.
          if (key == 'git push origin $tagObject:refs/tags/v0.2.0' &&
              (results[key]?.exitCode ?? 0) == 0) {
            tags.add('v0.2.0');
          }
          onRun?.call(key);
        },
        // Origin answers from the world: a tag the world holds is listed,
        // one it does not is not — the remote leg reads reality, and this is
        // the reality the drive maintains.
        answers: (key) {
          if (key == 'git rev-parse --verify refs/tags/v0.2.0^{tag}') {
            return ToolResult(
              exitCode: 0,
              stdout: '$tagObject\n',
              stderr: '',
            );
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
              stdout: 'object ${git.head}\n'
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
      final output =
          Output(sink: buffer.write, isTerminal: false, useColor: false);

      var code = ExitCodes.refused;
      Object? died;
      try {
        final stageRoot = Directory.systemTemp.createTempSync('rk-drive-');
        addTearDown(() {
          if (stageRoot.existsSync()) stageRoot.deleteSync(recursive: true);
        });
        stages = ReleaseStages(
          source: tree,
          git: git,
          repositoryRoot: stageRoot.path,
        );
        code = await ReleaseCommand(
          resolution: resolution,
          tree: tree,
          git: git,
          registry: registry,
          // The same tools the command gets, which is what `bin/rk.dart`
          // does — release never builds a toolless inspector. Without them
          // the tag step could not reach the `answers:` leg above, so the
          // drive maintained a faithful remote and then inspected a
          // different reality than the one it acted on.
          inspector: Inspector(
            registry: registry,
            pubDev: PubDevTarget(
              registry: registry,
              comparator: Comparator(tools: const SystemTools()),
              source: tree,
            ),
            git: git,
            tools: tools,
            repository: 'example/keybay',
            stageFor: stages.call,
          ),
          tools: tools,
          output: output,
          confirm: (_) async => '0.2.0',
          wait: (_) async {},
          stageFor: stages.call,
          refreshStage: stages.refresh,
          refreshGit: () => git,
        ).run(only: 'core');
      } on Object catch (error) {
        died = error;
      }
      return (
        code: code,
        text: buffer.toString(),
        calls: tools.calls,
        report: jsonDecode(output.report.encode(exit: code))
            as Map<String, Object?>,
        died: died,
      );
    }

    List<int> archiveOfTree() => ArchiveBuilder.gzip(ArchiveBuilder.tar([
          ArchiveEntry(
            name: 'pubspec.yaml',
            bytes: 'name: keybay\nversion: 0.2.0\n'.codeUnits,
          ),
          ArchiveEntry(name: 'CHANGELOG.md', bytes: '## 0.2.0\n'.codeUnits),
        ]));

    test('type-the-version confirmation for a permanent act', () {
      expect(sourceContains('type ${'\$'}{unit.version}'), isTrue);
    });

    test('tag step with pre-act and post-act inspection', () {
      expect(sourceContains('StepKind.tag'), isTrue);
    });

    test('consumer resolve runs before the permanent act, and blocks it',
        () async {
      final run = await drive(
        published: {
          'keybay': ['0.1.0']
        },
        archives: {},
        tags: {},
        results: {
          'dart pub get --no-precompile': ToolResult(
            exitCode: 1,
            stdout: '',
            stderr: 'version solving failed',
          ),
        },
      );

      expect(run.code, ExitCodes.refused);
      expect(run.text, contains('consumers could not resolve this'));
      expect(
        run.calls.where((c) => c.contains('publish --force')),
        isEmpty,
        reason: 'pub excludes pubspec_overrides.yaml from the archive but '
            'honours it locally — a dry run can pass while the published '
            'package is unresolvable for everyone else, so the resolve '
            'gates the act',
      );
    });

    test('post-publish re-download and compare, and a mismatch is terminal',
        () async {
      final published = {
        'keybay': ['0.1.0']
      };
      final archives = <String, List<int>>{};
      final run = await drive(
        published: published,
        archives: archives,
        tags: {},
        onRun: (key) {
          if (key == 'dart pub publish --force') {
            published['keybay']!.add('0.2.0');
            // The registry serves bytes this tree cannot account for.
            archives['keybay@0.2.0'] = ArchiveBuilder.gzip(ArchiveBuilder.tar([
              ArchiveEntry(
                name: 'pubspec.yaml',
                bytes: 'name: keybay\nversion: 0.2.0\n'.codeUnits,
              ),
              ArchiveEntry(
                name: 'lib/injected.dart',
                bytes: 'not yours\n'.codeUnits,
              ),
            ]));
          }
        },
      );

      expect(run.code, ExitCodes.refused);
      expect(
        (run.report['problems'] as List).map((p) => (p as Map)['code']),
        contains('RK-PUB-006'),
      );
      expect(run.text, contains('lib/injected.dart'));
      expect(
        run.report['rerun_helps'],
        false,
        reason: 'an agent must not retry a release that can never succeed',
      );
      expect(run.text, contains('cannot be fixed by re-running'));
    });

    test(
        'DONE WHEN, resume half: killed after the tag, a re-run finishes '
        'without re-tagging', () async {
      final published = {
        'keybay': ['0.1.0']
      };
      final archives = <String, List<int>>{};
      final tags = <String>{};

      final first = await drive(
        published: published,
        archives: archives,
        tags: tags,
        results: {
          'dart pub publish --force':
              ToolResult(exitCode: 137, stdout: '', stderr: 'Killed: 9'),
        },
        onRun: (key) {
          if (key.startsWith('git tag')) tags.add('v0.2.0');
        },
      );
      expect(first.code, ExitCodes.refused, reason: first.text);
      expect(tags, contains('v0.2.0'), reason: 'the tag landed before death');

      final second = await drive(
        published: published,
        archives: archives,
        tags: tags,
        onRun: (key) {
          if (key == 'dart pub publish --force') {
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
        second.calls.where((c) => c.contains('publish --force')),
        hasLength(1),
      );
      expect(second.text, contains('byte-identical'));
    });

    test(
        'DONE WHEN, resume half: killed after the publish, a re-run '
        'confirms without publishing twice', () async {
      final published = {
        'keybay': ['0.1.0']
      };
      final archives = <String, List<int>>{};
      final tags = <String>{'v0.2.0'};

      final first = await drive(
        published: published,
        archives: archives,
        tags: tags,
        onRun: (key) {
          if (key == 'dart pub publish --force') {
            published['keybay']!.add('0.2.0');
            archives['keybay@0.2.0'] = archiveOfTree();
            throw StateError('killed between the act and the confirmation');
          }
        },
      );
      expect(first.died, isNotNull, reason: 'the run died mid-flight');

      final second =
          await drive(published: published, archives: archives, tags: tags);

      expect(second.code, ExitCodes.ok, reason: second.text);
      expect(
        second.calls.where((c) => c.contains('publish --force')),
        isEmpty,
        reason: 'pub.dev already lists it; publishing again would be the '
            'permanent mistake',
      );
      expect(second.text, contains('already released'));
    });

    test('resume skips what reality says is done', () {
      expect(sourceContains('isExact'), isTrue);
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
    expect(accepted, contains('--stage'), reason: 'the scrape still works');

    // Exactly the documents that describe rk's *current* surface. Widening
    // this to every shipped markdown was tried and is wrong: `doc/plan.md`
    // is a history that legitimately records `--rehearse` and `--verbose` as
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
          reason: '$path names $flag, which rk refuses with RK-CLI-001',
        );
      }
    }
  });

  group('phase 6 — rk init', () {
    late Directory scratch;

    setUpAll(() => scratch = Directory.systemTemp.createTempSync('rk-phase6-'));
    tearDownAll(() => scratch.deleteSync(recursive: true));

    test('scans, classifies, proposes — and writes nothing without a human',
        () {
      final repo = Rk.example(scratch, 'workspace-with-dependent', as: 'scan');
      File('${repo.root}/release.toml').deleteSync();
      repo.commit(); // the scan reads tracked files, and rightly so
      final run = repo(['init']);

      expect(run.code, 0, reason: run.all);
      expect(run.all, contains('2 releasable packages'));
      expect(run.all, contains('example_workspace is a workspace root'));
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
    });

    test('never edits a config that exists', () {
      final repo = Rk.example(scratch, 'single-package', as: 'existing');
      final run = repo(['init']);
      expect(run.code, 0);
      expect(run.all, contains('already exists'));
      expect(run.all, contains('decision already made'));
    });

    test('a repository with nothing releasable is a correct answer', () {
      final repo = Rk.repository(scratch, 'none', {
        'pubspec.yaml': 'name: tool\npublish_to: none\nversion: 1.0.0\n',
      });
      repo.commit(); // untracked manifests would give the same words for the
      // wrong reason — the veto is what this asserts
      final run = repo(['init']);
      expect(run.code, 0, reason: 'not a refusal');
      expect(run.all, contains('nothing here can be released'));
    });

    test('init takes no unit, and says so instead of ignoring one', () {
      final repo = Rk.example(scratch, 'single-package', as: 'stray-arg');
      final run = repo(['init', 'somepkg']);
      expect(run.code, isNot(0));
      expect(
        run.all,
        contains('takes no unit'),
        reason: 'silently configuring the whole repository under an argument '
            'that reads as a scope is worse than refusing it',
      );
    });

    test('the quiet exits are distinguishable by a caller, not only a reader',
        () {
      // Review finding: already-configured and nothing-releasable produced
      // byte-identical empty documents under --json. Each fact is data now.
      final existing = Rk.example(scratch, 'single-package', as: 'json-exists');
      final exists = existing(['init', '--json']);
      expect(exists.code, 0, reason: exists.all);
      expect(
        (exists.json['problems'] as List)
            .map((p) => (p as Map)['code'])
            .toList(),
        contains('RK-INIT-002'),
      );

      final none = Rk.repository(scratch, 'json-none', {
        'pubspec.yaml': 'name: tool\npublish_to: none\nversion: 1.0.0\n',
      });
      none.commit();
      final nothing = none(['init', '--json']);
      expect(nothing.code, 0, reason: nothing.all);
      expect(
        (nothing.json['problems'] as List)
            .map((p) => (p as Map)['code'])
            .toList(),
        contains('RK-INIT-003'),
      );
    });

    test('the CLI parses consent through the one parser that declines EOF', () {
      // `rk init < /dev/null` wrote the file: EOF read as null, null
      // collapsed to '', and '' means Yes — while macOS reports /dev/null as
      // a terminal, so hasTerminal never guarded it. A test harness cannot
      // reach that state through a real pipe (pipes report no terminal and
      // take the nobody-to-confirm path), so the gate is that the entry
      // point routes its answer through InitCommand.consented — whose
      // vectors, including EOF, are pinned in init_test.dart.
      expect(usedOutside('InitCommand.consented', 'init.dart'), isTrue);
    });

    test(
        'DONE WHEN: the proposal round-trips through the machine surface '
        'into a releasable repository', () {
      // The dogfood loop, entirely through the CLI: init emits the proposal
      // as data, the caller writes it, and rk itself must then accept it —
      // a written config rk refuses would be rk debugging its own output.
      final repo = Rk.example(scratch, 'multi-project-unit', as: 'loop');
      File('${repo.root}/release.toml').deleteSync();
      repo.commit();

      final proposal = repo(['init', '--json']);
      expect(proposal.code, 0, reason: proposal.all);
      final config = ((proposal.json['attachments'] as Map?) ??
          const {})['release.toml'] as String?;
      expect(
        config,
        isNotNull,
        reason: 'an agent reads the proposal from the document; a human '
            'writes it at a terminal',
      );

      File('${repo.root}/release.toml').writeAsStringSync(config!);
      final status = repo(['status', '--offline', '--json']);
      expect(status.code, 0, reason: status.all);
      expect(
        status.units,
        hasLength(3),
        reason: 'what init proposed, status releases',
      );
    });
  });

  // Shared by the 7a and 7b groups: one scratch, one command-layer drive.
  late Directory scratch;
  setUpAll(() => scratch = Directory.systemTemp.createTempSync('rk-7-'));
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
      })> binaryDrive({
    required bool dryRun,
    Set<String> remoteTags = const {},
    bool notaryRejects = false,
    bool signingRejects = false,
    List<String> platforms = const ['macos-arm64'],
    bool homebrew = false,
    String label = '',
    String? containerRuntime = 'docker',
    int certificates = 1,
    List<String>? certTeams,
    bool keychainReadable = true,
    String? previousTag,
    bool declaresCodeId = true,
    bool publishedNamesTeam = true,
    bool publishStaged = false,
    bool baselineChangesBeforeConsent = false,
  }) async {
    final root = Directory('${scratch.path}/drive-${dryRun ? 'd' : 'f'}'
        '${notaryRejects ? '-nr' : ''}$label')
      ..createSync(recursive: true);
    final buffer = StringBuffer();
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse('''
schema = 1

[release.cli]
path = "packages/tool"
publish = ["github-release"${homebrew ? ', "homebrew"' : ''}]
binary_platforms = [${platforms.map((p) => '"$p"').join(', ')}]
${declaresCodeId ? 'code_id = "io.github.example.tool"' : ''}
''', 'release.toml', diagnostics)!;
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
          previousTag: '1111111111111111111111111111111111111111'
      },
      signingConfigured: true,
      originUrl: 'example/tool',
    );
    final stageCache = <String, ReleaseStage>{};
    ReleaseStage stageFor(ResolvedUnit unit) =>
        stageCache.putIfAbsent(unit.name, () {
          return ReleaseStage(
            unit: unit,
            source: tree,
            directory: StageDirectory(
              repositoryRoot: root.path,
              identity: StageIdentity.forPlan(
                headCommit: git.head,
                headTree: '2222222222222222222222222222222222222222',
                resolvedPlan: {
                  'unit': unit.name,
                  'version': unit.version.canonical,
                  'fixture': label,
                },
              ),
            ),
          );
        });
    final work = stageFor(resolution.unit('cli')!).directory.path;

    const releaseTagObject = '4444444444444444444444444444444444444444';
    final pushed = <String>{...remoteTags};
    final uploaded = <String>{};
    var draftCreated = false;
    var released = false;
    String? notesAtCreate;
    List<int>? publishedFormula;
    var publishedIdentityReads = 0;
    List<Map<String, Object?>> uploadedAssets() => [
          for (final (index, name) in uploaded.indexed)
            {
              'id': 100 + index,
              'name': name,
              'state': 'uploaded',
              'size': File('$work/$name').lengthSync(),
              'digest':
                  'sha256:${Sha256.hex(File('$work/$name').readAsBytesSync())}',
            },
        ];
    final signingTeams = certTeams ??
        [for (var i = 0; i < certificates; i++) 'TEAM12345${i + 6}'];
    String certificateSha1(int index) => '${index + 1}' * 40;
    String certificateSha256(int index) =>
        String.fromCharCode('a'.codeUnitAt(0) + index) * 64;
    final tools = RecordingTools(
      probe: (key, workingDirectory) {
        if (key == 'git push' && workingDirectory != null) {
          final formula = File('$workingDirectory/Formula/tool.rb');
          if (formula.existsSync()) {
            publishedFormula = formula.readAsBytesSync();
          }
        }
      },
      onRun: (key) {
        if (key.startsWith('git push origin ')) {
          final refspec = key.substring('git push origin '.length);
          const marker = ':refs/tags/';
          if (refspec.contains(marker)) {
            pushed.add(refspec.split(marker).last);
          }
        }
        if (key.contains(' -X POST repos/example/tool/releases --input ')) {
          final input = key.split(' --input ').last;
          final body = jsonDecode(File(input).readAsStringSync())
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
            ..writeAsBytesSync(File('$work/$name').readAsBytesSync());
        }
        if (key.startsWith('dart compile exe')) {
          final out = key.split(' -o ').last.split(' ').first;
          File(out)
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync('BINARY 1.0.0'.codeUnits);
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
          final manifest = File('$work/release-manifest.json');
          final digest = Sha256.hex(manifest.readAsBytesSync());
          return ToolResult(
            exitCode: 0,
            stdout: 'object ${git.head}\n'
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
        if (signingRejects && key.startsWith('codesign --force')) {
          return ToolResult(
            exitCode: 1,
            stdout: '',
            stderr: 'the signing operation was interrupted',
          );
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
              stdout: 'designated => identifier "io.github.example.tool" '
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
            stdout: 'designated => identifier "io.github.example.tool" and '
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
            stdout: 'SHA-256 hash: ${certificateSha256(index)}\n'
                'SHA-1 hash: ${certificateSha1(index)}\n',
            stderr: '',
          );
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
                    'id': 6,
                  },
                if (draftCreated)
                  {
                    'tag_name': 'v1.0.0',
                    'draft': !released,
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
                    'id': 7,
                    'name': 'tool 1.0.0',
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
                    'name': 'tool 1.0.0',
                    'body': notesAtCreate,
                    'draft': false,
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
        if (key.startsWith('gh api repos/example/homebrew-tap/contents/')) {
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
      final output =
          Output(sink: buffer.write, isTerminal: false, useColor: false);
      final code = await ReleaseCommand(
        resolution: resolution,
        tree: tree,
        git: git,
        registry: registry,
        inspector: Inspector(
          registry: registry,
          pubDev: PubDevTarget(
            registry: registry,
            comparator: Comparator(tools: const SystemTools()),
            source: tree,
          ),
          git: git,
          tools: tools,
          repository: 'example/tool',
          stageFor: stageFor,
        ),
        tools: tools,
        output: output,
        confirm: (_) async => '1.0.0',
        stageOnly: stageOnly,
        stageFor: stageFor,
        refreshStage: (unit, _) => stageFor(unit),
        wait: (_) => Future<void>.delayed(Duration.zero),
        capabilities: HostCapabilities(
          hostPlatform: 'macos-arm64',
          containerRuntime: containerRuntime,
          hasNativeAssets: false,
        ),
      ).run(only: 'cli');
      return (code: code, output: output);
    }

    var execution = await execute(dryRun);
    if (publishStaged && execution.code == ExitCodes.ok) {
      if (!dryRun) {
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
      expected: Inspector.expectedAssets(resolution.unit('cli')!),
    );
  }

  group('phase 7a — the local chain', () {
    test('capability resolution per platform', () {
      expect(fileExists('lib/src/builds/capability.dart'), isTrue);
    });

    test('deterministic archives', () {
      expect(fileExists('lib/src/transforms/archive.dart'), isTrue);
    });

    test('signing verifies against the published requirement', () {
      // Green now for the reason the red version demanded: release derives
      // the requirement from the previous published release and the sign
      // step compares against it — binary_steps_test proves the refusal.
      expect(
        usedOutside('PublishedIdentity(', 'engine/identity.dart'),
        isTrue,
        reason: 'the requirement must come from the release users already '
            'installed, and something in the product must ask for it',
      );
      expect(
        File('lib/src/binary_chain.dart').readAsStringSync(),
        contains('publishedRequirement'),
      );
    });

    test(
        'no state carried between steps — a full release, each step its '
        'own act', () async {
      expect(
        File('lib/src/commands/release.dart').readAsStringSync(),
        isNot(contains('_produced')),
        reason: 'CI seam 1: a step must be executable from the checklist, '
            'its id, the workspace and reality',
      );

      final run = await binaryDrive(dryRun: false);
      expect(run.code, 0, reason: run.text);
      expect(run.calls, isNot(contains('dart pub login')),
          reason:
              'a unit with no pub.dev target has no pub session to acquire');
      // Every stage of the chain acted, separately, in checklist order.
      final order = [
        'dart compile exe',
        'codesign --force',
        'ditto',
        'xcrun notarytool submit',
        'xcrun notarytool log',
        'gh api -X POST repos/example/tool/releases --input',
      ];
      var at = -1;
      for (final prefix in order) {
        final index = run.calls.indexWhere((c) => c.startsWith(prefix));
        expect(index, greaterThan(at), reason: '$prefix in order');
        at = index;
      }
      expect(
        run.text,
        contains('publish 5 assets to the v1.0.0 release'),
      );
      expect(run.text, contains('released'));
    });

    test(
        'a chain failure halts with its sentence — partway, not "nothing '
        'changed" and not "lost sight"', () async {
      // Review finding: most chain failures exited 1 with no halt at all —
      // no sentence for a person, no `halt` key for a caller. A rejected
      // notarization is the everyday representative of the class.
      final run = await binaryDrive(
        dryRun: false,
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
        reason: 'a rejected submission is fixed and re-run; nothing here is '
            'terminal',
      );
      expect(
        run.text,
        contains('notarization did not complete'),
        reason: 'the problem itself is still named beside the sentence',
      );
      expect(
        run.calls.where((call) =>
            call.startsWith('git push origin') ||
            call.contains(' -X POST repos/example/tool/releases --input ')),
        isEmpty,
        reason: 'the complete private stage precedes every public act',
      );
    });

    test('a signing interruption leaves every public target untouched',
        () async {
      final run = await binaryDrive(
        dryRun: false,
        signingRejects: true,
        label: '-sign-failure-boundary',
      );

      expect(run.code, ExitCodes.refused, reason: run.text);
      expect(run.text, contains('signing failed'));
      expect((run.json['halt'] as Map?)?['kind'], 'stoppedPartway');
      expect(
        run.calls.where((call) =>
            call.startsWith('git push origin') ||
            call.contains(' -X POST repos/example/tool/releases --input ')),
        isEmpty,
        reason: 'signed bytes are required in the stage before publication',
      );
    });

    test(
        'DONE WHEN, stage half: every local step runs for real and '
        'nothing public is touched', () async {
      final run = await binaryDrive(dryRun: true);

      expect(run.code, 0, reason: run.text);
      for (final local in [
        'dart compile exe',
        'codesign --force',
        'ditto',
        'xcrun notarytool submit',
      ]) {
        expect(
          run.calls.any((c) => c.startsWith(local)),
          isTrue,
          reason: '$local ran for real — staging exists so an expired '
              'certificate is found on a quiet afternoon',
        );
      }
      for (final public in [
        'git tag',
        'git push',
        'gh api -X POST repos/example/tool/releases --input',
      ]) {
        expect(
          run.calls.any((c) => c.startsWith(public)),
          isFalse,
          reason: '$public is public and staging never touches it',
        );
      }
      expect(run.text, contains('1.0.0 staged'));
      expect(run.text, contains('it publishes nothing'));
    });

    test('stage spans every platform and still touches nothing public',
        () async {
      final run = await binaryDrive(
        dryRun: true,
        platforms: ['macos-arm64', 'linux-x64', 'linux-arm64'],
        homebrew: true,
        label: '-3pr',
      );
      expect(run.code, 0, reason: run.text);
      expect(
        run.calls.where((c) => c.startsWith('dart compile exe')).length,
        3,
      );
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
      expect(run.text, contains('1.0.0 staged'));
    });

    test(
        'a platform nothing can run still ships — built, not executed, and '
        'disclosed before the version is typed', () async {
      // Optional evidence degrades honestly (CI-readiness constraint 6). A
      // missing container runtime used to refuse the whole release: a
      // daemon that is not running became a hard blocker on shipping,
      // which is a heavier claim than the smoke test earns.
      final run = await binaryDrive(
        dryRun: false,
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
      expect(
        run.text,
        contains('built but never executed'),
        reason: 'the operator accepts the weaker assurance knowingly, at '
            'the prompt, before the version is typed',
      );
      expect(run.text, contains('linux-x64'));
      expect(
        run.text,
        isNot(contains('macos-arm64 — no container runtime')),
        reason: 'the host runs its own binaries for free; only the '
            'cross-compiled target is unproven',
      );
      expect(run.text, contains('released'));
    });
  });

  /// Phase 7b — the destinations, driven through the same command-layer world
  /// as 7a: the release carries the full asset shape, the body is the
  /// changelog entry, and the tap moves only after the release is public.
  ///
  /// This group was deleted as collateral when `--rehearse` was cut, and the
  /// commit that did it never said so. What it guards is the one seam
  /// `engine/assets.dart` does *not* close: `expectedFor` unified the
  /// expectation side, but the producer still gathers archives and notary
  /// evidence in `gatherAssets` and splices the formula in by hand. So the
  /// two can still disagree — and `GithubRelease.publish` verifies only
  /// against what it just uploaded, never against the expected set. One name
  /// out of step publishes green, and the *next* inspect returns
  /// `Verdict.conflict` on a release that cannot be edited: permanently
  /// unfixable, against a release rk made itself.
  ///
  /// Mutation-proven, both directions: dropping the formula from the upload
  /// list, and replacing the body with anything but the changelog entry,
  /// each pass the whole suite without this group.
  group('phase 7b — the destinations', () {
    test(
        'DONE WHEN, drive half: what the release publishes is exactly what '
        'the inspector will expect, and the body is the changelog entry',
        () async {
      final run = await binaryDrive(
        dryRun: false,
        platforms: ['macos-arm64', 'linux-x64', 'linux-arm64'],
        homebrew: true,
        label: '-3p',
      );
      expect(run.code, 0, reason: run.text);

      // Three builds, two of them cross-compiled for linux.
      expect(
        run.calls.where((c) => c.startsWith('dart compile exe')).length,
        3,
      );
      expect(
        run.calls
            .where((c) =>
                c.startsWith('dart compile exe') &&
                c.contains('--target-os=linux'))
            .length,
        2,
      );

      // Set equality against the derivation, not against a literal list.
      // A literal would pin the producer to a spelling; this pins it to the
      // inspector, which is the party it has to agree with. Both sides move
      // together or this fails.
      final uploaded = run.calls
          .where((call) => call.contains('uploads.github.com'))
          .map((call) => Uri.decodeQueryComponent(
                call.split('assets?name=').last,
              ))
          .toSet();

      expect(
        uploaded,
        equals(run.expected),
        reason: 'the release publishes exactly the set Inspector.'
            'expectedAssets derives — any difference is a conflict verdict '
            'on the next run, and a published release cannot be edited',
      );
      // The formula is the name the producer splices in by hand, so it is
      // the one most able to drift. Named to say so.
      expect(run.expected, contains('tool.rb'));
      expect(
        run.text,
        contains('publish 8 assets to the v1.0.0 release'),
        reason: run.text,
      );

      // The body is the changelog entry — one source of release prose.
      expect(
        run.notes,
        'First release.',
        reason: 'the release body must be the CHANGELOG entry, not a '
            'commit-log digest',
      );

      // The formula moves only after the release is public, and what the
      // public tap serves is read back and proven.
      final publishAt = run.calls.indexWhere(
        (c) => c.contains(' -X PATCH repos/example/tool/releases/7 '),
      );
      final tapCloneAt = run.calls.indexWhere(
          (c) => c.startsWith('git clone') && c.contains('homebrew-tap'));
      expect(tapCloneAt, greaterThan(publishAt),
          reason: 'a formula pointing at an unpublished release would brew '
              'a 404');
      expect(
        run.calls.any(
          (call) => call.startsWith(
            'gh api repos/example/homebrew-tap/contents/',
          ),
        ),
        isTrue,
        reason: 'the formula is proven from the public tap after its push',
      );
      expect(run.text, contains('released'));
    });

    // This unit publishes to no registry, so nothing in it is permanent by
    // `Step.isPermanent`. That is exactly the shape the old gating was
    // silent on: it required `permanent.isNotEmpty`, which is "a pub.dev
    // publish remains" — a fact about pub.dev, not about signing.
    test('a genuine first signing names the certificate before the yes',
        () async {
      final run = await binaryDrive(dryRun: false, label: '-first');

      expect(run.code, 0, reason: run.text);
      expect(
        run.text,
        contains('this release claims, for the first time:'),
        reason: 'the identity about to become permanent is disclosed at the '
            'prompt, and this unit has nothing permanent in the pub.dev '
            'sense — which is what used to silence it',
      );
      // Anchored to the disclosure sentence, contiguously. Matching the two
      // strings separately over the whole buffer was satisfied by the sign
      // step's own note, which prints the identifier *after* consent — the
      // one place it is too late to matter.
      expect(
        run.text,
        contains('macOS identity   io.github.example.tool'),
        reason: 'the identifier is what becomes permanent, and it is on its '
            'own line so a wrong one is seen rather than hunted for',
      );
      expect(
        run.text,
        contains('Signed by\n'
            '                     Developer ID Application: D (TEAM123456)'),
        reason: 'the identifier is half of what becomes permanent, and the '
            'RFC already claimed this sentence named it — it named only the '
            'certificate',
      );
    });

    test('a later release does not claim to be a first one', () async {
      // The common false positive, and rk's own shape: one certificate
      // installed, a release already published. The old gate asked
      // `permanent.isNotEmpty && certificates.length == 1` — neither of
      // which is first-ness — so rk downloaded the published archive, read
      // its identity, and then told the operator that identity did not
      // exist yet.
      final run = await binaryDrive(
        dryRun: false,
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
        isNot(contains('this release claims, for the first time:')),
        reason: 'there is an identity to reproduce, and it was just read',
      );
    });

    test('reusing a later signed stage does not turn it into a first claim',
        () async {
      final run = await binaryDrive(
        dryRun: true,
        publishStaged: true,
        label: '-later-stage-reuse',
        previousTag: 'v0.9.0',
      );

      expect(run.code, 0, reason: run.text);
      expect(
        run.calls.where((call) => call.startsWith('codesign --force')),
        hasLength(1),
        reason: 'the release invocation reuses the staged signed bytes',
      );
      expect(
        run.text,
        isNot(contains('this release claims, for the first time:')),
        reason: 'first-identity is receipt data, not inferred from the mere '
            'presence of a signing certificate',
      );
    });

    test('a changed public signing baseline refuses before authorization',
        () async {
      final run = await binaryDrive(
        dryRun: false,
        label: '-baseline-race',
        previousTag: 'v0.9.0',
        baselineChangesBeforeConsent: true,
      );

      expect(run.code, ExitCodes.refused, reason: run.text);
      expect(run.text, contains('RK-SIGN-013'));
      expect(
        run.calls.where((call) => call.startsWith('git push origin')),
        isEmpty,
        reason: 'the baseline refresh is before consent and the first public '
            'act',
      );
    });

    test('nothing published and nothing declared is refused, not guessed',
        () async {
      // The identifier used to fall back to the pub package name, chosen at
      // the one moment that makes it permanent: macOS stores the designated
      // requirement in the ACL of every Keychain item the program creates,
      // so a wrong one is an auth dialog on every access, forever. Nothing
      // in the system states it — not the keychain, not the pubspec, not the
      // forge — so rk refuses and suggests instead of choosing.
      final run = await binaryDrive(
        dryRun: false,
        label: '-nocodeid',
        declaresCodeId: false,
      );

      expect(run.code, ExitCodes.refused, reason: run.text);
      expect(run.text, contains('RK-SIGN-009'));
      expect((run.json['halt']! as Map)['kind'], 'beforeActing');
      expect(
        run.calls.any((c) => c.startsWith('git push origin')),
        isFalse,
        reason: 'refused before the tag is public',
      );
      expect(
        run.calls.any((c) => c.startsWith('codesign --force')),
        isFalse,
        reason: 'and before anything is signed under a guessed name',
      );
      // The remedy offers the convention as text to read and edit. It is a
      // suggestion, never a fallback — the rule reproduces rk's own declared
      // identifier and misses keybay's deliberate `.cli` suffix.
      expect(run.text, contains('code_id = "io.github.example.tool"'));
    });

    group('the keychain is read before anything acts, not midway', () {
      test('an unreadable keychain is not an absent certificate', () async {
        final run = await binaryDrive(
          dryRun: false,
          label: '-nokc',
          keychainReadable: false,
        );

        expect(run.code, ExitCodes.refused, reason: run.text);
        expect(run.text, contains('RK-SIGN-006'));
        expect(
          run.text,
          isNot(contains('no Developer ID Application certificate')),
          reason: 'telling an operator to install a certificate is wrong '
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
          dryRun: false,
          label: '-nocert',
          certificates: 0,
        );

        expect(run.code, ExitCodes.refused, reason: run.text);
        expect(run.text, contains('RK-SIGN-007'));
        expect((run.json['halt']! as Map)['kind'], 'beforeActing');
        expect(run.calls.any((c) => c.startsWith('git push origin')), isFalse);
      });

      test('a published release naming no readable team refuses before acting',
          () async {
        // The sign step refuses this as RK-SIGN-001 — after the tag is
        // public. The requirement is in hand during preflight, and the
        // answer does not change by waiting.
        final run = await binaryDrive(
          dryRun: false,
          label: '-noteam',
          previousTag: 'v0.9.0',
          publishedNamesTeam: false,
        );

        expect(run.code, ExitCodes.refused, reason: run.text);
        expect(run.text, contains('RK-SIGN-001'));
        expect((run.json['halt']! as Map)['kind'], 'beforeActing');
        expect(run.calls.any((c) => c.startsWith('git push origin')), isFalse);
      });

      test('a rehearsal shows the names the real run will claim', () async {
        // The names are exactly what a rehearsal is for reading before they
        // become unreclaimable, and they used to appear for the first time
        // only at the real prompt, after the version was typed.
        final run = await binaryDrive(dryRun: true, label: '-dryclaim');

        expect(run.code, ExitCodes.ok, reason: run.text);
        expect(run.text, contains('this release claims, for the first time:'));
        expect(run.text, contains('macOS identity   io.github.example.tool'));
      });

      test('a dry run still refuses when nothing states the program name',
          () async {
        // --stage signs for real, so it needs a real identifier. The
        // refusal is gated on `willSign`, never on dryRun.
        final run = await binaryDrive(
          dryRun: true,
          label: '-drynoid',
          declaresCodeId: false,
        );

        expect(run.code, ExitCodes.refused, reason: run.text);
        expect(run.text, contains('RK-SIGN-009'));
        expect(run.calls.any((c) => c.startsWith('codesign --force')), isFalse);
      });

      test('a certificate for the wrong team refuses before the publish',
          () async {
        // The likeliest signing failure there is, and the costliest to catch
        // late: `publishRegistry` is emitted before `build`, so for every
        // unit in this fleet a signing problem the preflight misses costs a
        // permanently burned version number. MacOsSigner.sign refuses this —
        // after the tag is public and pub.dev has published.
        final run = await binaryDrive(
          dryRun: false,
          label: '-wrongteam',
          previousTag: 'v0.9.0',
          certTeams: ['TEAMZZZZZZ'],
        );

        expect(run.code, ExitCodes.refused, reason: run.text);
        expect(run.text, contains('RK-SIGN-010'));
        expect(run.text, contains('TEAM123456'),
            reason: 'the team users installed');
        expect(run.text, contains('TEAMZZZZZZ'), reason: 'and the one here');
        expect((run.json['halt']! as Map)['kind'], 'beforeActing');
        expect(run.calls.any((c) => c.startsWith('git push origin')), isFalse);
      });

      test('several certificates for the published team refuses too', () async {
        final run = await binaryDrive(
          dryRun: false,
          label: '-dupeteam',
          previousTag: 'v0.9.0',
          certTeams: ['TEAM123456', 'TEAM123456'],
        );

        expect(run.code, ExitCodes.refused, reason: run.text);
        expect(run.text, contains('RK-SIGN-011'));
        expect((run.json['halt']! as Map)['kind'], 'beforeActing');
        expect(run.calls.any((c) => c.startsWith('git push origin')), isFalse);
      });

      test('an ambiguous first signing refuses, naming the teams', () async {
        final run = await binaryDrive(
          dryRun: false,
          label: '-twocerts',
          certificates: 2,
        );

        expect(run.code, ExitCodes.refused, reason: run.text);
        expect(run.text, contains('RK-SIGN-008'));
        expect(run.text, contains('TEAM123456'));
        expect(run.text, contains('TEAM123457'));
        expect((run.json['halt']! as Map)['kind'], 'beforeActing');
        expect(run.calls.any((c) => c.startsWith('git push origin')), isFalse);
      });
    });
  });
}
