import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../engine/timings.dart';

/// SHA-256, the digest every staged and published byte is named by.
abstract final class Sha256 {
  /// The lowercase hexadecimal digest of [message].
  static String hex(List<int> message) => Timings.enabled
      ? Timings.timeTally('sha256', () => _hex(message), bytes: message.length)
      : _hex(message);

  static String _hex(List<int> message) =>
      crypto.sha256.convert(message).toString();

  /// Digests a file with bounded memory, returning the bytes actually read.
  static ({String sha256, int size}) file(File file) {
    final watch = Timings.enabled ? (Stopwatch()..start()) : null;
    final handle = file.openSync();
    var size = 0;
    try {
      late String digest;
      final sink = crypto.sha256.startChunkedConversion(
        ChunkedConversionSink.withCallback(
          (digests) => digest = digests.single.toString(),
        ),
      );
      final buffer = Uint8List(64 * 1024);
      while (true) {
        final count = handle.readIntoSync(buffer);
        if (count == 0) break;
        sink.add(Uint8List.sublistView(buffer, 0, count));
        size += count;
      }
      sink.close();
      return (sha256: digest, size: size);
    } finally {
      handle.closeSync();
      if (watch != null) {
        Timings.tally('sha256', bytes: size, elapsed: watch.elapsed);
      }
    }
  }
}
