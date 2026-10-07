import '../engine/repository_stage_preparation.dart';
import '../engine/resolve.dart';
import '../output/output.dart';
import '../output/progress.dart';
import 'release_progress.dart';

/// The board for the repository-wide stage check that runs before any unit is
/// prepared: each unit's saved stage found and every staged file verified,
/// the units' public targets read, and the dependencies of units with no
/// stage resolved.
///
/// Without it this was the longest silence in a release: tens of seconds
/// after the last "Releasing" heading with nothing on screen, which reads
/// as a hang.
///
/// A row is active only while its own work runs. The check does one unit at
/// a time, so a row's time is that work's time, and a stop fails the row
/// that was running and no other. Reading public targets and resolving
/// dependencies each take one row, naming the unit at hand, so the board
/// grows by one line per unit rather than three.
final class StageCheckProgress implements RepositoryPreparationObserver {
  StageCheckProgress(
    Output output, {
    required List<ResolvedUnit> units,
    Duration delay = briefPhase,
  }) : _board = output.progressBoard(
         'Checking stages',
         delay: delay,
         emitSlowToNonTerminal: true,
       ) {
    units.forEach(_stage);
  }

  static final _resolving = ProgressActivity(
    running: 'resolving',
    failed: 'resolution failed',
  );

  final LiveProgress _board;
  final Map<String, ProgressRowController> _stages = {};
  ProgressRowController? _targets;
  ProgressRowController? _dependencies;

  /// The unit a shared row is at: in its detail while it runs, and in its
  /// failure if the check stops there.
  String? _at;

  /// [unit]'s saved-stage row. The selected units' rows exist from the start;
  /// a sibling's appears when its stage is looked for. Unit names have no
  /// `/`, so these ids cannot meet the shared rows'.
  ProgressRowController _stage(ResolvedUnit unit) =>
      _stages[unit.name] ??= _board.addRow(
        id: 'stage-check/${unit.name}/stage',
        label: '${unit.name} ${unit.version}',
        coordinate: 'saved stage',
      );

  @override
  void restoring(ResolvedUnit unit) =>
      _stage(unit).handle.begin(CommonProgressActivities.verifying);

  @override
  void restored(ResolvedUnit unit, {required bool found}) =>
      _stage(unit).complete(
        note: found ? 'verified' : 'none',
        mark: found ? ProgressRowMark.satisfied : ProgressRowMark.none,
      );

  @override
  void discovering(ResolvedUnit unit) {
    _at = '${unit.name} ${unit.version}';
    (_dependencies ??= _board.addRow(
      id: 'stage-check/dependencies',
      label: 'dependencies',
    )).handle.begin(_resolving, detail: _at);
  }

  @override
  void discovered() {
    _at = null;
    _dependencies?.complete(note: 'resolved');
  }

  /// Runs [body], the release command's read of [unit]'s public targets, on
  /// the row they share.
  Future<T> checkingPublicTargets<T>(
    ResolvedUnit unit,
    Future<T> Function() body,
  ) {
    _at = '${unit.name} ${unit.version}';
    (_targets ??= _board.addRow(
      id: 'stage-check/public-targets',
      label: 'public targets',
    )).handle.begin(CommonProgressActivities.checking, detail: _at);
    return body();
  }

  /// Every unit's public targets have been read.
  void publicTargetsChecked() {
    _at = null;
    _targets?.complete(note: 'checked', mark: ProgressRowMark.none);
  }

  /// Takes the board down once the check has finished. Every row has already
  /// settled on what its own work found.
  void finish() {
    assert(
      _board.model.rows.every((row) => row.state != ProgressRowState.active),
      'a stage-check row was left running',
    );
    _board.discard();
  }

  /// Ends the board after a refusal: the row that was running fails, naming
  /// the unit when it is a shared row, and rows the check never reached say
  /// so.
  void stop() {
    for (final row in [_targets, _dependencies]) {
      if (row == null || row.state != ProgressRowState.active) continue;
      row.fail(note: _at == null ? null : '${row.activity!.failed} · $_at');
    }
    _board.conclude();
  }
}
