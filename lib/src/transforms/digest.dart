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
}
