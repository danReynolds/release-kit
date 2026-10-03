import '../../engine/assets.dart';
import '../../engine/canonical_json.dart';
import '../../engine/git.dart';
import '../../engine/resolve.dart';
import '../../engine/source_tree.dart';
import '../../engine/stage_dependencies.dart';
import '../../engine/stage_receipt.dart';
import '../../engine/tools.dart';
import 'dependencies.dart';
import 'hosted_discovery.dart';
import 'resolution_graph.dart';
import 'stage_context.dart';
import 'stage_source.dart';

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
  }) => DartStageAuthorization._(
    DartStageSource(
      resolution: resolution,
      source: source,
      git: git,
      defaultRegistry: defaultRegistry,
    ),
    tools,
    compiler,
  );

  DartStageAuthorization._(this._stageSource, this.tools, this.compiler);

  final DartStageSource _stageSource;
  final Tools tools;
  final String compiler;

  Resolution get resolution => _stageSource.resolution;
  SourceTree get source => _stageSource.source;
  String get defaultRegistry => _stageSource.defaultRegistry;

  Map<String, Object?> readIntent(ResolvedUnit unit) =>
      _stageSource.readIntent(unit);

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
    final operations = _stageSource.operations(unit);
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
    final candidates = _stageSource.candidates(defaultRegistry: registry);
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
}
