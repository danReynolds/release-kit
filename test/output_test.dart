import 'dart:convert';

import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/unit_release.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/output/progress.dart';
import 'package:test/test.dart';

/// Captures what rk would print, so the contract can be asserted rather than
/// eyeballed.
class Captured {
  final StringBuffer buffer = StringBuffer();
  String get text => buffer.toString();
  List<String> get lines =>
      text.split('\n').where((l) => l.isNotEmpty).toList();
}

(Output, Captured) make({bool isTerminal = false, int? terminalWidth}) {
  final captured = Captured();
  final output = Output(
    sink: captured.buffer.write,
    isTerminal: isTerminal,
    useColor: false,
    terminalWidth: terminalWidth ?? (isTerminal ? 80 : null),
  );
  return (output, captured);
}

String withoutControls(String text) =>
    text.replaceAll(RegExp('\x1b\\[[0-9;]*[A-Za-z]'), '').replaceAll('\r', '');

final ansi = RegExp(r'\x1b\[[0-9;]*m');

void main() {
  test('deferred warnings are said in release order, whichever came first', () {
    // Units staged side by side finish in any order; what a run says must
    // not depend on which.
    final buffer = StringBuffer();
    final output = Output(
      sink: buffer.write,
      isTerminal: false,
      useColor: false,
    );
    output.deferWarning(
      const Diagnostic(code: 'RK-PUB-012', message: 'for other', remedy: 'r'),
      unit: 'other',
    );
    output.deferWarning(
      const Diagnostic(code: 'RK-PUB-012', message: 'for core', remedy: 'r'),
      unit: 'core',
    );
    output.flushWarnings(order: const ['core', 'other']);

    final text = buffer.toString();
    expect(text.indexOf('for core'), lessThan(text.indexOf('for other')));
    final report =
        jsonDecode(output.report.encode(exit: 0)) as Map<String, Object?>;
    expect(
      [
        for (final warning in report['warnings'] as List)
          (warning as Map)['unit'],
      ],
      ['core', 'other'],
    );
  });

  test('public steps preserve concrete target identity in JSON', () {
    final (out, _) = make();
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
    out.step(
      UnitRelease.derive(
        resolution.unit('core')!,
        resolution,
        repository: null,
        problems: diagnostics,
      ).packages.single,
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

    final progress = output.progressBoard('cli · staging');
    final row = progress.addRow(
      id: 'cli/build/macos-arm64',
      label: 'Local binary',
      coordinate: 'macos-arm64',
    );
    row.handle.begin(
      ProgressActivity(running: 'building', failed: 'build failed'),
    );
    output.problem(
      Diagnostic(
        code: 'RK-BUILD-001',
        message: 'macos-arm64: the build did not produce a working binary',
        remedy: 'see the compiler output',
      ),
      unit: 'cli',
    );
    // The problem never touches the board; its owner concludes it.
    progress.conclude();
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
      lessThan(captured.lines[1].indexOf('pub.dev')),
    );
  });

  group('non-terminal output is append-only', () {
    test('a live board prints nothing at all', () {
      final (out, captured) = make(isTerminal: false);
      final board = out.progressBoard('Staging', delay: Duration.zero);
      board
          .addRow(id: 'build', label: 'linux-x64')
          .handle
          .begin(CommonProgressActivities.checking);
      expect(captured.text, isEmpty, reason: 'a pipe sees no spinner');
      board.discard();
    });

    test('and no cursor movement is emitted', () {
      final (out, captured) = make(isTerminal: false);
      final board = out.progressBoard('Staging', delay: Duration.zero);
      board
          .addRow(id: 'build', label: 'linux-x64')
          .handle
          .begin(CommonProgressActivities.checking);
      out.line('built', mark: Mark.done);
      board.discard();
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
    test('target rows fit and erase exactly at 36 columns', () async {
      const width = 36;
      final (out, captured) = make(isTerminal: true, terminalWidth: width);
      final checks = out.targetChecks(delay: Duration.zero);
      checks
        ..add('tag', 'Git tag')
        ..add('pub', 'pub.dev · rk')
        ..add('github', 'GitHub Release · danReynolds/release-kit');
      await Future<void>.delayed(const Duration(milliseconds: 1));

      checks.finish('github', Verdict.exact);
      checks.close();

      final visibleLines = withoutControls(
        captured.text,
      ).split('\n').where((line) => line.isNotEmpty);
      expect(
        visibleLines.every((line) => line.runes.length <= width),
        isTrue,
        reason:
            'a transient logical row must not wrap into two physical '
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
  });

  group('terminal styling', () {
    test('human diagnostics neutralize controls while JSON stays raw', () {
      const message = 'provider said \x1b[2Jbad\x00\x07\x7f\x9bmessage';
      const remedy = 'retry after \x1b]8;;https://bad.invalid\x07link';
      const evidence = 'native\x1b[H\x00\x84output';
      final captured = Captured();
      final output = Output(
        sink: captured.buffer.write,
        isTerminal: false,
        useColor: false,
      );

      output.problem(
        const Diagnostic(
          code: 'RK-TEST-001',
          message: message,
          remedy: remedy,
          evidence: evidence,
        ),
      );

      expect(captured.text, isNot(contains('\x1b')));
      for (final control in ['\x00', '\x07', '\x7f', '\x84', '\x9b']) {
        expect(captured.text, isNot(contains(control)));
      }
      expect(
        captured.text,
        contains(r'provider said \x1b[2Jbad\x00\x07\x7f\x9bmessage'),
      );
      expect(
        captured.text,
        contains(r'retry after \x1b]8;;https://bad.invalid\x07link'),
      );

      final document = jsonDecode(output.report.encode(exit: 1)) as Map;
      final problem = (document['problems'] as List).single as Map;
      expect(problem['message'], message);
      expect(problem['remedy'], remedy);
      expect(problem['evidence'], 'tool-output/1-RK-TEST-001.txt');
      expect((document['attachments'] as Map)[problem['evidence']], evidence);
    });

    test('non-terminal output clamps color even when requested', () {
      final captured = Captured();
      final output = Output(
        sink: captured.buffer.write,
        isTerminal: false,
        useColor: true,
      );

      output
        ..heading('Repository')
        ..line('archive', role: VisualRole.localWork)
        ..line(
          'GitHub Release',
          mark: Mark.blocked,
          role: VisualRole.releaseTarget,
        );

      expect(captured.text, isNot(contains('\x1b')));
      expect(captured.text, contains('✗'));
    });

    test('color preserves the complete plain-text contract', () {
      String render({required bool useColor}) {
        final captured = Captured();
        final output = Output(
          sink: captured.buffer.write,
          isTerminal: true,
          useColor: useColor,
          terminalWidth: 80,
        );
        output
          ..heading('Release plan')
          ..line('archive', role: VisualRole.localWork)
          ..line('stage complete', role: VisualRole.checkpoint)
          ..line('pub.dev', role: VisualRole.releaseTarget)
          ..line(
            'GitHub Release',
            mark: Mark.blocked,
            role: VisualRole.releaseTarget,
          )
          ..spans(const [
            OutputSpan('local', role: VisualRole.localWork),
            OutputSpan(' -> '),
            OutputSpan('public', role: VisualRole.releaseTarget),
          ]);
        return captured.text;
      }

      final plainText = render(useColor: false);
      final coloredText = render(useColor: true);
      expect(coloredText, contains('\x1b'));
      expect(coloredText.replaceAll(ansi, ''), plainText);
    });

    test(
      'help styling preserves every plain byte with or without final LF',
      () {
        const document =
            'rk — a release tool\n'
            '\n'
            'Usage\n'
            '  rk plan [unit]    show the configured release graph\n'
            '\n'
            'Flags\n'
            '  --json            print the machine document\n'
            '\n'
            'Marks: ✓ done,  ✗ problem\n'
            '       → your next move,  unmarked pending\n';

        String render(String text, {required bool useColor}) {
          final captured = Captured();
          Output(
            sink: captured.buffer.write,
            isTerminal: true,
            useColor: useColor,
          ).help(text);
          return captured.text;
        }

        for (final help in [
          document,
          document.substring(0, document.length - 1),
        ]) {
          final plainText = render(help, useColor: false);
          final coloredText = render(help, useColor: true);
          expect(plainText, help);
          expect(coloredText.replaceAll(ansi, ''), help);
        }
      },
    );

    test('help remains unstyled on a non-terminal', () {
      const document = 'Usage\n  rk plan    show the release graph\n';
      final captured = Captured();
      Output(
        sink: captured.buffer.write,
        isTerminal: false,
        useColor: true,
      ).help(document);

      expect(captured.text, document);
      expect(captured.text, isNot(contains('\x1b')));
    });
  });

  test(
    'settled rows use readable hanging indentation on a narrow terminal',
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
        state: RuntimeState.failure,
        noteState: RuntimeState.attention,
      );

      final visible = withoutControls(
        captured.text,
      ).split('\n').where((line) => line.isNotEmpty).toList();
      expect(visible.every((line) => line.runes.length <= 36), isTrue);
      expect(
        visible.first,
        startsWith('    ✗ GitHub Release'),
        reason: 'a nested row\'s mark sits beside it, not in the margin',
      );
      expect(
        visible.skip(1).every((line) => line.startsWith('        ')),
        isTrue,
      );
      expect(
        visible
            .join(' ')
            .replaceAll('✗', '')
            .split(RegExp(r'\s+'))
            .where((word) => word.isNotEmpty),
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
        expect(
          line,
          endsWith('\x1b[0m'),
          reason: 'each painted physical row closes its ANSI span',
        );
      }
    },
  );

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
      expect(captured.text, contains('No public targets changed'));
      expect(captured.text, contains('Resolve the conflict before retrying'));
      expect(out.report.rerunHelps, isFalse);
    });

    test(
      'a conflict after an earlier unit published acknowledges that act',
      () {
        final (out, captured) = make();
        out.previousUnitActed = true;
        out.halt(HaltKind.unfixableByRerun);
        expect(captured.text, isNot(contains('No public targets changed')));
        expect(captured.text, contains('rk acted'));
        final report = jsonDecode(out.report.encode(exit: 1)) as Map;
        expect((report['halt'] as Map)['kind'], 'actedAndUnfixable');
        expect(report['rerun_helps'], isFalse);
      },
    );
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
    out.warning(
      const Diagnostic(
        code: 'RK-GIT-001',
        message: '1 uncommitted path will be included',
      ),
    );
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
