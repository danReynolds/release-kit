import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Runs the native tools rk defers to.
///
/// One place, so what rk shells out to is enumerable rather than scattered
/// through adapters — and so the credential chokepoint the CI seam requires
/// has somewhere to live when it arrives. rk never passes a secret through
/// here: a native tool reads its own session from its own store.
abstract class Tools {
  /// Runs [executable], returning what it said.
  ///
  /// [timeout] bounds this one call, whatever the toolset's own bound is:
  /// some commands wait for a person, and a caller that has captured their
  /// output has taken away the prompt they are waiting on.
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  });

  /// Runs [executable] attached to the terminal, so a native prompt — a
  /// registry's MFA challenge, a keychain unlock — reaches the operator.
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  });
}

/// Tools that can also hand over a command's output line by line as it
/// arrives, for work long enough that a person wants to watch it move.
abstract interface class StreamingTools implements Tools {
  /// Runs [executable] as [run] does, calling [onLine] with each line either
  /// stream writes, as it arrives. The result still carries all of both.
  ///
  /// A tool that cannot watch a process as it runs hands over [ToolResult.lines]
  /// once it ends.
  Future<ToolResult> runStreaming(
    String executable,
    List<String> arguments, {
    required void Function(String line) onLine,
    String? workingDirectory,
    Map<String, String>? environment,
  });
}

class ToolResult {
  ToolResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;

  /// Each line of [stdout], then each line of [stderr].
  Iterable<String> get lines =>
      [stdout, stderr].expand(const LineSplitter().convert);

  /// The most useful line to show a human, preferring what failed.
  String get summary {
    final text = stderr.trim().isEmpty ? stdout.trim() : stderr.trim();
    final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return 'exit $exitCode';
    final failure = RegExp(
      r'\b(error|fatal|failed|could not|denied|not found|timed out|exception)\b',
      caseSensitive: false,
    );
    return lines
        .map((line) => line.trim())
        .firstWhere((line) => failure.hasMatch(line), orElse: () => lines.last);
  }

  /// The whole of what the tool said.
  ///
  /// [summary] picks the one line worth a person's screen; this is the rest —
  /// the thirty lines of compiler errors behind a remedy that says "see the
  /// compiler output". Kept for the diagnosis, where an operator goes when
  /// the one line was not enough.
  String get transcript => [
    'exit $exitCode',
    if (stdout.trim().isNotEmpty) ...['--- stdout ---', stdout.trimRight()],
    if (stderr.trim().isNotEmpty) ...['--- stderr ---', stderr.trimRight()],
  ].join('\n');
}

/// UTF-8 that survives a byte sequence it cannot make sense of.
///
/// A captured tool is not obliged to speak valid UTF-8 — a crashing binary
/// can put raw bytes on stderr, and a strict decoder turns that into a
/// FormatException thrown out of the middle of a release. rk would rather
/// read a replacement character than lose the run.
const _lenient = Utf8Codec(allowMalformed: true);

/// What a bounded run tells git rather than be asked a question it cannot
/// relay.
///
/// Only bounded runs. A bound is rk saying nobody will be waiting this long,
/// and git's credential prompt goes to /dev/tty, which closing stdin does not
/// touch — so an inspection meets the prompt, burns its whole bound, and is
/// killed, reporting "timed out" for a tool that only asked a question.
/// Unbounded runs are the acts, where the operator is at the terminal the
/// prompt reaches and there is no deadline to miss: suppressing it there
/// would turn an answerable push into a refusal.
///
/// One variable, deliberately. `SSH_ASKPASS_REQUIRE=never` sends ssh to the
/// terminal rather than away from it, and `GIT_SSH_COMMAND` or `GIT_ASKPASS`
/// would overwrite configuration the operator set for themselves. A caller
/// that means to override this is spread in after and wins.
const _unattended = {'GIT_TERMINAL_PROMPT': '0'};

/// Bytes read so far from one process pipe, with a cancellation handle.
///
/// `Stream.join` hides that handle. That is harmless for an ordinary child,
/// but not for a child that exits after giving its pipe to a grandchild: the
/// stream remains open and there is then no way to honor the caller's bound.
final class _CapturedOutput {
  _CapturedOutput(Stream<List<int>> stream) {
    _subscription = stream.listen(
      _bytes.add,
      onError: (Object error, StackTrace stackTrace) {
        if (!_done.isCompleted) _done.completeError(error, stackTrace);
      },
      onDone: () {
        if (!_done.isCompleted) _done.complete();
      },
    );
  }

  final BytesBuilder _bytes = BytesBuilder(copy: false);
  final Completer<void> _done = Completer<void>();
  late final StreamSubscription<List<int>> _subscription;

  Future<void> get done => _done.future;
  String get text => _lenient.decode(_bytes.toBytes());

  Future<void> cancel() => _subscription.cancel();
}

/// Cancellation belongs to a read-only inspection session, never release acts.
class ToolCancellation {
  final _done = Completer<void>();
  bool get cancelled => _done.isCompleted;
  Future<void> get whenCancelled => _done.future;
  void cancel() {
    if (!cancelled) _done.complete();
  }
}

class SystemTools implements StreamingTools {
  const SystemTools({this.timeout, this.cancellation});
  final ToolCancellation? cancellation;

  /// A bound for non-interactive subprocesses, used by public-target readers.
  /// Release acts deliberately use an unbounded instance: signing and
  /// notarization have their own progress and completion contracts.
  final Duration? timeout;

  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    if (cancellation?.cancelled == true) {
      return ToolResult(
        exitCode: 130,
        stdout: '',
        stderr: 'inspection cancelled',
      );
    }
    final bound =
        timeout ??
        this.timeout ??
        (cancellation == null ? null : const Duration(minutes: 2));
    if (bound == null) {
      final result = await Process.run(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        stdoutEncoding: _lenient,
        stderrEncoding: _lenient,
      );
      return ToolResult(
        exitCode: result.exitCode,
        stdout: result.stdout as String,
        stderr: result.stderr as String,
      );
    }

    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: {..._unattended, ...?environment},
    );
    // The same closed stdin an unbounded run gets from Process.run. Left
    // open, a tool that reads stdin blocks on a pipe nobody will ever write
    // to and burns the whole bound before rk kills it; closed, it sees EOF
    // and fails in milliseconds. This governs stdin only — a tool that
    // prompts on /dev/tty still holds rk's terminal, and the lever for those
    // is the environment (GIT_TERMINAL_PROMPT and its kind), not this.
    unawaited(process.stdin.close().catchError((Object _) {}));
    final stdout = _CapturedOutput(process.stdout);
    final stderr = _CapturedOutput(process.stderr);
    int? observedExitCode;
    final exitCode = process.exitCode.then((code) {
      observedExitCode = code;
      return code;
    });
    final completed = Future.wait<Object?>([
      exitCode,
      stdout.done,
      stderr.done,
    ]);
    final deadline = Completer<void>();
    final timer = Timer(bound, deadline.complete);
    late final bool timedOut;
    try {
      timedOut = await Future.any([
        completed.then((_) => false),
        deadline.future.then((_) => true),
        if (cancellation != null) cancellation!.whenCancelled.then((_) => true),
      ]);
    } on Object {
      await _cancel(stdout, stderr);
      rethrow;
    } finally {
      timer.cancel();
    }

    if (timedOut) {
      // Killing is necessary only while the direct child is alive. A child
      // that has already exited can still leave inherited pipe descriptors
      // behind; canceling the captures below is what bounds that case.
      if (observedExitCode == null) {
        process.kill(ProcessSignal.sigterm);
        try {
          await exitCode.timeout(const Duration(seconds: 1));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
          try {
            await exitCode.timeout(const Duration(seconds: 1));
          } on TimeoutException {
            // The caller's result remains bounded even if the operating
            // system does not report termination after SIGKILL.
          }
        }
      }
      await _cancel(stdout, stderr);
    }

    final capturedOut = stdout.text;
    final capturedErr = stderr.text;
    return ToolResult(
      exitCode: timedOut
          ? (cancellation?.cancelled == true ? 130 : 124)
          : observedExitCode!,
      stdout: capturedOut,
      stderr: timedOut
          ? [
              capturedErr.trimRight(),
              cancellation?.cancelled == true
                  ? 'inspection cancelled'
                  : 'timed out after ${_durationLabel(bound)}',
            ].where((line) => line.isNotEmpty).join('\n')
          : capturedErr,
    );
  }

  static Future<void> _cancel(
    _CapturedOutput stdout,
    _CapturedOutput stderr,
  ) async {
    try {
      await Future.wait([
        stdout.cancel(),
        stderr.cancel(),
      ]).timeout(const Duration(seconds: 1), onTimeout: () => <void>[]);
    } on Object {
      // Capture cancellation is best-effort housekeeping after the result is
      // already known. It must not turn a timeout into another unbounded wait
      // or hide the tool outcome.
    }
  }

  static String _durationLabel(Duration duration) {
    if (duration.inMilliseconds < 1000) {
      return '${duration.inMilliseconds} milliseconds';
    }
    return '${duration.inSeconds} seconds';
  }

  @override
  Future<ToolResult> runStreaming(
    String executable,
    List<String> arguments, {
    required void Function(String line) onLine,
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    // A bounded run keeps [run]'s bound, and hands over its lines at the end.
    if (timeout != null || cancellation != null) {
      final result = await run(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
      );
      result.lines.forEach(onLine);
      return result;
    }
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    // The same closed stdin as [run], so a command that reads it sees EOF.
    unawaited(process.stdin.close().catchError((Object _) {}));
    // A listener that fails must not stop the reading: the process would go
    // on writing into a closed pipe. What it threw is thrown once it ends.
    Object? failure;
    StackTrace? failureTrace;
    void deliver(String line) {
      if (failure != null) return;
      try {
        onLine(line);
      } on Object catch (error, stackTrace) {
        failure = error;
        failureTrace = stackTrace;
      }
    }

    Future<String> read(Stream<List<int>> stream) async {
      final text = StringBuffer();
      await stream
          .transform(_lenient.decoder)
          .map((chunk) {
            text.write(chunk);
            return chunk;
          })
          .transform(const LineSplitter())
          .forEach(deliver);
      return text.toString();
    }

    final [stdout, stderr, exitCode] = await Future.wait<Object>([
      read(process.stdout),
      read(process.stderr),
      process.exitCode,
    ]);
    if (failure case final failed?) {
      Error.throwWithStackTrace(failed, failureTrace!);
    }
    return ToolResult(
      exitCode: exitCode as int,
      stdout: stdout as String,
      stderr: stderr as String,
    );
  }

  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }
}

/// Records what would have been run, for tests and for a dry run.
class RecordingTools implements StreamingTools {
  RecordingTools({
    this.results = const {},
    this.onRun,
    this.answers,
    this.probe,
  });

  /// Keyed by `executable arg1 arg2`, so a test can decide an outcome.
  final Map<String, ToolResult> results;

  /// Called for every invocation, so a test can change the world the way the
  /// real command would — a publish makes a version live *at the registry*,
  /// not inside whoever asked.
  final void Function(String key)? onRun;

  /// Consulted after [results], for outcomes that depend on the world as it
  /// stands at call time — a remote that lists the tag only once it has been
  /// pushed. An explicit script wins over the model, so a test can force the
  /// one anomalous answer while the model carries the rest. Null falls
  /// through to the default.
  final ToolResult? Function(String key)? answers;

  /// Sees the working directory too, so a test can prove *where* a command
  /// ran and read what rk wrote there — three mutations of the consumer
  /// probe survived because nothing could.
  final void Function(String key, String? workingDirectory)? probe;

  final List<String> calls = [];

  /// The environment each command last ran with, by key, so a test can see
  /// what rk asked of a tool as well as what it ran.
  final Map<String, Map<String, String>?> environments = {};

  ToolResult _result(String key) =>
      results[key] ??
      answers?.call(key) ??
      ToolResult(exitCode: 0, stdout: '', stderr: '');

  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    final key = '$executable ${arguments.join(' ')}';
    calls.add(key);
    environments[key] = environment;
    probe?.call(key, workingDirectory);
    onRun?.call(key);
    return _result(key);
  }

  /// Answers as [run] does, then hands over the answer's lines in order.
  @override
  Future<ToolResult> runStreaming(
    String executable,
    List<String> arguments, {
    required void Function(String line) onLine,
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final result = await run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    result.lines.forEach(onLine);
    return result;
  }

  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    final key = '$executable ${arguments.join(' ')}';
    calls.add(key);
    probe?.call(key, workingDirectory);
    onRun?.call(key);
    return _result(key).exitCode;
  }
}
