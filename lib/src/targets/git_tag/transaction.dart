import 'dart:io';

import '../../engine/assets.dart';
import '../../engine/diagnostic.dart';
import '../../engine/publish_target.dart';
import '../../engine/resolve.dart';
import '../../output/progress.dart';
import '../../transforms/digest.dart';
import '../target_module.dart';
import 'client.dart';

/// Creates, validates, and pushes one exact annotated release tag.
///
/// These are one transaction rather than core lifecycle hooks. The returned
/// provider-neutral outcome carries cleanup authority for the module's
/// post-act reconciliation policy.
Future<TargetActOutcome> publishGitTag(
  TargetReleaseContext context,
  ResolvedUnit unit,
) async {
  final git = context.git;
  final tag = requiredTargetTag(unit, PublishTarget.gitTag);
  final destination = GitTag(tools: context.tools, root: git.root);
  // As Git itself does, rk signs a tag when tag.gpgSign asks it to. A
  // signing key alone, which may be there for commits, does not sign
  // release tags.
  final signed = git.tagSigningRequested;

  if (signed && !git.signingConfigured) {
    return TargetActOutcome(
      ok: false,
      coordinate: tag,
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

  // An interrupted run may have created the exact local tag without pushing
  // it. Validate and push that object instead of recreating or moving it.
  if (git.hasTag(tag)) {
    context.progress.begin(
      ProgressActivity(running: 'pushing', failed: 'push failed'),
    );
    final outcome = await _pushExisting(
      destination,
      unit,
      object: git.tagObject(tag),
    );
    context.reads.forget(originTagsKey);
    return outcome;
  }

  final manifestSha256 = _manifestDigest(context);
  // The run's commit is the one its stage was built from.
  final created = await destination.create(
    tag,
    commit: git.head,
    signed: signed,
    message:
        '${unit.name} ${unit.version}\n\n'
        'release-manifest-sha256: $manifestSha256',
  );
  if (!created.ok) {
    return TargetActOutcome(
      ok: false,
      coordinate: tag,
      diagnostic: Diagnostic(
        code: 'RK-TAG-001',
        message: 'the tag $tag could not be created',
        remedy: created.summary,
      ),
      evidence: created.transcript,
      reconciledNote:
          'tag creation response was lost · origin confirmed '
          'the exact release tag',
    );
  }

  context.progress.begin(
    ProgressActivity(running: 'pushing', failed: 'push failed'),
  );

  final resolved = await destination.localObject(tag);
  final object = resolved.object;
  if (object == null) {
    return TargetActOutcome(
      ok: false,
      coordinate: tag,
      diagnostic: Diagnostic(
        code: 'RK-TAG-001',
        message: 'the new tag $tag could not be identified',
        remedy: resolved.problem ?? 'the annotated tag object was unreadable',
      ),
    );
  }
  Future<TargetCleanupResult> cleanup() =>
      _deleteLocalTag(destination, tag, object);

  final pushed = await destination.pushExact(tag, object);
  context.reads.forget(originTagsKey);
  if (!pushed.ok) {
    return TargetActOutcome(
      ok: false,
      coordinate: tag,
      mayHaveActed: true,
      cleanupIfAbsent: cleanup,
      diagnostic: Diagnostic(
        code: 'RK-TAG-002',
        message: 'the tag $tag could not be pushed',
        remedy:
            '${pushed.summary}\norigin will be read before this result '
            'is classified; a re-run inspects before pushing again',
      ),
      evidence: pushed.transcript,
      reconciledNote: 'push response was lost · origin confirmed exact',
    );
  }
  return TargetActOutcome(
    ok: true,
    coordinate: tag,
    mayHaveActed: true,
    successNote: [if (signed) 'signed' else 'unsigned', 'pushed'].join(', '),
  );
}

Future<TargetActOutcome> _pushExisting(
  GitTag destination,
  ResolvedUnit unit, {
  required String? object,
}) async {
  final tag = requiredTargetTag(unit, PublishTarget.gitTag);
  if (object == null) {
    return TargetActOutcome(
      ok: false,
      coordinate: tag,
      diagnostic: Diagnostic(
        code: 'RK-TAG-002',
        message: 'the tag $tag could not be pushed',
        remedy:
            'the validated local tag object id is unavailable; '
            're-run so rk can inspect it again',
      ),
    );
  }
  final pushed = await destination.pushExact(tag, object);
  if (!pushed.ok) {
    return TargetActOutcome(
      ok: false,
      coordinate: tag,
      mayHaveActed: true,
      diagnostic: Diagnostic(
        code: 'RK-TAG-002',
        message: 'the tag $tag could not be pushed',
        remedy:
            '${pushed.summary}\nthe tag pre-existed this run, so it '
            'was left in place — re-running pushes it again',
      ),
      evidence: pushed.transcript,
      reconciledNote: 'push response was lost · origin confirmed exact',
    );
  }
  return TargetActOutcome(
    ok: true,
    coordinate: tag,
    mayHaveActed: true,
    successNote: 'pushed, pre-existing local tag',
  );
}

String _manifestDigest(TargetReleaseContext context) {
  final manifest = File(
    context.stage.directory.resolve(ReleaseAssets.manifest),
  );
  if (!manifest.existsSync()) {
    throw StateError('the completed stage has no release manifest');
  }
  return Sha256.hex(manifest.readAsBytesSync());
}

Future<TargetCleanupResult> _deleteLocalTag(
  GitTag destination,
  String tag,
  String object,
) async {
  final removed = await destination.deleteLocalIfExact(tag, object);
  return TargetCleanupResult(
    ok: removed.ok,
    detail: removed.ok
        ? 'the local tag was removed, so re-running starts clean'
        : 'the local tag could not be removed and was left in place; '
              're-running inspects and pushes it safely',
  );
}
