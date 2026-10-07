import '../engine/repository_stage_preparation.dart';
import '../engine/resolve.dart';
import '../output/output.dart';
import '../output/progress.dart';
import 'release_progress.dart';

/// The board for the repository-wide stage check that runs before any unit is
/// prepared: each unit's saved stage found and every staged file verified,
/// the units' public targets read, and, for a unit with no stage, its
/// dependencies resolved.
///
/// Without it this was the longest silence in a release: tens of seconds
/// after the last "Releasing" heading with nothing on screen, which reads
/// as a hang.
///
/// A row is active only while its own work runs. The check does one unit at
/// a time, so its time is that work's time, and a stop fails the row that
/// was running and no other.
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
  final Map<String, ProgressRowController> _dependencies = {};
  ProgressRowController? _targets;

  /// [unit]'s saved-stage row. The selected units' rows exist from the start;
  /// a sibling's appears when its stage is looked for.
  ProgressRowController _stage(ResolvedUnit unit) =>
      _stages[unit.name] ??= _board.addRow(
        id: 'stage-check/${unit.name}',
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
    // Its own row: the unit's stage row settled long before, and other
    // units' work ran in between.
    final row = _dependencies[unit.name] = _board.addRow(
      id: 'stage-check/${unit.name}/dependencies',
      label: '${unit.name} ${unit.version}',
      coordinate: 'dependencies',
    );
    row.handle.begin(_resolving);
  }

  @override
  void discovered(ResolvedUnit unit) =>
      _dependencies[unit.name]!.complete(note: 'resolved');

  /// Runs [body], the release command's read of [unit]'s public targets. One
  /// row covers every unit's read, naming the unit being read.
  Future<T> checkingPublicTargets<T>(
    ResolvedUnit unit,
    Future<T> Function() body,
  ) {
    (_targets ??= _board.addRow(
      id: 'stage-check/public-targets',
      label: 'public targets',
    )).handle.begin(
      CommonProgressActivities.checking,
      detail: '${unit.name} ${unit.version}',
    );
    return body();
  }

  /// Every unit's public targets have been read.
  void publicTargetsChecked() =>
      _targets?.complete(note: 'checked', mark: ProgressRowMark.none);

  /// Takes the board down once the check has finished. Every row has already
  /// settled on what its own work found.
  void finish() {
    assert(
      _board.model.rows.every((row) => row.state != ProgressRowState.active),
      'a stage-check row was left running',
    );
    _board.discard();
  }

  /// Ends the board after a refusal: the row that was running fails, and
  /// rows the check never reached say so.
  void stop() => _board.conclude();
}
