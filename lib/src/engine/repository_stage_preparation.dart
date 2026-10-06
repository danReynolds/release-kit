import 'canonical_json.dart';
import 'dependency_graph.dart';
import 'git.dart';
import 'native_dependencies.dart';
import 'native_stage_discovery.dart';
import 'producers.dart';
import 'release_stage.dart';
import 'resolve.dart';
import 'resolution_facts.dart';
import 'stage_dependencies.dart';
import 'stage_intent.dart';

/// A completed provider already authorized against current source and native
/// metadata by restoration. Pin its receipt as well as its stage identity:
/// selection cannot later switch bytes, silently fall back, or finish a sibling.
final class PreparedStageProvider {
  PreparedStageProvider.capture(this.stage)
    : receipt = stage.requireReceipt().encode() {
    if (stage.intent == null) {
      throw StateError('a reusable provider needs an authorized native intent');
    }
  }

  final ReleaseStage stage;
  final String receipt;

  void requireCurrent(ReleaseStages stages, GitState git) {
    if (!identical(stages(stage.unit), stage) ||
        stages.refresh(stage.unit, git).directory.identity.id !=
            stage.directory.identity.id ||
        stage.requireReceipt().encode() != receipt) {
      throw StateError('selected provider changed after eligibility');
    }
  }
}

/// Command-owned eligibility after restoration and public inventory. Native
/// code receives only these candidates; public exactness and command scope are
/// never inferred from package names by the scheduler.
final class RepositoryStageCandidates {
  RepositoryStageCandidates({
    required Iterable<NativeCandidate> candidates,
    Iterable<PreparedStageProvider> providers = const [],
    Iterable<String> withoutPreparation = const [],
  }) : candidates = List.unmodifiable(candidates),
       providers = List.unmodifiable(providers),
       withoutPreparation = Set.unmodifiable(withoutPreparation);

  final List<NativeCandidate> candidates;
  final List<PreparedStageProvider> providers;

  /// Selected units whose remaining destinations can recover entirely from
  /// authenticated public inputs. They receive no discovery or producer work
  /// and cannot be offered as private providers. The command must recheck that
  /// recovery binding before consent and the eventual public operation.
  final Set<String> withoutPreparation;
}

/// Watches [RepositoryStagePreparation.resolve] without taking part in it, so
/// a command can show which unit's stage is being read. Restoration verifies
/// every staged file and discovery resolves dependencies; either can take
/// long enough that saying nothing looks like a hang.
abstract interface class RepositoryPreparationObserver {
  /// [unit]'s saved stage is about to be found and verified.
  void restoring(ResolvedUnit unit);

  /// [unit]'s restoration ended: [found] is whether a stage was adopted.
  void restored(ResolvedUnit unit, {required bool found});

  /// [unit] has no stage, and its dependencies are about to be resolved.
  void discovering(ResolvedUnit unit);
}

/// Resolves one repository preparation scope without running its producers.
/// The caller holds the stage-store mutation lock and supplies restoration that
/// returns null only for conclusive absence, throwing on all rejected state.
/// The command then executes [RepositoryPreparationPlan.order] through the
/// existing per-unit coordinator, calling bind immediately before each unit.
final class RepositoryStagePreparation {
  RepositoryStagePreparation({
    required this.resolution,
    required this.stages,
    required this.native,
    required this.restore,
    required this.refreshGit,
  });

  final Resolution resolution;
  final ReleaseStages stages;
  final NativeStageDiscovery native;
  final Future<ReleaseStage?> Function(ResolvedUnit unit) restore;
  final Future<GitState> Function() refreshGit;

  Future<RepositoryPreparationPlan> resolve({
    required Iterable<ResolvedUnit> selected,
    required Future<RepositoryStageCandidates> Function(
      Map<String, ReleaseStage> restored,
    )
    eligibility,
    RepositoryPreparationObserver? observer,
  }) async {
    final resolvedFacts = resolutionFacts(resolution);
    final units = selected.toList();
    final names = <String>{};
    for (final unit in units) {
      if (!identical(resolution.unit(unit.name), unit) ||
          !names.add(unit.name)) {
        throw ArgumentError('preparation requires unique configured units');
      }
    }
    final restored = <String, ReleaseStage>{};
    for (final unit in units) {
      observer?.restoring(unit);
      final stage = await restore(unit);
      observer?.restored(unit, found: stage != null);
      if (stage != null) {
        if (!identical(stages(unit), stage) || stage.intent == null) {
          throw StateError('restoration did not install the shared binding');
        }
        restored[unit.name] = stage;
      }
    }
    final expected = {for (final unit in units) unit.name: stages(unit)};
    final current = await refreshGit();
    final intents = {
      for (final unit in units)
        unit.name: stages.intentFor(
          unit,
          currentGit: current,
          readInputs: () => native.readIntent(unit),
        ),
    };
    final scope = await eligibility(Map.unmodifiable(restored));
    if (!names.containsAll(scope.withoutPreparation)) {
      throw StateError(
        'public recovery names a unit outside preparation scope',
      );
    }
    final providers = <String, PreparedStageProvider>{};
    for (final provider in scope.providers) {
      final name = provider.stage.unit.name;
      if (!identical(resolution.unit(name), provider.stage.unit) ||
          providers.containsKey(name)) {
        throw StateError('duplicate or unknown eligible provider unit');
      }
      providers[name] = provider;
    }
    for (final stage in restored.values) {
      if (stage.inspect().reusable) {
        providers.putIfAbsent(
          stage.unit.name,
          () => PreparedStageProvider.capture(stage),
        );
      }
    }
    final configured = {
      for (final candidate in native.configuredCandidates())
        CanonicalJson.encode(candidate.toJson()),
    };
    final eligible = <String>{};
    for (final candidate in scope.candidates) {
      final key = CanonicalJson.encode(candidate.toJson());
      if (scope.withoutPreparation.contains(candidate.unit) ||
          !native.ecosystems.contains(candidate.package.ecosystem) ||
          !configured.contains(key) ||
          !eligible.add(key)) {
        throw StateError(
          'eligible provider differs from current configuration',
        );
      }
      if (!names.contains(candidate.unit) &&
          !providers.containsKey(candidate.unit)) {
        throw StateError(
          'out-of-scope provider is not complete and authorized',
        );
      }
    }
    final pending = <String, DiscoveredNativeStage>{};
    for (final unit in units) {
      if (restored.containsKey(unit.name) ||
          scope.withoutPreparation.contains(unit.name)) {
        continue;
      }
      observer?.discovering(unit);
      pending[unit.name] = await native.discover(
        unit,
        candidates: scope.candidates,
      );
      if (pending[unit.name]!.contexts.any(
        (context) => !native.ecosystems.contains(context.ecosystem),
      )) {
        throw StateError('native discovery returned an unauthorized ecosystem');
      }
    }
    final plan = RepositoryPreparationPlan._(
      stages: stages,
      resolution: resolution,
      resolvedFacts: resolvedFacts,
      units: units,
      expected: expected,
      restored: restored,
      withoutPreparation: scope.withoutPreparation,
      intents: intents,
      pending: pending,
      providers: providers,
      eligible: eligible,
      refreshGit: refreshGit,
    );
    // Discovery and eligibility have awaited external work. Before returning an
    // executable order, validate the entire scope against current inputs again.
    plan._requireCurrent(await refreshGit());
    return plan;
  }
}

final class RepositoryPreparationPlan {
  RepositoryPreparationPlan._({
    required this.stages,
    required this.resolution,
    required this.resolvedFacts,
    required List<ResolvedUnit> units,
    required Map<String, ReleaseStage> expected,
    required Map<String, ReleaseStage> restored,
    required Set<String> withoutPreparation,
    required Map<String, StageIntent> intents,
    required Map<String, DiscoveredNativeStage> pending,
    required Map<String, PreparedStageProvider> providers,
    required Set<String> eligible,
    required this.refreshGit,
  }) : _expected = Map.of(expected),
       _restored = Map.unmodifiable(restored),
       withoutPreparation = Set.unmodifiable(withoutPreparation),
       _intents = Map.unmodifiable(intents),
       _pending = Map.unmodifiable(pending),
       _providers = Map.unmodifiable({
         for (final entry in providers.entries)
           if (expected.containsKey(entry.key) ||
               pending.values.any(
                 (discovery) => discovery.pending.any(
                   (request) => request.use.provider.unit == entry.key,
                 ),
               ))
             entry.key: entry.value,
       }) {
    final nodes = <String, Set<String>>{};
    final unitNeeds = {for (final unit in units) unit.name: <String>{}};
    String node(String unit, String producer) =>
        CanonicalJson.encode([unit, producer]);
    for (final unit in units) {
      final stage = expected[unit.name]!;
      for (final producer in stage.producerNames) {
        nodes[node(unit.name, producer)] = {
          for (final needed in stage.producerDependencies(producer))
            node(unit.name, needed),
        };
      }
    }
    for (final unit in units) {
      final discovery = pending[unit.name];
      if (discovery == null) continue;
      final stage = expected[unit.name]!;
      final consumers = {
        for (final contribution in stage.targetContributions)
          contribution.step.name,
        for (final contract in localProducerContracts(unit)) contract.name,
      };
      final owners = unit.projects.map((p) => p.name).toSet();
      for (final context in discovery.contexts) {
        if (!owners.contains(context.owner) ||
            !consumers.containsAll(context.consumers)) {
          throw StateError('native context names an unknown owner or producer');
        }
      }
      for (final request in discovery.pending) {
        final use = request.use;
        final provider = use.provider;
        if (!eligible.contains(CanonicalJson.encode(provider.toJson()))) {
          throw StateError('native discovery selected an ineligible provider');
        }
        final providerUnit = resolution.unit(provider.unit);
        if (providerUnit == null ||
            !providerUnit.projects.any((p) => p.name == provider.project)) {
          throw StateError(
            'native provider names an unknown configured project',
          );
        }
        final providerStage =
            providers[provider.unit]?.stage ?? expected[provider.unit];
        if (providerStage == null ||
            !providerStage.producerNames.contains(provider.producer) ||
            providerStage
                    .producerContract(provider.producer)
                    .outputs[request.path] !=
                request.type ||
            !consumers.containsAll(use.consumers)) {
          throw StateError('native request differs from its artifact contract');
        }
        if (providers.containsKey(provider.unit) &&
            provider.unit != unit.name) {
          // Already completed and pinned inputs impose no production wait.
          continue;
        }
        for (final consumer in use.consumers) {
          nodes[node(unit.name, consumer)]!.add(
            node(provider.unit, provider.producer),
          );
        }
        if (provider.unit != unit.name) {
          unitNeeds[unit.name]!.add(provider.unit);
        }
      }
    }
    // Diagnose the actual producer graph first. Acyclic producer work can still
    // require unit interleaving that the serial complete-unit executor cannot do.
    DependencyGraph<String>(
      nodes.keys,
      idOf: (id) => id,
      dependenciesOf: (id) => nodes[id]!,
    );
    try {
      order = DependencyGraph<ResolvedUnit>(
        units,
        idOf: (unit) => unit.name,
        dependenciesOf: (unit) => unitNeeds[unit.name]!,
      ).ordered();
    } on StateError catch (error) {
      throw StateError(
        'native preparation requires interleaved release units; '
        'regroup the packages into independent units: $error',
      );
    }
  }

  final ReleaseStages stages;
  final Resolution resolution;
  final String resolvedFacts;
  final Future<GitState> Function() refreshGit;
  late final List<ResolvedUnit> order;
  final Set<String> withoutPreparation;
  final Map<String, ReleaseStage> _expected;
  final Map<String, ReleaseStage> _restored;
  final Map<String, StageIntent> _intents;
  final Map<String, DiscoveredNativeStage> _pending;
  final Map<String, PreparedStageProvider> _providers;
  final Set<String> _bound = {};

  void _requireCurrent(GitState git) {
    if (resolutionFacts(resolution) != resolvedFacts) {
      throw StateError('repository configuration changed after discovery');
    }
    for (final entry in _expected.entries) {
      final stage = entry.value;
      if (!identical(stages(stage.unit), stage) ||
          stages.refresh(stage.unit, git).directory.identity.id !=
              stage.directory.identity.id) {
        throw StateError('repository preparation binding or toolchain changed');
      }
      final current = stages.intentFor(
        stage.unit,
        currentGit: git,
        readInputs: () => _intents[entry.key]!.inputs,
      );
      _intents[entry.key]!.requireCurrent(current.base);
    }
    for (final provider in _providers.values) {
      provider.requireCurrent(stages, git);
    }
  }

  /// Finalize archive commitments only after selected providers have completed.
  /// This installs no files and invokes no producer or publication operation.
  Future<ReleaseStage> bind(ResolvedUnit unit) async {
    if (!identical(resolution.unit(unit.name), unit) ||
        !_expected.containsKey(unit.name)) {
      throw ArgumentError('unit is outside the resolved preparation scope');
    }
    final git = await refreshGit();
    _requireCurrent(git);
    if (_restored.containsKey(unit.name) ||
        withoutPreparation.contains(unit.name) ||
        _bound.contains(unit.name)) {
      return _expected[unit.name]!;
    }
    final discovery = _pending[unit.name]!;
    final imports = <ImportedStageDependency>[];
    final local = <LocalStageDependency>[];
    for (final request in discovery.pending) {
      if (request.use.provider.unit == unit.name) {
        local.add(
          LocalStageDependency(
            use: request.use,
            path: request.path,
            type: request.type,
          ),
        );
      } else {
        final providerUnit = resolution.unit(request.use.provider.unit)!;
        imports.add(
          ImportedStageDependency.fromProvider(
            use: request.use,
            provider: stages(providerUnit),
            path: request.path,
            type: request.type,
          ),
        );
      }
    }
    final dependencies = StageDependencies(
      contexts: discovery.contexts,
      external: discovery.external,
      local: local,
      imports: imports,
    );
    final stage = stages.bindDiscovered(
      unit,
      dependencies: dependencies,
      intent: _intents[unit.name]!,
      currentGit: git,
      expectedBinding: _expected[unit.name]!,
      beforeInstall: () {
        _requireCurrent(git);
        // Canonical plan construction can read live toolchain/provider hooks.
        // Reauthenticate all exact input declarations immediately before install.
        for (final input in imports) {
          final current = ImportedStageDependency.fromProvider(
            use: input.use,
            provider: stages(resolution.unit(input.use.provider.unit)!),
            path: input.original.path,
            type: input.original.type,
          );
          if (CanonicalJson.encode(current.toJson()) !=
              CanonicalJson.encode(input.toJson())) {
            throw StateError('provider changed before dependency installation');
          }
        }
      },
    );
    _expected[unit.name] = stage;
    _bound.add(unit.name);
    return stage;
  }
}
