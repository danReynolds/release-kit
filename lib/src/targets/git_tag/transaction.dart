import '../../engine/assets.dart';
import '../../engine/diagnostic.dart';
import '../../engine/resolve.dart';
import '../../engine/verdict.dart';
import '../../output/progress.dart';
import '../target_module.dart';
import 'client.dart';

/// Creates and pushes one annotated release tag.
///
/// Git's answer to the push is the read-back: it accepts a tag only as the
/// exact object it is given, and refuses to replace one origin already has.
/// Only a push whose answer did not say which reads origin again, and
/// compares origin's tag with the object rk pushed.
Future<TargetActOutcome> publishGitTag(
  TargetReleaseContext context,
  ResolvedUnit unit,
) async {
  final git = context.git;
  final tag = unit.tag!;
  final destination = GitTag(tools: context.tools, root: git.root);
  // As Git itself does, rk signs a tag when tag.gpgSign asks it to. A
  // signing key alone, which may be there for commits, does not sign
  // release tags.
  final signed = git.tagSigningRequested;

  if (signed && !git.signingConfigured) {
    return TargetActOutcome(
      ok: false,
      diagnostic: Diagnostic(
        code: 'RK-TAG-005',
        message:
            'this project signs its release tags, and no signing key '
            'is configured',
        remedy:
            'Set user.signingkey (with gpg.format=ssh for an SSH key), '
            'or, to release ${unit.name} unsigned, clear tag.gpgSign and '
            'know that its signed release history no longer continues.',
      ),
    );
  }

  // The stage was checked just before this act: its manifest is the one
  // the receipt records.
  final manifestSha256 =
      context.stage!.receipt!.files[ReleaseAssets.manifest]!.sha256;
  final String object;
  // An interrupted run may have created the exact local tag without pushing
  // it. Inspection validated that object, so it is pushed as it is.
  final created = !git.hasTag(tag);
  if (created) {
    // The run's commit is the one its stage was built from.
    final made = await destination.create(
      tag,
      commit: git.head,
      signed: signed,
      message:
          '${unit.name} ${unit.version}\n\n'
          'release-manifest-sha256: $manifestSha256',
    );
    if (!made.ok) {
      return TargetActOutcome(
        ok: false,
        diagnostic: Diagnostic(
          code: 'RK-TAG-001',
          message: 'the tag $tag could not be created',
          remedy: made.summary,
        ),
        evidence: made.transcript,
      );
    }
    final resolved = await destination.localObject(tag);
    if (resolved.object == null) {
      return TargetActOutcome(
        ok: false,
        diagnostic: Diagnostic(
          code: 'RK-TAG-001',
          message: 'the new tag $tag could not be identified',
          remedy: resolved.problem ?? 'the annotated tag object was unreadable',
        ),
      );
    }
    object = resolved.object!;
  } else {
    final existing = git.tagObject(tag);
    if (existing == null) {
      return TargetActOutcome(
        ok: false,
        diagnostic: Diagnostic(
          code: 'RK-TAG-002',
          message: 'the tag $tag could not be pushed',
          remedy:
              'the validated local tag object id is unavailable; '
              're-run so rk can inspect it again',
        ),
      );
    }
    object = existing.toLowerCase();
  }

  context.progress.begin(
    ProgressActivity(running: 'pushing', failed: 'push failed'),
  );
  final pushed = await destination.pushExact(tag, object);
  final exact = Inspection.exact(
    detail: 'origin has the tag rk pushed',
    evidence: {
      'tag object': object,
      'source commit': git.head,
      'manifest sha256': manifestSha256,
    },
  );
  if (pushed.ok) {
    return TargetActOutcome(
      ok: true,
      mayHaveActed: true,
      successNote: created
          ? '${signed ? 'signed' : 'unsigned'}, pushed'
          : 'pushed, pre-existing local tag',
      confirmed: exact,
    );
  }

  // Git refused the push, or its answer was lost. Origin's tag, read on its
  // own, says which.
  final origin = await destination.onOrigin(tag);
  final Inspection state;
  if (origin.problem case final problem?) {
    state = Inspection.unknown(problem);
  } else if (origin.object == null) {
    state = const Inspection.absent(detail: 'not on origin');
  } else if (origin.object == object) {
    state = exact;
  } else {
    final released = origin.commit!;
    state = Inspection.conflict(
      'origin has another $tag',
      evidence: {
        'tag object': 'origin ${origin.object}, pushed $object',
        'source commit': 'origin $released, pushed ${git.head}',
      },
      sourceMismatch: released == git.head.toLowerCase()
          ? null
          : SourceBindingMismatch(
              releasedCommit: released,
              currentCommit: git.head,
            ),
    );
  }

  // A tag this run made that origin does not hold is removed, so a re-run
  // starts clean. One that pre-existed stays, as found.
  String? cleanup;
  if (created && (state.isAbsent || state.verdict == Verdict.conflict)) {
    final removed = await destination.deleteLocalIfExact(tag, object);
    cleanup = removed.ok
        ? 'the local tag was removed, so re-running starts clean'
        : 'the local tag could not be removed and was left in place; '
              're-running inspects it before pushing';
  }
  return TargetActOutcome(
    ok: false,
    problem: cleanup,
    // An unread origin may hold the push that lost its answer.
    mayHaveActed: state.verdict == Verdict.unknown,
    diagnostic: Diagnostic(
      code: 'RK-TAG-002',
      message: 'the tag $tag could not be pushed',
      remedy: pushed.summary,
    ),
    evidence: pushed.transcript,
    reconciledNote: 'push response was lost · origin confirmed exact',
    confirmed: state,
  );
}
