import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/transforms/digest.dart';

/// Models compiler/copy/launcher outputs for release orchestration tests, and
/// what codesign reports about the files it signed: identifiers and code
/// hashes, which depend on any embedded library load constraint. No platform
/// executable runs. Real launcher and pinning behavior have separate tests.
///
/// A scripted result always wins, as [RecordingTools] promises. The model
/// answers only the codesign displays nothing scripted.
class BundleRecordingTools extends RecordingTools {
  BundleRecordingTools({
    super.results,
    super.answers,
    super.onRun,
    super.probe,
  });
  final _identifiers = <String, String>{};
  final _signatures = <String, _Signature>{};

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
    final result =
        results[key] ??
        answers?.call(key) ??
        _display(executable, arguments) ??
        ToolResult(exitCode: 0, stdout: '', stderr: '');
    if (!result.ok) return result;
    if (arguments.firstOrNull == 'compile') {
      final output = arguments[arguments.indexOf('-o') + 1];
      File(output)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('BINARY 1.0.0');
    } else if (executable == '/bin/cp') {
      File(arguments.first).copySync(arguments.last);
      // A copy carries its source's signature, not one made here.
      _signatures.remove(arguments.last);
    } else if (executable.endsWith('/clang')) {
      File(arguments.last).writeAsStringSync('LAUNCHER');
    } else if (executable == '/bin/chmod') {
      Process.runSync(executable, arguments);
    } else if (executable == 'codesign' && arguments.contains('--identifier')) {
      final path = arguments.last;
      final identifier = arguments[arguments.indexOf('--identifier') + 1];
      _identifiers[path] = identifier;
      final at = arguments.indexOf('--library-constraint');
      _signatures[path] = _Signature(
        File(path).readAsBytesSync(),
        identifier,
        at < 0
            ? null
            : parsePlist(File(arguments[at + 1]).readAsStringSync())
                  as Map<String, Object?>,
      );
    } else if (executable == 'codesign' && arguments.contains('-r-')) {
      final id = _identifiers[arguments.last];
      if (id != null) {
        String identify(String value) {
          if (value.contains('identifier')) {
            return value.replaceFirst(
              RegExp(r'identifier\s+(?:"[^"]+"|\S+)'),
              'identifier "$id"',
            );
          }
          return value.replaceFirst(
            'designated => ',
            'designated => identifier "$id" and ',
          );
        }

        return ToolResult(
          exitCode: result.exitCode,
          stdout: identify(result.stdout),
          stderr: identify(result.stderr),
        );
      }
    }
    return result;
  }

  /// codesign's display of [arguments]' file, as codesign reports it: a
  /// failure for anything missing, unsigned or changed since it was signed.
  ToolResult? _display(String executable, List<String> arguments) {
    if (executable != 'codesign' || arguments.length != 2) return null;
    final [flag, path] = arguments;
    if (flag != '-dvvv') return null;
    final file = File(path);
    if (!file.existsSync()) {
      return ToolResult(
        exitCode: 1,
        stdout: '',
        stderr: '$path: No such file or directory',
      );
    }
    final signature = _signatures[path];
    if (signature == null || !signature.covers(file.readAsBytesSync())) {
      return ToolResult(
        exitCode: 1,
        stdout: '',
        stderr: '$path: code object is not signed at all',
      );
    }
    return ToolResult(
      exitCode: 0,
      stdout: '',
      stderr: 'CandidateCDHash sha256=${signature.cdhash}\n',
    );
  }
}

/// A signature made here. Its code hash depends on the bytes it covers and
/// what it was signed with, not on where the file is.
final class _Signature {
  factory _Signature(
    List<int> bytes,
    String identifier,
    Map<String, Object?>? constraint,
  ) {
    final digest = Sha256.hex(bytes);
    final signed = [
      digest,
      identifier,
      if (constraint != null) ..._render(constraint, 0),
    ].join('\n');
    return _Signature._(
      digest,
      Sha256.hex(utf8.encode(signed)).substring(0, 40),
    );
  }
  _Signature._(this._digest, this.cdhash);

  final String _digest;
  final String cdhash;

  bool covers(List<int> bytes) => Sha256.hex(bytes) == _digest;
}

List<String> _render(Object? value, int depth) {
  final indent = '\t' * depth;
  return switch (value) {
    Map map => [
      '$indent[Dict]',
      for (final entry in map.entries) ...[
        '$indent\t[Key] ${entry.key}',
        '$indent\t[Value]',
        ..._render(entry.value, depth + 2),
      ],
    ],
    Uint8List bytes => [
      '$indent[Data] '
          '${[for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0')].join()}',
    ],
    List list => [
      '$indent[Array]',
      for (final item in list) ..._render(item, depth + 1),
    ],
    int number => ['$indent[Int] $number'],
    bool flag => ['$indent[Bool] $flag'],
    _ => ['$indent[String] $value'],
  };
}

/// Parses the XML property lists codesign takes as inputs: dict, key, array,
/// data, string, integer, true and false.
Object? parsePlist(String xml) {
  final tokens = RegExp(
    r'<(dict|array)>|</(dict|array)>|'
    r'<(key|data|string|integer)>([^<]*)</\3>|<(true|false)\s*/>|'
    r'<(dict|array)\s*/>',
  ).allMatches(xml).toList();
  var at = 0;
  Object? value() {
    final token = tokens[at++];
    if (token.group(1) == 'dict') {
      final map = <String, Object?>{};
      while (tokens[at].group(2) != 'dict') {
        final key = tokens[at++];
        if (key.group(3) != 'key') {
          throw FormatException('expected a key, found ${key.group(0)}');
        }
        map[key.group(4)!] = value();
      }
      at++;
      return map;
    }
    if (token.group(1) == 'array') {
      final list = <Object?>[];
      while (tokens[at].group(2) != 'array') {
        list.add(value());
      }
      at++;
      return list;
    }
    if (token.group(6) != null) {
      return token.group(6) == 'dict' ? <String, Object?>{} : <Object?>[];
    }
    if (token.group(5) != null) return token.group(5) == 'true';
    final text = token.group(4)!.trim();
    return switch (token.group(3)) {
      'data' => base64.decode(text.replaceAll(RegExp(r'\s'), '')),
      'string' => text,
      'integer' => int.parse(text),
      _ => throw FormatException('unexpected ${token.group(0)}'),
    };
  }

  return value();
}
