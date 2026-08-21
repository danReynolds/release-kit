/// Target-owned wording for one meaningful release operation.
///
/// RK owns the lifecycle and renderer; a target owns only the words that
/// describe work it can actually observe. The failure label is kept beside
/// the running label so a target cannot start an operation without saying how
/// a definite failure of that operation reads.
final class ProgressActivity {
  ProgressActivity({required String running, required String failed})
      : running = _label('running activity', running),
        failed = _label('failed activity', failed);

  final String running;
  final String failed;

  @override
  bool operator ==(Object other) =>
      other is ProgressActivity &&
      other.running == running &&
      other.failed == failed;

  @override
  int get hashCode => Object.hash(running, failed);

  static String _label(String field, String value) {
    final text = value.trim();
    if (text.isEmpty) throw ArgumentError('$field cannot be empty');
    if (text != text.toLowerCase()) {
      throw ArgumentError('$field must be lowercase: $text');
    }
    if (text.runes.length > 40) {
      throw ArgumentError('$field is longer than 40 characters');
    }
    if (_unsafe.hasMatch(text)) {
      throw ArgumentError('$field must be one printable line');
    }
    return text;
  }
}

final RegExp _unsafe = RegExp(
  r'[\x00-\x1f\x7f\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]',
);

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
  ProgressRow._({
    required this.id,
    required String label,
    required String? coordinate,
    required this.group,
    required ProgressElapsed Function() clock,
    required void Function(ProgressRow row) changed,
  })  : label = _text('progress label', label, max: 120),
        coordinate = coordinate == null
            ? null
            : _text('progress coordinate', coordinate, max: 160),
        _clock = clock,
        _changed = changed;

  final String id;
  final String label;
  final String? coordinate;
  final String? group;
  final ProgressElapsed Function() _clock;
  final void Function(ProgressRow row) _changed;

  ProgressRowState _state = ProgressRowState.pending;
  ProgressRowMark _mark = ProgressRowMark.none;
  ProgressRowEmphasis _emphasis = ProgressRowEmphasis.plain;
  ProgressActivity? _activity;
  String? _detail;
  String? _note;
  ProgressElapsed? _elapsed;

  ProgressRowState get state => _state;
  ProgressRowMark get mark => _mark;
  ProgressRowEmphasis get emphasis => _emphasis;
  ProgressActivity? get activity => _activity;
  String? get detail => _detail;
  String? get note => _note;
  Duration get elapsed => _elapsed?.call() ?? Duration.zero;

  void _wait(String result) {
    if (_state != ProgressRowState.pending) {
      throw StateError('only pending progress row $id can wait');
    }
    _note = _text('progress wait', result, max: 120);
    _changed(this);
  }

  void _begin(ProgressActivity next, {String? detail}) {
    if (_state == ProgressRowState.complete ||
        _state == ProgressRowState.failed ||
        _state == ProgressRowState.notAttempted) {
      throw StateError('settled progress row $id cannot become active');
    }
    final safeDetail =
        detail == null ? null : _text('progress detail', detail, max: 120);
    if (_activity != next) _elapsed = _clock();
    _activity = next;
    _detail = safeDetail;
    _note = null;
    _state = ProgressRowState.active;
    _changed(this);
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
    _note = _text('progress completion', result, max: 120);
    _detail = null;
    _mark = mark;
    _emphasis = emphasis;
    _state = ProgressRowState.complete;
    _changed(this);
  }

  void _fail({ProgressActivity? activity, String? note}) {
    if (_state != ProgressRowState.active) {
      throw StateError('only active progress row $id can fail');
    }
    final failedActivity = activity ?? _activity;
    final result = note ?? failedActivity?.failed ?? 'failed';
    _activity = failedActivity;
    _note = _text('progress failure', result, max: 120);
    _detail = null;
    _mark = ProgressRowMark.none;
    _emphasis = ProgressRowEmphasis.plain;
    _state = ProgressRowState.failed;
    _changed(this);
  }

  void _notAttempted(String result) {
    // Pending is the usual case. Active is the drained lane: its in-flight
    // step finished after a stop elsewhere, and the owner records that the
    // row's artifact was never attempted — the receipt keeps what did run.
    if (_state != ProgressRowState.pending &&
        _state != ProgressRowState.active) {
      throw StateError('only pending or active progress row $id can be '
          'not attempted');
    }
    _note = _text('progress skipped result', result, max: 120);
    _state = ProgressRowState.notAttempted;
    _changed(this);
  }

  static String _text(String field, String value, {required int max}) {
    final text = value.trim();
    if (text.isEmpty) throw ArgumentError('$field cannot be empty');
    if (_unsafe.hasMatch(text)) {
      throw ArgumentError('$field must be one printable line');
    }
    if (text.runes.length > max) {
      throw ArgumentError('$field is longer than $max characters');
    }
    return text;
  }
}

/// Mutable row inventory with immutable target ownership once a row exists.
///
/// Rendering lives in [Output]; this model is deliberately terminal-agnostic
/// so target contract tests can assert lifecycle behavior without ANSI text.
final class ProgressModel {
  ProgressModel({
    required String title,
    required ProgressElapsed Function() clock,
    required void Function(ProgressRow row) changed,
  })  : title = ProgressRow._text('progress title', title, max: 120),
        _clock = clock,
        _changed = changed;

  final String title;
  final ProgressElapsed Function() _clock;
  final void Function(ProgressRow row) _changed;
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
    final safeGroup = group == null
        ? null
        : ProgressRow._text('progress group', group, max: 120);
    if (safeGroup != null && !_groups.contains(safeGroup)) {
      _groups.add(safeGroup);
    }
    final row = ProgressRow._(
      id: id,
      label: label,
      coordinate: coordinate,
      group: safeGroup,
      clock: _clock,
      changed: _changed,
    );
    _rows.add(row);
    _changed(row);
    return ProgressRowController._(row);
  }
}
