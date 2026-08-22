import '../../engine/assets.dart';
import '../../engine/checklist.dart';
import '../../engine/diagnostic.dart';
import '../../engine/git.dart';
import '../../engine/publish_target.dart';
import '../../engine/resolve.dart';
import '../../engine/targets.dart';
import '../../engine/verdict.dart';
import '../../engine/version.dart';
import '../../output/output.dart';
import '../../output/progress.dart';
import '../target_module.dart';
import 'client.dart';
import 'transaction.dart';

final class GitTagTargetModule extends TargetModule {
  const GitTagTargetModule();

  @override
  PublishTarget get target => PublishTarget.gitTag;

  @override
  Future<TargetReadinessOutcome> checkReadiness(
    TargetReadinessContext context,
    ResolvedUnit unit,
  ) async =>
      const TargetReady();

  @override
  ProgressActivity get publishActivity => ProgressActivity(
        running: 'creating',
        failed: 'tag creation failed',
      );

  @override
  TargetPlan plan({
    required ResolvedUnit unit,
    required Step step,
    String? repository,
  }) {
    final tag = requiredTargetTag(unit, PublishTarget.gitTag);
    return TargetPlan(
      label: 'Git tag',
      kindLabel: 'Git tag',
      identity: tag,
      planNote: tag,
      coordinate: tag,
      targetVersion: unit.version.canonical,
      step: step,
      // The tag binds the manifest digest in its annotation; it does not
      // host a file named release-manifest.json. Binary releases publish
      // that file on GitHub. A pub-only release is recovered directly from
      // its peeled source commit plus pub.dev's archive.
      artifacts: const [],
      uses: unit.shipsBinaries
          ? '${ReleaseAssets.manifest} from GitHub Release'
          : null,
    );
  }

  @override
  Future<Inspection> inspectCandidate(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetPlan target,
  ) async {
    final tag = requiredTargetTag(unit, PublishTarget.gitTag);
    final tools = context.tools;
    if (tools == null) {
      return Inspection.unknown(
        context.git.hasTag(tag)
            ? 'the tag exists locally; no tools to read origin with'
            : 'no tools to read origin with',
      );
    }
    final destination = GitTag(tools: tools, root: context.git.root);
    final stage = context.reusableStage(unit);
    String? manifestSha256;
    if (stage != null) {
      try {
        final manifest = stage.requireReceipt().artifacts.singleWhere(
              (artifact) => artifact.path == ReleaseAssets.manifest,
            );
        manifestSha256 = manifest.sha256;
      } on Object catch (error) {
        return Inspection.unknown(
          'the expected release tag binding could not be read: $error',
        );
      }
    }

    final remote = await destination.inspectReleaseBinding(
      tag: tag,
      expectedCommit: context.git.head,
      expectedManifestSha256: manifestSha256,
      requireSignature: context.git.signingConfigured,
    );
    if (!remote.isAbsent || !context.git.hasTag(tag)) return remote;

    final commit = context.git.tagTarget(tag);
    if (commit == null) {
      return const Inspection.unknown(
        'could not read the expected local tag commit',
      );
    }
    final object = context.git.tagObject(tag);
    if (object == null) {
      return const Inspection.unknown(
        'could not read the expected local tag object',
      );
    }
    if (commit.toLowerCase() != context.git.head.toLowerCase()) {
      return Inspection.conflict(
        'the local release tag points at a different source commit',
        evidence: {
          'source commit': 'local $commit, expected ${context.git.head}',
        },
      );
    }
    final local = await destination.inspectLocalReleaseBinding(
      tag: tag,
      expectedObject: object,
      expectedCommit: commit,
      expectedManifestSha256: manifestSha256,
      requireSignature: context.git.signingConfigured,
    );
    return local.isExact ? remote : local;
  }

  @override
  Future<TargetHistory> inspectHistory(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetPlan target, {
    bool fresh = false,
  }) async {
    final tools = context.tools;
    final inspection = tools == null
        ? const Inspection.unknown('no tools to read origin with')
        : await GitTag(tools: tools, root: context.git.root)
            .inspectLatestVersion(
            requiredTargetTagPattern(unit, PublishTarget.gitTag),
          );
    final history = TargetHistory.versioned(
      inspection: inspection,
      target: target,
      regressionDiagnostic: (publicVersion) => Diagnostic(
        code: 'RK-MONO-003',
        message: '${target.label} is already at $publicVersion, ahead of '
            '${target.targetVersion}',
        remedy: 'a release moves forward — bump past $publicVersion',
      ),
    );
    // Public history is the stronger fact. When origin already proves the
    // namespace is ahead, do not repeat the same refusal from the local tag.
    if (history.problems.any((item) => item.code == 'RK-MONO-003')) {
      return history;
    }
    return TargetHistory(
      inspection: history.inspection,
      version: history.version,
      problems: [...history.problems, ..._localVersionProblems(context, unit)],
    );
  }

  Iterable<Diagnostic> _localVersionProblems(
    TargetReadContext context,
    ResolvedUnit unit,
  ) sync* {
    final pattern = requiredTargetTagPattern(unit, PublishTarget.gitTag);
    for (final tag in context.git.tagsMatching(pattern)) {
      final raw = GitState.versionIn(tag, pattern);
      if (raw == null) continue;
      final existing = Version.tryParse(raw);
      if (existing == null || existing == unit.version) continue;
      if (existing > unit.version) {
        yield Diagnostic(
          code: 'RK-MONO-001',
          message: 'the tag $tag is ahead of ${unit.version}, which this '
              'release would publish',
          remedy: 'a release moves forward — bump past $raw',
        );
        return;
      }
    }
  }

  @override
  Diagnostic diagnoseConflict(
    ResolvedUnit unit,
    TargetPlan target,
    Inspection conflict,
  ) {
    if (conflict.sourceMismatch != null) {
      final project = unit.projects.first;
      return Diagnostic(
        code: 'RK-MONO-004',
        message: 'current source still declares released version '
            '${unit.version}',
        source: SourceLocation(
          project.pubspec.path,
          project.pubspec.versionLine,
        ),
        remedy: 'bump the version and changelog for the next release. '
            'Do not move ${target.coordinate}',
      );
    }
    return Diagnostic(
      code: 'RK-REL-001',
      message: '${target.label}: '
          '${conflict.detail ?? 'the public tag does not match'}',
      remedy: 'do not move the public tag. If it is not the intended '
          'release, bump the version and changelog, then stage the new '
          'release',
    );
  }

  @override
  Future<TargetActOutcome> publish(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetPlan target,
    Inspection inspected,
  ) =>
      publishGitTag(context, unit);

  @override
  Future<TargetFailure> classifyUnconfirmedPublication(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetPlan target,
    Inspection state,
    TargetActOutcome act, {
    required bool actedBefore,
  }) async {
    String? cleanup;
    var cleanupFailed = false;
    final recovery = act.cleanupIfAbsent;
    if (state.isAbsent && recovery != null) {
      final result = await recovery();
      cleanupFailed = !result.ok;
      cleanup = result.detail;
    }

    final conflict = state.verdict == Verdict.conflict;
    final code = conflict ? 'RK-TAG-004' : act.diagnostic?.code ?? 'RK-TAG-003';
    final message = conflict
        ? 'origin did not confirm the release binding on '
            '${act.coordinate ?? target.coordinate}'
        : act.diagnostic?.message ??
            'the push reported success, and origin did not confirm the exact '
                'tag ${act.coordinate ?? target.coordinate}';
    final details = <String>[
      if (act.diagnostic?.remedy != null) act.diagnostic!.remedy!,
      if (act.problem != null) act.problem!,
      if (state.detail != null) state.detail!,
      ...state.evidence.entries.map((entry) => '${entry.key}: ${entry.value}'),
      if (cleanup != null) cleanup,
    ];
    final pushProvedAbsent = !act.ok && state.isAbsent;
    final halt = conflict
        ? HaltKind.actedAndUnfixable
        : cleanupFailed
            ? HaltKind.stoppedPartway
            : pushProvedAbsent
                ? (actedBefore
                    ? HaltKind.stoppedPartway
                    : HaltKind.beforeActing)
                : act.mayHaveActed || state.verdict == Verdict.unknown
                    ? HaltKind.lostTrack
                    : actedBefore
                        ? HaltKind.stoppedPartway
                        : HaltKind.beforeActing;
    return TargetFailure(
      diagnostic: Diagnostic(
        code: code,
        message: message,
        remedy: details.isEmpty
            ? 're-run; the shared destination inspection will classify the '
                'public target before any retry'
            : details.join('\n'),
        evidence: act.evidence ?? act.diagnostic?.evidence,
      ),
      halt: halt,
    );
  }
}
