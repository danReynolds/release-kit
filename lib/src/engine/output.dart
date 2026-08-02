import 'dart:async';
import 'dart:io';

import 'checklist.dart';
import 'diagnostic.dart';
import 'report.dart';
import 'verdict.dart';

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
    Report? report,
    Elapsed Function()? clock,
  })  : report = report ?? Report('rk'),
        _clock = clock ?? _wallClock;

  /// Writes to stdout, detecting a terminal and honouring `NO_COLOR`.
  ///
  /// [json] moves the prose to nowhere: `--json` is the named machine surface
  /// rather than an addition to the human one, so a caller parsing stdout is
  /// never handed both. The report is still recorded, because the recording
  /// happens inside the same calls that would have printed.
  factory Output.stdio({
    bool verbose = false,
    bool json = false,
    required String command,
  }) {
    final terminal = stdout.hasTerminal && !json;
    return Output(
      sink: json ? _discard : stdout.write,
      isTerminal: terminal,
      verbose: verbose,
      useColor: terminal && !Platform.environment.containsKey('NO_COLOR'),
      report: Report(command),
    );
  }

  static void _discard(String _) {}

  static Elapsed _wallClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  final void Function(String) sink;

  /// Spinners, transient lines, and cursor movement happen only here.
  final bool isTerminal;

  final bool verbose;
  final bool useColor;

  /// What a caller is told, recorded by the same calls that print.
  final Report report;

  final Elapsed Function() _clock;

  var _transient = false;

  /// A heading. Callers space their own sections; this adds nothing.
  void heading(String text) {
    _clearTransient();
    sink('$text\n');
  }

  /// The repository line, recorded in parts so a caller is not left parsing
  /// "keybay · main · 2 uncommitted" back into fields.
  void repository({required String name, String? branch, int? uncommitted}) {
    report.repository(name: name, branch: branch, uncommitted: uncommitted);
    heading([
      name,
      if (branch != null) branch,
      if (uncommitted != null && uncommitted > 0) '$uncommitted uncommitted',
    ].join(' · '));
  }

  /// Opens a unit. Steps printed after this belong to it.
  void unit(String name, {required String version, required String tag}) {
    report.unit(name: name, version: version, tag: tag);
    blank();
    line(name, note: '$version → $tag');
  }

  /// One step of a checklist, printed and recorded as one act.
  ///
  /// Taking the [Step] rather than its parts is what makes the two surfaces
  /// agree: there is no way to show a person one id and hand a caller another,
  /// because there is only one call and it reads both from the same object.
  ///
  /// [show] records without printing, for a step collapse leaves off the
  /// screen. The asymmetry runs one way only and deliberately: everything
  /// printed is recorded, while the document may carry more than the terminal
  /// shows. Terseness is a rule about a person's attention, and a caller
  /// keying on step ids wants the whole checklist.
  void step(
    Step step, {
    Mark mark = Mark.none,
    String? note,
    Verdict verdict = Verdict.unknown,
    String? detail,
    Map<String, String> evidence = const {},
    Duration? took,
    int depth = 1,
    bool show = true,
  }) {
    report.step(
      id: step.id,
      unit: step.unit,
      summary: step.summary,
      verdict: verdict.name,
      detail: detail,
      evidence: evidence,
      permanent: step.isPermanent,
      public: step.isPublic,
      needs: step.needs,
      took: took,
    );
    if (!show) return;
    line(
      step.summary,
      mark: mark,
      note: note ?? (step.isPermanent ? 'permanent' : null),
      depth: depth,
      labelWidth: 48,
    );
    // The difference itself, not the fact of one — on the surface a person
    // reads, not only in the document. status's live forge conflict printed
    // a bare blocked line while the JSON carried the six-asset table.
    for (final entry in evidence.entries) {
      line('${entry.key}  ${entry.value}', depth: depth + 1);
    }
  }

  /// One verification result, printed and recorded as one act.
  ///
  /// [id] is the frozen step id for a subject the grammar names, so a caller
  /// keys verifications the same way it keys steps — free prose was the phase
  /// 3 "machine surface empty where a caller needs it" finding relocated.
  /// [counts] is false for a scope disclosure — a subject this command names
  /// as unexamined rather than one it judged — which reads as unknown but is
  /// not a failed proof, because it never claimed to be one.
  void verification(
    String unit,
    String subject, {
    required Verdict verdict,
    String? id,
    String? detail,
    Map<String, String> evidence = const {},
    bool counts = true,
  }) {
    report.verification(
      unit,
      subject,
      id: id,
      verdict: verdict.name,
      detail: detail,
      evidence: evidence,
      counts: counts,
    );
    line(
      subject,
      mark: switch (verdict) {
        Verdict.exact => Mark.done,
        // A proof that failed — conflicting or not provable — is ✗: the RFC
        // gives the glyph to "blocked, conflicting, or failed", and a failed
        // run whose line carries no mark reads as a note.
        Verdict.conflict => Mark.blocked,
        Verdict.unknown when counts => Mark.blocked,
        _ => Mark.none,
      },
      note: detail,
      depth: 1,
      labelWidth: 32,
    );
    for (final entry in evidence.entries) {
      line('${entry.key}  ${entry.value}', depth: 2);
    }
  }

  /// Begins a step whose work takes long enough that silence would read as a
  /// hang. Finish it with [Activity.done] or [Activity.failed].
  ///
  /// [typically] is how long this normally takes, which is the difference
  /// between patience and a cancelled release when the wait is somebody else's.
  Activity begin(
    Step step, {
    Duration? typically,
    int depth = 1,
  }) {
    // rk works one step at a time, so a live activity here is one whose caller
    // never finished it. Cancelling it is what keeps a forgotten step from
    // holding the isolate open forever.
    _live?.abandon();
    return _live = Activity._(this, step, typically, depth, _clock());
  }

  Activity? _live;

  /// Ends the run's rendering.
  ///
  /// A repeating timer keeps a Dart isolate alive, so an activity abandoned by
  /// a thrown exception would leave rk running with nothing to do — a hang,
  /// which in CI is worse than a crash because nothing reports it. Calling this
  /// on the way out is what makes that impossible rather than unlikely.
  void close() {
    _live?.abandon();
    _live = null;
    _clearTransient();
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
      // Too long to keep the note on the grid. It follows the label anyway,
      // because a note describes the line it is on: given its own line it reads
      // as a fact about nothing, and "permanent" floating alone is worse than
      // "permanent" out of column.
      sink('$glyph $indented $note\n');
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
    final sentence = switch (kind) {
      HaltKind.beforeActing =>
        'rk stopped before acting. nothing changed. safe to re-run.',
      HaltKind.lostTrack => 'rk acted, then lost sight of the result. '
          'an effect may exist. still safe to re-run.',
      HaltKind.unfixableByRerun =>
        'rk did not act. this cannot be fixed by re-running.',
    };
    report.halt(
      kind.name,
      sentence,
      helps: kind != HaltKind.unfixableByRerun,
    );
    blank();
    say(sentence);
    blank();
  }

  /// A problem, with its remedy and — only under `-v` — its code.
  ///
  /// The code is always in the report: a person searching for it wants it out
  /// of the way until they need it, while a caller keying on it needs it every
  /// time.
  void problem(Diagnostic diagnostic, {String? unit, int depth = 0}) {
    report.problem(diagnostic, unit: unit);
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
    report.next(command);
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

/// How long something has been running.
///
/// A function rather than a `Stopwatch` so liveness can be tested without
/// waiting: the wall clock is one implementation of it, and a test's counter is
/// another.
typedef Elapsed = Duration Function();

/// A step being worked on, so that waiting reads as work rather than as a hang.
///
/// The RFC's rule, and the reason this exists at all: a release takes minutes
/// and some steps are opaque — notarization waits on Apple — and silence during
/// that is not austerity, it is anxiety. An operator who cannot tell a wait from
/// a hang cancels the release, which is the expensive outcome.
///
/// Nothing here happens off a terminal. A pipe, a log, and an agent get one
/// line per step, on completion, in the same words the terminal ends up
/// showing: no spinner, no elapsed counter, no rewriting.
class Activity {
  Activity._(
    this._output,
    this._step,
    this._typically,
    this._depth,
    this._elapsed,
  ) {
    if (_output.isTerminal) {
      _draw();
      // The counter has to advance on its own. A step that blocks — a
      // subprocess, a poll that has not come back — would otherwise show a
      // frozen spinner, which is indistinguishable from the hang this exists
      // to rule out.
      _timer =
          Timer.periodic(const Duration(milliseconds: 120), (_) => _draw());
    }
  }

  final Output _output;
  final Step _step;
  final Duration? _typically;
  final int _depth;
  final Elapsed _elapsed;

  Timer? _timer;
  String? _doing;
  var _spin = 0;
  var _finished = false;

  static const _frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

  /// A duration worth printing on a finished step. Below this it is noise: the
  /// reader learns nothing from being told a step took a moment.
  static const notable = Duration(seconds: 5);

  /// What the step is doing now. Shown while it runs and gone once it has.
  void update(String doing) {
    _doing = doing;
    if (_output.isTerminal) _draw();
  }

  /// Finished, with [result] as the one line that survives.
  ///
  /// [verdict] is what a caller keys on, and it is the [Verdict] type rather
  /// than a string so the four-word vocabulary is enforced by the compiler:
  /// prose in this field — "Apple rejected the submission" where a caller
  /// expects one of four words — is now unrepresentable, not merely wrong.
  void done(
    String result, {
    Mark mark = Mark.done,
    Verdict verdict = Verdict.exact,
  }) =>
      _finish(mark, result, verdict);

  /// Failed. The line stays, and so does whatever the caller prints after it,
  /// because that detail is the diagnosis.
  ///
  /// The verdict is `unknown` rather than anything definite: rk tried and did
  /// not get an answer, which is not the same as having learned that nothing
  /// is there.
  void failed(String result, {Verdict verdict = Verdict.unknown}) =>
      _finish(Mark.blocked, result, verdict);

  /// Stops rendering without recording an outcome, for a step whose caller
  /// went away. Nothing is printed: there is no result to report.
  void abandon() {
    _finished = true;
    _timer?.cancel();
  }

  void _finish(Mark mark, String result, Verdict verdict) {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    final took = _elapsed();
    _output.step(
      _step,
      mark: mark,
      note: took >= notable ? '$result · ${formatDuration(took)}' : result,
      verdict: verdict,
      detail: result,
      took: took,
      depth: _depth,
    );
  }

  /// The line a terminal shows while this runs.
  ///
  /// Pure, so what an operator sees during a five-minute wait is asserted in a
  /// test that takes no time at all.
  String frame() {
    final took = _elapsed();
    final parts = [
      _step.summary,
      if (_doing != null) _doing!,
      formatDuration(took),
      if (_typically != null && took > _typically)
        'longer than the usual ${formatDuration(_typically)}'
      else if (_typically != null)
        'typically ${formatDuration(_typically)}',
    ];
    return '${_frames[_spin % _frames.length]} ${parts.join(' · ')}';
  }

  void _draw() {
    _output.progress('${'  ' * _depth}${frame()}');
    _spin++;
  }
}

/// A duration in the coarsest terms that still say something: seconds under a
/// minute, then minutes, then hours. Nobody waiting on a release needs
/// milliseconds, and nobody reading "184s" converts it gladly.
String formatDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) {
    final seconds = d.inSeconds % 60;
    return seconds == 0 ? '${d.inMinutes}m' : '${d.inMinutes}m ${seconds}s';
  }
  final minutes = d.inMinutes % 60;
  return minutes == 0 ? '${d.inHours}h' : '${d.inHours}h ${minutes}m';
}
