import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

/// What a stream has produced, given a moment to finish after a kill.
Future<String> _settled(Future<String> stream) => stream.timeout(
      const Duration(seconds: 2),
      onTimeout: () => '',
    );

class SystemTools implements Tools {
  const SystemTools({this.timeout});

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
    final bound = timeout ?? this.timeout;
    if (bound == null) {
      final result = await Process.run(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
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
      environment: environment,
    );
    // The same closed stdin an unbounded run gets from Process.run. Left
    // open, a tool that reads stdin blocks on a pipe nobody will ever write
    // to and burns the whole bound before rk kills it; closed, it sees EOF
    // and fails in milliseconds. This governs stdin only — a tool that
    // prompts on /dev/tty still holds rk's terminal, and the lever for those
    // is the environment (GIT_TERMINAL_PROMPT and its kind), not this.
    unawaited(process.stdin.close().catchError((Object _) {}));
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    var timedOut = false;
    var exitCode = 124;
    try {
      exitCode = await process.exitCode.timeout(bound);
    } on TimeoutException {
      timedOut = true;
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
    }
    // A kill reaches the child, not whatever it started. An orphaned
    // grandchild holds the write end of these pipes open, and joining them
    // unconditionally waits for a process rk never knew about — so a bound
    // that has already fired would go on to wait forever, which is the one
    // thing a bound exists to rule out. What was read by then is what the
    // tool said.
    final capturedOut = timedOut ? await _settled(stdout) : await stdout;
    final capturedErr = timedOut ? await _settled(stderr) : await stderr;
    return ToolResult(
      exitCode: exitCode,
      stdout: capturedOut,
      stderr: timedOut
          ? [
              capturedErr.trimRight(),
              'timed out after ${bound.inSeconds} seconds',
            ].where((line) => line.isNotEmpty).join('\n')
          : capturedErr,
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
class RecordingTools implements Tools {
  RecordingTools(
      {this.results = const {}, this.onRun, this.answers, this.probe});

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
    probe?.call(key, workingDirectory);
    onRun?.call(key);
    return _result(key);
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
