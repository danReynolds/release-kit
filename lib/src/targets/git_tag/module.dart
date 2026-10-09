import '../../engine/assets.dart';
import '../../engine/diagnostic.dart';
import '../../engine/git.dart';
import '../../engine/publish_target.dart';
import '../../engine/resolve.dart';
import '../../engine/stage.dart';
import '../../engine/unit_release.dart';
import '../../engine/verdict.dart';
import '../../engine/version.dart';
import '../target_module.dart';
import 'client.dart';
import 'transaction.dart';

final class GitTagTargetModule extends TargetModule {
  const GitTagTargetModule();

  @override
  PublishTarget get target => PublishTarget.gitTag;

  /// Origin's tag, and the lane's latest version, from one listing of
  /// origin's tags per run.
  @override
  Future<TargetRead> read(
    TargetReadContext reads,
    ResolvedUnit unit,
    Target target, {
    Stage? stage,
  }) async {
    final history = readHistory(() => _history(reads, unit, target));
    return (
      state: await _candidate(reads, unit, stage: stage),
      history: await history,
    );
  }

  Future<Inspection> _candidate(
    TargetReadContext context,
    ResolvedUnit unit, {
    Stage? stage,
  }) async {
    final tag = unit.tag!;
    final tools = context.tools;
    if (tools == null) {
      return Inspection.unknown(
        context.git.hasTag(tag)
            ? 'the tag exists locally; no tools to read origin with'
            : 'no tools to read origin with',
      );
    }
    final destination = GitTag(tools: tools, root: context.git.root);
    final manifestSha256 =
        stage?.receipt?.files[ReleaseAssets.manifest]?.sha256;

    final remote = await destination.inspectReleaseBinding(
      listing: context.once(originTagsKey, destination.listTags),
      tag: tag,
      expectedCommit: context.git.head,
      expectedManifestSha256: manifestSha256,
      // Before this commit is staged, the question is whether an unchanged
      // unit is already released. Once it is staged, rk means to publish its
      // bytes, which only a tag on this commit can bind.
      sourcePaths: stage != null
          ? const []
          : [for (final project in unit.projects) project.pubspec.directory],
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
    // A tag only this clone has is the operator's to remove: the conflict
    // says so, and so does its remedy.
    final notOnOrigin = {'origin': 'has no $tag'};
    if (commit.toLowerCase() != context.git.head.toLowerCase()) {
      return Inspection.conflict(
        'the local release tag points at a different source commit',
        evidence: {
          'source commit': 'local $commit, expected ${context.git.head}',
          ...notOnOrigin,
        },
      );
    }
    final local = await destination.inspectLocalReleaseBinding(
      tag: tag,
      expectedObject: object,
      expectedCommit: commit,
      expectedManifestSha256: manifestSha256,
    );
    if (local.isExact) return remote;
    return local.verdict == Verdict.conflict
        ? Inspection.conflict(
            local.detail!,
            evidence: {...local.evidence, ...notOnOrigin},
          )
        : local;
  }

  Future<TargetHistory> _history(
    TargetReadContext context,
    ResolvedUnit unit,
    Target target,
  ) async {
    final tools = context.tools;
    final destination = tools == null
        ? null
        : GitTag(tools: tools, root: context.git.root);
    final inspection = destination == null
        ? const Inspection.unknown('no tools to read origin with')
        : await destination.inspectLatestVersion(
            unit.tagPattern!,
            listing: context.once(originTagsKey, destination.listTags),
          );
    final history = TargetHistory.versioned(
      inspection: inspection,
      target: target,
      regressionDiagnostic: (publicVersion) => Diagnostic(
        code: 'RK-MONO-003',
        message:
            '${target.label} is already at $publicVersion, ahead of '
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
    final pattern = unit.tagPattern!;
    for (final tag in context.git.tagsMatching(pattern)) {
      final raw = GitState.versionIn(tag, pattern);
      if (raw == null) continue;
      final existing = Version.tryParse(raw);
      if (existing == null || existing == unit.version) continue;
      if (existing > unit.version) {
        yield Diagnostic(
          code: 'RK-MONO-001',
          message:
              'the tag $tag is ahead of ${unit.version}, which this '
              'release would publish',
          remedy: 'a release moves forward — bump past $raw',
        );
        return;
      }
    }
  }

  @override
  ({Diagnostic diagnostic, String? next}) explain(
    ResolvedUnit unit,
    Target target,
    Inspection state, {
    TargetActOutcome? acted,
  }) => acted != null
      ? unconfirmedAct(target, state, acted)
      : (diagnostic: _conflict(unit, target, state), next: null);

  Diagnostic _conflict(ResolvedUnit unit, Target target, Inspection conflict) {
    if (conflict.sourceMismatch != null) {
      final project = unit.projects.first;
      return Diagnostic(
        code: 'RK-MONO-004',
        message:
            'version ${unit.version} is already released from '
            'different source',
        source: SourceLocation(
          project.pubspec.path,
          project.pubspec.versionLine,
        ),
        remedy:
            'To release these changes, bump the version and add its '
            'changelog entry, then run rk stage ${unit.name}.',
      );
    }
    final tag = unit.tag!;
    if (conflict.evidence['origin'] == 'has no $tag') {
      return Diagnostic(
        code: 'RK-REL-001',
        message: '${target.label}: ${conflict.detail}',
        remedy:
            '$tag is only in this clone, and is not one rk made for this '
            'commit. Delete it with git tag -d $tag, then re-run',
      );
    }
    return Diagnostic(
      code: 'RK-REL-001',
      message:
          '${target.label}: '
          '${conflict.detail ?? 'the public tag does not match'}',
      remedy:
          'do not move the public tag. If it is not the intended '
          'release, bump the version and changelog, then stage the new '
          'release',
    );
  }

  @override
  Future<TargetActOutcome> publish(
    TargetReleaseContext context,
    ResolvedUnit unit,
    Target target,
    Inspection before,
  ) => publishGitTag(context, unit);
}
