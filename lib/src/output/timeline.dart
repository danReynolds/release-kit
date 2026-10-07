import 'dart:convert';

import 'output.dart' show Elapsed, formatDuration, terminalSafeText;

/// One command's phases, the rows it showed, and the time it spent waiting
/// on a person: what the closing summary and `--timings` report.
///
/// It is recorded on every run, because it costs a few list entries. It is
/// shown only on a terminal (the summary) or on request (`--timings`), so
/// pipes and `--json` stay the same from run to run.
///
/// The phases cover the run from its first moment: until a command names
/// its first phase, the run is `starting`, so setup that is slow (reading
/// the repository, probing the toolchain) is named like any other phase.
final class RunTimeline {
  RunTimeline(Elapsed Function() clock) : _since = clock() {
    _phases.add(_Phase('starting', Duration.zero));
  }

  /// Time since the run began, waits included.
  final Elapsed _since;

  final List<_Phase> _phases = [];
  final List<({Duration start, Duration end})> _waits = [];
  final List<_Row> _rows = [];

  /// Starts the phase named [name], ending the one before it.
  void phase(String name) {
    endPhase();
    _phases.add(_Phase(name, _since()));
  }

  /// Ends the current phase, if one is running.
  void endPhase() {
    final current = _phases.lastOrNull;
    if (current != null && current.end == null) current.end = _since();
  }

  /// Runs [body], a wait on a person: rk asking at the terminal. Its time
  /// counts toward no phase and no total, because a release that sat at a
  /// prompt over lunch did not take an hour. A native tool that asks a
  /// person something is still doing the work, and is not one.
  Future<T> waitingOnPerson<T>(Future<T> Function() body) async {
    final start = _since();
    try {
      return await body();
    } finally {
      _waits.add((start: start, end: _since()));
    }
  }

  /// Records a row that ran for [took] and has just settled, under [board],
  /// the title of the board that showed it. [subject] says what the row is
  /// about, in the board's own words.
  void rowSettled({
    required String board,
    required String id,
    required String subject,
    required String? note,
    required Duration took,
  }) {
    final end = _since();
    _rows.add(
      _Row(
        board: board,
        id: id,
        subject: subject,
        note: note,
        start: end - took,
        end: end,
      ),
    );
  }

  /// Working time between [start] and [end]: the interval less any wait on a
  /// person inside it.
  Duration _work(Duration start, Duration end) {
    var work = end - start;
    for (final wait in _waits) {
      final from = wait.start > start ? wait.start : start;
      final to = wait.end < end ? wait.end : end;
      if (to > from) work -= to - from;
    }
    return work;
  }

  /// The run's working time so far.
  Duration get working => _work(Duration.zero, _since());

  /// Time spent waiting on a person so far.
  Duration get waited => _waits.fold(
    Duration.zero,
    (total, wait) => total + (wait.end - wait.start),
  );

  /// The closing line on a terminal, such as
  /// `Done in 2m 31s · checking stages 31s · staging 1m 58s`, or null when
  /// the run took under ten seconds, quick enough that nobody wondered where
  /// the time went. Phases under a second are left out.
  String? summaryLine() {
    endPhase();
    final total = working;
    if (total < const Duration(seconds: 10)) return null;
    return [
      'Done in ${formatDuration(total)}',
      for (final phase in _phases)
        if (_work(phase.start, phase.end!) >= const Duration(seconds: 1))
          '${phase.name} ${formatDuration(_work(phase.start, phase.end!))}',
    ].join(' · ');
  }

  /// The `--timings` breakdown: each phase, then each row that ran during
  /// it, under the board that showed it. Every row is listed, however fast,
  /// in the words the run already used.
  String breakdown() {
    endPhase();
    final out = StringBuffer('Timings\n');
    final unplaced = [..._rows];
    for (final phase in _phases) {
      _writeTimed(out, phase.name, _work(phase.start, phase.end!), depth: 1);
      final inside = [
        for (final row in unplaced)
          if (row.start >= phase.start && row.end <= phase.end!) row,
      ];
      unplaced.removeWhere(inside.contains);
      _writeRows(out, inside, depth: 2);
    }
    if (unplaced.isNotEmpty) {
      out.writeln('  across phases');
      _writeRows(out, unplaced, depth: 2);
    }
    final waited = this.waited;
    // A neutral word: the breakdown is printed for a run that stopped, too.
    out.writeln(
      'Total ${_precise(working)}'
      '${waited > Duration.zero ? ', not counting ${_precise(waited)} waiting on you' : ''}',
    );
    return out.toString();
  }

  /// [rows] under their boards, each board once even when rk showed it in
  /// more than one pass, in the order the boards first appeared.
  void _writeRows(StringBuffer out, List<_Row> rows, {required int depth}) {
    final boards = <String, List<_Row>>{};
    for (final row in rows..sort((a, b) => a.start.compareTo(b.start))) {
      (boards[row.board] ??= []).add(row);
    }
    for (final MapEntry(key: board, value: shown) in boards.entries) {
      out.writeln('${'  ' * depth}${terminalSafeText(board)}');
      for (final row in shown) {
        _writeTimed(
          out,
          row.note == null ? row.subject : '${row.subject}  ${row.note}',
          row.took,
          depth: depth + 1,
        );
      }
    }
  }

  /// One line ending in [took], aligned with the lines around it unless
  /// [text] is too long to leave room. The text came from boards and tools,
  /// so it is made inert before it reaches a terminal.
  static void _writeTimed(
    StringBuffer out,
    String text,
    Duration took, {
    required int depth,
  }) {
    final indented = '${'  ' * depth}${terminalSafeText(text)}';
    final width = indented.runes.length;
    final gap = width < 56 ? 56 - width : 2;
    out.writeln('$indented${' ' * gap}${_precise(took)}');
  }

  /// The same run as Chrome trace events, which Perfetto and
  /// `chrome://tracing` open: phases on one track, each row on its own, and
  /// waits on a person marked where they fell.
  String traceJson() {
    endPhase();
    int micros(Duration d) => d.inMicroseconds;
    final events = <Map<String, Object?>>[
      {
        'name': 'thread_name',
        'ph': 'M',
        'pid': 1,
        'tid': 1,
        'args': {'name': 'phases'},
      },
      for (final phase in _phases)
        {
          'name': phase.name,
          'cat': 'phase',
          'ph': 'X',
          'ts': micros(phase.start),
          'dur': micros(phase.end! - phase.start),
          'pid': 1,
          'tid': 1,
        },
      for (final wait in _waits)
        {
          'name': 'waiting on you',
          'cat': 'wait',
          'ph': 'X',
          'ts': micros(wait.start),
          'dur': micros(wait.end - wait.start),
          'pid': 1,
          'tid': 1,
        },
      for (final (index, row) in _rows.indexed) ...[
        {
          'name': 'thread_name',
          'ph': 'M',
          'pid': 1,
          'tid': index + 2,
          'args': {'name': '${row.board} · ${row.subject}'},
        },
        {
          'name': row.subject,
          'cat': 'row',
          'ph': 'X',
          'ts': micros(row.start),
          'dur': micros(row.took),
          'pid': 1,
          'tid': index + 2,
          'args': {'board': row.board, 'row': row.id, 'note': ?row.note},
        },
      ],
    ];
    return '${const JsonEncoder.withIndent('  ').convert({'traceEvents': events, 'displayTimeUnit': 'ms'})}\n';
  }

  /// Tenths under ten seconds, so fast steps can still be told apart; the
  /// terminal's format above that. Both round down, so a time never reads
  /// longer than one beside it that took longer.
  static String _precise(Duration d) => d < const Duration(seconds: 10)
      ? '${d.inMilliseconds ~/ 1000}.${d.inMilliseconds % 1000 ~/ 100}s'
      : formatDuration(d);
}

final class _Phase {
  _Phase(this.name, this.start);

  final String name;
  final Duration start;
  Duration? end;
}

final class _Row {
  _Row({
    required this.board,
    required this.id,
    required this.subject,
    required this.note,
    required this.start,
    required this.end,
  });

  final String board;
  final String id;
  final String subject;
  final String? note;
  final Duration start;
  final Duration end;

  Duration get took => end - start;
}
