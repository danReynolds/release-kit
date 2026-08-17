import 'diagnostic.dart';
import 'publish_target.dart';
import 'resolve.dart';
import 'version.dart';

/// The repository's Dart package dependency graph.
///
/// It is the one source of project publication order, cross-unit
/// prerequisites, and repository release order. Destination state stays out:
/// the checklist and inspector decide what work remains after this plan.
final class ReleaseDependencyPlan {
  ReleaseDependencyPlan(this.resolution)
      : _firstParty = {
          for (final project in resolution.allProjects) project.name: project,
        };

  final Resolution resolution;
  final Map<String, ResolvedProject> _firstParty;

  List<ResolvedProject> projects(
    ResolvedUnit unit,
    Diagnostics diagnostics,
  ) =>
      _ordered(
        unit.projects,
        (project) => [
          ...project.pubspec.dependencies.keys,
          ...project.pubspec.devDependencies.keys,
        ]
            .map((name) => _firstParty[name])
            .where((project) => project?.unitName == unit.name)
            .nonNulls,
        diagnostics,
        (blocked) => Diagnostic(
          code: 'RK-DEP-003',
          message: 'the packages in "${unit.name}" depend on each other in '
              'a circle, so there is no order that publishes them',
          source: unit.location,
          remedy: 'break the dependency cycle involving: '
              '${blocked.map((project) => project.name).join(', ')}',
        ),
      ) ??
      const [];

  List<ExternalPrerequisite> prerequisites(
    ResolvedUnit unit,
    Diagnostics diagnostics,
  ) {
    final result = <ExternalPrerequisite>[];
    final own = {for (final project in unit.projects) project.name};

    for (final project in unit.projects) {
      final required = {
        ...project.pubspec.dependencies,
        ...project.pubspec.devDependencies,
      };
      required.forEach((name, dependency) {
        final sibling = _firstParty[name];
        if (own.contains(name) ||
            sibling == null ||
            !sibling.publish.contains(PublishTarget.pubDev)) {
          return;
        }

        final satisfied = dependency.satisfiedBy(sibling.version);
        if (satisfied != true) {
          diagnostics.add(
            satisfied == false ? 'RK-DEP-001' : 'RK-DEP-002',
            satisfied == false
                ? '"${project.name}" requires $name ${dependency.constraint}, '
                    'and this repository releases $name at ${sibling.version}'
                : 'rk cannot tell whether "${project.name}" accepts $name '
                    '${sibling.version}: it requires '
                    '${dependency.describeRequirement()}',
            source: SourceLocation(project.pubspec.path, dependency.line),
            remedy: satisfied == false
                ? 'align the constraint with the version being released'
                : 'first-party dependencies use an exact or caret version, '
                    'so rk can check the release against them',
          );
          return;
        }

        result.add((
          dependent: project.name,
          package: name,
          version: sibling.version,
          declaredBy: sibling.unitName,
          coordinate: 'pub.dev/$name/${sibling.version}',
        ));
      });
    }
    return result;
  }

  List<ResolvedUnit>? units(Diagnostics diagnostics) {
    final needs = <String, Set<String>>{
      for (final unit in resolution.units)
        unit.name: {
          for (final prerequisite in prerequisites(unit, diagnostics))
            prerequisite.declaredBy,
        },
    };
    final byName = {for (final unit in resolution.units) unit.name: unit};
    return _ordered(
      resolution.units,
      (unit) => needs[unit.name]!.map((name) => byName[name]!),
      diagnostics,
      (blocked) => Diagnostic(
        code: 'RK-DEP-004',
        message: 'the release units depend on each other in a circle',
        remedy: 'break the first-party dependency cycle involving: '
            '${blocked.map((unit) => unit.name).join(', ')}',
      ),
    );
  }

  static List<T>? _ordered<T>(
    List<T> values,
    Iterable<T> Function(T value) dependencies,
    Diagnostics diagnostics,
    Diagnostic Function(List<T> blocked) cycle,
  ) {
    final ordered = <T>[];
    final settled = <T>{};
    while (ordered.length < values.length) {
      final ready = values.where((value) =>
          !settled.contains(value) &&
          dependencies(value).every(settled.contains));
      if (ready.isEmpty) {
        diagnostics.report(cycle([
          for (final value in values)
            if (!settled.contains(value)) value,
        ]));
        return null;
      }
      ordered.add(ready.first);
      settled.add(ready.first);
    }
    return ordered;
  }
}

/// A package released by another unit that must be live first.
typedef ExternalPrerequisite = ({
  String dependent,
  String package,
  Version version,
  String declaredBy,
  String coordinate,
});
