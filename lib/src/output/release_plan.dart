import '../engine/publish_target.dart';
import '../engine/unit_release.dart';
import 'output.dart';

/// The human projection of the canonical source-only release graph.
/// [source] is what the checkout is at, its [sourceIdentity]; empty, the
/// plan is of the configured flow alone.
///
/// Wide terminals receive a release tree. Narrow terminals and pipes receive
/// an outline rather than locally wrapped connectors. Both views are derived
/// from the same nodes whose direct edges remain complete in `--json`.
void renderPlan(
  Output output,
  List<UnitRelease> releases, {
  required String repository,
  required String source,
}) {
  final plan = [for (final release in releases) _UnitRows(release)];
  final from = source.isEmpty ? 'configured flow' : source;
  final lines = _graph(plan, repository: repository, source: from);
  final width = output.terminalWidth;
  final graphFits =
      output.isTerminal &&
      width != null &&
      width >= 72 &&
      lines.every((line) => Output.plainWidth(line) <= width);
  if (graphFits) {
    for (final line in lines) {
      output.spans(line);
    }
    return;
  }
  _outline(output, plan, repository: repository, source: from);
}

List<List<OutputSpan>> _graph(
  List<_UnitRows> plan, {
  required String repository,
  required String source,
}) {
  final lines = <List<OutputSpan>>[
    [OutputSpan('${repository.toUpperCase()} RELEASE PLAN', strong: true)],
    [OutputSpan(source, role: VisualRole.secondary)],
    const [OutputSpan('')],
  ];
  for (final (index, unit) in plan.indexed) {
    final lastUnit = index == plan.length - 1;
    final trunk = lastUnit ? '└─' : '├─';
    final rail = lastUnit ? '  ' : '│ ';
    lines.add([
      OutputSpan('$trunk ', role: VisualRole.secondary),
      OutputSpan('${index + 1} · ${unit.name} ${unit.version}', strong: true),
    ]);
    lines.add([OutputSpan('$rail │', role: VisualRole.secondary)]);

    final requirements = unit.requirements.toList();
    for (final requirement in requirements) {
      lines.add([
        OutputSpan('$rail ├─ ', role: VisualRole.secondary),
        OutputSpan(
          'requires  [${_requirementIdentity(requirement)}]',
          role: VisualRole.requirement,
          strong: true,
        ),
      ]);
    }
    if (requirements.isNotEmpty) {
      lines.add([OutputSpan('$rail │', role: VisualRole.secondary)]);
    }

    lines.add([
      OutputSpan('$rail ├─ ', role: VisualRole.secondary),
      const OutputSpan('STAGE', strong: true),
    ]);
    lines.addAll(_stageGraph(unit, rail));
    lines.add([OutputSpan('$rail │', role: VisualRole.secondary)]);
    lines.add([
      OutputSpan('$rail └─ ', role: VisualRole.secondary),
      const OutputSpan('PUBLISH', strong: true),
    ]);
    lines.addAll(_publicGraph(unit, '$rail    '));
    if (!lastUnit) {
      lines.add([OutputSpan(rail, role: VisualRole.secondary)]);
    }
  }
  lines.addAll([
    const [OutputSpan('')],
    const [
      OutputSpan(
        'no destination checks · no changes',
        role: VisualRole.secondary,
      ),
    ],
  ]);
  return lines;
}

List<List<OutputSpan>> _stageGraph(_UnitRows unit, String rail) {
  final nodes = unit.stage.toList();
  final source = nodes.singleWhere(
    (node) => node.kind == StepKind.sourceSnapshot,
  );
  final complete = nodes.singleWhere(
    (node) => node.kind == StepKind.completeStage,
  );
  final work = nodes
      .where(
        (node) =>
            node.kind != StepKind.sourceSnapshot &&
            node.kind != StepKind.completeStage,
      )
      .toList();
  final lines = <List<OutputSpan>>[
    [
      OutputSpan('$rail │  └─ ', role: VisualRole.secondary),
      _node(source, VisualRole.localWork),
    ],
  ];

  final targetWork = work
      .where((node) => node.kind == StepKind.targetStage)
      .toList();
  final byPlatform = <String, List<PlanNode>>{};
  for (final node in work.where((node) => node.platform != null)) {
    (byPlatform[node.platform!] ??= []).add(node);
  }
  final dependentTargetWork = targetWork
      .where((node) => node.needs.any((need) => need != source.id))
      .toSet();
  final projects = {
    for (final node in targetWork)
      if (node.project != null) node.project!,
  };
  final targetLanes = _laneCounts(targetWork);
  final sourceBranches = targetWork.where(
    (node) => !dependentTargetWork.contains(node),
  );
  for (final node in sourceBranches) {
    lines.add([
      OutputSpan('$rail │     ├─▶ ', role: VisualRole.secondary),
      _node(
        node,
        VisualRole.localWork,
        qualify: projects.length > 1 || node.project != unit.name,
      ),
      if (unit.sharedLaneNote(node, targetLanes) case final lane?)
        OutputSpan(' · $lane', role: VisualRole.requirement),
    ]);
  }
  for (final entry in byPlatform.entries) {
    lines.add([
      OutputSpan('$rail │     ├─▶ ', role: VisualRole.secondary),
      OutputSpan('${entry.key}  ', strong: true),
      ..._chain(entry.value, VisualRole.localWork),
    ]);
  }
  for (final dependent in dependentTargetWork) {
    lines.add([
      OutputSpan('$rail │     ├─▶ ', role: VisualRole.secondary),
      _node(
        dependent,
        VisualRole.localWork,
        qualify: projects.length > 1 || dependent.project != unit.name,
      ),
      OutputSpan(
        ' · needs ${_dependencySummary(dependent, nodes)}',
        role: VisualRole.requirement,
      ),
      if (unit.sharedLaneNote(dependent, targetLanes) case final lane?)
        OutputSpan(' · $lane', role: VisualRole.requirement),
    ]);
  }
  lines.add([
    OutputSpan('$rail │     └─▶ ', role: VisualRole.secondary),
    _node(complete, VisualRole.checkpoint),
  ]);
  return lines;
}

List<List<OutputSpan>> _publicGraph(_UnitRows unit, String prefix) {
  final nodes = unit.public.toList();
  if (nodes.isEmpty) {
    return [
      [
        OutputSpan(prefix, role: VisualRole.secondary),
        const OutputSpan('none', role: VisualRole.secondary),
      ],
    ];
  }
  final byId = {for (final node in nodes) node.id: node};
  final laneCounts = _laneCounts(nodes);
  final children = <String, List<PlanNode>>{};
  final roots = <PlanNode>[];
  final extraNeeds = <String, List<PlanNode>>{};
  for (final node in nodes) {
    final publicNeeds = [
      for (final need in node.needs)
        if (byId[need] case final parent?) parent,
    ];
    if (publicNeeds.isEmpty) {
      roots.add(node);
    } else {
      final parent = publicNeeds.last;
      (children[parent.id] ??= []).add(node);
      if (publicNeeds.length > 1) {
        extraNeeds[node.id] = publicNeeds.sublist(0, publicNeeds.length - 1);
      }
    }
  }
  final lines = <List<OutputSpan>>[];
  void draw(PlanNode node, String indent, bool last) {
    lines.add([
      OutputSpan('$indent${last ? '└─▶' : '├─▶'} ', role: VisualRole.secondary),
      OutputSpan(
        '[${unit.publicIdentity(node)}]',
        role: VisualRole.releaseTarget,
        strong: true,
      ),
      if (extraNeeds[node.id] case final additional?)
        OutputSpan(
          ' · also needs ${additional.map(unit.publicIdentity).join(', ')}',
          role: VisualRole.requirement,
        ),
      if (unit.sharedLaneNote(node, laneCounts) case final lane?)
        OutputSpan(' · $lane', role: VisualRole.requirement),
    ]);
    final descendants = children[node.id] ?? const [];
    for (final (index, child) in descendants.indexed) {
      draw(
        child,
        '$indent${last ? '    ' : '│   '}',
        index == descendants.length - 1,
      );
    }
  }

  for (final (index, root) in roots.indexed) {
    draw(root, prefix, index == roots.length - 1);
  }
  return lines;
}

void _outline(
  Output output,
  List<_UnitRows> plan, {
  required String repository,
  required String source,
}) {
  output.heading('$repository · release plan');
  output.say(source, role: VisualRole.secondary);
  for (final (index, unit) in plan.indexed) {
    output.blank();
    output.line(
      '${index + 1} · ${unit.name}',
      note: unit.version,
      strong: true,
      noteRole: VisualRole.secondary,
    );
    for (final requirement in unit.requirements) {
      output.line(
        'requires ${_requirementIdentity(requirement)}',
        depth: 1,
        role: VisualRole.requirement,
      );
    }
    output.line('stage', depth: 1, strong: true);
    final stage = unit.stage.toList();
    final stageLanes = _laneCounts(
      stage.where((node) => node.kind == StepKind.targetStage),
    );
    for (final node in stage) {
      final lane = unit.sharedLaneNote(node, stageLanes);
      output.line(
        _qualifiedSummary(node),
        note: unit.outlineNote(node, lane, stage),
        depth: 2,
        labelWidth: 34,
        role: node.kind == StepKind.completeStage
            ? VisualRole.checkpoint
            : VisualRole.localWork,
        noteRole: node.needs.isEmpty && lane == null
            ? VisualRole.secondary
            : VisualRole.requirement,
      );
    }
    output.line('publish', depth: 1, strong: true);
    final public = unit.public.toList();
    final publicLanes = _laneCounts(public);
    if (public.isEmpty) {
      output.line('none', depth: 2, role: VisualRole.secondary);
    } else {
      for (final node in public) {
        final lane = unit.sharedLaneNote(node, publicLanes);
        output.line(
          unit.publicIdentity(node),
          note: unit.outlineNote(node, lane, unit.nodes),
          depth: 2,
          labelWidth: 34,
          role: VisualRole.releaseTarget,
          noteRole: node.needs.isEmpty && lane == null
              ? VisualRole.secondary
              : VisualRole.requirement,
        );
      }
    }
  }
  output.blank();
  output.say('no destination checks · no changes', role: VisualRole.secondary);
}

List<OutputSpan> _chain(List<PlanNode> nodes, VisualRole role) => [
  for (final (index, node) in nodes.indexed) ...[
    if (index > 0) const OutputSpan(' ─▶ ', role: VisualRole.secondary),
    _node(node, role),
  ],
];

OutputSpan _node(PlanNode node, VisualRole role, {bool qualify = false}) =>
    OutputSpan(
      '[${qualify ? _qualifiedSummary(node) : _graphSummary(node)}]',
      role: role,
      strong: true,
    );

String _qualifiedSummary(PlanNode node) {
  final project = node.project;
  final summary = _humanSummary(node);
  return project == null ? summary : '$summary · $project';
}

String _graphSummary(PlanNode node) => switch (node.kind) {
  StepKind.build when node.platform?.startsWith('macos-') == true =>
    'build + sign',
  StepKind.build => 'build',
  StepKind.notarize => 'notarize',
  StepKind.archive => 'archive',
  StepKind.buildAssets => 'build',
  _ => _humanSummary(node),
};

String _humanSummary(PlanNode node) => switch (node.kind) {
  StepKind.completeStage => 'finalize stage',
  _ => node.summary,
};

String _requirementIdentity(PlanNode node) {
  final parts = node.coordinate?.split('/');
  if (parts != null &&
      parts.length == 3 &&
      parts.first == 'pub.dev' &&
      parts[1].isNotEmpty &&
      parts[2].isNotEmpty) {
    return [
      '${parts[1]}@${parts[2]} on pub.dev',
      if (node.requiresUnit != null) 'provided by ${node.requiresUnit}',
    ].join(' · ');
  }
  return node.summary;
}

String _dependencySummary(PlanNode node, List<PlanNode> stage) {
  final byId = {for (final candidate in stage) candidate.id: candidate};
  final labels = [
    for (final id in node.needs)
      if (byId[id] case final dependency?)
        dependency.platform ?? dependency.summary,
  ];
  if (labels.isNotEmpty &&
      node.needs.every((id) => byId[id]?.kind == StepKind.archive)) {
    return 'archives';
  }
  return labels.isEmpty ? 'its inputs' : labels.join(', ');
}

Map<String, int> _laneCounts(Iterable<PlanNode> nodes) {
  final counts = <String, int>{};
  for (final node in nodes) {
    final lane = node.lane;
    if (lane != null) counts[lane] = (counts[lane] ?? 0) + 1;
  }
  return counts;
}

/// One unit's plan rows, by phase, and what its release calls them.
final class _UnitRows {
  _UnitRows(this.release);

  final UnitRelease release;
  late final List<PlanNode> nodes = release.planNodes;
  String get name => release.unit.name;
  String get version => release.unit.version.canonical;

  Iterable<PlanNode> get requirements =>
      nodes.where((node) => node.phase == StepPhase.inspect);
  Iterable<PlanNode> get stage =>
      nodes.where((node) => node.phase == StepPhase.stage);
  Iterable<PlanNode> get public =>
      nodes.where((node) => node.phase == StepPhase.publish);

  String publicIdentity(PlanNode node) => switch (node.target) {
    PublishTarget.gitTag => node.summary,
    PublishTarget.pubDev => 'pub.dev ${node.coordinate}',
    PublishTarget.githubRelease =>
      'GitHub Release · ${release.github!.artifacts.length} assets',
    PublishTarget.homebrew =>
      'Homebrew · ${node.coordinate?.split('/').last ?? 'formula'}',
    null => node.summary,
  };

  /// Which destination's lane [node] waits its turn in, when another of
  /// [counts]'s nodes shares it.
  String? sharedLaneNote(PlanNode node, Map<String, int> counts) {
    final lane = node.lane;
    if (lane == null || (counts[lane] ?? 0) < 2) return null;
    final label = release.targets
        .where((target) => target.target.wireName == lane)
        .firstOrNull
        ?.kindLabel;
    return 'serialized in ${label ?? lane} lane';
  }

  String? outlineNote(PlanNode node, String? lane, Iterable<PlanNode> nodes) {
    final need = _outlineNeed(node, nodes);
    final facts = [if (need != null) 'needs $need', ?lane];
    return facts.isEmpty ? null : facts.join(' · ');
  }

  String? _outlineNeed(PlanNode node, Iterable<PlanNode> nodes) {
    if (node.kind == StepKind.completeStage) return null;
    if (node.needs.isEmpty) return null;
    final byId = {for (final candidate in nodes) candidate.id: candidate};
    final dependencies = [
      for (final id in node.needs)
        if (byId[id] case final dependency?) dependency,
    ];
    if (node.kind == StepKind.targetStage &&
        dependencies.isNotEmpty &&
        dependencies.every(
          (dependency) => dependency.kind == StepKind.archive,
        )) {
      return 'archives';
    }
    if (dependencies.length != node.needs.length) return 'configured inputs';
    return dependencies.map(_dependencyIdentity).join(', ');
  }

  String _dependencyIdentity(PlanNode node) => switch (node.kind) {
    StepKind.sourceSnapshot => 'source snapshot',
    StepKind.completeStage => 'finalize stage',
    StepKind.build => [?node.platform, 'build'].join(' '),
    StepKind.notarize => [?node.platform, 'notarization'].join(' '),
    StepKind.archive => [?node.platform, 'archive'].join(' '),
    StepKind.buildAssets => 'release assets build',
    StepKind.targetStage => _qualifiedSummary(node),
    StepKind.prerequisite => _requirementIdentity(node),
    StepKind.tag ||
    StepKind.publishRegistry ||
    StepKind.publishRelease ||
    StepKind.publishHomebrew => publicIdentity(node),
  };
}
