import '../engine/tools.dart';
import '../engine/unit_release.dart';
import '../engine/verdict.dart';
import '../output/output.dart';
import '../targets/target_module.dart';

/// Public-target rows rendered through RK's shared board.
final class TargetReleaseProgress {
  TargetReleaseProgress(
    Output output, {
    required String title,
    required Iterable<Target> targets,
    Duration delay = const Duration(milliseconds: 80),
  }) : _output = output,
       live = output.board(title, delay: delay, heartbeat: true) {
    for (final target in targets) {
      live.add(target.id, target.kindLabel, coordinate: target.coordinate);
    }
  }

  final Output _output;
  final Board live;

  Row _row(Target target) => live[target.id];

  Rows handle(Target target) => _row(target).rows;

  Rows combined(Iterable<Target> targets) =>
      Rows([for (final target in targets) _row(target)]);

  void waiting(Target target, {required String note}) =>
      _row(target).wait(note);

  void begin(Target target, Activity activity, {String? detail}) =>
      _row(target).begin(activity, detail: detail);

  void complete(
    Target target, {
    required String note,
    bool satisfied = false,
  }) =>
      _row(target).complete(note, mark: satisfied ? Mark.satisfied : Mark.done);

  void observe(Target target, Inspection inspection) {
    final row = _row(target);
    if (row.state != RowState.active) return;
    if (inspection.isExact) {
      row.complete('already published', mark: Mark.satisfied);
    } else if (inspection.isAbsent) {
      row.complete('not published', mark: Mark.none);
    } else {
      row.complete(
        inspection.verdict == Verdict.conflict ? 'conflict' : 'unreadable',
        mark: Mark.none,
        tone: RuntimeState.attention,
      );
    }
  }

  void fail(Target target, {Activity? activity, String? note}) =>
      _row(target).fail(activity: activity, note: note);

  void failAll(Iterable<Target> targets, {required Activity activity}) {
    for (final target in targets) {
      fail(target, activity: activity);
    }
  }

  void notAttemptedPending() => live.skipPending();

  ProgressInteractiveRunner interactive(Tools tools) {
    return (
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    }) async {
      live.suspend();
      try {
        return await tools.runInteractive(
          executable,
          arguments,
          workingDirectory: workingDirectory,
        );
      } finally {
        live.resume(afterNativeOutput: _output.isTerminal);
      }
    };
  }

  void discard() => live.discard();

  void settle({bool released = false}) => live.settle(
    title: released
        ? live.title.replaceFirst(' · releasing', ' · released')
        : null,
  );
}

/// Receipt-backed stage rows rendered through the shared board.
final class StageReleaseProgress {
  StageReleaseProgress(
    Output output, {
    required String title,
    required this.board,
  }) : live = output.board(title, heartbeat: true),
       _owned = true {
    _addRows(null);
  }

  /// One unit's rows on a board several units share, each group named for
  /// [unit]. The board's owner settles it; this only fills the rows.
  StageReleaseProgress.shared(
    this.live, {
    required this.board,
    required String unit,
  }) : _owned = false {
    _addRows(unit);
  }

  void _addRows(String? unit) {
    for (final group in board) {
      for (final row in group.rows) {
        _rows[row] = live.add(
          row.id,
          row.name,
          group: unit == null ? group.label : '$unit · ${group.label}',
        );
      }
    }
  }

  /// The rows this stage fills, by destination: see [UnitRelease.board].
  final List<BoardGroup> board;
  final Board live;
  final bool _owned;
  final Map<BoardRow, Row> _rows = {};

  /// Each recorded producer's evidence, by its name.
  final Map<String, Map<String, Object?>> _recorded = {};

  /// The rows [producer] fills, in board order. Work whose output reaches
  /// no destination — the release notes — fills none, and says nothing.
  List<BoardRow> _rowsFor(String producer) => [
    for (final group in board)
      for (final row in group.rows)
        if (row.filledBy.any((work) => work.name == producer)) row,
  ];

  Rows? handleFor(String producer) {
    final rows = _rowsFor(producer);
    if (rows.isEmpty) return null;
    return Rows([for (final row in rows) _rows[row]!]);
  }

  void begin(String producer, Activity activity) {
    for (final row in _rowsFor(producer)) {
      _rows[row]!.begin(activity);
    }
  }

  /// Fills the rows every producer in [producers] completes: what a
  /// receipt records, by name, with each one's evidence.
  void restore(Map<String, Map<String, Object?>> producers) {
    _recorded.addAll(producers);
    for (final group in board) {
      for (final row in group.rows) {
        final expected = {for (final work in row.filledBy) work.name};
        if (expected.isEmpty || !expected.every(_recorded.containsKey)) {
          continue;
        }
        final filled = _rows[row]!;
        filled.complete(
          _noteFor(expected),
          mark: filled.state == RowState.pending ? Mark.satisfied : Mark.done,
        );
      }
    }
  }

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

  void fail(String producer) {
    for (final row in _rowsFor(producer)) {
      _rows[row]!.fail();
    }
  }

  void conclude() {
    if (_owned) live.conclude();
  }

  /// Ends this unit's part without producing anything. On a shared board
  /// its rows say they were not attempted.
  void discard() {
    if (_owned) {
      live.discard();
      return;
    }
    for (final row in _rows.values) {
      row.skip();
    }
  }

  void concludeStopped() {
    for (final row in _rows.values) {
      if (row.state == RowState.active) row.skip();
    }
    if (_owned) live.conclude();
  }

  void settle({String? title}) {
    if (_owned) live.settle(title: title);
  }
}
