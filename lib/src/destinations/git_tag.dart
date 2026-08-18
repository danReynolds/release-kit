import '../engine/tools.dart';
import '../engine/verdict.dart';
import '../engine/version.dart';

/// The git tag as a destination, spoken to through git.
///
/// One of the destinations in this directory, beside `github_release.dart`
/// `homebrew.dart`, and `pub_dev.dart`. Its act half remains in
/// `commands/release.dart`; the adapter here owns the one exact read shared by
/// status and both sides of that act.
///
/// It keeps the convention the other two keep: it takes [Tools] and
/// coordinates, never an [Output]. That is the test for whether a cut is a
/// destination at all — prose about what happened belongs to the verb,
/// because only the verb knows what the operator is being told, and when.
///
/// The protocol is here; the halting policy is not. Which halt sentence a
/// failed push earns, and whether the local tag is removed, are decisions
/// about what the operator must be told — they stay in `release.dart`.
/// The signature block every git signing format writes into a tag object:
/// OpenPGP, SSH, and X.509 (gpgsm) respectively.
final _signatureBlock = RegExp(
  r'^-----BEGIN (?:PGP SIGNATURE|SSH SIGNATURE|SIGNED MESSAGE)-----$',
  multiLine: true,
);

class GitTag {
  GitTag({required this.tools, required this.root});

  final Tools tools;

  /// The repository every invocation runs in.
  final String root;

  /// Whether origin lists [tag].
  ///
  /// Three answers, not two. A read that failed is not a tag that is
  /// absent, and the sealed type makes that structural rather than a
  /// discipline each caller has to remember — the same shape the forge
  /// reader already uses for its own lookups.
  Future<TagPresence> onOrigin(String tag) async {
    final result = await tools.run(
      'git',
      ['ls-remote', 'origin', 'refs/tags/$tag'],
      workingDirectory: root,
    );
    if (!result.ok) return TagUnreadable(result.summary);
    return result.stdout.contains('refs/tags/$tag')
        ? const TagListed()
        : const TagNotListed();
  }

  /// The newest semantic version named by a tag on origin matching
  /// [tagPattern]. Direct refs are the inventory; peeled `^{}` lines describe
  /// the same annotated tag and are ignored for version discovery.
  Future<Inspection> inspectLatestVersion(String tagPattern) async {
    final parts = tagPattern.split('{version}');
    if (parts.length != 2) {
      return const Inspection.unknown(
        'the release tag pattern has no single {version} coordinate',
      );
    }
    final ToolResult result;
    try {
      result = await tools.run(
        'git',
        const ['ls-remote', '--tags', 'origin'],
        workingDirectory: root,
      );
    } on Object catch (error) {
      return Inspection.unknown('origin tags could not be read: $error');
    }
    if (!result.ok) {
      return Inspection.unknown(
        'origin tags could not be read: ${result.summary}',
      );
    }

    Version? latest;
    for (final line in result.stdout.split('\n')) {
      if (line.trim().isEmpty) continue;
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length != 2 || !_isObjectId(fields[0])) {
        return const Inspection.unknown(
          'origin returned a malformed tag inventory',
        );
      }
      final ref = fields[1];
      if (!ref.startsWith('refs/tags/')) {
        return const Inspection.unknown(
          'origin returned a malformed tag reference',
        );
      }
      if (ref.endsWith('^{}')) continue;
      final tag = ref.substring('refs/tags/'.length);
      final raw = _versionIn(tag, parts);
      if (raw == null) continue;
      final version = Version.tryParse(raw);
      if (version == null) {
        return Inspection.unknown(
          'the origin tag $tag matches the release pattern but is not a '
          'semantic version',
        );
      }
      if (latest == null || version > latest) latest = version;
    }
    if (latest == null) {
      return const Inspection.absent(
        detail: 'origin has no matching release tag',
      );
    }
    return Inspection.exact(
      detail: 'latest release tag on origin is $latest',
      evidence: {'version': latest.canonical},
    );
  }

  /// Whether origin's [tag] is the exact local tag object and source commit
  /// the caller expects.
  ///
  /// An annotated tag has two identities on the wire: the ref points at the
  /// tag object, while its peeled `^{}` ref points at the commit. Checking
  /// only one loses information — the same source could carry a different
  /// signed tag object, or the same tag-object-shaped answer could peel to a
  /// different source. Lightweight tags use the commit for both expected
  /// values and normally have no peeled line.
  ///
  /// Signature policy deliberately stays with the caller. This reader proves
  /// which object origin has; a policy layer can separately decide whether
  /// that local object was signed as required.
  Future<Inspection> inspect({
    required String tag,
    required String expectedObject,
    required String expectedCommit,
  }) async {
    if (!_isObjectId(expectedObject) || !_isObjectId(expectedCommit)) {
      return const Inspection.unknown(
        'the expected local tag identity could not be read',
      );
    }

    final directRef = 'refs/tags/$tag';
    final peeledRef = '$directRef^{}';
    final parsed = await _read(tag);
    if (parsed.problem != null) {
      return Inspection.unknown(parsed.problem!);
    }
    if (parsed.direct == null) {
      return const Inspection.absent(detail: 'not on origin');
    }

    final expectedObjectId = expectedObject.toLowerCase();
    final expectedCommitId = expectedCommit.toLowerCase();
    final remoteCommit = parsed.peeled ?? parsed.direct!;
    final evidence = <String, String>{};
    if (parsed.direct != expectedObjectId) {
      evidence['tag object'] =
          'origin ${parsed.direct}, expected $expectedObjectId';
    }
    if (remoteCommit != expectedCommitId) {
      evidence['source commit'] =
          'origin $remoteCommit, expected $expectedCommitId';
    }
    if (expectedObjectId != expectedCommitId && parsed.peeled == null) {
      evidence['peeled tag'] =
          'origin did not advertise $peeledRef, expected $expectedCommitId';
    }
    if (evidence.isNotEmpty) {
      return Inspection.conflict(
        'origin has a different tag identity',
        evidence: evidence,
      );
    }

    return Inspection.exact(
      detail: parsed.peeled == null
          ? 'origin points at $expectedCommitId'
          : 'origin has tag object $expectedObjectId, peeled to '
              '$expectedCommitId',
      evidence: {
        'tag object': expectedObjectId,
        'source commit': expectedCommitId,
      },
    );
  }

  /// Reads the public-manifest digest from an exact annotated tag.
  ///
  /// The message is read only after [inspect] has proven that origin carries
  /// the expected direct tag object and peeled source commit. Reading the
  /// local object first would let a stale or unpushed tag lend its binding to
  /// a different public ref. The object is addressed by OID rather than by
  /// the mutable local ref for the same reason.
  Future<TagManifestBinding> manifestBinding({
    required String tag,
    required String expectedObject,
    required String expectedCommit,
  }) async {
    final remote = await inspect(
      tag: tag,
      expectedObject: expectedObject,
      expectedCommit: expectedCommit,
    );
    switch (remote.verdict) {
      case Verdict.absent:
        return TagManifestAbsent(remote.detail ?? 'not on origin');
      case Verdict.conflict:
        return TagManifestConflict(
          remote.detail ?? 'origin has a different tag identity',
          evidence: remote.evidence,
        );
      case Verdict.unknown:
        return TagManifestUnreadable(
          remote.detail ?? 'origin could not be read',
        );
      case Verdict.exact:
        break;
    }

    if (expectedObject.toLowerCase() == expectedCommit.toLowerCase()) {
      return const TagManifestUnbound(
        'the exact remote tag is lightweight and has no annotated message',
      );
    }

    final ToolResult object;
    try {
      object = await tools.run(
        'git',
        ['cat-file', 'tag', expectedObject],
        workingDirectory: root,
      );
    } on Object catch (error) {
      return TagManifestUnreadable('the annotated tag could not be read: '
          '$error');
    }
    if (!object.ok) {
      return TagManifestUnreadable(
        'the annotated tag could not be read: ${object.summary}',
      );
    }
    return _manifestBindingIn(object.stdout);
  }

  /// Proves the release binding carried by origin's annotated tag when the
  /// caller knows the source commit but did not know the tag object id until
  /// after creating/pushing it. When [expectedManifestSha256] is present the
  /// binding must name those exact staged bytes; without a stage, one valid
  /// binding is still required so a malformed release tag is never exact.
  ///
  /// The direct object id is read from origin, its peel must be the expected
  /// source, and `cat-file` addresses that immutable id rather than the mutable
  /// local ref. Thus the message parsed here is the message origin actually
  /// names. When [requireSignature] is true, Git must also authenticate that
  /// same object before the tag step can be called exact.
  Future<Inspection> inspectReleaseBinding({
    required String tag,
    required String expectedCommit,
    required String? expectedManifestSha256,
    required bool requireSignature,
  }) async {
    if (!_isObjectId(expectedCommit) ||
        (expectedManifestSha256 != null &&
            !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(expectedManifestSha256))) {
      return const Inspection.unknown(
        'could not read the expected release tag binding',
      );
    }
    final remote = await _read(tag);
    if (remote.problem != null) return Inspection.unknown(remote.problem!);
    if (remote.direct == null) {
      return const Inspection.absent(detail: 'not on origin');
    }
    if (remote.peeled == null) {
      return const Inspection.conflict(
        'origin has a lightweight release tag with no manifest message',
      );
    }
    final expectedSource = expectedCommit.toLowerCase();
    if (remote.peeled != expectedSource) {
      return Inspection.conflict(
        'origin points the release tag at a different source commit',
        evidence: {
          'source commit': 'origin ${remote.peeled}, expected $expectedSource',
        },
      );
    }

    final object = await tools.run(
      'git',
      ['cat-file', 'tag', remote.direct!],
      workingDirectory: root,
    );
    if (!object.ok) {
      return Inspection.unknown(
        'origin\'s annotated tag object could not be read: ${object.summary}',
      );
    }
    final binding = _manifestBindingIn(object.stdout);
    if (binding is! TagManifestBound) {
      final why = switch (binding) {
        TagManifestAbsent(:final why) ||
        TagManifestMissing(:final why) ||
        TagManifestMalformed(:final why) ||
        TagManifestConflict(:final why) ||
        TagManifestUnreadable(:final why) ||
        TagManifestUnbound(:final why) =>
          why,
        TagManifestBound() => 'unexpected manifest binding state',
      };
      return Inspection.conflict(
        'origin\'s release tag does not carry one valid manifest binding',
        evidence: {'manifest binding': why},
      );
    }
    final digest = binding.digest;
    final expectedDigest = expectedManifestSha256?.toLowerCase();
    if (expectedDigest != null && digest != expectedDigest) {
      return Inspection.conflict(
        'origin\'s release tag binds a different manifest',
        evidence: {
          'manifest sha256': 'origin $digest, expected $expectedDigest',
        },
      );
    }

    if (requireSignature) {
      final verified = await tools.run(
        'git',
        ['verify-tag', remote.direct!],
        workingDirectory: root,
      );
      if (!verified.ok) {
        return Inspection.conflict(
          'origin\'s release tag signature could not be verified',
          evidence: {'signature': verified.summary},
        );
      }
    }
    return Inspection.exact(
      detail: 'origin tag binds the expected source and release manifest',
      evidence: {
        'tag object': remote.direct!,
        'source commit': expectedSource,
        'manifest sha256': digest,
        'signature': requireSignature ? 'verified' : 'not required',
      },
    );
  }

  /// Whether a local tag is safe to use as the input to the next push.
  ///
  /// A remote absence is permission to push only after the existing local
  /// object has passed the same source, manifest, and signature policy as a
  /// public tag. Otherwise a harmless preflight absence would turn a malformed
  /// local tag into an immutable public conflict before rk discovered it.
  Future<Inspection> inspectLocalReleaseBinding({
    required String tag,
    required String expectedObject,
    required String expectedCommit,
    required String? expectedManifestSha256,
    required bool requireSignature,
  }) async {
    if (!_isObjectId(expectedObject) ||
        !_isObjectId(expectedCommit) ||
        (expectedManifestSha256 != null &&
            !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(expectedManifestSha256))) {
      return const Inspection.unknown(
        'the expected local release tag binding could not be read',
      );
    }
    if (expectedObject.toLowerCase() == expectedCommit.toLowerCase()) {
      return const Inspection.conflict(
        'the local release tag is lightweight and has no manifest message',
      );
    }

    final object = await tools.run(
      'git',
      ['cat-file', 'tag', expectedObject],
      workingDirectory: root,
    );
    if (!object.ok) {
      return Inspection.unknown(
        'the local annotated tag object could not be read: ${object.summary}',
      );
    }
    final objectHeader = RegExp(
      r'^object ([0-9a-fA-F]{40,64})$',
      multiLine: true,
    ).firstMatch(object.stdout);
    if (objectHeader == null ||
        objectHeader.group(1)!.toLowerCase() != expectedCommit.toLowerCase()) {
      return Inspection.conflict(
        'the local release tag points at a different source commit',
        evidence: {
          'source commit': 'local ${objectHeader?.group(1) ?? 'unreadable'}, '
              'expected ${expectedCommit.toLowerCase()}',
        },
      );
    }

    final binding = _manifestBindingIn(object.stdout);
    if (binding is! TagManifestBound) {
      final why = switch (binding) {
        TagManifestAbsent(:final why) ||
        TagManifestMissing(:final why) ||
        TagManifestMalformed(:final why) ||
        TagManifestConflict(:final why) ||
        TagManifestUnreadable(:final why) ||
        TagManifestUnbound(:final why) =>
          why,
        TagManifestBound() => 'unexpected manifest binding state',
      };
      return Inspection.conflict(
        'the local release tag does not carry one valid manifest binding',
        evidence: {'manifest binding': why},
      );
    }
    final expectedDigest = expectedManifestSha256?.toLowerCase();
    if (expectedDigest != null && binding.digest != expectedDigest) {
      return Inspection.conflict(
        'the local release tag binds a different manifest',
        evidence: {
          'manifest sha256':
              'local ${binding.digest}, expected $expectedDigest',
        },
      );
    }

    if (requireSignature) {
      final verified = await tools.run(
        'git',
        ['verify-tag', expectedObject],
        workingDirectory: root,
      );
      if (!verified.ok) {
        return Inspection.conflict(
          'the local release tag signature could not be verified',
          evidence: {'signature': verified.summary},
        );
      }
    }
    return Inspection.exact(
      detail: 'the local tag binds the expected source and release manifest',
      evidence: {
        'tag object': expectedObject.toLowerCase(),
        'source commit': expectedCommit.toLowerCase(),
        'manifest sha256': binding.digest,
        'signature': requireSignature ? 'verified' : 'not required',
      },
    );
  }

  Future<_RemoteTag> _read(String tag) async {
    final directRef = 'refs/tags/$tag';
    final peeledRef = '$directRef^{}';
    final ToolResult result;
    try {
      result = await tools.run(
        'git',
        ['ls-remote', 'origin', directRef, peeledRef],
        workingDirectory: root,
      );
    } on Object catch (error) {
      return _RemoteTag(problem: 'origin could not be read: $error');
    }
    if (!result.ok) {
      return _RemoteTag(
        problem: 'origin could not be read: ${result.summary}',
      );
    }
    return _RemoteTag.parse(
      result.stdout,
      directRef: directRef,
      peeledRef: peeledRef,
    );
  }

  /// Whether the annotated tag [object] carries a signature block.
  ///
  /// Read from the object rather than inferred from configuration: `tag.gpgSign`
  /// makes even a `-a` tag signed, so what git was asked to do and what the
  /// object actually holds are different questions. Null when the object could
  /// not be read, which is never treated as an answer either way.
  ///
  /// Presence is deliberately separate from `git verify-tag`, which fails both
  /// for an unsigned tag and for a signed one this machine cannot check
  /// (`gpg.ssh.allowedSignersFile` unset). Those need different remedies.
  Future<bool?> hasSignature(String object) async {
    final ToolResult read;
    try {
      read = await tools.run(
        'git',
        ['cat-file', 'tag', object],
        workingDirectory: root,
      );
    } on Object {
      return null;
    }
    if (!read.ok) return null;
    return _signatureBlock.hasMatch(read.stdout);
  }

  /// Whether git can authenticate [object]'s signature on this machine.
  Future<ToolResult> verifySignature(String object) => tools.run(
        'git',
        ['verify-tag', object],
        workingDirectory: root,
      );

  /// Creates the tag locally, signed when the repository has a key.
  Future<ToolResult> create(
    String tag, {
    required bool signed,
    required String message,
  }) =>
      tools.run(
        'git',
        ['tag', if (signed) '-s' else '-a', tag, '-m', message],
        workingDirectory: root,
      );

  /// Resolves the immutable annotated-tag object currently named by [tag].
  ///
  /// The caller validates that object and then passes its OID to [pushExact].
  /// Keeping the mutable ref name out of the push closes the interval in which
  /// another local process could replace the tag after validation.
  Future<({String? object, String? problem})> localObject(String tag) async {
    final ToolResult result;
    try {
      result = await tools.run(
        'git',
        ['rev-parse', '--verify', 'refs/tags/$tag^{tag}'],
        workingDirectory: root,
      );
    } on Object catch (error) {
      return (object: null, problem: '$error');
    }
    if (!result.ok) return (object: null, problem: result.summary);
    final lines = result.stdout
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.length != 1 || !_isObjectId(lines.single)) {
      return (
        object: null,
        problem: 'git returned an invalid annotated-tag object id',
      );
    }
    return (object: lines.single.toLowerCase(), problem: null);
  }

  /// Pushes the exact validated tag object to the public tag ref.
  Future<ToolResult> pushExact(String tag, String object) {
    if (!_isObjectId(object)) {
      throw ArgumentError.value(object, 'object', 'invalid Git object id');
    }
    return tools.run(
      'git',
      ['push', 'origin', '${object.toLowerCase()}:refs/tags/$tag'],
      workingDirectory: root,
    );
  }

  /// Removes a local tag only while it still names the object rk created.
  ///
  /// Supplying the expected old OID makes the ref update atomic: if another
  /// process replaced the tag after validation, Git refuses instead of
  /// deleting that process's tag.
  Future<ToolResult> deleteLocalIfExact(String tag, String object) {
    if (!_isObjectId(object)) {
      throw ArgumentError.value(object, 'object', 'invalid Git object id');
    }
    return tools.run(
      'git',
      ['update-ref', '-d', 'refs/tags/$tag', object.toLowerCase()],
      workingDirectory: root,
    );
  }
}

String? _versionIn(String tag, List<String> pattern) {
  final prefix = pattern[0];
  final suffix = pattern[1];
  if (!tag.startsWith(prefix) || !tag.endsWith(suffix)) return null;
  final end = tag.length - suffix.length;
  if (end <= prefix.length) return null;
  return tag.substring(prefix.length, end);
}

TagManifestBinding _manifestBindingIn(String tagObject) {
  final messageAt = tagObject.indexOf('\n\n');
  if (messageAt < 0) {
    return const TagManifestMalformed(
      'the annotated tag object has no readable message',
    );
  }
  final message = tagObject.substring(messageAt + 2);
  final candidates = message
      .split('\n')
      .where((line) => line.contains('release-manifest-sha256'))
      .toList();
  if (candidates.isEmpty) {
    return const TagManifestMissing(
      'the annotated tag message has no release-manifest-sha256 binding',
    );
  }
  if (candidates.length != 1) {
    return const TagManifestMalformed(
      'the annotated tag message has more than one manifest binding',
    );
  }
  final match = RegExp(r'^release-manifest-sha256: ([0-9a-f]{64})$')
      .firstMatch(candidates.single);
  if (match == null) {
    return const TagManifestMalformed(
      'the annotated tag message has a malformed manifest binding',
    );
  }
  return TagManifestBound(match.group(1)!);
}

/// What reading an exact remote tag's release-manifest binding produced.
sealed class TagManifestBinding {
  const TagManifestBinding();

  /// Present only when the tag carries one exact lowercase SHA-256 binding.
  String? get sha256 => null;
}

class TagManifestBound extends TagManifestBinding {
  const TagManifestBound(this.digest);

  final String digest;

  @override
  String get sha256 => digest;
}

/// No tag exists at the remote coordinate.
class TagManifestAbsent extends TagManifestBinding {
  const TagManifestAbsent(this.why);
  final String why;
}

/// The exact annotated tag has no binding line.
class TagManifestMissing extends TagManifestBinding {
  const TagManifestMissing(this.why);
  final String why;
}

/// A binding-like line or tag message exists but does not meet the contract.
class TagManifestMalformed extends TagManifestBinding {
  const TagManifestMalformed(this.why);
  final String why;
}

/// Origin carries a different tag object or source commit.
class TagManifestConflict extends TagManifestBinding {
  const TagManifestConflict(this.why, {this.evidence = const {}});
  final String why;
  final Map<String, String> evidence;
}

/// The tag or its object could not be read.
class TagManifestUnreadable extends TagManifestBinding {
  const TagManifestUnreadable(this.why);
  final String why;
}

/// The tag is exact but has no annotated message by construction.
class TagManifestUnbound extends TagManifestBinding {
  const TagManifestUnbound(this.why);
  final String why;
}

class _RemoteTag {
  const _RemoteTag({this.direct, this.peeled, this.problem});

  final String? direct;
  final String? peeled;
  final String? problem;

  static _RemoteTag parse(
    String stdout, {
    required String directRef,
    required String peeledRef,
  }) {
    String? direct;
    String? peeled;
    for (final raw in stdout.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final fields = line.split(RegExp(r'\s+'));
      if (fields.length != 2 || !_isObjectId(fields[0])) {
        return const _RemoteTag(
          problem: 'origin returned a malformed tag identity',
        );
      }
      final oid = fields[0].toLowerCase();
      switch (fields[1]) {
        case final ref when ref == directRef:
          if (direct != null && direct != oid) {
            return const _RemoteTag(
              problem: 'origin returned conflicting tag identities',
            );
          }
          direct = oid;
        case final ref when ref == peeledRef:
          if (peeled != null && peeled != oid) {
            return const _RemoteTag(
              problem: 'origin returned conflicting peeled tag identities',
            );
          }
          peeled = oid;
        default:
          return const _RemoteTag(
            problem: 'origin returned an unexpected tag identity',
          );
      }
    }
    if (direct == null && peeled != null) {
      return const _RemoteTag(
        problem: 'origin returned a peeled tag without its tag ref',
      );
    }
    return _RemoteTag(direct: direct, peeled: peeled);
  }
}

bool _isObjectId(String value) =>
    RegExp(r'^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$').hasMatch(value);

/// What asking origin about a tag produced.
sealed class TagPresence {
  const TagPresence();
}

class TagListed extends TagPresence {
  const TagListed();
}

class TagNotListed extends TagPresence {
  const TagNotListed();
}

/// origin could not be asked — never the same answer as "not there".
class TagUnreadable extends TagPresence {
  const TagUnreadable(this.why);
  final String why;
}
