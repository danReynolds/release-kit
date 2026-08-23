import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/publish_target.dart';
import '../engine/registry.dart';
import '../engine/release_stage.dart';
import '../engine/resolve.dart';
import '../engine/stage_contract.dart';
import '../engine/stage_receipt.dart';
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
    TargetPlan target, {
    bool fresh = false,
  }) async =>
      null;

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

  /// Acquires or refreshes the native publication session after the exact
  /// stage exists and before authorization.
  ///
  /// Returning false means the module already reported a refusal. Every
  /// module chooses explicitly, including destinations whose native tool has
  /// no separate session-acquisition command.
  TargetSessionProvider? get authentication => null;

  /// The effective destination bound before staging and checked after native
  /// credential acquisition. It is never serialized: an origin URL can carry
  /// credentials even though GitState normally redacts it for reports.
  String destinationBinding(
    TargetReadinessContext context,
    ResolvedUnit unit,
    List<TargetPlan> targets,
  ) {
    final coordinates = targets.map((item) => item.coordinate).toList()..sort();
    return [
      if (target.requiresGit) context.git.originUrl ?? 'unbound',
      ...coordinates,
    ].join('\n');
  }

  Future<TargetActOutcome> publish(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetPlan target,
    Inspection inspected,
  );

  Future<Inspection> confirmPublication(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetPlan target,
  ) =>
      inspectCandidate(context.reads, unit, target);

  /// Checks whether an exact publication is usable through its consumer path.
  ///
  /// Publication read-back remains the release boundary. This optional check
  /// is for providers whose accepted bytes can become usable later (for
  /// example a registry solver index or Apple's notarization ticket service).
  /// A pending answer is a warning, never permission to publish again.
  Future<TargetAvailabilityOutcome?> checkAvailability(
    TargetAvailabilityContext context,
    ResolvedUnit unit,
    TargetPlan target,
  ) async =>
      null;

  /// Classifies a provider operation that did not settle exact.
  ///
  /// Most append-only targets share this policy. A target overrides it only
  /// when it has a real provider-specific recovery operation or when a public
  /// conflict is repairable by a later run.
  Future<TargetFailure> classifyUnconfirmedPublication(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetPlan target,
    Inspection state,
    TargetActOutcome act, {
    required bool actedBefore,
  }) async {
    final details = <String>[
      if (act.diagnostic?.remedy != null) act.diagnostic!.remedy!,
      if (act.problem != null) act.problem!,
      if (act.privateEffectDetail != null) act.privateEffectDetail!,
      if (act.privateEffectDetail == null &&
          act.privateEffect == TargetPrivateEffect.changed)
        'private provider state changed; this step did not confirm a public '
            'release.',
      if (act.privateEffectDetail == null &&
          act.privateEffect == TargetPrivateEffect.uncertain)
        'private provider state may have changed; no public release was '
            'confirmed.',
      if (state.detail != null) state.detail!,
      ...state.evidence.entries.map((entry) => '${entry.key}: ${entry.value}'),
      if (act.permanent != null) act.permanent!,
    ];
    final immutableConflict = state.verdict == Verdict.conflict;
    final halt = act.permanent != null || immutableConflict
        ? HaltKind.actedAndUnfixable
        : act.mayHaveActed ||
                act.privateEffect == TargetPrivateEffect.uncertain ||
                state.verdict == Verdict.unknown
            ? HaltKind.lostTrack
            : act.privateEffect == TargetPrivateEffect.changed || actedBefore
                ? HaltKind.stoppedPartway
                : HaltKind.beforeActing;
    return TargetFailure(
      diagnostic: Diagnostic(
        code: act.diagnostic?.code ?? 'RK-REL-003',
        message: act.diagnostic?.message ??
            '${target.step.summary}: '
                '${act.problem ?? state.detail ?? 'the public result could not be confirmed'}',
        remedy: details.isEmpty
            ? 're-run; the shared destination inspection will classify the '
                'public target before any retry'
            : details.join('\n'),
        evidence: act.evidence ?? act.diagnostic?.evidence,
      ),
      halt: halt,
    );
  }

  TargetStage? stageInput({
    required ResolvedUnit unit,
    required TargetPlan target,
  }) =>
      null;

  /// Stable, non-secret identity of the public inputs authorizing recovery.
  ///
  /// Core freezes this before consent and compares it with the final
  /// observation immediately before the act. The adapter retains the actual
  /// authority and payload; orchestration needs only equality.
  String? stageRecoveryBinding(Inspection inspected) => null;
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
  })  : problems = List.unmodifiable(problems),
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
              message: '${target.label} is already at $version, ahead of the '
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
  });

  final RegistryReader? registry;
  final PublicationInspector? pubDev;
  final GitState git;
  final Tools? tools;
  final String? repository;
  final ReleaseStage Function(ResolvedUnit unit)? stageFor;

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
    required this.sourceStep,
    required Iterable<StageStep> priorSteps,
    required Map<String, ProgressHandle> progress,
  })  : priorSteps = List<StageStep>.unmodifiable(priorSteps),
        _attach = attach,
        _progress = Map.unmodifiable(progress);

  final StageContributionContract contract;
  final Tools tools;
  final GitState git;
  String? get repository => git.originUrl;
  final void Function(String name, String contents) _attach;
  void attach(String name, String contents) => _attach(name, contents);
  final ReleaseStage stage;
  Workspace get workspace => stage.directory.workspace;
  final StageStep sourceStep;
  final List<StageStep> priorSteps;
  final Map<String, ProgressHandle> _progress;

  ProgressHandle progress(String id) =>
      _progress[id] ?? (throw StateError('undeclared progress row "$id"'));
}

typedef TargetStageProducer = Future<TargetStageOutcome> Function(
  TargetStageContext context,
);

sealed class TargetStageOutcome {
  const TargetStageOutcome();

  List<Diagnostic> get warnings;
}

final class TargetStageSuccess extends TargetStageOutcome {
  TargetStageSuccess(
    StageStep step, {
    Iterable<Diagnostic> warnings = const [],
  })  : warnings = List.unmodifiable(warnings),
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
    inputs: step.inputs,
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
    Iterable<TargetStageProgress> progress = const [],
    required this.prepare,
  }) : progress = List.unmodifiable(progress) {
    final ids = <String>{};
    final outputs = <String>{};
    for (final view in this.progress) {
      if (!ids.add(view.id)) {
        throw ArgumentError('duplicate target stage progress id ${view.id}');
      }
      final output = view.output;
      if (output != null && !contract.step.outputs.containsKey(output)) {
        throw ArgumentError(
          '${contract.step.name} progress binds undeclared output $output',
        );
      }
      if (output != null && !outputs.add(output)) {
        throw ArgumentError(
          '${contract.step.name} progress binds output $output twice',
        );
      }
    }
  }

  final TargetPlan target;
  final StageContributionContract contract;
  final List<TargetStageProgress> progress;
  final TargetStageProducer prepare;
}

/// How one target-owned stage contribution appears in the shared board.
///
/// [artifact] binds a declared producer output to a public artifact row already
/// declared by the target expectation. A validation-only contribution supplies
/// [label] instead. Unbound outputs remain receipt-validated but do not invent
/// rows for private intermediates.
final class TargetStageProgress {
  const TargetStageProgress.row({
    required this.id,
    required this.label,
  })  : artifact = null,
        output = null,
        assert(id != ''),
        assert(label != '');

  const TargetStageProgress.output({
    required this.id,
    required this.output,
    required this.artifact,
  })  : label = null,
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
    required this.runInteractive,
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
  final ProgressInteractiveRunner runInteractive;
  Workspace get workspace => stage.directory.workspace;
  final Future<void> Function(Duration duration) wait;
  final Duration confirmDeadline;
  final Duration confirmInterval;
}

/// Runtime dependencies for an informational post-release consumer check.
final class TargetAvailabilityContext {
  const TargetAvailabilityContext({
    required this.tools,
    required this.stage,
  });

  final Tools tools;
  final ReleaseStage? stage;
}

sealed class TargetAvailabilityOutcome {
  const TargetAvailabilityOutcome();
}

final class TargetAvailable extends TargetAvailabilityOutcome {
  const TargetAvailable({this.note = 'available'});

  final String note;
}

final class TargetAvailabilityPending extends TargetAvailabilityOutcome {
  const TargetAvailabilityPending(this.diagnostic);

  final Diagnostic diagnostic;
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

typedef ProgressInteractiveRunner = Future<int> Function(
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

  /// Whether a usable session already exists, before [acquire] is called.
  ///
  /// Null means the question could not be answered, which is never read as
  /// either answer: rk leaves a session it cannot account for alone. Providers
  /// that keep no local session say nothing here.
  Future<bool?> established(TargetReadinessContext context) async => null;

  /// Ends a session that this run created, returning what to disclose.
  ///
  /// Only called when [established] answered false before [acquire] — a machine
  /// that was already signed in is left signed in, because a release should not
  /// change how the operator's tools are configured.
  Future<String?> restore(TargetReadinessContext context) async => null;
}

final class TargetSessionRequirement {
  const TargetSessionRequirement({
    required this.key,
    required this.provider,
    required this.targets,
  });

  final String key;
  final TargetSessionProvider provider;
  final List<TargetPlan> targets;
}

/// Provider-neutral facts returned by one target act.
final class TargetActOutcome {
  const TargetActOutcome({
    required this.ok,
    this.problem,
    this.mayHaveActed = false,
    this.privateEffect = TargetPrivateEffect.none,
    this.privateEffectDetail,
    this.permanent,
    this.diagnostic,
    this.coordinate,
    this.cleanupIfAbsent,
    this.successNote,
    this.includeInspectionDetail = false,
    this.reconciledNote,
    this.evidence,
  });

  final bool ok;
  final String? problem;
  final bool mayHaveActed;
  final TargetPrivateEffect privateEffect;
  final String? privateEffectDetail;
  final String? permanent;
  final Diagnostic? diagnostic;
  final String? coordinate;
  final TargetCleanup? cleanupIfAbsent;
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
}

/// A private provider-side effect that is not itself a published release.
enum TargetPrivateEffect { none, changed, uncertain }

/// A target-owned recovery action safe only after public absence is proven.
typedef TargetCleanup = Future<TargetCleanupResult> Function();

final class TargetCleanupResult {
  const TargetCleanupResult({required this.ok, required this.detail});

  final bool ok;
  final String detail;
}

/// The target's final classification after an act and authoritative read-back.
final class TargetFailure {
  const TargetFailure({
    required this.diagnostic,
    required this.halt,
    this.nextCommand,
  });

  final Diagnostic diagnostic;
  final HaltKind halt;
  bool get rerunHelps => halt != HaltKind.actedAndUnfixable;
  final String? nextCommand;
}
