import 'dart:async';

import 'output.dart' show oneLine;

/// Long enough that a preparation board helps instead of flashing briefly.
const briefPhase = Duration(milliseconds: 800);

/// Target-owned wording for one meaningful release operation.
///
/// RK owns the lifecycle and renderer; a target owns only the words that
/// describe work it can actually observe. The failure label is kept beside
/// the running label so a target cannot start an operation without saying how
/// a definite failure of that operation reads.
final class ProgressActivity {
  ProgressActivity({required this.running, required this.failed});

  final String running;
  final String failed;

  @override
  bool operator ==(Object other) =>
      other is ProgressActivity &&
      other.running == running &&
      other.failed == failed;

  @override
  int get hashCode => Object.hash(running, failed);
}

/// Conventional wording available to targets without closing the vocabulary.
///
/// These are conveniences, not a universal pipeline. A target defines a
/// bespoke [ProgressActivity] beside its implementation when these words do
/// not describe what it really does.
abstract final class CommonProgressActivities {
  static final checking = ProgressActivity(
    running: 'checking',
    failed: 'check failed',
  );
  static final checkingSignIn = ProgressActivity(
    running: 'checking sign-in',
    failed: 'sign-in check failed',
  );
  static final validating = ProgressActivity(
    running: 'validating',
    failed: 'validation failed',
  );
  static final verifying = ProgressActivity(
    running: 'verifying',
    failed: 'verification failed',
  );
}

enum ProgressRowState { pending, active, complete, failed, notAttempted }

/// The visual mark for a settled progress row.
///
/// State and mark are separate because a completed observation can mean
/// either "RK completed this" or "the publication was already present".
enum ProgressRowMark { done, satisfied, none }

enum ProgressRowEmphasis { plain, muted, attention }

typedef ProgressElapsed = Duration Function();

/// The narrow handle release code and target modules receive.
///
/// It can describe active work, but it cannot declare public success, failure,
/// or downstream state. Those decisions remain with the coordinator through
/// [ProgressRowController].
final class ProgressHandle {
  ProgressHandle._(ProgressRow row) : _rows = [row];

  ProgressHandle.combine(Iterable<ProgressHandle> handles)
    : _rows = List.unmodifiable([
        for (final handle in handles) ...handle._rows,
      ]);

  final List<ProgressRow> _rows;

  ProgressActivity? get activity => _rows.firstOrNull?.activity;

  /// Whether this handle's rows are still at work, and so may be redrawn.
  bool get active =>
      _rows.isNotEmpty &&
      _rows.every((row) => row.state == ProgressRowState.active);

  /// This handle's first row alone, for detail the other rows would only
  /// repeat, such as the latest line of a build that makes them all.
  ProgressHandle get first =>
      _rows.length <= 1 ? this : ProgressHandle._(_rows.first);

  void begin(ProgressActivity activity, {String? detail}) {
    for (final row in _rows) {
      row._begin(activity, detail: detail);
    }
  }
}

/// Coordinator authority for one row.
final class ProgressRowController {
  ProgressRowController._(this._row) : handle = ProgressHandle._(_row);

  final ProgressRow _row;
  final ProgressHandle handle;

  String get id => _row.id;
  ProgressRowState get state => _row.state;
  ProgressActivity? get activity => _row.activity;

  /// Describes why a pending row cannot start yet.
  void wait({required String note}) {
    _row._wait(note);
  }

  void complete({
    required String note,
    ProgressRowMark mark = ProgressRowMark.done,
    ProgressRowEmphasis emphasis = ProgressRowEmphasis.muted,
  }) {
    _row._complete(note, mark: mark, emphasis: emphasis);
  }

  /// Restores a completed row from already-validated durable evidence.
  ///
  /// Normal execution must become active first; receipt restoration is the
  /// one honest path from pending directly to complete.
  void restoreComplete({
    required String note,
    ProgressRowMark mark = ProgressRowMark.done,
    ProgressRowEmphasis emphasis = ProgressRowEmphasis.muted,
  }) {
    _row._restoreComplete(note, mark: mark, emphasis: emphasis);
  }

  void fail({ProgressActivity? activity, String? note}) {
    _row._fail(activity: activity, note: note);
  }

  void notAttempted({String note = 'not attempted'}) {
    _row._notAttempted(note);
  }
}

/// One row in a fixed-height progress surface.
final class ProgressRow {
  ProgressRow._(
    this._model, {
    required this.id,
    required String label,
    required String? coordinate,
    required this.group,
  }) : label = oneLine(label),
       coordinate = coordinate == null ? null : oneLine(coordinate, max: 160);

  final ProgressModel _model;
  final String id;
  final String label;
  final String? coordinate;
  final String? group;

  ProgressRowState _state = ProgressRowState.pending;
  ProgressRowMark _mark = ProgressRowMark.none;
  ProgressRowEmphasis _emphasis = ProgressRowEmphasis.plain;
  ProgressActivity? _activity;
  String? _detail;
  String? _note;
  ProgressElapsed? _elapsed;

  /// The stopwatch of the row's first operation; `_elapsed` restarts with
  /// each new activity, this one does not.
  ProgressElapsed? _activeSince;
  Duration? _took;

  /// A pipe's heartbeat: restarted when the row's activity changes, it says
  /// the activity once if the row is still at it when the timer fires.
  Timer? _heartbeat;
  ProgressActivity? _announced;

  ProgressRowState get state => _state;
  ProgressRowMark get mark => _mark;
  ProgressRowEmphasis get emphasis => _emphasis;
  ProgressActivity? get activity => _activity;
  String? get detail => _detail;
  String? get note => _note;
  Duration get elapsed => _elapsed?.call() ?? Duration.zero;

  /// How long the row was active in all, from its first operation to its
  /// settlement. Null for a row that has not settled, or never ran (one
  /// restored from a receipt, or never begun).
  Duration? get took => _took;

  /// How long the row has been active: [took] once it settles, the time so
  /// far while it runs, and null if it never ran.
  Duration? get ranFor => _took ?? _activeSince?.call();

  /// What the row is about: its label, and its coordinate when it has one.
  String get subject => coordinate == null ? label : '$label · $coordinate';

  /// Whether a pipe has been told this row is under way.
  bool get announced => _announced != null;

  void _changed() => _model._changed(this);

  void _wait(String result) {
    if (_state != ProgressRowState.pending) {
      throw StateError('only pending progress row $id can wait');
    }
    _note = oneLine(result);
    _changed();
  }

  void _begin(ProgressActivity next, {String? detail}) {
    if (_state == ProgressRowState.complete ||
        _state == ProgressRowState.failed ||
        _state == ProgressRowState.notAttempted) {
      throw StateError('settled progress row $id cannot become active');
    }
    final safeDetail = detail == null ? null : oneLine(detail);
    if (_activity != next) {
      _elapsed = _model._clock();
      if (_model._announce case final announce?) {
        _heartbeat?.cancel();
        _heartbeat = Timer(_model._heartbeatAfter, () {
          if (_state != ProgressRowState.active ||
              _activity != next ||
              _announced == next) {
            return;
          }
          _announced = next;
          announce(this);
        });
      }
    }
    _activeSince ??= _elapsed;
    _activity = next;
    _detail = safeDetail;
    _note = null;
    _state = ProgressRowState.active;
    _changed();
  }

  void _complete(
    String result, {
    required ProgressRowMark mark,
    required ProgressRowEmphasis emphasis,
  }) {
    if (_state != ProgressRowState.active) {
      throw StateError('only active progress row $id can complete');
    }
    _settleComplete(result, mark: mark, emphasis: emphasis);
  }

  void _restoreComplete(
    String result, {
    required ProgressRowMark mark,
    required ProgressRowEmphasis emphasis,
  }) {
    if (_state != ProgressRowState.pending) {
      throw StateError('only pending progress row $id can be restored');
    }
    _settleComplete(result, mark: mark, emphasis: emphasis);
  }

  void _settleComplete(
    String result, {
    required ProgressRowMark mark,
    required ProgressRowEmphasis emphasis,
  }) {
    _note = oneLine(result);
    _detail = null;
    _took = _activeSince?.call();
    _mark = mark;
    _emphasis = emphasis;
    _state = ProgressRowState.complete;
    _heartbeat?.cancel();
    _changed();
  }

  void _fail({ProgressActivity? activity, String? note}) {
    if (_state != ProgressRowState.active) {
      throw StateError('only active progress row $id can fail');
    }
    final failedActivity = activity ?? _activity;
    final result = note ?? failedActivity?.failed ?? 'failed';
    _activity = failedActivity;
    _note = oneLine(result);
    _detail = null;
    _took = _activeSince?.call();
    _mark = ProgressRowMark.none;
    _emphasis = ProgressRowEmphasis.plain;
    _state = ProgressRowState.failed;
    _heartbeat?.cancel();
    _changed();
  }

  void _notAttempted(String result) {
    // Pending is the usual case. Active is the drained lane: its in-flight
    // step finished after a stop elsewhere, and the owner records that the
    // row's artifact was never attempted — the receipt keeps what did run.
    if (_state != ProgressRowState.pending &&
        _state != ProgressRowState.active) {
      throw StateError(
        'only pending or active progress row $id can be '
        'not attempted',
      );
    }
    _note = oneLine(result);
    // A drained lane's row did run, until the stop; its time stands.
    _took = _activeSince?.call();
    _state = ProgressRowState.notAttempted;
    _heartbeat?.cancel();
    _changed();
  }
}

/// Mutable row inventory with immutable target ownership once a row exists.
///
/// Rendering lives in [Output]; this model is deliberately terminal-agnostic
/// so target contract tests can assert lifecycle behavior without ANSI text.
final class ProgressModel {
  /// With [announce], a pipe hears of a row still at one activity after
  /// [heartbeatAfter], once, through it.
  ProgressModel({
    required String title,
    required ProgressElapsed Function() clock,
    required void Function(ProgressRow row) changed,
    void Function(ProgressRow row)? announce,
    Duration heartbeatAfter = const Duration(seconds: 10),
  }) : title = oneLine(title),
       _clock = clock,
       _changed = changed,
       _announce = announce,
       _heartbeatAfter = heartbeatAfter;

  final String title;
  final ProgressElapsed Function() _clock;
  final void Function(ProgressRow row) _changed;
  void Function(ProgressRow row)? _announce;
  final Duration _heartbeatAfter;
  final List<ProgressRow> _rows = [];
  final List<String> _groups = [];

  List<ProgressRow> get rows => List.unmodifiable(_rows);
  List<String> get groups => List.unmodifiable(_groups);

  ProgressRowController addRow({
    required String id,
    required String label,
    String? coordinate,
    String? group,
  }) {
    if (_rows.any((row) => row.id == id)) {
      throw StateError('duplicate progress row $id');
    }
    final safeGroup = group == null ? null : oneLine(group);
    if (safeGroup != null && !_groups.contains(safeGroup)) {
      _groups.add(safeGroup);
    }
    final row = ProgressRow._(
      this,
      id: id,
      label: label,
      coordinate: coordinate,
      group: safeGroup,
    );
    _rows.add(row);
    _changed(row);
    return ProgressRowController._(row);
  }

  /// Stops every row's heartbeat, for good: its board has ended.
  void stopHeartbeats() {
    _announce = null;
    for (final row in _rows) {
      row._heartbeat?.cancel();
    }
  }
}
