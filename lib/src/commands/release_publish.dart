import '../builds/macos_identity.dart';
import '../engine/canonical_json.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/inspect.dart';
import '../engine/publish_target.dart';
import '../engine/resolve.dart';
import '../engine/tools.dart';
import '../engine/unit_release.dart';
import '../engine/unit_snapshot.dart';
import '../engine/verdict.dart';
import '../output/output.dart';
import '../targets/target_module.dart';
import 'release_progress.dart';

enum ReleaseAction {
  notAttempted('not_attempted', 'not attempted'),
  alreadyPublished('already_published', 'already published'),
  completed('completed', 'completed'),
  failed('failed', 'failed');

  const ReleaseAction(this.wire, this.human);

  final String wire;
  final String human;
}

/// One unit's way through a release: what was read once, shared with
/// `rk status`, and what each phase settles for the next.
final class UnitRun {
  UnitRun(this.read);

  final UnitSnapshot read;

  /// Whether what this unit has left finishes from public inputs, without
  /// its stage.
  var recovering = false;

  /// The repository packages each of the unit's Pub packages takes from
  /// this source when staged: see [StageRun.fromSource].
  var fromSource = const <String, Map<String, String>>{};

  /// The identity its macOS build signs as: settled before the stage is
  /// built, or recorded in the stage reused. Null when it signs nothing.
  MacIdentity? identity;

  /// What the release has done at each target so far.
  late final actions = <Target, ReleaseAction>{
    for (final target in read.targets)
      target: read.states[target.id]!.isExact
          ? ReleaseAction.alreadyPublished
          : ReleaseAction.notAttempted,
  };
}

/// Owns the late, public half of a release.
///
/// Public state is read once before staging, and that snapshot is what one
/// question asks about. After the yes, each act reads its own target again,
/// checks the staged bytes it publishes, acts, and reads the result back.
/// Nothing the yes did not accept is published.
final class Publication {
  Publication({
    required this.inspector,
    required this.initialGit,
    required this.tools,
    required this.output,
    required this.refreshEnvironment,
    required this.wait,
    required this.confirm,
    required this.allowInteractiveTools,
    required this.confirmDeadline,
    required this.confirmInterval,
  });

  final Inspector inspector;
  final GitState initialGit;
  final Tools tools;
  final Output output;
  final Map<String, String> Function() refreshEnvironment;
  final Future<void> Function(Duration) wait;
  final Future<String?> Function(String prompt)? confirm;
  final bool allowInteractiveTools;
  final Duration confirmDeadline;
  final Duration confirmInterval;

  /// The targets the one yes accepted, by unit. Null until asked.
  Map<String, Set<Target>>? _authorized;

  /// The targets whose native session this run has already signed in to.
  final Set<PublishTarget> _signedIn = {};

  /// Proves every unfinished target of [run]'s unit can publish from this
  /// host, before any private work is spent on it.
  Future<bool> checkReadiness(UnitRun run) async {
    final UnitSnapshot(:unit, :targets, remaining: outstanding) = run.read;
    if (outstanding.isEmpty) return true;
    final board = targetBoard(
      output,
      '${unit.name} ${unit.version} · preparing release',
      targets,
      delay: briefPhase,
    );
    final environment = refreshEnvironment();
    for (final targetKind in outstanding.map((item) => item.target).toSet()) {
      final grouped = [
        for (final target in outstanding)
          if (target.target == targetKind) board[target.id],
      ];
      final module = inspector.targets.moduleFor(targetKind);
      final rows = Rows(grouped)..begin(Activities.checking);
      final readiness = await module.ready(
        TargetReadinessContext(
          tools: tools,
          git: initialGit,
          environment: environment,
          progress: rows,
        ),
        unit,
        signIn: false,
      );
      if (readiness.problem case final problem?) {
        _stopBefore(board, grouped, Activities.checking);
        output.problem(problem, unit: unit.name);
        output.halt(Stop.refused);
        return false;
      }
      for (final row in grouped) {
        row.complete(readiness.note);
      }
    }
    board.discard();
    return true;
  }

  /// What the release did at each of [run]'s targets, said when it stops.
  void showActions(UnitRun run) {
    output.blank();
    output.heading('Release targets');
    for (final target in run.read.targets) {
      final action = run.actions[target]!;
      final mark = switch (action) {
        ReleaseAction.completed => Mark.done,
        ReleaseAction.alreadyPublished => Mark.satisfied,
        ReleaseAction.failed => Mark.blocked,
        ReleaseAction.notAttempted => Mark.none,
      };
      output.line(
        target.label,
        mark: mark,
        note: action.human,
        depth: 1,
        role: VisualRole.releaseTarget,
        state: switch (action) {
          ReleaseAction.notAttempted => RuntimeState.neutral,
          ReleaseAction.alreadyPublished => RuntimeState.satisfied,
          ReleaseAction.completed => RuntimeState.success,
          ReleaseAction.failed => RuntimeState.failure,
        },
      );
    }
  }

  /// Stops before anything acts on [step], whose snapshot read refuses it.
  void haltForState(ResolvedUnit unit, Step step, Inspection state) {
    final refusal = _refusal(step, unit, state);
    output.problem(refusal.diagnostics.single, unit: unit.name);
    output.halt(refusal.stop);
  }

  /// Asks once, for every unit, whether to publish what the snapshot found
  /// missing. No session is acquired before the answer.
  Future<bool> authorize(List<UnitRun> runs) async {
    final asking = [
      for (final run in runs)
        if (run.read.remaining.isNotEmpty) run.read,
    ];
    if (asking.isEmpty) {
      _authorized = const {};
      return true;
    }
    for (final run in runs) {
      if (run.read.remaining.isNotEmpty) _showAuthorization(run);
    }
    if (!_requireAuthorizer(asking.first.unit)) return false;
    final names = [
      for (final read in asking) '${read.unit.name} ${read.unit.version}',
    ];
    final series = names.length <= 2
        ? names.join(' and ')
        : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
    output.report.attach(
      'authorization-disclosures/run',
      [
        'Private preparation completed for the selected release scope.',
        for (final read in asking)
          [
            '${read.unit.name} ${read.unit.version}',
            'stage ${read.stage!.id.id}',
            ...read.remaining.map(
              (target) =>
                  '  ${target.kindLabel}: '
                  '${_targetNote(target, read.claims)}',
            ),
            output
                    .report
                    .attachments['authorization-disclosures/${read.unit.name}'] ??
                '',
            CanonicalJson.encode(
              output.report.warningEvidenceFor(read.unit.name),
            ),
          ].join('\n'),
      ].join('\n\n'),
    );
    final answer = await confirm!('Release $series? [y/N] ');
    final accepted = const {'y', 'yes'}.contains(answer?.trim().toLowerCase());
    if (!accepted) {
      output.blank();
      output.say(
        answer == null
            ? 'No confirmation received for $series.'
            : 'Cancelled release of $series.',
      );
      output.problem(
        const Diagnostic(
          code: 'RK-AUTH-002',
          message: 'the release was not authorized',
          remedy:
              'answer yes at the prompt, or pass --yes for an unattended release',
        ),
      );
      output.halt(Stop.refused);
      output.next(
        runs.length == 1
            ? 'rk release ${runs.single.read.unit.name}'
            : 'rk release',
      );
      return false;
    }
    _authorized = {
      for (final read in asking) read.unit.name: {...read.remaining},
    };
    output.blank();
    return true;
  }

  /// Publishes what [authorize] accepted for [run]'s unit, and nothing
  /// else, in fixed lanes.
  Future<int> publish(UnitRun run) async {
    final authorized = _authorized;
    if (authorized == null) {
      throw StateError('publication needs one authorization first');
    }
    final UnitSnapshot(:unit, :targets, :release) = run.read;
    final accepted = authorized[unit.name] ?? const <Target>{};
    if (accepted.isEmpty) {
      if (targets.isNotEmpty) {
        output.line(
          '${unit.name} ${unit.version}',
          mark: Mark.satisfied,
          note: 'already released',
        );
      }
      return ExitCodes.ok;
    }
    final publishing = [
      for (final target in targets)
        if (accepted.contains(target)) target,
    ];
    if (!await _acquireSessions(unit, publishing)) {
      showActions(run);
      return ExitCodes.refused;
    }
    final board = targetBoard(
      output,
      '${unit.name} ${unit.version} · releasing',
      targets,
    );
    for (final target in targets) {
      if (!accepted.contains(target)) {
        board[target.id].complete('already published', mark: Mark.satisfied);
      }
    }
    final done = {
      for (final target in targets)
        if (!accepted.contains(target)) target.id,
    };
    final acting = <Target>{};
    final failures = <_PublicationFailure>[];

    // Each pending row says what it waits for: a target it needs, or its
    // turn at a destination another act is under way at.
    void describeWaits() {
      for (final target in targets) {
        if (done.contains(target.id) || acting.contains(target)) continue;
        final blockers = {
          for (final need in target.needs)
            if (need is Target && !done.contains(need.id)) need.label,
        };
        final note = blockers.isNotEmpty
            ? 'waiting for ${blockers.join(', ')}'
            : acting.any((other) => other.target == target.target)
            ? 'waiting its turn at ${target.kindLabel}'
            : null;
        if (note != null) board[target.id].wait(note);
      }
    }

    // One lane publishes its targets in order, one at a time. Once any
    // lane has failed, or crashed, it starts nothing new; an act already
    // under way is confirmed.
    var crashed = false;
    Future<void> lane(List<Target?> lane) async {
      for (final target in lane.nonNulls) {
        if (failures.isNotEmpty || crashed) return;
        if (done.contains(target.id)) continue;
        acting.add(target);
        describeWaits();
        final _PublicationFailure? failure;
        try {
          failure = await _publishTarget(target, run, board);
        } on Object {
          crashed = true;
          rethrow;
        } finally {
          acting.remove(target);
        }
        if (failure != null) {
          failures.add(failure);
          return;
        }
        done.add(target.id);
        describeWaits();
      }
    }

    // The tag first: everything else is published under it. Then the
    // packages, in dependency order, beside the GitHub release and the
    // formula that points at its archives.
    await lane([release.tag]);
    await Future.wait([
      lane(release.packages),
      lane([release.github, release.homebrew]),
    ]);

    if (failures.isNotEmpty || output.report.halted) {
      board
        ..skipPending()
        ..settle();
      _reportPublicationFailures(failures);
      return ExitCodes.refused;
    }

    board.settle(title: '${unit.name} ${unit.version} · released');
    return ExitCodes.ok;
  }

  /// Signs in once per target for the run, after the yes and before the
  /// first act that needs it: pub.dev and GitHub have native sessions.
  Future<bool> _acquireSessions(
    ResolvedUnit unit,
    List<Target> publishing,
  ) async {
    final byTarget = <PublishTarget, List<Target>>{};
    for (final target in publishing) {
      if (target.target != PublishTarget.pubDev &&
          target.target != PublishTarget.githubRelease) {
        continue;
      }
      if (_signedIn.contains(target.target)) continue;
      (byTarget[target.target] ??= []).add(target);
    }
    if (byTarget.isEmpty) return true;
    final board = targetBoard(
      output,
      '${unit.name} ${unit.version} · preparing release',
      [for (final grouped in byTarget.values) ...grouped],
    );
    final environment = refreshEnvironment();
    for (final MapEntry(key: kind, value: targets) in byTarget.entries) {
      final grouped = [for (final target in targets) board[target.id]];
      final rows = Rows(grouped)..begin(Activities.checkingSignIn);
      final signedIn = await inspector.targets
          .moduleFor(kind)
          .ready(
            TargetReadinessContext(
              tools: tools,
              git: initialGit,
              environment: environment,
              progress: rows,
              runInteractive: allowInteractiveTools
                  ? interactive(board, tools)
                  : null,
            ),
            unit,
            signIn: true,
          );
      if (signedIn.problem case final problem?) {
        _stopBefore(board, grouped, Activities.checkingSignIn);
        output.problem(problem, unit: unit.name);
        output.halt(Stop.refused);
        return false;
      }
      _signedIn.add(kind);
      for (final row in grouped) {
        row.complete(signedIn.note);
      }
    }
    board.discard();
    return true;
  }

  /// Settles [board] where a check of [checked] refused: they failed at
  /// [activity], and nothing after them was attempted.
  static void _stopBefore(Board board, List<Row> checked, Activity activity) {
    for (final row in checked) {
      row.fail(activity: activity);
    }
    board
      ..skipPending()
      ..settle();
  }

  /// The release loop for one target: read it fresh; done if it is already
  /// there, refused if something else is; check what it publishes; act;
  /// confirm. Null when the target is published, and otherwise why the
  /// release stops.
  Future<_PublicationFailure?> _publishTarget(
    Target target,
    UnitRun run,
    Board board,
  ) async {
    final unit = run.read.unit;
    final actions = run.actions;
    final stage = run.read.stage!;
    final module = inspector.targets.moduleFor(target.target);
    final row = board[target.id]..begin(Activities.checking);
    final releaseContext = TargetReleaseContext(
      reads: inspector.targetReads,
      tools: tools,
      release: run.read.release,
      // What the act publishes from: the complete stage, or nothing when
      // what is left finishes from public inputs alone.
      stage: run.recovering ? null : stage,
      progress: row.rows,
      runInteractive: allowInteractiveTools ? interactive(board, tools) : null,
      wait: wait,
      confirmDeadline: confirmDeadline,
      confirmInterval: confirmInterval,
    );
    // The target is read again right before its act: another run or person
    // may have published it since the snapshot.
    var state = await inspector.inspect(
      target,
      unit,
      stage: releaseContext.checkedStage,
    );
    output.report.step(
      target,
      verdict: state.verdict,
      detail: state.detail,
      evidence: state.evidence,
      action: actions[target]!.wire,
    );
    if (state.isExact) {
      actions[target] = ReleaseAction.alreadyPublished;
      row.complete('already published', mark: Mark.satisfied);
      output.report.step(
        target,
        verdict: state.verdict,
        action: actions[target]!.wire,
      );
      return null;
    }
    if (!state.isAbsent) {
      row.fail(activity: Activities.checking);
      return _refusal(target, unit, state);
    }
    // What the act publishes must still be what was reviewed: public
    // inputs a lost stage can finish from, or the stage's recorded bytes,
    // checked again. Within a run this costs a stat per file.
    final unpublishable = run.recovering
        ? (state.recoversWithoutStage
              ? null
              : Diagnostic(
                  code: 'RK-STAGE-005',
                  message:
                      '${target.summary} can no longer recover without its '
                      'stage',
                  remedy:
                      'its public inputs changed. Re-run so rk can inspect '
                      'the release again; restore ${stage.path} if the '
                      'target still needs the original bytes.',
                ))
        : switch (stage.check(run.read.release)) {
            final checked when !checked.reusable => Diagnostic(
              code: 'RK-STAGE-002',
              message:
                  'the reviewed release stage changed before '
                  '${target.summary}',
              remedy:
                  '${checked.lines.join('\n')}\n'
                  'rebuild it explicitly: rk stage ${unit.name}',
            ),
            _ => null,
          };
    if (unpublishable != null) {
      row.fail(activity: Activities.checking);
      return _PublicationFailure(
        step: target,
        diagnostics: [unpublishable],
        stop: Stop.refused,
      );
    }

    output.report.acted = true;
    final mutationActivity = _acting(target.target);
    row.begin(mutationActivity);
    late final TargetActOutcome act;
    try {
      act = await module.publish(releaseContext, unit, target, state);
    } on Object catch (error) {
      act = TargetActOutcome(
        ok: false,
        mayHaveActed: true,
        problem: '${target.kindLabel} operation threw: $error',
      );
    }
    final lastMutationActivity =
        releaseContext.progress.activity ?? mutationActivity;

    // A process result is not public truth unless the provider's answer is
    // the read-back. Every started operation is read back even if another
    // concurrent lane has failed.
    row.begin(Activities.verifying);
    try {
      state =
          act.confirmed ??
          await module.confirm(releaseContext, unit, target, act);
    } on Object catch (error) {
      state = Inspection.unknown(
        '${target.kindLabel} verification threw: $error',
      );
    }
    // What a halt says changed is what was read back, decided here for
    // every lane: an act that may have landed counts, and one that reported
    // success counts unless the read found nothing.
    if (state.isExact || act.mayHaveActed || (act.ok && !state.isAbsent)) {
      output.report.publicChanged = true;
    }
    actions[target] = state.isExact
        ? ReleaseAction.completed
        : ReleaseAction.failed;
    output.report.step(
      target,
      verdict: state.verdict,
      detail: state.detail,
      evidence: state.evidence,
      action: actions[target]!.wire,
    );
    if (!act.ok && state.isExact) {
      final inspected = act.includeInspectionDetail && state.detail != null
          ? ' · ${state.detail}'
          : '';
      final note =
          '${act.reconciledNote ?? 'command response was lost · public target confirmed exact'}$inspected';
      row.complete(note);
      return null;
    }
    if (!act.ok || !state.isExact) {
      row.fail(
        // A refused act failed where it acted; one that may have landed
        // failed where it was read back.
        activity:
            !act.ok &&
                !act.mayHaveActed &&
                (state.isAbsent || state.verdict == Verdict.conflict)
            ? lastMutationActivity
            : Activities.verifying,
      );
      return _unconfirmed(unit, target, state, act);
    }

    final note = [
      ?act.successNote,
      if (act.includeInspectionDetail) ?state.detail,
    ].join(' · ');
    row.complete(note.isEmpty ? 'published' : note);
    return null;
  }

  /// What an act that did not settle exact means: why the release stops,
  /// and the diagnostic, in [target]'s words.
  _PublicationFailure _unconfirmed(
    ResolvedUnit unit,
    Target target,
    Inspection state,
    TargetActOutcome act,
  ) {
    final module = inspector.targets.moduleFor(target.target);
    final conflict = state.verdict == Verdict.conflict;
    // The provider refused the act because a permanent target was already
    // something else: the conflict a fresh inspection would have found, with
    // the same advice.
    if (conflict && !target.moving && !act.ok && !act.mayHaveActed) {
      final advice = module.explain(unit, target, state).diagnostic;
      return _PublicationFailure(
        step: target,
        diagnostics: [
          Diagnostic(
            code: advice.code,
            message: advice.message,
            source: advice.source,
            remedy: [?advice.remedy, ?act.problem].join('\n'),
            evidence: act.evidence ?? act.diagnostic?.evidence,
          ),
        ],
        stop: Stop.unfixable,
      );
    }
    final given = act.diagnostic;
    final named = given == null || conflict
        ? module.explain(unit, target, state, acted: act)
        : (diagnostic: given, next: null);
    final details = [
      ?given?.remedy,
      ?act.problem,
      ?switch (act.privateEffect) {
        TargetPrivateEffect.none => null,
        TargetPrivateEffect.changed =>
          'GitHub private draft state changed; this step did not publish a '
              'GitHub Release.',
        TargetPrivateEffect.uncertain =>
          'GitHub private draft state may have changed; no GitHub Release '
              'was confirmed public.',
      },
      ?state.detail,
      ...state.evidence.entries.map((entry) => '${entry.key}: ${entry.value}'),
    ];
    return _PublicationFailure(
      step: target,
      diagnostics: [
        Diagnostic(
          code: named.diagnostic.code,
          message: named.diagnostic.message,
          remedy: details.isEmpty
              ? 're-run; the shared destination inspection will classify the '
                    'public target before any retry'
              : details.join('\n'),
          evidence: act.evidence ?? given?.evidence,
        ),
      ],
      stop: conflict
          ? (target.moving ? Stop.partway : Stop.unfixable)
          : act.mayHaveActed ||
                act.privateEffect == TargetPrivateEffect.uncertain ||
                state.verdict == Verdict.unknown
          ? Stop.lostTrack
          : act.privateEffect == TargetPrivateEffect.changed
          ? Stop.partway
          : Stop.refused,
      nextCommand: named.next,
    );
  }

  /// What a target's row says while rk acts on it.
  static Activity _acting(PublishTarget target) => switch (target) {
    PublishTarget.gitTag => (
      running: 'creating',
      failed: 'tag creation failed',
    ),
    PublishTarget.pubDev => (running: 'publishing', failed: 'publish failed'),
    PublishTarget.githubRelease => (
      running: 'drafting',
      failed: 'draft failed',
    ),
    PublishTarget.homebrew => (running: 'updating', failed: 'update failed'),
  };

  /// A read that found something other than the release missing: a
  /// conflict carries the target's own advice; anything else says what was
  /// read.
  _PublicationFailure _refusal(Step step, ResolvedUnit unit, Inspection state) {
    final conflict = state.verdict == Verdict.conflict;
    return _PublicationFailure(
      step: step,
      diagnostics: [
        if (conflict && step is Target)
          inspector.targets
              .moduleFor(step.target)
              .explain(unit, step, state)
              .diagnostic
        else
          Diagnostic(
            code: 'RK-REL-001',
            message: '${step.summary}: ${state.detail ?? state.verdict.name}',
            remedy: state.evidence.isEmpty
                ? (state.verdict == Verdict.unknown
                      ? 'the target could not be proven; fix the read and re-run'
                      : null)
                : state.evidence.entries
                      .map((entry) => '${entry.key}: ${entry.value}')
                      .join('\n'),
          ),
      ],
      stop: conflict ? Stop.unfixable : Stop.refused,
    );
  }

  void _reportPublicationFailures(List<_PublicationFailure> failures) {
    for (final failure in failures) {
      for (final diagnostic in failure.diagnostics) {
        output.problem(diagnostic, unit: failure.step.unit);
      }
      if (failure.nextCommand case final next?) output.next(next);
    }
    if (output.report.halted || failures.isEmpty) return;
    output.halt(Stop.worst(failures.map((failure) => failure.stop)));
  }

  /// The platforms [run]'s stage built and could not run, from what its
  /// receipt records: a reused stage may have been smoke-tested elsewhere.
  List<({String platform, String reason})> _unprovable(UnitRun run) {
    final checked = run.read.stage!.check(run.read.release);
    if (!checked.reusable) return const [];
    return [
      for (final work in run.read.release.work)
        if (work.kind == StepKind.build)
          if (checked.receipt!.producers[work.name]?['smoke'] case {
            'status': 'not-executed',
            'reason': final String reason,
          } when reason.isNotEmpty)
            (platform: work.platform!, reason: reason),
    ];
  }

  /// A row for each of [remaining], saying which are permanent and which
  /// claim a name for the first time.
  void _showTargets(List<Target> remaining, List<TargetClaim> claims) {
    // Grouped by destination, the way status and staging read. What is
    // permanent is said on the row it belongs to: a paragraph explaining
    // that publishing is forever tells an operator what they already know,
    // and buries the one line they do not.
    for (final target in remaining) {
      output.line(
        target.kindLabel,
        note: _targetNote(target, claims),
        depth: 1,
        labelWidth: 26,
        role: VisualRole.releaseTarget,
        noteState: _marks(target, claims).isEmpty
            ? RuntimeState.neutral
            : RuntimeState.attention,
      );
    }
  }

  /// What [target]'s row says: what arrives there, and its marks.
  String _targetNote(Target target, List<TargetClaim> claims) =>
      [target.planNote, ..._marks(target, claims)].join(' · ');

  // Keyed by what is claimed, not by where: a unit publishing several
  // packages to pub.dev has one row each, and marking them all because one
  // name is new would tell the operator they are permanently taking names
  // that were taken releases ago.
  static List<String> _marks(Target target, List<TargetClaim> claims) => [
    if (target.isPermanent) 'permanent',
    if (claims.any(
      (claim) =>
          claim.registrar == target.kindLabel &&
          claim.name == target.coordinate,
    ))
      'first claim',
  ];

  /// The long form of what a yes for [remaining] accepts, which travels with
  /// it: what the permanent targets mean, and every name claimed first.
  ///
  /// [firstStep] says which permanent step is the first a yes lets happen,
  /// which only the question itself knows when it covers several units.
  List<String> _disclosureFor(
    List<Target> remaining,
    List<TargetClaim> claims, {
    MacIdentity? firstSigning,
    bool firstStep = true,
  }) {
    final permanent = [
      for (final target in remaining)
        if (target.isPermanent) target,
    ];
    final notices = {
      for (final target in permanent)
        if (target.permanenceNotice case final notice?) notice,
    };
    return [
      if (permanent.isNotEmpty)
        [
          ...notices,
          if (firstStep)
            'everything before this yes re-runs safely. after it, the first '
                'permanent step is: ${permanent.first.summary}.',
        ].join('\n'),
      ..._recordClaims(claims, firstSigning),
    ];
  }

  void _showAuthorization(UnitRun run) {
    final UnitSnapshot(:unit, :remaining, :claims) = run.read;
    final signing = run.identity;
    final unprovable = _unprovable(run);
    final disclosed = <String>[];
    output.blank();
    output.line(
      'Release ${unit.name} ${unit.version}',
      role: VisualRole.checkpoint,
      strong: true,
    );

    _showTargets(remaining, claims);
    final firstSigning = signing != null && signing.first ? signing : null;
    if (firstSigning != null) {
      // The identifier first: it is what gets sealed into the designated
      // requirement and every Keychain item, so a wrong one has to be seen
      // rather than hunted for. The certificate says who signed it.
      output.line(
        'macOS identity',
        note:
            '${firstSigning.codeId} signed by '
            '${_shortCertificate(firstSigning.certificate)} · '
            'permanent · first claim',
        depth: 1,
        labelWidth: 26,
        role: VisualRole.requirement,
        noteState: RuntimeState.attention,
      );
    }
    // Nothing is said about permanence beyond the rows. A sentence telling
    // an operator that a release is permanent, printed above a prompt they
    // reached deliberately, is a paragraph they learn to scroll past — and
    // the rows already name which destinations mean it. The full wording,
    // and which step is the first that cannot be re-run, stay in the record
    // that travels with the authorization.
    disclosed.addAll(
      _disclosureFor(remaining, claims, firstSigning: firstSigning),
    );

    // A weaker build proof belongs on the authorization surface as well as in
    // its durable record.
    if (unprovable.isNotEmpty) {
      output.blank();
      output.heading('Warnings');
      for (final item in unprovable) {
        output.warning(
          Diagnostic(
            code: 'RK-BUILD-002',
            message:
                '${item.platform} was built but not executed: '
                '${item.reason}',
            remedy:
                'run the staged binary on ${item.platform} before '
                'release if that platform is release-critical',
          ),
          unit: unit.name,
          depth: 1,
        );
      }
      disclosed.add(
        'these ship built but never executed — rk cannot '
        'prove they run or report ${unit.version}:\n'
        '${unprovable.map((item) => '${item.platform} — ${item.reason}').join('\n')}',
      );
    }

    // What the yes accepts travels with it. The attachment keeps the long
    // form even when the terminal surface intentionally stays concise.
    if (disclosed.isNotEmpty) {
      output.report.attach(
        'authorization-disclosures/${unit.name}',
        disclosed.join('\n\n'),
      );
    }
  }

  bool _requireAuthorizer(ResolvedUnit unit) {
    if (confirm != null) return true;
    output.problem(
      Diagnostic(
        code: 'RK-AUTH-001',
        message: 'nobody is here to authorize this release',
        remedy:
            'answer yes at a terminal, or pass --yes for an unattended '
            'release. Without either, rk refuses.',
      ),
      unit: unit.name,
    );
    output.halt(Stop.refused);
    return false;
  }

  /// Long-form first claims retained with the authorization record.
  List<String> _recordClaims(
    List<TargetClaim> claims,
    MacIdentity? firstSigning,
  ) {
    // Sentences, not columns. This is read out of the report by whoever or
    // whatever consented; the alignment it used to carry was for a screen
    // that no longer prints it.
    final firstOf = <String>[
      for (final claim in claims)
        '${claim.registrar} ${claim.name} — ${claim.consequence}',
      if (firstSigning != null)
        'macOS identity ${firstSigning.codeId} — permanent: sealed into the '
            'designated requirement, and into every Keychain item this '
            'program creates. Signed by ${firstSigning.certificate}',
    ];
    if (firstOf.isEmpty) return const [];
    return ['this release claims, for the first time:', ...firstOf];
  }

  /// Every Developer ID certificate begins the same way; what varies is the
  /// team it names.
  static String _shortCertificate(String certificate) =>
      certificate.replaceFirst('Developer ID Application: ', '');
}

final class _PublicationFailure {
  const _PublicationFailure({
    required this.step,
    required this.diagnostics,
    required this.stop,
    this.nextCommand,
  });

  final Step step;
  final List<Diagnostic> diagnostics;
  final Stop stop;
  final String? nextCommand;
}
