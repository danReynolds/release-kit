import 'package:release_kit/src/engine/tools.dart';

/// Tools that answer from a script keyed by executable, recording every call.
class ScriptedTools implements Tools {
  ScriptedTools(this.answers);

  final Map<String, ToolResult> answers;

  /// Every command run, in order.
  final List<List<String>> calls = [];

  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    calls.add([executable, ...arguments]);
    return answers[executable] ??
        ToolResult(exitCode: 127, stdout: '', stderr: '$executable not found');
  }

  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async =>
      0;
}

/// Tools that answer in order, for the paths where rk asks twice.
class SequencedTools implements Tools {
  SequencedTools(this._answers);

  final List<ToolResult> _answers;
  var _at = 0;

  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async =>
      _at < _answers.length
          ? _answers[_at++]
          : ToolResult(exitCode: 127, stdout: '', stderr: 'unscripted');

  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async =>
      0;
}

ToolResult ok([String stdout = '']) =>
    ToolResult(exitCode: 0, stdout: stdout, stderr: '');

ToolResult failed(String stderr) =>
    ToolResult(exitCode: 1, stdout: '', stderr: stderr);
