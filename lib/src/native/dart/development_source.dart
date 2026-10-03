import '../../engine/canonical_json.dart';
import '../../engine/stage.dart';
import 'dependencies.dart';
import 'package_archive.dart';

/// A workspace package authorized by the consumer's source snapshot. This is
/// solver metadata and a source binding, never a package archive or producer.
final class DartDevelopmentSource {
  DartDevelopmentSource({
    required this.manifestPath,
    required String registry,
    required this.manifest,
  }) : registry = dartHostedRegistry(registry) {
    final parts = StagePath.segments(manifestPath);
    if (parts.last != 'pubspec.yaml') {
      throw const FormatException('development source must name its manifest');
    }
  }

  factory DartDevelopmentSource.fromJson(Object? value) {
    if (value is! Map ||
        value.length != 3 ||
        value['manifest_path'] is! String ||
        value['registry'] is! String ||
        value['manifest'] is! Map) {
      throw const FormatException('invalid development source binding');
    }
    return DartDevelopmentSource(
      manifestPath: value['manifest_path'] as String,
      registry: value['registry'] as String,
      manifest: DartPackageManifest.developmentSource(value['manifest']),
    );
  }

  final String manifestPath;
  final String registry;
  final DartPackageManifest manifest;

  Map<String, Object?> toJson() => {
    'manifest_path': manifestPath,
    'registry': registry,
    'manifest': manifest.fields,
  };

  void requireSameSource(DartDevelopmentSource recorded) {
    if (CanonicalJson.encode(toJson()) !=
        CanonicalJson.encode(recorded.toJson())) {
      throw StateError(
        'development source ${manifest.name} differs from the selected snapshot',
      );
    }
  }
}

/// Original runtime declarations remain authoritative when a serialized graph
/// omits an edge or a root also declares the name as a dev dependency.
Map<String, List<String>> dartRuntimeDependencyPaths(
  DartPackageManifest root,
  Iterable<DartPackageManifest> packages,
) {
  final manifests = {
    for (final package in packages) package.name: package,
    root.name: root,
  };
  final paths = <String, List<String>>{
    root.name: [root.name],
  };
  final pending = [root.name];
  while (pending.isNotEmpty) {
    final name = pending.removeLast();
    final dependencies = manifests[name]?.fields['dependencies'];
    if (dependencies is! Map) continue;
    for (final dependency in dependencies.keys.cast<String>()) {
      if (paths.containsKey(dependency)) continue;
      paths[dependency] = [...paths[name]!, dependency];
      pending.add(dependency);
    }
  }
  return paths;
}
