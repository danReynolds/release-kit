import 'assets.dart';
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

  static Checklist derive(
    ResolvedUnit unit,
    Resolution resolution,
    Diagnostics diagnostics,
  ) {
    final steps = <Step>[];

    // A dependency released by another unit must already be public, so it is
    // an inspect-only step rather than something this release performs. Keep
    // these reads first: they can refuse an impossible release before local
    // producers spend time or credentials.
    // One step per distinct coordinate — two dependents on the same package
    // are one fact about the world, not two — and every dependent waits on
    // each of its own, not merely the last one seen.
    final byCoordinate = <String, Step>{};
    final waitsOn = <String, List<String>>{};

    for (final prerequisite
        in externalPrerequisites(unit, resolution, diagnostics)) {
      final id = '${unit.name}/requires/${prerequisite.coordinate}';
      final step = byCoordinate.putIfAbsent(
        prerequisite.coordinate,
        () => Step(
          id: id,
          kind: StepKind.prerequisite,
          unit: unit.name,
          coordinate: prerequisite.coordinate,
          summary: '${prerequisite.package} ${prerequisite.version} must be '
              'live on pub.dev',
          needs: const [],
        ),
      );
      (waitsOn[prerequisite.dependent] ??= []).add(step.id);
    }
    steps.addAll(byCoordinate.values);

    final publicationOrder = _publicationOrder(unit, diagnostics);

    // Every local producer runs before a public identity exists. Their output
    // is not permission to publish until the complete-stage barrier has
    // finalized and validated the package, notes and manifest preflight too.
    final localProducers = <Step>[];
    for (final project in publicationOrder) {
      if (!project.config.wantsBinaries) continue;
      localProducers.addAll(_localBinarySteps(unit, project));
    }
    steps.addAll(localProducers);

    final completeStage = Step(
      id: '${unit.name}/stage/complete',
      kind: StepKind.completeStage,
      unit: unit.name,
      summary: 'complete the local stage',
      needs: [for (final producer in localProducers) producer.id],
    );
    steps.add(completeStage);

    // The tag is the first public act. Even a unit without binary producers
    // gets a stage barrier: registry package, notes and manifest preparation
    // are finalized when the command executes that barrier.
    final tag = Step(
      id: '${unit.name}/tag/${unit.tag}',
      kind: StepKind.tag,
      unit: unit.name,
      summary: 'tag ${unit.tag}',
      needs: [completeStage.id],
    );
    steps.add(tag);

    // Publish steps are emitted first so a sibling's prerequisite can be a
    // lookup rather than a second place that reconstructs an id format.
    final published = <String, Step>{};
    for (final project in publicationOrder) {
      if (!project.channels.contains('pub.dev')) continue;
      published[project.name] = Step(
        id: '${unit.name}/pub.dev/${project.name}@${project.version}',
        kind: StepKind.publishRegistry,
        unit: unit.name,
        project: project.name,
        coordinate: '${project.name}@${project.version}',
        summary: 'publish ${project.name} ${project.version} to pub.dev',
        needs: const [],
      );
    }

    for (final project in publicationOrder) {
      final step = published[project.name];
      if (step == null) continue;
      final needs = <String>[tag.id];

      for (final name in project.pubspec.dependencies.keys) {
        final sibling = published[name];
        if (sibling != null && sibling.id != step.id) needs.add(sibling.id);
      }
      needs.addAll(waitsOn[project.name] ?? const []);

      steps.add(step.withNeeds(needs));
    }

    // Binary channels belong to the single project that requested them.
    for (final project in publicationOrder) {
      if (!project.config.wantsBinaries) continue;
      steps.addAll(
        _binaryPublicationSteps(
          unit,
          project,
          tag.id,
          completeStage.id,
        ),
      );
    }

    // A refused input — a dependency circle, say — legitimately has no order,
    // and its diagnostic is the answer rather than a crash.
    if (diagnostics.isEmpty) _checkGraph(steps);

    return Checklist(unit: unit, steps: steps);
  }

  /// A checklist whose contract is a stable id must not be able to emit two,
  /// and a step must never wait on one that comes later.
  ///
  /// Violations here are rk's own bugs, not the user's, so they throw rather
  /// than diagnose.
  static void _checkGraph(List<Step> steps) {
    final seen = <String>{};
    var phase = StepPhase.inspect;
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      if (step.phase.index < phase.index) {
        throw StateError('"${step.id}" moves from the ${phase.name} phase '
            'back to ${step.phase.name}');
      }
      phase = step.phase;
      if (!seen.add(step.id)) {
        throw StateError('two steps share the id "${step.id}"');
      }
      for (final need in step.needs) {
        final at = steps.indexWhere((s) => s.id == need);
        if (at < 0) {
          throw StateError('"${step.id}" waits on "$need", which is not a '
              'step in this checklist');
        }
        if (at > i) {
          throw StateError('"${step.id}" waits on "$need", which comes after '
              'it');
        }
      }
    }
  }

  /// Within a unit, a project that another depends on publishes first, so the
  /// dependent resolves for consumers the moment it lands.
  static List<ResolvedProject> _publicationOrder(
    ResolvedUnit unit,
    Diagnostics diagnostics,
  ) {
    final byName = {for (final p in unit.projects) p.name: p};
    final ordered = <ResolvedProject>[];
    final visiting = <String>{};

    void visit(ResolvedProject project) {
      if (ordered.contains(project)) return;
      if (!visiting.add(project.name)) {
        // Two packages that require each other cannot both publish second.
        diagnostics.add(
          'RK-DEP-003',
          'the packages in "${unit.name}" depend on each other in a circle, '
              'so there is no order that publishes them',
          source: unit.location,
          remedy: 'a cycle including "${project.name}" — break it before '
              'releasing',
        );
        return;
      }
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

  static List<Step> _localBinarySteps(
    ResolvedUnit unit,
    ResolvedProject project,
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
        needs: const [],
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

    return steps;
  }

  static List<Step> _binaryPublicationSteps(
    ResolvedUnit unit,
    ResolvedProject project,
    String tagStepId,
    String completeStageStepId,
  ) {
    final steps = <Step>[];

    final publish = Step(
      id: '${unit.name}/github-release/${unit.tag}',
      kind: StepKind.publishRelease,
      unit: unit.name,
      project: project.name,
      summary: 'publish ${ReleaseAssets.expectedFor(project).length} assets '
          'to the ${unit.tag} release',
      needs: [tagStepId, completeStageStepId],
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

  /// Something another unit released, which must already be public.
  prerequisite,
  build,
  sign,
  notarize,
  archive,
  checksums,

  /// The locally validated release receipt exists and is complete.
  completeStage,
  publishRegistry,
  publishRelease,
  publishFormula,
}

/// The three safety phases a checklist may cross, in order.
///
/// This is deliberately derived from [StepKind]: there is one source of
/// truth, while callers can enforce the stage-before-public boundary without
/// depending on where a step happened to be appended to a list.
enum StepPhase { inspect, stage, publish }

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
    this.coordinate,
  });

  /// The same step, waiting on [needs]. Steps are built before their edges are
  /// known, so an edge is added by rebuilding rather than by mutation.
  Step withNeeds(List<String> needs) => Step(
        id: id,
        kind: kind,
        unit: unit,
        summary: summary,
        needs: needs,
        project: project,
        platform: platform,
        coordinate: coordinate,
      );

  /// `<unit>/<adapter>/<coordinate>`, stable across runs.
  final String id;

  final StepKind kind;
  final String unit;
  final String? project;
  final String? platform;

  /// What this step acts on, so an executor never has to take an id apart to
  /// recover it.
  final String? coordinate;

  /// One line, in the user's terms.
  final String summary;

  /// Ids of steps that must be done first.
  final List<String> needs;

  /// Whether this step changes something outside the workspace.
  bool get isPublic => phase == StepPhase.publish;

  StepPhase get phase => switch (kind) {
        StepKind.prerequisite => StepPhase.inspect,
        StepKind.build ||
        StepKind.sign ||
        StepKind.notarize ||
        StepKind.archive ||
        StepKind.checksums ||
        StepKind.completeStage =>
          StepPhase.stage,
        StepKind.tag ||
        StepKind.publishRegistry ||
        StepKind.publishRelease ||
        StepKind.publishFormula =>
          StepPhase.publish,
      };

  /// Whether this step's effect can never be taken back.
  ///
  /// Only a registry publication: pub.dev burns a version number forever, so a
  /// mistake there costs a version rather than a retry. A release, its assets,
  /// a formula and even a tag can all be removed — rk deletes and recreates a
  /// wrong draft as a matter of course — and marking those permanent too would
  /// spend the operator's attention on the steps that do not need it.
  bool get isPermanent => switch (kind) {
        StepKind.publishRegistry => true,
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
    // Both kinds: a development dependency orders publication within a unit,
    // and the consumer resolve a release runs resolves them too, so a
    // coordinated bump must be refused before the work rather than at publish.
    final required = {
      ...project.pubspec.dependencies,
      ...project.pubspec.devDependencies,
    };
    required.forEach((name, dependency) {
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
          constraint: dependency.constraint,
          declaredBy: sibling.unitName,
        ),
      );
    });
  }
  return result;
}
