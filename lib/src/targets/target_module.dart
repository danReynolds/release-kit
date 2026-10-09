import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/publish_target.dart';
import '../engine/registry.dart';
import '../engine/resolve.dart';
import '../engine/stage.dart';
import '../engine/stage_source.dart';
import '../engine/tools.dart';
import '../engine/unit_release.dart';
import '../engine/verdict.dart';
import '../engine/version.dart';
import '../output/output.dart';
import '../output/progress.dart';

/// What one read of a target finds: the state of this release there, and
/// the lane's public history. Null history means the target keeps none: its
/// state carries its version.
typedef TargetRead = ({Inspection state, TargetHistory? history});

/// One built-in public target's provider behaviour.
///
/// This is intentionally a closed application seam, not a runtime plugin API.
/// What a target is — its identity, its stage work, its files — is release
/// model data; a module reads, prepares and publishes it, and the core
/// release loop decides when.
abstract base class TargetModule {
  const TargetModule();

  PublishTarget get target;

  /// What [target]'s destination holds, and what its lane is already at:
  /// read for the snapshot, again before each act, and by default after
  /// one. [stage] is the unit's complete stage, when it has one: what a
  /// release would publish from.
  Future<TargetRead> read(
    TargetReadContext reads,
    ResolvedUnit unit,
    Target target, {
    Stage? stage,
  });

  /// Prepares [work], this target's input to the stage: what its release
  /// model says this target contributes.
  Future<Produced> prepare(StageRun run, Work work) =>
      throw StateError('${target.configName} contributes no stage work');

  /// Whether this host can publish to the target: the ambient checks before
  /// staging, and with [signIn], the native session, once per run after the
  /// yes. A target with credentials of its own must override this.
  Future<TargetReadiness> ready(
    TargetReadinessContext context,
    ResolvedUnit unit, {
    required bool signIn,
  }) async => const TargetReadiness();

  Future<TargetActOutcome> publish(
    TargetReleaseContext context,
    ResolvedUnit unit,
    Target target,
    Inspection before,
  );

  /// Reads back what [acted] did, when the act did not confirm it itself.
  Future<Inspection> confirm(
    TargetReleaseContext context,
    ResolvedUnit unit,
    Target target,
    TargetActOutcome acted,
  ) async =>
      (await read(context.reads, unit, target, stage: context.stage)).state;

  /// What [state] means in this target's terms: a conflict found before
  /// acting, or, with [acted], an act that did not settle exact — and the
  /// command to run next, when one helps. Core decides when either stops
  /// the release.
  ({Diagnostic diagnostic, String? next}) explain(
    ResolvedUnit unit,
    Target target,
    Inspection state, {
    TargetActOutcome? acted,
  });
}

/// How an act that did not settle exact reads when its target has no words
/// of its own for it: what the act, or the read after it, said.
({Diagnostic diagnostic, String? next}) unconfirmedAct(
  Target target,
  Inspection state,
  TargetActOutcome acted,
) => (
  diagnostic: Diagnostic(
    code: 'RK-REL-003',
    message:
        '${target.summary}: '
        '${acted.problem ?? state.detail ?? 'the public result could not be confirmed'}',
  ),
  next: null,
);

/// [history], or an unknown one when reading it threw: an unread history is
/// never taken for an empty one.
Future<TargetHistory> readHistory(
  Future<TargetHistory> Function() history,
) async {
  try {
    return await history();
  } on Object catch (error) {
    return TargetHistory(
      inspection: Inspection.unknown(
        'the latest public version could not be read: $error',
      ),
    );
  }
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
    required Target target,
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
    this.shared,
  });

  final RegistryReader? registry;
  final PublicationInspector? pubDev;
  final GitState git;
  final Tools? tools;
  final String? repository;

  /// Reads several targets share within one run, by key.
  final Map<String, Future<Object?>>? shared;

  /// [read], once per run for [key]: origin's tag listing answers every tag
  /// target's history and candidate.
  Future<T> once<T>(String key, Future<T> Function() read) {
    final memo = shared;
    if (memo == null) return read();
    return (memo[key] ??= read()).then((value) => value as T);
  }
}

/// One piece of stage work, and what it runs with.
final class StageRun {
  StageRun({
    required this.unit,
    required this.stage,
    required this.source,
    required this.tools,
    required this.git,
    required this.output,
    this.rows,
    Map<String, String> fromSource = const {},
  }) : fromSource = Map.unmodifiable(fromSource);

  final ResolvedUnit unit;

  /// The stage in progress: its receipt records the work done so far.
  final Stage stage;

  /// The source the stage is built from. Work that builds exports it into a
  /// directory of its own.
  final StageSourceSnapshot source;
  final Tools tools;
  final GitState git;
  String? get repository => git.originUrl;

  /// Where the work says what went wrong, and attaches what a tool said.
  final Output output;

  /// The stage rows this work fills, when it fills any.
  final ProgressHandle? rows;

  /// The repository packages a Pub package takes from this source when it
  /// is staged, by name, with each one's directory relative to the
  /// repository root: those it needs whose versions are not published yet,
  /// and those only its development needs.
  final Map<String, String> fromSource;

  void attach(String name, String contents) =>
      output.report.attach(name, contents);
}

/// What a piece of stage work found: the evidence its receipt keeps and the
/// warnings a reused stage says again; or that it failed, having said why,
/// and how the stage stops.
final class Produced {
  const Produced({this.evidence = const {}, this.warnings = const []})
    : halt = null;

  const Produced.failed([HaltKind this.halt = HaltKind.stoppedPartway])
    : evidence = const {},
      warnings = const [];

  final Map<String, Object?> evidence;
  final List<Diagnostic> warnings;
  final HaltKind? halt;

  bool get ok => halt == null;
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

  /// The complete stage the act publishes from; null when what is left
  /// finishes from public inputs alone.
  final Stage? stage;
  final ProgressHandle progress;

  /// Native inherited-stdio access, absent for JSON and redirected output.
  final ProgressInteractiveRunner? runInteractive;
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

/// Whether a target can be published from this host: ready, with a note
/// for its row, or refused, with the problem that says why.
final class TargetReadiness {
  const TargetReadiness({this.note = 'checked'}) : problem = null;

  const TargetReadiness.refused(Diagnostic this.problem) : note = 'refused';

  final String note;
  final Diagnostic? problem;
}

typedef ProgressInteractiveRunner =
    Future<int> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    });

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
  /// [problem] is the line the operator reads. This is the rest, carried
  /// into the one diagnostic that is reported, so the account of a
  /// half-finished publish survives the sentence summarizing it.
  final String? evidence;

  /// The public state the act itself established, when the provider's own
  /// answer is the read-back: Git accepts a tag push only as the exact
  /// object it was given. Null means the target is read back.
  final Inspection? confirmed;
}

/// A private provider-side effect that is not itself a published release.
enum TargetPrivateEffect { none, changed, uncertain }
