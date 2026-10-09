import 'assets.dart';
import 'diagnostic.dart';
import 'publish_target.dart';
import 'resolve.dart';

/// One unit's release, derived from `release.toml` and the manifests alone:
/// the packages it needs sibling units to put on pub.dev, the work its stage
/// does, the targets it publishes, and every file that leaves the stage.
///
/// Identical on every machine, computed offline, and carrying no reality:
/// what is already done is decided later, by reading destinations. The rules
/// are fixed, one for each of the four targets, so the release is built in
/// the order it is described rather than searched for.
final class UnitRelease {
  UnitRelease._({
    required this.unit,
    required this.repository,
    required this.requirements,
    required this.work,
    required this.targets,
    required this.assets,
    required this.artifacts,
  });

  /// [unit]'s release. What [resolution] cannot order — packages that depend
  /// on each other in a circle — is reported in [problems], and the release
  /// still describes every target, so status can show what the circle
  /// blocks.
  factory UnitRelease.derive(
    ResolvedUnit unit,
    Resolution resolution, {
    required String? repository,
    required Diagnostics problems,
  }) {
    final dependencies = resolution.dependencyPlan;

    // One requirement per distinct coordinate — two dependents on the same
    // package are one fact about the world, not two — and every dependent
    // waits on each of its own. They are read first: they can refuse an
    // impossible release before any work spends time or credentials.
    final requirements = <String, Requirement>{};
    final waitsOn = <String, List<Requirement>>{};
    for (final prerequisite in dependencies.prerequisites(unit, problems)) {
      final requirement = requirements.putIfAbsent(
        prerequisite.coordinate,
        () => Requirement._(unit.name, prerequisite.provider),
      );
      (waitsOn[prerequisite.dependent] ??= []).add(requirement);
    }

    final publicationOrder = dependencies.projects(unit, problems);
    final packages = [
      for (final project in publicationOrder)
        if (project.publish.contains(PublishTarget.pubDev)) project,
    ];
    final tagName = unit.tag;
    final releases = unit.publish.contains(PublishTarget.githubRelease);
    // The configured Homebrew target is the stable channel. Prerelease
    // archives remain available from GitHub without replacing its formula.
    final formulas = [
      if (releases && !unit.version.isPrerelease)
        for (final project in publicationOrder)
          if (project.publish.contains(PublishTarget.homebrew)) project,
    ];

    // The stage's work, in the one order the receipt, the plan and the
    // runner share: each package's archive, by name; the release notes; the
    // project's own build, or each platform's build, notarization and
    // archive; each formula, once its archives exist; and the barrier.
    final archives = {
      for (final project in [
        ...packages,
      ]..sort((a, b) => a.name.compareTo(b.name)))
        project.name: Work._target(
          unit.name,
          'pub-archive:${project.name}',
          summary: 'package archive',
          project: project,
          target: PublishTarget.pubDev,
          outputs: [ReleaseAssets.pubArchivePath(project)],
        ),
    };
    final notes = releases
        ? Work._target(
            unit.name,
            'release-notes',
            summary: 'release notes',
            target: PublishTarget.githubRelease,
            outputs: const ['release-notes.md'],
          )
        : null;
    final local = _localWork(unit);
    final formulaWork = {
      for (final project in [
        ...formulas,
      ]..sort((a, b) => a.name.compareTo(b.name)))
        project.name: Work._target(
          unit.name,
          'homebrew-formula:${project.name}',
          summary: 'Homebrew formula',
          project: project,
          target: PublishTarget.homebrew,
          outputs: [ReleaseAssets.formulaPath(project)],
          inputs: [
            for (final platform in project.binaryPlatforms)
              local.singleWhere(
                (work) =>
                    work.kind == StepKind.archive &&
                    work.project == project &&
                    work.platform == platform,
              ),
          ],
        ),
    };
    final targetWork = [...archives.values, ?notes, ...formulaWork.values];
    final barrier = Work._(
      id: '${unit.name}/stage/complete',
      unit: unit.name,
      kind: StepKind.completeStage,
      name: 'complete-stage',
      summary: 'complete the local stage',
      outputs: const [ReleaseAssets.manifest],
      // Target work by its name, then local work in order: the plan shows
      // the barrier waiting on all of it.
      inputs: [
        ...[...targetWork]..sort((a, b) => a.name.compareTo(b.name)),
        ...local,
      ],
      needs: local,
    );
    final work = [
      ...archives.values,
      ?notes,
      ...local,
      ...formulaWork.values,
      barrier,
    ];

    // Every file that leaves the stage: what each target publishes, and the
    // manifest the tag binds.
    final published = <Artifact>[
      for (final asset in ReleaseAssets.bundleFor(unit))
        for (final work in local)
          if (work.outputs.contains(asset.stagedPath))
            Artifact._(asset.stagedPath, name: asset.publicName, madeBy: work),
    ];
    final manifest = Artifact._(
      ReleaseAssets.manifest,
      name: ReleaseAssets.manifest,
      madeBy: barrier,
    );
    Artifact made(Work work) => Artifact._(
      work.outputs.single,
      name: work.target == PublishTarget.homebrew
          ? ReleaseAssets.formulaName(work.project!.executable!)
          : null,
      madeBy: work,
    );

    final targets = <Target>[];
    final tag = unit.publish.contains(PublishTarget.gitTag)
        ? Target._(
            id: '${unit.name}/tag/$tagName',
            unit: unit.name,
            kind: StepKind.tag,
            target: PublishTarget.gitTag,
            summary: 'tag $tagName',
            label: 'Git tag',
            kindLabel: 'Git tag',
            identity: tagName!,
            planNote: tagName,
            coordinate: tagName,
            targetVersion: unit.version.canonical,
            // The tag binds the manifest digest in its annotation; it does
            // not host a file named release-manifest.json. Binary releases
            // publish that file on GitHub. A pub-only release is recovered
            // from its peeled source commit plus pub.dev's archive.
            uses: unit.buildsReleaseAssets
                ? '${ReleaseAssets.manifest} from GitHub Release'
                : null,
          )
        : null;
    if (tag != null) {
      tag.needs = [barrier];
      targets.add(tag);
    }

    final byPackage = <String, Target>{
      for (final project in packages)
        project.name: Target._(
          id: '${unit.name}/pub.dev/${project.name}@${project.version}',
          unit: unit.name,
          kind: StepKind.publishRegistry,
          target: PublishTarget.pubDev,
          project: project,
          summary: 'publish ${project.name} ${project.version} to pub.dev',
          label: 'pub.dev · ${project.name}',
          kindLabel: 'pub.dev',
          identity: project.name,
          planNote: '${project.name} ${project.version.canonical}',
          coordinate: project.name,
          targetVersion: project.version.canonical,
          permanenceNotice:
              'pub.dev never deletes a version. a version can be retracted, '
              'which hides it and removes nothing.',
          // pub publishes the staged archive under its own name: there is no
          // public file name to show for this target.
          files: [made(archives[project.name]!)],
          preparedBy: archives[project.name],
        ),
    };
    for (final project in packages) {
      final target = byPackage[project.name]!;
      // The same requirements as the order; development inputs are never
      // public prerequisites.
      target.needs = [
        tag ?? barrier,
        for (final provider in {...dependencies.requires(project)})
          ?byPackage[provider.name],
        ...?waitsOn[project.name],
      ];
      targets.add(target);
    }

    if (releases) {
      final expected = ReleaseAssets.expectedForUnit(unit);
      final coordinate = repository == null
          ? tagName!
          : '$repository/releases/tag/$tagName';
      final github = Target._(
        id: '${unit.name}/github-release/$tagName',
        unit: unit.name,
        kind: StepKind.publishRelease,
        target: PublishTarget.githubRelease,
        summary: 'publish ${expected.length} assets to the $tagName release',
        label: repository == null
            ? 'GitHub Release'
            : 'GitHub Release · $repository',
        kindLabel: 'GitHub Release',
        // Without an origin there is no repository to name, and echoing the
        // tag here would print the Git tag row's identity twice.
        identity: repository ?? 'no origin remote',
        planNote:
            '${expected.length} asset${expected.length == 1 ? '' : 's'} '
            'to $coordinate',
        coordinate: coordinate,
        targetVersion: unit.version.canonical,
        files: [...published, manifest, made(notes!)],
        preparedBy: notes,
      )..needs = [?tag];
      targets.add(github);

      for (final project in formulas) {
        final executable = project.executable!;
        final tap = repository == null
            ? unit.homebrewTap
            : unit.tapFor(repository);
        final formula = ReleaseAssets.formulaName(executable);
        targets.add(
          Target._(
            id: '${unit.name}/homebrew/${project.name}/$executable',
            unit: unit.name,
            kind: StepKind.publishHomebrew,
            target: PublishTarget.homebrew,
            project: project,
            summary: 'update the $executable formula',
            label: tap == null ? 'Homebrew' : 'Homebrew · $tap',
            kindLabel: 'Homebrew',
            identity: tap ?? 'no tap configured',
            planNote: '$executable formula',
            coordinate: tap == null
                ? 'Formula/$formula'
                : '$tap/Formula/$formula',
            targetVersion: project.version.canonical,
            uses: '$formula bound in the release manifest',
            files: [made(formulaWork[project.name]!)],
            preparedBy: formulaWork[project.name],
          )..needs = [github],
        );
      }
    }

    return UnitRelease._(
      unit: unit,
      repository: repository,
      requirements: List.unmodifiable(requirements.values),
      work: List.unmodifiable(work),
      targets: List.unmodifiable(targets),
      assets: List.unmodifiable(published),
      artifacts: List.unmodifiable([
        ...published,
        manifest,
        for (final work in targetWork) made(work),
      ]),
    );
  }

  /// Every unit of [resolution], in release order. Null when the units
  /// cannot be ordered or a unit cannot be derived: [problems] says why.
  static List<UnitRelease>? all(
    Resolution resolution, {
    required String? repository,
    required Diagnostics problems,
  }) {
    final ordered = resolution.dependencyPlan.units(problems);
    if (problems.isNotEmpty) return null;
    final releases = <UnitRelease>[];
    for (final unit in ordered) {
      releases.add(
        UnitRelease.derive(
          unit,
          resolution,
          repository: repository,
          problems: problems,
        ),
      );
      if (problems.isNotEmpty) return null;
    }
    return List.unmodifiable(releases);
  }

  /// The project's own build is one step: rk cannot divide a command it does
  /// not know, and its assets are only ever made together. A binary is
  /// built — and on macOS signed, as one step — then notarized on macOS, then
  /// archived, platform by platform in sorted order.
  static List<Work> _localWork(ResolvedUnit unit) {
    if (unit.assetProject case final built?) {
      return [
        Work._(
          id: '${unit.name}/build/${built.name}',
          unit: unit.name,
          kind: StepKind.buildAssets,
          name: 'assets:${built.name}',
          project: built,
          summary: 'build the release assets',
          outputs: ReleaseAssets.assetOutputs(built),
        ),
      ];
    }
    final project = unit.binaryProject;
    if (project == null) return const [];
    final work = <Work>[];
    for (final platform in [...project.binaryPlatforms]..sort()) {
      final macos = platform.startsWith('macos-');
      final coordinate = '${project.name}/$platform';
      final receipt = '${project.name}:$platform';
      final build = Work._(
        id: '${unit.name}/build/$coordinate',
        unit: unit.name,
        kind: StepKind.build,
        name: 'build:$receipt',
        project: project,
        platform: platform,
        summary: macos
            ? 'build and sign ${project.executable} for $platform'
            : 'build ${project.executable} for $platform',
        outputs: ReleaseAssets.binaryOutputs(project, platform),
      );
      // Apple's verdict is evidence; notarization adds no file.
      final notarize = macos
          ? Work._(
              id: '${unit.name}/notarize/$coordinate',
              unit: unit.name,
              kind: StepKind.notarize,
              name: 'notarize:$receipt',
              project: project,
              platform: platform,
              summary: 'notarize $platform',
              inputs: [build],
              needs: [build],
            )
          : null;
      final archive = Work._(
        id: '${unit.name}/archive/$coordinate',
        unit: unit.name,
        kind: StepKind.archive,
        name: 'archive:$receipt',
        project: project,
        platform: platform,
        summary: 'archive $platform',
        outputs: [ReleaseAssets.archivePath(project, platform)],
        inputs: [build, ?notarize],
        needs: [notarize ?? build],
      );
      work.addAll([build, ?notarize, archive]);
    }
    return work;
  }

  final ResolvedUnit unit;

  /// The `owner/name` the targets are published under; null without an
  /// origin.
  final String? repository;

  /// The packages sibling units put on pub.dev, which must be live first.
  final List<Requirement> requirements;

  /// The stage's work in its canonical order; the last is the barrier.
  final List<Work> work;

  /// The tag, the pub.dev packages in dependency order, the GitHub release,
  /// and the Homebrew formula.
  final List<Target> targets;

  /// The files the release builds for its GitHub release, by public name:
  /// each platform's archive, or the assets a project's own build declares.
  /// A unit that publishes none still builds them, to keep locally.
  final List<Artifact> assets;

  /// Every file that leaves the stage: [assets], the manifest, and each
  /// target's own input.
  final List<Artifact> artifacts;

  /// Completes the stage once every other piece of work is recorded.
  Work get barrier => work.last;

  /// The steps a run reports: the requirements, the local work and its
  /// barrier, then the targets.
  Iterable<Step> get steps sync* {
    yield* requirements;
    for (final work in this.work) {
      if (work.kind != StepKind.targetStage) yield work;
    }
    yield* targets;
  }

  Step? step(String id) {
    for (final step in steps) {
      if (step.id == id) return step;
    }
    return null;
  }

  Target? get tag => _target(PublishTarget.gitTag);
  Target? get github => _target(PublishTarget.githubRelease);
  Target? get homebrew => _target(PublishTarget.homebrew);
  List<Target> get packages => [
    for (final target in targets)
      if (target.target == PublishTarget.pubDev) target,
  ];

  /// The target [work] prepares, when it is target work.
  Target? preparing(Work work) {
    for (final target in targets) {
      if (target.preparedBy == work) return target;
    }
    return null;
  }

  Target? _target(PublishTarget kind) {
    for (final target in targets) {
      if (target.target == kind) return target;
    }
    return null;
  }

  /// The rows `rk plan` shows, in release order: the requirements, the
  /// source every piece of work starts from, the work, then the targets.
  /// Work with no input of its own, and the barrier, start from the source.
  List<PlanNode> get planNodes {
    final source = PlanNode(
      id: '${unit.name}/stage/source',
      kind: StepKind.sourceSnapshot,
      summary: 'source snapshot',
      needs: const [],
    );
    return [
      for (final requirement in requirements)
        PlanNode(
          id: requirement.id,
          kind: requirement.kind,
          summary: requirement.summary,
          needs: const [],
          coordinate: requirement.coordinate,
          target: PublishTarget.pubDev,
          requiresUnit: requirement.provider.unitName,
        ),
      source,
      for (final work in work)
        PlanNode(
          id: work.id,
          kind: work.kind,
          summary: work == barrier
              ? 'complete and validate stage'
              : work.summary,
          needs: [
            if (work == barrier || work.inputs.isEmpty) source.id,
            for (final input in work.inputs) input.id,
          ],
          producer: work.name,
          project: work.project?.name,
          platform: work.platform,
          target: work.target,
          coordinate: preparing(work)?.coordinate,
          lane: work.target?.wireName,
        ),
      for (final target in targets)
        PlanNode(
          id: target.id,
          kind: target.kind,
          summary: target.summary,
          needs: [for (final need in target.needs) need.id],
          project: target.project?.name,
          target: target.target,
          coordinate: target.target == PublishTarget.pubDev
              ? '${target.project!.name}@${target.project!.version}'
              : target.coordinate,
          lane: target.target.wireName,
        ),
    ];
  }

  /// The rows staging fills, grouped by destination, each with the work
  /// that fills it.
  ///
  /// The steps rk runs and the files it produces are not the same list: four
  /// producers — build, sign, notarize, archive — make one macOS archive, and
  /// naming each of them told the operator about rk's internals rather than
  /// about their release. The rows here are the files, and a row narrates its
  /// own production: which work is filling it now, and when the stage settles
  /// what that work proved.
  ///
  /// A target that publishes no file of its own — a Git tag — has no group.
  /// pub.dev has one row per package: it uploads no file rk makes, but it does
  /// validate the staged source, and that check is the most common reason a
  /// release stops later than it should have. A formula fills its own row,
  /// under Homebrew; the release notes fill none.
  List<BoardGroup> get board {
    // A file's row is filled by the work that makes it. A platform's archive
    // is also filled by the build, signing and notarization it is made
    // from: the binary itself never leaves the stage.
    final makers = {
      for (final file in artifacts)
        if (file.name case final name?) name: file.madeBy,
    };
    List<Work> filling(String name) {
      final made = makers[name]!;
      return [if (made.kind == StepKind.archive) ...made.inputs, made];
    }

    final groups = <BoardGroup>[];
    for (final target in targets) {
      final rows = [
        for (final name in target.artifacts)
          BoardRow('${target.id}/$name', name, filling(name)),
        if (target.preparedBy case final work?
            when work.target == PublishTarget.pubDev)
          BoardRow('${target.id}/${work.name}/source', 'package archive', [
            work,
          ]),
      ];
      // Production order, not alphabetical. The manifest covers everything,
      // so listing it first would put the last row to fill at the top, where
      // a pending mark reads as skipped rather than as not yet.
      rows.sort(
        (left, right) => (left.name == ReleaseAssets.manifest ? 1 : 0)
            .compareTo(right.name == ReleaseAssets.manifest ? 1 : 0),
      );
      if (rows.isNotEmpty) groups.add(BoardGroup(target.label, rows));
    }

    // Archives no target publishes are the stage's own output, named as the
    // file is: the path inside the stage means nothing to a reader, and the
    // stage says where its archives are.
    final published = {for (final target in targets) ...target.artifacts};
    final local = [
      for (final Artifact(:name, :madeBy) in assets)
        if (madeBy.kind == StepKind.archive && !published.contains(name))
          BoardRow(
            'local/${madeBy.project!.name}/${madeBy.platform}',
            name!,
            filling(name),
          ),
    ];
    if (local.isNotEmpty) groups.add(BoardGroup('Local binaries', local));
    return groups;
  }
}

/// One row of `rk plan`, and what `--json` reports for it.
final class PlanNode {
  PlanNode({
    required this.id,
    required this.kind,
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
  final StepKind kind;
  final String summary;
  final List<String> needs;
  final String? producer;
  final String? project;
  final String? platform;
  final PublishTarget? target;
  final String? coordinate;
  final String? requiresUnit;
  final String? lane;

  StepPhase get phase => kind.phase;

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

/// The stage rows for one destination.
final class BoardGroup {
  BoardGroup(this.label, Iterable<BoardRow> rows)
    : rows = List.unmodifiable(rows);

  final String label;
  final List<BoardRow> rows;
}

/// One file staging makes, and the work that fills its row.
final class BoardRow {
  BoardRow(this.id, this.name, Iterable<Work> filledBy)
    : filledBy = List.unmodifiable(filledBy);

  final String id;
  final String name;
  final List<Work> filledBy;
}

/// What a step or plan row is. The names are what a `--json` caller keys on,
/// in `steps[]` and in `rk plan`, so they are frozen.
enum StepKind {
  /// Something another unit released, which must already be public.
  prerequisite,

  /// The commit's source, read once: every piece of work starts from it.
  /// Only `rk plan` shows it.
  sourceSnapshot,

  /// A target's own input to the stage: a package archive, the release
  /// notes, a formula.
  targetStage,

  /// Compile the platform binary — and on macOS, sign it, as one step.
  build,
  notarize,
  archive,

  /// Run a project's own build and keep the release assets it declares.
  buildAssets,

  /// The locally validated release receipt exists and is complete.
  completeStage,
  tag,
  publishRegistry,
  publishRelease,
  publishHomebrew,
}

/// The three safety phases a release crosses, in order.
///
/// Derived from [StepKind]: there is one source of truth, while callers can
/// enforce the stage-before-public boundary without depending on where a
/// step happened to be appended to a list.
enum StepPhase { inspect, stage, publish }

extension StepKindFacts on StepKind {
  StepPhase get phase => switch (this) {
    StepKind.prerequisite => StepPhase.inspect,
    StepKind.sourceSnapshot ||
    StepKind.build ||
    StepKind.notarize ||
    StepKind.archive ||
    StepKind.buildAssets ||
    StepKind.targetStage ||
    StepKind.completeStage => StepPhase.stage,
    StepKind.tag ||
    StepKind.publishRegistry ||
    StepKind.publishRelease ||
    StepKind.publishHomebrew => StepPhase.publish,
  };

  bool get isPublic => phase == StepPhase.publish;

  /// Only a registry publication can never be taken back: pub.dev burns a
  /// version number forever, so a mistake there costs a version rather than
  /// a retry. Tags, releases and formulae are still guarded against
  /// destructive repair, but marking them permanent would spend the
  /// operator's attention on the wrong steps.
  bool get isPermanent => this == StepKind.publishRegistry;
}

/// One entry in a release, decided from its id, the stage and destination
/// reality — never from state a previous step left in memory.
sealed class Step {
  Step({
    required this.id,
    required this.unit,
    required this.kind,
    required this.summary,
  });

  /// `<unit>/<adapter>/<coordinate>`, stable across runs.
  final String id;
  final String unit;
  final StepKind kind;

  /// One line, in the user's terms.
  final String summary;

  /// The steps that must be done first.
  List<Step> get needs;

  /// The destination a public step changes, or the one target work feeds.
  PublishTarget? get target => null;

  /// Whether this step changes something outside the workspace.
  bool get isPublic => kind.isPublic;

  /// Whether this step's effect can never be taken back.
  bool get isPermanent => kind.isPermanent;

  StepPhase get phase => kind.phase;

  @override
  String toString() => id;
}

/// A package another unit of this repository releases, which must be live
/// on pub.dev before this unit's packages that need it publish.
final class Requirement extends Step {
  Requirement._(String unit, this.provider)
    : super(
        id: '$unit/requires/pub.dev/${provider.name}/${provider.version}',
        unit: unit,
        kind: StepKind.prerequisite,
        summary: '${provider.name} ${provider.version} must be live on pub.dev',
      );

  /// The sibling project that publishes the package.
  final ResolvedProject provider;

  @override
  List<Step> get needs => const [];

  String get coordinate => 'pub.dev/${provider.name}/${provider.version}';
}

/// Work the stage does, recorded under [name] in its receipt.
final class Work extends Step {
  Work._({
    required super.id,
    required super.unit,
    required super.kind,
    required this.name,
    required super.summary,
    this.project,
    this.platform,
    this.target,
    this.outputs = const [],
    this.inputs = const [],
    this.needs = const [],
  });

  Work._target(
    String unit,
    String name, {
    required String summary,
    required PublishTarget target,
    ResolvedProject? project,
    required List<String> outputs,
    List<Work> inputs = const [],
  }) : this._(
         id: '$unit/stage/$name',
         unit: unit,
         kind: StepKind.targetStage,
         name: name,
         summary: summary,
         project: project,
         target: target,
         outputs: outputs,
         inputs: inputs,
       );

  /// The receipt's name for this work, such as `build:cli:macos-arm64`.
  final String name;
  final ResolvedProject? project;
  final String? platform;

  /// The target this work prepares, when it is target work.
  @override
  final PublishTarget? target;

  /// The stage paths this work writes; notarization writes none.
  final List<String> outputs;

  /// The work this needs first, as the plan shows it.
  final List<Work> inputs;

  @override
  final List<Step> needs;
}

/// One public target, and what it publishes.
final class Target extends Step {
  Target._({
    required super.id,
    required super.unit,
    required super.kind,
    required this.target,
    required super.summary,
    required this.label,
    required this.kindLabel,
    required this.identity,
    required this.planNote,
    required this.coordinate,
    required this.targetVersion,
    this.project,
    this.uses,
    this.permanenceNotice,
    this.files = const [],
    this.preparedBy,
  });

  @override
  final PublishTarget target;
  final ResolvedProject? project;

  /// The destination and the one thing it points at, said once.
  final String label;

  /// The kind of destination, without the thing it points at.
  final String kindLabel;

  /// What this target points at: a tag name, a package, a repository.
  final String identity;

  /// What arrives at this target, for the question that authorizes it.
  final String planNote;

  /// Where the target is published.
  final String coordinate;
  final String targetVersion;

  /// A concise reference to an artifact another target inventories.
  final String? uses;

  /// What an irreversible act here means, said before the yes.
  final String? permanenceNotice;

  /// The staged files this target publishes or binds.
  final List<Artifact> files;

  /// The work that prepares this target's input, when it has some.
  final Work? preparedBy;

  @override
  late final List<Step> needs;

  /// The public names of the files this target publishes, by name.
  late final List<String> artifacts = List.unmodifiable(
    [
      for (final file in files)
        if (file.name case final name?) name,
    ]..sort(),
  );

  /// A moving channel: the next update moves it, so a conflict read back
  /// after an act is not permanent.
  bool get moving => target == PublishTarget.homebrew;
}

/// One file that leaves the stage.
final class Artifact {
  Artifact._(this.path, {required this.name, required this.madeBy});

  /// Where the stage holds it.
  final String path;

  /// Its public name, when it is published under one.
  final String? name;
  final Work madeBy;
}
