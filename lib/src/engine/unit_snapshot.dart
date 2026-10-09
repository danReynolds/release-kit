import '../targets/target_module.dart';
import 'diagnostic.dart';
import 'inspect.dart';
import 'publish_target.dart';
import 'release_stage.dart';
import 'resolve.dart';
import 'stage_inspection.dart';
import 'unit_release.dart';
import 'verdict.dart';

/// One unit's public and private state, read once.
///
/// `rk status` shows it and `rk release` decides from it, so the two answer
/// every question about a unit the same way: what each destination holds,
/// what the stage holds, whether a partial release needs the exact stage it
/// no longer has, and which prerequisites this repository publishes first.
final class UnitSnapshot {
  UnitSnapshot._({
    required this.release,
    required Iterable<Diagnostic> releaseProblems,
    required this.inspector,
    required this.stage,
    required this.stageInspection,
    required this.stageError,
  }) : releaseProblems = List.unmodifiable(releaseProblems);

  /// Starts every read [unit] needs — each step's destination, each lane's
  /// history — and returns at once, so a caller can start every unit's reads
  /// before awaiting any. [stageFor] is asked only of a source with a commit
  /// ([hasCommit]): a stage is named by its commit. [repository] is the
  /// `owner/name` the targets are published under.
  factory UnitSnapshot.start(
    ResolvedUnit unit, {
    required Resolution resolution,
    required Inspector inspector,
    required String? repository,
    required bool hasCommit,
    ReleaseStage Function(ResolvedUnit unit)? stageFor,
  }) {
    final releaseProblems = Diagnostics();
    final release = UnitRelease.derive(
      unit,
      resolution,
      repository: repository,
      problems: releaseProblems,
    );
    ReleaseStage? stage;
    StageInspection? inspection;
    Object? error;
    if (hasCommit && stageFor != null) {
      try {
        stage = stageFor(unit);
        inspection = stage.inspect();
      } on Object catch (caught) {
        error = caught;
      }
    }
    final snapshot = UnitSnapshot._(
      release: release,
      releaseProblems: releaseProblems.found,
      inspector: inspector,
      stage: stage,
      stageInspection: inspection,
      stageError: error,
    );
    snapshot.reads = {
      for (final step in release.steps) step.id: snapshot._read(step),
    };
    snapshot.historyReads = {
      for (final target in release.targets)
        target.id: inspector.readHistory(target, unit),
    };
    return snapshot;
  }

  final UnitRelease release;
  ResolvedUnit get unit => release.unit;

  /// What deriving [release] refused: a dependency rk cannot order or read.
  final List<Diagnostic> releaseProblems;

  /// The public targets, in release order.
  List<Target> get targets => release.targets;
  final Inspector inspector;

  /// This commit's stage; null without a commit, or when it could not be
  /// read ([stageError]).
  final ReleaseStage? stage;
  final StageInspection? stageInspection;
  final Object? stageError;

  /// Each step's read as it arrives, by step id.
  late final Map<String, Future<Inspection>> reads;

  /// Each public target's history as it arrives, by step id. Null history
  /// means the target keeps none: its candidate read carries its version.
  late final Map<String, Future<TargetHistory?>> historyReads;

  /// What every step's read found, by step id. Set by [settle].
  late final Map<String, Inspection> states;
  late final Map<String, TargetHistory?> histories;

  /// The names this release would claim for the first time.
  late final List<TargetClaim> claims;

  /// What the lanes' histories refuse, and what the tag guards do.
  late final List<Diagnostic> historyProblems;
  late final List<Diagnostic> tagProblems;

  /// Waits for every read, then records what they found.
  Future<void> settle() async {
    final steps = release.steps.toList();
    final read = await Future.wait([for (final step in steps) reads[step.id]!]);
    states = Map.unmodifiable({
      for (final (index, step) in steps.indexed) step.id: read[index],
    });
    final latest = await Future.wait([
      for (final target in targets) historyReads[target.id]!,
    ]);
    histories = Map.unmodifiable({
      for (final (index, target) in targets.indexed) target.id: latest[index],
    });
    final problems = Diagnostics();
    final history = Inspector.historyFindings([
      for (final (index, target) in targets.indexed) (target, latest[index]),
    ], problems);
    claims = history.claims;
    historyProblems = List.unmodifiable(problems.found);
    tagProblems = List.unmodifiable(inspector.tagGuards(unit, release, states));
  }

  Future<Inspection> _read(Step step) async {
    if (step.kind == StepKind.completeStage) return stageState;
    if (step.phase == StepPhase.stage) {
      return stageReusable
          ? const Inspection.exact(detail: 'validated in the release stage')
          : const Inspection.unknown('local work, decided when it runs');
    }
    try {
      return await inspector.inspect(step, unit);
    } on Object catch (error) {
      return Inspection.unknown('the target read failed: $error');
    }
  }

  /// What the stage holds, as the complete-stage step reads it.
  Inspection get stageState {
    if (stageError case final error?) {
      return Inspection.unknown('the release stage could not be read: $error');
    }
    return stageInspection?.asInspection ??
        const Inspection.absent(detail: 'not staged');
  }

  /// Why this unit's stage could not be read at all, when it could not.
  Diagnostic? get stageReadProblem => stageError == null
      ? null
      : Diagnostic(
          code: 'RK-STAGE-002',
          message: 'the release stage could not be inspected',
          remedy:
              'fix the recorded stage read error, then rebuild it with '
              'rk stage ${unit.name}',
          evidence: '$stageError',
        );

  bool get stageReusable => stageInspection?.reusable == true;

  /// Every public target is already where this release puts it.
  bool get released =>
      targets.isNotEmpty &&
      targets.every((target) => states[target.id]!.isExact);

  /// The public targets this release still publishes.
  List<Target> get remaining => [
    for (final target in targets)
      if (!states[target.id]!.isExact) target,
  ];

  /// Whether an earlier commit released this version. It is public from
  /// that commit's stage, not from one this commit could have lost: what
  /// remains of it is finished there (RK-GIT-009).
  bool get releasedElsewhere =>
      targets.any((target) => states[target.id]!.releasedFrom != null);

  /// Whether public bytes already bind this unit's stage, and it is gone:
  /// built assets partly published on a GitHub release or in a formula.
  ///
  /// Only built release assets bind a stage: on a GitHub release, in a
  /// Homebrew formula that names their hashes, and in the release manifest a
  /// tag annotation records. A unit without them stages the same manifest
  /// again from its commit, and a published package binds nothing.
  bool get partialStageLoss =>
      !stageReusable &&
      !releasedElsewhere &&
      unit.buildsReleaseAssets &&
      targets.any(
        (target) =>
            target.target != PublishTarget.pubDev && states[target.id]!.isExact,
      );

  /// Whether every target a unit has left can finish from authenticated
  /// public inputs without its stage, as a moving channel may. One versioned
  /// publication that still needs bytes keeps the stage recovery-critical.
  bool get recoversWithoutStage =>
      !stageReusable &&
      remaining.isNotEmpty &&
      remaining.every((target) {
        final state = states[target.id]!;
        return state.isAbsent &&
            inspector.targets
                .moduleFor(target.target)
                .recoversWithoutStage(state);
      });

  /// Whether a partial release needs the exact stage it no longer has, when
  /// [recovering] says whether recovery from public inputs is on offer.
  /// Unread destinations cannot authorize rebuilding it.
  bool needsLostStage({required bool recovering}) =>
      partialStageLoss &&
      !(recovering && recoversWithoutStage) &&
      targets.any((target) {
        final state = states[target.id]!;
        return state.isAbsent || state.verdict == Verdict.unknown;
      });

  /// Why a partial release cannot finish here: see [needsLostStage].
  Diagnostic get lostStageProblem => Diagnostic(
    code: 'RK-STAGE-005',
    message: unit.shipsBinaries
        ? 'the partial binary release needs its exact stage'
        : 'the partial release needs its exact stage',
    remedy:
        'restore ${stage?.directory.path ?? '.rk/work/stages/<stage-id>'} '
        'from the machine that staged this release. '
        '${unit.shipsBinaries ? 'Signed or notarized bytes' : 'Recorded archive bytes'} '
        'cannot be recreated byte-for-byte after a public target has bound '
        'them.',
  );

  /// Whether this unit needs a package another unit of this repository has
  /// yet to put on pub.dev: only a repository release, which publishes that
  /// unit first, can release it.
  bool get releasesAfterSibling => release.requirements.any(
    (requirement) => releasedFirstBy(requirement) != null,
  );

  /// The project in this repository that publishes the package [step] needs,
  /// when it is not on pub.dev yet: a repository release publishes it first,
  /// so it orders this release rather than blocking it.
  ResolvedProject? releasedFirstBy(Step step) =>
      step is Requirement && states[step.id]!.isAbsent ? step.provider : null;
}
