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
    final pattern = '$executable-*-$platform.tar.gz';

    final downloaded = await tools.run(
      'gh',
      [
        'release',
        'download',
        tag,
        '--repo',
        repository,
        '--pattern',
        pattern,
        '--dir',
        into,
        '--clobber',
      ],
      workingDirectory: workingDirectory,
    );
    if (!downloaded.ok) {
      final said = downloaded.summary.toLowerCase();
      // No asset is a fact; a failure to ask is not. They are kept apart
      // because the first means "there is no published identity yet" — the
      // honest answer for a first signed release — and the second means rk
      // does not know, which must never read as permission.
      //
      // gh gives the same words for a release that is missing and a
      // repository it cannot see, so absence is only concluded once the
      // repository has answered for itself.
      if (said.contains('no assets match') ||
          said.contains('release not found')) {
        final readable = await tools.run(
          'gh',
          ['repo', 'view', repository, '--json', 'name'],
          workingDirectory: workingDirectory,
        );
        return readable.ok
            ? const IdentityReading.none(
                'no macOS archive is published under that release',
              )
            : IdentityReading.unreadable(
                '$repository could not be read, so rk cannot tell what is '
                'published: ${readable.summary}',
              );
      }
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
  const IdentityReading._(this.requirement, this.why);

  const IdentityReading.found(String requirement) : this._(requirement, null);

  /// Nothing is published to compare against — the honest state before a
  /// first signed release.
  const IdentityReading.none(String why) : this._(null, why);

  const IdentityReading.unreadable(String why) : this._(null, why);

  final String? requirement;
  final String? why;

  bool get isKnown => requirement != null;
}
