import 'dart:typed_data';

/// SHA-256, written rather than imported.
///
/// rk has no runtime dependencies, which keeps third-party code away from the
/// signing path — and a digest is the one primitive every identity decision
/// rests on, so it is the last thing that should come from somewhere else.
class Sha256 {
  static final _k = Uint32List.fromList(const <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, //
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ]);

  /// The lowercase hexadecimal digest of [message].
  static String hex(List<int> message) {
    final digest = bytes(message);
    final out = StringBuffer();
    for (final byte in digest) {
      out.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  /// The digest of [message].
  ///
  /// Whole 64-byte blocks are compressed straight out of [message]; only the
  /// tail is copied, to carry the terminator, the zero padding, and the
  /// length. Padding by building one list of the whole message first cost
  /// more than the hashing did — a growable `List<int>` holds eight bytes
  /// per element, so a 10MB input became an 80MB list — and every staged
  /// byte passes through here, several times over a release.
  static Uint8List bytes(List<int> message) {
    // Typed once, so the compression loop indexes bytes rather than a
    // generic list. Callers reading files already hand over a Uint8List.
    final data = message is Uint8List ? message : Uint8List.fromList(message);
    final h = Uint32List.fromList(const <int>[
      0x6a09e667,
      0xbb67ae85,
      0x3c6ef372,
      0xa54ff53a,
      0x510e527f,
      0x9b05688c,
      0x1f83d9ab,
      0x5be0cd19,
    ]);
    final w = Uint32List(64);

    final length = data.length;
    final whole = length - (length % 64);
    for (var at = 0; at < whole; at += 64) {
      _compress(data, at, w, h);
    }

    // The terminator, the zeroes, and the 64-bit length need one more block,
    // or two when the remainder leaves no room for the length.
    final remaining = length - whole;
    final tail = Uint8List(remaining < 56 ? 64 : 128);
    for (var i = 0; i < remaining; i++) {
      tail[i] = data[whole + i];
    }
    tail[remaining] = 0x80;
    final bitLength = length * 8;
    for (var i = 0; i < 8; i++) {
      tail[tail.length - 1 - i] = (bitLength >> (i * 8)) & 0xff;
    }
    for (var at = 0; at < tail.length; at += 64) {
      _compress(tail, at, w, h);
    }

    final out = Uint8List(32);
    for (var i = 0; i < 8; i++) {
      final value = h[i];
      out[i * 4] = (value >> 24) & 0xff;
      out[i * 4 + 1] = (value >> 16) & 0xff;
      out[i * 4 + 2] = (value >> 8) & 0xff;
      out[i * 4 + 3] = value & 0xff;
    }
    return out;
  }

  /// One 64-byte block into the running state. Stores into [w] and [h]
  /// truncate to 32 bits, which is the arithmetic SHA-256 asks for.
  static void _compress(Uint8List data, int at, Uint32List w, Uint32List h) {
    for (var i = 0; i < 16; i++) {
      final j = at + i * 4;
      w[i] = (data[j] << 24) |
          (data[j + 1] << 16) |
          (data[j + 2] << 8) |
          data[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final left = w[i - 15];
      final right = w[i - 2];
      final s0 = _rotr(left, 7) ^ _rotr(left, 18) ^ (left >> 3);
      final s1 = _rotr(right, 17) ^ _rotr(right, 19) ^ (right >> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    var a = h[0],
        b = h[1],
        c = h[2],
        d = h[3],
        e = h[4],
        f = h[5],
        g = h[6],
        seventh = h[7];

    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ (~e & 0xffffffff & g);
      final temp1 = (seventh + s1 + ch + _k[i] + w[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xffffffff;

      seventh = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }

    h[0] += a;
    h[1] += b;
    h[2] += c;
    h[3] += d;
    h[4] += e;
    h[5] += f;
    h[6] += g;
    h[7] += seventh;
  }

  static int _rotr(int value, int by) =>
      ((value >> by) | (value << (32 - by))) & 0xffffffff;
}
