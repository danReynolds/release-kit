import 'dart:convert';

import '../../engine/stage.dart';
import '../../transforms/digest.dart';
import 'dependencies.dart';
import 'package_archive.dart';

/// Source identity only. The lock's contents are read from the authoritative
/// source snapshot, never from a restored context's caller-supplied YAML.
final class DartLockBinding {
  DartLockBinding({required this.path, required this.sha256}) {
    final parts = StagePath.segments(path);
    if (parts.last != 'pubspec.lock' ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw const FormatException('invalid native lockfile binding');
    }
  }
  final String path;
  final String sha256;

  factory DartLockBinding.fromJson(Object? value) {
    if (value is! Map ||
        value.length != 2 ||
        value['path'] is! String ||
        value['sha256'] is! String) {
      throw const FormatException('invalid native lockfile binding');
    }
    return DartLockBinding(
      path: value['path'] as String,
      sha256: value['sha256'] as String,
    );
  }

  Map<String, Object?> toJson() => {'path': path, 'sha256': sha256};
}

/// Pub's ordinary get preferences, not an RK solver or --enforce-lockfile.
/// The original bytes also authorize hashes for unchanged external coordinates.
final class DartDependencyLock {
  DartDependencyLock._(this.binding, this.contents, this.document);

  factory DartDependencyLock.parse(String contents, {required String path}) {
    final original = contents.trim().isEmpty
        ? const <String, Object?>{}
        : readDartYamlDocument(contents);
    final document = Map<String, Object?>.unmodifiable({
      ...original,
      'packages': original['packages'] ?? const <String, Object?>{},
    });
    if (document['packages'] is! Map ||
        (document['sdks'] != null && document['sdks'] is! Map)) {
      throw const FormatException('invalid native Pub lockfile');
    }
    for (final entry in (document['packages'] as Map).entries) {
      final value = entry.value;
      if (value is! Map ||
          value['version'] is! String ||
          value['source'] is! String ||
          (value['dependency'] != null && value['dependency'] is! String)) {
        throw const FormatException('invalid native locked package');
      }
      if (value['source'] == 'hosted') {
        final description = value['description'];
        if (description is String && description == entry.key) continue;
        if (description is! Map ||
            description['name'] != entry.key ||
            description['url'] is! String ||
            (description['sha256'] != null &&
                (description['sha256'] is! String ||
                    !RegExp(
                      r'^[0-9a-fA-F]{64}$',
                    ).hasMatch(description['sha256'] as String)))) {
          throw const FormatException('invalid native locked hosted package');
        }
        dartHostedRegistry(description['url'] as String);
      }
    }
    return DartDependencyLock._(
      DartLockBinding(path: path, sha256: Sha256.hex(utf8.encode(contents))),
      contents,
      document,
    );
  }

  final DartLockBinding binding;
  final String contents;
  final Map<String, Object?> document;

  /// Native metadata-only discovery needs shadow locations and placeholder
  /// archive integrity. Never mutate the original document or seed a refinement
  /// from the previous pass: its transient choices are not committed preferences.
  Future<String> forDiscovery(
    Future<String> Function(String registry) shadow, {
    required String defaultRegistry,
  }) async {
    final packages = <String, Object?>{};
    for (final entry in (document['packages'] as Map).entries) {
      final value = (entry.value as Map).cast<String, Object?>();
      if (value['source'] == 'hosted') {
        final description = value['description'] is String
            ? <String, Object?>{'name': entry.key, 'url': defaultRegistry}
            : (value['description'] as Map).cast<String, Object?>();
        packages[entry.key as String] = {
          ...value,
          'description': {
            for (final field in description.entries)
              if (field.key != 'sha256' && field.key != 'url')
                field.key: field.value,
            'url': await shadow(
              dartHostedRegistry(description['url'] as String),
            ),
          },
        };
      } else {
        packages[entry.key as String] = value;
      }
    }
    return jsonEncode({...document, 'packages': packages});
  }

  /// A changed coordinate is a native lock update. At an unchanged external
  /// coordinate, synthetic discovery integrity cannot excuse changed real bytes.
  void requireExternalIntegrity({
    required String name,
    required String registry,
    required String version,
    required String sha256,
  }) {
    final locked = (document['packages'] as Map)[name];
    if (locked is! Map ||
        locked['source'] != 'hosted' ||
        locked['version'] != version) {
      return;
    }
    final description = locked['description'];
    if (description is! Map) return;
    if (dartRegistryIdentity(description['url'] as String) !=
        dartRegistryIdentity(registry)) {
      return;
    }
    final digest = description['sha256'];
    if (digest != null &&
        (digest as String).toLowerCase() != sha256.toLowerCase()) {
      throw StateError(
        'registry archive for $name $version differs from the committed lockfile',
      );
    }
  }
}
