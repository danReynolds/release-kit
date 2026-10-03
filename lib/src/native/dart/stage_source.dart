import '../../engine/canonical_json.dart';
import '../../engine/config.dart';
import '../../engine/diagnostic.dart';
import '../../engine/git.dart';
import '../../engine/publish_target.dart';
import '../../engine/resolve.dart';
import '../../engine/source_tree.dart';
import '../../transforms/digest.dart';
import 'dependencies.dart';
import 'hosted_discovery.dart';
import 'stage_inputs.dart';

/// Original Dart inputs shared by fresh discovery and frozen authorization.
/// Availability and command scope never affect configured candidates or roots.
final class DartStageSource {
  factory DartStageSource({
    required Resolution resolution,
    required SourceTree source,
    required GitState git,
    required String Function() defaultRegistry,
  }) {
    final selected = DartStageInputs.authoritativeSource(source, git);
    final diagnostics = Diagnostics();
    final configText = selected.read('release.toml');
    final config = configText == null
        ? null
        : ReleaseConfig.parse(configText, 'release.toml', diagnostics);
    final current = config == null
        ? null
        : Resolution.resolve(config, selected, diagnostics);
    if (current == null || diagnostics.isNotEmpty) {
      throw StateError(
        'native authorization requires valid configuration from the selected source',
      );
    }
    if (CanonicalJson.encode(_nativeResolution(current)) !=
        CanonicalJson.encode(_nativeResolution(resolution))) {
      throw StateError('native configuration differs from the selected source');
    }
    return DartStageSource._(current, selected, defaultRegistry);
  }

  DartStageSource._(this.resolution, this.source, this._defaultRegistry);

  final Resolution resolution;
  final SourceTree source;
  final String Function() _defaultRegistry;

  String get defaultRegistry => dartHostedRegistry(_defaultRegistry());

  /// All configured Dart operations in the current source unit, including
  /// operations whose native dependency graph will be empty.
  Map<String, DartStageSourceOperation> operations(ResolvedUnit unit) {
    final current = resolution.unit(unit.name);
    if (current == null ||
        CanonicalJson.encode(_nativeUnit(current)) !=
            CanonicalJson.encode(_nativeUnit(unit))) {
      throw StateError(
        'native operation unit differs from current configuration',
      );
    }
    return Map.unmodifiable({
      for (final project in current.projects)
        if (_isDart(project))
          for (final operation in [
            if (project.publish.contains(PublishTarget.pubDev))
              DartStageOperation.pubArchive,
            if (project.binaryPlatforms.isNotEmpty) DartStageOperation.binary,
          ])
            'dart:${operation.name}:${project.name}':
                DartStageSourceOperation._(
                  project,
                  operation,
                  DartStageInputs.read(
                    source: source,
                    project: project,
                    operation: operation,
                  ),
                  (operation == DartStageOperation.pubArchive
                        ? ['pub-archive:${project.name}']
                        : [
                            for (final platform in project.binaryPlatforms)
                              'build:${project.name}:$platform',
                          ])
                    ..sort(),
                ),
    });
  }

  /// Configured archive providers across every unit. Supply the registry read
  /// at the start of a larger operation to preserve one live-registry snapshot.
  List<DartDiscoveryCandidate> candidates({String? defaultRegistry}) {
    final registry = defaultRegistry == null
        ? this.defaultRegistry
        : dartHostedRegistry(defaultRegistry);
    return List.unmodifiable([
      for (final project in resolution.allProjects)
        if (_isDart(project) && project.publish.contains(PublishTarget.pubDev))
          DartDiscoveryCandidate(
            provider: dartCandidate(project, defaultRegistry: registry),
            registry: project.pubspec.publishTo ?? registry,
            manifest: DartStageInputs.read(
              source: source,
              project: project,
              operation: DartStageOperation.pubArchive,
            ).root,
          ),
    ]);
  }

  /// Suitable for StageIntent's live reader. Helper membership is established
  /// natively during discovery or authorization; here source manifests and
  /// configuration are bound without a solve or workspace command. Git already
  /// binds all source bytes; unbound snapshots have single-invocation authority.
  Map<String, Object?> readIntent(ResolvedUnit unit) {
    final registry = defaultRegistry;
    final currentOperations = operations(unit);
    return {
      'format': 1,
      'default_registry': registry,
      'operations': {
        for (final entry in currentOperations.entries)
          entry.key: {
            'root': entry.value.inputs.root.fields,
            'lockfile': entry.value.inputs.lock?.binding.toJson(),
            'lock_path': entry.value.inputs.lockPath,
            'consumers': entry.value.consumers,
          },
      },
      'configured_candidates': {
        for (final candidate in candidates(defaultRegistry: registry))
          candidate.manifest.name: {
            'provider': candidate.provider.toJson(),
            'manifest': candidate.manifest.fields,
          },
      },
      'workspace_manifests': {
        if (currentOperations.values.any(
          (operation) =>
              operation.inputs.root.fields.containsKey('workspace') ||
              operation.inputs.root.fields.containsKey('resolution'),
        ))
          for (final path in [...source.trackedFiles()]..sort())
            if (path == 'pubspec.yaml' ||
                path.endsWith('/pubspec.yaml') ||
                path == 'pubspec_overrides.yaml' ||
                path.endsWith('/pubspec_overrides.yaml'))
              path: Sha256.hex(
                source.readBytes(path) ??
                    (throw StateError('native workspace source disappeared')),
              ),
      },
    };
  }
}

/// One original package root and the producers that consume its native graph.
final class DartStageSourceOperation {
  DartStageSourceOperation._(
    this.project,
    this.operation,
    this.inputs,
    List<String> consumers,
  ) : consumers = List.unmodifiable(consumers);

  final ResolvedProject project;
  final DartStageOperation operation;
  final DartStageInputs inputs;
  final List<String> consumers;
}

bool _isDart(ResolvedProject project) =>
    project.pubspec.path == 'pubspec.yaml' ||
    project.pubspec.path.endsWith('/pubspec.yaml');

// Only the facts this adapter uses to select roots, candidates and producers.
// Canonical release-plan/source/toolchain authorization remains core-owned.
Map<String, Object?> _nativeResolution(Resolution resolution) => {
  for (final unit in resolution.units) unit.name: _nativeUnit(unit),
};

Map<String, Object?> _nativeUnit(ResolvedUnit unit) => {
  'unit': unit.name,
  'projects': {
    for (final project in unit.projects)
      project.name: {
        'owner': project.unitName,
        'manifest': project.pubspec.path,
        'version': project.version.canonical,
        'publish_to': project.pubspec.publishTo,
        'pub_archive': project.publish.contains(PublishTarget.pubDev),
        'binary_platforms': [...project.binaryPlatforms]..sort(),
      },
  },
};
