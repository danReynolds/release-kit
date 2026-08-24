import 'dart:convert';

import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/publish_target.dart';
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

(Output, Captured) make({
  bool isTerminal = false,
  int? terminalWidth,
}) {
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

    final progress = output.progressBoard('cli · staging');
    final row = progress.addRow(
      id: 'cli/build/macos-arm64',
      label: 'Local binary',
      coordinate: 'macos-arm64',
    );
    row.handle.begin(ProgressActivity(
      running: 'building',
      failed: 'build failed',
    ));
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
        lessThan(
          captured.lines[1].indexOf('pub.dev'),
        ));
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
          ..add('pub', 'pub.dev · rk')
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

  group('semantic terminal styling', () {
    const colored = OutputTheme(useColor: true);
    const plain = OutputTheme(useColor: false);

    test('topology roles have one standard ANSI vocabulary', () {
      expect(colored.paint('primary'), 'primary');
      expect(
        colored.paint('secondary', role: VisualRole.secondary),
        '\x1b[90msecondary\x1b[0m',
      );
      expect(
        colored.paint('local', role: VisualRole.localWork),
        '\x1b[34mlocal\x1b[0m',
      );
      expect(
        colored.paint('join', role: VisualRole.checkpoint),
        '\x1b[35mjoin\x1b[0m',
      );
      expect(
        colored.paint('need', role: VisualRole.requirement),
        '\x1b[33mneed\x1b[0m',
      );
      expect(
        colored.paint('public', role: VisualRole.releaseTarget),
        '\x1b[36mpublic\x1b[0m',
      );
      expect(
        colored.paint('act', role: VisualRole.operatorAction),
        '\x1b[36mact\x1b[0m',
      );
      expect(
        plain.paint(
          'unchanged',
          role: VisualRole.releaseTarget,
          state: RuntimeState.failure,
          strong: true,
        ),
        'unchanged',
      );
    });

    test('runtime truth overrides topology and green only means success', () {
      for (final role in VisualRole.values) {
        expect(
          colored.paint('failed', role: role, state: RuntimeState.failure),
          '\x1b[31mfailed\x1b[0m',
        );
      }
      expect(
        colored.paint(
          'published',
          role: VisualRole.releaseTarget,
          state: RuntimeState.success,
        ),
        '\x1b[32mpublished\x1b[0m',
      );
      expect(
        colored.render([
          const OutputSpan('local', role: VisualRole.localWork),
          const OutputSpan(' checkpoint', role: VisualRole.checkpoint),
          const OutputSpan(' public', role: VisualRole.releaseTarget),
        ]),
        isNot(contains('\x1b[32m')),
        reason: 'a source-only topology has no successful runtime outcome',
      );
    });

    test('an explicit state governs both the glyph and its subject', () {
      final captured = Captured();
      final output = Output(
        sink: captured.buffer.write,
        isTerminal: true,
        useColor: true,
      );

      output.line(
        'already published',
        mark: Mark.done,
        role: VisualRole.releaseTarget,
        state: RuntimeState.satisfied,
      );

      expect(captured.text, contains('\x1b[90m✓\x1b[0m'));
      expect(captured.text, contains('\x1b[90malready published\x1b[0m'));
      expect(
        captured.text,
        isNot(contains('\x1b[32m')),
        reason: 'a done mark does not override the explicit satisfied state',
      );
    });

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
      expect(
        (document['attachments'] as Map)[problem['evidence']],
        evidence,
      );
    });

    test('verdicts map to the shared runtime states', () {
      expect(RuntimeState.of(Verdict.exact), RuntimeState.satisfied);
      expect(RuntimeState.of(Verdict.conflict), RuntimeState.failure);
      expect(RuntimeState.of(Verdict.unknown), RuntimeState.attention);
      expect(RuntimeState.of(Verdict.absent), RuntimeState.neutral);
    });

    test('bold is an emphasis layered onto the semantic color', () {
      expect(
        colored.paint(
          'release',
          role: VisualRole.releaseTarget,
          strong: true,
        ),
        '\x1b[1;36mrelease\x1b[0m',
      );
      expect(colored.paint('heading', strong: true), '\x1b[1mheading\x1b[0m');
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
      expect(coloredText, contains('\x1b[31mGitHub Release\x1b[0m'));
      expect(
        coloredText,
        isNot(contains('\x1b[36mGitHub Release\x1b[0m')),
        reason: 'failure state must override the public-target role',
      );
    });

    test('help styling preserves every plain byte with or without final LF',
        () {
      const document = 'rk — a release tool\n'
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
        document.substring(0, document.length - 1)
      ]) {
        final plainText = render(help, useColor: false);
        final coloredText = render(help, useColor: true);
        expect(plainText, help);
        expect(coloredText.replaceAll(ansi, ''), help);
      }
    });

    test('help styles structure and invocations, never outcomes', () {
      const document = 'rk — a release tool\n'
          '\n'
          'Usage\n'
          '  rk plan [unit]    show the configured release graph\n'
          'Flags\n'
          '  --json            print the machine document\n'
          'Marks: ✓ done,  ✗ problem\n';
      final captured = Captured();
      Output(
        sink: captured.buffer.write,
        isTerminal: true,
        useColor: true,
      ).help(document);
      final text = captured.text;

      expect(text, startsWith('\x1b[1mrk — a release tool\x1b[0m\n'));
      expect(text, contains('\x1b[1mUsage\x1b[0m'));
      expect(text, contains('  \x1b[36mrk plan [unit]\x1b[0m    show'));
      expect(text, contains('  \x1b[36m--json\x1b[0m'));
      expect(text, contains('\x1b[1mMarks:\x1b[0m ✓ done'));
      for (final outcomeCode in ['31', '32', '33']) {
        expect(text, isNot(contains('\x1b[${outcomeCode}m')),
            reason: 'help describes actions; it has no runtime outcome');
      }
    });

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
      state: RuntimeState.failure,
      noteState: RuntimeState.attention,
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
