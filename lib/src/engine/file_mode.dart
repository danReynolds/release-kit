import 'dart:io';

/// Renders the POSIX permission and special bits recorded in stage receipts.
String posixMode(int mode) => (mode & 0xfff).toRadixString(8).padLeft(4, '0');

/// Gives each file its recorded POSIX mode, in one call per mode.
///
/// A `chmod` per file is a subprocess per file. Batching keeps exact source
/// copies cheap without making correctness depend on the host's copy defaults.
void setFileModes(Map<String, String> byPath) {
  final needing = <String, List<String>>{};
  byPath.forEach((path, wanted) {
    if (!RegExp(r'^0[0-7]{3}$').hasMatch(wanted)) {
      throw ArgumentError('file mode must look like 0644 or 0755: $wanted');
    }
    if (posixMode(File(path).statSync().mode) == wanted) return;
    needing.putIfAbsent(wanted.substring(1), () => []).add(path);
  });
  needing.forEach((permissions, paths) {
    // One argument list has a length the kernel will refuse. This bound is
    // well under every supported platform's limit.
    for (final batch in _batched(paths, 32000)) {
      final changed = Process.runSync('chmod', [permissions, ...batch]);
      if (changed.exitCode != 0) {
        throw FileSystemException(
          'could not preserve file mode $permissions: ${changed.stderr}',
          batch.first,
        );
      }
    }
  });
}

Iterable<List<String>> _batched(List<String> paths, int maxCharacters) sync* {
  var batch = <String>[];
  var length = 0;
  for (final path in paths) {
    if (batch.isNotEmpty && length + path.length + 1 > maxCharacters) {
      yield batch;
      batch = <String>[];
      length = 0;
    }
    batch.add(path);
    length += path.length + 1;
  }
  if (batch.isNotEmpty) yield batch;
}
