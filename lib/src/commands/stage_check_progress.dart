import '../engine/repository_stage_preparation.dart';
import '../engine/resolve.dart';
import '../output/output.dart';
import '../output/progress.dart';

/// The board for the repository-wide stage check that runs before any unit is
/// prepared: one row per unit while its saved stage is found and every staged
/// file verified, or, when there is none, while its dependencies resolve.
///
/// Without it this was the longest silence in a release: tens of seconds
/// after the last "Releasing" heading with nothing on screen, which reads
/// as a hang.
final class StageCheckProgress implements RepositoryPreparationObserver {
  StageCheckProgress(
    Output output, {
    required String repository,
    required List<ResolvedUnit> units,
    // The same grace the per-unit stage check gives a quick answer.
    Duration delay = const Duration(milliseconds: 800),
  }) : _board = output.progressBoard(
         '$repository · checking stages',
         delay: delay,
         emitSlowToNonTerminal: true,
       ) {
    for (final unit in units) {
      _rows[unit.name] = _board.addRow(
        id: 'stage-check/${unit.name}',
        label: '${unit.name} ${unit.version}',
        coordinate: 'saved stage',
      );
    }
  }

  static final _resolving = ProgressActivity(
    running: 'resolving dependencies',
    failed: 'resolution failed',
  );

  final LiveProgress _board;
  final Map<String, ProgressRowController> _rows = {};

  @override
  void restoring(ResolvedUnit unit) =>
      _rows[unit.name]?.handle.begin(CommonProgressActivities.verifying);

  @override
  void restored(ResolvedUnit unit, {required bool found}) {
    final row = _rows[unit.name];
    if (row == null) return;
    if (found) {
      row.complete(note: 'verified', mark: ProgressRowMark.satisfied);
    } else {
      // Still this unit's work: the check goes on to its public targets and,
      // if it is to be staged, its dependencies.
      row.handle.begin(
        CommonProgressActivities.checking,
        detail: 'no saved stage',
      );
    }
  }

  @override
  void discovering(ResolvedUnit unit) =>
      _rows[unit.name]?.handle.begin(_resolving);

  /// Settles the rows the check left open and takes the board down.
  void finish() {
    for (final row in _rows.values) {
      if (row.state != ProgressRowState.active) continue;
      row.complete(
        note: row.activity == _resolving ? 'resolved' : 'to stage',
        mark: ProgressRowMark.none,
      );
    }
    _board.discard();
  }

  /// Ends the board after a refusal: unfinished rows show they stopped.
  void stop() => _board.conclude();
}
