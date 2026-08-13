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

  /// Copies the example named [shape] into [parent] and makes it a repository.
  ///
  /// Copied rather than used in place, so a test that writes into a repository
  /// — and rk writes `.rk/` into every one it fails in — cannot leave anything
  /// behind in `examples/`.
  factory Rk.example(Directory parent, String shape, {String? as}) {
    final source = Directory('examples/$shape');
    if (!source.existsSync()) {
      fail('there is no example named "$shape" — see examples/README.md');
    }
    final dir = Directory('${parent.path}/${as ?? shape}')
      ..createSync(recursive: true);
    for (final entry in source.listSync(recursive: true)) {
      final relative = entry.path.substring(source.path.length + 1);
      if (entry is Directory) {
        Directory('${dir.path}/$relative').createSync(recursive: true);
      } else if (entry is File) {
        final target = File('${dir.path}/$relative')
          ..parent.createSync(recursive: true);
        target.writeAsBytesSync(entry.readAsBytesSync());
      }
    }
    return Rk._initialized(dir.path);
  }

  /// Creates a git repository under [parent] containing [files].
  ///
  /// For a shape too small or too odd to deserve a directory of its own. A
  /// shape a reader would want to see written out belongs in `examples/`.
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
    return Rk._initialized(dir.path);
  }

  factory Rk._initialized(String path) {
    final git = Process.runSync('git', ['init', '-q'], workingDirectory: path);
    expect(git.exitCode, 0, reason: 'the fixture must be a repository');
    return Rk(path);
  }

  /// Commits everything, so the fixture is a repository with a clean tree —
  /// which is what rk requires before it will release anything.
  void commit() {
    for (final args in [
      ['config', 'user.email', 'rk@example.test'],
      ['config', 'user.name', 'rk tests'],
      ['add', '-A'],
      ['commit', '-qm', 'the fixture'],
    ]) {
      Process.runSync('git', args, workingDirectory: root);
    }
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

  List<Map<String, Object?>> targetsOf(String unit) => units
      .where((u) => u['name'] == unit)
      .expand(
          (u) => ((u['targets'] as List?) ?? []).cast<Map<String, Object?>>())
      .toList();

  List<Map<String, Object?>> get problems =>
      ((json['problems'] as List?) ?? const []).cast<Map<String, Object?>>();

  List<Map<String, Object?>> get warnings =>
      ((json['warnings'] as List?) ?? const []).cast<Map<String, Object?>>();
}
