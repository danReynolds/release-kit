import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import '../../engine/canonical_json.dart';
import '../../transforms/digest.dart';
import 'dependencies.dart';

/// Native Pub's selected graph. Dart's single-version-by-name rule stays here,
/// outside the shared requirements and artifact-input machinery.
final class DartResolutionGraph {
  DartResolutionGraph._(this.roots, this.packages);

  final Set<String> roots;
  final Map<String, DartResolvedPackage> packages;

  /// Structural restore of portable native evidence. Source authorization and
  /// artifact verification remain the caller's responsibility; a serialized
  /// graph alone never grants access to a reusable stage.
  factory DartResolutionGraph.fromJson(Object? value) {
    final map = _fields(value, {'roots', 'packages'});
    final roots = _names(map['roots'], 'roots');
    final values = map['packages'];
    if (roots.isEmpty || values is! Map) {
      throw const FormatException('invalid frozen native graph');
    }
    final packages = <String, DartResolvedPackage>{};
    for (final entry in values.entries) {
      final name = _text(entry.key, 'package name');
      final node = _fields(
        entry.value,
        {'name', 'version', 'source', 'dependencies', 'devDependencies'},
        optional: {'archive_sha256'},
      );
      final source = _text(node['source'], '$name source');
      final hash = node['archive_sha256'];
      final development = _names(node['devDependencies'], '$name development');
      if (node['name'] != name ||
          (source == 'root') != roots.contains(name) ||
          (source != 'root' &&
              !RegExp(
                r'^(hosted|sdk|git|path):[0-9a-f]{64}$',
              ).hasMatch(source)) ||
          (!roots.contains(name) && development.isNotEmpty) ||
          (node.containsKey('archive_sha256') &&
              (!source.startsWith('hosted:') ||
                  hash is! String ||
                  !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)))) {
        throw FormatException('invalid frozen native identity for $name');
      }
      packages[name] = DartResolvedPackage._(
        name: name,
        version: _text(node['version'], '$name version'),
        source: source,
        archiveSha256: hash as String?,
        dependencies: _names(node['dependencies'], '$name dependencies'),
        development: development,
      );
    }
    if (!packages.keys.toSet().containsAll(roots)) {
      throw const FormatException('frozen native graph omits its roots');
    }
    final reached = <String>{};
    final pending = roots.toList();
    while (pending.isNotEmpty) {
      final name = pending.removeLast();
      if (!reached.add(name)) continue;
      final node = packages[name];
      if (node == null) {
        throw FormatException('frozen native graph omits $name');
      }
      pending.addAll([...node.dependencies, ...node.development]);
    }
    if (reached.length != packages.length) {
      throw const FormatException(
        'frozen native graph has unreachable packages',
      );
    }
    return DartResolutionGraph._(
      Set.unmodifiable(roots),
      Map.unmodifiable(packages),
    );
  }

  factory DartResolutionGraph.read(
    Directory root, {
    Map<String, String> registryAliases = const {},
  }) => DartResolutionGraph.parse(
    File('${root.path}/.dart_tool/package_graph.json').readAsStringSync(),
    File('${root.path}/pubspec.lock').readAsStringSync(),
    registryAliases: registryAliases,
  );

  factory DartResolutionGraph.parse(
    String graphJson,
    String lockYaml, {
    Map<String, String> registryAliases = const {},
  }) {
    final graph = jsonDecode(graphJson);
    final lock = loadYaml(lockYaml);
    if (graph is! Map ||
        graph['configVersion'] != 1 ||
        graph['packages'] is! List ||
        lock is! Map ||
        lock['packages'] is! Map) {
      throw const FormatException('unsupported native Pub graph or lockfile');
    }
    final roots = _names(graph['roots'], 'roots');
    final locked = lock['packages'] as Map;
    final packages = <String, DartResolvedPackage>{};
    for (final value in graph['packages'] as List) {
      if (value is! Map) {
        throw const FormatException('invalid native Pub package');
      }
      final name = _text(value['name'], 'package name');
      if (packages.containsKey(name)) {
        throw FormatException('duplicate native Pub package $name');
      }
      final version = _text(value['version'], '$name version');
      final dependencies = _names(value['dependencies'], '$name dependencies');
      final development = _names(
        value['devDependencies'] ?? [],
        '$name development dependencies',
      );
      final entry = locked[name];
      String source;
      String? digest;
      if (roots.contains(name)) {
        if (entry != null) {
          throw FormatException('native root $name also appears in lockfile');
        }
        source = 'root';
      } else {
        if (development.isNotEmpty) {
          throw FormatException(
            'non-root native package $name declares root development edges',
          );
        }
        if (entry is! Map || entry['version'] != version) {
          throw FormatException('native graph and lockfile disagree for $name');
        }
        final kind = _text(entry['source'], '$name source');
        final description = entry['description'];
        if (kind == 'hosted') {
          if (description is! Map || description['name'] != name) {
            throw FormatException('invalid hosted identity for $name');
          }
          final registry = _text(description['url'], '$name registry');
          source = dartRegistryIdentity(registryAliases[registry] ?? registry);
          digest = _text(description['sha256'], '$name archive hash');
          if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
            throw FormatException('invalid native archive hash for $name');
          }
        } else {
          if (!const {'sdk', 'git', 'path'}.contains(kind)) {
            throw FormatException('unsupported native source $kind for $name');
          }
          // Keep native SDK/path/git identity distinct. Development snapshots
          // need an explicit adapter binding; they never become hosted proof.
          source =
              '$kind:${Sha256.hex(utf8.encode(CanonicalJson.encode(_plain(description))))}';
        }
      }
      packages[name] = DartResolvedPackage._(
        name: name,
        version: version,
        source: source,
        archiveSha256: digest,
        dependencies: dependencies,
        development: development,
      );
    }
    if (!packages.keys.toSet().containsAll(roots) ||
        !packages.keys.toSet().containsAll(locked.keys.cast<String>())) {
      throw const FormatException(
        'native graph omits a root or locked package',
      );
    }
    for (final package in packages.values) {
      for (final dependency in [
        ...package.dependencies,
        ...package.development,
      ]) {
        if (!packages.containsKey(dependency)) {
          throw FormatException(
            'native graph omits $dependency required by ${package.name}',
          );
        }
      }
    }
    return DartResolutionGraph._(
      Set.unmodifiable(roots),
      Map.unmodifiable(packages),
    );
  }

  /// Discovery archive hashes describe metadata-only payloads. Compare native
  /// identities and full causal edges separately from real archive integrity.
  void requireSameSelection(DartResolutionGraph discovery) {
    if (CanonicalJson.encode(toJson(includeIntegrity: false)) !=
        CanonicalJson.encode(discovery.toJson(includeIntegrity: false))) {
      throw StateError(
        'native dependency graph changed between discovery and artifact replay',
      );
    }
  }

  void requireArchives(Map<String, String> expected) {
    for (final entry in expected.entries) {
      if (packages[entry.key]?.archiveSha256 != entry.value) {
        throw StateError(
          'native replay does not use the verified archive for ${entry.key}',
        );
      }
    }
  }

  /// Once replay has real bytes, later packaging/compilation must retain every
  /// selected archive hash as well as the native graph.
  void requireSameArtifacts(DartResolutionGraph frozen) {
    if (CanonicalJson.encode(toJson()) !=
        CanonicalJson.encode(frozen.toJson())) {
      throw StateError('native dependency artifacts changed after replay');
    }
  }

  Map<String, Object?> toJson({bool includeIntegrity = true}) => {
    'roots': roots.toList()..sort(),
    'packages': {
      for (final name in packages.keys.toList()..sort())
        name: packages[name]!.toJson(includeIntegrity: includeIntegrity),
    },
  };
}

final class DartResolvedPackage {
  DartResolvedPackage._({
    required this.name,
    required this.version,
    required this.source,
    required this.archiveSha256,
    required Set<String> dependencies,
    required Set<String> development,
  }) : dependencies = Set.unmodifiable(dependencies),
       development = Set.unmodifiable(development);

  final String name;
  final String version;
  final String source;
  final String? archiveSha256;
  final Set<String> dependencies;
  final Set<String> development;

  Map<String, Object?> toJson({bool includeIntegrity = true}) => {
    'name': name,
    'version': version,
    'source': source,
    'dependencies': dependencies.toList()..sort(),
    'devDependencies': development.toList()..sort(),
    if (includeIntegrity && archiveSha256 != null)
      'archive_sha256': archiveSha256,
  };
}

String _text(Object? value, String label) {
  if (value is! String || value.isEmpty) {
    throw FormatException('invalid $label in native Pub output');
  }
  return value;
}

Set<String> _names(Object? value, String label) {
  if (value is! List) {
    throw FormatException('invalid $label in native Pub output');
  }
  final names = value.map((name) => _text(name, label)).toSet();
  if (names.length != value.length) {
    throw FormatException('duplicate $label in native Pub output');
  }
  return names;
}

Object? _plain(Object? value) => switch (value) {
  Map() => {
    for (final entry in value.entries) '${entry.key}': _plain(entry.value),
  },
  List() => value.map(_plain).toList(),
  _ => value,
};

Map<String, Object?> _fields(
  Object? value,
  Set<String> required, {
  Set<String> optional = const {},
}) {
  if (value is! Map ||
      !value.keys.toSet().containsAll(required) ||
      !value.keys.every(
        (key) => required.contains(key) || optional.contains(key),
      )) {
    throw const FormatException('invalid frozen native graph fields');
  }
  return value.cast<String, Object?>();
}
