import 'dart:io';

import 'package:rk/src/engine/output.dart';
import 'package:test/test.dart';

import 'rk_process.dart';

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
      expect(
        usedOutside('Inspector(', 'engine/inspect.dart'),
        isTrue,
        reason: 'a second implementation is a second set of answers to the '
            'same question, and they drifted before',
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

    test('identity is derived from what is published, not from the keychain',
        () {
      // identity_test drives PublishedIdentity with scripted tools: it
      // asserts the command sequence, that `security` is never consulted, and
      // that "nothing published" and "could not read" stay separate answers.
      expect(fileExists('test/identity_test.dart'), isTrue);
      expect(
        usedOutside('designatedRequirement(', 'transforms/macos.dart'),
        isTrue,
        reason: 'read from the certificate that signs, it is a tautology',
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

  group('phase 4 — rk verify', () {
    test('logical comparison of a published archive', () {
      expect(
        sourceContains('compareArchives') || sourceContains('logicalContents'),
        isTrue,
        reason: 'the checkpoint exists to prove the comparison against real '
            'published data before rk ever publishes',
      );
    });

    test('config and sources resolved at the tag', () {
      expect(
        sourceContains('atTag') || sourceContains('showAtTag'),
        isTrue,
        reason: 'verifying an old release against today\'s config is wrong',
      );
    });

    test('provenance output naming what is not knowable', () {
      expect(
        usedOutside('Provenance(', 'commands/verify.dart'),
        isTrue,
        reason: 'the class exists and is never constructed, so no release '
            'reports where it came from',
      );
    });
  });

  group('phase 5 — rk release for pub.dev', () {
    test('type-the-version confirmation for a permanent act', () {
      expect(sourceContains('type ${'\$'}{unit.version}'), isTrue);
    });

    test('tag step with inspect, act, verify', () {
      expect(sourceContains('StepKind.tag'), isTrue);
    });

    test('consumer resolve before publishing', () {
      expect(
        sourceContains('no-overrides'),
        isTrue,
        reason: 'pub excludes pubspec_overrides from the archive but honours '
            'it locally, so a dry run can pass while the published package '
            'is unresolvable for everyone else',
      );
    });

    test('post-publish re-download and compare', () {
      expect(
        sourceContains('compareArchives') || sourceContains('logicalContents'),
        isTrue,
        reason: 'confirming the version exists is not confirming the right '
            'bytes were published',
      );
    });

    test('resume skips what reality says is done', () {
      expect(sourceContains('isExact'), isTrue);
    });
  });

  group('phase 7 — binary chain', () {
    test('capability resolution per platform', () {
      expect(fileExists('lib/src/builds/capability.dart'), isTrue);
    });

    test('signing verifies against the published requirement', () {
      expect(
        usedOutside('designatedRequirement(', 'transforms/macos.dart'),
        isTrue,
        reason: 'comparing a signature to the certificate that made it '
            'proves nothing',
      );
    });

    test('deterministic archives', () {
      expect(fileExists('lib/src/transforms/archive.dart'), isTrue);
    });

    test('no state carried between steps', () {
      expect(
        File('lib/src/commands/release.dart').readAsStringSync(),
        isNot(contains('_produced')),
        reason: 'CI seam 1: a step must be executable from the checklist, its '
            'id, the workspace and reality — a field holding artifacts '
            'between steps cannot be split across machines',
      );
    });
  });
}
