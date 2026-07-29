import 'diagnostic.dart';
import 'resolve.dart';
import 'version.dart';

/// The ordered set of steps a release performs.
///
/// Derived purely from the manifests and `release.toml`: identical on every
/// machine, computed offline, and carrying no reality. What is already done is
/// decided later, by inspecting destinations.
class Checklist {
  Checklist({required this.unit, required this.steps});

  final ResolvedUnit unit;
  final List<Step> steps;

  Step? operator [](String id) {
    for (final step in steps) {
      if (step.id == id) return step;
    }
    return null;
  }

  /// Steps in dependency order, which is the order they may run in.
  Iterable<Step> get ordered => steps;

  static Checklist derive(ResolvedUnit unit, Resolution resolution) {
    final steps = <Step>[];

    // A tag names the release. It is created for an interactive release and
    // merely verified for a non-interactive one, but either way it precedes
    // everything, because a forge release attaches to it.
    steps.add(
      Step(
        id: '${unit.name}/tag/${unit.tag}',
        kind: StepKind.tag,
        unit: unit.name,
        summary: 'tag ${unit.tag}',
        needs: const [],
      ),
    );

    final publicationOrder = _publicationOrder(unit);

    for (final project in publicationOrder) {
      final prerequisites = _prerequisites(project, unit, resolution);

      if (project.channels.contains('pub.dev')) {
        steps.add(
          Step(
            id: '${unit.name}/pub.dev/${project.name}@${project.version}',
            kind: StepKind.publishRegistry,
            unit: unit.name,
            project: project.name,
            summary: 'publish ${project.name} ${project.version} to pub.dev',
            needs: [
              steps.first.id,
              ...prerequisites.map((p) => p.id),
            ],
          ),
        );
      }
    }

    // Binary channels belong to the single project that requested them.
    for (final project in publicationOrder) {
      if (!project.config.wantsBinaries) continue;
      steps.addAll(_binarySteps(unit, project, steps.first.id));
    }

    return Checklist(unit: unit, steps: steps);
  }

  /// Within a unit, a project that another depends on publishes first, so the
  /// dependent resolves for consumers the moment it lands.
  static List<ResolvedProject> _publicationOrder(ResolvedUnit unit) {
    final byName = {for (final p in unit.projects) p.name: p};
    final ordered = <ResolvedProject>[];
    final visiting = <String>{};

    void visit(ResolvedProject project) {
      if (ordered.contains(project)) return;
      if (!visiting.add(project.name)) return; // a cycle: leave the order be
      for (final name in project.pubspec.dependencies.keys) {
        final sibling = byName[name];
        if (sibling != null) visit(sibling);
      }
      for (final name in project.pubspec.devDependencies.keys) {
        final sibling = byName[name];
        if (sibling != null) visit(sibling);
      }
      visiting.remove(project.name);
      ordered.add(project);
    }

    for (final project in unit.projects) {
      visit(project);
    }
    return ordered;
  }

  /// Steps this project's publication waits on within the same unit.
  static List<Step> _prerequisites(
    ResolvedProject project,
    ResolvedUnit unit,
    Resolution resolution,
  ) {
    final result = <Step>[];
    final siblings = {for (final p in unit.projects) p.name: p};
    for (final name in project.pubspec.dependencies.keys) {
      final sibling = siblings[name];
      if (sibling == null || sibling.name == project.name) continue;
      if (!sibling.channels.contains('pub.dev')) continue;
      result.add(
        Step(
          id: '${unit.name}/pub.dev/$name@${sibling.version}',
          kind: StepKind.publishRegistry,
          unit: unit.name,
          project: name,
          summary: 'publish $name',
          needs: const [],
        ),
      );
    }
    return result;
  }

  static List<Step> _binarySteps(
    ResolvedUnit unit,
    ResolvedProject project,
    String tagStepId,
  ) {
    final steps = <Step>[];
    final built = <String>[];

    for (final platform in project.binaryPlatforms) {
      final build = Step(
        id: '${unit.name}/build/$platform',
        kind: StepKind.build,
        unit: unit.name,
        project: project.name,
        platform: platform,
        summary: 'build ${project.executable} for $platform',
        needs: [tagStepId],
      );
      steps.add(build);

      var last = build.id;
      if (platform.startsWith('macos-')) {
        final sign = Step(
          id: '${unit.name}/sign/$platform',
          kind: StepKind.sign,
          unit: unit.name,
          project: project.name,
          platform: platform,
          summary: 'sign $platform',
          needs: [last],
        );
        steps.add(sign);
        last = sign.id;

        final notarize = Step(
          id: '${unit.name}/notarize/$platform',
          kind: StepKind.notarize,
          unit: unit.name,
          project: project.name,
          platform: platform,
          summary: 'notarize $platform',
          needs: [last],
        );
        steps.add(notarize);
        last = notarize.id;
      }

      final archive = Step(
        id: '${unit.name}/archive/$platform',
        kind: StepKind.archive,
        unit: unit.name,
        project: project.name,
        platform: platform,
        summary: 'archive $platform',
        needs: [last],
      );
      steps.add(archive);
      built.add(archive.id);
    }

    final checksums = Step(
      id: '${unit.name}/checksums/SHA256SUMS',
      kind: StepKind.checksums,
      unit: unit.name,
      project: project.name,
      summary: 'checksums for ${built.length} archives',
      needs: built,
    );
    steps.add(checksums);

    final publish = Step(
      id: '${unit.name}/github-release/${unit.tag}',
      kind: StepKind.publishRelease,
      unit: unit.name,
      project: project.name,
      summary: 'publish ${built.length + 1} assets to '
          'the ${unit.tag} release',
      needs: [...built, checksums.id],
    );
    steps.add(publish);

    if (project.channels.contains('homebrew')) {
      steps.add(
        Step(
          id: '${unit.name}/homebrew/${project.executable}',
          kind: StepKind.publishFormula,
          unit: unit.name,
          project: project.name,
          summary: 'update the ${project.executable} formula',
          // The formula points at published assets, so it waits for the
          // release to be public rather than merely staged.
          needs: [publish.id],
        ),
      );
    }

    return steps;
  }
}

enum StepKind {
  tag,
  build,
  sign,
  notarize,
  archive,
  checksums,
  publishRegistry,
  publishRelease,
  publishFormula,
}

/// One entry in a checklist, executable in isolation from its id, the
/// workspace, and destination reality — never from state a previous step left
/// in memory.
class Step {
  Step({
    required this.id,
    required this.kind,
    required this.unit,
    required this.summary,
    required this.needs,
    this.project,
    this.platform,
  });

  /// `<unit>/<adapter>/<coordinate>`, stable across runs.
  final String id;

  final StepKind kind;
  final String unit;
  final String? project;
  final String? platform;

  /// One line, in the user's terms.
  final String summary;

  /// Ids of steps that must be done first.
  final List<String> needs;

  /// Whether this step changes something outside the workspace.
  bool get isPublic => switch (kind) {
        StepKind.tag ||
        StepKind.publishRegistry ||
        StepKind.publishRelease ||
        StepKind.publishFormula =>
          true,
        _ => false,
      };

  /// Whether this step's effect can never be taken back.
  bool get isPermanent => switch (kind) {
        StepKind.publishRegistry || StepKind.publishRelease => true,
        _ => false,
      };

  @override
  String toString() => id;
}

/// A dependency on a package released by another unit, which must be live and
/// verified before this unit's publication can proceed.
class ExternalPrerequisite {
  ExternalPrerequisite({
    required this.dependent,
    required this.package,
    required this.version,
    required this.constraint,
    required this.declaredBy,
  });

  final String dependent;
  final String package;

  /// The version required, read from the depended-on project's own manifest —
  /// never inferred from the pin's form, since an ordinary caret pin would
  /// otherwise derive nothing.
  final Version version;

  final String? constraint;

  /// The unit whose project declares the depended-on package.
  final String declaredBy;

  String get coordinate => 'pub.dev/$package/$version';
}

/// Prerequisites a unit has on packages released by other units.
List<ExternalPrerequisite> externalPrerequisites(
  ResolvedUnit unit,
  Resolution resolution,
  Diagnostics diagnostics,
) {
  final result = <ExternalPrerequisite>[];
  final own = {for (final p in unit.projects) p.name};

  // Every declared project, across every unit, is the repository's first-party
  // identity map: it is what lets a sibling be recognised rather than mistaken
  // for an ordinary hosted package.
  final firstParty = <String, ResolvedProject>{};
  for (final project in resolution.allProjects) {
    firstParty[project.name] = project;
  }

  for (final project in unit.projects) {
    project.pubspec.dependencies.forEach((name, dependency) {
      if (own.contains(name)) return; // ordered within the unit instead
      final sibling = firstParty[name];
      if (sibling == null) return; // an ordinary third-party dependency
      if (!sibling.channels.contains('pub.dev')) return;

      final satisfied = dependency.satisfiedBy(sibling.version);
      if (satisfied == false) {
        diagnostics.add(
          'RK-DEP-001',
          '"${project.name}" requires $name ${dependency.constraint}, and '
              'this repository releases $name at ${sibling.version}',
          source: SourceLocation(
            project.pubspec.path,
            dependency.line,
          ),
          remedy: 'align the constraint with the version being released',
        );
        return;
      }

      result.add(
        ExternalPrerequisite(
          dependent: project.name,
          package: name,
          version: sibling.version,
          constraint: dependency.constraint,
          declaredBy: sibling.unitName,
        ),
      );
    });
  }
  return result;
}
