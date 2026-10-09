import 'dart:io';

/// Writes one file as a flushed sibling followed by an atomic rename.
///
/// Callers remain responsible for validating the destination and its parent
/// path. This helper owns only the byte replacement boundary and cleanup of
/// the private temporary file when writing or renaming fails.
abstract final class AtomicFile {
  static void write(String destination, List<int> bytes) => _replace(
    destination,
    (temporary) => temporary.writeAsBytesSync(bytes, flush: true),
  );

  /// Copies an existing file without loading its contents into memory.
  static void copy(String destination, File source) =>
      _replace(destination, (temporary) {
        source.copySync(temporary.path);
        final handle = temporary.openSync(mode: FileMode.append);
        try {
          handle.flushSync();
        } finally {
          handle.closeSync();
        }
      });

  static void _replace(String destination, void Function(File) prepare) {
    final temporary = File(
      '$destination.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      prepare(temporary);
      temporary.renameSync(destination);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }
}
