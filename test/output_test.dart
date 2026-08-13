import 'dart:convert';

import 'package:release_kit/src/engine/diagnostic.dart';
import 'package:release_kit/src/engine/verdict.dart';
import 'package:release_kit/src/engine/checklist.dart';
import 'package:release_kit/src/engine/publish_target.dart';
import 'package:release_kit/src/output/output.dart';
import 'package:test/test.dart';

/// Captures what rk would print, so the contract can be asserted rather than
/// eyeballed.
class Captured {
  final StringBuffer buffer = StringBuffer();
  String get text => buffer.toString();
  List<String> get lines =>
      text.split('\n').where((l) => l.isNotEmpty).toList();
}

(Output, Captured) make({
  bool isTerminal = false,
  int? terminalWidth,
}) {
  final captured = Captured();
  final output = Output(
    sink: captured.buffer.write,
    isTerminal: isTerminal,
    useColor: false,
    terminalWidth: terminalWidth,
  );
  return (output, captured);
}

String withoutControls(String text) =>
    text.replaceAll(RegExp('\x1b\\[[0-9;]*[A-Za-z]'), '').replaceAll('\r', '');

void main() {
  test('public steps preserve concrete target identity in JSON', () {
    final (out, _) = make();
    out.step(
      Step(
        id: 'core/pub.dev/core@1.2.3',
        kind: StepKind.publishRegistry,
        target: PublishTarget.pubDev,
        unit: 'core',
        project: 'core',
        summary: 'publish core 1.2.3 to pub.dev',
        needs: const [],
      ),
      show: false,
    );

    final document = out.report.encode(exit: 0);
    expect(document, contains('"kind": "publishRegistry"'));
    expect(document, contains('"target": "pubDev"'));
  });

  test('a problem printed while a step is running survives it', () {
    // The regression that reverted the grouped live board: producers print
    // nothing but diagnostics now, and a transient region that erased what
    // sat above it deleted the only account of why a release stopped.
    final buffer = StringBuffer();
    final output = Output(
      sink: buffer.write,
      isTerminal: true,
      useColor: false,
      terminalWidth: 80,
    );

    final activity = output.begin(
      Step(
        id: 'cli/build/macos-arm64',
        kind: StepKind.build,
        unit: 'cli',
        summary: 'build tool for macos-arm64',
        needs: const [],
      ),
    );
    output.problem(
      Diagnostic(
        code: 'RK-BUILD-001',
        message: 'macos-arm64: the build did not produce a working binary',
        remedy: 'see the compiler output',
      ),
      unit: 'cli',
    );
    activity.failed('the build failed');
    output.close();

    expect(buffer.toString(), isNot(contains('RK-BUILD-001')));
    expect(
      (jsonDecode(output.report.encode(exit: 1))['problems'] as List)
          .single['code'],
      'RK-BUILD-001',
    );
    expect(buffer.toString(), contains('did not produce a working binary'));
    expect(buffer.toString(), contains('see the compiler output'));
  });

  test('a plain line carries no glyph', () {
    final (out, captured) = make();
    out.line('core', note: '0.2.0 published');
    expect(captured.lines.single, '  core             0.2.0 published');
  });

  test('marks lead the line rather than trailing it', () {
    final (out, captured) = make();
    out.line('published', mark: Mark.done);
    expect(captured.lines.single, '✓ published');
  });

  test('depth indents the tree', () {
    final (out, captured) = make();
    out.line('cli', depth: 0);
    out.line('pub.dev', depth: 1);
    expect(
        captured.lines[0].indexOf('cli'),
        lessThan(
          captured.lines[1].indexOf('pub.dev'),
        ));
  });

  group('non-terminal output is append-only', () {
    test('progress prints nothing at all', () {
      final (out, captured) = make(isTerminal: false);
      out.progress('building linux-x64');
      expect(captured.text, isEmpty, reason: 'a pipe sees no spinner');
    });

    test('and no cursor movement is emitted', () {
      final (out, captured) = make(isTerminal: false);
      out.progress('building');
      out.line('built', mark: Mark.done);
      expect(captured.text, isNot(contains('\r')));
      expect(captured.text, isNot(contains('\x1b')));
    });

    test('and settled rows are not reformatted to an invented width', () {
      final (out, captured) = make(isTerminal: false);
      const row = 'a deliberately long machine-readable line stays one line';
      out.say(row);
      expect(captured.lines, ['  $row']);
    });
  });

  group('terminal output is transient', () {
    test('progress writes, then is cleared by the next line', () {
      final (out, captured) = make(isTerminal: true);
      out.progress('building linux-x64');
      expect(captured.text, contains('building linux-x64'));
      out.line('built', mark: Mark.done);
      expect(
        captured.text,
        contains('\r'),
        reason: 'the transient line is erased rather than left behind',
      );
    });

    test('a concurrent target list is fixed, updated, then erased', () async {
      final (out, captured) = make(isTerminal: true);
      final checks = out.targetChecks(delay: Duration.zero);
      checks
        ..add('tag', 'Git tag')
        ..add('pub', 'pub.dev');
      await Future<void>.delayed(const Duration(milliseconds: 1));

      expect(captured.text, contains('Release targets'));
      expect(captured.text, contains('Git tag'));
      expect(captured.text, contains('pub.dev'));
      checks.finish('pub', Verdict.exact);
      checks.close();

      expect(captured.text, contains('checked'));
      expect(captured.text, contains('\x1b[1A'));
    });

    for (final width in [52, 36]) {
      test('target rows fit and erase exactly at $width columns', () async {
        final (out, captured) = make(
          isTerminal: true,
          terminalWidth: width,
        );
        final checks = out.targetChecks(delay: Duration.zero);
        checks
          ..add('tag', 'Git tag')
          ..add('pub', 'pub.dev · release_kit')
          ..add(
            'github',
            'GitHub Release · danReynolds/release-kit',
          );
        await Future<void>.delayed(const Duration(milliseconds: 1));

        checks.finish('github', Verdict.exact);
        checks.close();

        final visibleLines = withoutControls(captured.text)
            .split('\n')
            .where((line) => line.isNotEmpty);
        expect(
          visibleLines.every((line) => line.runes.length <= width),
          isTrue,
          reason: 'a transient logical row must not wrap into two physical '
              'rows or cursor-up will leave a stale fragment',
        );
        expect(withoutControls(captured.text), contains('…'));
        final erase = '\x1b[1A\r\x1b[2K';
        expect(
          captured.text,
          endsWith(List.filled(4, erase).join()),
          reason: 'the four fixed physical rows are completely erased',
        );
      });
    }
  });

  test('colour is off when asked, and never the only signal', () {
    final (out, captured) = make();
    out.line('failed', mark: Mark.blocked);
    expect(captured.text, isNot(contains('\x1b')));
    expect(captured.text, contains('✗'));
  });

  test('settled rows use readable hanging indentation on a narrow terminal',
      () {
    final captured = Captured();
    final out = Output(
      sink: captured.buffer.write,
      isTerminal: true,
      useColor: true,
      terminalWidth: 36,
    );

    out.line(
      'GitHub Release',
      mark: Mark.blocked,
      note: '0.1.0 › 0.2.0 · public history could not be read',
      depth: 2,
      tone: Tone.bad,
      noteTone: Tone.attention,
    );

    final visible = withoutControls(captured.text)
        .split('\n')
        .where((line) => line.isNotEmpty)
        .toList();
    expect(visible.every((line) => line.runes.length <= 36), isTrue);
    expect(visible.first, startsWith('✗     GitHub Release'));
    expect(
        visible.skip(1).every((line) => line.startsWith('        ')), isTrue);
    expect(
      visible.join(' ').replaceAll('✗', '').split(RegExp(r'\s+')).where(
            (word) => word.isNotEmpty,
          ),
      [
        'GitHub',
        'Release',
        '0.1.0',
        '›',
        '0.2.0',
        '·',
        'public',
        'history',
        'could',
        'not',
        'be',
        'read',
      ],
      reason: 'wrapping may move words, never omit or reorder them',
    );
    for (final line
        in captured.text.split('\n').where((line) => line.isNotEmpty)) {
      expect(line, endsWith('\x1b[0m'),
          reason: 'each painted physical row closes its ANSI span');
    }
  });

  group('halts open with the sentence, not the noun', () {
    test('no public target changed', () {
      final (out, captured) = make();
      out.halt(HaltKind.beforeActing);
      expect(captured.text, contains('no public target changed'));
      expect(captured.text, contains('safe to re-run'));
    });

    test('something may have happened', () {
      final (out, captured) = make();
      out.halt(HaltKind.lostTrack);
      expect(captured.text, contains('an effect may exist'));
    });

    test('re-running will not help', () {
      final (out, captured) = make();
      out.halt(HaltKind.unfixableByRerun);
      expect(captured.text, contains('cannot be fixed by re-running'));
    });
  });

  group('problems', () {
    final diagnostic = Diagnostic(
      code: 'RK-CONF-019',
      message: 'a project in "core" does not say where to publish',
      source: SourceLocation('release.toml', 4),
      remedy: 'add publish = ["git-tag", "pub.dev"]',
    );

    test('lead with where and what, and carry the fix', () {
      final (out, captured) = make();
      out.problem(diagnostic);
      expect(captured.text, contains('release.toml:4'));
      expect(captured.text, contains('does not say where to publish'));
      expect(captured.text, contains('add publish'));
    });

    test('hide the code from prose and preserve it in JSON', () {
      final (out, captured) = make();
      out.problem(diagnostic);
      expect(captured.text, isNot(contains('RK-CONF-019')));
      final json = jsonDecode(out.report.encode(exit: 1)) as Map;
      expect(((json['problems'] as List).single as Map)['code'], 'RK-CONF-019');
    });

    test('are reported in one pass', () {
      final (out, captured) = make();
      out.problems([
        diagnostic,
        Diagnostic(code: 'RK-CONF-003', message: 'unknown setting "toolchain"'),
      ]);
      expect(captured.lines.where((l) => l.contains('✗')), hasLength(2));
    });
  });

  test('warnings use a distinct nonblocking mark and machine collection', () {
    final (out, captured) = make();
    out.warning(const Diagnostic(
      code: 'RK-GIT-001',
      message: '1 uncommitted path will be included',
    ));
    expect(captured.lines.single, '! 1 uncommitted path will be included');
    expect(captured.text, isNot(contains('RK-GIT-001')));
    final json = jsonDecode(out.report.encode(exit: 0)) as Map;
    expect(((json['warnings'] as List).single as Map)['code'], 'RK-GIT-001');
    expect(json['problems'], isEmpty);
  });

  test('the next command is marked as the reader\'s move', () {
    final (out, captured) = make();
    out.next('rk release core');
    expect(captured.lines.single, contains('→'));
    expect(captured.lines.single, contains('rk release core'));
  });

  test('exit codes follow the contract', () {
    expect(ExitCodes.ok, 0, reason: 'blocked is a state, not a failure');
    expect(ExitCodes.refused, 1);
    expect(ExitCodes.usage, 2);
  });
}
