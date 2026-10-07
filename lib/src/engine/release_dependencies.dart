import '../native/dart/dependencies.dart';
import 'diagnostic.dart';
import 'native_dependencies.dart';
import 'publish_target.dart';
import 'resolve.dart';
import 'version.dart';

/// Source-only dependency facts and candidate projections for this repository.
///
/// One instance lives on [Resolution.dependencyPlan]. Source-only readers use
/// this provisional projection; preparation and publication derive their actual
/// orders from adapter-validated native contexts. Incompatible local candidates
/// remain unresolved hosted requirements. Destination state stays out.
final class ReleaseDependencyPlan {
  ReleaseDependencyPlan(this.resolution);

  final Resolution resolution;

  /// Native source facts; no registry/cache/compiler access. Only hosted
  /// package requirements participate in configured provider selection.
  List<NativeRequirement> requirements(
    ResolvedUnit unit,
    Diagnostics diagnostics,
  ) {
    final result = <NativeRequirement>[];
    for (final project in unit.projects) {
      try {
        result.addAll(
          dartRequirements(
            project,
            publicPackage: project.publish.contains(PublishTarget.pubDev),
          ),
        );
      } on InvalidNativeRequirement catch (error) {
        diagnostics.report(
          Diagnostic(
            code: 'RK-DEP-002',
            message:
                'Pub cannot parse ${error.requirement.package.name} ${error.requirement.constraint} required by "${project.name}"',
            source: error.requirement.location,
            remedy:
                'correct the native Pub version constraint in this manifest',
            evidence: error.detail,
          ),
        );
      }
    }
    return List.unmodifiable(result);
  }

  List<NativeCandidateSelection> selections(
    ResolvedUnit unit,
    Diagnostics diagnostics, {
    required DependencyPhase phase,
  }) => _select(requirements(unit, diagnostics), phase);

  List<NativeCandidateSelection> _select(
    Iterable<NativeRequirement> requirements,
    DependencyPhase phase,
  ) => selectNativeCandidates(
    requirements: requirements,
    candidates: [
      for (final project in resolution.allProjects)
        if (project.publish.contains(PublishTarget.pubDev))
          dartCandidate(project),
    ],
    semantics: const DartDependencySemantics(),
    phase: phase,
  );

  /// The repository's packages [project] takes from this source when it is
  /// staged, so that Pub resolves it as its consumers will.
  ///
  /// A package it needs at runtime, directly or through other such
  /// packages, comes from this source while its version here satisfies
  /// what is asked of it and is not [published] yet: it can come from
  /// nowhere else, and it publishes first. Once that version is published,
  /// Pub takes it from the registry, as consumers do. A package [project]
  /// needs only for development comes from this source whenever its
  /// version satisfies: its consumers never resolve it.
  Future<List<ResolvedProject>> fromSource(
    ResolvedProject project,
    Future<bool> Function(String package, String version) published,
  ) async {
    final projects = {
      for (final project in resolution.allProjects) project.name: project,
    };
    List<NativeCandidate> needs(
      ResolvedProject owner,
      bool Function(NativeRequirement requirement) needed,
      DependencyPhase phase,
    ) => [
      for (final selection in _select(
        requirements(
          resolution.unit(owner.unitName)!,
          Diagnostics(),
        ).where((requirement) => requirement.owner == owner.name).where(needed),
        phase,
      ))
        if (selection.candidate case final provider?) provider,
    ];
    bool runtime(NativeRequirement requirement) =>
        requirement.kind == 'runtime';

    final runtimeNames = project.pubspec.dependencies.keys.toSet();
    final sourced = <ResolvedProject>[
      for (final provider in needs(
        project,
        (requirement) =>
            requirement.kind == 'development' &&
            !runtimeNames.contains(requirement.slot),
        DependencyPhase.preparation,
      ))
        if (provider.project != project.name) projects[provider.project]!,
    ];
    final seen = {project.name, for (final sibling in sourced) sibling.name};
    final pending = [
      ...needs(project, runtime, DependencyPhase.publication),
      for (final sibling in sourced)
        ...needs(sibling, runtime, DependencyPhase.publication),
    ];
    while (pending.isNotEmpty) {
      final provider = pending.removeLast();
      if (!seen.add(provider.project) ||
          await published(provider.package.name, provider.version)) {
        continue;
      }
      final sibling = projects[provider.project]!;
      sourced.add(sibling);
      pending.addAll(needs(sibling, runtime, DependencyPhase.publication));
    }
    return sourced;
  }

  /// Within [unit], a project that another depends on publishes first, so
  /// the dependent resolves for consumers the moment it lands. Development
  /// inputs do not become publication prerequisites.
  List<ResolvedProject> projects(ResolvedUnit unit, Diagnostics diagnostics) {
    assert(
      resolution.units.contains(unit),
      'the unit must belong to this plan\'s resolution',
    );
    final byName = {for (final project in unit.projects) project.name: project};
    final selected = selections(
      unit,
      diagnostics,
      phase: DependencyPhase.publication,
    );
    final needs = {
      for (final project in unit.projects)
        project: <ResolvedProject>[
          for (final selection in selected)
            if (selection.requirements.any(
              (requirement) => requirement.owner == project.name,
            ))
              if (selection.candidate case final provider?)
                if (provider.unit == unit.name) byName[provider.project]!,
        ],
    };
    return _ordered(
      unit.projects,
      (project) => needs[project]!,
      diagnostics,
      (cycle) => Diagnostic(
        code: 'RK-DEP-003',
        message:
            'the packages in "${unit.name}" depend on each other in '
            'a circle, so there is no order that publishes them',
        source: unit.location,
        remedy:
            'break the dependency cycle involving: '
            '${cycle.map((project) => project.name).join(', ')}',
      ),
    );
  }

  /// Prerequisites [unit] has on packages released by other units.
  List<ExternalPrerequisite> prerequisites(
    ResolvedUnit unit,
    Diagnostics diagnostics,
  ) {
    return [
      for (final selection in selections(
        unit,
        diagnostics,
        phase: DependencyPhase.publication,
      ))
        if (selection.candidate case final provider?)
          if (provider.unit != unit.name)
            for (final dependent
                in selection.requirements
                    .map((requirement) => requirement.owner)
                    .toSet())
              ExternalPrerequisite(
                dependent: dependent,
                package: provider.package.name,
                version: Version.tryParse(provider.version)!,
                declaredBy: provider.unit,
              ),
    ];
  }

  /// The repository's units in release order, dependencies first. An
  /// incompatible local candidate adds no edge: its original requirement is
  /// left to native hosted resolution, without claiming a public version exists.
  List<ResolvedUnit> units(Diagnostics diagnostics) {
    final needs = {
      for (final unit in resolution.units)
        unit: [
          for (final name in {
            for (final prerequisite in prerequisites(unit, diagnostics))
              prerequisite.declaredBy,
          })
            resolution.unit(name)!,
        ],
    };
    return _ordered(
      resolution.units,
      (unit) => needs[unit]!,
      diagnostics,
      (cycle) => Diagnostic(
        code: 'RK-DEP-004',
        message: 'the release units depend on each other in a circle',
        remedy:
            'break the first-party dependency cycle involving: '
            '${cycle.map((unit) => unit.name).join(', ')}',
      ),
    );
  }

  /// A dependencies-first order over [values]. When a cycle makes complete
  /// ordering impossible, reports [cycle] with the actual members and falls
  /// back to input order for the remainder: every value is always returned,
  /// and the diagnostic is the refusal.
  static List<T> _ordered<T>(
    List<T> values,
    List<T> Function(T value) dependencies,
    Diagnostics diagnostics,
    Diagnostic Function(List<T> cycle) cycle,
  ) {
    final ordered = <T>[];
    final settled = <T>{};
    while (ordered.length < values.length) {
      final next = values
          .where(
            (value) =>
                !settled.contains(value) &&
                dependencies(value).every(settled.contains),
          )
          .firstOrNull;
      if (next == null) {
        diagnostics.report(cycle(_cycle(values, dependencies, settled)));
        for (final value in values) {
          if (settled.add(value)) ordered.add(value);
        }
        return ordered;
      }
      ordered.add(next);
      settled.add(next);
    }
    return ordered;
  }

  /// One actual cycle among the unsettled values, so the remedy names the
  /// circle itself rather than everything stalled behind it. When the sort
  /// stalls, every unsettled value has an unsettled dependency, so following
  /// them must revisit a value; the loop from that revisit is the cycle.
  static List<T> _cycle<T>(
    List<T> values,
    List<T> Function(T value) dependencies,
    Set<T> settled,
  ) {
    final path = <T>[];
    var value = values.firstWhere((value) => !settled.contains(value));
    while (!path.contains(value)) {
      path.add(value);
      value = dependencies(
        value,
      ).firstWhere((dependency) => !settled.contains(dependency));
    }
    return path.sublist(path.indexOf(value));
  }
}

/// A dependency on a package released by another unit, which must be live
/// and verified before this unit's publication can proceed.
class ExternalPrerequisite {
  ExternalPrerequisite({
    required this.dependent,
    required this.package,
    required this.version,
    required this.declaredBy,
  });

  final String dependent;
  final String package;

  /// The version required, read from the depended-on project's own manifest —
  /// never inferred from the pin's form, since an ordinary caret pin would
  /// otherwise derive nothing.
  final Version version;

  /// The unit whose project declares the depended-on package.
  final String declaredBy;

  String get coordinate => 'pub.dev/$package/$version';
}
