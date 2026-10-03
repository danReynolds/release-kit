import '../../engine/assets.dart';
import '../../engine/canonical_json.dart';
import '../../engine/config.dart';
import '../../engine/diagnostic.dart';
import '../../engine/git.dart';
import '../../engine/publish_target.dart';
import '../../engine/resolve.dart';
import '../../engine/source_tree.dart';
import '../../engine/stage_dependencies.dart';
import '../../engine/stage_receipt.dart';
import '../../engine/tools.dart';
import '../../transforms/digest.dart';
import 'dependencies.dart';
import 'hosted_discovery.dart';
import 'resolution_graph.dart';
import 'stage_context.dart';
import 'stage_inputs.dart';

/// Current source authority for the Dart part of a release. Availability and
/// command scope never enter these facts: a saved hosted choice stays hosted.
/// Core separately authorizes provider proofs, canonical receipt semantics and
/// actual recorded artifact bytes before transactional adoption.
final class DartStageAuthorization {
  factory DartStageAuthorization({
    required Resolution resolution,
    required SourceTree source,
    required GitState git,
    required Tools tools,
    required String compiler,
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
    return DartStageAuthorization._(
      current,
      selected,
      tools,
      compiler,
      defaultRegistry,
    );
  }

  DartStageAuthorization._(
    this.resolution,
    this.source,
    this.tools,
    this.compiler,
    this._defaultRegistry,
  );

  final Resolution resolution;
  final SourceTree source;
  final Tools tools;
  final String compiler;
  final String Function() _defaultRegistry;

  String get defaultRegistry => dartHostedRegistry(_defaultRegistry());

  /// Suitable for StageIntent's live reader. Helper membership is established
  /// natively during authorization; here its source manifests/configuration are
  /// bound without a solve or workspace command. Git already binds all source
  /// bytes, and unbound snapshots retain only single-invocation authority.
  Map<String, Object?> readIntent(ResolvedUnit unit) {
    final registry = defaultRegistry;
    final operations = _operations(unit);
    return {
      'format': 1,
      'default_registry': registry,
      'operations': {
        for (final entry in operations.entries)
          entry.key: {
            'root': entry.value.inputs.root.fields,
            'lockfile': entry.value.inputs.lock?.binding.toJson(),
            'lock_path': entry.value.inputs.lockPath,
            'consumers': entry.value.consumers,
          },
      },
      'configured_candidates': {
        for (final candidate in _candidates(registry))
          candidate.manifest.name: {
            'provider': candidate.provider.toJson(),
            'manifest': candidate.manifest.fields,
          },
      },
      'workspace_manifests': {
        if (operations.values.any(
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

  /// Reauthorizes original envelopes without upgrading their format or solving
  /// new choices. The returned discovery objects carry transient fetch handles;
  /// callers retain the original serialized contexts and dependency declarations.
  Future<Map<String, DartDiscoveryResult>> authorize(
    ResolvedUnit unit,
    StageReceipt receipt,
  ) async {
    final plan = receipt.plan;
    if (plan == null) {
      throw StateError('native authorization requires a frozen plan');
    }
    final dependencies = plan['dependency_inputs'] == null
        ? StageDependencies()
        : StageDependencies.fromJson(plan['dependency_inputs']);
    final before = CanonicalJson.encode(readIntent(unit));
    final registry = defaultRegistry;
    final operations = _operations(unit);
    final contexts = {
      for (final envelope in dependencies.contexts.where(
        (c) => c.ecosystem == 'dart',
      ))
        envelope.context: DartStageContext.fromEnvelope(envelope),
    };
    if (contexts.length != operations.length ||
        !operations.keys.toSet().containsAll(contexts.keys)) {
      throw StateError(
        'frozen Dart contexts omit or add a configured operation',
      );
    }
    final candidates = _candidates(registry);
    // Validate all source/operation/archive declarations before a native command
    // or registry request. One missing binary context cannot silently fall back.
    for (final entry in contexts.entries) {
      final context = entry.value;
      final operation = operations[entry.key]!;
      operation.inputs.requireMatches(context.root, context.lock);
      if (context.defaultRegistry != registry ||
          CanonicalJson.encode(context.envelope.consumers) !=
              CanonicalJson.encode(operation.consumers)) {
        throw StateError(
          'frozen Dart registry or consumers differ from current inputs',
        );
      }
      for (final binding in context.envelope.bindings) {
        final selected = context.discovery.packages[binding.slot]!;
        if (binding.provider case final provider?) {
          final matches = candidates.where(
            (candidate) =>
                CanonicalJson.encode(candidate.provider.toJson()) ==
                CanonicalJson.encode(provider.toJson()),
          );
          if (matches.length != 1) {
            throw StateError(
              'frozen Dart provider is not a current configured candidate',
            );
          }
          matches.single.manifest.requireSameManifest(selected.manifest);
          final project = resolution.allProjects.singleWhere(
            (p) => p.name == provider.project,
          );
          final path = ReleaseAssets.pubArchivePath(project);
          if (provider.unit == unit.name) {
            final local = dependencies.local
                .where(
                  (input) =>
                      input.use.context == entry.key &&
                      input.use.slot == binding.slot,
                )
                .singleOrNull;
            if (local == null ||
                local.path != path ||
                local.type != 'pub-archive') {
              throw StateError(
                'frozen Dart local input differs from its archive producer',
              );
            }
          } else {
            final imported = dependencies.imports
                .where(
                  (input) =>
                      input.use.context == entry.key &&
                      input.use.slot == binding.slot,
                )
                .singleOrNull;
            if (imported == null ||
                imported.original.path != path ||
                imported.original.type != 'pub-archive') {
              throw StateError(
                'frozen Dart import differs from its archive producer',
              );
            }
          }
        } else {
          final external = dependencies.external
              .where(
                (input) =>
                    input.context == entry.key &&
                    input.binding.slot == binding.slot,
              )
              .singleOrNull;
          if (external == null ||
              external.archive.sha256 != selected.archiveSha256) {
            throw StateError(
              'frozen Dart external archive differs from native selection',
            );
          }
        }
      }
    }
    _requireProducerEvidence(unit.name, receipt, dependencies, contexts.values);
    final authorized = <String, DartDiscoveryResult>{};
    for (final entry in contexts.entries) {
      final context = entry.value;
      final inputs = operations[entry.key]!.inputs;
      final helpers = await inputs.authorizeDevelopmentSources(
        context.developmentSources,
        tools: tools,
        compiler: compiler,
        defaultRegistry: registry,
      );
      final verified =
          await DartHostedDiscovery(
            tools: tools,
            compiler: compiler,
            defaultRegistry: registry,
          ).verifyFrozen(
            root: inputs.root,
            frozen: context.discovery,
            candidates: candidates.where(
              (candidate) => candidate.manifest.name != context.root.name,
            ),
            developmentSources: helpers,
            lock: inputs.lock,
          );
      if (CanonicalJson.encode(verified.toJson()) !=
          CanonicalJson.encode(context.discovery.toJson())) {
        throw StateError('native authorization changed frozen Dart selections');
      }
      authorized[entry.key] = verified;
    }
    if (CanonicalJson.encode(readIntent(unit)) != before) {
      throw StateError(
        'native source intent changed during Dart authorization',
      );
    }
    return Map.unmodifiable(authorized);
  }

  void _requireProducerEvidence(
    String unit,
    StageReceipt receipt,
    StageDependencies dependencies,
    Iterable<DartStageContext> contexts,
  ) {
    final steps = {for (final step in receipt.steps) step.name: step};
    for (final context in contexts) {
      for (final name in context.envelope.consumers) {
        final step = steps[name];
        if (step == null) {
          if (receipt.complete) {
            throw StateError('completed stage omits a native producer');
          }
          continue; // An authorized declaration does not claim future output.
        }
        final graph = DartResolutionGraph.fromJson(
          step.evidence['native_resolution'],
        );
        graph.requireSameSelection(
          context.discovery.graph,
          verifiedDevelopmentSources: {
            for (final helper in context.developmentSources)
              helper.manifest.name: dartRegistryIdentity(helper.registry),
          },
        );
        final hashes = <String, String>{};
        for (final binding in context.envelope.bindings) {
          final provider = binding.provider;
          if (provider == null) {
            hashes[binding.slot] = dependencies.external
                .singleWhere(
                  (input) =>
                      input.context == context.envelope.context &&
                      input.binding.slot == binding.slot,
                )
                .archive
                .sha256;
          } else if (provider.unit != unit) {
            hashes[binding.slot] = dependencies.imports
                .singleWhere(
                  (input) =>
                      input.use.context == context.envelope.context &&
                      input.use.slot == binding.slot,
                )
                .archive
                .sha256;
          } else {
            final local = dependencies.local.singleWhere(
              (input) =>
                  input.use.context == context.envelope.context &&
                  input.use.slot == binding.slot,
            );
            final output = steps[provider.producer]?.outputs
                .where(
                  (artifact) =>
                      artifact.path == local.path &&
                      artifact.type == local.type,
                )
                .singleOrNull;
            if (output == null) {
              throw StateError(
                'native producer evidence lacks its local provider output',
              );
            }
            hashes[binding.slot] = output.sha256;
          }
        }
        graph.requireArchives(hashes);
      }
    }
  }

  Map<String, _Operation> _operations(ResolvedUnit unit) {
    final current = resolution.unit(unit.name);
    if (current == null ||
        CanonicalJson.encode(_nativeUnit(current)) !=
            CanonicalJson.encode(_nativeUnit(unit))) {
      throw StateError(
        'native operation unit differs from current configuration',
      );
    }
    return {
      for (final project in current.projects)
        if (_isDart(project))
          for (final operation in [
            if (project.publish.contains(PublishTarget.pubDev))
              DartStageOperation.pubArchive,
            if (project.binaryPlatforms.isNotEmpty) DartStageOperation.binary,
          ])
            'dart:${operation.name}:${project.name}': _Operation(
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
    };
  }

  List<DartDiscoveryCandidate> _candidates(String registry) => [
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
  ];
}

bool _isDart(ResolvedProject project) =>
    project.pubspec.path == 'pubspec.yaml' ||
    project.pubspec.path.endsWith('/pubspec.yaml');

final class _Operation {
  const _Operation(this.inputs, this.consumers);
  final DartStageInputs inputs;
  final List<String> consumers;
}

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
