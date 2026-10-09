import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/unit_release.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/output/report.dart';
import 'package:test/test.dart';

import 'support/memory_source_tree.dart';

Map<String, Object?> decode(Report report, {int exit = 0}) =>
    jsonDecode(report.encode(exit: exit)) as Map<String, Object?>;

/// A release to record steps from: one package, published to pub.dev once
/// its stage is complete.
final release = () {
  final diagnostics = Diagnostics();
  final resolution = Resolution.resolve(
    ReleaseConfig.parse(
      'schema = 2\n\n[release.core]\npublish = ["pub.dev"]\n',
      'release.toml',
      diagnostics,
    )!,
    MemorySourceTree({'pubspec.yaml': 'name: core\nversion: 1.2.3\n'}),
    diagnostics,
  )!;
  return UnitRelease.derive(
    resolution.unit('core')!,
    resolution,
    repository: null,
    problems: diagnostics,
  );
}();

void main() {
  test('a crash after a release staged privately says nothing public '
      'changed', () {
    // Staging writes a stage, which sets acted; a halt in a release speaks
    // of public targets, and none changed until one is published.
    final release = Report('release')..acted = true;
    expect(release.changedWhatHaltsSpeakOf, isFalse);
    release.publicChanged = true;
    expect(release.changedWhatHaltsSpeakOf, isTrue);
    // init, clean and use write files, and those are what a halt speaks of.
    expect((Report('init')..acted = true).changedWhatHaltsSpeakOf, isTrue);
  });

  group('the document a caller keys on', () {
    test('names its schema, its command, and how the process ended', () {
      final report = Report('status');
      final json = decode(report, exit: 1);
      expect(json['rk'], Report.schema);
      expect(json['command'], 'status');
      expect(
        json['exit'],
        1,
        reason: 'a caller that captured only stdout still knows',
      );
    });

    test('steps are keyed by id and carry their order', () {
      final report = Report('status')
        ..unit(name: 'core', version: '1.2.3', tag: null)
        ..step(release.barrier)
        ..step(release.packages.single);

      final units = decode(report)['units'] as List;
      final steps = (units.single as Map)['steps'] as List;
      expect((steps[0] as Map)['id'], release.barrier.id);
      expect((steps[1] as Map)['needs'], contains(release.barrier.id));
    });

    test('a step names its own unit, so order of calls does not matter', () {
      final report = Report('status')
        ..step(release.barrier)
        ..unit(name: 'core', version: '1.2.3', tag: null);

      final unit = (decode(report)['units'] as List).single as Map;
      expect(unit['version'], '1.2.3');
      expect((unit['steps'] as List), hasLength(1));
    });

    test('every step states a verdict, and unknown is stated', () {
      final report = Report('status')..step(release.barrier);
      final steps =
          ((decode(report)['units'] as List).single as Map)['steps'] as List;
      expect(
        (steps.single as Map)['verdict'],
        'unknown',
        reason:
            'an absent key invites reading it as "nothing is there", '
            'which is the one collapse rk must never make',
      );
    });
  });

  group('rerun_helps is the one rerun question', () {
    test('true by default, because re-running is the resume', () {
      expect(decode(Report('release'))['rerun_helps'], isTrue);
    });

    test('a conflict does not help, and the halt says why', () {
      final report = Report('release')..halt(HaltKind.unfixableByRerun);
      expect(decode(report)['rerun_helps'], isFalse);
      expect((decode(report)['halt'] as Map)['kind'], 'unfixableByRerun');
    });

    test('helps cannot be talked back up', () {
      final report = Report('release')
        ..halt(HaltKind.actedAndUnfixable)
        ..halt(HaltKind.beforeActing);
      expect(
        decode(report)['rerun_helps'],
        isFalse,
        reason: 'the worst answer of the run is the answer for the run',
      );
    });
  });

  test('a problem carries the code the prose hides', () {
    final report = Report('status')
      ..problem(
        Diagnostic(
          code: 'RK-DEP-001',
          message: 'the pin does not match',
          source: SourceLocation('pubspec.yaml', 4),
          remedy: 'align the constraint',
        ),
      );
    final problem = (decode(report)['problems'] as List).single as Map;
    expect(problem['code'], 'RK-DEP-001');
    expect(problem['source'], 'pubspec.yaml:4');
    expect(problem['remedy'], 'align the constraint');
  });

  test('the top-level keys keep their documented order', () {
    // Recorded out of order: the document's order is its own.
    final report = Report('release')
      ..section('release_choices', const [])
      ..section('installations', const {})
      ..section('plan', const {})
      ..section('cleanup', const {})
      ..section('init', const {})
      ..repository(name: 'tool')
      ..next('rk release')
      ..attach('notes', 'text')
      ..diagnosis = '.rk/diagnosis/now'
      ..halt(HaltKind.beforeActing);
    expect(decode(report).keys, [
      'rk',
      'command',
      'observed_at',
      'exit',
      'rerun_helps',
      'repository',
      'init',
      'cleanup',
      'plan',
      'installations',
      'release_choices',
      'units',
      'problems',
      'warnings',
      'next',
      'attachments',
      'diagnosis',
      'halt',
    ]);
  });

  test('the next command is data a caller can chain on', () {
    final report = Report('status')..next('rk release cli');
    expect(decode(report)['next'], ['rk release cli']);
  });

  group('the diagnosis directory', () {
    group('write policy', () {
      test('plan never leaves repository-local evidence, even on a crash', () {
        expect(Report('plan').keepsDiagnosis(crashed: true), isFalse);
        expect(
          (Report('plan')..acted = true).keepsDiagnosis(crashed: true),
          isFalse,
          reason:
              'the read-only verb stays write-free even under an '
              'impossible acted flag',
        );
      });

      test('other commands retain crashes and acted failures only', () {
        expect(
          Report('status').keepsDiagnosis(crashed: true),
          isTrue,
          reason: 'a crash stack is otherwise lost',
        );
        expect(
          (Report('release')..acted = true).keepsDiagnosis(crashed: false),
          isTrue,
          reason: 'an interrupted effect needs a receipt of what happened',
        );
        expect(
          Report('release').keepsDiagnosis(crashed: false),
          isFalse,
          reason:
              'an ordinary pre-act refusal already said everything it knows',
        );
      });
    });

    test('holds what the run saw, under the stamp it was given', () {
      final root = Directory.systemTemp.createTempSync('rk-diag-');
      addTearDown(() => root.deleteSync(recursive: true));
      final report = Report('release')
        ..unit(name: 'core', version: '1.2.3', tag: null)
        ..step(release.barrier, verdict: Verdict.conflict)
        ..attach('notarytool.stderr', 'Invalid credentials');

      final at = report.writeDiagnosis(
        root.path,
        stamp: '2026-07-29T12-00-00',
        exit: 1,
        crash: 'the stack',
      );

      expect(at, contains('2026-07-29T12-00-00'));
      expect(report.diagnosis, at);
      final run = File('$at/run.json').readAsStringSync();
      expect(run, contains('"verdict": "conflict"'));
      expect(run, contains('"exit": 1'));
      expect(
        File('$at/notarytool.stderr').readAsStringSync(),
        'Invalid credentials',
        reason: 'native tool stderr is the diagnosis, not a summary of it',
      );
      expect(File('$at/crash.txt').readAsStringSync(), 'the stack');
    });

    test('a finding files its own account, and names it', () {
      final report = Report('release')
        ..problem(
          const Diagnostic(
            code: 'RK-BUILD-001',
            message: 'macos-arm64: the build did not produce a working binary',
            evidence: 'exit 1\n--- stderr ---\nlib/a.dart:3:5: Error: nope',
          ),
        );

      final problem =
          (jsonDecode(report.encode(exit: 1))['problems'] as List).single
              as Map;
      expect(problem['evidence'], 'tool-output/1-RK-BUILD-001.txt');
      expect(
        report.attachments['tool-output/1-RK-BUILD-001.txt'],
        contains('lib/a.dart:3:5'),
      );
    });

    test('two findings of the same kind keep both accounts', () {
      // Three platforms failing the same way carry one RK code between them.
      // A name built from the code alone would keep the last and lose the
      // rest without saying so.
      final report = Report('release');
      for (final platform in ['linux-x64', 'macos-arm64']) {
        report.problem(
          Diagnostic(
            code: 'RK-BUILD-001',
            message: '$platform: the build did not produce a working binary',
            evidence: 'the $platform compiler said this',
          ),
        );
      }

      expect(report.attachments, hasLength(2));
      expect(
        report.attachments.values,
        containsAll([contains('linux-x64'), contains('macos-arm64')]),
      );
    });

    test('a finding with nothing to file attaches nothing', () {
      final report = Report('release')
        ..problem(
          const Diagnostic(
            code: 'RK-CONF-009',
            message: 'a project does not say where to publish',
          ),
        );
      expect(report.attachments, isEmpty);
      expect(
        ((jsonDecode(report.encode(exit: 1))['problems'] as List).single
            as Map),
        isNot(contains('evidence')),
      );
    });

    test('two runs do not overwrite one another', () {
      final root = Directory.systemTemp.createTempSync('rk-diag-');
      addTearDown(() => root.deleteSync(recursive: true));
      Report('release').writeDiagnosis(root.path, stamp: 'a', exit: 1);
      Report('release').writeDiagnosis(root.path, stamp: 'b', exit: 1);
      expect(Directory('${root.path}/.rk/diagnosis').listSync(), hasLength(2));
    });
  });
}
