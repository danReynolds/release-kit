import 'dart:collection';
import 'dart:convert';

import 'package:yaml/yaml.dart';

import '../../engine/canonical_json.dart';
import '../../transforms/digest.dart';
import '../package_archive.dart';

/// Archive manifests are compared with the original discovery metadata before
/// any native cache preload. Comments/formatting may differ; no semantic field
/// may change, including SDK requirements and previously hidden dependencies.
final class DartPackageManifest {
  DartPackageManifest._(this.fields);

  factory DartPackageManifest.parse(String yaml) {
    return DartPackageManifest.fromMap(readDartYamlDocument(yaml));
  }

  factory DartPackageManifest.fromMap(Object? manifest) {
    final value = _plain(manifest, HashSet.identity(), _ManifestBudget(), 0);
    if (value is! Map<String, Object?> ||
        value['name'] is! String ||
        value['version'] is! String) {
      throw const FormatException(
        'native Pub archive has no package name/version',
      );
    }
    return DartPackageManifest._(value);
  }

  factory DartPackageManifest.fromArchive(NativePackageArchive archive) {
    final manifest = archive.files['pubspec.yaml'];
    if (manifest == null) {
      throw const FormatException('native Pub archive has no pubspec.yaml');
    }
    return DartPackageManifest.parse(utf8.decode(manifest.bytes));
  }

  final Map<String, Object?> fields;
  String get name => fields['name']! as String;
  String get version => fields['version']! as String;
  String get sha256 => Sha256.hex(utf8.encode(CanonicalJson.encode(fields)));

  void requireSameManifest(DartPackageManifest discovered) {
    if (sha256 != discovered.sha256) {
      throw FormatException(
        'native archive manifest for $name $version differs from discovery metadata for ${discovered.name} ${discovered.version}',
      );
    }
  }
}

/// Bounded YAML documents from the selected source, including workspace
/// manifests without a package version and native lockfiles. Expansion shares
/// the same alias/depth limits as archive manifests.
Map<String, Object?> readDartYamlDocument(String yaml) {
  if (utf8.encode(yaml).length > 1024 * 1024) {
    throw const FormatException('native Pub document is too large');
  }
  final loaded = loadYaml(yaml);
  final value = _plain(loaded, HashSet.identity(), _ManifestBudget(), 0);
  if (value is! Map<String, Object?>) {
    throw const FormatException('native Pub document must be a map');
  }
  return value;
}

final class _ManifestBudget {
  int remaining = 1024 * 1024;
  int nodes = 100000;
  void use(Object? value, int depth) {
    remaining -= value is String ? utf8.encode(value).length + 2 : 8;
    if (--nodes < 0 || remaining < 0 || depth > 128) {
      throw const FormatException(
        'native Pub manifest expansion exceeds its size or depth limit',
      );
    }
  }
}

Object? _plain(
  Object? value,
  Set<Object> visiting,
  _ManifestBudget budget,
  int depth,
) {
  budget.use(value, depth);
  if (value is Map || value is List) {
    if (!visiting.add(value!)) {
      throw const FormatException(
        'native Pub manifest contains a recursive alias',
      );
    }
  }
  try {
    if (value is Map) {
      if (value.keys.any((key) => key is! String)) {
        throw const FormatException(
          'native Pub manifest contains a non-string key',
        );
      }
      return Map<String, Object?>.unmodifiable({
        for (final entry in value.entries)
          _plain(entry.key, visiting, budget, depth + 1) as String: _plain(
            entry.value,
            visiting,
            budget,
            depth + 1,
          ),
      });
    }
    if (value is List) {
      return List<Object?>.unmodifiable(
        value.map((item) => _plain(item, visiting, budget, depth + 1)),
      );
    }
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    throw const FormatException('native Pub manifest has an unsupported value');
  } finally {
    if (value is Map || value is List) visiting.remove(value);
  }
}
