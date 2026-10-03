import 'native_dependencies.dart';
import 'native_stage_context.dart';
import 'resolve.dart';
import 'stage_dependencies.dart';

/// Native discovery injected into fresh repository preparation. Core chooses
/// eligible configured providers and schedules selected producers; adapters
/// own compatibility, transitive resolution and external archive verification.
abstract interface class NativeStageDiscovery {
  Set<String> get ecosystems;

  /// Every configured provider, without filtering by scope or availability.
  List<NativeCandidate> configuredCandidates();

  /// Unsolved, scope-independent inputs from the current authoritative source.
  Map<String, Object?> readIntent(ResolvedUnit unit);

  /// Resolve only among eligible configured providers and ordinary external
  /// sources. Offers must belong to this adapter's ecosystems. This neither
  /// binds a stage nor reads or produces a first-party archive.
  Future<DiscoveredNativeStage> discover(
    ResolvedUnit unit, {
    required Iterable<NativeCandidate> candidates,
  });
}

/// A selected first-party archive whose provider has not yet been scheduled.
/// It becomes local or imported only when core binds the prepared unit.
final class PendingStageDependency {
  PendingStageDependency({
    required this.use,
    required String path,
    required this.type,
  }) : path = LocalStageDependency(use: use, path: path, type: type).path;

  final NativeArtifactUse use;
  final String path;
  final String type;
}

/// Complete native choices for one unit, before provider artifacts are bound.
/// External inputs already hold their exact adapter-verified archive bytes.
final class DiscoveredNativeStage {
  factory DiscoveredNativeStage({
    Iterable<NativeStageContext> contexts = const [],
    Iterable<PendingStageDependency> pending = const [],
    Iterable<ExternalStageDependency> external = const [],
  }) {
    final requests = pending.toList();
    final checked = StageDependencies(
      contexts: contexts,
      local: requests.map(
        (request) => LocalStageDependency(
          use: request.use,
          path: request.path,
          type: request.type,
        ),
      ),
      external: external,
    );
    // StageDependencies retains support for old generic receipts without
    // native contexts. Fresh native discovery always supplies full coverage.
    if (checked.local.isNotEmpty && checked.contexts.isEmpty) {
      throw ArgumentError('discovered archives require native contexts');
    }
    return DiscoveredNativeStage._(
      checked.contexts,
      List.unmodifiable([
        for (final input in checked.local)
          PendingStageDependency(
            use: input.use,
            path: input.path,
            type: input.type,
          ),
      ]),
      checked.external,
    );
  }

  DiscoveredNativeStage._(this.contexts, this.pending, this.external);

  final List<NativeStageContext> contexts;
  final List<PendingStageDependency> pending;
  final List<ExternalStageDependency> external;
}
