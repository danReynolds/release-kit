import '../engine/canonical_json.dart';
import '../engine/checklist.dart';
import '../engine/dependency_graph.dart';
import '../engine/native_publication.dart';
import '../engine/stage_dependencies.dart';
import '../engine/stage_receipt.dart';
import '../engine/targets.dart';
import 'release_publication_coordinator.dart';

/// Maps adapter-proven runtime occurrences onto existing public target IDs.
/// Native versions, constraints and source semantics stay in the adapter; this
/// composition owns only exact artifact commitments, scope and graph order.
Future<List<PublicationPlan>> repositoryPublications({
  required Iterable<PublicationPlan> prepared,
  required NativePublication native,
}) async {
  final plans = prepared.toList();
  final byUnit = {for (final plan in plans) plan.unit.name: plan};
  if (byUnit.length != plans.length) {
    throw StateError('publication scope repeats a unit');
  }
  final packageTargets = <(String, String), TargetPlan>{};
  for (final plan in plans) {
    for (final target in plan.targets) {
      final producer = target.packageProducer;
      if (producer == null) continue;
      if (packageTargets.containsKey((plan.unit.name, producer))) {
        throw StateError('a package producer has multiple publication targets');
      }
      packageTargets[(plan.unit.name, producer)] = target;
    }
  }
  final checks = <String, Map<String, NativePublicationCheck>>{};
  final needs = <String, Set<String>>{};
  final unitNeeds = {for (final plan in plans) plan.unit.name: <String>{}};
  final sourcePrerequisites = {
    for (final plan in plans)
      for (final step in plan.steps)
        if (step.kind == StepKind.prerequisite) step.id,
  };
  final packageIds = packageTargets.values.map((t) => t.step.id).toSet();
  // Replace all source-inferred native edges. Retain target lifecycle edges,
  // such as complete-stage -> tag -> archive publication and release -> tap.
  for (final plan in plans) {
    for (final step in plan.steps) {
      if (sourcePrerequisites.contains(step.id)) continue;
      needs[step.id] = {
        for (final id in step.needs)
          if (!sourcePrerequisites.contains(id) &&
              !(packageIds.contains(step.id) && packageIds.contains(id)))
            id,
      };
    }
  }
  for (final plan in plans) {
    final targets = {
      for (final target in plan.targets)
        if (target.packageProducer case final producer?) producer: target,
    };
    checks[plan.unit.name] = {};
    if (targets.isEmpty || plan.preparedNoop) continue;
    if (plan.recoversWithoutStage) {
      if (targets.values.any(
        (target) => !plan.states[target.step.id]!.isExact,
      )) {
        throw StateError(
          'package publication requires its exact prepared stage',
        );
      }
      // Only authenticated moving targets remain. Exact package coordinates
      // stay under aggregate omission checks; no package upload is authorized.
      continue;
    }
    for (final context in plan.stage.dependencies.contexts) {
      if (context.consumers.any(targets.containsKey) &&
          !native.ecosystems.contains(context.ecosystem)) {
        throw StateError('no publication adapter for ${context.ecosystem}');
      }
    }
    final projected = await native.prepare(plan.stage);
    final covered = <String>{};
    final artifacts = {
      for (final artifact in plan.stage.requireReceipt().artifacts)
        artifact.path: artifact,
    };
    for (final check in projected) {
      final target = targets[check.producer];
      if (target == null || !covered.add(check.producer)) {
        throw StateError(
          'native publication has an extra or duplicate producer',
        );
      }
      checks[plan.unit.name]![target.step.id] = check;
      final slots = <(String, String)>{};
      for (final requirement in check.requirements) {
        final use = requirement.use;
        if (!use.consumers.contains(check.producer) ||
            !slots.add((use.context, use.slot)) ||
            !_recordedUse(plan, use, requirement.archive) ||
            !_sameArtifact(
              artifacts[requirement.archive.path],
              requirement.archive,
            )) {
          throw StateError(
            'public dependency differs from the frozen stage input',
          );
        }
        final provider = use.provider;
        final selected = byUnit[provider.unit];
        if (selected == null) continue; // The native gate proves public inputs.
        final dependency = packageTargets[(provider.unit, provider.producer)];
        if (dependency == null ||
            dependency.project?.name != provider.project ||
            dependency.targetVersion != provider.version) {
          throw StateError(
            'selected public provider differs from its native identity',
          );
        }
        if (!selected.preparedNoop && !selected.recoversWithoutStage) {
          final emitted = selected.stage
              .requireReceipt()
              .steps
              .singleWhere((step) => step.name == provider.producer)
              .outputs;
          if (!emitted.any(
            (artifact) =>
                artifact.sha256 == requirement.archive.sha256 &&
                artifact.size == requirement.archive.size &&
                artifact.mode == requirement.archive.mode,
          )) {
            throw StateError(
              'selected provider archive differs from the consumer commitment',
            );
          }
        }
        needs[target.step.id]!.add(dependency.step.id);
        if (provider.unit != plan.unit.name) {
          unitNeeds[plan.unit.name]!.add(provider.unit);
        }
      }
    }
    if (covered.length != targets.length) {
      throw StateError(
        'native publication does not cover every package producer',
      );
    }
  }
  // Diagnose actual target cycles before the more restrictive complete-unit
  // executor. An acyclic target graph may still require unit interleaving.
  final allSteps = {
    for (final plan in plans)
      for (final step in plan.steps)
        if (!sourcePrerequisites.contains(step.id)) step.id: step,
  };
  final targetOrder = DependencyGraph<Step>(
    allSteps.values,
    idOf: (step) => step.id,
    dependenciesOf: (step) => needs[step.id]!,
  ).ordered();
  final List<PublicationPlan> order;
  try {
    order = DependencyGraph<PublicationPlan>(
      plans,
      idOf: (plan) => plan.unit.name,
      dependenciesOf: (plan) => unitNeeds[plan.unit.name]!,
    ).ordered();
  } on StateError catch (error) {
    throw StateError(
      'native publication requires interleaved release units; '
      'regroup the packages into independent units: $error',
    );
  }
  return List.unmodifiable([
    for (final plan in order)
      _withDependencies(plan, [
        for (final step in targetOrder)
          if (step.unit == plan.unit.name)
            step.withNeeds(
              needs[step.id]!
                  .where((id) => allSteps[id]!.unit == plan.unit.name)
                  .toList(),
            ),
      ], checks[plan.unit.name]!),
  ]);
}

bool _sameArtifact(StageArtifact? left, StageArtifact right) =>
    left != null &&
    CanonicalJson.encode(left.toJson()) == CanonicalJson.encode(right.toJson());

bool _recordedUse(
  PublicationPlan plan,
  NativeArtifactUse use,
  StageArtifact artifact,
) {
  final key = CanonicalJson.encode(use.toJson());
  return plan.stage.dependencies.imports.any(
        (input) =>
            CanonicalJson.encode(input.use.toJson()) == key &&
            _sameArtifact(input.archive, artifact),
      ) ||
      plan.stage.dependencies.local.any(
        (input) =>
            CanonicalJson.encode(input.use.toJson()) == key &&
            input.path == artifact.path &&
            input.type == artifact.type,
      );
}

PublicationPlan _withDependencies(
  PublicationPlan plan,
  List<Step> steps,
  Map<String, NativePublicationCheck> checks,
) {
  final byId = {for (final step in steps) step.id: step};
  return PublicationPlan(
    unit: plan.unit,
    steps: steps,
    publicSteps: steps.where((step) => step.isPublic),
    targets: [
      for (final target in plan.targets) target.withStep(byId[target.step.id]!),
    ],
    states: plan.states,
    endpointBaselines: plan.endpointBaselines,
    actions: plan.actions,
    prepared: plan.prepared,
    stage: plan.stage,
    recoversWithoutStage: plan.recoversWithoutStage,
    preparedNoop: plan.preparedNoop,
    nativeChecks: checks,
  );
}
