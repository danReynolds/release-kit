import 'dart:io';

/// Writes one file as a flushed sibling followed by an atomic rename.
///
/// Callers remain responsible for validating the destination and its parent
/// path. This helper owns only the byte replacement boundary and cleanup of
/// the private temporary file when writing or renaming fails.
abstract final class AtomicFile {
  static void write(String destination, List<int> bytes) {
    final temporary = File(
      '$destination.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      temporary.writeAsBytesSync(bytes, flush: true);
      temporary.renameSync(destination);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }
}
