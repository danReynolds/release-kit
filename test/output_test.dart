import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/output.dart';
import 'package:test/test.dart';

/// Captures what rk would print, so the contract can be asserted rather than
/// eyeballed.
class Captured {
  final StringBuffer buffer = StringBuffer();
  String get text => buffer.toString();
  List<String> get lines =>
      text.split('\n').where((l) => l.isNotEmpty).toList();
}

(Output, Captured) make({bool isTerminal = false, bool verbose = false}) {
  final captured = Captured();
  final output = Output(
    sink: captured.buffer.write,
    isTerminal: isTerminal,
    verbose: verbose,
    useColor: false,
  );
  return (output, captured);
}

void main() {
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
  });

  test('colour is off when asked, and never the only signal', () {
    final (out, captured) = make();
    out.line('failed', mark: Mark.blocked);
    expect(captured.text, isNot(contains('\x1b')));
    expect(captured.text, contains('✗'));
  });

  group('halts open with the sentence, not the noun', () {
    test('nothing happened', () {
      final (out, captured) = make();
      out.halt(HaltKind.beforeActing);
      expect(captured.text, contains('nothing changed'));
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
      remedy: 'add publish = ["pub.dev"]',
    );

    test('lead with where and what, and carry the fix', () {
      final (out, captured) = make();
      out.problem(diagnostic);
      expect(captured.text, contains('release.toml:4'));
      expect(captured.text, contains('does not say where to publish'));
      expect(captured.text, contains('add publish'));
    });

    test('carry the code on the ✗ line, in every mode', () {
      // Reversed by the persona review: an alert grepping a CI log must not
      // depend on someone having passed -v, so the code rides the message
      // it names rather than hiding behind a flag.
      final (out, captured) = make();
      out.problem(diagnostic);
      expect(
        captured.lines.firstWhere((l) => l.contains('✗')),
        contains('· RK-CONF-019'),
      );

      final (verbose, verboseCaptured) = make(verbose: true);
      verbose.problem(diagnostic);
      expect(verboseCaptured.text, contains('· RK-CONF-019'));
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
