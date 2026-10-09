import '../engine/receipt.dart';
import '../engine/tools.dart';
import '../engine/unit_release.dart';
import '../engine/verdict.dart';
import '../output/output.dart';
import '../targets/target_module.dart';

/// A board with a row for each of [targets], by target id. A pipe hears of
/// a row still at one thing after a while: a sign-in or a long upload.
Board targetBoard(
  Output output,
  String title,
  Iterable<Target> targets, {
  Duration delay = const Duration(milliseconds: 80),
}) {
  final board = output.board(title, delay: delay, heartbeat: true);
  for (final target in targets) {
    board.add(target.id, target.kindLabel, coordinate: target.coordinate);
  }
  return board;
}

/// Settles [row], checking its target, with what the read found.
void observe(Row row, Inspection state) {
  if (row.state != RowState.active) return;
  if (state.isExact) {
    row.complete('already published', mark: Mark.satisfied);
  } else if (state.isAbsent) {
    row.complete('not published', mark: Mark.none);
  } else {
    row.complete(
      state.verdict == Verdict.conflict ? 'conflict' : 'unreadable',
      mark: Mark.none,
      tone: RuntimeState.attention,
    );
  }
}

/// Runs a native tool on the terminal [board] steps aside for.
ProgressInteractiveRunner interactive(Board board, Tools tools) =>
    (
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    }) async {
      board.suspend();
      try {
        return await tools.runInteractive(
          executable,
          arguments,
          workingDirectory: workingDirectory,
        );
      } finally {
        board.resume(afterNativeOutput: true);
      }
    };

/// Says, with the run's other warnings, what [receipt]'s work found while
/// it staged [release], each with the target that work prepares.
void deferStageWarnings(Output output, UnitRelease release, Receipt receipt) {
  for (final work in release.work) {
    for (final warning in receipt.warnings(work.name)) {
      output.deferWarning(
        warning,
        unit: release.unit.name,
        target: release.preparing(work)?.id,
      );
    }
  }
}

/// One unit's stage rows on a board: those [UnitRelease.board] lists, each
/// filled by the work that makes it. The board's owner ends the board.
final class StageRows {
  /// Adds [release]'s rows to [board], each group named for [unit] when
  /// units stage side by side on one board.
  StageRows(Board board, UnitRelease release, {String? unit}) {
    for (final group in release.board) {
      for (final row in group.rows) {
        _rows[row] = board.add(
          row.id,
          row.name,
          group: unit == null ? group.label : '$unit · ${group.label}',
        );
      }
    }
  }

  final Map<BoardRow, Row> _rows = {};

  /// Each recorded producer's evidence, by its name.
  final Map<String, Map<String, Object?>> _recorded = {};

  /// The rows [work] fills, in board order. Work whose output reaches no
  /// destination — the release notes — fills none, and says nothing.
  List<Row> _of(Work work) => [
    for (final MapEntry(key: row, value: shown) in _rows.entries)
      if (row.filledBy.any((filler) => filler.name == work.name)) shown,
  ];

  Rows of(Work work) => Rows(_of(work));

  void begin(Work work, Activity activity) => of(work).begin(activity);

  /// Fills each row whose work [receipt] records: all of it, so a row
  /// several pieces of work make waits for the last.
  void restore(Receipt receipt) {
    _recorded.addAll(receipt.producers);
    for (final MapEntry(key: row, value: shown) in _rows.entries) {
      final expected = {for (final work in row.filledBy) work.name};
      if (expected.isEmpty || !expected.every(_recorded.containsKey)) continue;
      shown.complete(
        _noteFor(expected),
        mark: shown.state == RowState.pending ? Mark.satisfied : Mark.done,
      );
    }
  }

  /// What a filled row holds: staged, and signed and notarized when its
  /// work's evidence says so.
  String _noteFor(Set<String> producers) {
    final facts = <String>['staged'];
    for (final producer in producers) {
      final evidence = _recorded[producer]!;
      final signature = evidence['signature'];
      final notary = evidence['notary'];
      if (signature is Map && signature['certificate'] is String) {
        facts.add('signed');
      }
      if (notary is Map && notary['status'] == 'Accepted') {
        facts.add('notarized');
      }
    }
    return facts.toSet().join(' · ');
  }

  void fail(Work work) {
    for (final row in _of(work)) {
      row.fail();
    }
  }

  /// Ends this unit's part on a board units share, having produced
  /// nothing: its rows were not attempted.
  void abandon() {
    for (final row in _rows.values) {
      row.skip();
    }
  }

  /// After a stop elsewhere: what was under way when its lane drained was
  /// not attempted, rather than failed.
  void stopped() {
    for (final row in _rows.values) {
      if (row.state == RowState.active) row.skip();
    }
  }
}
