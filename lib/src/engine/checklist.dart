import 'assets.dart';
import 'diagnostic.dart';
import 'publish_target.dart';
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
    final localProducers = localProducerSteps(unit);
    steps.addAll(localProducers);

    final completeStage = Step(
      id: '${unit.name}/stage/complete',
      kind: StepKind.completeStage,
      unit: unit.name,
      summary: 'complete the local stage',
      needs: [for (final producer in localProducers) producer.id],
    );
    steps.add(completeStage);

    Step? tag;
    if (unit.publish.contains(PublishTarget.gitTag)) {
      tag = Step(
        id: '${unit.name}/tag/${unit.tag!}',
        kind: StepKind.tag,
        target: PublishTarget.gitTag,
        unit: unit.name,
        summary: 'tag ${unit.tag!}',
        needs: [completeStage.id],
      );
      steps.add(tag);
    }

    // Publish steps are emitted first so a sibling's prerequisite can be a
    // lookup rather than a second place that reconstructs an id format.
    final published = <String, Step>{};
    for (final project in publicationOrder) {
      if (!project.publish.contains(PublishTarget.pubDev)) continue;
      published[project.name] = Step(
        id: '${unit.name}/pub.dev/${project.name}@${project.version}',
        kind: StepKind.publishRegistry,
        target: PublishTarget.pubDev,
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
      final needs = <String>[tag?.id ?? completeStage.id];

      for (final name in project.pubspec.dependencies.keys) {
        final sibling = published[name];
        if (sibling != null && sibling.id != step.id) needs.add(sibling.id);
      }
      needs.addAll(waitsOn[project.name] ?? const []);

      steps.add(step.withNeeds(needs));
    }

    if (unit.publish.contains(PublishTarget.githubRelease)) {
      final release = Step(
        id: '${unit.name}/github-release/${unit.tag!}',
        kind: StepKind.publishRelease,
        target: PublishTarget.githubRelease,
        unit: unit.name,
        summary: 'publish ${ReleaseAssets.expectedForUnit(unit).length} assets '
            'to the ${unit.tag!} release',
        needs: [tag!.id, completeStage.id],
      );
      steps.add(release);

      for (final formulaProject in publicationOrder.where(
        (project) => project.publish.contains(PublishTarget.homebrew),
      )) {
        steps.add(
          Step(
            id: '${unit.name}/homebrew/${formulaProject.name}/'
                '${formulaProject.executable}',
            kind: StepKind.publishFormula,
            target: PublishTarget.homebrew,
            unit: unit.name,
            project: formulaProject.name,
            summary: 'update the ${formulaProject.executable} formula',
            needs: [release.id],
          ),
        );
      }
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

  /// The ordered local producer steps for [unit] — the one derivation of
  /// the pipeline's names, order, and dependency edges. The receipt contract
  /// and the coordinator both consume this list; nothing else respells it.
  static List<Step> localProducerSteps(ResolvedUnit unit) {
    final project = unit.binaryProject;
    return project == null ? const [] : _localBinarySteps(unit, project);
  }

  static List<Step> _localBinarySteps(
    ResolvedUnit unit,
    ResolvedProject project,
  ) {
    final steps = <Step>[];

    // Sorted, so the checklist and the receipt agree on one sequence
    // without a second ordering rule anywhere.
    for (final platform in [...project.binaryPlatforms]..sort()) {
      final macos = platform.startsWith('macos-');
      // Compiling and signing are one step: a signature is not resumable
      // work worth its own receipt, and one step means the checklist, the
      // receipt, and the validators all speak the same producer names.
      final build = Step(
        id: '${unit.name}/build/${project.name}/$platform',
        kind: StepKind.build,
        unit: unit.name,
        project: project.name,
        platform: platform,
        summary: macos
            ? 'build and sign ${project.executable} for $platform'
            : 'build ${project.executable} for $platform',
        needs: const [],
      );
      steps.add(build);

      var last = build.id;
      if (macos) {
        final notarize = Step(
          id: '${unit.name}/notarize/${project.name}/$platform',
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
        id: '${unit.name}/archive/${project.name}/$platform',
        kind: StepKind.archive,
        unit: unit.name,
        project: project.name,
        platform: platform,
        summary: 'archive $platform',
        needs: [last],
      );
      steps.add(archive);
    }

    return steps;
  }
}

enum StepKind {
  tag,

  /// Something another unit released, which must already be public.
  prerequisite,

  /// Compile the platform binary — and on macOS, sign it, as one step.
  build,
  notarize,
  archive,

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

extension StepKindFacts on StepKind {
  StepPhase get phase => switch (this) {
        StepKind.prerequisite => StepPhase.inspect,
        StepKind.build ||
        StepKind.notarize ||
        StepKind.archive ||
        StepKind.completeStage =>
          StepPhase.stage,
        StepKind.tag ||
        StepKind.publishRegistry ||
        StepKind.publishRelease ||
        StepKind.publishFormula =>
          StepPhase.publish,
      };

  bool get isPublic => phase == StepPhase.publish;

  bool get isPermanent => switch (this) {
        StepKind.publishRegistry => true,
        _ => false,
      };
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
    this.coordinate,
    this.target,
  }) {
    if (kind.isPublic && target == null) {
      throw ArgumentError.value(
        target,
        'target',
        'a public step must name its concrete target',
      );
    }
  }

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
        target: target,
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

  /// The concrete destination identity. [kind] describes lifecycle mechanics;
  /// several registry providers can therefore share one step kind without
  /// becoming the same target.
  final PublishTarget? target;

  /// One line, in the user's terms.
  final String summary;

  /// Ids of steps that must be done first.
  final List<String> needs;

  /// Whether this step changes something outside the workspace.
  bool get isPublic => kind.isPublic;

  StepPhase get phase => kind.phase;

  /// Whether this step's effect can never be taken back.
  ///
  /// Only a registry publication: pub.dev burns a version number forever, so a
  /// mistake there costs a version rather than a retry. Tags, releases, and
  /// formulas are still guarded against destructive repair, but they are not
  /// irrevocable provider acts, so marking them permanent would spend the
  /// operator's attention on the wrong steps.
  bool get isPermanent => kind.isPermanent;

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
      if (!sibling.publish.contains(PublishTarget.pubDev)) return;

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
