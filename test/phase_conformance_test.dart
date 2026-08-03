import 'dart:io';

import 'dart:convert';

import 'package:rk/src/commands/release.dart';
import 'package:rk/src/engine/compare.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/inspect.dart';
import 'package:rk/src/engine/output.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/transforms/archive.dart';
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
/// leaves the live proof to the checkpoint runs recorded in doc/plan.md.
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
  bool usedOutside(String pattern, String definedIn) => shipped
      .where((f) => !f.path.endsWith(definedIn))
      .any((f) => f.readAsStringSync().contains(pattern));

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
          contains('derived from the manifests alone'),
          reason: '$shape must say what it did not read',
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
      expect(steps.first['verdict'], 'unknown', reason: 'nothing was read');
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
        ['verify', 'nosuch', '--json'],
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
      final source = File('lib/src/engine/output.dart').readAsStringSync();
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
          if (target.startsWith('package:rk/')) continue;
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

  group('phase 4 — the comparator, worn by rk verify', () {
    late Directory scratch;

    setUpAll(() => scratch = Directory.systemTemp.createTempSync('rk-phase4-'));
    tearDownAll(() => scratch.deleteSync(recursive: true));

    test('one comparator, used by verify — release joins it in phase 5', () {
      expect(
        File('lib/src/commands/verify.dart').readAsStringSync(),
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
    });

    test('sources are resolved at the ref, not the worktree', () {
      // source_tree_test proves GitTreeAtRef against real repositories:
      // reads at the tag while the worktree has moved on, byte-safe reads,
      // nothing uncommitted visible.
      expect(fileExists('test/source_tree_test.dart'), isTrue);
      expect(
        File('lib/src/commands/verify.dart').readAsStringSync(),
        contains('treeAt('),
      );
    });

    test(
        'DONE WHEN, refusal half: a version that is not published is '
        'refused with the reason, in data', () {
      // Executable against real pub.dev: this package name has never been
      // published, so verify must refuse — and must say "not published",
      // never fabricate a pass.
      final repo = Rk.repository(scratch, 'unpublished', {
        'release.toml': '''
schema = 1

[release.lib]
publish = ["pub.dev"]
''',
        'pubspec.yaml': 'name: rk_conformance_never_published\n'
            'version: 1.0.0\n',
        'CHANGELOG.md': '## 1.0.0\n',
      });
      repo.commit();
      Process.runSync('git', ['tag', 'v1.0.0'], workingDirectory: repo.root);

      final run = repo(['verify', '--json']);
      expect(run.code, 1, reason: run.all);
      expect(
        run.problems.map((p) => p['code']),
        contains('RK-VER-003'),
        reason: 'nothing to verify is a refusal, not a quiet pass',
      );
    });

    test('a missing tag is no provenance, said plainly', () {
      final repo = Rk.repository(scratch, 'untagged', {
        'release.toml': '''
schema = 1

[release.lib]
publish = ["pub.dev"]
''',
        'pubspec.yaml': 'name: rk_conformance_never_published\n'
            'version: 1.0.0\n',
      });
      repo.commit(); // no tag

      final run = repo(['verify', '--json']);
      expect(run.code, 1);
      expect(run.problems.map((p) => p['code']), contains('RK-VER-001'));
      expect(
        run.all,
        contains('--at='),
        reason: 'the way out is named for a release under an older scheme',
      );
    });

    test('DONE WHEN, proof half: recorded checkpoint against real keybay', () {
      // The exact-path proof runs against the real repository and live
      // pub.dev — a checkpoint run recorded in doc/plan.md, per the phase 3
      // precedent, because pinning a test to a third-party service verifying
      // real content is a test that fails for reasons nobody here caused.
      expect(
        File('doc/plan.md').readAsStringSync(),
        contains('Phase 4 checkpoint'),
        reason: 'the checkpoint run must be recorded, with its output',
      );
    });
  });

  group('phase 5 — rk release for pub.dev', () {
    // Executed at the command layer with an evolving world: the acts change
    // the same fake registry and tag set the next inspection reads, which is
    // what lets a re-run be the resume. Real pub.dev cannot be published to
    // from a test, so the live half of the DONE WHEN is a recorded
    // checkpoint, red below until the real publish lands.
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
      final git = GitState(
        root: '/repo',
        head: '9f2c1ab',
        branch: 'main',
        isClean: true,
        uncommitted: const [],
        headIsPushed: true,
        tags: tags.toList(),
        tagTargets: {for (final t in tags) t: '9f2c1ab'},
        signingConfigured: true,
        originUrl: 'example/keybay',
      );
      final tools = RecordingTools(
        results: results,
        onRun: (key) {
          // A successful push is what puts a tag on origin — the same set
          // feeds the next run's local tags and the remote's answer, which
          // is exactly the world after a push: everyone can see it.
          if (key == 'git push origin v0.2.0' &&
              (results[key]?.exitCode ?? 0) == 0) {
            tags.add('v0.2.0');
          }
          onRun?.call(key);
        },
        // Origin answers from the world: a tag the world holds is listed,
        // one it does not is not — the remote leg reads reality, and this is
        // the reality the drive maintains.
        answers: (key) => key == 'git ls-remote origin refs/tags/v0.2.0'
            ? ToolResult(
                exitCode: 0,
                stdout:
                    tags.contains('v0.2.0') ? 'deadbeef refs/tags/v0.2.0' : '',
                stderr: '',
              )
            : null,
      );
      final output =
          Output(sink: buffer.write, isTerminal: false, useColor: false);

      var code = ExitCodes.refused;
      Object? died;
      try {
        code = await ReleaseCommand(
          resolution: resolution,
          tree: tree,
          git: git,
          registry: registry,
          inspector: Inspector(registry: registry, git: git),
          comparator: Comparator(tools: const SystemTools()),
          tools: tools,
          output: output,
          confirm: (_) async => '0.2.0',
          wait: (_) async {},
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

    test('tag step with inspect, act, verify', () {
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
        contains('RK-VER-006'),
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

    test(
        'DONE WHEN, live half: recorded checkpoint of the real keybay '
        'publish', () {
      // Red until keybay core publishes through rk for real — a permanent,
      // outward-facing act that belongs to the operator at a terminal. This
      // test is the forcing function that keeps the phase honest about it.
      expect(
        File('doc/plan.md').readAsStringSync(),
        contains('\n## Phase 5 checkpoint'),
        reason: 'the live publish must be recorded, with its output — and '
            'the anchor is a heading at line start, because the plan\'s own '
            'instruction text mentioning the phrase turned this gate green '
            'before the act it forces: the displaced-string anti-pattern, '
            'third appearance, in the gate guarding the most consequential '
            'claim',
      );
    });

    test('resume skips what reality says is done', () {
      expect(sourceContains('isExact'), isTrue);
    });
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
        contains('nobody is here to confirm, so nothing was written'),
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

  group('phase 7a — the local chain', () {
    late Directory scratch;

    setUpAll(() => scratch = Directory.systemTemp.createTempSync('rk-7a-'));
    tearDownAll(() => scratch.deleteSync(recursive: true));

    /// Drives a full binary-unit release at the command layer, with tools
    /// scripted by prefix and the compiler's output written where the
    /// workspace says. Returns the run and the calls.
    Future<({int code, String text, List<String> calls})> binaryDrive({
      required bool rehearse,
      Set<String> remoteTags = const {},
    }) async {
      final root = Directory('${scratch.path}/drive-${rehearse ? 'r' : 'f'}')
        ..createSync(recursive: true);
      final buffer = StringBuffer();
      final diagnostics = Diagnostics();
      final config = ReleaseConfig.parse('''
schema = 1

[release.cli]
path = "packages/tool"
publish = ["github-release"]
binary_platforms = ["macos-arm64"]

[identity]
apple_team = "TEAM123456"
code_id = "com.example.tool"
''', 'release.toml', diagnostics)!;
      final tree = MemorySourceTree({
        'packages/tool/pubspec.yaml': '''
name: tool
version: 1.0.0
publish_to: none
executables:
  tool: tool
''',
        'packages/tool/CHANGELOG.md': '## 1.0.0\n',
      }, description: '$root/tool');
      final resolution = Resolution.resolve(config, tree, diagnostics)!;
      final git = GitState(
        root: root.path,
        head: '9f2c1ab',
        branch: 'main',
        isClean: true,
        uncommitted: const [],
        headIsPushed: true,
        tags: const [],
        signingConfigured: true,
        originUrl: 'example/tool',
      );
      final binaryPath =
          '${root.path}/.rk/work/v1.0.0-9f2c1ab/macos-arm64/tool';

      final pushed = <String>{...remoteTags};
      var released = false;
      final tools = RecordingTools(
        onRun: (key) {
          if (key.startsWith('git push origin ')) {
            pushed.add(key.substring('git push origin '.length));
          }
          if (key.startsWith('gh release create')) released = true;
          if (key.startsWith('dart compile exe')) {
            File(binaryPath)
              ..parent.createSync(recursive: true)
              ..writeAsBytesSync('BINARY 1.0.0'.codeUnits);
          }
          if (key.startsWith('ditto')) {
            File('$binaryPath.zip')
              ..parent.createSync(recursive: true)
              ..writeAsBytesSync('ZIP'.codeUnits);
          }
        },
        answers: (key) {
          if (key.startsWith('git ls-remote origin refs/tags/')) {
            final tag = key.substring('git ls-remote origin refs/tags/'.length);
            return ToolResult(
              exitCode: 0,
              stdout: pushed.contains(tag) ? 'dead refs/tags/$tag' : '',
              stderr: '',
            );
          }
          if (key.startsWith('codesign --test-requirement')) {
            return ToolResult(exitCode: 1, stdout: '', stderr: 'no');
          }
          if (key.startsWith('codesign -d -r-')) {
            return ToolResult(
              exitCode: 0,
              stdout: 'designated => leaf "A"',
              stderr: '',
            );
          }
          if (key.startsWith('security find-identity')) {
            return ToolResult(
              exitCode: 0,
              stdout: '1) X "Developer ID Application: D (TEAM123456)"',
              stderr: '',
            );
          }
          if (key.startsWith('xcrun notarytool submit')) {
            return ToolResult(
              exitCode: 0,
              stdout: '{"id": "s-1", "status": "Accepted"}',
              stderr: '',
            );
          }
          if (key.contains('--version')) {
            return ToolResult(exitCode: 0, stdout: '1.0.0', stderr: '');
          }
          if (key ==
              'gh release list --repo example/tool --limit 100 '
                  '--json tagName,isDraft,name') {
            return ToolResult(exitCode: 0, stdout: '[]', stderr: '');
          }
          if (key.startsWith('gh release view')) {
            // The forge answers from the world: nothing before the create,
            // the finished release after it.
            return released
                ? ToolResult(
                    exitCode: 0,
                    stdout: '{"tagName":"v1.0.0","isDraft":false,'
                        '"name":"v1.0.0",'
                        '"assets":[{"name":"tool-1.0.0-macos-arm64.tar.gz"},'
                        '{"name":"SHA256SUMS"}]}',
                    stderr: '',
                  )
                : ToolResult(
                    exitCode: 1, stdout: '', stderr: 'release not found');
          }
          if (key.startsWith('gh repo view')) {
            return ToolResult(
                exitCode: 0, stdout: '{"name":"tool"}', stderr: '');
          }
          return null;
        },
      );

      final output =
          Output(sink: buffer.write, isTerminal: false, useColor: false);
      final registry = FakeRegistry({});
      final code = await ReleaseCommand(
        resolution: resolution,
        tree: tree,
        git: git,
        registry: registry,
        inspector: Inspector(
          registry: registry,
          git: git,
          tools: tools,
          repository: 'example/tool',
        ),
        comparator: Comparator(tools: const SystemTools()),
        tools: tools,
        output: output,
        confirm: (_) async => '1.0.0',
        rehearse: rehearse,
        wait: (_) => Future<void>.delayed(Duration.zero),
      ).run(only: 'cli');
      return (code: code, text: buffer.toString(), calls: tools.calls);
    }

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
        File('lib/src/commands/binary_chain.dart').readAsStringSync(),
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

      final run = await binaryDrive(rehearse: false);
      expect(run.code, 0, reason: run.text);
      // Every stage of the chain acted, separately, in checklist order.
      final order = [
        'dart compile exe',
        'codesign --force',
        'ditto',
        'xcrun notarytool submit',
        'gh release create',
      ];
      var at = -1;
      for (final prefix in order) {
        final index = run.calls.indexWhere((c) => c.startsWith(prefix));
        expect(index, greaterThan(at), reason: '$prefix in order');
        at = index;
      }
      expect(run.text, contains('2 assets, immutable'));
      expect(run.text, contains('released'));
    });

    test(
        'DONE WHEN, rehearse half: every local step runs for real and '
        'nothing public is touched', () async {
      final run = await binaryDrive(rehearse: true);

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
          reason: '$local ran for real — the rehearsal exists so an expired '
              'certificate is found on a quiet afternoon',
        );
      }
      for (final public in ['git tag', 'git push', 'gh release create']) {
        expect(
          run.calls.any((c) => c.startsWith(public)),
          isFalse,
          reason: '$public is public and a rehearsal never touches it',
        );
      }
      expect(run.text, contains('rehearsed'));
      expect(run.text, contains('nothing public changed'));
    });
  });
}
