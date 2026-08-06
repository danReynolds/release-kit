import 'dart:convert';
import 'dart:io';

import 'package:release_kit/src/output/diagnosis.dart';
import 'package:release_kit/src/engine/diagnostic.dart';
import 'package:release_kit/src/output/output.dart';
import 'package:release_kit/src/output/report.dart';
import 'package:test/test.dart';

Map<String, Object?> decode(Report report, {int exit = 0}) =>
    jsonDecode(report.encode(exit: exit)) as Map<String, Object?>;

void main() {
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
        ..unit(name: 'cli', version: '0.2.0', tag: 'keybay_cli-v0.2.0')
        ..step(id: 'cli/build/linux-x64', unit: 'cli', summary: 'build')
        ..step(
          id: 'cli/archive/linux-x64',
          unit: 'cli',
          summary: 'archive',
          needs: ['cli/build/linux-x64'],
        );

      final units = decode(report)['units'] as List;
      final steps = (units.single as Map)['steps'] as List;
      expect((steps[0] as Map)['id'], 'cli/build/linux-x64');
      expect((steps[1] as Map)['needs'], ['cli/build/linux-x64']);
    });

    test('a step names its own unit, so order of calls does not matter', () {
      final report = Report('status')
        ..step(id: 'cli/build/linux-x64', unit: 'cli', summary: 'build')
        ..unit(name: 'cli', version: '0.2.0', tag: 'keybay_cli-v0.2.0');

      final unit = (decode(report)['units'] as List).single as Map;
      expect(unit['version'], '0.2.0');
      expect((unit['steps'] as List), hasLength(1));
    });

    test('every step states a verdict, and unknown is stated', () {
      final report = Report('status')
        ..step(id: 'cli/build/linux-x64', unit: 'cli', summary: 'build');
      final steps =
          ((decode(report)['units'] as List).single as Map)['steps'] as List;
      expect(
        (steps.single as Map)['verdict'],
        'unknown',
        reason: 'an absent key invites reading it as "nothing is there", '
            'which is the one collapse rk must never make',
      );
    });
  });

  group('safe and helps are different questions', () {
    test('both true by default, because re-running is the resume', () {
      final json = decode(Report('release'));
      expect(json['safe_to_rerun'], isTrue);
      expect(json['rerun_helps'], isTrue);
    });

    test('a conflict is still safe to re-run — it just will not help', () {
      final report = Report('release')
        ..halt('unfixableByRerun', 'cannot be fixed', helps: false);
      expect(
        decode(report)['safe_to_rerun'],
        isTrue,
        reason: 'a second run inspects and refuses again; nothing is harmed. '
            'Reporting it unsafe tells an agent re-running may do damage.',
      );
      expect(decode(report)['rerun_helps'], isFalse);
      expect((decode(report)['halt'] as Map)['kind'], 'unfixableByRerun');
    });

    test('neither can be talked back up', () {
      final report = Report('release')
        ..halt('x', 'bad', helps: false, safe: false)
        ..halt('beforeActing', 'nothing changed', helps: true);
      final json = decode(report);
      expect(json['safe_to_rerun'], isFalse);
      expect(json['rerun_helps'], isFalse);
      expect(
        json['safe_to_rerun'],
        isFalse,
        reason: 'the worst answer of the run is the answer for the run',
      );
    });
  });

  test('a problem carries the code the prose hides', () {
    final report = Report('status')
      ..problem(Diagnostic(
        code: 'RK-DEP-001',
        message: 'the pin does not match',
        source: SourceLocation('pubspec.yaml', 4),
        remedy: 'align the constraint',
      ));
    final problem = (decode(report)['problems'] as List).single as Map;
    expect(problem['code'], 'RK-DEP-001');
    expect(problem['source'], 'pubspec.yaml:4');
    expect(problem['remedy'], 'align the constraint');
  });

  test('the next command is data a caller can chain on', () {
    final report = Report('status')..next('rk release cli');
    expect(decode(report)['next'], ['rk release cli']);
  });

  group('recording happens inside printing, so the two cannot drift', () {
    test('a problem printed is a problem reported', () {
      final output = Output(sink: (_) {}, isTerminal: false);
      output.problem(Diagnostic(code: 'RK-GIT-001', message: '2 uncommitted'));
      expect(
        decode(output.report)['problems'],
        hasLength(1),
        reason: 'there is one call, so there is nothing to forget',
      );
    });

    test('and prose suppressed is still recorded', () {
      final buffer = StringBuffer();
      final output = Output(sink: (_) {}, isTerminal: false);
      output.next('rk release cli');
      expect(buffer.toString(), isEmpty);
      expect(decode(output.report)['next'], ['rk release cli']);
    });
  });

  group('the diagnosis directory', () {
    test('holds what the run saw, under the stamp it was given', () {
      final root = Directory.systemTemp.createTempSync('rk-diag-');
      addTearDown(() => root.deleteSync(recursive: true));
      final report = Report('release')
        ..unit(name: 'cli', version: '0.2.0', tag: 'keybay_cli-v0.2.0')
        ..step(
          id: 'cli/notarize/macos-arm64',
          unit: 'cli',
          summary: 'notarize',
          verdict: 'rejected',
          took: const Duration(minutes: 4),
        );

      final at = Diagnosis.write(
        root.path,
        stamp: '2026-07-29T12-00-00',
        report: report,
        exit: 1,
        attachments: {'notarytool.stderr': 'Invalid credentials'},
      );

      expect(at, contains('2026-07-29T12-00-00'));
      final run = File('$at/run.json').readAsStringSync();
      expect(run, contains('"verdict": "rejected"'));
      expect(run, contains('"took_ms": 240000'), reason: 'durations');
      expect(run, contains('"exit": 1'));
      expect(
        File('$at/notarytool.stderr').readAsStringSync(),
        'Invalid credentials',
        reason: 'native tool stderr is the diagnosis, not a summary of it',
      );
    });

    test('two runs do not overwrite one another', () {
      final root = Directory.systemTemp.createTempSync('rk-diag-');
      addTearDown(() => root.deleteSync(recursive: true));
      Diagnosis.write(root.path,
          stamp: 'a', report: Report('release'), exit: 1);
      Diagnosis.write(root.path,
          stamp: 'b', report: Report('release'), exit: 1);
      expect(
        Directory('${root.path}/.rk/diagnosis').listSync(),
        hasLength(2),
      );
    });
  });
}
