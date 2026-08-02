import 'dart:io';

/// Runs the native tools rk defers to.
///
/// One place, so what rk shells out to is enumerable rather than scattered
/// through adapters — and so the credential chokepoint the CI seam requires
/// has somewhere to live when it arrives. rk never passes a secret through
/// here: a native tool reads its own session from its own store.
abstract class Tools {
  /// Runs [executable], returning what it said.
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
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
    return lines.isEmpty ? 'exit $exitCode' : lines.last.trim();
  }
}

class SystemTools implements Tools {
  const SystemTools();

  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
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
