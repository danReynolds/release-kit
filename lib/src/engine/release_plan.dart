import 'dependency_graph.dart';
import 'diagnostic.dart';
import 'publish_target.dart';
import 'resolve.dart';
import 'stage_contract.dart';
import 'unit_release.dart';

/// The complete configured release topology, derived without observing state.
///
/// This composes the two graphs release actually follows: the private stage
/// producer contract and the prerequisite/public steps. It never creates
/// a stage, identifies a compiler, reads a provider, or decides what work is
/// already complete.
final class RepositoryReleasePlan {
  RepositoryReleasePlan._(this.units);

  final List<ReleaseUnitPlan> units;

  static RepositoryReleasePlan? derive({
    required Resolution resolution,
    required String? repository,
    required Diagnostics diagnostics,
  }) {
    final releases = UnitRelease.all(
      resolution,
      repository: repository,
      problems: diagnostics,
    );
    if (releases == null) return null;
    return RepositoryReleasePlan._(
      List.unmodifiable([for (final release in releases) _deriveUnit(release)]),
    );
  }

  RepositoryReleasePlan select(String unit) => RepositoryReleasePlan._(
    List.unmodifiable(units.where((candidate) => candidate.name == unit)),
  );

  Map<String, Object?> toJson() => {
    'units': [for (final unit in units) unit.toJson()],
  };

  static ReleaseUnitPlan _deriveUnit(UnitRelease release) {
    final unit = release.unit;
    final producerGraph = StageProducerGraph.forWork(release.work);
    final byName = {for (final work in release.work) work.name: work};

    final sourceId = '${unit.name}/stage/source';
    final nodes = <ReleasePlanNode>[];

    for (final requirement in release.requirements) {
      nodes.add(
        ReleasePlanNode(
          id: requirement.id,
          kind: ReleasePlanNodeKind.prerequisite,
          phase: StepPhase.inspect,
          summary: requirement.summary,
          needs: [for (final need in requirement.needs) need.id],
          coordinate: requirement.coordinate,
          target: PublishTarget.pubDev,
          requiresUnit: requirement.provider.unitName,
        ),
      );
    }

    // Every producer builds from the commit's source, read once; a producer
    // that needs no other starts from it.
    nodes.add(
      ReleasePlanNode(
        id: sourceId,
        kind: ReleasePlanNodeKind.sourceSnapshot,
        phase: StepPhase.stage,
        summary: 'source snapshot',
        needs: const [],
      ),
    );
    for (final work in producerGraph.steps) {
      final producer = work.name;
      final prepared = release.preparing(work);
      nodes.add(
        ReleasePlanNode(
          id: work.id,
          kind: ReleasePlanNodeKind.values.byName(work.kind.name),
          phase: StepPhase.stage,
          summary: work.kind == StepKind.completeStage
              ? 'complete and validate stage'
              : work.summary,
          needs: [
            if (producer == 'complete-stage' ||
                producerGraph.dependenciesOf(producer).isEmpty)
              sourceId,
            for (final dependency in producerGraph.dependenciesOf(producer))
              byName[dependency]!.id,
          ],
          producer: producer,
          project: work.project?.name,
          platform: work.platform,
          target: work.target,
          coordinate: prepared?.coordinate,
          lane: work.target?.wireName,
        ),
      );
    }

    for (final target in release.targets) {
      nodes.add(
        ReleasePlanNode(
          id: target.id,
          kind: ReleasePlanNodeKind.values.byName(target.kind.name),
          phase: StepPhase.publish,
          summary: target.summary,
          needs: [for (final need in target.needs) need.id],
          project: target.project?.name,
          target: target.target,
          coordinate: target.target == PublishTarget.pubDev
              ? '${target.project!.name}@${target.project!.version}'
              : target.coordinate,
          lane: target.target.wireName,
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
      for (final requirement in release.requirements)
        requirement.provider.unitName,
    };
    return ReleaseUnitPlan(
      name: unit.name,
      version: unit.version.canonical,
      tag: unit.tag,
      requiresUnits: [for (final candidate in directUnits) candidate],
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
  }) : requiresUnits = List.unmodifiable(requiresUnits),
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
  buildAssets,
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
