import 'dart:io';

import 'package:test/test.dart';

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
  final lib = Directory('lib');

  /// Whether any source under lib/ contains [pattern].
  bool sourceContains(String pattern) => lib
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .any((f) => f.readAsStringSync().contains(pattern));

  bool fileExists(String path) => File(path).existsSync();

  /// Whether [pattern] appears in a file other than [definedIn].
  ///
  /// A definition is not a use: matching the declaration of the very thing
  /// being checked is how a conformance test passes while the feature is
  /// unwired, which is the failure this file exists to prevent.
  bool usedOutside(String pattern, String definedIn) => lib
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart') && !f.path.endsWith(definedIn))
      .any((f) => f.readAsStringSync().contains(pattern));

  /// Whether the CLI accepts [flag].
  bool cliAccepts(String flag) =>
      File('bin/rk.dart').readAsStringSync().contains("'$flag'");

  group('phase 1 — engine core', () {
    test('strict TOML subset parser', () {
      expect(fileExists('lib/src/engine/toml.dart'), isTrue);
    });

    test('pubspec reader covers name, version, publish_to, executables, '
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
      expect(sourceContains('tagPattern'), isTrue);
      expect(sourceContains('_derivedTagPattern'), isTrue);
    });

    test('checklist derivation with ordering and prerequisites', () {
      final source = File('lib/src/engine/checklist.dart').readAsStringSync();
      expect(source, contains('_publicationOrder'));
      expect(source, contains('externalPrerequisites'));
    });

    test('fixtures for the three repository shapes', () {
      // keybay-shaped, fleury-shaped, and dune-shaped, the last of which must
      // be refused rather than released.
      final tests = Directory('test')
          .listSync()
          .whereType<File>()
          .map((f) => f.readAsStringSync())
          .join();
      expect(tests, contains('keybay'), reason: 'keybay-shaped');
      expect(tests, contains('fleury'), reason: 'fleury-shaped');
      expect(tests, contains('dune'), reason: 'dune-shaped');
      expect(tests, contains('RK-DART-201'), reason: 'dune is refused');
    });

    test('DONE WHEN: the derived checklist can be printed offline', () {
      // The phase 1 milestone: the engine produces a checklist without a
      // network, and something can show it.
      expect(
        cliAccepts('--offline'),
        isTrue,
        reason: 'no command renders the checklist without touching the '
            'network, so phase 1 cannot be demonstrated on its own',
      );
    });
  });

  group('phase 2 — output', () {
    test('collapse, terseness, and the four-glyph gutter', () {
      final source = File('lib/src/engine/output.dart').readAsStringSync();
      for (final glyph in ['✓', '·', '✗', '→']) {
        expect(source, contains(glyph));
      }
    });

    test('non-TTY output is append-only', () {
      expect(fileExists('test/output_test.dart'), isTrue);
      expect(
        File('test/output_test.dart').readAsStringSync(),
        contains('append-only'),
      );
    });

    test('halt sentences, conflict evidence, remediation', () {
      final source = File('lib/src/engine/output.dart').readAsStringSync();
      expect(source, contains('HaltKind'));
      expect(sourceContains('evidence'), isTrue);
      expect(source, contains('remedy'));
    });

    test('liveness: a running step expands, a finished one collapses', () {
      expect(
        sourceContains('elapsed'),
        isTrue,
        reason: 'a step that waits on a third party must show how long it '
            'has waited, or a wait reads as a hang',
      );
    });

    test('--json, stable and surviving a non-zero exit', () {
      expect(cliAccepts('--json'), isTrue, reason: 'the flag is accepted');
      expect(
        sourceContains('safe_to_rerun'),
        isTrue,
        reason: 'the agent contract: a caller decides whether to retry from '
            'data rather than by parsing prose',
      );
    });

    test('diagnostic codes and the diagnosis directory', () {
      expect(sourceContains('RK-'), isTrue, reason: 'codes');
      expect(
        sourceContains('diagnosis'),
        isTrue,
        reason: 'reality records what exists and nothing about why a run '
            'failed',
      );
    });
  });

  group('phase 3 — probes and rk status', () {
    test('pub.dev client with no dependencies', () {
      expect(fileExists('lib/src/engine/registry.dart'), isTrue);
      expect(
        File('pubspec.yaml').readAsStringSync(),
        isNot(contains('\ndependencies:')),
        reason: 'zero runtime dependencies',
      );
    });

    test('git state: tags, cleanliness, HEAD vs remote', () {
      final source = File('lib/src/engine/git.dart').readAsStringSync();
      expect(source, contains('tags'));
      expect(source, contains('isClean'));
      expect(source, contains('headIsPushed'));
    });

    test('verdicts, including the definitive-negative rule', () {
      expect(fileExists('lib/src/engine/verdict.dart'), isTrue);
      expect(
        File('lib/src/engine/registry.dart').readAsStringSync(),
        contains('404'),
        reason: 'absent is concluded only from an authenticated negative',
      );
    });

    test('GitHub read API for releases and assets', () {
      expect(
        File('lib/src/commands/status.dart').readAsStringSync(),
        contains('GithubRelease('),
        reason: 'rk status must read the forge, or a unit shipping a release '
            'is reported on without its main channel being consulted',
      );
    });

    test('identity derivation from the last published release', () {
      expect(
        usedOutside('designatedRequirement(', 'transforms/macos.dart'),
        isTrue,
        reason: 'identity read from the certificate that signs is a '
            'tautology; it must come from what is already published',
      );
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
