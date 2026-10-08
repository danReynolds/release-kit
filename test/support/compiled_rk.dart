import 'dart:io';
import 'dart:typed_data';

import 'package:rk/src/transforms/digest.dart';

/// rk as a compiled executable, built once per change to its sources and
/// shared by every test that runs it as a process.
///
/// Running `dart bin/rk.dart` compiles rk and Fleury on every call, which was
/// most of the suite's time. Set `RK_TEST_EXECUTABLE` to use a binary built
/// elsewhere; CI builds one before `dart test`.
String compiledRk() => _compiled('bin/rk.dart', override: 'RK_TEST_EXECUTABLE');

/// The test entry point that sends rk's pub.dev traffic to a loopback
/// registry. Set `RK_TEST_LOCAL_PUB_EXECUTABLE` to use a prebuilt one.
String compiledLocalPubRk() => _compiled(
  'test/support/local_pub_rk.dart',
  override: 'RK_TEST_LOCAL_PUB_EXECUTABLE',
);

final _built = <String, String>{};

String _compiled(String entry, {required String override}) =>
    _built.putIfAbsent(entry, () {
      final given = Platform.environment[override];
      if (given != null && given.isNotEmpty) return given;
      final directory = Directory('.dart_tool/rk_test')
        ..createSync(recursive: true);
      final name = entry.split('/').last.replaceFirst('.dart', '');
      final executable = File('${directory.path}/$name-${_sourceKey(entry)}');
      if (executable.existsSync()) return executable.absolute.path;

      // Test files run concurrently. Creating the lock file exclusively is
      // atomic across isolates and processes: one compiles, the rest wait.
      final lock = File('${executable.path}.lock');
      while (true) {
        try {
          lock.createSync(exclusive: true);
          break;
        } on FileSystemException {
          if (executable.existsSync()) return executable.absolute.path;
          // A run that died mid-compile leaves its lock behind.
          if (_age(lock) > const Duration(minutes: 10)) _delete(lock);
          sleep(const Duration(milliseconds: 200));
        }
      }
      try {
        if (!executable.existsSync()) {
          for (final stale in directory.listSync().whereType<File>()) {
            final base = stale.uri.pathSegments.last;
            if (base.startsWith('$name-') && !base.endsWith('.lock')) {
              _delete(stale);
            }
          }
          final partial = '${executable.path}.partial';
          final built = Process.runSync(Platform.resolvedExecutable, [
            '--suppress-analytics',
            'compile',
            'exe',
            entry,
            '-o',
            partial,
          ]);
          if (built.exitCode != 0) {
            throw StateError(
              'could not compile $entry:\n${built.stdout}${built.stderr}',
            );
          }
          File(partial).renameSync(executable.path);
        }
        return executable.absolute.path;
      } finally {
        _delete(lock);
      }
    });

/// A digest of what the executable is built from: the entry point, rk's
/// sources, the resolved packages and the Dart SDK.
String _sourceKey(String entry) {
  final files = <File>[
    File(entry),
    File('pubspec.lock'),
    for (final root in ['lib', 'bin'])
      ...Directory(root)
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart')),
  ]..sort((left, right) => left.path.compareTo(right.path));
  final bytes = BytesBuilder(copy: false)..add(Platform.version.codeUnits);
  for (final file in files) {
    bytes
      ..add(file.path.codeUnits)
      ..add(file.readAsBytesSync());
  }
  return Sha256.hex(bytes.takeBytes()).substring(0, 16);
}

Duration _age(File file) {
  try {
    return DateTime.now().difference(file.statSync().modified);
  } on FileSystemException {
    return Duration.zero;
  }
}

void _delete(File file) {
  try {
    file.deleteSync();
  } on FileSystemException {
    // Another test cleaned it up first.
  }
}
