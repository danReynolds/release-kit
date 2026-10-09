import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../builds/binary_artifact.dart';
import '../engine/canonical_json.dart';
import '../engine/file_mode.dart';

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

  /// Compresses [bytes] without recording a timestamp or the machine that
  /// built it, so the same input produces the same output on any day and
  /// any host.
  static List<int> gzip(List<int> bytes) {
    final out = GZipCodec(level: 9).encode(bytes);
    out.setRange(4, 8, const [0, 0, 0, 0]); // no timestamp
    out[8] = 0x00; // no extra flags, rather than the compression level
    out[9] = 0xff; // unknown OS, rather than the one that happened to build it
    return out;
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

/// Reads back the gzip/ustar bytes [ArchiveBuilder] writes, and accepts
/// nothing else.
///
/// Only regular files with safe relative names are accepted. Header
/// checksums, padding, duplicate names, and the two-block trailer are all
/// checked, so what it reports is the archive users will actually unpack, not
/// merely a plausible prefix of it. The bytes come from the archive itself:
/// a reader verifies exactly what a consumer extracts, without trusting the
/// files that were handed to the builder.
final class ArchiveReader {
  ArchiveReader._(this.artifact, this.files, this._modes);

  /// Decodes and checks [archive], keeping every file it carries.
  factory ArchiveReader.decode(List<int> archive) {
    final List<int> tar;
    try {
      tar = GZipCodec().decode(archive);
    } on Object catch (error) {
      throw FormatException('archive is not valid gzip: $error');
    }
    return ArchiveReader.decodeTar(tar);
  }

  /// Checks an already expanded archive. A download can enforce a streaming
  /// decompression limit first, and still share these rules.
  factory ArchiveReader.decodeTar(List<int> tar) {
    final modes = <String, String>{};
    final files = <String, List<int>>{};
    var offset = 0;
    var zeroBlocks = 0;
    while (offset + 512 <= tar.length) {
      final header = tar.sublist(offset, offset + 512);
      offset += 512;
      if (header.every((byte) => byte == 0)) {
        zeroBlocks++;
        if (zeroBlocks == 2) break;
        continue;
      }
      if (zeroBlocks != 0) {
        throw const FormatException(
          'archive has an entry after its first zero trailer block',
        );
      }
      _verifyHeaderChecksum(header);

      final type = header[156];
      if (type != 0 && type != 0x30) {
        throw const FormatException('archive contains a non-regular entry');
      }
      final leaf = _text(header, 0, 100);
      final prefix = _text(header, 345, 155);
      final name = prefix.isEmpty ? leaf : '$prefix/$leaf';
      _requireSafeName(name);
      if (modes.containsKey(name)) {
        throw FormatException('archive contains duplicate entry: $name');
      }

      final modeValue = _octal(header, 100, 8, 'mode');
      if (modeValue != 0x1a4 && modeValue != 0x1ed) {
        throw FormatException(
          'archive entry $name has unsupported mode '
          '${modeValue.toRadixString(8)}',
        );
      }
      final size = _octal(header, 124, 12, 'size');
      if (size < 0 || offset + size > tar.length) {
        throw FormatException('archive entry $name exceeds the archive');
      }
      final bytes = tar.sublist(offset, offset + size);
      offset += size;
      final padding = (512 - (size % 512)) % 512;
      if (offset + padding > tar.length ||
          tar.sublist(offset, offset + padding).any((byte) => byte != 0)) {
        throw FormatException('archive entry $name has invalid padding');
      }
      offset += padding;
      modes[name] = modeValue.toRadixString(8).padLeft(4, '0');
      files[name] = List.unmodifiable(bytes);
    }

    if (zeroBlocks != 2) {
      throw const FormatException('archive has no complete tar trailer');
    }
    if (tar.skip(offset).any((byte) => byte != 0)) {
      throw const FormatException('archive has data after its tar trailer');
    }
    if (modes.isEmpty) {
      throw const FormatException('archive contains no files');
    }
    bool executable(String name) => modes[name] == '0755';
    final executables = modes.keys.where(executable).toList();
    final metadata = files[BinaryArtifact.manifestName];
    final BinaryArtifact artifact;
    if (metadata != null) {
      artifact = BinaryArtifact.fromJson(
        CanonicalJson.decodeDocument(utf8.decode(metadata)),
      );
    } else if (executables.length == 1) {
      artifact = BinaryArtifact.single(executables.single);
    } else {
      throw const FormatException(
        'archive must contain exactly one executable file',
      );
    }
    for (final file in artifact.files) {
      if (modes[file.path] != file.mode) {
        throw FormatException(
          'archive is missing ${file.path} with mode ${file.mode}',
        );
      }
    }
    final allowed = {
      for (final file in artifact.files) file.path,
      'LICENSE',
      'README.md',
    };
    for (final name in modes.keys) {
      if (!allowed.contains(name) ||
          ((name == 'LICENSE' || name == 'README.md') && executable(name))) {
        throw FormatException('unexpected artifact file: $name');
      }
    }
    return ArchiveReader._(
      artifact,
      Map.unmodifiable(files),
      Map.unmodifiable(modes),
    );
  }

  /// The program the archive ships.
  final BinaryArtifact artifact;

  /// Each file's bytes, by its path inside the archive.
  final Map<String, List<int>> files;

  /// Each file's mode, `0644` or `0755`, by its path inside the archive.
  final Map<String, String> _modes;

  /// Extracts only the validated regular files, into a new empty private
  /// directory.
  void extractTo(Directory directory) {
    if (directory.listSync().isNotEmpty) {
      throw ArgumentError('archive extraction requires an empty directory');
    }
    for (final MapEntry(key: name, value: bytes) in files.entries) {
      final file = File('${directory.path}/$name');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes, flush: true);
    }
    setFileModes({
      for (final MapEntry(key: name, value: mode) in _modes.entries)
        '${directory.path}/$name': mode,
    });
  }
}

void _verifyHeaderChecksum(List<int> header) {
  final expected = _octal(header, 148, 8, 'header checksum');
  var actual = 0;
  for (var index = 0; index < header.length; index++) {
    actual += index >= 148 && index < 156 ? 0x20 : header[index];
  }
  if (actual != expected) {
    throw const FormatException('archive tar header checksum is invalid');
  }
}

int _octal(List<int> bytes, int start, int length, String label) {
  final text = _text(bytes, start, length).trim();
  if (text.isEmpty || !RegExp(r'^[0-7]+$').hasMatch(text)) {
    throw FormatException('archive $label is not octal');
  }
  return int.parse(text, radix: 8);
}

String _text(List<int> bytes, int start, int length) {
  final field = bytes.sublist(start, start + length);
  final zero = field.indexOf(0);
  final content = zero < 0 ? field : field.sublist(0, zero);
  try {
    return utf8.decode(content);
  } on FormatException {
    throw const FormatException('archive header text is not UTF-8');
  }
}

void _requireSafeName(String name) {
  final parts = name.split('/');
  if (name.isEmpty ||
      name.startsWith('/') ||
      name.startsWith(r'\') ||
      name.contains(r'\') ||
      name.contains('\u0000') ||
      RegExp(r'^[A-Za-z]:').hasMatch(name) ||
      parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw FormatException('archive entry has an unsafe name: $name');
  }
}
