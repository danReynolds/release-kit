import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Builds the tar.gz a platform ships, byte-reproducibly.
///
/// Determinism is a requirement rather than polish: without it, "is this the
/// artifact I would have made" is undecidable, and every reuse decision
/// degenerates from identity into acceptability. Fixed entry order, zeroed
/// timestamps and ownership, normalised modes, and no gzip timestamp.
class ArchiveBuilder {
  /// Entries in the order they will be written, which is the order given.
  static Uint8List tar(List<ArchiveEntry> entries) {
    final out = BytesBuilder();
    for (final entry in entries) {
      out.add(_header(entry));
      out.add(entry.bytes);
      final padding = (512 - (entry.bytes.length % 512)) % 512;
      if (padding > 0) out.add(Uint8List(padding));
    }
    // Two zero blocks end the archive.
    out.add(Uint8List(1024));
    return out.takeBytes();
  }

  /// A ustar header with everything volatile zeroed.
  static Uint8List _header(ArchiveEntry entry) {
    final header = Uint8List(512);

    void write(String value, int offset, int length) {
      final bytes = utf8.encode(value);
      for (var i = 0; i < bytes.length && i < length; i++) {
        header[offset + i] = bytes[i];
      }
    }

    /// Octal, NUL-terminated, as tar requires.
    void writeOctal(int value, int offset, int length) {
      write(value.toRadixString(8).padLeft(length - 1, '0'), offset, length);
    }

    write(entry.name, 0, 100);
    writeOctal(entry.executable ? 0x1ed : 0x1a4, 100, 8); // 0755 or 0644
    writeOctal(0, 108, 8); // uid: a release is nobody's
    writeOctal(0, 116, 8); // gid
    writeOctal(entry.bytes.length, 124, 12);
    writeOctal(0, 136, 12); // mtime: zeroed, so the bytes do not move
    write('0', 156, 1); // a regular file
    write('ustar', 257, 6);
    write('00', 263, 2);

    // The checksum is computed with its own field read as spaces.
    for (var i = 148; i < 156; i++) {
      header[i] = 0x20;
    }
    var sum = 0;
    for (final byte in header) {
      sum += byte;
    }
    writeOctal(sum, 148, 7);
    header[155] = 0x20;

    return header;
  }

  /// Compresses [bytes] without recording a timestamp, so the same input
  /// produces the same output on any day.
  static List<int> gzip(List<int> bytes) {
    final deflated = ZLibCodec(raw: true, level: 9).encode(bytes);
    return [
      0x1f, 0x8b, // magic
      0x08, // deflate
      0x00, // no flags
      0, 0, 0, 0, // mtime, zeroed
      0x00, // no extra flags
      0xff, // unknown OS, rather than the one that happened to build it
      ...deflated,
      ..._le32(_crc32(bytes)),
      ..._le32(bytes.length & 0xffffffff),
    ];
  }

  static List<int> _le32(int value) => [
        value & 0xff,
        (value >> 8) & 0xff,
        (value >> 16) & 0xff,
        (value >> 24) & 0xff,
      ];

  static final _crcTable = () {
    final table = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
      }
      table[i] = c;
    }
    return table;
  }();

  static int _crc32(List<int> bytes) {
    var crc = 0xffffffff;
    for (final byte in bytes) {
      crc = _crcTable[(crc ^ byte) & 0xff] ^ (crc >> 8);
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }
}

class ArchiveEntry {
  ArchiveEntry({
    required this.name,
    required this.bytes,
    this.executable = false,
  });

  /// The path inside the archive.
  final String name;

  final List<int> bytes;
  final bool executable;
}
