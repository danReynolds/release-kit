import 'dart:async';
import 'dart:io';

import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import 'progress.dart';
import 'report.dart';
import '../engine/verdict.dart';

/// How a line reads at a glance.
///
/// A small mark vocabulary rather than one per state: anything finer is carried by the
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

  /// Nonblocking, but worth seeing before acting.
  warning('!'),

  /// Neither: a plain line.
  none(' ');

  const Mark(this.glyph);
  final String glyph;

  /// The mark a verdict earns.
  ///
  /// One definition, because two commands mapping this themselves is how
  /// the line a person reads and the document a caller keys on end up
  /// disagreeing about severity.
  static Mark of(Verdict verdict) => switch (verdict) {
        Verdict.exact => satisfied,
        Verdict.conflict => blocked,
        // Absent is work to do and unknown is work rk could not rule out.
        // Neither earns a glyph; the words separate them.
        Verdict.absent || Verdict.unknown => none,
      };
}

/// The colour a word earns from what it says.
///
/// The gutter's marks stay the vocabulary; tones repeat the same
/// judgment on the words for a reader scanning colour — never carrying
/// anything the words do not, so `NO_COLOR` loses nothing.
enum Tone {
  plain,

  /// A section header: structure, not a fact.
  header,

  /// Already so; nothing to do here.
  muted,

  /// Blocked, conflicting, or failed.
  bad,

  /// rk could not read it, and wants eyes on that.
  attention;

  /// The tone a verdict earns, beside [Mark.of].
  static Tone of(Verdict verdict) => switch (verdict) {
        Verdict.exact => muted,
        Verdict.conflict => bad,
        Verdict.unknown => attention,
        Verdict.absent => plain,
      };
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
    this.useColor = true,
    int? terminalWidth,
    int? Function()? terminalWidthReader,
    Report? report,
    Elapsed Function()? clock,
  })  : _terminalWidth = terminalWidth,
        _terminalWidthReader = terminalWidthReader,
        report = report ?? Report('rk'),
        _clock = clock ?? _wallClock;

  /// Writes to stdout, detecting a terminal and honouring `NO_COLOR`.
  ///
  /// [json] moves the prose to nowhere: `--json` is the named machine surface
  /// rather than an addition to the human one, so a caller parsing stdout is
  /// never handed both. The report is still recorded, because the recording
  /// happens inside the same calls that would have printed.
  factory Output.stdio({bool json = false, required String command}) {
    final attached = stdout.hasTerminal && !json;
    final noColor = Platform.environment.containsKey('NO_COLOR');
    final terminal =
        attached && Platform.environment['TERM']?.toLowerCase() != 'dumb';
    return Output(
      sink: json ? _discard : stdout.write,
      isTerminal: terminal,
      useColor: terminal && !noColor,
      terminalWidthReader: attached ? _stdoutWidth : null,
      report: Report(command),
    );
  }

  static void _discard(String _) {}

  static int? _stdoutWidth() {
    try {
      final width = stdout.terminalColumns;
      return width > 0 ? width : null;
    } on Object {
      return null;
    }
  }

  static Elapsed _wallClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  final void Function(String) sink;

  /// Spinners, transient lines, and cursor movement happen only here.
  final bool isTerminal;

  final bool useColor;

  /// Columns available on an attached terminal.
  ///
  /// Transient rows are shortened to stay one physical row, because cursor-up
  /// erasure depends on that. Settled rows are instead wrapped without losing
  /// words, with their continuation indented so narrow output remains readable.
  /// A pipe has no width and remains byte-for-byte append-only.
  final int? _terminalWidth;
  final int? Function()? _terminalWidthReader;

  int? get terminalWidth => _terminalWidthReader?.call() ?? _terminalWidth;

  /// What a caller is told, recorded by the same calls that print.
  final Report report;

  /// Whether an earlier unit in this repository command changed public
  /// truth. Set by the release command at unit boundaries so a later local
  /// refusal cannot claim the whole invocation changed nothing.
  bool previousUnitActed = false;

  final Elapsed Function() _clock;

  var _transient = false;
  LiveProgress? _progressBoard;

  /// A fixed-height, target-agnostic progress surface.
  ///
  /// Targets receive only row handles; the coordinator retains the returned
  /// controllers and therefore remains the sole authority that can declare a
  /// public row complete, failed, or not attempted.
  LiveProgress progressBoard(
    String title, {
    Duration delay = const Duration(milliseconds: 80),
    bool emitSlowToNonTerminal = false,
    bool showElapsed = true,
  }) {
    _clearTransient();
    final board = LiveProgress._(
      this,
      title,
      delay,
      emitSlowToNonTerminal: emitSlowToNonTerminal,
      showElapsed: showElapsed,
    );
    _progressBoard = board;
    return board;
  }

  /// A fixed multi-line region for concurrent public-target reads.
  ///
  /// Nothing is emitted for a pipe. On a terminal the region appears only
  /// after a short delay, so fast reads do not flicker, and [TargetChecks]
  /// erases it completely before the deterministic report is rendered.
  TargetChecks targetChecks(
      {Duration delay = const Duration(milliseconds: 80)}) {
    return TargetChecks._(this, delay);
  }

  /// A heading. Callers space their own sections; this adds nothing.
  void heading(String text) {
    _clearTransient();
    _writeSettled(text, continuationPrefix: '  ');
  }

  /// The repository line, recorded in parts so a caller is not left parsing
  /// "keybay · main · 2 uncommitted" back into fields.
  void repository({
    required String name,
    String? branch,
    String? commit,
    int? uncommitted,
    String? head,
    String? remote,
    String? sourceBinding,
    String? sourceComparison,
  }) {
    report.repository(
      name: name,
      branch: branch,
      uncommitted: uncommitted,
      head: head,
      remote: remote,
      sourceBinding: sourceBinding,
      sourceComparison: sourceComparison,
    );
    heading([
      name,
      // The commit rides beside the branch for a reader; the document keeps
      // them apart, because `branch` promises a branch name.
      if (branch != null && commit != null) '$branch@$commit',
      if (branch != null && commit == null) branch,
      if (branch == null && commit != null) commit,
      if (uncommitted != null && uncommitted > 0) '$uncommitted uncommitted',
    ].join(' · '));
  }

  /// Opens a unit. Steps printed after this belong to it.
  void unit(
    String name, {
    required String version,
    required String? tag,
    String? state,
    String? display,
  }) {
    report.unit(name: name, version: version, tag: tag);
    blank();
    // › for becomes and for sequence, everywhere inline: the gutter's → is
    // reserved for "your next move", and three reviewers independently
    // caught it moonlighting.
    line(
      name,
      note: display ??
          (state == null ? '$version › $tag' : '$version › $tag · $state'),
      // The unit's own line is a sentence, not a column: what follows the
      // name belongs beside it, not at the note column the rows below
      // share.
      labelWidth: 0,
    );
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
    String? action,
    int depth = 1,
    bool show = true,
  }) {
    report.step(
      id: step.id,
      unit: step.unit,
      summary: step.summary,
      verdict: verdict.name,
      kind: step.kind.name,
      target: step.target?.wireName,
      detail: detail,
      evidence: evidence,
      permanent: step.isPermanent,
      public: step.isPublic,
      needs: step.needs,
      took: took,
      action: action,
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

  /// Ends the run's rendering.
  ///
  /// A repeating timer keeps a Dart isolate alive, so an activity abandoned by
  /// a thrown exception would leave rk running with nothing to do — a hang,
  /// which in CI is worse than a crash because nothing reports it. Calling this
  /// on the way out is what makes that impossible rather than unlikely.
  void close() {
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
  ///
  /// Tones colour the words themselves, not only the gutter — a state word
  /// reads at a glance in the colour its verdict earns. Layout is computed
  /// on the plain text and colour applied after, so a painted label never
  /// shifts the column it sits in; `NO_COLOR` and pipes get the same
  /// characters uncoloured.
  void line(
    String label, {
    Mark mark = Mark.none,
    String? note,
    int depth = 0,
    int labelWidth = 16,
    Tone tone = Tone.plain,
    Tone noteTone = Tone.plain,
  }) {
    _clearTransient();
    final plainGlyph = mark == Mark.none ? ' ' : mark.glyph;
    final paintedGlyph = mark == Mark.none ? ' ' : _paint(mark);

    // The indent is part of what is padded, so the note column stays put as
    // the tree deepens rather than drifting right with it.
    final indented = '${'  ' * depth}$label';
    final plain = note == null
        ? '$plainGlyph $indented'
        : indented.length >= labelWidth
            ? '$plainGlyph $indented $note'
            : '$plainGlyph ${indented.padRight(labelWidth)} $note';
    final width = terminalWidth;
    if (width != null && plain.runes.length > width) {
      final firstPrefix = '$plainGlyph ${'  ' * depth}';
      final paintedFirstPrefix = '$paintedGlyph ${'  ' * depth}';
      final continuationPrefix = '${' ' * firstPrefix.runes.length}  ';
      _writeSettled(
        label,
        firstPrefix: firstPrefix,
        paintedFirstPrefix: paintedFirstPrefix,
        continuationPrefix: continuationPrefix,
        tone: tone,
      );
      if (note != null) {
        _writeSettled(
          note,
          firstPrefix: continuationPrefix,
          continuationPrefix: continuationPrefix,
          tone: noteTone,
        );
      }
      return;
    }

    final glyph = paintedGlyph;
    if (note == null) {
      sink('$glyph ${_tint(indented, tone)}\n');
      return;
    }
    if (indented.length >= labelWidth) {
      // Too long to keep the note on the grid. It follows the label anyway,
      // because a note describes the line it is on: given its own line it reads
      // as a fact about nothing, and "permanent" floating alone is worse than
      // "permanent" out of column.
      sink('$glyph ${_tint(indented, tone)} ${_tint(note, noteTone)}\n');
      return;
    }
    final padded = indented.padRight(labelWidth);
    sink('$glyph ${_tint(padded, tone)} ${_tint(note, noteTone)}\n');
  }

  /// [text] in [tone]'s colour, or untouched without colour support.
  String _tint(String text, Tone tone) {
    if (!useColor || tone == Tone.plain) return text;
    final code = switch (tone) {
      Tone.plain => null,
      Tone.header => '1', // bold
      Tone.muted => '90', // grey
      Tone.bad => '31', // red
      Tone.attention => '33', // yellow
    };
    return code == null ? text : '\x1b[${code}m$text\x1b[0m';
  }

  /// Free-form prose, wrapped in the same indentation as the tree.
  void say(String text, {int depth = 0}) {
    _clearTransient();
    final prefix = '  ${'  ' * depth}';
    for (final part in text.split('\n')) {
      final repeatsComment = part.startsWith('# ');
      _writeSettled(
        part,
        firstPrefix: prefix,
        continuationPrefix: '$prefix  ${repeatsComment ? '# ' : ''}',
      );
    }
  }

  /// A terminal prompt, using the same width policy as settled prose while
  /// leaving the cursor after the final space for the answer.
  void prompt(String text) {
    _clearTransient();
    final body = text.trimRight();
    _writeSettled(
      body,
      continuationPrefix: '  ',
      endWithNewline: false,
    );
    if (text.length != body.length) sink(' ');
  }

  void _writeSettled(
    String text, {
    String firstPrefix = '',
    String? paintedFirstPrefix,
    required String continuationPrefix,
    Tone tone = Tone.plain,
    bool endWithNewline = true,
  }) {
    final width = terminalWidth;
    if (width == null ||
        firstPrefix.runes.length + text.runes.length <= width) {
      sink('${paintedFirstPrefix ?? firstPrefix}${_tint(text, tone)}'
          '${endWithNewline ? '\n' : ''}');
      return;
    }

    final fragments = _wrapSettled(
      text,
      firstWidth: width - firstPrefix.runes.length,
      continuationWidth: width - continuationPrefix.runes.length,
    );
    for (final (index, fragment) in fragments.indexed) {
      final first = index == 0;
      final prefix =
          first ? paintedFirstPrefix ?? firstPrefix : continuationPrefix;
      final newline = index < fragments.length - 1 || endWithNewline;
      sink('$prefix${_tint(fragment, tone)}${newline ? '\n' : ''}');
    }
  }

  static List<String> _wrapSettled(
    String text, {
    required int firstWidth,
    required int continuationWidth,
  }) {
    final words = text.trim().split(RegExp(r'\s+'));
    if (words.length == 1 && words.single.isEmpty) return const [''];

    final lines = <String>[];
    var width = firstWidth < 1 ? 1 : firstWidth;
    var current = '';

    void flush() {
      if (current.isEmpty) return;
      lines.add(current);
      current = '';
      width = continuationWidth < 1 ? 1 : continuationWidth;
    }

    for (final word in words) {
      final runes = word.runes.toList();
      var offset = 0;
      while (offset < runes.length) {
        final separator = current.isEmpty ? 0 : 1;
        final available = width - current.runes.length - separator;
        if (available <= 0) {
          flush();
          continue;
        }
        final remaining = runes.length - offset;
        if (remaining <= available) {
          current = '$current${separator == 0 ? '' : ' '}'
              '${String.fromCharCodes(runes.skip(offset))}';
          offset = runes.length;
          continue;
        }
        if (current.isNotEmpty) {
          flush();
          continue;
        }
        current = String.fromCharCodes(runes.skip(offset).take(available));
        offset += available;
        flush();
      }
    }
    flush();
    return lines.isEmpty ? const [''] : lines;
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
    _progressBoard?.discard();
    if (!_transient) return;
    // Return to the start of the line and clear it.
    sink('\r\x1b[2K');
    _transient = false;
  }

  /// The plain sentence that opens every halt, before any verdict noun.
  void halt(HaltKind kind) {
    // A later unit can fail before its own first act after an earlier unit in
    // the same repository command already published. The report is for the
    // whole invocation, so "nothing changed" would be false.
    if (kind == HaltKind.beforeActing && previousUnitActed) {
      kind = HaltKind.stoppedPartway;
    }
    final sentence = switch (kind) {
      HaltKind.beforeActing =>
        'rk stopped. no public target changed. safe to re-run.',
      HaltKind.stoppedPartway => 'rk stopped partway. everything already '
          'done is real and stays done; re-running resumes after it.',
      HaltKind.lostTrack => 'rk acted, then lost sight of the result. '
          'an effect may exist. still safe to re-run.',
      HaltKind.unfixableByRerun =>
        'rk did not act. this cannot be fixed by re-running.',
      HaltKind.actedAndUnfixable =>
        'rk acted, and what it read back cannot be fixed by re-running.',
    };
    report.halt(
      kind.name,
      sentence,
      helps: kind != HaltKind.unfixableByRerun &&
          kind != HaltKind.actedAndUnfixable,
    );
    blank();
    say(sentence);
    blank();
  }

  /// A problem and its remedy.
  ///
  /// Stable codes stay in `--json`; the default human surface carries only
  /// the sentence and action they identify.
  void problem(
    Diagnostic diagnostic, {
    String? unit,
    String? target,
    int depth = 0,
  }) {
    _progressBoard?.failActiveAndSettle();
    report.problem(diagnostic, unit: unit, target: target);
    final where = diagnostic.source == null ? '' : '${diagnostic.source}  ';
    line(
      '$where${diagnostic.message}',
      mark: Mark.blocked,
      depth: depth,
      tone: Tone.bad,
    );
    if (diagnostic.remedy != null) {
      say(diagnostic.remedy!, depth: depth + 1);
    }
  }

  /// Every problem in one pass, so a fix cycle is one edit round.
  void problems(List<Diagnostic> found) {
    for (final diagnostic in found) {
      problem(diagnostic);
    }
  }

  /// A nonblocking diagnostic. Its stable code remains machine-readable.
  void warning(
    Diagnostic diagnostic, {
    String? unit,
    String? target,
    int depth = 0,
  }) {
    report.warning(diagnostic, unit: unit, target: target);
    final where = diagnostic.source == null ? '' : '${diagnostic.source}  ';
    line(
      '$where${diagnostic.message}',
      mark: Mark.warning,
      depth: depth,
      tone: Tone.attention,
    );
    if (diagnostic.remedy != null) {
      say(diagnostic.remedy!, depth: depth + 1);
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
      Mark.warning => '33', // yellow
      Mark.none => null,
    };
    return code == null ? mark.glyph : '\x1b[${code}m${mark.glyph}\x1b[0m';
  }
}

/// One live fixed-height progress surface.
///
/// Its model is terminal-agnostic; this class owns delayed display, redraw,
/// suspension around inherited-stdio tools, and the one settled snapshot that
/// survives. A caller must choose [discard] for a purely transient board or
/// [settle] for a board whose final state belongs in the transcript.
final class LiveProgress {
  LiveProgress._(
    this._output,
    String title,
    this._delayDuration, {
    required this.emitSlowToNonTerminal,
    required this.showElapsed,
  }) {
    model = ProgressModel(
      title: title,
      clock: _output._clock,
      changed: _changed,
    );
    if (_output.isTerminal) {
      _delay = Timer(_delayDuration, _showTerminal);
    }
  }

  final Output _output;
  final Duration _delayDuration;
  final bool emitSlowToNonTerminal;
  final bool showElapsed;
  late final ProgressModel model;
  final Map<String, ProgressRowController> _controllers = {};
  final Map<String, Timer> _nonTerminalDelays = {};
  final Map<String, ProgressActivity> _nonTerminalPrinted = {};
  final Map<String, ProgressActivity> _nonTerminalScheduled = {};
  Timer? _delay;
  Timer? _ticker;
  var _drawnLines = 0;
  var _spin = 0;
  var _closed = false;
  var _suspended = false;
  var _visible = false;
  var _delayElapsed = false;

  static const _frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

  ProgressRowController addRow({
    required String id,
    required String label,
    String? coordinate,
    String? group,
  }) {
    final controller = model.addRow(
      id: id,
      label: label,
      coordinate: coordinate,
      group: group,
    );
    _controllers[id] = controller;
    return controller;
  }

  void _changed(ProgressRow row) {
    if (_closed) return;
    if (_output.isTerminal) {
      if (_visible && !_suspended) {
        _draw();
      } else if (_delayElapsed && !_suspended && model.rows.isNotEmpty) {
        _showTerminal();
      }
      return;
    }
    if (!emitSlowToNonTerminal) return;
    if (row.state != ProgressRowState.active) {
      _nonTerminalDelays.remove(row.id)?.cancel();
      _nonTerminalScheduled.remove(row.id);
      return;
    }
    if (row.state != ProgressRowState.active || row.activity == null) return;
    final activity = row.activity!;
    if (_nonTerminalPrinted[row.id] == activity) {
      return;
    }
    if ((_nonTerminalDelays[row.id]?.isActive ?? false) &&
        _nonTerminalScheduled[row.id] == activity) {
      return;
    }
    _nonTerminalDelays.remove(row.id)?.cancel();
    _nonTerminalScheduled[row.id] = activity;
    _nonTerminalDelays[row.id] = Timer(_delayDuration, () {
      if (_closed ||
          row.state != ProgressRowState.active ||
          row.activity != activity) {
        return;
      }
      _nonTerminalScheduled.remove(row.id);
      _nonTerminalPrinted[row.id] = activity;
      final attached = identical(_output._progressBoard, this);
      if (attached) _output._progressBoard = null;
      _writeDurableRow(row, active: true);
      if (attached && !_closed) _output._progressBoard = this;
    });
  }

  void _showTerminal() {
    _delayElapsed = true;
    if (_closed || _suspended || model.rows.isEmpty) return;
    _ticker?.cancel();
    _visible = true;
    if (!_draw()) return;
    _ticker = Timer.periodic(
      const Duration(milliseconds: 120),
      (_) => _draw(),
    );
  }

  bool _draw() {
    if (_closed || _suspended || !_visible || model.rows.isEmpty) return false;
    final width = _output.terminalWidth;
    if (width == null || width < 12) {
      _ticker?.cancel();
      _erase();
      _visible = false;
      return false;
    }
    _erase();
    final lines = _transientLines(width);
    _output.sink('${lines.join('\n')}\n');
    _drawnLines = lines.length;
    _spin++;
    return true;
  }

  List<String> _transientLines(int available) {
    final lines = <String>[_fit(model.title, available)];
    final grouped = model.groups.isNotEmpty;
    for (final group in model.groups) {
      lines.add(_fit('  $group', available));
      for (final row in model.rows.where((row) => row.group == group)) {
        lines.add(_transientRow(row, available, depth: 2));
      }
    }
    for (final row in model.rows.where((row) => row.group == null)) {
      lines.add(_transientRow(row, available, depth: grouped ? 1 : 1));
    }
    return lines;
  }

  String _transientRow(ProgressRow row, int? available, {required int depth}) {
    final (glyph, status, tone) = _rowPresentation(row, active: true);
    final indent = '  ' * depth;
    final left =
        [row.label, if (row.coordinate != null) row.coordinate!].join('  ');
    final overhead = _displayWidth(indent) + _displayWidth(glyph) + 3;
    const minimumSubjectWidth = 6;
    final room = available == null ? null : _atLeastZero(available - overhead);
    final wantedStatus = _displayWidth(status);
    final statusBudget = room == null
        ? wantedStatus
        : _lesser(wantedStatus, _atLeastZero(room - minimumSubjectWidth - 2));
    final leftWidth = available == null
        ? _displayWidth(left)
        : _atLeastZero(available - overhead - statusBudget - 2);
    final fitted = _fit(left, leftWidth);
    final fittedLeft =
        '$fitted${' ' * _atLeastZero(leftWidth - _displayWidth(fitted))}';
    final remaining = available == null
        ? null
        : _atLeastZero(available - overhead - _displayWidth(fittedLeft) - 2);
    final fittedStatus = _fit(status, remaining);
    final gap = fittedLeft.isEmpty || fittedStatus.isEmpty ? '' : '  ';
    return '$indent$glyph $fittedLeft$gap${_output._tint(fittedStatus, tone)}';
  }

  (String, String, Tone) _rowPresentation(
    ProgressRow row, {
    required bool active,
  }) {
    return switch (row.state) {
      ProgressRowState.pending => ('…', 'queued', Tone.muted),
      ProgressRowState.active => (
          active ? _frames[_spin % _frames.length] : '…',
          [
            row.activity!.running,
            if (row.detail != null) row.detail!,
            if (active && showElapsed) formatDuration(row.elapsed),
          ].join(' · '),
          Tone.attention,
        ),
      ProgressRowState.complete => (
          switch (row.mark) {
            ProgressRowMark.done => Mark.done.glyph,
            ProgressRowMark.satisfied => Mark.satisfied.glyph,
            ProgressRowMark.none => Mark.none.glyph,
          },
          row.note!,
          switch (row.emphasis) {
            ProgressRowEmphasis.plain => Tone.plain,
            ProgressRowEmphasis.muted => Tone.muted,
            ProgressRowEmphasis.attention => Tone.attention,
          },
        ),
      ProgressRowState.failed => (
          Mark.blocked.glyph,
          row.note!,
          Tone.bad,
        ),
      ProgressRowState.notAttempted => ('—', row.note!, Tone.muted),
    };
  }

  /// Temporarily yields the terminal to a native inherited-stdio command.
  ///
  /// The durable active line remains above the native output. [resume] starts
  /// a fresh board below it; it never erases what the native tool printed.
  void suspend() {
    if (_closed || _suspended) return;
    if (!_output.isTerminal) return;
    _suspended = true;
    _delay?.cancel();
    _ticker?.cancel();
    _erase();
    _visible = false;
    final attached = identical(_output._progressBoard, this);
    if (attached) _output._progressBoard = null;
    for (final row in model.rows.where(
      (row) => row.state == ProgressRowState.active,
    )) {
      _writeDurableRow(row, active: true);
    }
    if (attached) _output._progressBoard = this;
  }

  void resume({bool afterNativeOutput = false}) {
    if (_closed || !_suspended) return;
    _suspended = false;
    if (_output.isTerminal) {
      if (afterNativeOutput) _output.sink('\n');
      _showTerminal();
    }
  }

  /// Erases the transient surface without leaving a snapshot.
  void discard() {
    if (_closed) return;
    final printedRows = !_output.isTerminal && emitSlowToNonTerminal
        ? model.rows
            .where((row) =>
                _nonTerminalPrinted.containsKey(row.id) &&
                row.state != ProgressRowState.pending &&
                row.state != ProgressRowState.active)
            .toList()
        : const <ProgressRow>[];
    _closeTimers();
    _erase();
    _closed = true;
    if (identical(_output._progressBoard, this)) {
      _output._progressBoard = null;
    }
    for (final row in printedRows) {
      _writeDurableRow(row);
    }
  }

  /// Replaces the transient board with one append-only final snapshot.
  void settle({String? title}) {
    if (_closed) return;
    final unfinished = model.rows.where(
      (row) =>
          row.state == ProgressRowState.pending ||
          row.state == ProgressRowState.active,
    );
    if (unfinished.isNotEmpty) {
      throw StateError(
        'cannot settle progress with unfinished rows: '
        '${unfinished.map((row) => row.id).join(', ')}',
      );
    }
    _closeTimers();
    _erase();
    _closed = true;
    if (identical(_output._progressBoard, this)) {
      _output._progressBoard = null;
    }
    _output.heading(title ?? model.title);
    for (final group in model.groups) {
      _output.line(group, depth: 1);
      for (final row in model.rows.where((row) => row.group == group)) {
        _writeDurableRow(row, depth: 2);
      }
    }
    for (final row in model.rows.where((row) => row.group == null)) {
      _writeDurableRow(row, depth: 1);
    }
  }

  /// While held, a diagnostic does not settle the board. Concurrent lanes
  /// drain after a failure, and a problem printed mid-drain must not turn
  /// the other lanes' still-running rows into failures; the coordinator
  /// marks the one failed row itself and settles once the drain completes.
  var _holdSettle = false;

  // ignore: avoid_positional_boolean_parameters
  void holdSettle(bool value) => _holdSettle = value;

  /// Preserves the active operation as the failure point before diagnostics.
  ///
  /// Targets can still use the ordinary diagnostic surface: the renderer
  /// turns whichever row they were describing into the durable failed row
  /// and makes every untouched downstream row explicit.
  void failActiveAndSettle() {
    if (_closed || _holdSettle) return;
    if (!model.rows.any((row) => row.state == ProgressRowState.active)) {
      return;
    }
    settleStopped();
  }

  /// Settles a board whose run stopped: still-active rows fail, untouched
  /// pending rows become an explicit "not attempted", and the board becomes
  /// its durable snapshot. Unlike [failActiveAndSettle], a fully drained
  /// board — every lane already finished or failed — still settles.
  void settleStopped() {
    if (_closed) return;
    final active = model.rows
        .where((row) => row.state == ProgressRowState.active)
        .toList();
    for (final row in active) {
      _controllers[row.id]!.fail();
    }
    for (final row in model.rows.where(
      (row) => row.state == ProgressRowState.pending,
    )) {
      _controllers[row.id]!.notAttempted();
    }
    settle();
  }

  void _writeDurableRow(
    ProgressRow row, {
    int depth = 1,
    bool active = false,
  }) {
    final (glyph, status, tone) = _rowPresentation(row, active: active);
    final mark = switch (glyph) {
      '✓' => Mark.done,
      '·' => Mark.satisfied,
      '✗' => Mark.blocked,
      _ => Mark.none,
    };
    final subject =
        [row.label, if (row.coordinate != null) row.coordinate!].join(' · ');
    final label = glyph == '—' || glyph == '…' ? '$glyph $subject' : subject;
    _output.line(
      label,
      mark: mark,
      note: status,
      depth: depth,
      labelWidth: 48,
      noteTone: tone,
    );
  }

  void _closeTimers() {
    _delay?.cancel();
    _ticker?.cancel();
    for (final timer in _nonTerminalDelays.values) {
      timer.cancel();
    }
    _nonTerminalDelays.clear();
    _nonTerminalScheduled.clear();
  }

  void _erase() {
    for (var i = 0; i < _drawnLines; i++) {
      _output.sink('\x1b[1A\r\x1b[2K');
    }
    _drawnLines = 0;
  }

  static int _atLeastZero(int value) => value < 0 ? 0 : value;

  static int _lesser(int left, int right) => left < right ? left : right;

  static String _fit(String text, int? width) {
    if (width == null || _displayWidth(text) <= width) return text;
    if (width <= 0) return '';
    if (width == 1) return '…';
    final out = StringBuffer();
    var used = 0;
    for (final rune in text.runes) {
      final next = _runeWidth(rune);
      if (used + next > width - 1) break;
      out.writeCharCode(rune);
      used += next;
    }
    return '${out.toString()}…';
  }

  static int _displayWidth(String text) =>
      text.runes.fold(0, (width, rune) => width + _runeWidth(rune));

  static int _runeWidth(int rune) {
    if ((rune >= 0x0300 && rune <= 0x036f) ||
        (rune >= 0x1ab0 && rune <= 0x1aff) ||
        (rune >= 0x1dc0 && rune <= 0x1dff) ||
        (rune >= 0xfe20 && rune <= 0xfe2f)) {
      return 0;
    }
    if (rune >= 0x1100 &&
        (rune <= 0x115f ||
            rune == 0x2329 ||
            rune == 0x232a ||
            (rune >= 0x2e80 && rune <= 0xa4cf && rune != 0x303f) ||
            (rune >= 0xac00 && rune <= 0xd7a3) ||
            (rune >= 0xf900 && rune <= 0xfaff) ||
            (rune >= 0xfe10 && rune <= 0xfe19) ||
            (rune >= 0xfe30 && rune <= 0xfe6f) ||
            (rune >= 0xff00 && rune <= 0xff60) ||
            (rune >= 0xffe0 && rune <= 0xffe6) ||
            (rune >= 0x1f300 && rune <= 0x1faff) ||
            (rune >= 0x20000 && rune <= 0x3fffd))) {
      return 2;
    }
    return 1;
  }
}

/// Compatibility adapter for status's parallel public-target reads.
///
/// It now uses the same renderer that staging and release use, while retaining
/// status's existing add/finish API and fully transient behavior.
final class TargetChecks {
  TargetChecks._(Output output, Duration delay)
      : _board = output.progressBoard(
          'Release targets',
          delay: delay,
          showElapsed: false,
        );

  final LiveProgress _board;
  final Map<String, ProgressRowController> _rows = {};
  var _closed = false;

  void add(String id, String label) {
    if (_closed || _rows.containsKey(id)) return;
    final row = _board.addRow(id: id, label: label);
    _rows[id] = row;
    row.handle.begin(CommonProgressActivities.checking);
  }

  void finish(String id, Verdict verdict) {
    if (_closed) return;
    final row = _rows[id];
    if (row == null) return;
    switch (verdict) {
      case Verdict.exact:
        row.complete(note: 'checked');
      case Verdict.absent:
        row.complete(note: 'checked', mark: ProgressRowMark.none);
      case Verdict.conflict:
        row.fail(note: 'differs');
      case Verdict.unknown:
        row.complete(
          note: 'unread',
          mark: ProgressRowMark.none,
          emphasis: ProgressRowEmphasis.attention,
        );
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _board.discard();
  }
}

/// Which of the two questions an operator has a halt is answering.
enum HaltKind {
  /// No public target changed. Private preparation or native login may have.
  beforeActing,

  /// The run stopped between acts; what completed stays done, nothing was
  /// lost sight of, and the next run continues from what it finds.
  ///
  /// Added with the local chain, whose failures — a build that does not
  /// compile, a notarization Apple rejects — stop a run that may already
  /// have acted (a pushed tag). "nothing changed" would be false there, and
  /// "lost sight of the result" would be too: the result was read, and it
  /// was a refusal.
  stoppedPartway,

  /// Something may have happened; the next run classifies what it finds.
  lostTrack,

  /// Something is wrong that re-running will not resolve.
  unfixableByRerun,

  /// rk acted, read the result back, and the result is permanently wrong.
  ///
  /// The pre-act sentence said "rk did not act" about the worst path rk has
  /// — a mismatch read back one step after a real publish — which answered
  /// the halt's own first question falsely.
  actedAndUnfixable,
}

/// Process exit codes, from the RFC's output contract.
class ExitCodes {
  /// Clean, complete, or blocked — blocked is a state, not a failure.
  static const ok = 0;

  /// A refusal: a validation error, a conflict, or an unknown verdict.
  static const refused = 1;

  /// The command was used incorrectly.
  static const usage = 2;

  /// rk itself failed — not a refusal, and worth different handling: a
  /// refusal has a remedy, a crash has a diagnosis directory and a bug.
  static const crashed = 3;
}

/// How long something has been running.
///
/// A function rather than a `Stopwatch` so liveness can be tested without
/// waiting: the wall clock is one implementation of it, and a test's counter is
/// another.
typedef Elapsed = Duration Function();

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
