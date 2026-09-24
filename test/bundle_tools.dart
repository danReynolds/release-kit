import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/transforms/digest.dart';

/// Models compiler/copy/launcher outputs for release orchestration tests, and
/// what codesign reports about the files it signed: identifiers, code hashes
/// and embedded library load constraints. No platform executable runs. Real
/// launcher and pinning behavior have separate tests.
class BundleRecordingTools extends RecordingTools {
  BundleRecordingTools(
      {super.results, super.answers, super.onRun, super.probe});
  final _identifiers = <String, String>{};
  final _constraints = <String, List<String>>{};

  /// The code hash codesign reports for the bytes now at [path].
  static String codeHash(String path) => Sha256.hex(utf8.encode(
          '$path:${File(path).existsSync() ? File(path).readAsStringSync() : ''}'))
      .substring(0, 40);

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
      // A signature carries the constraint it was given; re-signing without
      // one removes it.
      final at = arguments.indexOf('--library-constraint');
      if (at < 0) {
        _constraints.remove(arguments.last);
      } else {
        _constraints[arguments.last] = [
          for (final match in RegExp(r'<data>([^<]+)</data>')
              .allMatches(File(arguments[at + 1]).readAsStringSync()))
            [
              for (final byte in base64.decode(match.group(1)!.trim()))
                byte.toRadixString(16).padLeft(2, '0')
            ].join(),
        ];
      }
    } else if (executable == 'codesign' &&
        arguments.first == '-dvvv' &&
        result.stdout.isEmpty &&
        result.stderr.isEmpty) {
      return ToolResult(
          exitCode: 0,
          stdout: '',
          stderr: 'CandidateCDHash sha256=${codeHash(arguments.last)}\n');
    } else if (executable == 'codesign' &&
        arguments.first == '-dvvvvvv' &&
        result.stdout.isEmpty &&
        result.stderr.isEmpty) {
      final admitted = _constraints[arguments.last];
      return ToolResult(
          exitCode: 0,
          stdout: '',
          stderr: [
            if (admitted != null) ...[
              'Library Load Constraints:',
              '\tHas Library Load Constraints',
              '\t\t[Key] reqs',
              '\t\t\t\t[Key] cdhash',
              '\t\t\t\t\t\t[Key] \$in',
              for (final hash in admitted) '\t\t\t\t\t\t\t\t[Data] $hash',
            ],
            'Signature=fixture',
          ].join('\n'));
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
