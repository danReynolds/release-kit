import 'dart:convert';

import '../transforms/macos.dart';
import 'tools.dart';

/// What the signing identity of a release must match, read from the release
/// that is already public.
///
/// Not from the certificate in the keychain. Asking the thing that is about to
/// sign what it is going to sign with is a tautology: it agrees with itself
/// whatever it is, including a certificate that is not the one users have
/// already installed a binary from. The only authority that can say what
/// *this* program is signed by is the copy of it people already have.
///
/// The failure this prevents is a quiet substitution: a new certificate, a new
/// team, or a rebuilt identity ships and every local check passes, while
/// Gatekeeper on a user's machine sees a different program wearing the same
/// name.
class PublishedIdentity {
  PublishedIdentity({
    required this.tools,
    required this.repository,
    required this.workingDirectory,
  });

  final Tools tools;

  /// `owner/name`.
  final String repository;

  final String workingDirectory;

  /// Reads the designated requirement of the macOS binary published at [tag].
  ///
  /// [into] is a directory this may fill with a downloaded archive and its
  /// contents. Nothing is kept: the reading is the product.
  Future<IdentityReading> read({
    required String tag,
    required String executable,
    required String into,
    String platform = 'macos-arm64',
  }) async {
    // No asset is a fact; a failure to ask is not. They are kept apart
    // because the first means "there is no published identity yet" — the
    // honest answer for a first signed release — and the second means rk
    // does not know, which must never read as permission. The distinction
    // is read from the release object's own asset list via `gh api`, whose
    // error line carries the HTTP status — the porcelain download said the
    // same words for a missing release and an unreachable one, and absence
    // used to hang on matching them.
    final viewed = await tools.run(
      'gh',
      ['api', 'repos/$repository/releases/tags/$tag'],
      workingDirectory: workingDirectory,
    );
    if (!viewed.ok) {
      if (viewed.summary.contains('(HTTP 404)')) {
        // GitHub answers 404 for a repository the token cannot see, so a
        // 404 becomes "nothing is published" only once the repository has
        // answered for itself.
        final readable = await tools.run(
          'gh',
          ['repo', 'view', repository, '--json', 'name'],
          workingDirectory: workingDirectory,
        );
        return readable.ok
            ? const IdentityReading.none('no release is published at that tag')
            : IdentityReading.unreadable(
                '$repository could not be read, so rk cannot tell what is '
                'published: ${readable.summary}',
              );
      }
      return IdentityReading.unreadable(
        'the published release could not be read: ${viewed.summary}',
      );
    }

    final String? assetName;
    try {
      final decoded = jsonDecode(viewed.stdout);
      final assets = decoded is Map ? decoded['assets'] : null;
      assetName = assets is! List
          ? null
          : assets
              .whereType<Map>()
              .map((a) => a['name'])
              .whereType<String>()
              .where((name) =>
                  name.startsWith('$executable-') &&
                  name.endsWith('-$platform.tar.gz'))
              .firstOrNull;
    } on Object catch (error) {
      return IdentityReading.unreadable(
        'the release at $tag answered something unreadable: $error',
      );
    }
    if (assetName == null) {
      return const IdentityReading.none(
        'no macOS archive is published under that release',
      );
    }

    final downloaded = await tools.run(
      'gh',
      [
        'release',
        'download',
        tag,
        '--repo',
        repository,
        '--pattern',
        assetName,
        '--dir',
        into,
        '--clobber',
      ],
      workingDirectory: workingDirectory,
    );
    if (!downloaded.ok) {
      // The asset is known to exist — rk just read it in the list — so a
      // failed download is never absence.
      return IdentityReading.unreadable(
        'the published archive could not be downloaded: ${downloaded.summary}',
      );
    }

    final listed = await tools.run(
      'sh',
      ['-c', 'ls $into/*.tar.gz | head -1'],
      workingDirectory: workingDirectory,
    );
    final archive = listed.stdout.trim();
    if (!listed.ok || archive.isEmpty) {
      return const IdentityReading.unreadable(
        'the downloaded archive could not be found',
      );
    }

    final extracted = await tools.run(
      'tar',
      ['-xzf', archive, '-C', into],
      workingDirectory: workingDirectory,
    );
    if (!extracted.ok) {
      return IdentityReading.unreadable(
        'the published archive could not be opened: ${extracted.summary}',
      );
    }

    final requirement = await MacOsSigner(tools: tools)
        .designatedRequirement('$into/$executable');
    if (requirement == null) {
      return const IdentityReading.unreadable(
        'the published binary carries no signature rk could read',
      );
    }
    return IdentityReading.found(requirement);
  }
}

/// What reading the published identity produced.
///
/// Three answers rather than a nullable string, for the reason that recurs
/// everywhere in rk: "there is no published identity" and "rk could not find
/// out" call for opposite responses, and collapsing them lets an unreadable
/// network stand in for a first release.
class IdentityReading {
  const IdentityReading._(this.answer, this.requirement, this.why);

  const IdentityReading.found(String requirement)
      : this._(IdentityAnswer.found, requirement, null);

  /// Nothing is published to compare against — the honest state before a
  /// first signed release.
  const IdentityReading.none(String why)
      : this._(IdentityAnswer.none, null, why);

  const IdentityReading.unreadable(String why)
      : this._(IdentityAnswer.unreadable, null, why);

  /// Which of the three it is, as data. The two null-requirement cases were
  /// distinguishable only by their prose, which is an invitation to
  /// string-match — and the caller that confuses them signs a release against
  /// no identity at all.
  final IdentityAnswer answer;

  final String? requirement;
  final String? why;

  bool get isKnown => answer == IdentityAnswer.found;
}

enum IdentityAnswer {
  /// The published binary yielded its requirement.
  found,

  /// The repository answered, and nothing is published — a first release.
  none,

  /// rk could not find out, which is never permission to proceed.
  unreadable,
}
