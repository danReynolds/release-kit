import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/publish_target.dart';
import '../engine/registry.dart';
import '../engine/release_stage.dart';
import '../engine/resolve.dart';
import '../engine/stage_contract.dart';
import '../engine/stage_receipt.dart';
import '../engine/stage_source.dart';
import '../engine/targets.dart';
import '../engine/tools.dart';
import '../engine/verdict.dart';
import '../engine/version.dart';
import '../engine/workspace.dart';
import '../output/output.dart';
import '../output/progress.dart';

/// The tag coordinate guaranteed by a selected tag-backed target.
///
/// Untagged units legitimately carry no tag. Target derivation is the boundary
/// where configuration has already proved that a Git tag, GitHub Release, or
/// Homebrew target is selected and therefore has a tag prerequisite.
String requiredTargetTag(ResolvedUnit unit, PublishTarget target) {
  assert(_selects(unit, target));
  assert(unit.publish.contains(PublishTarget.gitTag));
  final tag = unit.tag;
  assert(tag != null);
  return tag!;
}

/// The tag pattern guaranteed by a selected tag-backed target.
String requiredTargetTagPattern(ResolvedUnit unit, PublishTarget target) {
  assert(_selects(unit, target));
  assert(unit.publish.contains(PublishTarget.gitTag));
  final pattern = unit.tagPattern;
  assert(pattern != null);
  return pattern!;
}

bool _selects(ResolvedUnit unit, PublishTarget target) =>
    target.scope == TargetScope.unit
    ? unit.publish.contains(target)
    : unit.projects.any((project) => project.publish.contains(target));

/// One built-in public target and the manifest-derived identity it reports.
///
/// This is intentionally a closed application seam, not a runtime plugin API.
/// Provider behavior grows behind these modules while checklist ordering stays
/// explicit in the release coordinator.
abstract base class TargetModule {
  const TargetModule();

  PublishTarget get target;

  TargetPlan plan({
    required ResolvedUnit unit,
    required Step step,
    String? repository,
  });

  Future<Inspection> inspectCandidate(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetPlan target,
  );

  /// Reads the lane's public version history, when it has one.
  ///
  /// Candidate inspection answers whether this release exists. History
  /// answers the separate question "what is this lane already at?" and owns
  /// any target-specific version refusal or first-publication claim. Null
  /// means candidate inspection already carries the lane's current version.
  Future<TargetHistory?> inspectHistory(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetPlan target,
  ) async => null;

  /// Explains one conflicting public observation in this target's terms.
  ///
  /// Core owns when a conflict blocks. The module owns what the provider
  /// conflict means and the safe next action; this keeps target-specific
  /// semantics out of generic status prose without adding lifecycle hooks.
  Diagnostic diagnoseConflict(
    ResolvedUnit unit,
    TargetPlan target,
    Inspection conflict,
  );

  ProgressActivity get publishActivity;

  /// Performs this target's ambient, fail-before-staging readiness check.
  ///
  /// Every target must choose this explicitly. A silent inherited success
  /// would let a new publisher omit credential checks and fail only after an
  /// earlier target had acted.
  Future<TargetReadinessOutcome> checkReadiness(
    TargetReadinessContext context,
    ResolvedUnit unit,
  );

  /// The native publication session this target needs, acquired once per
  /// run after the yes and before the first act that needs it.
  TargetSessionProvider? get authentication => null;

  Future<TargetActOutcome> publish(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetPlan target,
    Inspection inspected,
  );

  /// Reads back what [act] did, when the act did not confirm it itself.
  Future<Inspection> confirmPublication(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetPlan target,
    TargetActOutcome act,
  ) => inspectCandidate(context.reads, unit, target);

  /// The code and sentence for an act that did not settle exact and carried
  /// no diagnostic of its own, or whose result is a conflict, in this
  /// target's terms; and the command to run next, if one helps.
  ({String code, String message, String? next}) nameUnconfirmed(
    ResolvedUnit unit,
    TargetPlan target,
    Inspection state,
    TargetActOutcome act,
  ) => (
    code: 'RK-REL-003',
    message:
        '${target.step.summary}: '
        '${act.problem ?? state.detail ?? 'the public result could not be confirmed'}',
    next: null,
  );

  /// Whether a conflict read back after this target's act is permanent. A
  /// moving channel's is not: the next update moves it.
  bool get conflictIsPermanent => true;

  /// Classifies a provider operation that did not settle exact.
  Future<TargetFailure> classifyUnconfirmedPublication(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetPlan target,
    Inspection state,
    TargetActOutcome act, {
    required bool actedBefore,
  }) async {
    final conflict = state.verdict == Verdict.conflict;
    // The provider refused the act because a permanent target was already
    // something else: the conflict a fresh inspection would have found, with
    // the same advice.
    if (conflict && conflictIsPermanent && !act.ok && !act.mayHaveActed) {
      final advice = diagnoseConflict(unit, target, state);
      return TargetFailure(
        diagnostic: Diagnostic(
          code: advice.code,
          message: advice.message,
          source: advice.source,
          remedy: [?advice.remedy, ?act.problem].join('\n'),
          evidence: act.evidence ?? act.diagnostic?.evidence,
        ),
        halt: actedBefore
            ? HaltKind.actedAndUnfixable
            : HaltKind.unfixableByRerun,
      );
    }
    final given = act.diagnostic;
    final named = given == null || conflict
        ? nameUnconfirmed(unit, target, state, act)
        : (code: given.code, message: given.message, next: null);
    final details = [
      ?given?.remedy,
      ?act.problem,
      ?act.privateEffectDetail,
      if (act.privateEffectDetail == null &&
          act.privateEffect == TargetPrivateEffect.changed)
        'private provider state changed; this step did not confirm a public '
            'release.',
      if (act.privateEffectDetail == null &&
          act.privateEffect == TargetPrivateEffect.uncertain)
        'private provider state may have changed; no public release was '
            'confirmed.',
      ?state.detail,
      ...state.evidence.entries.map((entry) => '${entry.key}: ${entry.value}'),
    ];
    return TargetFailure(
      diagnostic: Diagnostic(
        code: named.code,
        message: named.message,
        remedy: details.isEmpty
            ? 're-run; the shared destination inspection will classify the '
                  'public target before any retry'
            : details.join('\n'),
        evidence: act.evidence ?? given?.evidence,
      ),
      halt: conflict
          ? (conflictIsPermanent
                ? HaltKind.actedAndUnfixable
                : HaltKind.stoppedPartway)
          : act.mayHaveActed ||
                act.privateEffect == TargetPrivateEffect.uncertain ||
                state.verdict == Verdict.unknown
          ? HaltKind.lostTrack
          : act.privateEffect == TargetPrivateEffect.changed || actedBefore
          ? HaltKind.stoppedPartway
          : HaltKind.beforeActing,
      nextCommand: named.next,
    );
  }

  TargetStage? stageInput({
    required ResolvedUnit unit,
    required TargetPlan target,
  }) => null;

  /// Whether [inspected] carries what this target needs to publish without
  /// its stage: authenticated public inputs a moving channel can finish
  /// from once the local stage is gone.
  bool recoversWithoutStage(Inspection inspected) => false;
}

/// One typed read of a target's independent public history.
///
/// The target translates provider payloads here. Core never recovers a
/// semantic version from an evidence-map key, asks a second hook to explain
/// that version, or guesses which target owns the resulting diagnostic.
final class TargetHistory {
  TargetHistory({
    required this.inspection,
    this.version,
    Iterable<Diagnostic> problems = const [],
    Iterable<TargetClaim> claims = const [],
  }) : problems = List.unmodifiable(problems),
       claims = List.unmodifiable(claims);

  factory TargetHistory.versioned({
    required Inspection inspection,
    required TargetPlan target,
    Diagnostic Function(Version publicVersion)? regressionDiagnostic,
    Iterable<Diagnostic> problems = const [],
    Iterable<TargetClaim> claims = const [],
  }) {
    final raw = inspection.evidence['version'];
    final version = raw == null ? null : Version.tryParse(raw);
    final found = [...problems];
    final intended = Version.tryParse(target.targetVersion);
    if (version != null && intended != null && version > intended) {
      found.add(
        regressionDiagnostic?.call(version) ??
            Diagnostic(
              code: 'RK-MONO-003',
              message:
                  '${target.label} is already at $version, ahead of the '
                  'target ${target.targetVersion}',
              remedy: 'a release moves forward — bump past $version',
            ),
      );
    }
    return TargetHistory(
      inspection: inspection,
      version: version,
      problems: found,
      claims: claims,
    );
  }

  final Inspection inspection;
  final Version? version;
  final List<Diagnostic> problems;
  final List<TargetClaim> claims;
}

/// Read-only dependencies shared by the four built-in target modules.
final class TargetReadContext {
  const TargetReadContext({
    required this.registry,
    required this.pubDev,
    required this.git,
    required this.tools,
    required this.repository,
    required this.stageFor,
    this.shared,
  });

  final RegistryReader? registry;
  final PublicationInspector? pubDev;
  final GitState git;
  final Tools? tools;
  final String? repository;
  final ReleaseStage Function(ResolvedUnit unit)? stageFor;

  /// Reads several targets share within one run, by key.
  final Map<String, Future<Object?>>? shared;

  /// [read], once per run for [key]: origin's tag listing answers every tag
  /// target's history and candidate.
  Future<T> once<T>(String key, Future<T> Function() read) {
    final memo = shared;
    if (memo == null) return read();
    return (memo[key] ??= read()).then((value) => value as T);
  }

  ReleaseStage? reusableStage(ResolvedUnit unit) {
    final factory = stageFor;
    if (factory == null) return null;
    try {
      final stage = factory(unit);
      return stage.inspect().reusable ? stage : null;
    } on Object {
      return null;
    }
  }
}

final class TargetStageContext {
  TargetStageContext({
    required this.contract,
    required this.tools,
    required this.git,
    required void Function(String name, String contents) attach,
    required this.stage,
    required this.source,
    required Iterable<StageStep> priorSteps,
    required Map<String, ProgressHandle> progress,
    Map<String, String> fromSource = const {},
  }) : priorSteps = List<StageStep>.unmodifiable(priorSteps),
       fromSource = Map.unmodifiable(fromSource),
       _attach = attach,
       _progress = Map.unmodifiable(progress);

  final StageStepContract contract;
  final Tools tools;
  final GitState git;
  String? get repository => git.originUrl;
  final void Function(String name, String contents) _attach;
  void attach(String name, String contents) => _attach(name, contents);
  final ReleaseStage stage;
  Workspace get workspace => stage.directory.workspace;

  /// The source the stage is built from. A producer that builds exports it
  /// into a directory of its own.
  final StageSourceSnapshot source;
  final List<StageStep> priorSteps;

  /// The repository packages a Pub package takes from this source when it
  /// is staged, by name, with each one's directory relative to the
  /// repository root: those it needs whose versions are not published yet,
  /// and those only its development needs.
  final Map<String, String> fromSource;
  final Map<String, ProgressHandle> _progress;

  ProgressHandle progress(String id) =>
      _progress[id] ?? (throw StateError('undeclared progress row "$id"'));
}

typedef TargetStageProducer =
    Future<TargetStageOutcome> Function(TargetStageContext context);

sealed class TargetStageOutcome {
  const TargetStageOutcome();

  List<Diagnostic> get warnings;
}

final class TargetStageSuccess extends TargetStageOutcome {
  TargetStageSuccess(StageStep step, {Iterable<Diagnostic> warnings = const []})
    : warnings = List.unmodifiable(warnings),
      step = _recordTargetStageWarnings(step, warnings);

  final StageStep step;
  @override
  final List<Diagnostic> warnings;
}

final class TargetStageFailure extends TargetStageOutcome {
  TargetStageFailure(
    this.diagnostic, {
    this.unit,
    Iterable<Diagnostic> warnings = const [],
  }) : warnings = List.unmodifiable(warnings);

  final Diagnostic diagnostic;
  final String? unit;
  @override
  final List<Diagnostic> warnings;
}

const _targetStageWarningsKey = 'rk_warnings';

StageStep _recordTargetStageWarnings(
  StageStep step,
  Iterable<Diagnostic> warnings,
) {
  final recorded = warnings.toList();
  if (recorded.isEmpty) return step;
  return StageStep(
    name: step.name,
    outputs: step.outputs,
    evidence: {
      ...step.evidence,
      _targetStageWarningsKey: [
        for (final warning in recorded)
          {
            'code': warning.code,
            'message': warning.message,
            if (warning.remedy != null) 'remedy': warning.remedy,
          },
      ],
    },
  );
}

/// Nonblocking target warnings preserved by a reusable stage receipt.
List<Diagnostic> recordedTargetStageWarnings(StageStep step) {
  final values = step.evidence[_targetStageWarningsKey];
  if (values is! List) return const [];
  return [
    for (final value in values)
      if (value is Map && value['code'] is String && value['message'] is String)
        Diagnostic(
          code: value['code'] as String,
          message: value['message'] as String,
          remedy: value['remedy'] is String ? value['remedy'] as String : null,
        ),
  ];
}

/// One optional, target-owned contribution to the reusable local stage.
///
/// Declaration, validation contract, and producer stay together so they
/// cannot drift across two lifecycle hooks.
final class TargetStage {
  TargetStage({
    required this.target,
    required this.contract,
    required String planLabel,
    Iterable<TargetStageProgress> progress = const [],
    required this.prepare,
  }) : planLabel = _planLabel(planLabel),
       progress = List.unmodifiable(progress) {
    final ids = <String>{};
    final outputs = <String>{};
    for (final view in this.progress) {
      if (!ids.add(view.id)) {
        throw ArgumentError('duplicate target stage progress id ${view.id}');
      }
      final output = view.output;
      if (output != null && !contract.outputs.containsKey(output)) {
        throw ArgumentError(
          '${contract.name} progress binds undeclared output $output',
        );
      }
      if (output != null && !outputs.add(output)) {
        throw ArgumentError(
          '${contract.name} progress binds output $output twice',
        );
      }
    }
  }

  final TargetPlan target;
  final StageStepContract contract;
  final String planLabel;
  final List<TargetStageProgress> progress;
  final TargetStageProducer prepare;

  static String _planLabel(String value) {
    final label = value.trim();
    if (label.isEmpty || label.contains('\n')) {
      throw ArgumentError('a target stage plan label must be one line');
    }
    return label;
  }
}

/// How one target-owned stage contribution appears in the shared board.
///
/// [artifact] binds a declared producer output to a public artifact row already
/// declared by the target expectation. A validation-only contribution supplies
/// [label] instead. Unbound outputs remain receipt-validated but do not invent
/// rows for private intermediates.
final class TargetStageProgress {
  const TargetStageProgress.row({required this.id, required this.label})
    : artifact = null,
      output = null,
      assert(id != ''),
      assert(label != '');

  const TargetStageProgress.output({
    required this.id,
    required this.output,
    required this.artifact,
  }) : label = null,
       assert(id != ''),
       assert(output != ''),
       assert(artifact != '');

  final String id;
  final String? label;
  final String? artifact;
  final String? output;
}

final class TargetClaim {
  const TargetClaim({
    required this.registrar,
    required this.name,
    required this.consequence,
  });

  final String registrar;
  final String name;
  final String consequence;
}

/// Runtime dependencies for one public target act.
///
/// The release coordinator owns ordering and authorization. A target owns its
/// provider transaction and reconciliation through the shared read path.
final class TargetReleaseContext {
  const TargetReleaseContext({
    required this.reads,
    required this.tools,
    required this.stage,
    required this.progress,
    this.runInteractive,
    required this.wait,
    required this.confirmDeadline,
    required this.confirmInterval,
  });

  final TargetReadContext reads;
  final Tools tools;
  GitState get git => reads.git;
  String? get repository => reads.repository;
  final ReleaseStage stage;
  final ProgressHandle progress;

  /// Native inherited-stdio access, absent for JSON and redirected output.
  final ProgressInteractiveRunner? runInteractive;
  Workspace get workspace => stage.directory.workspace;
  final Future<void> Function(Duration duration) wait;
  final Duration confirmDeadline;
  final Duration confirmInterval;
}

/// Dependencies shared by safe readiness and later session acquisition.
final class TargetReadinessContext {
  TargetReadinessContext({
    required this.tools,
    required this.git,
    required Map<String, String> environment,
    this.progress,
    this.runInteractive,
  }) : environment = Map.unmodifiable(environment);

  final Tools tools;
  final GitState git;
  final Map<String, String> environment;
  final ProgressHandle? progress;
  final ProgressInteractiveRunner? runInteractive;
}

sealed class TargetReadinessOutcome {
  const TargetReadinessOutcome();
}

final class TargetReady extends TargetReadinessOutcome {
  const TargetReady({this.note = 'checked'});

  final String note;
}

final class TargetNotReady extends TargetReadinessOutcome {
  const TargetNotReady(this.diagnostic, {this.unit});

  final Diagnostic diagnostic;
  final String? unit;
}

typedef ProgressInteractiveRunner =
    Future<int> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    });

abstract base class TargetSessionProvider {
  const TargetSessionProvider();

  String get id;
  ProgressActivity get activity;

  Future<TargetReadinessOutcome> acquire(
    TargetReadinessContext context,
    ResolvedUnit unit,
    List<TargetPlan> targets,
  );
}

/// Provider-neutral facts returned by one target act.
final class TargetActOutcome {
  const TargetActOutcome({
    required this.ok,
    this.problem,
    this.mayHaveActed = false,
    this.privateEffect = TargetPrivateEffect.none,
    this.privateEffectDetail,
    this.diagnostic,
    this.coordinate,
    this.successNote,
    this.includeInspectionDetail = false,
    this.reconciledNote,
    this.evidence,
    this.confirmed,
  });

  final bool ok;
  final String? problem;
  final bool mayHaveActed;
  final TargetPrivateEffect privateEffect;
  final String? privateEffectDetail;
  final Diagnostic? diagnostic;
  final String? coordinate;
  final String? successNote;
  final bool includeInspectionDetail;
  final String? reconciledNote;

  /// What the native tool said, when a tool is what failed.
  ///
  /// [problem] is the line the operator reads. This is the rest, carried to
  /// `classifyUnconfirmedPublication`, which builds the one diagnostic that
  /// is reported —
  /// so the account of a half-finished publish survives the sentence
  /// summarizing it.
  final String? evidence;

  /// The public state the act itself established, when the provider's own
  /// answer is the read-back: Git accepts a tag push only as the exact
  /// object it was given. Null means the target is read back.
  final Inspection? confirmed;
}

/// A private provider-side effect that is not itself a published release.
enum TargetPrivateEffect { none, changed, uncertain }

/// The target's final classification after an act and authoritative read-back.
final class TargetFailure {
  const TargetFailure({
    required this.diagnostic,
    required this.halt,
    this.nextCommand,
  });

  final Diagnostic diagnostic;
  final HaltKind halt;
  final String? nextCommand;
}
