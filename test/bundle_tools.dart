import 'dart:io';

import 'package:rk/src/engine/tools.dart';

/// Models compiler/copy/launcher outputs for release orchestration tests.
/// No platform executable runs. Real launcher behavior has a separate test.
class BundleRecordingTools extends RecordingTools {
  BundleRecordingTools(
      {super.results, super.answers, super.onRun, super.probe});
  final _identifiers = <String, String>{};

  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    final result = await super.run(executable, arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        timeout: timeout);
    if (!result.ok) return result;
    if (arguments.firstOrNull == 'compile') {
      final output = arguments[arguments.indexOf('-o') + 1];
      File(output)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('BINARY 1.0.0');
    } else if (executable == '/bin/cp') {
      File(arguments.first).copySync(arguments.last);
    } else if (executable.endsWith('/clang')) {
      File(arguments.last).writeAsStringSync('LAUNCHER');
    } else if (executable == '/bin/chmod') {
      Process.runSync(executable, arguments);
    } else if (executable == 'codesign' && arguments.contains('--identifier')) {
      _identifiers[arguments.last] =
          arguments[arguments.indexOf('--identifier') + 1];
    } else if (executable == 'codesign' && arguments.contains('-r-')) {
      final id = _identifiers[arguments.last];
      if (id != null) {
        String identify(String value) {
          if (value.contains('identifier')) {
            return value.replaceFirst(
                RegExp(r'identifier\s+(?:"[^"]+"|\S+)'), 'identifier "$id"');
          }
          return value.replaceFirst(
              'designated => ', 'designated => identifier "$id" and ');
        }

        return ToolResult(
            exitCode: result.exitCode,
            stdout: identify(result.stdout),
            stderr: identify(result.stderr));
      }
    }
    return result;
  }
}
