import '../engine/release_plan.dart';
import '../engine/publish_target.dart';
import 'output.dart';

/// The human projection of the canonical source-only release graph.
///
/// Wide terminals receive a release tree. Narrow terminals and pipes receive
/// an outline rather than locally wrapped connectors. Both views are derived
/// from the same nodes whose direct edges remain complete in `--json`.
final class ReleasePlanRenderer {
  const ReleasePlanRenderer(this.output);

  final Output output;

  void render(
    RepositoryReleasePlan plan, {
    required String repository,
    String? branch,
    String? commit,
    required int? uncommitted,
  }) {
    final lines = _graph(
      plan,
      repository: repository,
      branch: branch,
      commit: commit,
      uncommitted: uncommitted,
    );
    final width = output.terminalWidth;
    final graphFits = output.isTerminal &&
        width != null &&
        width >= 72 &&
        lines.every((line) => Output.plainWidth(line) <= width);
    if (graphFits) {
      for (final line in lines) {
        output.spans(line);
      }
      return;
    }
    _outline(
      plan,
      repository: repository,
      branch: branch,
      commit: commit,
      uncommitted: uncommitted,
    );
  }

  List<List<OutputSpan>> _graph(
    RepositoryReleasePlan plan, {
    required String repository,
    String? branch,
    String? commit,
    required int? uncommitted,
  }) {
    final lines = <List<OutputSpan>>[
      [
        OutputSpan(
          '${repository.toUpperCase()} RELEASE PLAN',
          strong: true,
        ),
      ],
      [
        OutputSpan(
          _sourceLine(branch, commit, uncommitted),
          role: VisualRole.secondary,
        ),
      ],
      const [OutputSpan('')],
    ];
    for (final (index, unit) in plan.units.indexed) {
      final lastUnit = index == plan.units.length - 1;
      final trunk = lastUnit ? '└─' : '├─';
      final rail = lastUnit ? '  ' : '│ ';
      lines.add([
        OutputSpan('$trunk ', role: VisualRole.secondary),
        OutputSpan(
          '${index + 1} · ${unit.name} ${unit.version}',
          strong: true,
        ),
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
          'source-only · no destination checks · no changes',
          role: VisualRole.secondary,
        ),
      ],
    ]);
    return lines;
  }

  List<List<OutputSpan>> _stageGraph(ReleaseUnitPlan unit, String rail) {
    final nodes = unit.stage.toList();
    final source = nodes.singleWhere(
      (node) => node.kind == ReleasePlanNodeKind.sourceSnapshot,
    );
    final complete = nodes.singleWhere(
      (node) => node.kind == ReleasePlanNodeKind.completeStage,
    );
    final work = nodes
        .where((node) =>
            node.kind != ReleasePlanNodeKind.sourceSnapshot &&
            node.kind != ReleasePlanNodeKind.completeStage)
        .toList();
    final lines = <List<OutputSpan>>[
      [
        OutputSpan('$rail │  └─ ', role: VisualRole.secondary),
        _node(source, VisualRole.localWork),
      ],
    ];

    final targetWork = work
        .where((node) => node.kind == ReleasePlanNodeKind.targetStage)
        .toList();
    final byPlatform = <String, List<ReleasePlanNode>>{};
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
    final sourceBranches =
        targetWork.where((node) => !dependentTargetWork.contains(node));
    for (final node in sourceBranches) {
      lines.add([
        OutputSpan('$rail │     ├─▶ ', role: VisualRole.secondary),
        _node(
          node,
          VisualRole.localWork,
          qualifyProject: projects.length > 1 || node.project != unit.name,
        ),
        if (_sharedLaneNote(node, targetLanes) case final lane?)
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
          qualifyProject: projects.length > 1 || dependent.project != unit.name,
        ),
        OutputSpan(
          ' · needs ${_dependencySummary(dependent, nodes)}',
          role: VisualRole.requirement,
        ),
        if (_sharedLaneNote(dependent, targetLanes) case final lane?)
          OutputSpan(' · $lane', role: VisualRole.requirement),
      ]);
    }
    lines.add([
      OutputSpan('$rail │     └─▶ ', role: VisualRole.secondary),
      _node(complete, VisualRole.checkpoint),
      OutputSpan(
        work.isEmpty ? '' : ' · needs all stage work',
        role: VisualRole.requirement,
      ),
    ]);
    return lines;
  }

  List<List<OutputSpan>> _publicGraph(ReleaseUnitPlan unit, String prefix) {
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
    final children = <String, List<ReleasePlanNode>>{};
    final roots = <ReleasePlanNode>[];
    final extraNeeds = <String, List<ReleasePlanNode>>{};
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
    void draw(ReleasePlanNode node, String indent, bool last) {
      lines.add([
        OutputSpan('$indent${last ? '└─▶' : '├─▶'} ',
            role: VisualRole.secondary),
        _node(node, VisualRole.releaseTarget, publicLabel: true),
        if (extraNeeds[node.id] case final additional?)
          OutputSpan(
            ' · also needs ${additional.map(_publicIdentity).join(', ')}',
            role: VisualRole.requirement,
          ),
        if (_sharedLaneNote(node, laneCounts) case final lane?)
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
    RepositoryReleasePlan plan, {
    required String repository,
    String? branch,
    String? commit,
    required int? uncommitted,
  }) {
    output.heading('$repository · release plan');
    output.say(
      _sourceLine(branch, commit, uncommitted),
      role: VisualRole.secondary,
    );
    for (final (index, unit) in plan.units.indexed) {
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
        stage.where((node) => node.kind == ReleasePlanNodeKind.targetStage),
      );
      for (final node in stage) {
        final lane = _sharedLaneNote(node, stageLanes);
        output.line(
          _qualifiedSummary(node),
          note: _outlineNote(node, lane, stage),
          depth: 2,
          labelWidth: 34,
          role: node.kind == ReleasePlanNodeKind.completeStage
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
          final lane = _sharedLaneNote(node, publicLanes);
          output.line(
            _publicIdentity(node),
            note: _outlineNote(node, lane, unit.nodes),
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
    output.say(
      'source-only · no destination checks · no changes',
      role: VisualRole.secondary,
    );
  }

  static List<OutputSpan> _chain(
    List<ReleasePlanNode> nodes,
    VisualRole role,
  ) {
    final spans = <OutputSpan>[];
    for (final (index, node) in nodes.indexed) {
      if (index > 0) {
        spans.add(const OutputSpan(' ─▶ ', role: VisualRole.secondary));
      }
      spans.add(_node(node, role));
    }
    return spans;
  }

  static OutputSpan _node(
    ReleasePlanNode node,
    VisualRole role, {
    bool qualifyProject = false,
    bool publicLabel = false,
  }) {
    final label = publicLabel
        ? _publicIdentity(node)
        : qualifyProject
            ? _qualifiedSummary(node)
            : _graphSummary(node);
    return OutputSpan('[$label]', role: role, strong: true);
  }

  static String _qualifiedSummary(ReleasePlanNode node) {
    final project = node.project;
    final summary = _humanSummary(node);
    return project == null ? summary : '$summary · $project';
  }

  static String _graphSummary(ReleasePlanNode node) => switch (node.kind) {
        ReleasePlanNodeKind.build
            when node.platform?.startsWith('macos-') == true =>
          'build + sign',
        ReleasePlanNodeKind.build => 'build',
        ReleasePlanNodeKind.notarize => 'notarize',
        ReleasePlanNodeKind.archive => 'archive',
        _ => _humanSummary(node),
      };

  static String _humanSummary(ReleasePlanNode node) => switch (node.kind) {
        ReleasePlanNodeKind.completeStage => 'finalize stage',
        _ => node.summary,
      };

  static String _publicIdentity(ReleasePlanNode node) => switch (node.target) {
        PublishTarget.gitTag => node.summary,
        PublishTarget.pubDev => 'pub.dev ${node.coordinate}',
        PublishTarget.githubRelease => _githubReleaseIdentity(node),
        PublishTarget.homebrew =>
          'Homebrew · ${node.coordinate?.split('/').last ?? 'formula'}',
        null => node.summary,
      };

  static String _githubReleaseIdentity(ReleasePlanNode node) {
    final match =
        RegExp(r'^publish (\d+) (asset|assets) to ').firstMatch(node.summary);
    return match == null
        ? 'GitHub Release'
        : 'GitHub Release · ${match.group(1)} ${match.group(2)}';
  }

  static String _requirementIdentity(ReleasePlanNode node) {
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

  static String _dependencySummary(
    ReleasePlanNode node,
    List<ReleasePlanNode> stage,
  ) {
    final byId = {for (final candidate in stage) candidate.id: candidate};
    final labels = [
      for (final id in node.needs)
        if (byId[id] case final dependency?)
          dependency.platform ?? dependency.summary,
    ];
    if (labels.isNotEmpty &&
        node.needs
            .every((id) => byId[id]?.kind == ReleasePlanNodeKind.archive)) {
      return 'archives';
    }
    return labels.isEmpty ? 'its inputs' : labels.join(', ');
  }

  static Map<String, int> _laneCounts(Iterable<ReleasePlanNode> nodes) {
    final counts = <String, int>{};
    for (final node in nodes) {
      final lane = node.lane;
      if (lane != null) counts[lane] = (counts[lane] ?? 0) + 1;
    }
    return counts;
  }

  static String? _sharedLaneNote(
    ReleasePlanNode node,
    Map<String, int> counts,
  ) {
    final lane = node.lane;
    if (lane == null || (counts[lane] ?? 0) < 2) return null;
    final label = switch (lane) {
      'gitTag' => 'Git tag',
      'pubDev' => 'pub.dev',
      'githubRelease' => 'GitHub Release',
      'homebrew' => 'Homebrew',
      _ => lane,
    };
    return 'serialized in $label lane';
  }

  static String? _outlineNote(
    ReleasePlanNode node,
    String? lane,
    Iterable<ReleasePlanNode> nodes,
  ) {
    final need = _outlineNeed(node, nodes);
    final facts = [
      if (need != null) 'needs $need',
      if (lane != null) lane,
    ];
    return facts.isEmpty ? null : facts.join(' · ');
  }

  static String? _outlineNeed(
    ReleasePlanNode node,
    Iterable<ReleasePlanNode> nodes,
  ) {
    if (node.needs.isEmpty) return null;
    final byId = {for (final candidate in nodes) candidate.id: candidate};
    final dependencies = [
      for (final id in node.needs)
        if (byId[id] case final dependency?) dependency,
    ];
    if (node.kind == ReleasePlanNodeKind.completeStage &&
        dependencies.any(
          (dependency) => dependency.kind != ReleasePlanNodeKind.sourceSnapshot,
        )) {
      return 'all stage work';
    }
    if (node.kind == ReleasePlanNodeKind.targetStage &&
        dependencies.isNotEmpty &&
        dependencies.every(
          (dependency) => dependency.kind == ReleasePlanNodeKind.archive,
        )) {
      return 'archives';
    }
    if (dependencies.length != node.needs.length) return 'configured inputs';
    return dependencies.map(_outlineDependencyIdentity).join(', ');
  }

  static String _outlineDependencyIdentity(ReleasePlanNode node) =>
      switch (node.kind) {
        ReleasePlanNodeKind.sourceSnapshot => 'source snapshot',
        ReleasePlanNodeKind.completeStage => 'finalize stage',
        ReleasePlanNodeKind.build => [
            if (node.platform != null) node.platform!,
            'build',
          ].join(' '),
        ReleasePlanNodeKind.notarize => [
            if (node.platform != null) node.platform!,
            'notarization',
          ].join(' '),
        ReleasePlanNodeKind.archive => [
            if (node.platform != null) node.platform!,
            'archive',
          ].join(' '),
        ReleasePlanNodeKind.targetStage => _qualifiedSummary(node),
        ReleasePlanNodeKind.prerequisite => _requirementIdentity(node),
        ReleasePlanNodeKind.tag ||
        ReleasePlanNodeKind.publishRegistry ||
        ReleasePlanNodeKind.publishRelease ||
        ReleasePlanNodeKind.publishHomebrew =>
          _publicIdentity(node),
      };

  static String _sourceLine(
    String? branch,
    String? commit,
    int? uncommitted,
  ) {
    final identity = [
      if (branch != null && commit != null) '$branch@$commit',
      if (branch != null && commit == null) branch,
      if (branch == null && commit != null) commit,
      if (uncommitted != null && uncommitted > 0) '$uncommitted uncommitted',
    ].join(' · ');
    return identity.isEmpty ? 'configured flow' : identity;
  }
}
