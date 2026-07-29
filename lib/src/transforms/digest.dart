/// SHA-256, written rather than imported.
///
/// rk has no runtime dependencies, which keeps third-party code away from the
/// signing path — and a digest is the one primitive every identity decision
/// rests on, so it is the last thing that should come from somewhere else.
class Sha256 {
  static const _k = <int>[
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
  ];

  /// The lowercase hexadecimal digest of [message].
  static String hex(List<int> message) {
    final digest = bytes(message);
    final out = StringBuffer();
    for (final byte in digest) {
      out.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  static List<int> bytes(List<int> message) {
    var h0 = 0x6a09e667,
        h1 = 0xbb67ae85,
        h2 = 0x3c6ef372,
        h3 = 0xa54ff53a,
        h4 = 0x510e527f,
        h5 = 0x9b05688c,
        h6 = 0x1f83d9ab,
        h7 = 0x5be0cd19;

    final padded = _pad(message);
    final w = List<int>.filled(64, 0);

    for (var chunk = 0; chunk < padded.length; chunk += 64) {
      for (var i = 0; i < 16; i++) {
        final at = chunk + i * 4;
        w[i] = (padded[at] << 24) |
            (padded[at + 1] << 16) |
            (padded[at + 2] << 8) |
            padded[at + 3];
      }
      for (var i = 16; i < 64; i++) {
        final s0 =
            _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = _add(_add(w[i - 16], s0), _add(w[i - 7], s1));
      }

      var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;

      for (var i = 0; i < 64; i++) {
        final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
        final ch = (e & f) ^ (~e & 0xffffffff & g);
        final temp1 = _add(_add(_add(h, s1), _add(ch, _k[i])), w[i]);
        final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final temp2 = _add(s0, maj);

        h = g;
        g = f;
        f = e;
        e = _add(d, temp1);
        d = c;
        c = b;
        b = a;
        a = _add(temp1, temp2);
      }

      h0 = _add(h0, a);
      h1 = _add(h1, b);
      h2 = _add(h2, c);
      h3 = _add(h3, d);
      h4 = _add(h4, e);
      h5 = _add(h5, f);
      h6 = _add(h6, g);
      h7 = _add(h7, h);
    }

    final out = <int>[];
    for (final value in [h0, h1, h2, h3, h4, h5, h6, h7]) {
      out.addAll([
        (value >> 24) & 0xff,
        (value >> 16) & 0xff,
        (value >> 8) & 0xff,
        value & 0xff,
      ]);
    }
    return out;
  }

  /// Appends the 1 bit, the zero padding, and the 64-bit length.
  static List<int> _pad(List<int> message) {
    final bitLength = message.length * 8;
    final padded = <int>[...message, 0x80];
    while (padded.length % 64 != 56) {
      padded.add(0);
    }
    for (var shift = 56; shift >= 0; shift -= 8) {
      padded.add((bitLength >> shift) & 0xff);
    }
    return padded;
  }

  static int _rotr(int value, int by) =>
      ((value >> by) | (value << (32 - by))) & 0xffffffff;

  static int _add(int a, int b) => (a + b) & 0xffffffff;
}

/// The `SHA256SUMS` file shipped beside a release's assets.
class Checksums {
  /// One line per asset, in the order given: digest, two spaces, name — the
  /// format `shasum -c` reads.
  static String render(Map<String, List<int>> assets) {
    final out = StringBuffer();
    for (final entry in assets.entries) {
      out.writeln('${Sha256.hex(entry.value)}  ${entry.key}');
    }
    return out.toString();
  }
}
