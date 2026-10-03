import '../../engine/canonical_json.dart';
import '../../engine/native_dependencies.dart';
import '../../engine/native_stage_context.dart';
import 'dependencies.dart';
import 'dependency_lock.dart';
import 'hosted_discovery.dart';
import 'package_archive.dart';
import 'stage_inputs.dart';

export 'stage_inputs.dart' show DartStageOperation;

/// The Dart interpretation of a generic native stage context. The envelope
/// is portable evidence, not authorization to restore a previous stage. Core
/// checks slot coverage; this adapter checks root, operation and producers.
final class DartStageContext {
  DartStageContext._(
    this.envelope,
    this.root,
    this.defaultRegistry,
    this.operation,
    this.discovery,
    this.lock,
  );

  factory DartStageContext.discovered({
    required DartPackageManifest root,
    required String defaultRegistry,
    required DartStageOperation operation,
    required Iterable<String> consumers,
    required DartDiscoveryResult discovery,
    DartDependencyLock? lock,
  }) {
    final context = DartStageContext.fromEnvelope(
      NativeStageContext(
        context: 'dart:${operation.name}:${root.name}',
        ecosystem: 'dart',
        owner: root.name,
        format: 2,
        consumers: consumers,
        bindings: [
          for (final selected in discovery.packages.values)
            NativeStageBinding(
              slot: selected.manifest.name,
              package: NativePackage(
                ecosystem: 'dart',
                source: dartRegistryIdentity(selected.registry),
                name: selected.manifest.name,
              ),
              version: selected.manifest.version,
              provider: selected.candidate?.provider,
            ),
        ],
        native: {
          'root_manifest': root.fields,
          'default_registry': dartHostedRegistry(defaultRegistry),
          'operation': operation.name,
          'resolution': discovery.toJson(),
          'lockfile': lock?.binding.toJson(),
        },
      ),
    );
    // Keep live fetch handles only in this invocation. The envelope drops
    // signed URLs; restoring it must reacquire authorization separately.
    return DartStageContext._(
      context.envelope,
      context.root,
      context.defaultRegistry,
      context.operation,
      discovery,
      context.lock,
    );
  }

  factory DartStageContext.fromEnvelope(NativeStageContext envelope) {
    final payload = envelope.native;
    if (envelope.ecosystem != 'dart' ||
        envelope.format != 2 ||
        payload.length != 5 ||
        !payload.keys.toSet().containsAll({
          'root_manifest',
          'default_registry',
          'operation',
          'resolution',
          'lockfile',
        }) ||
        payload['root_manifest'] is! Map ||
        payload['default_registry'] is! String) {
      throw const FormatException('unsupported Dart stage context');
    }
    final root = DartPackageManifest.fromMap(
      (payload['root_manifest'] as Map).cast<String, Object?>(),
    );
    final registry = dartHostedRegistry(payload['default_registry'] as String);
    final operations = DartStageOperation.values.where(
      (value) => value.name == payload['operation'],
    );
    if (operations.length != 1) {
      throw const FormatException('unknown Dart stage operation');
    }
    final operation = operations.single;
    final lock = payload['lockfile'] == null
        ? null
        : DartLockBinding.fromJson(payload['lockfile']);
    if (operation == DartStageOperation.pubArchive && lock != null) {
      throw const FormatException(
        'Pub archive context cannot inherit a lockfile',
      );
    }
    final discovery = DartDiscoveryResult.fromJson(payload['resolution']);
    final graphRoot = discovery.graph.packages[root.name];
    if (envelope.owner != root.name ||
        envelope.context != 'dart:${operation.name}:${root.name}' ||
        discovery.graph.roots.length != 1 ||
        !discovery.graph.roots.contains(root.name) ||
        graphRoot?.version != root.version ||
        registry != payload['default_registry']) {
      throw const FormatException('Dart stage context disagrees with its root');
    }
    for (final producer in envelope.consumers) {
      final valid = switch (operation) {
        DartStageOperation.pubArchive => producer == 'pub-archive:${root.name}',
        DartStageOperation.binary =>
          producer.startsWith('build:${root.name}:') &&
              producer.split(':').length == 3 &&
              producer.split(':').last.isNotEmpty,
      };
      if (!valid) {
        throw const FormatException(
          'Dart stage context has an unrelated consumer',
        );
      }
    }
    final expected = <String, NativeStageBinding>{};
    for (final selected in discovery.packages.values) {
      final provider = selected.candidate?.provider;
      if (provider != null &&
          (provider.project != selected.manifest.name ||
              provider.producer != 'pub-archive:${provider.project}')) {
        throw const FormatException(
          'Dart package provider is not its native archive producer',
        );
      }
      expected[selected.manifest.name] = NativeStageBinding(
        slot: selected.manifest.name,
        package: NativePackage(
          ecosystem: 'dart',
          source: dartRegistryIdentity(selected.registry),
          name: selected.manifest.name,
        ),
        version: selected.manifest.version,
        provider: provider,
      );
    }
    if (expected.length != envelope.bindings.length ||
        envelope.bindings.any(
          (binding) =>
              CanonicalJson.encode(expected[binding.slot]?.toJson()) !=
              CanonicalJson.encode(binding.toJson()),
        )) {
      throw const FormatException(
        'Dart context bindings differ from native selection',
      );
    }
    return DartStageContext._(
      envelope,
      root,
      registry,
      operation,
      discovery,
      lock,
    );
  }

  final NativeStageContext envelope;
  final DartPackageManifest root;
  final String defaultRegistry;
  final DartStageOperation operation;
  final DartDiscoveryResult discovery;
  final DartLockBinding? lock;
}
