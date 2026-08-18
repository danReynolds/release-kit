import 'dart:io';

import '../destinations/git_tag.dart';
import '../engine/assets.dart';
import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/publish_target.dart';
import '../engine/resolve.dart';
import '../engine/targets.dart';
import '../engine/verdict.dart';
import '../engine/version.dart';
import '../output/output.dart';
import '../output/progress.dart';
import '../transforms/digest.dart';
import 'target_module.dart';

final class GitTagTargetModule extends TargetModule {
  const GitTagTargetModule();

  @override
  PublishTarget get target => PublishTarget.gitTag;

  @override
  StepKind get stepKind => StepKind.tag;

  @override
  Future<TargetReadinessOutcome> preflight(
    TargetReadinessContext context,
    ResolvedUnit unit,
  ) async =>
      const TargetReady();

  @override
  ProgressActivity get actActivity => ProgressActivity(
        running: 'creating',
        failed: 'tag creation failed',
      );

  @override
  TargetExpectation expectation({
    required ResolvedUnit unit,
    required Step step,
    String? repository,
  }) {
    final tag = requiredTargetTag(unit, PublishTarget.gitTag);
    return TargetExpectation(
      label: 'Git tag',
      kindLabel: 'Git tag',
      identity: tag,
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
  Future<Inspection> inspectExact(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetExpectation target,
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
  Future<Inspection> inspectLatest(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetExpectation target,
  ) {
    final tools = context.tools;
    if (tools == null) {
      return Future.value(
        const Inspection.unknown('no tools to read origin with'),
      );
    }
    return GitTag(tools: tools, root: context.git.root).inspectLatestVersion(
      requiredTargetTagPattern(unit, PublishTarget.gitTag),
    );
  }

  @override
  bool get publicHistorySupersedesLocalTag => true;

  @override
  bool ownsDiagnostic(
    Diagnostic diagnostic,
    TargetExpectation target,
  ) =>
      const {
        'RK-MONO-001',
        'RK-GIT-004',
        'RK-GIT-005',
        'RK-GIT-007',
      }.contains(diagnostic.code);

  @override
  Iterable<Diagnostic> localReleaseDiagnostics(
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
  String conflictRemedy(
    ResolvedUnit unit,
    TargetExpectation target,
  ) =>
      'do not move the public tag. If it is not the intended release, '
      'bump the version and changelog, then stage the new release';

  @override
  Future<TargetActOutcome> act(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetExpectation target,
    Inspection inspected,
  ) async {
    final git = context.git;
    final tag = requiredTargetTag(unit, PublishTarget.gitTag);
    final destination = GitTag(tools: context.tools, root: git.root);
    final signed = git.signingConfigured;
    final required = await _signatureRequired(context, unit, destination);

    // Refuse before creating anything: a project that signs its releases must
    // not produce an unsignable one, and the fix is local configuration.
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

    // A prior interrupted run may have created the exact local tag without
    // getting it to origin. Push that validated object instead of recreating
    // or moving it.
    if (git.hasTag(tag)) {
      // The policy applies to what that earlier run actually produced, not to
      // what this run's configuration would have produced.
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

    final manifestSha256 = _manifestDigest(context, unit);
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

  /// What [object]'s signature actually is, and whether that satisfies the
  /// project's signing policy.
  ///
  /// Presence is read from the object; verifiability is a separate question,
  /// because `git verify-tag` fails both for an unsigned tag and for a signed
  /// one this machine holds no allowed-signers list for. A signature rk cannot
  /// authenticate is refused either way: rk would otherwise report a release as
  /// signed on the strength of bytes it never checked.
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
        ),
      );
    }
    return (signed: true, refusal: null);
  }

  /// Whether this project's next release tag must carry a signature.
  ///
  /// Two signals, both the project's own rather than an rk setting:
  /// `tag.gpgSign` states the intent directly, and a signed release history
  /// states it durably — `.git/config` is not committed, so a fresh clone would
  /// otherwise silently downgrade a project that has always signed.
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

  String _manifestDigest(TargetReleaseContext context, ResolvedUnit unit) {
    final manifest = File(
      context.stage.directory.resolve(ReleaseAssets.manifest),
    );
    if (!manifest.existsSync()) {
      throw StateError('the completed stage has no release manifest');
    }
    return Sha256.hex(manifest.readAsBytesSync());
  }

  @override
  Future<TargetFailure> classifyFailure(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetExpectation target,
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
      ),
      halt: halt,
    );
  }
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
