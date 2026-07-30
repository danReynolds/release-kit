import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Runs the real `rk` in a real repository.
///
/// Shared so that a conformance check can execute the program rather than read
/// a test file and hope. The phase 2 gate was, at one point, satisfied by
/// asserting that a file under test/ contained a particular sentence — which
/// meant renaming a test failed the phase and deleting the feature passed it.
class Rk {
  Rk(this.root);

  /// Creates a git repository under [parent] containing [files].
  factory Rk.repository(
    Directory parent,
    String name,
    Map<String, String> files,
  ) {
    final dir = Directory('${parent.path}/$name')..createSync(recursive: true);
    files.forEach((path, contents) {
      File('${dir.path}/$path')
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);
    });
    final git =
        Process.runSync('git', ['init', '-q'], workingDirectory: dir.path);
    expect(git.exitCode, 0, reason: 'the fixture must be a repository');
    return Rk(dir.path);
  }

  final String root;

  static final _bin = File('bin/rk.dart').absolute.path;

  Run call(List<String> args) {
    final result = Process.runSync(
      Platform.resolvedExecutable,
      ['run', _bin, ...args],
      workingDirectory: root,
    );
    return Run(
      code: result.exitCode,
      stdout: result.stdout as String,
      stderr: result.stderr as String,
    );
  }

  /// Every `run.json` a diagnosis left behind.
  List<Map<String, Object?>> diagnoses() {
    final dir = Directory('$root/.rk/diagnosis');
    if (!dir.existsSync()) return const [];
    return [
      for (final entry in dir.listSync())
        if (entry is Directory && File('${entry.path}/run.json').existsSync())
          jsonDecode(File('${entry.path}/run.json').readAsStringSync())
              as Map<String, Object?>,
    ];
  }
}

class Run {
  Run({required this.code, required this.stdout, required this.stderr});

  final int code;
  final String stdout;
  final String stderr;

  String get all => '$stdout$stderr';

  /// stdout parsed as the machine surface, failing loudly when it is not.
  Map<String, Object?> get json {
    try {
      return jsonDecode(stdout) as Map<String, Object?>;
    } on Object catch (error) {
      fail('stdout was not the document --json promises ($error):\n$stdout');
    }
  }

  List<Map<String, Object?>> get units =>
      ((json['units'] as List?) ?? const []).cast<Map<String, Object?>>();

  List<Map<String, Object?>> stepsOf(String unit) => units
      .where((u) => u['name'] == unit)
      .expand((u) => (u['steps'] as List).cast<Map<String, Object?>>())
      .toList();

  List<Map<String, Object?>> get problems =>
      ((json['problems'] as List?) ?? const []).cast<Map<String, Object?>>();
}

/// A keybay-shaped repository: a library and a CLI that depends on it.
const keybayFiles = {
  'release.toml': '''
schema = 1

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]

[release.cli]
path = "packages/keybay_cli"
publish = ["pub.dev", "github-release", "homebrew"]
binary_platforms = ["linux-x64", "macos-arm64"]
''',
  'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
  'packages/keybay_cli/pubspec.yaml': '''
name: keybay_cli
version: 0.2.0
dependencies:
  keybay: 0.2.0
executables:
  keybay: keybay
''',
};
