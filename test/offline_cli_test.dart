import 'dart:io';

import 'package:test/test.dart';

import 'rk_process.dart';

/// Phase 1's milestone, run rather than inspected.
///
/// "rk parses the release.toml and prints the derived checklist offline" is a
/// claim about a program, so each of these copies a repository out of
/// `examples/`, makes it a repository, and runs the real executable against it.
/// The check this replaced asserted that `bin/rk.dart` *contained the string*
/// `--offline`.
///
/// The examples are named for the shape they are, never for a real project —
/// see examples/README.md for why that rule exists.
void main() {
  late Directory scratch;

  setUpAll(() => scratch = Directory.systemTemp.createTempSync('rk-offline-'));
  tearDownAll(() => scratch.deleteSync(recursive: true));

  Run offline(String shape) =>
      Rk.example(scratch, shape)(['status', '--offline']);

  /// The same run as a document. Derivation claims — ordering, dependency
  /// edges, the shape of the chain — are structural, so they are asserted on
  /// the machine surface rather than on prose that collapses for a reader.
  Run offlineJson(String shape) =>
      Rk.example(scratch, shape)(['status', '--offline', '--json']);

  group('single-package', () {
    late Run run;
    setUpAll(() => run = offline('single-package'));

    test('it succeeds', () => expect(run.code, 0, reason: run.all));

    test('one package in the repository takes the bare tag', () {
      expect(
        run.all,
        contains('v1.4.0'),
        reason: "pub.dev documents v{version} where a repository publishes one",
      );
      expect(run.all, isNot(contains('retry_helper-v1.4.0')));
    });

    test('a folded description does not swallow the version after it', () {
      expect(run.all, contains('1.4.0'));
    });
  });

  group('workspace-with-dependent', () {
    late Run run;
    setUpAll(() => run = offline('workspace-with-dependent'));

    test('it succeeds', () => expect(run.code, 0, reason: run.all));

    test('two units mean each tag names its package', () {
      expect(run.all, contains('example_core-v0.3.0'));
      expect(run.all, contains('example_cli-v0.3.0'));
    });

    test('the cross-unit dependency becomes a prerequisite', () {
      final steps = offlineJson('workspace-with-dependent').stepsOf('cli');
      expect(
        steps.map((s) => s['id']),
        contains('cli/requires/pub.dev/example_core/0.3.0'),
        reason: 'a dependency on another unit is a step, not a footnote',
      );
      expect(run.all, contains('needs'));
      expect(run.all, contains('example_core'));
    });

    test('the workspace root is not mistaken for a package', () {
      expect(run.all, isNot(contains('example_workspace')));
    });

    test('it says what it did not read, so nothing reads as done', () {
      expect(run.all, contains('derived from the manifests alone'));
      expect(run.all, contains('says what is already done'));
    });
  });

  group('multi-project-unit', () {
    late Run run;
    setUpAll(() => run = offline('multi-project-unit'));

    test('it succeeds', () => expect(run.code, 0, reason: run.all));

    test('the declared tag wins over the convention', () {
      expect(run.all, contains('framework-v0.2.0'));
    });

    test('publication order comes from the manifests, not the file', () {
      final ids = offlineJson('multi-project-unit')
          .stepsOf('framework')
          .map((s) => '${s['id']}')
          .toList();
      int at(String package) =>
          ids.indexWhere((id) => id.contains('/pub.dev/$package@'));
      expect(at('example_base'), greaterThan(-1), reason: ids.join('\n'));
      expect(at('example_base'), lessThan(at('example_middle')),
          reason: 'declaration order was reversed');
      expect(at('example_middle'), lessThan(at('example_top')),
          reason: 'a dev dependency orders too');
    });
  });

  group('escapes-repository', () {
    late Run run;
    setUpAll(() => run = offline('escapes-repository'));

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

  group('binary-cli', () {
    late Run run;
    setUpAll(() => run = offline('binary-cli'));

    test('it succeeds', () => expect(run.code, 0, reason: run.all));

    test('the binary chain is derived in full, in order', () {
      final steps = offlineJson('binary-cli').stepsOf('cli');
      final ids = steps.map((s) => '${s['id']}').toList();
      for (final expected in [
        'cli/build/linux-x64',
        'cli/build/macos-arm64',
        'cli/sign/macos-arm64',
        'cli/notarize/macos-arm64',
        'cli/archive/macos-arm64',
        'cli/checksums/SHA256SUMS',
      ]) {
        expect(ids, contains(expected), reason: ids.join('\n'));
      }
      // The reader sees the same chain folded onto one row per platform.
      expect(run.all, contains('build › sign › notarize › archive'));
    });

    test('only macOS is signed', () {
      final ids = offlineJson('binary-cli')
          .stepsOf('cli')
          .map((s) => '${s['id']}')
          .toList();
      expect(ids, isNot(contains('cli/sign/linux-x64')));
    });

    test('the formula waits for the release', () {
      final steps = offlineJson('binary-cli').stepsOf('cli');
      final formula = steps.firstWhere((s) => s['kind'] == 'publishFormula');
      final release = steps.firstWhere((s) => s['kind'] == 'publishRelease');
      expect(
        formula['needs'],
        contains(release['id']),
        reason: 'a formula pointing at an unpublished release would 404',
      );
    });
  });

  group('flags that carry no meaning here are refused, not repaired', () {
    late Rk repo;
    setUpAll(() => repo = Rk.example(scratch, 'single-package', as: 'flags'));

    test('--at on a verb that is not verify', () {
      final run = repo(['status', '--at=v1.0.0', '--json']);
      expect(run.code, 2, reason: run.all);
      expect(run.problems.map((p) => p['code']), contains('RK-CLI-005'));
    });

    test('an empty --at names no ref', () {
      final run = repo(['verify', '--at=', '--json']);
      expect(run.code, 2);
      expect(run.problems.map((p) => p['code']), contains('RK-CLI-007'));
    });

    test('a third word is refused, not silently dropped', () {
      final run = repo(['verify', 'lib', 'bogus', '--json']);
      expect(run.code, 2);
      expect(run.problems.map((p) => p['code']), contains('RK-CLI-007'));
    });
  });

  group('a repository rk has nothing to say about', () {
    test('no release.toml is not an error', () {
      final bare = Rk.repository(scratch, 'bare', {'README.md': 'nothing\n'});
      final run = bare(['status', '--offline']);
      expect(run.code, 0, reason: 'absence of intent is not a failure');
      expect(run.all, contains('release.toml'));
    });

    test('outside a repository is a usage error', () {
      final loose = Directory('${scratch.path}/loose')..createSync();
      File('${loose.path}/release.toml').writeAsStringSync('schema = 1\n');
      final run = Rk(loose.path)(['status', '--offline']);
      expect(run.code, 2, reason: run.all);
    });
  });
}
