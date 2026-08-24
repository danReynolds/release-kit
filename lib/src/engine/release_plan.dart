import '../targets/catalog.dart';
import '../targets/target_module.dart';
import 'checklist.dart';
import 'dependency_graph.dart';
import 'diagnostic.dart';
import 'producers.dart';
import 'publish_target.dart';
import 'release_dependencies.dart';
import 'resolve.dart';
import 'stage_contract.dart';
import 'targets.dart';

/// The complete configured release topology, derived without observing state.
///
/// This composes the two graphs release actually follows: the private stage
/// producer contract and the prerequisite/public checklist. It never creates
/// a stage, identifies a compiler, reads a provider, or decides what work is
/// already complete.
final class RepositoryReleasePlan {
  RepositoryReleasePlan._(this.units);

  final List<ReleaseUnitPlan> units;

  static RepositoryReleasePlan? derive({
    required Resolution resolution,
    required String? repository,
    required TargetCatalog targets,
    required Diagnostics diagnostics,
  }) {
    final ordered = resolution.dependencyPlan.units(diagnostics);
    if (diagnostics.isNotEmpty) return null;

    final plans = <ReleaseUnitPlan>[];
    for (final unit in ordered) {
      final prerequisites =
          resolution.dependencyPlan.prerequisites(unit, diagnostics);
      final checklist = Checklist.derive(unit, resolution, diagnostics);
      if (diagnostics.isNotEmpty) return null;

      final publicTargets = targets.derive(
        unit,
        checklist,
        repository: repository,
      );
      final targetStages = targets.stages(
        unit: unit,
        targets: publicTargets,
      );
      plans.add(
        _deriveUnit(
          unit,
          checklist,
          prerequisites,
          publicTargets,
          targetStages,
        ),
      );
    }
    return RepositoryReleasePlan._(List.unmodifiable(plans));
  }

  RepositoryReleasePlan select(String unit) => RepositoryReleasePlan._(
        List.unmodifiable(units.where((candidate) => candidate.name == unit)),
      );

  Map<String, Object?> toJson() => {
        'source_only': true,
        'destinations_inspected': false,
        'units': [for (final unit in units) unit.toJson()],
      };

  static ReleaseUnitPlan _deriveUnit(
    ResolvedUnit unit,
    Checklist checklist,
    List<ExternalPrerequisite> prerequisites,
    List<TargetPlan> publicTargets,
    List<TargetStage> targetStages,
  ) {
    final localSteps = {
      for (final step in checklist.steps.where(
        (step) =>
            step.kind == StepKind.build ||
            step.kind == StepKind.notarize ||
            step.kind == StepKind.archive,
      ))
        receiptNameFor(step): step,
    };
    final targetStagesByProducer = {
      for (final stage in targetStages) stage.contract.step.name: stage,
    };
    final publicTargetByStep = {
      for (final target in publicTargets) target.step.id: target,
    };
    final producerGraph = StageProducerGraph.forUnit(
      targetContributions: targetStages.map((stage) => stage.contract),
      localProducers: localProducerContracts(unit),
    );

    String producerId(String producer) {
      if (producer == 'source-snapshot') return '${unit.name}/stage/source';
      if (producer == 'complete-stage') return '${unit.name}/stage/complete';
      final local = localSteps[producer];
      if (local != null) return local.id;
      return '${unit.name}/stage/$producer';
    }

    final prerequisiteByCoordinate = {
      for (final prerequisite in prerequisites)
        prerequisite.coordinate: prerequisite,
    };
    final nodes = <ReleasePlanNode>[];

    for (final step in checklist.steps.where(
      (step) => step.kind == StepKind.prerequisite,
    )) {
      final prerequisite = prerequisiteByCoordinate[step.coordinate];
      nodes.add(
        ReleasePlanNode(
          id: step.id,
          kind: ReleasePlanNodeKind.prerequisite,
          phase: StepPhase.inspect,
          summary: step.summary,
          needs: step.needs,
          coordinate: step.coordinate,
          target: PublishTarget.pubDev,
          requiresUnit: prerequisite?.declaredBy,
        ),
      );
    }

    for (final contract in producerGraph.steps) {
      final producer = contract.name;
      final local = localSteps[producer];
      final targetStage = targetStagesByProducer[producer];
      final kind = switch (producer) {
        'source-snapshot' => ReleasePlanNodeKind.sourceSnapshot,
        'complete-stage' => ReleasePlanNodeKind.completeStage,
        _ when local != null => switch (local.kind) {
            StepKind.build => ReleasePlanNodeKind.build,
            StepKind.notarize => ReleasePlanNodeKind.notarize,
            StepKind.archive => ReleasePlanNodeKind.archive,
            _ => throw StateError('unexpected local producer ${local.kind}'),
          },
        _ when targetStage != null => ReleasePlanNodeKind.targetStage,
        _ => throw StateError('the stage graph has no plan metadata for '
            '"$producer"'),
      };
      nodes.add(
        ReleasePlanNode(
          id: producerId(producer),
          kind: kind,
          phase: StepPhase.stage,
          summary: switch (producer) {
            'source-snapshot' => 'source snapshot',
            'complete-stage' => 'complete and validate stage',
            _ when local != null => local.summary,
            _ => targetStage!.planLabel,
          },
          needs: [
            for (final dependency in producerGraph.dependenciesOf(producer))
              producerId(dependency),
          ],
          producer: producer,
          project: local?.project ?? targetStage?.target.project?.name,
          platform: local?.platform,
          target: targetStage?.target.target,
          coordinate: targetStage?.target.coordinate,
          lane: targetStage?.target.target.wireName,
        ),
      );
    }

    for (final step in checklist.steps.where((step) => step.isPublic)) {
      final plannedTarget = publicTargetByStep[step.id]!;
      nodes.add(
        ReleasePlanNode(
          id: step.id,
          kind: switch (step.kind) {
            StepKind.tag => ReleasePlanNodeKind.tag,
            StepKind.publishRegistry => ReleasePlanNodeKind.publishRegistry,
            StepKind.publishRelease => ReleasePlanNodeKind.publishRelease,
            StepKind.publishHomebrew => ReleasePlanNodeKind.publishHomebrew,
            _ => throw StateError('unexpected public step ${step.kind}'),
          },
          phase: StepPhase.publish,
          summary: step.summary,
          needs: step.needs,
          project: plannedTarget.project?.name ?? step.project,
          platform: step.platform,
          target: step.target,
          coordinate: step.target == PublishTarget.pubDev
              ? step.coordinate
              : plannedTarget.coordinate,
          lane: step.target?.wireName,
        ),
      );
    }

    final graph = DependencyGraph<ReleasePlanNode>(
      nodes,
      idOf: (node) => node.id,
      dependenciesOf: (node) => node.needs,
    );
    final canonical = graph.ordered();
    final directUnits = <String>{
      for (final prerequisite in prerequisites) prerequisite.declaredBy,
    };
    return ReleaseUnitPlan(
      name: unit.name,
      version: unit.version.canonical,
      tag: unit.tag,
      requiresUnits: [
        for (final candidate in directUnits) candidate,
      ],
      nodes: canonical,
    );
  }
}

final class ReleaseUnitPlan {
  ReleaseUnitPlan({
    required this.name,
    required this.version,
    required this.tag,
    required List<String> requiresUnits,
    required List<ReleasePlanNode> nodes,
  })  : requiresUnits = List.unmodifiable(requiresUnits),
        nodes = List.unmodifiable(nodes);

  final String name;
  final String version;
  final String? tag;
  final List<String> requiresUnits;
  final List<ReleasePlanNode> nodes;

  Iterable<ReleasePlanNode> get requirements =>
      nodes.where((node) => node.phase == StepPhase.inspect);
  Iterable<ReleasePlanNode> get stage =>
      nodes.where((node) => node.phase == StepPhase.stage);
  Iterable<ReleasePlanNode> get public =>
      nodes.where((node) => node.phase == StepPhase.publish);

  Map<String, Object?> toJson() => {
        'name': name,
        'version': version,
        'tag': tag,
        'requires_units': requiresUnits,
        'nodes': [for (final node in nodes) node.toJson()],
      };
}

enum ReleasePlanNodeKind {
  prerequisite,
  sourceSnapshot,
  targetStage,
  build,
  notarize,
  archive,
  completeStage,
  tag,
  publishRegistry,
  publishRelease,
  publishHomebrew,
}

final class ReleasePlanNode {
  ReleasePlanNode({
    required this.id,
    required this.kind,
    required this.phase,
    required this.summary,
    required Iterable<String> needs,
    this.producer,
    this.project,
    this.platform,
    this.target,
    this.coordinate,
    this.requiresUnit,
    this.lane,
  }) : needs = List.unmodifiable(needs);

  final String id;
  final ReleasePlanNodeKind kind;
  final StepPhase phase;
  final String summary;
  final List<String> needs;
  final String? producer;
  final String? project;
  final String? platform;
  final PublishTarget? target;
  final String? coordinate;
  final String? requiresUnit;
  final String? lane;

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'phase': phase.name,
        'summary': summary,
        'needs': needs,
        if (producer != null) 'producer': producer,
        if (project != null) 'project': project,
        if (platform != null) 'platform': platform,
        if (target != null) 'target': target!.wireName,
        if (coordinate != null) 'coordinate': coordinate,
        if (requiresUnit != null) 'requires_unit': requiresUnit,
        if (lane != null) 'lane': lane,
      };
}
