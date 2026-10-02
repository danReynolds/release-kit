import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tar/tar.dart';

import '../engine/file_mode.dart';
import '../engine/stage.dart';
import '../transforms/digest.dart';

/// Validated native tar.gz contents. Pub and future tar-based native adapters
/// share the format reader; package identities and manifests remain native.
final class NativePackageArchive {
  NativePackageArchive._(
    Uint8List bytes,
    this.sha256,
    this.files,
    this.directories,
  ) : bytes = bytes.asUnmodifiableView();

  /// The exact validated archive, for native preload into an owned scratch file.
  final Uint8List bytes;
  final String sha256;
  final Map<String, NativeArchiveFile> files;
  final Set<String> directories;

  static Future<NativePackageArchive> read(
    File archive, {
    String? expectedSha256,
    int maxCompressedBytes = 128 * 1024 * 1024,
    int maxExpandedBytes = 512 * 1024 * 1024,
    int maxEntries = 100000,
  }) async {
    final bytes = await _collect(archive.openRead(), maxCompressedBytes);
    final digest = Sha256.hex(bytes);
    if (expectedSha256 != null && digest != expectedSha256) {
      throw const FormatException('native package archive digest changed');
    }
    final tar = await _collect(
      Stream<List<int>>.value(bytes).transform(gzip.decoder),
      maxExpandedBytes,
    );
    // Dart's streaming gzip decoder can emit a complete payload from a stream
    // whose footer was truncated. Require the single native gzip member's
    // final CRC/size too, before trusting those emitted bytes.
    if (bytes.length < 18 ||
        bytes[0] != 0x1f ||
        bytes[1] != 0x8b ||
        bytes[2] != 8) {
      throw const FormatException(
        'native package is not a complete gzip archive',
      );
    }
    final footer = ByteData.sublistView(bytes, bytes.length - 8);
    if (footer.getUint32(0, Endian.little) != Crc32.hash(tar) ||
        footer.getUint32(4, Endian.little) != (tar.length & 0xffffffff)) {
      throw const FormatException(
        'native package gzip checksum or size is invalid',
      );
    }
    // TarReader supplies native format interpretation and checksums. This
    // additional envelope check refuses truncated trailers and malformed PAX
    // tails the native reader intentionally tolerates, before preload sees them.
    _validateEnvelope(tar, maxEntries);
    final reader = TarReader(
      Stream.value(tar),
      disallowTrailingData: true,
      maxSpecialFileSize: 1024 * 1024,
    );
    final files = <String, NativeArchiveFile>{};
    final directories = <String>{};
    final explicit = <String>{};
    var count = 0;
    var totalFilesSize = 0;
    try {
      while (await reader.moveNext()) {
        if (++count > maxEntries) {
          throw const FormatException('native package has too many entries');
        }
        final entry = reader.current;
        final header = entry.header;
        final directory = header.typeFlag == TypeFlag.dir;
        if (!directory && header.typeFlag != TypeFlag.reg) {
          throw FormatException(
            'native package contains a link or unsupported entry: ${header.name}',
          );
        }
        final name = _safeName(header.name, directory: directory);
        if (!explicit.add(name)) {
          throw FormatException(
            'native package contains duplicate entry: $name',
          );
        }
        if (header.mode < 0 || (header.mode & ~0x1ff) != 0) {
          throw FormatException(
            'native package has special permission bits: $name',
          );
        }
        if (directory && header.size != 0) {
          throw FormatException(
            'native package directory has a payload: $name',
          );
        }
        if (name.isEmpty) continue; // An explicit ./ root directory.
        final parts = name.split('/');
        for (var i = 1; i < parts.length; i++) {
          final parent = parts.take(i).join('/');
          if (files.containsKey(parent)) {
            throw FormatException(
              'native package path is also a file: $parent',
            );
          }
          directories.add(parent);
        }
        if (files.containsKey(name) ||
            (!directory && directories.contains(name))) {
          throw FormatException(
            'native package path has conflicting types: $name',
          );
        }
        if (directory) {
          directories.add(name);
        } else {
          if (header.size < 0 ||
              header.size > maxExpandedBytes - totalFilesSize) {
            throw FormatException('native package file is too large: $name');
          }
          totalFilesSize += header.size;
          final content = await _collect(entry.contents, header.size);
          if (content.length != header.size) {
            throw FormatException('native package file is truncated: $name');
          }
          // Pub normalizes read/write permissions and preserves executable
          // bits. Use the same effective mode for the checked extraction.
          files[name] = NativeArchiveFile._(
            content,
            posixMode(0x1a4 | (header.mode & 0x49)),
          );
        }
      }
    } finally {
      await reader.cancel();
    }
    if (files.isEmpty) {
      throw const FormatException('native package has no files');
    }
    return NativePackageArchive._(
      bytes,
      digest,
      Map.unmodifiable(files),
      Set.unmodifiable(directories),
    );
  }

  /// Always creates its own empty directory. It never overlays a checkout,
  /// follows an archive link, or fills absent files from workspace sources.
  Directory extract() {
    final root = Directory.systemTemp.createTempSync('rk-native-package-');
    try {
      for (final name in directories.toList()..sort()) {
        Directory('${root.path}/$name').createSync(recursive: true);
      }
      final modes = <String, String>{};
      for (final entry in files.entries) {
        final file = File('${root.path}/${entry.key}');
        // Detect aliases on this filesystem (case folding and Unicode forms)
        // before a later entry could overwrite bytes already extracted.
        if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw FormatException(
            'native package paths alias on this filesystem: ${entry.key}',
          );
        }
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(entry.value.bytes, flush: true);
        modes[file.path] = entry.value.mode;
      }
      setFileModes(modes);
      return root;
    } on Object {
      root.deleteSync(recursive: true);
      rethrow;
    }
  }

  /// Checks the native package manager's extraction against the approved
  /// inventory. A successful native preload alone is not archive fidelity.
  void requireExtracted(Directory root) {
    if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException(
        'native package cache root is not a directory',
      );
    }
    final seen = <String>{};
    final seenDirectories = <String>{};
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      final name = entity.path
          .substring(root.path.length + 1)
          .replaceAll(Platform.pathSeparator, '/');
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      if (type == FileSystemEntityType.directory &&
          directories.contains(name)) {
        seenDirectories.add(name);
        continue;
      }
      final expected = files[name];
      if (type != FileSystemEntityType.file || expected == null) {
        throw FormatException(
          'native package cache has an unexpected entry: $name',
        );
      }
      final bytes = File(entity.path).readAsBytesSync();
      if (bytes.length != expected.bytes.length ||
          Sha256.hex(bytes) != expected.sha256 ||
          (!Platform.isWindows &&
              posixMode(entity.statSync().mode) != expected.mode)) {
        throw FormatException(
          'native package cache differs from its archive: $name',
        );
      }
      seen.add(name);
    }
    if (seen.length != files.length ||
        !seenDirectories.containsAll(directories)) {
      throw const FormatException(
        'native package cache omits archive files or directories',
      );
    }
  }
}

final class NativeArchiveFile {
  NativeArchiveFile._(Uint8List bytes, this.mode)
    : bytes = bytes.asUnmodifiableView();
  final Uint8List bytes;
  final String mode;
  late final String sha256 = Sha256.hex(bytes);
}

String _safeName(String name, {required bool directory}) {
  while (name.startsWith('./')) {
    name = name.substring(2);
  }
  if (directory && (name.isEmpty || name == '.')) return '';
  if (directory && name.endsWith('/')) {
    name = name.substring(0, name.length - 1);
  }
  StagePath.require(name);
  final parts = name.split('/');
  if (utf8.encode(name).length > 4096 || parts.length > 128) {
    throw const FormatException(
      'native package path exceeds the supported length or depth',
    );
  }
  if (name.contains(RegExp(r'[\x00-\x1f\x7f:]'))) {
    throw FormatException('native package has an unsafe filename: $name');
  }
  if (Platform.isWindows &&
      parts.any(
        (part) =>
            part.endsWith('.') ||
            part.endsWith(' ') ||
            RegExp(
              r'^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
              caseSensitive: false,
            ).hasMatch(part),
      )) {
    throw FormatException('native package has a reserved Windows path: $name');
  }
  return name;
}

Future<Uint8List> _collect(Stream<List<int>> stream, int limit) async {
  final result = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (chunk.length > limit - result.length) {
      throw FormatException('native package exceeds the $limit byte limit');
    }
    result.add(chunk);
  }
  return result.takeBytes();
}

/// Strict framing around the native tar parser, not another name/format
/// interpreter. In particular PAX size applies to the next real entry, never
/// to an intervening GNU/PAX metadata header.
void _validateEnvelope(Uint8List tar, int maxEntries) {
  var offset = 0;
  var count = 0;
  int? nextSize;
  var pendingMetadata = false;
  while (offset + 512 <= tar.length) {
    final header = Uint8List.sublistView(tar, offset, offset + 512);
    offset += 512;
    if (header.every((b) => b == 0)) {
      if (pendingMetadata ||
          tar.length - offset < 512 ||
          tar.length % 512 != 0 ||
          tar.skip(offset).any((b) => b != 0)) {
        throw const FormatException(
          'native package has an incomplete or invalid tar trailer',
        );
      }
      return;
    }
    if (++count > maxEntries) {
      throw const FormatException('native package has too many tar entries');
    }
    final type = header[156];
    final metadata = type == 0x78 || type == 0x4c; // x: PAX, L: GNU name.
    if (!metadata && type != 0 && type != 0x30 && type != 0x35) {
      throw const FormatException(
        'native package contains a link, global PAX, or unsupported tar entry',
      );
    }
    final rawSize = _size(header.sublist(124, 136));
    final size = metadata ? rawSize : nextSize ?? rawSize;
    // Native TarReader treats directory contents as empty irrespective of the
    // encoded size. Do not let a payload hide headers from this framing check.
    if (type == 0x35 && size != 0) {
      throw const FormatException('native package directory has a payload');
    }
    final padded = ((size + 511) ~/ 512) * 512;
    if (size > tar.length - offset ||
        padded > tar.length - offset ||
        tar.sublist(offset + size, offset + padded).any((b) => b != 0)) {
      throw const FormatException(
        'native package has a truncated payload or invalid padding',
      );
    }
    if (metadata) {
      // Native tar applies a preceding PAX size to metadata headers too.
      // Refuse stacked headers rather than maintain a second interpretation.
      if (pendingMetadata) {
        throw const FormatException('native package has stacked tar metadata');
      }
      if (size > 1024 * 1024) {
        throw const FormatException('native package metadata is too large');
      }
      pendingMetadata = true;
      if (type == 0x78) {
        final pax = _pax(Uint8List.sublistView(tar, offset, offset + size));
        if (pax['size'] case final value?) {
          if (!RegExp(r'^[0-9]+$').hasMatch(value)) {
            throw const FormatException('invalid native PAX size');
          }
          nextSize = int.tryParse(value);
          if (nextSize == null || nextSize < 0) {
            throw const FormatException('invalid native PAX size');
          }
        }
      }
    } else {
      nextSize = null;
      pendingMetadata = false;
    }
    offset += padded;
  }
  throw const FormatException('native package has no complete tar trailer');
}

int _size(List<int> bytes) {
  if ((bytes.first & 0x80) != 0) {
    if ((bytes.first & 0x40) != 0) {
      throw const FormatException('negative native tar size');
    }
    var value = bytes.first & 0x7f;
    for (final b in bytes.skip(1)) {
      if (value > 0x1fffffffffffff ~/ 256) {
        throw const FormatException('native tar size is out of range');
      }
      value = value * 256 + b;
    }
    return value;
  }
  final zero = bytes.indexOf(0);
  if (zero >= 0 && bytes.skip(zero).any((b) => b != 0 && b != 32)) {
    throw const FormatException('invalid native tar size padding');
  }
  final text = String.fromCharCodes(zero < 0 ? bytes : bytes.take(zero)).trim();
  if (text.isEmpty) return 0;
  if (!RegExp(r'^[0-7]+$').hasMatch(text)) {
    throw const FormatException('invalid native tar size');
  }
  final value = int.tryParse(text, radix: 8);
  if (value == null || value < 0) {
    throw const FormatException('invalid native tar size');
  }
  return value;
}

Map<String, String> _pax(Uint8List bytes) {
  var offset = 0;
  final values = <String, String>{};
  while (offset < bytes.length) {
    final space = bytes.indexOf(32, offset);
    if (space < 0) throw const FormatException('malformed native PAX record');
    final lengthText = String.fromCharCodes(bytes.sublist(offset, space));
    final length = int.tryParse(lengthText);
    if (!RegExp(r'^[1-9][0-9]*$').hasMatch(lengthText) ||
        length == null ||
        length <= space - offset + 3 ||
        length > bytes.length - offset ||
        bytes[offset + length - 1] != 10) {
      throw const FormatException('malformed native PAX record');
    }
    final end = offset + length;
    final equals = bytes.indexOf(61, space + 1);
    if (equals <= space + 1 || equals >= end - 1) {
      throw const FormatException('malformed native PAX record');
    }
    final key = utf8.decode(bytes.sublist(space + 1, equals));
    // Restrict metadata with extraction semantics. Pub does not need sparse
    // files, links, ACLs or device attributes to represent a package payload.
    if (!const {
      'path',
      'size',
      'mtime',
      'atime',
      'ctime',
      'uid',
      'gid',
      'uname',
      'gname',
      'comment',
      'charset',
    }.contains(key)) {
      throw FormatException('unsupported native PAX metadata: $key');
    }
    if (values.containsKey(key)) {
      throw FormatException('duplicate native PAX key: $key');
    }
    values[key] = utf8.decode(bytes.sublist(equals + 1, end - 1));
    offset = end;
  }
  return values;
}
