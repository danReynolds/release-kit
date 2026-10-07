import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The maintainer's trace of where a run's time goes: `RK_TIMINGS=1`.
///
/// It shows rk's internals (subprocesses, hashing, parsing), which the
/// public `--timings` breakdown deliberately does not: that one speaks in the
/// phases, units and rows a person sees. This one is for deciding what to
/// optimize, and is undocumented on purpose.
///
/// Spans nest through zones, so work started under a span is charged to it
/// even across awaits and concurrent futures. Tallies collect work too small
/// or too frequent to be its own span (one digest per file) and are charged
/// to the span they ran in. `RK_TIMINGS_CALLERS=1` adds each tally's first
/// caller frame; it walks a stack per tally, so it is for diagnosis only.
///
/// Recording off, every call runs its body directly. Hot paths check
/// [Timings.enabled] first, so they do not even build a tally's name.
final class Timings {
  Timings._();

  static _Recording? _recording = Platform.environment['RK_TIMINGS'] == '1'
      ? _Recording(
          _stopwatchClock(),
          callers: Platform.environment['RK_TIMINGS_CALLERS'] == '1',
        )
      : null;

  static const Symbol _key = #rkTimingSpan;

  /// Whether this run is being traced.
  static bool get enabled => _recording != null;

  /// Starts a fresh recording read from [clock], replacing any other; for
  /// tests, which cannot set the environment of the process they run in.
  static void startRecording({
    required Duration Function() clock,
    bool callers = false,
  }) {
    _recording = _Recording(clock, callers: callers);
  }

  /// Stops recording. Calls then run their bodies directly again.
  static void stopRecording() => _recording = null;

  /// Runs [body] as a span named [name].
  static Future<T> span<T>(String name, Future<T> Function() body) {
    final recording = _recording;
    if (recording == null) return body();
    final span = _Span(name, recording.current, recording.now());
    // Future.sync: a body that throws before returning a future still ends
    // its span.
    return runZoned(
      () => Future.sync(body).whenComplete(() => span.end = recording.now()),
      zoneValues: {_key: span},
    );
  }

  /// Runs synchronous [body] as a span named [name].
  static T spanSync<T>(String name, T Function() body) {
    final recording = _recording;
    if (recording == null) return body();
    final span = _Span(name, recording.current, recording.now());
    try {
      return runZoned(body, zoneValues: {_key: span});
    } finally {
      span.end = recording.now();
    }
  }

  /// Charges one occurrence of [name], with [bytes] and [elapsed], to the
  /// current span.
  static void tally(String name, {int bytes = 0, Duration? elapsed}) {
    final recording = _recording;
    if (recording == null) return;
    recording.charge(recording.keyFor(name), bytes: bytes, elapsed: elapsed);
  }

  /// Times synchronous [body] as a tally named [name].
  static T timeTally<T>(String name, T Function() body, {int bytes = 0}) {
    final recording = _recording;
    if (recording == null) return body();
    final key = recording.keyFor(name);
    final started = recording.now();
    try {
      return body();
    } finally {
      recording.charge(key, bytes: bytes, elapsed: recording.now() - started);
    }
  }

  /// Times asynchronous [body] as a tally named [name].
  static Future<T> timeTallyAsync<T>(String name, Future<T> Function() body) {
    final recording = _recording;
    if (recording == null) return body();
    // The caller is read now: once the future completes, the stack holds
    // only the event loop.
    final key = recording.keyFor(name);
    final started = recording.now();
    return Future.sync(body).whenComplete(
      () => recording.charge(key, elapsed: recording.now() - started),
    );
  }

  /// The span tree so far, or null when nothing is being recorded.
  static String? reportText() {
    final recording = _recording;
    if (recording == null) return null;
    recording.root.end = recording.now();
    final out = StringBuffer(
      'rk timings (wall clock; nested spans overlap their parent)\n',
    );
    recording.root.write(out, depth: 0);
    return out.toString();
  }

  /// Writes the span tree to [sink], when this run is being traced.
  static void report(IOSink sink) {
    final text = reportText();
    if (text != null) sink.write('\n$text');
  }

  /// The first frame outside timing and process plumbing, and outside the
  /// wrappers that tally on their callers' behalf.
  static String _caller() {
    const plumbing = [
      'timings.dart',
      'source_tree.dart',
      'tools.dart',
      'digest.dart',
    ];
    const wrappers = [
      'CanonicalJson.encode',
      'StageDirectory.fingerprint',
      'StageReceipt.parse',
      'StageReceipt._parse',
    ];
    for (final line in StackTrace.current.toString().split('\n')) {
      final frame = RegExp(r'#\d+\s+(.*?) \((.*?)\)').firstMatch(line);
      if (frame == null) continue;
      final where = frame.group(2)!;
      if (where.startsWith('dart:') || plumbing.any(where.contains)) continue;
      if (wrappers.any(frame.group(1)!.contains)) continue;
      return '${frame.group(1)} (${where.split('/').last})';
    }
    return '?';
  }

  static Duration Function() _stopwatchClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }
}

final class _Recording {
  _Recording(this.now, {required this.callers})
    : root = _Span('rk', null, now());

  final Duration Function() now;
  final bool callers;
  final _Span root;

  _Span get current => (Zone.current[Timings._key] as _Span?) ?? root;

  /// [name], with its caller when callers are being recorded.
  String keyFor(String name) =>
      callers ? '$name  ← ${Timings._caller()}' : name;

  /// Charges one occurrence of [key] to the current span.
  void charge(String key, {int bytes = 0, Duration? elapsed}) {
    current.tallies.putIfAbsent(key, _Tally.new)
      ..count += 1
      ..bytes += bytes
      ..elapsed += elapsed ?? Duration.zero;
  }
}

final class _Tally {
  int count = 0;
  int bytes = 0;
  Duration elapsed = Duration.zero;
}

final class _Span {
  _Span(this.name, this.parent, this.start) {
    parent?.children.add(this);
  }

  final String name;
  final _Span? parent;
  final Duration start;
  Duration? end;
  final children = <_Span>[];
  final tallies = <String, _Tally>{};

  void write(StringSink sink, {required int depth}) {
    final finish = end;
    final took = finish == null ? 'unfinished' : _seconds(finish - start);
    sink.writeln(
      '${'  ' * depth}${_seconds(start).padLeft(8)} +${took.padRight(9)} $name',
    );
    for (final MapEntry(:key, :value) in tallies.entries) {
      final size = value.bytes == 0
          ? ''
          : ', ${(value.bytes / 1e6).toStringAsFixed(1)} MB';
      sink.writeln(
        '${'  ' * (depth + 1)}         = ${_seconds(value.elapsed).padRight(9)} '
        '$key × ${value.count}$size',
      );
    }
    for (final child in children) {
      child.write(sink, depth: depth + 1);
    }
  }

  static String _seconds(Duration duration) =>
      '${(duration.inMicroseconds / 1e6).toStringAsFixed(3)}s';
}

/// A subprocess's tally name: its executable's name and the leading
/// arguments that say what it does, up to the first that looks like data —
/// a path, a ref, a `commit:path`, a `key=value` — which differs from one call
/// to the next. A command run a hundred times is one line counted a hundred
/// times: every `git show <commit>:<path>` is `git show`.
String processTally(String executable, List<String> arguments) {
  final words = [executable.split('/').last];
  for (final argument in arguments.take(4)) {
    if (argument.contains(_data)) break;
    words.add(argument);
  }
  return words.join(' ');
}

final _data = RegExp('[/:=@]');

/// [Process.runSync], tallied by [processTally].
ProcessResult timedRunSync(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Encoding? stdoutEncoding = systemEncoding,
  Encoding? stderrEncoding = systemEncoding,
}) {
  ProcessResult run() => Process.runSync(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    stdoutEncoding: stdoutEncoding,
    stderrEncoding: stderrEncoding,
  );
  return Timings.enabled
      ? Timings.timeTally(processTally(executable, arguments), run)
      : run();
}
