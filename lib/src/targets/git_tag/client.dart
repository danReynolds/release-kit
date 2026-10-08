import '../../engine/tools.dart';
import '../../engine/verdict.dart';
import '../../engine/version.dart';

/// The git tag as a destination, spoken to through git.
///
/// The transport adapter for the Git-tag target. The target module owns the
/// release lifecycle, while this client owns exact reads and writes through
/// git.
///
/// It keeps the convention the other two keep: it takes [Tools] and
/// coordinates, never an [Output]. That is the test for whether a cut is a
/// destination at all — prose about what happened belongs to the verb,
/// because only the verb knows what the operator is being told, and when.
///
/// The protocol is here; the halting policy remains in the target module.

/// The run's one read of origin's tags.
const originTagsKey = 'git ls-remote --tags origin';

class GitTag {
  GitTag({required this.tools, required this.root});

  final Tools tools;

  /// The repository every invocation runs in.
  final String root;

  /// The newest semantic version named by a tag on origin matching
  /// [tagPattern]. Direct refs are the inventory; peeled `^{}` lines describe
  /// the same annotated tag and are ignored for version discovery.
  Future<Inspection> inspectLatestVersion(
    String tagPattern, {
    Future<ToolResult>? listing,
  }) async {
    final parts = tagPattern.split('{version}');
    if (parts.length != 2) {
      return const Inspection.unknown(
        'the release tag pattern has no single {version} coordinate',
      );
    }
    final ToolResult result;
    try {
      result = await (listing ?? listTags());
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
      // A tag that names no semantic version, `v1.0` or `vnext`, is no
      // release of this lane, as the local check reads it too.
      final version = Version.tryParse(_versionIn(tag, parts) ?? '');
      if (version == null) continue;
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

  /// Every tag origin has, with the commit each annotated tag peels to.
  Future<ToolResult> listTags() => tools.run('git', const [
    'ls-remote',
    '--tags',
    'origin',
  ], workingDirectory: root);

  /// Proves the release binding carried by origin's annotated tag, read from
  /// [listing], the run's one read of origin's tags. When
  /// [expectedManifestSha256] is present the binding must name those exact
  /// staged bytes; without a stage, one valid binding is still required so a
  /// malformed release tag is never exact.
  ///
  /// The direct object id is read from origin, its peel must be the expected
  /// source, and `cat-file` addresses that immutable id rather than the mutable
  /// local ref. Thus the message parsed here is the message origin actually
  /// names.
  ///
  /// A tag on an earlier commit still releases this version when nothing
  /// under [sourcePaths], the unit's own directories, has changed since:
  /// later commits elsewhere in the repository change nothing it published.
  /// Its manifest then describes that earlier commit, so it is not compared
  /// with a stage made from this one.
  Future<Inspection> inspectReleaseBinding({
    required String tag,
    required String expectedCommit,
    required String? expectedManifestSha256,
    List<String> sourcePaths = const [],
    Future<ToolResult>? listing,
  }) async {
    if (!_isObjectId(expectedCommit) ||
        (expectedManifestSha256 != null &&
            !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(expectedManifestSha256))) {
      return const Inspection.unknown(
        'could not read the expected release tag binding',
      );
    }
    final remote = await _read(tag, listing: listing ?? listTags());
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
    final sameCommit = remote.peeled == expectedSource;
    final (:unchanged, :why) = sameCommit
        ? (unchanged: true, why: null)
        : await _unchangedSince(remote.peeled!, expectedSource, sourcePaths);
    if (unchanged == null) {
      return Inspection.unknown(
        'origin\'s tag names ${remote.peeled!.substring(0, 7)}, which could '
        'not be compared with HEAD ($why). If this clone lacks it, fetch it: '
        'git fetch origin tag $tag',
        releasedFrom: remote.peeled!,
      );
    }
    final sourceMatches = unchanged;

    final object = await tools.run('git', [
      'cat-file',
      'tag',
      remote.direct!,
    ], workingDirectory: root);
    if (!object.ok) {
      return Inspection.unknown(
        'origin\'s annotated tag object could not be read: ${object.summary}',
      );
    }
    final (:digest, :problem) = _manifestBindingIn(object.stdout);
    if (digest == null) {
      return Inspection.conflict(
        'origin\'s release tag does not carry one valid manifest binding',
        evidence: {'manifest binding': problem!},
      );
    }
    final expectedDigest = expectedManifestSha256?.toLowerCase();
    if (sameCommit && expectedDigest != null && digest != expectedDigest) {
      return Inspection.conflict(
        'origin\'s release tag binds a different manifest',
        evidence: {
          'manifest sha256': 'origin $digest, expected $expectedDigest',
        },
      );
    }

    if (!sourceMatches) {
      return Inspection.conflict(
        'this version was released from a different source commit',
        sourceMismatch: SourceBindingMismatch(
          releasedCommit: remote.peeled!,
          currentCommit: expectedSource,
        ),
        evidence: {
          'tag object': remote.direct!,
          'released source commit': remote.peeled!,
          'current source commit': expectedSource,
          'manifest sha256': digest,
        },
      );
    }
    return Inspection.exact(
      detail: sameCommit
          ? 'origin tag binds the expected source and release manifest'
          : 'origin tag binds ${remote.peeled!.substring(0, 7)}, and nothing '
                'this unit releases has changed since',
      evidence: {
        'tag object': remote.direct!,
        'source commit': remote.peeled!,
        'manifest sha256': digest,
      },
      releasedFrom: sameCommit ? null : remote.peeled!,
    );
  }

  /// Whether nothing under [paths] differs between [released] and
  /// [current]: false when there are no paths, and null, with Git's reason,
  /// when Git cannot compare the two, as when the released commit is not in
  /// this clone.
  ///
  /// Plumbing, with literal paths, so no diff configuration or glob in a
  /// directory's name changes the answer.
  Future<({bool? unchanged, String? why})> _unchangedSince(
    String released,
    String current,
    List<String> paths,
  ) async {
    if (paths.isEmpty || !_isObjectId(released)) {
      return (unchanged: false, why: null);
    }
    final diff = await tools.run('git', [
      '--literal-pathspecs',
      'diff-tree',
      '--quiet',
      '-r',
      '$released^{commit}',
      current,
      '--',
      ...paths,
    ], workingDirectory: root);
    return switch (diff.exitCode) {
      0 => (unchanged: true, why: null),
      1 => (unchanged: false, why: null),
      _ => (unchanged: null, why: diff.summary),
    };
  }

  /// Whether a local tag is safe to use as the input to the next push.
  ///
  /// A remote absence is permission to push only after the existing local
  /// object has passed the same source and manifest policy as a public tag.
  /// Otherwise a harmless preflight absence would turn a malformed local tag
  /// into an immutable public conflict before rk discovered it.
  Future<Inspection> inspectLocalReleaseBinding({
    required String tag,
    required String expectedObject,
    required String expectedCommit,
    required String? expectedManifestSha256,
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

    final object = await tools.run('git', [
      'cat-file',
      'tag',
      expectedObject,
    ], workingDirectory: root);
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
          'source commit':
              'local ${objectHeader?.group(1) ?? 'unreadable'}, '
              'expected ${expectedCommit.toLowerCase()}',
        },
      );
    }

    final (:digest, :problem) = _manifestBindingIn(object.stdout);
    if (digest == null) {
      return Inspection.conflict(
        'the local release tag does not carry one valid manifest binding',
        evidence: {'manifest binding': problem!},
      );
    }
    final expectedDigest = expectedManifestSha256?.toLowerCase();
    if (expectedDigest != null && digest != expectedDigest) {
      return Inspection.conflict(
        'the local release tag binds a different manifest',
        evidence: {
          'manifest sha256': 'local $digest, expected $expectedDigest',
        },
      );
    }

    return Inspection.exact(
      detail: 'the local tag binds the expected source and release manifest',
      evidence: {
        'tag object': expectedObject.toLowerCase(),
        'source commit': expectedCommit.toLowerCase(),
        'manifest sha256': digest,
      },
    );
  }

  /// Origin's [tag] now, read on its own rather than from the run's listing:
  /// the object it names, and the commit that object peels to.
  Future<({String? object, String? commit, String? problem})> onOrigin(
    String tag,
  ) async {
    final remote = await _read(tag);
    return (
      object: remote.direct,
      commit: remote.peeled ?? remote.direct,
      problem: remote.problem,
    );
  }

  Future<_RemoteTag> _read(String tag, {Future<ToolResult>? listing}) async {
    final directRef = 'refs/tags/$tag';
    final peeledRef = '$directRef^{}';
    final ToolResult result;
    try {
      result =
          await (listing ??
              tools.run('git', [
                'ls-remote',
                'origin',
                directRef,
                peeledRef,
              ], workingDirectory: root));
    } on Object catch (error) {
      return _RemoteTag(problem: 'origin could not be read: $error');
    }
    if (!result.ok) {
      return _RemoteTag(problem: 'origin could not be read: ${result.summary}');
    }
    return _RemoteTag.parse(
      [
        for (final line in result.stdout.split('\n'))
          if (line.trim().endsWith(directRef) ||
              line.trim().endsWith(peeledRef))
            line,
      ].join('\n'),
      directRef: directRef,
      peeledRef: peeledRef,
    );
  }

  /// Creates the annotated tag [tag] on [commit], never on whatever HEAD is
  /// by the time the release reaches this step; signed when [signed] says so.
  Future<ToolResult> create(
    String tag, {
    required String commit,
    required bool signed,
    required String message,
  }) => tools.run('git', [
    'tag',
    if (signed) '-s' else '-a',
    tag,
    commit,
    '-m',
    message,
  ], workingDirectory: root);

  /// Resolves the immutable annotated-tag object currently named by [tag].
  ///
  /// The caller passes its OID to [pushExact]. Keeping the mutable ref name
  /// out of the push means the object pushed is the one rk created.
  Future<({String? object, String? problem})> localObject(String tag) async {
    final ToolResult result;
    try {
      result = await tools.run('git', [
        'rev-parse',
        '--verify',
        'refs/tags/$tag^{tag}',
      ], workingDirectory: root);
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

  /// Pushes the exact tag object to the public tag ref.
  ///
  /// Git refuses to replace a tag origin already has, and pushing the object
  /// origin already has succeeds, so its answer settles the push.
  Future<ToolResult> pushExact(String tag, String object) {
    if (!_isObjectId(object)) {
      throw ArgumentError.value(object, 'object', 'invalid Git object id');
    }
    return tools.run('git', [
      'push',
      'origin',
      '${object.toLowerCase()}:refs/tags/$tag',
    ], workingDirectory: root);
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
    return tools.run('git', [
      'update-ref',
      '-d',
      'refs/tags/$tag',
      object.toLowerCase(),
    ], workingDirectory: root);
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

/// The release-manifest digest an annotated tag object's message binds, or
/// why it binds none.
({String? digest, String? problem}) _manifestBindingIn(String tagObject) {
  ({String? digest, String? problem}) none(String problem) =>
      (digest: null, problem: problem);
  final messageAt = tagObject.indexOf('\n\n');
  if (messageAt < 0) {
    return none('the annotated tag object has no readable message');
  }
  final candidates = tagObject
      .substring(messageAt + 2)
      .split('\n')
      .where((line) => line.contains('release-manifest-sha256'))
      .toList();
  if (candidates.isEmpty) {
    return none(
      'the annotated tag message has no release-manifest-sha256 binding',
    );
  }
  if (candidates.length != 1) {
    return none('the annotated tag message has more than one manifest binding');
  }
  final match = RegExp(
    r'^release-manifest-sha256: ([0-9a-f]{64})$',
  ).firstMatch(candidates.single);
  if (match == null) {
    return none('the annotated tag message has a malformed manifest binding');
  }
  return (digest: match.group(1)!, problem: null);
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
