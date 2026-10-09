import 'dart:io';

import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/identity.dart';
import '../engine/publish_target.dart';
import '../engine/receipt.dart';
import '../engine/resolve.dart';
import '../engine/tools.dart';
import '../output/output.dart';
import '../output/progress.dart';
import '../transforms/macos.dart';

/// Who a unit's macOS binaries are signed as: the code identifier sealed
/// into their designated requirement, and the certificate that signs them.
///
/// It must reproduce the identity users already installed, which the newest
/// published release that shipped a macOS binary states. A first signed
/// release has none to reproduce, and makes the one it signs permanent.
/// [settle] chooses it before any producer runs, so a release that cannot
/// sign as that identity refuses before minutes of builds; each signed build
/// records it, and a reused stage is published under what it recorded.
final class MacIdentity {
  const MacIdentity({
    required this.codeId,
    required this.certificate,
    required this.publishedRequirement,
    this.identity,
  });

  final String codeId;

  /// The signing certificate's name, which says its team.
  final String certificate;

  /// The designated requirement of the release users already installed, or
  /// null on a first signed release.
  final String? publishedRequirement;

  /// The keychain's certificate, present only while a stage is produced: a
  /// reused stage needs what it recorded, not live keychain state.
  final SigningIdentity? identity;

  /// Whether this release signs the program for the first time.
  bool get first => publishedRequirement == null;

  /// Whether [unit] ships a macOS binary, which is signed.
  static bool signs(ResolvedUnit unit) => _project(unit) != null;

  /// Settles the identity [unit]'s macOS builds sign as, before any of its
  /// producers run: the notarization credential is checked, the published
  /// identity read, and the one certificate that reproduces it chosen. Null
  /// when the release is refused, having said why.
  static Future<MacIdentity?> settle(
    Tools tools,
    Output output,
    ResolvedUnit unit,
    GitState git,
  ) async {
    final project = _project(unit)!;
    final live = output.progressBoard(
      '${unit.name} ${unit.version} · preparing stage',
      delay: briefPhase,
      emitSlowToNonTerminal: true,
    );
    final row = live.addRow(
      id: '${unit.name}/release-inputs',
      label: 'Release inputs',
      coordinate: 'notarization and signing identity',
    );
    row.handle.begin(
      ProgressActivity(
        running: 'checking notarization',
        failed: 'notarization check failed',
      ),
    );
    final notary = await MacOsNotarizer(tools: tools).preflight();
    if (!notary.ok) {
      live.conclude();
      output.problem(
        Diagnostic(
          code: 'RK-NOTARY-004',
          message: 'the rk-notary credential is not ready',
          remedy: notary.remedy ?? notary.problem,
          evidence: notary.transcript,
        ),
        unit: unit.name,
      );
      output.halt(HaltKind.beforeActing);
      return null;
    }
    row.handle.begin(
      ProgressActivity(
        running: 'checking signing',
        failed: 'signing check failed',
      ),
    );
    final baseline = await _baseline(tools, output, unit, project, git);
    if (!baseline.ok) {
      live.conclude();
      return null;
    }
    final publishedRequirement = baseline.requirement;
    final certificate = await _certificate(
      tools,
      output,
      unit,
      publishedRequirement,
    );
    if (certificate == null) {
      live.conclude();
      return null;
    }
    final codeId = publishedRequirement == null
        ? project.executable
        : identifierOf(publishedRequirement);
    if (codeId == null || codeId.isEmpty) {
      live.conclude();
      output.problem(
        Diagnostic(
          code: 'RK-SIGN-009',
          message: 'no release states what this program is called',
          remedy: 'declare one executable in the native project manifest',
        ),
      );
      output.halt(HaltKind.beforeActing);
      return null;
    }
    row.complete(note: 'checked');
    live.discard();
    return MacIdentity(
      codeId: codeId,
      certificate: certificate.name,
      publishedRequirement: publishedRequirement,
      identity: certificate,
    );
  }

  /// The identity [receipt]'s signed build recorded, which a reused stage
  /// is published under; null when it signed nothing. A unit signs one
  /// build: its binary's one macOS platform.
  static MacIdentity? recorded(Receipt receipt) {
    for (final evidence in receipt.producers.values) {
      if (evidence['signature'] case final Map signature) {
        return MacIdentity(
          codeId: signature['code_id']! as String,
          certificate: signature['certificate']! as String,
          publishedRequirement: signature['published_requirement'] as String?,
        );
      }
    }
    return null;
  }

  /// The certificate that signs: the one Developer ID on a first release,
  /// or the one for the team [publishedRequirement] names. Null when the
  /// keychain cannot say which, having said why.
  static Future<SigningIdentity?> _certificate(
    Tools tools,
    Output output,
    ResolvedUnit unit,
    String? publishedRequirement,
  ) async {
    final signer = MacOsSigner(tools: tools);
    final certificates = await signer.availableIdentities();
    Diagnostic? refusal;

    if (certificates == null) {
      refusal = Diagnostic(
        code: 'RK-SIGN-006',
        message: 'the login keychain could not be read',
        remedy:
            'signing needs `security find-identity -v -p codesigning` to '
            'answer. This is not the same as having no certificate, and rk '
            'will not guess which it is.',
      );
    } else if (certificates.isEmpty) {
      refusal = Diagnostic(
        code: 'RK-SIGN-007',
        message: 'no Developer ID Application certificate is installed',
        remedy:
            'a signed release needs one in the login keychain — it is '
            'the only certificate that distributes outside the App Store.',
      );
    } else if (publishedRequirement != null &&
        teamOf(publishedRequirement) == null) {
      // The requirement is in hand here, so the question "can rk tell which
      // certificate reproduces this?" is answerable before stage work begins
      // and does not change by waiting. The sign step signs with the
      // certificate chosen here.
      refusal = Diagnostic(
        code: 'RK-SIGN-001',
        message: 'the published release names no team rk can read',
        remedy:
            'its designated requirement carries no subject.OU, so rk '
            'cannot tell which certificate reproduces it.',
      );
    } else if (publishedRequirement != null &&
        teamOf(publishedRequirement) != null &&
        certificates
            .where((c) => c.team == teamOf(publishedRequirement))
            .isEmpty) {
      // The likeliest signing failure of all — a machine that has a
      // certificate, just not the one the published release names — caught
      // before any time goes into a stage whose signing identity can never
      // match the published baseline.
      refusal = Diagnostic(
        code: 'RK-SIGN-010',
        message: 'no certificate for the team the published release names',
        remedy:
            'users installed a binary signed by team '
            '${teamOf(publishedRequirement)}; this machine has '
            '${certificates.map((c) => c.team).join(', ')}. Signing with a '
            'different team ships what macOS treats as a new program.',
      );
    } else if (publishedRequirement != null &&
        certificates
                .where((c) => c.team == teamOf(publishedRequirement))
                .length >
            1) {
      refusal = Diagnostic(
        code: 'RK-SIGN-011',
        message:
            'several certificates for team '
            '${teamOf(publishedRequirement)}, and rk will not '
            'guess which one distributes this',
        remedy:
            'leave one Developer ID Application certificate for that '
            'team in the login keychain.',
      );
    } else if (publishedRequirement == null && certificates.length > 1) {
      // With a published requirement the team is derived from it and the
      // sign step picks by that, so several certificates are fine. Without
      // one, nothing says which of them distributes this — and the first
      // signing is what makes the answer permanent.
      refusal = Diagnostic(
        code: 'RK-SIGN-008',
        message:
            'this machine has ${certificates.length} Developer ID '
            'certificates and nothing published says which distributes this',
        remedy:
            'release once from a machine with one '
            '(${certificates.map((c) => c.team).join(', ')}), and every '
            'release after derives it from what users installed.',
      );
    }

    if (refusal != null) {
      output.problem(refusal, unit: unit.name);
      output.halt(HaltKind.beforeActing);
      return null;
    }
    return publishedRequirement == null
        ? certificates!.single
        : certificates!.singleWhere(
            (certificate) => certificate.team == teamOf(publishedRequirement),
          );
  }

  /// The designated requirement of the newest already-published release,
  /// which is what this release's signature must reproduce.
  ///
  /// Derived, not declared: the complete public release history is searched
  /// newest-to-oldest for the latest release that actually shipped a macOS
  /// binary. That binary is the only authority on what identity this program
  /// has. `none` — no earlier signed release — is a null requirement with
  /// `ok`, and the sign step uses the native executable name.
  /// `unreadable` refuses the whole run before anything public acts. Not
  /// knowing the baseline is not permission to ship a new one.
  static Future<({bool ok, String? requirement})> _baseline(
    Tools tools,
    Output output,
    ResolvedUnit unit,
    ResolvedProject project,
    GitState git,
  ) async {
    if (!unit.publish.contains(PublishTarget.githubRelease) ||
        unit.tagPattern == null) {
      return (ok: true, requirement: null);
    }
    final repository = git.originUrl;
    if (repository == null) return (ok: true, requirement: null);

    final published = PublishedIdentity(
      tools: tools,
      repository: repository,
      workingDirectory: git.root,
    );
    final history = await published.priorReleaseTags(
      tagPattern: unit.tagPattern!,
      before: unit.version,
    );
    if (!history.readable) {
      output.problem(
        Diagnostic(
          code: 'RK-SIGN-004',
          message: 'the identity users already installed could not be read',
          remedy:
              '${history.why}\n'
              'rk must read the complete public release history before it '
              'can decide this is the first signed release.',
        ),
        unit: unit.name,
      );
      output.halt(HaltKind.beforeActing);
      return (ok: false, requirement: null);
    }

    for (final tag in history.tags!) {
      final scratch = Directory.systemTemp.createTempSync('rk-identity-');
      final reading = await published.read(
        tag: tag,
        executable: project.executable!,
        into: '${scratch.path}/published-identity',
      );
      try {
        scratch.deleteSync(recursive: true);
      } on FileSystemException {
        // The published identity answer does not depend on scratch cleanup.
      }
      switch (reading.answer) {
        case IdentityAnswer.found:
          return (ok: true, requirement: reading.requirement);
        case IdentityAnswer.none:
          // A release without this unit's macOS binary is not its signing
          // baseline. Continue to the next older release.
          continue;
        case IdentityAnswer.unreadable:
          output.problem(
            Diagnostic(
              code: 'RK-SIGN-004',
              message:
                  'the identity users already installed could not be '
                  'read',
              remedy:
                  '${reading.why}\n'
                  'rk found a published signing candidate at $tag; until '
                  'that release can be read, a new signature cannot be '
                  'proven continuous with it.',
            ),
            unit: unit.name,
          );
          output.halt(HaltKind.beforeActing);
          return (ok: false, requirement: null);
      }
    }
    return (ok: true, requirement: null);
  }

  /// [unit]'s binary project when it ships a macOS build.
  static ResolvedProject? _project(ResolvedUnit unit) {
    final project = unit.binaryProject;
    return project != null &&
            project.binaryPlatforms.any(
              (platform) => platform.startsWith('macos-'),
            )
        ? project
        : null;
  }

  /// The team id inside a designated requirement, which is the one fact
  /// needed to pick the certificate that can reproduce it.
  ///
  /// The quotes are optional because codesign's requirement printer only
  /// quotes an OU that needs quoting: a team id beginning with a digit
  /// prints as `leaf[subject.OU] = "2DC432GLL2"`, one beginning with a
  /// letter as `leaf[subject.OU] = Q6L2SF6YDW`.
  static String? teamOf(String requirement) => RegExp(
    r'subject\.OU\]\s*=\s*"?([A-Z0-9]+)"?',
  ).firstMatch(requirement)?.group(1);

  /// The program identity a designated requirement names.
  ///
  /// codesign quotes an identifier only when it has to: `rk` prints bare
  /// while `"io.github.danreynolds.keybay.cli"` is quoted, and a program
  /// must recognise its own published identity either way.
  static String? identifierOf(String requirement) {
    final match = RegExp(
      r'identifier\s+(?:"([^"]+)"|([^\s"]+))',
    ).firstMatch(requirement);
    if (match == null) return null;
    return match.group(1) ?? match.group(2);
  }
}
