import 'dart:io';

import 'diagnostic.dart';

/// How a line reads at a glance.
///
/// Four marks rather than one per state: anything finer is carried by the
/// words on the line, which the reader has to read anyway.
enum Mark {
  /// Done or proven.
  done('✓'),

  /// Already satisfied; nothing to do.
  satisfied('·'),

  /// Blocked, conflicting, or failed.
  blocked('✗'),

  /// Your next move.
  next('→'),

  /// Neither: a plain line.
  none(' ');

  const Mark(this.glyph);
  final String glyph;
}

/// Everything rk prints goes through here, so terseness, collapse, and the
/// non-TTY contract are enforced in one place rather than per command.
///
/// The rules this encodes, from the RFC: rk does not narrate itself; a running
/// step expands and a finished one collapses; and a pipe sees the same words
/// the terminal ends up showing, with no cursor movement.
class Output {
  Output({
    required this.sink,
    required this.isTerminal,
    this.verbose = false,
    this.useColor = true,
  });

  /// Writes to stdout, detecting a terminal and honouring `NO_COLOR`.
  factory Output.stdio({bool verbose = false}) {
    final terminal = stdout.hasTerminal;
    return Output(
      sink: stdout.write,
      isTerminal: terminal,
      verbose: verbose,
      useColor:
          terminal && !Platform.environment.containsKey('NO_COLOR'),
    );
  }

  final void Function(String) sink;

  /// Spinners, transient lines, and cursor movement happen only here.
  final bool isTerminal;

  final bool verbose;
  final bool useColor;

  var _transient = false;

  /// A heading, with a blank line before it unless it opens the output.
  void heading(String text) {
    _clearTransient();
    sink('$text\n');
  }

  void blank() {
    _clearTransient();
    sink('\n');
  }

  /// One line of the tree, indented by [depth] levels of two spaces.
  ///
  /// [note] is the fact; [detail] is the part that only matters when it
  /// differs, and is aligned so a column of them stays readable.
  void line(
    String label, {
    Mark mark = Mark.none,
    String? note,
    int depth = 0,
    int labelWidth = 16,
  }) {
    _clearTransient();
    final glyph = mark == Mark.none ? ' ' : _paint(mark);

    // The indent is part of what is padded, so the note column stays put as
    // the tree deepens rather than drifting right with it.
    final indented = '${'  ' * depth}$label';
    if (note == null) {
      sink('$glyph $indented\n');
      return;
    }
    if (indented.length >= labelWidth) {
      // Too long to share a line without pushing the note off the grid, so
      // the note gets its own, aligned to the column it would have used.
      sink('$glyph $indented\n');
      sink('${' ' * (labelWidth + 2)}$note\n');
      return;
    }
    sink('$glyph ${indented.padRight(labelWidth)} $note\n');
  }

  /// Free-form prose, wrapped in the same indentation as the tree.
  void say(String text, {int depth = 0}) {
    _clearTransient();
    final indent = '  ' * depth;
    for (final part in text.split('\n')) {
      sink('  $indent$part\n');
    }
  }

  /// A line that will be replaced by its own completion, so the terminal shows
  /// what is happening and the scrollback shows only what happened.
  ///
  /// Suppressed entirely when not attached to a terminal: a log, a pipe, and
  /// an agent see one line per step, on completion, never a redraw.
  void progress(String text) {
    if (!isTerminal) return;
    _clearTransient();
    sink('  $text');
    _transient = true;
  }

  void _clearTransient() {
    if (!_transient) return;
    // Return to the start of the line and clear it.
    sink('\r\x1b[2K');
    _transient = false;
  }

  /// The plain sentence that opens every halt, before any verdict noun.
  void halt(HaltKind kind) {
    blank();
    say(switch (kind) {
      HaltKind.beforeActing =>
        'rk stopped before acting. nothing changed. safe to re-run.',
      HaltKind.lostTrack => 'rk acted, then lost sight of the result. '
          'an effect may exist. still safe to re-run.',
      HaltKind.unfixableByRerun =>
        'rk did not act. this cannot be fixed by re-running.',
    });
    blank();
  }

  /// A problem, with its remedy and — only under `-v` — its code.
  void problem(Diagnostic diagnostic, {int depth = 0}) {
    final where = diagnostic.source == null ? '' : '${diagnostic.source}  ';
    line(
      '$where${diagnostic.message}',
      mark: Mark.blocked,
      depth: depth,
    );
    if (diagnostic.remedy != null) {
      say(diagnostic.remedy!, depth: depth + 1);
    }
    if (verbose) {
      say(diagnostic.code, depth: depth + 1);
    }
  }

  /// Every problem in one pass, so a fix cycle is one edit round.
  void problems(List<Diagnostic> found) {
    for (final diagnostic in found) {
      problem(diagnostic);
    }
  }

  /// The next command, which is what a reader wants after being told to act.
  void next(String command, {int depth = 0}) {
    // Marked by position, not by content: two identical lines are two lines,
    // and only the first is the reader's next move.
    for (final (index, part) in command.split('\n').indexed) {
      line(part, mark: index == 0 ? Mark.next : Mark.none, depth: depth);
    }
  }

  String _paint(Mark mark) {
    if (!useColor) return mark.glyph;
    final code = switch (mark) {
      Mark.done => '32', // green
      Mark.blocked => '31', // red
      Mark.satisfied => '90', // grey
      Mark.next => '36', // cyan
      Mark.none => null,
    };
    return code == null ? mark.glyph : '\x1b[${code}m${mark.glyph}\x1b[0m';
  }
}

/// Which of the two questions an operator has a halt is answering.
enum HaltKind {
  /// Nothing happened; the world is unchanged.
  beforeActing,

  /// Something may have happened; the next run classifies what it finds.
  lostTrack,

  /// Something is wrong that re-running will not resolve.
  unfixableByRerun,
}

/// Process exit codes, from the RFC's output contract.
class ExitCodes {
  /// Clean, complete, or blocked — blocked is a state, not a failure.
  static const ok = 0;

  /// A refusal: a validation error, a conflict, or an unknown verdict.
  static const refused = 1;

  /// The command was used incorrectly.
  static const usage = 2;
}
