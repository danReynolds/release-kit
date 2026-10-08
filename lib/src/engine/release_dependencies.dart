import 'diagnostic.dart';
import 'publish_target.dart';
import 'pubspec.dart';
import 'resolve.dart';
import 'version.dart';

/// The repository's own packages that its packages depend on, read from
/// their pubspecs.
///
/// A hosted pub.dev requirement on a package this repository publishes, at a
/// version the requirement allows, is met by that package. Every other
/// requirement is Pub's to resolve from its registry, and a malformed one is
/// Pub's to report when it stages the package.
final class ReleaseDependencyPlan {
  ReleaseDependencyPlan(this.resolution);

  final Resolution resolution;

  late final Map<String, ResolvedProject> _onPubDev = {
    for (final project in resolution.allProjects)
      if (project.publish.contains(PublishTarget.pubDev)) project.name: project,
  };

  /// The repository's packages [project] requires: at runtime, or with
  /// [development], only to develop it. A name it also requires at runtime
  /// is a runtime requirement.
  List<ResolvedProject> _providers(
    ResolvedProject project, {
    bool development = false,
  }) {
    final runtime = project.pubspec.dependencies;
    final requirements = development
        ? {
            for (final MapEntry(:key, :value)
                in project.pubspec.devDependencies.entries)
              if (!runtime.containsKey(key)) key: value,
          }
        : runtime;
    return [
      for (final MapEntry(key: name, value: dependency) in requirements.entries)
        if (_onPubDev[name] case final provider?)
          if (provider != project &&
              _fromPubDev(dependency.hostedUrl) &&
              dependency.satisfiedBy(provider.version) == true)
            provider,
    ];
  }

  /// Whether a hosted requirement names pub.dev, where this repository's
  /// packages are published: by default, by its URL, or by its old name.
  static bool _fromPubDev(String? hostedUrl) =>
      hostedUrl == null ||
      isPubDevDestination(hostedUrl) ||
      canonicalPublishDestination(hostedUrl) == 'https://pub.dartlang.org';

  /// What [project]'s consumers need from this repository: nothing for a
  /// package that is not published to pub.dev.
  List<ResolvedProject> requires(ResolvedProject project) =>
      project.publish.contains(PublishTarget.pubDev)
      ? _providers(project)
      : const [];

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
    final sourced = _providers(project, development: true);
    final seen = {project.name, for (final sibling in sourced) sibling.name};
    final pending = [
      for (final owner in [project, ...sourced]) ...requires(owner),
    ];
    while (pending.isNotEmpty) {
      final provider = pending.removeLast();
      if (!seen.add(provider.name) ||
          await published(provider.name, provider.version.canonical)) {
        continue;
      }
      sourced.add(provider);
      pending.addAll(requires(provider));
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
    final needs = {
      for (final project in unit.projects)
        project: [
          for (final provider in requires(project))
            if (provider.unitName == unit.name) provider,
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
      for (final project in unit.projects)
        for (final provider in requires(project))
          if (provider.unitName != unit.name)
            ExternalPrerequisite(
              dependent: project.name,
              package: provider.name,
              version: provider.version,
              declaredBy: provider.unitName,
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
