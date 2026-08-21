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
  final signed = git.signingConfigured;
  final required = await _signatureRequired(context, unit, destination);

  if (required && !signed) {
    return TargetActOutcome(
      ok: false,
      coordinate: tag,
      diagnostic: Diagnostic(
        code: 'RK-TAG-005',
        message: 'this project signs its release tags, and no signing key '
            'is configured',
        remedy: 'Set user.signingkey (with gpg.format=ssh for an SSH key), '
            'or, to release ${unit.name} unsigned, clear tag.gpgSign and '
            'know that its signed release history no longer continues.',
      ),
    );
  }

  // An interrupted run may have created the exact local tag without pushing
  // it. Validate and push that object instead of recreating or moving it.
  if (git.hasTag(tag)) {
    final existing = git.tagObject(tag);
    var existingSigned = false;
    if (existing != null) {
      final signature = await _signatureState(
        destination,
        existing,
        required: required,
        tag: tag,
        unit: unit,
      );
      if (signature.refusal != null) {
        return TargetActOutcome(
          ok: false,
          coordinate: tag,
          diagnostic: signature.refusal!,
        );
      }
      existingSigned = signature.signed;
    }
    context.progress.begin(
      ProgressActivity(running: 'pushing', failed: 'push failed'),
    );
    return _pushExisting(
      destination,
      unit,
      object: existing,
      signed: existingSigned,
    );
  }

  final manifestSha256 = _manifestDigest(context);
  final created = await destination.create(
    tag,
    signed: signed,
    message: '${unit.name} ${unit.version}\n\n'
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
      reconciledNote: 'tag creation response was lost · origin confirmed '
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

  final signature = await _signatureState(
    destination,
    object,
    required: required,
    tag: tag,
    unit: unit,
  );
  if (signature.refusal != null) {
    return TargetActOutcome(
      ok: false,
      coordinate: tag,
      cleanupIfAbsent: cleanup,
      diagnostic: signature.refusal!,
    );
  }

  final local = await destination.inspectLocalReleaseBinding(
    tag: tag,
    expectedObject: object,
    expectedCommit: git.head,
    expectedManifestSha256: manifestSha256,
    requireSignature: signature.signed,
  );
  if (!local.isExact) {
    return TargetActOutcome(
      ok: false,
      coordinate: tag,
      cleanupIfAbsent: cleanup,
      diagnostic: Diagnostic(
        code: 'RK-TAG-001',
        message: 'the new tag $tag did not validate',
        remedy: [
          if (local.detail != null) local.detail!,
          ...local.evidence.entries
              .map((entry) => '${entry.key}: ${entry.value}'),
        ].join('\n'),
      ),
    );
  }

  final pushed = await destination.pushExact(tag, object);
  if (!pushed.ok) {
    return TargetActOutcome(
      ok: false,
      coordinate: tag,
      mayHaveActed: true,
      cleanupIfAbsent: cleanup,
      diagnostic: Diagnostic(
        code: 'RK-TAG-002',
        message: 'the tag $tag could not be pushed',
        remedy: '${pushed.summary}\norigin will be read before this result '
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
    successNote: [
      if (signature.signed) 'signed, verified' else 'unsigned',
      'pushed',
    ].join(', '),
  );
}

/// What [object]'s signature actually is, and whether policy accepts it.
Future<({bool signed, Diagnostic? refusal})> _signatureState(
  GitTag destination,
  String object, {
  required bool required,
  required String tag,
  required ResolvedUnit unit,
}) async {
  final present = await destination.hasSignature(object);
  if (present == null) {
    return (
      signed: false,
      refusal: Diagnostic(
        code: 'RK-TAG-006',
        message: 'the tag object for $tag could not be read',
        remedy: 'Re-run rk release ${unit.name}. The local tag is removed '
            'when it is not on origin, so a re-run starts from a clean state.',
      ),
    );
  }
  if (!present) {
    if (!required) return (signed: false, refusal: null);
    return (
      signed: false,
      refusal: Diagnostic(
        code: 'RK-TAG-006',
        message: 'this project signs its release tags, and $tag was created '
            'without a signature',
        remedy: 'Confirm the signing key works — git tag -s a throwaway tag '
            'and check git cat-file tag on it — then re-run rk release '
            '${unit.name}.',
      ),
    );
  }
  final verified = await destination.verifySignature(object);
  if (!verified.ok) {
    return (
      signed: true,
      refusal: Diagnostic(
        code: 'RK-TAG-007',
        message: '$tag is signed, and its signature could not be verified '
            'on this machine',
        remedy: 'For an SSH signing key, git needs a list of the signers it '
            'should trust: write your public key to an allowed-signers file '
            'and set gpg.ssh.allowedSignersFile to it. rk will not record a '
            'release as signed on a signature it could not check.\n'
            '${verified.summary}',
        evidence: verified.transcript,
      ),
    );
  }
  return (signed: true, refusal: null);
}

/// Whether project configuration or signed release history requires signing.
Future<bool> _signatureRequired(
  TargetReleaseContext context,
  ResolvedUnit unit,
  GitTag destination,
) async {
  if (context.git.tagSigningRequested) return true;
  final pattern = requiredTargetTagPattern(unit, PublishTarget.gitTag);
  for (final tag in context.git.tagsMatching(pattern)) {
    final object = context.git.tagObject(tag);
    if (object == null) continue;
    if (await destination.hasSignature(object) ?? false) return true;
  }
  return false;
}

Future<TargetActOutcome> _pushExisting(
  GitTag destination,
  ResolvedUnit unit, {
  required String? object,
  required bool signed,
}) async {
  final tag = requiredTargetTag(unit, PublishTarget.gitTag);
  if (object == null) {
    return TargetActOutcome(
      ok: false,
      coordinate: tag,
      diagnostic: Diagnostic(
        code: 'RK-TAG-002',
        message: 'the tag $tag could not be pushed',
        remedy: 'the validated local tag object id is unavailable; '
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
        remedy: '${pushed.summary}\nthe tag pre-existed this run, so it '
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
    successNote: [
      if (signed) 'signed, verified' else 'unsigned',
      'pushed',
      'pre-existing local tag',
    ].join(', '),
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
