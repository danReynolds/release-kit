import 'dart:convert';
import 'dart:io';

import '../transforms/digest.dart';

/// The safe, regular-file inventory inside one staged release archive.
class StageArchiveEntry {
  const StageArchiveEntry({
    required this.name,
    required this.mode,
    required this.size,
    required this.sha256,
  });

  factory StageArchiveEntry.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('archive inventory entry is not an object');
    }
    final map = value.cast<Object?, Object?>();
    const fields = {'mode', 'name', 'sha256', 'size'};
    if (map.keys.any((key) => key is! String) ||
        map.keys.cast<String>().toSet().difference(fields).isNotEmpty ||
        fields.difference(map.keys.cast<String>().toSet()).isNotEmpty) {
      throw const FormatException(
        'archive inventory entry has unknown or missing fields',
      );
    }
    final name = map['name'];
    final mode = map['mode'];
    final size = map['size'];
    final sha256 = map['sha256'];
    if (name is! String ||
        mode is! String ||
        size is! int ||
        sha256 is! String) {
      throw const FormatException('archive inventory entry has wrong types');
    }
    _requireSafeName(name);
    if (!RegExp(r'^0[0-7]{3}$').hasMatch(mode)) {
      throw const FormatException('archive inventory mode is invalid');
    }
    if (size < 0) {
      throw const FormatException('archive inventory size is negative');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw const FormatException('archive inventory digest is invalid');
    }
    return StageArchiveEntry(
      name: name,
      mode: mode,
      size: size,
      sha256: sha256,
    );
  }

  final String name;
  final String mode;
  final int size;
  final String sha256;

  bool get executable => mode == '0755';

  Map<String, Object?> toJson() => {
        'mode': mode,
        'name': name,
        'sha256': sha256,
        'size': size,
      };
}

/// Parses the deterministic gzip/ustar bytes rk itself produces.
///
/// Only regular files with safe relative names are accepted. Header
/// checksums, padding, duplicate names, and the two-block trailer are all
/// checked so receipt evidence describes the archive users will actually
/// unpack, not merely a plausible prefix of it.
abstract final class StageArchiveInventory {
  static List<StageArchiveEntry> parse(List<int> archive) {
    final List<int> tar;
    try {
      tar = GZipCodec().decode(archive);
    } on Object catch (error) {
      throw FormatException('archive is not valid gzip: $error');
    }

    final entries = <StageArchiveEntry>[];
    final names = <String>{};
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
      if (!names.add(name)) {
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
      entries.add(StageArchiveEntry(
        name: name,
        mode: modeValue.toRadixString(8).padLeft(4, '0'),
        size: size,
        sha256: Sha256.hex(bytes),
      ));
    }

    if (zeroBlocks != 2) {
      throw const FormatException('archive has no complete tar trailer');
    }
    if (tar.skip(offset).any((byte) => byte != 0)) {
      throw const FormatException('archive has data after its tar trailer');
    }
    if (entries.isEmpty) {
      throw const FormatException('archive contains no files');
    }
    if (entries.where((entry) => entry.executable).length != 1) {
      throw const FormatException(
        'archive must contain exactly one executable file',
      );
    }
    return List<StageArchiveEntry>.unmodifiable(entries);
  }

  static List<StageArchiveEntry> parseEvidence(Object? value) {
    if (value is! List) {
      throw const FormatException('archive inventory evidence is not a list');
    }
    final entries = value.map(StageArchiveEntry.fromJson).toList();
    final names = <String>{};
    for (final entry in entries) {
      if (!names.add(entry.name)) {
        throw FormatException(
          'archive inventory evidence repeats ${entry.name}',
        );
      }
    }
    return entries;
  }

  static List<Object?> evidence(List<StageArchiveEntry> entries) => [
        for (final entry in entries) entry.toJson(),
      ];

  static void requireSame(
    List<StageArchiveEntry> expected,
    List<StageArchiveEntry> actual,
  ) {
    if (expected.length != actual.length) {
      throw const FormatException(
        'archive inventory differs from its receipt evidence',
      );
    }
    for (var index = 0; index < expected.length; index++) {
      final left = expected[index];
      final right = actual[index];
      if (left.name != right.name ||
          left.mode != right.mode ||
          left.size != right.size ||
          left.sha256 != right.sha256) {
        throw FormatException(
          'archive inventory differs at ${right.name}',
        );
      }
    }
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
