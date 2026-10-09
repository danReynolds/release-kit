part of 'output.dart';

/// Long enough that a preparation board helps instead of flashing briefly.
const briefPhase = Duration(milliseconds: 800);

/// What a row is doing, in the words of whoever does it, and how a definite
/// failure of it reads: no operation starts without saying how its failure
/// reads. Records compare by value, so the same words are the same activity.
typedef Activity = ({String running, String failed});

/// Conventional wording, for work these words describe. A target says
/// something else when they do not.
abstract final class Activities {
  static const checking = (running: 'checking', failed: 'check failed');
  static const checkingSignIn = (
    running: 'checking sign-in',
    failed: 'sign-in check failed',
  );
  static const validating = (
    running: 'validating',
    failed: 'validation failed',
  );
  static const verifying = (
    running: 'verifying',
    failed: 'verification failed',
  );
}

enum RowState { pending, active, complete, failed, notAttempted }

/// The rows one piece of work fills, as the work itself gets them: it can
/// say what it is doing, while only the board's owner settles a row.
extension type const Rows(List<Row> _rows) {
  Activity? get activity => _rows.firstOrNull?.activity;

  /// Whether these rows are still at work, and so may be redrawn.
  bool get active =>
      _rows.isNotEmpty && _rows.every((row) => row.state == RowState.active);

  /// The first row alone, for detail the others would only repeat, such as
  /// the latest line of a build that makes them all.
  Rows get first => _rows.length <= 1 ? this : Rows([_rows.first]);

  void begin(Activity activity, {String? detail}) {
    for (final row in _rows) {
      row.begin(activity, detail: detail);
    }
  }
}

/// One row of a [Board].
///
/// Every call is idempotent: one that comes too late for the row, such as a
/// begin after it settled, is ignored and notifies nothing, so the timeline
/// hears of each row once and a lane that drains after a stop cannot crash
/// the report of it.
final class Row {
  Row._(this._board, this.id, String label, String? coordinate, this.group)
    : label = oneLine(label),
      coordinate = coordinate == null ? null : oneLine(coordinate, max: 160);

  final Board _board;
  final String id;
  final String label;
  final String? coordinate;
  final String? group;

  RowState _state = RowState.pending;
  Mark _mark = Mark.none;
  RuntimeState _tone = RuntimeState.neutral;
  Activity? _activity;
  String? _detail;
  String? _note;
  Elapsed? _elapsed;

  /// The stopwatch of the row's first activity; [elapsed] restarts with
  /// each new activity, this one does not.
  Elapsed? _activeSince;
  Duration? _took;

  /// A pipe's heartbeat: restarted when the row's activity changes, it says
  /// the activity once if the row is still at it when the timer fires.
  Timer? _heartbeat;
  Activity? _announced;

  RowState get state => _state;

  /// A settled row's mark, and the state its note is drawn in.
  Mark get mark => _mark;
  RuntimeState get tone => _tone;
  Activity? get activity => _activity;
  String? get detail => _detail;
  String? get note => _note;
  Duration get elapsed => _elapsed?.call() ?? Duration.zero;

  /// How long the row was active in all, from its first activity to its
  /// settlement. Null for a row that has not settled, or never ran (one
  /// restored from a receipt, or never begun).
  Duration? get took => _took;

  /// How long the row has been active: [took] once it settles, the time so
  /// far while it runs, and null if it never ran.
  Duration? get ranFor => _took ?? _activeSince?.call();

  /// What the row is about: its label, and its coordinate when it has one.
  String get subject => coordinate == null ? label : '$label · $coordinate';

  Rows get rows => Rows([this]);

  bool get _settled =>
      _state == RowState.complete ||
      _state == RowState.failed ||
      _state == RowState.notAttempted;

  /// Says what the row is doing now. Ignored once it has settled.
  void begin(Activity activity, {String? detail}) {
    if (_settled) return;
    if (_activity != activity) {
      _elapsed = _board._output._clock();
      _board._beat(this, activity);
    }
    _activeSince ??= _elapsed;
    _activity = activity;
    _detail = detail == null ? null : oneLine(detail);
    _note = null;
    _state = RowState.active;
    _board._changed(this);
  }

  /// Says why a pending row cannot start yet.
  void wait(String note) {
    if (_state != RowState.pending) return;
    _note = oneLine(note);
    _board._changed(this);
  }

  /// Settles the row with [note], drawn in [tone]. A pending row is
  /// restored from what a receipt or a read already proved: it never ran,
  /// so it keeps no time.
  void complete(
    String note, {
    Mark mark = Mark.done,
    RuntimeState tone = RuntimeState.satisfied,
  }) {
    if (_settled) return;
    _mark = mark;
    _tone = tone;
    _settle(RowState.complete, note);
  }

  /// Settles an active row as failed: [note], or how its activity fails.
  void fail({Activity? activity, String? note}) {
    if (_state != RowState.active) return;
    _activity = activity ?? _activity;
    _settle(RowState.failed, note ?? _activity?.failed ?? 'failed');
  }

  /// Settles a row whose work never ran. An active one is a drained lane:
  /// its in-flight step finished after a stop elsewhere, and the time it
  /// ran stands.
  void skip({String note = 'not attempted'}) {
    if (_settled) return;
    _settle(RowState.notAttempted, note);
  }

  void _settle(RowState state, String note) {
    _note = oneLine(note);
    _detail = null;
    _took = _activeSince?.call();
    _state = state;
    _heartbeat?.cancel();
    _board._changed(this);
  }
}

/// One live, fixed-height board of rows.
///
/// On a terminal it appears after [delay], so fast work does not flicker,
/// redraws as its rows change, steps aside for prose and for native tools
/// that take the terminal, and leaves one settled snapshot or nothing. A
/// pipe sees only that snapshot, and on a heartbeat board one untimed line
/// for a row still at one activity after `heartbeatAfter`: a long build or
/// a sign-in, never a read that answers in a moment, so the transcript is
/// the same from run to run. Its owner ends it: [settle], [conclude] or
/// [discard].
final class Board {
  Board._(
    this._output,
    String title,
    Duration delay, {
    required bool heartbeat,
    required Duration heartbeatAfter,
    required bool elapsed,
  }) : title = oneLine(title),
       _heartbeat = heartbeat && !_output.isTerminal,
       _heartbeatAfter = heartbeatAfter,
       _showElapsed = elapsed {
    if (_output.isTerminal) _delay = Timer(delay, _showTerminal);
  }

  final Output _output;
  final String title;
  final bool _heartbeat;
  final Duration _heartbeatAfter;
  final bool _showElapsed;
  final List<Row> _rows = [];
  final List<String> _groups = [];
  Timer? _delay;
  Timer? _ticker;
  var _drawnLines = 0;
  var _spin = 0;
  var _closed = false;
  var _suspended = false;
  var _visible = false;
  var _delayElapsed = false;

  static const _frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

  /// The rows, in the order they were added; [groups] in the order they
  /// first appeared. The board is drawn in that order, which is what lets
  /// it erase exactly the lines it drew.
  List<Row> get rows => List.unmodifiable(_rows);
  List<String> get groups => List.unmodifiable(_groups);

  Row add(String id, String label, {String? coordinate, String? group}) {
    if (_rows.any((row) => row.id == id)) {
      throw StateError('duplicate progress row $id');
    }
    final safeGroup = group == null ? null : oneLine(group);
    if (safeGroup != null && !_groups.contains(safeGroup)) {
      _groups.add(safeGroup);
    }
    final row = Row._(this, id, label, coordinate, safeGroup);
    _rows.add(row);
    _changed(row);
    return row;
  }

  Row operator [](String id) => _rows.firstWhere((row) => row.id == id);

  /// Settles every row still pending as never attempted.
  void skipPending() {
    for (final row in _rows) {
      if (row.state == RowState.pending) row.skip();
    }
  }

  void _changed(Row row) {
    if (_closed) return;
    // A row settles once, so this records it once. One still running when
    // its board was discarded was recorded then, as unfinished.
    if (row.took case final took?) _time(row, took, note: row.note);
    if (!_output.isTerminal) return;
    if (_visible && !_suspended) {
      _draw();
    } else if (_delayElapsed && !_suspended && _rows.isNotEmpty) {
      _showTerminal();
    }
  }

  /// Restarts [row]'s heartbeat for [activity], on a heartbeat board in a
  /// pipe.
  void _beat(Row row, Activity activity) {
    if (!_heartbeat || _closed) return;
    row._heartbeat?.cancel();
    row._heartbeat = Timer(_heartbeatAfter, () {
      if (row._state != RowState.active ||
          row._activity != activity ||
          row._announced == activity) {
        return;
      }
      row._announced = activity;
      _writeDurableRow(row, active: true, inPipe: true);
    });
  }

  /// Clears the transient region so a durable line can join the transcript;
  /// the board repaints beneath it a frame later. Prose composes with a live
  /// board — only the owner's settle, conclude, or discard ends one.
  void _yieldToProse() {
    if (_closed || _suspended || !_visible) return;
    _erase();
    _visible = false;
    _ticker?.cancel();
    _ticker = Timer(const Duration(milliseconds: 40), _showTerminal);
  }

  void _showTerminal() {
    _delayElapsed = true;
    if (_closed || _suspended || _rows.isEmpty) return;
    _ticker?.cancel();
    _visible = true;
    if (!_draw()) return;
    _ticker = Timer.periodic(const Duration(milliseconds: 120), (_) => _draw());
  }

  bool _draw() {
    if (_closed || _suspended || !_visible || _rows.isEmpty) return false;
    final width = _output.terminalWidth;
    if (width == null || width < 12) {
      _ticker?.cancel();
      _erase();
      _visible = false;
      return false;
    }
    _erase();
    final lines = [
      _output._style(_fit(title, width), strong: true),
      for (final group in _groups) ...[
        _output._style(
          _fit('  $group', width),
          role: VisualRole.secondary,
          strong: true,
        ),
        for (final row in _rows.where((row) => row.group == group))
          _transientRow(row, width, depth: 2),
      ],
      for (final row in _rows.where((row) => row.group == null))
        _transientRow(row, width, depth: 1),
    ];
    _output.sink('${lines.join('\n')}\n');
    _drawnLines = lines.length;
    _spin++;
    return true;
  }

  /// [row] fitted to one physical line of [available] columns, which is
  /// what lets cursor-up erase it exactly.
  String _transientRow(Row row, int available, {required int depth}) {
    final (glyph, rawStatus, glyphState, textState) = _presentation(
      row,
      active: true,
    );
    final indent = '  ' * depth;
    final left = terminalSafeText([row.label, ?row.coordinate].join('  '));
    final overhead = _width(indent) + _width(glyph) + 3;
    const minimumSubjectWidth = 6;
    final subjectWidth = max(_width(left), minimumSubjectWidth);
    final status = terminalSafeText(
      _detailGivesWay(row, rawStatus, available - overhead - subjectWidth - 2),
    );
    final room = max(available - overhead, 0);
    final statusBudget = min(
      _width(status),
      max(room - minimumSubjectWidth - 2, 0),
    );
    final leftWidth = max(available - overhead - statusBudget - 2, 0);
    final fitted = _fit(left, leftWidth);
    final fittedLeft = '$fitted${' ' * max(leftWidth - _width(fitted), 0)}';
    final fittedStatus = _fit(
      status,
      max(available - overhead - _width(fittedLeft) - 2, 0),
    );
    final gap = fittedLeft.isEmpty || fittedStatus.isEmpty ? '' : '  ';
    return '$indent${_output._style(glyph, state: glyphState)} '
        '${_output._style(fittedLeft, state: glyphState)}$gap'
        '${_output._style(fittedStatus, state: textState)}';
  }

  /// [status], with an active row's long detail shortened or left out so
  /// that it fits in [room] beside the whole label. The label and the elapsed
  /// time say more than a long detail does, such as a build's latest line;
  /// a short one, such as an upload's count, keeps its place.
  String _detailGivesWay(Row row, String status, int room) {
    final detail = row.detail;
    if (detail == null ||
        row.state != RowState.active ||
        _width(detail) <= 12 ||
        _width(status) <= room) {
      return status;
    }
    final elapsed = [if (_showElapsed) formatDuration(row.elapsed)];
    final without = [row.activity!.running, ...elapsed].join(' · ');
    final detailRoom = room - _width(without) - 3;
    if (detailRoom < 10) return without;
    return [
      row.activity!.running,
      _fit(detail, detailRoom),
      ...elapsed,
    ].join(' · ');
  }

  /// How [row] reads: its glyph, its words, and the states that colour
  /// each. [active] draws a running row's spinner and time.
  (String, String, RuntimeState, RuntimeState) _presentation(
    Row row, {
    required bool active,
    bool inPipe = false,
  }) => switch (row.state) {
    RowState.pending => (
      '…',
      row.note ?? 'queued',
      RuntimeState.satisfied,
      RuntimeState.satisfied,
    ),
    RowState.active => (
      active ? _frames[_spin % _frames.length] : '…',
      [
        row.activity!.running,
        // A count such as `2/6` is wherever the step had got to when the
        // row was written: a pipe gets the step, not the moment.
        if (row.detail != null && !inPipe) row.detail!,
        if (active && _showElapsed) formatDuration(row.elapsed),
      ].join(' · '),
      RuntimeState.active,
      RuntimeState.active,
    ),
    RowState.complete => (row.mark.glyph, row.note!, row.mark.state, row.tone),
    RowState.failed => (
      Mark.blocked.glyph,
      row.note!,
      RuntimeState.failure,
      RuntimeState.failure,
    ),
    RowState.notAttempted => (
      '—',
      row.note!,
      RuntimeState.satisfied,
      RuntimeState.satisfied,
    ),
  };

  /// Temporarily yields the terminal to a native inherited-stdio command.
  ///
  /// The durable active line remains above the native output. [resume] starts
  /// a fresh board below it; it never erases what the native tool printed.
  void suspend() {
    if (_closed || _suspended || !_output.isTerminal) return;
    _suspended = true;
    _delay?.cancel();
    _ticker?.cancel();
    _erase();
    _visible = false;
    for (final row in _rows.where((row) => row.state == RowState.active)) {
      _writeDurableRow(row, active: true);
    }
  }

  void resume({bool afterNativeOutput = false}) {
    if (_closed || !_suspended) return;
    _suspended = false;
    if (afterNativeOutput) _output.sink('\n');
    _showTerminal();
  }

  /// Erases the transient surface without leaving a snapshot.
  void discard() {
    if (_closed) return;
    // Work cut off mid-run, such as by a crash, still took its time.
    for (final row in _rows) {
      if (row.state != RowState.active) continue;
      if (row.ranFor case final ran?) _time(row, ran, note: 'unfinished');
    }
    // A pipe told a row was under way hears how it ended.
    final announced = [
      for (final row in _rows)
        if (row._announced != null &&
            row.state != RowState.pending &&
            row.state != RowState.active)
          row,
    ];
    _close();
    for (final row in announced) {
      _writeDurableRow(row, inPipe: true);
    }
  }

  /// Replaces the transient board with one append-only final snapshot,
  /// under [title] when the run's words for it changed.
  void settle({String? title}) {
    if (_closed) return;
    final unfinished = _rows.where(
      (row) => row.state == RowState.pending || row.state == RowState.active,
    );
    if (unfinished.isNotEmpty) {
      throw StateError(
        'cannot settle progress with unfinished rows: '
        '${unfinished.map((row) => row.id).join(', ')}',
      );
    }
    _close();
    _output.heading(title ?? this.title);
    for (final group in _groups) {
      _output.line(group, depth: 1, role: VisualRole.secondary, strong: true);
      for (final row in _rows.where((row) => row.group == group)) {
        _writeDurableRow(row, depth: 2);
      }
    }
    for (final row in _rows.where((row) => row.group == null)) {
      _writeDurableRow(row, depth: 1);
    }
  }

  /// Concludes a stopped run: still-active rows fail, untouched pending
  /// rows become an explicit "not attempted", and the board becomes its
  /// durable snapshot. A no-op on a board already settled or discarded.
  ///
  /// The renderer draws; the coordinator judges. A diagnostic never touches
  /// board state — the owner that began the rows marks them and concludes
  /// at its own halt sites, so a problem printed while concurrent lanes
  /// drain cannot turn innocent still-running rows into failures.
  void conclude() {
    if (_closed) return;
    for (final row in _rows) {
      if (row.state == RowState.active) row.fail();
    }
    skipPending();
    settle();
  }

  void _close() {
    _delay?.cancel();
    _ticker?.cancel();
    for (final row in _rows) {
      row._heartbeat?.cancel();
    }
    _erase();
    _closed = true;
    if (identical(_output._board, this)) _output._board = null;
  }

  /// Tells the run's timeline that [row] ran for [took]. Its group goes with
  /// it: rows under different groups can share a label.
  void _time(Row row, Duration took, {required String? note}) =>
      _output.timeline.rowSettled(
        board: title,
        id: row.id,
        subject: row.group == null
            ? row.subject
            : '${row.group} · ${row.subject}',
        note: note,
        took: took,
      );

  /// [inPipe] is a row a pipe is told about on its own, outside the
  /// board's snapshot: it names what it belongs to, and carries no time.
  void _writeDurableRow(
    Row row, {
    int depth = 1,
    bool active = false,
    bool inPipe = false,
  }) {
    var (glyph, status, glyphState, textState) = _presentation(
      row,
      active: active && !inPipe,
      inPipe: inPipe,
    );
    // A finished row that ran long enough for its counter to tick keeps its
    // total, on a terminal. A pipe's transcript stays the same every run.
    final took = row.took;
    if (!active &&
        _output.isTerminal &&
        took != null &&
        took >= const Duration(seconds: 1)) {
      status = '$status · ${formatDuration(took)}';
    }
    final subject = inPipe
        ? '${row.group ?? title} · ${row.subject}'
        : row.subject;
    _output.line(
      glyph == '—' || glyph == '…' ? '$glyph $subject' : subject,
      mark: switch (row.state) {
        RowState.complete => row.mark,
        RowState.failed => Mark.blocked,
        _ => Mark.none,
      },
      note: status,
      depth: depth,
      labelWidth: 48,
      state: glyphState,
      noteState: textState,
    );
  }

  void _erase() {
    for (var i = 0; i < _drawnLines; i++) {
      _output.sink('\x1b[1A\r\x1b[2K');
    }
    _drawnLines = 0;
  }

  static int _width(String text) => Output.displayWidth(text);

  static String _fit(String text, int width) {
    text = terminalSafeText(text);
    if (_width(text) <= width) return text;
    if (width <= 0) return '';
    if (width == 1) return '…';
    final out = StringBuffer();
    var used = 0;
    for (final rune in text.runes) {
      final next = _terminalRuneWidth(rune);
      if (used + next > width - 1) break;
      out.writeCharCode(rune);
      used += next;
    }
    return '$out…';
  }
}
