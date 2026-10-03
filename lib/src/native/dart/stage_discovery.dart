import '../../engine/assets.dart';
import '../../engine/canonical_json.dart';
import '../../engine/native_dependencies.dart';
import '../../engine/native_stage_discovery.dart';
import '../../engine/resolve.dart';
import '../../engine/stage_dependencies.dart';
import '../../engine/tools.dart';
import 'hosted_archive.dart';
import 'hosted_discovery.dart';
import 'stage_context.dart';
import 'stage_source.dart';

/// Fresh native resolution over original source inputs and core-authorized
/// eligible providers. First-party archives remain pending producer requests.
final class DartStageDiscovery implements NativeStageDiscovery {
  DartStageDiscovery(
    this.source, {
    required this.tools,
    required this.compiler,
  });

  final DartStageSource source;
  final Tools tools;
  final String compiler;

  @override
  Set<String> get ecosystems => const {'dart'};

  @override
  List<NativeCandidate> configuredCandidates() => List.unmodifiable([
    for (final candidate in source.candidates()) candidate.provider,
  ]);

  @override
  Map<String, Object?> readIntent(ResolvedUnit unit) => source.readIntent(unit);

  @override
  Future<DiscoveredNativeStage> discover(
    ResolvedUnit unit, {
    required Iterable<NativeCandidate> candidates,
  }) async {
    final intent = readIntent(unit);
    final before = CanonicalJson.encode(intent);
    final registry = intent['default_registry']! as String;
    final operations = source.operations(unit);
    final configured = {
      for (final candidate in source.candidates(defaultRegistry: registry))
        CanonicalJson.encode(candidate.provider.toJson()): candidate,
    };
    final eligible = <DartDiscoveryCandidate>[];
    final offered = <String>{};
    for (final candidate in candidates) {
      final key = CanonicalJson.encode(candidate.toJson());
      final current = configured[key];
      if (candidate.package.ecosystem != 'dart' ||
          current == null ||
          !offered.add(key)) {
        throw StateError(
          'eligible Dart candidate is duplicated or differs from configured source',
        );
      }
      eligible.add(current);
    }
    void requireUnchanged() {
      if (CanonicalJson.encode(readIntent(unit)) != before) {
        throw StateError('native source intent changed during Dart discovery');
      }
    }

    final contexts = <DartStageContext>[];
    for (final operation in operations.values) {
      final inputs = operation.inputs;
      final discovery = await inputs.discover(
        discovery: DartHostedDiscovery(
          tools: tools,
          compiler: compiler,
          defaultRegistry: registry,
        ),
        candidates: eligible.where(
          (candidate) => candidate.manifest.name != inputs.root.name,
        ),
      );
      requireUnchanged();
      contexts.add(
        DartStageContext.discovered(
          root: inputs.root,
          lock: inputs.lock,
          defaultRegistry: registry,
          operation: operation.operation,
          consumers: operation.consumers,
          discovery: discovery,
        ),
      );
    }

    final pending = <PendingStageDependency>[];
    final external = <ExternalStageDependency>[];
    for (final context in contexts) {
      for (final binding in context.envelope.bindings) {
        if (binding.provider case final provider?) {
          final project = source.resolution.allProjects.singleWhere(
            (project) => project.name == provider.project,
          );
          pending.add(
            PendingStageDependency(
              use: NativeArtifactUse(
                context: context.envelope.context,
                slot: binding.slot,
                provider: provider,
                consumers: context.envelope.consumers,
              ),
              path: ReleaseAssets.pubArchivePath(project),
              type: 'pub-archive',
            ),
          );
        } else {
          final selected = context.discovery.packages[binding.slot]!;
          final archive = await DartHostedArchive.fetch(selected);
          requireUnchanged();
          external.add(
            ExternalStageDependency.fromBytes(
              context: context.envelope.context,
              binding: binding,
              consumers: context.envelope.consumers,
              bytes: archive.archive.bytes,
              expectedSha256: selected.archiveSha256!,
            ),
          );
        }
      }
    }
    requireUnchanged();
    return DiscoveredNativeStage(
      contexts: contexts.map((context) => context.envelope),
      pending: pending,
      external: external,
    );
  }
}
