import 'diagnostic.dart';
import 'publish_target.dart';
import 'resolve.dart';
import 'version.dart';

/// The repository's Dart package dependency graph.
///
/// One instance lives on [Resolution.dependencyPlan] — the single source of
/// project publication order, cross-unit prerequisites, and repository
/// release order. Diagnostics are the refusal signal: on a cycle or a bad
/// constraint the returned order is best-effort so non-refusing readers
/// (status) still describe every step, and acting sinks refuse on the
/// problems. Destination state stays out: the checklist and inspector
/// decide what work remains after this plan.
final class ReleaseDependencyPlan {
  ReleaseDependencyPlan(this.resolution)
      : _firstParty = {
          for (final project in resolution.allProjects) project.name: project,
        };

  final Resolution resolution;
  final Map<String, ResolvedProject> _firstParty;

  /// Within [unit], a project that another depends on publishes first, so
  /// the dependent resolves for consumers the moment it lands. Both
  /// dependency kinds order publication.
  List<ResolvedProject> projects(
    ResolvedUnit unit,
    Diagnostics diagnostics,
  ) {
    assert(
      resolution.units.contains(unit),
      'the unit must belong to this plan\'s resolution',
    );
    // Sibling edges resolve through the unit's own projects, not the
    // repository map, so membership cannot be masked by a name elsewhere.
    final byName = {for (final project in unit.projects) project.name: project};
    final needs = {
      for (final project in unit.projects)
        project: [
          for (final name in [
            ...project.pubspec.dependencies.keys,
            ...project.pubspec.devDependencies.keys,
          ])
            if (byName[name] case final sibling?) sibling,
        ],
    };
    return _ordered(
      unit.projects,
      (project) => needs[project]!,
      diagnostics,
      (cycle) => Diagnostic(
        code: 'RK-DEP-003',
        message: 'the packages in "${unit.name}" depend on each other in '
            'a circle, so there is no order that publishes them',
        source: unit.location,
        remedy: 'break the dependency cycle involving: '
            '${cycle.map((project) => project.name).join(', ')}',
      ),
    );
  }

  /// Prerequisites [unit] has on packages released by other units.
  List<ExternalPrerequisite> prerequisites(
    ResolvedUnit unit,
    Diagnostics diagnostics,
  ) {
    final result = <ExternalPrerequisite>[];
    for (final project in unit.projects) {
      // Both kinds: a development dependency orders publication within a
      // unit, and the consumer resolve a release runs resolves them too, so
      // a coordinated bump must be refused before the work rather than at
      // publish.
      final required = {
        ...project.pubspec.dependencies,
        ...project.pubspec.devDependencies,
      };
      required.forEach((name, dependency) {
        final sibling = _firstParty[name];
        if (sibling == null || // an ordinary third-party dependency
            sibling.unitName == unit.name || // ordered within the unit
            !sibling.publish.contains(PublishTarget.pubDev)) {
          return;
        }

        final satisfied = dependency.satisfiedBy(sibling.version);
        if (satisfied == false) {
          diagnostics.add(
            'RK-DEP-001',
            '"${project.name}" requires $name ${dependency.constraint}, and '
                'this repository releases $name at ${sibling.version}',
            source: SourceLocation(project.pubspec.path, dependency.line),
            remedy: 'align the constraint with the version being released',
          );
          return;
        }
        if (satisfied == null) {
          // Not knowing is not the same as being satisfied. Treating it as
          // satisfied would publish against a requirement rk never checked.
          diagnostics.add(
            'RK-DEP-002',
            'rk cannot tell whether "${project.name}" accepts $name '
                '${sibling.version}: it requires '
                '${dependency.describeRequirement()}',
            source: SourceLocation(project.pubspec.path, dependency.line),
            remedy: 'first-party dependencies use an exact or caret version, '
                'so rk can check the release against them',
          );
          return;
        }

        result.add(
          ExternalPrerequisite(
            dependent: project.name,
            package: name,
            version: sibling.version,
            declaredBy: sibling.unitName,
          ),
        );
      });
    }
    return result;
  }

  /// The repository's units in release order, dependencies first. An
  /// unsatisfied prerequisite reports RK-DEP-001/002 and drops its edge, so
  /// the order stays best-effort while the diagnostics refuse the release.
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
        remedy: 'break the first-party dependency cycle involving: '
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
          .where((value) =>
              !settled.contains(value) &&
              dependencies(value).every(settled.contains))
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
      value = dependencies(value)
          .firstWhere((dependency) => !settled.contains(dependency));
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
