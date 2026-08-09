import '../engine/tools.dart';

/// Signs and notarizes a macOS binary.
///
/// The identity is verified against what is already published rather than
/// against the certificate doing the signing, because comparing output to the
/// thing that produced it proves nothing. On macOS the code identity is what
/// the OS ties Keychain items and permission grants to, so a drift here
/// silently locks existing users out of their own data.
class MacOsSigner {
  MacOsSigner({required this.tools});

  final Tools tools;

  /// The `Developer ID Application` identities in the login keychain, or
  /// null when the keychain could not be read at all.
  ///
  /// Filtered to that type: it is the only certificate that can distribute a
  /// signed binary outside the App Store.
  ///
  /// Null rather than empty for an unreadable keychain, because they are
  /// different facts with different remedies — "install a Developer ID
  /// certificate" is wrong advice on a host that has no `security` at all —
  /// and collapsing them is the same mistake as an absent verdict for a
  /// destination nobody asked.
  Future<List<SigningIdentity>?> availableIdentities() async {
    final result = await tools.run(
      'security',
      const ['find-identity', '-v', '-p', 'codesigning'],
    );
    if (!result.ok) return null;

    final identities = <SigningIdentity>[];
    for (final line in result.stdout.split('\n')) {
      if (!line.contains('Developer ID Application')) continue;
      final parsed = RegExp(
        r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"',
      ).firstMatch(line);
      if (parsed == null) return null;
      final sha1 = parsed.group(1)!.toLowerCase();
      final name = parsed.group(2);
      final team =
          RegExp(r'\(([A-Z0-9]{10})\)$').firstMatch(name ?? '')?.group(1);
      if (name != null && team != null) {
        identities.add(SigningIdentity(
          name: name,
          team: team,
          sha1: sha1,
        ));
      }
    }
    return identities;
  }

  /// The SHA-256 fingerprint of the exact certificate identity selected by
  /// `find-identity`.
  ///
  /// `find-certificate -Z` emits both SHA-256 and SHA-1. Names alone are not
  /// unique, so the SHA-1 identity token correlates the selected signing
  /// identity to the right certificate block; the stronger SHA-256 value is
  /// what the stage records.
  Future<String?> certificateSha256(SigningIdentity identity) async {
    final result = await tools.run('security', [
      'find-certificate',
      '-a',
      '-c',
      identity.name,
      '-Z',
    ]);
    if (!result.ok) return null;
    final starts = RegExp(
      r'SHA-256 hash:\s*([0-9A-Fa-f]{64})',
    ).allMatches(result.stdout).toList();
    for (var index = 0; index < starts.length; index++) {
      final match = starts[index];
      final end = index + 1 < starts.length
          ? starts[index + 1].start
          : result.stdout.length;
      final block = result.stdout.substring(match.start, end);
      final sha1 = RegExp(
        r'SHA-1 hash:\s*([0-9A-Fa-f]{40})',
      ).firstMatch(block)?.group(1)?.toLowerCase();
      if (sha1 == identity.sha1) return match.group(1)!.toLowerCase();
    }
    return null;
  }

  /// Signs [binary]. [team] selects the certificate when the published
  /// release names one; without it the certificate is discovered, because
  /// capabilities are discovered and never declared — and a machine with
  /// one Developer ID has nothing to declare.
  Future<SignOutcome> sign({
    required String binary,
    required String? team,
    required String codeId,
    SigningIdentity? selectedIdentity,
    String? expectedCertificateSha256,
  }) async {
    final identities = await availableIdentities();
    if (identities == null) {
      return SignOutcome.failed('the login keychain could not be read');
    }
    if (identities.isEmpty) {
      return SignOutcome.failed(
        'no Developer ID Application certificate is installed',
      );
    }

    final matching = selectedIdentity == null
        ? (team == null
            ? identities
            : identities.where((i) => i.team == team).toList())
        : identities
            .where((identity) => identity.sha1 == selectedIdentity.sha1)
            .toList();

    if (matching.isEmpty) {
      return SignOutcome.failed(
        'no certificate for team $team; this machine has '
        '${identities.map((i) => i.team).join(', ')}',
      );
    }
    if (matching.length > 1) {
      return SignOutcome.failed(
        team == null
            ? 'this machine has ${matching.length} Developer ID certificates '
                '(${matching.map((i) => i.team).join(', ')}) and nothing '
                'published says which one distributes this — release once '
                'from a machine with one, and every release after derives it'
            : '${matching.length} certificates for team $team — rk will not '
                'guess which one distributes this',
      );
    }

    final selected = matching.single;
    if (selectedIdentity != null &&
        (selected.name != selectedIdentity.name ||
            selected.team != selectedIdentity.team)) {
      return SignOutcome.failed(
        'the selected signing certificate changed after preflight',
      );
    }
    final certificateSha256 = await this.certificateSha256(selected);
    if (certificateSha256 == null) {
      return SignOutcome.failed(
        'the selected certificate SHA-256 fingerprint could not be read',
      );
    }
    if (expectedCertificateSha256 != null &&
        certificateSha256 != expectedCertificateSha256) {
      return SignOutcome.failed(
        'the selected certificate fingerprint changed after preflight',
      );
    }

    final signed = await tools.run('codesign', [
      '--force',
      '--timestamp',
      '--options=runtime',
      '--identifier',
      codeId,
      '--sign',
      // Names are display labels and need not be unique. The SHA-1 identity
      // token is the exact keychain selector emitted by find-identity; the
      // stage records the correlated SHA-256 certificate fingerprint.
      selected.sha1,
      binary,
    ]);
    if (!signed.ok) return SignOutcome.failed(signed.summary);

    final requirement = await designatedRequirement(binary);
    if (requirement == null) {
      return SignOutcome.failed('the signature could not be read back');
    }
    if (!await verifies(binary)) {
      return SignOutcome.failed('the signature did not verify after signing');
    }
    return SignOutcome.signed(
      requirement,
      certificate: selected.name,
      certificateSha256: certificateSha256,
    );
  }

  /// The designated requirement of an already-signed binary.
  ///
  /// This is what a release must match: read it from the currently published
  /// binary, and compare the new one against it.
  ///
  /// A display, not a verification: `codesign -d` prints the requirement —
  /// exit 0 and all — for a binary whose code was modified after signing.
  /// Anything trusting the *bytes* must call [verifies] first.
  Future<String?> designatedRequirement(String binary) async {
    final result = await tools.run('codesign', ['-d', '-r-', binary]);
    if (!result.ok) return null;
    final text = '${result.stdout}\n${result.stderr}';
    for (final line in text.split('\n')) {
      if (line.startsWith('designated =>')) return line.trim();
    }
    return null;
  }

  /// Whether the signature is valid for exactly these bytes.
  ///
  /// This is the verification the display commands are not: it fails on a
  /// binary modified after signing, where `-d -r-` happily prints the
  /// requirement of the signature the modification broke.
  Future<bool> verifies(String binary) async {
    final result =
        await tools.run('codesign', ['--verify', '--strict', binary]);
    return result.ok;
  }

  /// Whether Apple has notarized these exact bytes.
  Future<bool> isNotarized(String binary) async {
    final result = await tools
        .run('codesign', ['--test-requirement=notarized', '-v', binary]);
    return result.ok;
  }
}

class SigningIdentity {
  const SigningIdentity({
    required this.name,
    required this.team,
    required this.sha1,
  });

  /// The full certificate common name, which codesign selects by.
  final String name;
  final String team;

  /// The SHA-1 token `security find-identity` uses to name the exact
  /// keychain identity. It is correlation only; stage evidence records the
  /// SHA-256 certificate fingerprint read through that token.
  final String sha1;
}

class SignOutcome {
  const SignOutcome._(
    this.requirement,
    this.problem, {
    this.certificate,
    this.certificateSha256,
  });
  const SignOutcome.signed(
    String requirement, {
    String? certificate,
    String? certificateSha256,
  }) : this._(
          requirement,
          null,
          certificate: certificate,
          certificateSha256: certificateSha256,
        );
  const SignOutcome.failed(String problem) : this._(null, problem);

  /// The designated requirement the signature produced.
  final String? requirement;
  final String? problem;

  /// The certificate that signed, named so a first release can show which
  /// identity it just made permanent.
  final String? certificate;

  /// The SHA-256 fingerprint of [certificate].
  final String? certificateSha256;

  bool get ok => requirement != null;
}

/// Submits a signed binary to Apple and waits for a verdict.
class MacOsNotarizer {
  MacOsNotarizer({required this.tools, this.profile = 'rk-notary'});

  final Tools tools;

  /// The `notarytool` keychain profile rk expects, by convention rather than
  /// configuration. rk never sees the credential it holds.
  final String profile;

  Future<NotarizeOutcome> submit(String zipPath) async {
    final result = await tools.run('xcrun', [
      'notarytool',
      'submit',
      zipPath,
      '--keychain-profile',
      profile,
      '--wait',
      '--output-format',
      'json',
    ]);

    if (!result.ok) {
      final missing = result.summary.contains('profile') ||
          result.summary.contains('keychain');
      return NotarizeOutcome.failed(
        result.summary,
        remedy: missing
            ? 'store the credential once: xcrun notarytool '
                'store-credentials $profile'
            : null,
      );
    }

    // The submission id is what a later run correlates against, so it is
    // reported even on success.
    final id =
        RegExp(r'"id"\s*:\s*"([^"]+)"').firstMatch(result.stdout)?.group(1);
    final accepted = result.stdout.contains('"status":"Accepted"') ||
        result.stdout.contains('"status": "Accepted"');

    if (!accepted) {
      return NotarizeOutcome.failed(
        'Apple did not accept it',
        remedy: id == null
            ? null
            : 'the reason is in the log: xcrun notarytool log $id '
                '--keychain-profile $profile',
      );
    }
    return NotarizeOutcome.accepted(id, raw: result.stdout);
  }

  /// Apple's log for a submission — the evidence of what was checked.
  ///
  /// Published with the release: the result says Accepted, the log says what
  /// that claim covered, and a user who trusts neither can ask Apple with
  /// the id inside them.
  Future<ToolResult> log(String submissionId) => tools.run('xcrun', [
        'notarytool',
        'log',
        submissionId,
        '--keychain-profile',
        profile,
      ]);
}

class NotarizeOutcome {
  const NotarizeOutcome._(this.submissionId, this.problem, this.remedy,
      {this.raw});
  const NotarizeOutcome.accepted(String? id, {String? raw})
      : this._(id, null, null, raw: raw);
  const NotarizeOutcome.failed(String problem, {String? remedy})
      : this._(null, problem, remedy);

  final String? submissionId;
  final String? problem;
  final String? remedy;

  /// notarytool's own words for an accepted submission, kept verbatim
  /// because they become a published asset.
  final String? raw;

  bool get ok => problem == null;
}
