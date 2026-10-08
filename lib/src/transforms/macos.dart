import 'dart:convert';
import 'dart:io';

import '../engine/tools.dart';

/// Signs and notarizes a macOS binary.
///
/// The identity is verified against what is already published rather than
/// against the certificate doing the signing, because comparing output to the
/// thing that produced it proves nothing. On macOS the code identity is what
/// the OS ties Keychain items and permission grants to, so a drift here
/// silently locks existing users out of their own data.
const String _emptyEntitlements = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
''';

/// A code directory hash as the kernel compares it: 20 bytes, in hex.
final RegExp _cdhash = RegExp(r'^[0-9a-f]{40}$');

/// A library load constraint that admits only [cdhashes].
///
/// macOS exempts its own libraries from these constraints, so the runtime can
/// still load the system. Any other library is refused, including one signed
/// by the same team: library validation compares teams, and this compares the
/// exact code.
String libraryConstraintPlist(Iterable<String> cdhashes) {
  final data = [
    for (final hash in cdhashes)
      '      <data>${base64.encode(_bytesOfHex(hash))}</data>',
  ].join('\n');
  return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>cdhash</key>
  <dict>
    <key>\$in</key>
    <array>
$data
    </array>
  </dict>
</dict>
</plist>
''';
}

List<int> _bytesOfHex(String hex) => [
  for (var index = 0; index < hex.length; index += 2)
    int.parse(hex.substring(index, index + 2), radix: 16),
];

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
    final result = await tools.run('security', const [
      'find-identity',
      '-v',
      '-p',
      'codesigning',
    ]);
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
      final team = RegExp(
        r'\(([A-Z0-9]{10})\)$',
      ).firstMatch(name ?? '')?.group(1);
      if (name != null && team != null) {
        identities.add(SigningIdentity(name: name, team: team, sha1: sha1));
      }
    }
    return identities;
  }

  /// Signs [binary] with [identity], the certificate the preflight chose,
  /// selected by its SHA-1 token: names are labels and need not be unique.
  /// codesign's run is the result, and its exit status says whether it signed.
  ///
  /// [pinnedLibraries] are the code hashes of the only non-system libraries
  /// [binary] may load. A non-empty list embeds a library load constraint
  /// admitting exactly them.
  Future<ToolResult> sign({
    required String binary,
    required SigningIdentity identity,
    required String codeId,
    List<String> pinnedLibraries = const [],
  }) async {
    // The bundle maps a separately signed AOT module. Clear any entitlements
    // on the SDK runtime; no executable-memory or library-validation exception
    // is needed or inherited from the upstream Dart binary.
    final scratch = Directory.systemTemp.createTempSync('rk-codesign-inputs-');
    try {
      final entitlements = File('${scratch.path}/entitlements.plist')
        ..writeAsStringSync(_emptyEntitlements);
      final constraint = File('${scratch.path}/library-constraint.plist');
      if (pinnedLibraries.isNotEmpty) {
        constraint.writeAsStringSync(libraryConstraintPlist(pinnedLibraries));
      }
      return await tools.run('codesign', [
        '--force',
        '--timestamp',
        '--options=runtime',
        '--entitlements',
        entitlements.path,
        '--identifier',
        codeId,
        // Refuse a constraint this macOS cannot evaluate rather than sign one
        // it would ignore.
        if (pinnedLibraries.isNotEmpty) ...[
          '--enforce-constraint-validity',
          '--library-constraint',
          constraint.path,
        ],
        '--sign',
        identity.sha1,
        binary,
      ]);
    } finally {
      // Inputs to codesign, never artifacts: they must not survive into the
      // staged workspace, even when signing fails.
      scratch.deleteSync(recursive: true);
    }
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

  /// Whether the signature is valid for exactly these bytes, and what
  /// codesign said deciding it.
  ///
  /// This is the verification the display commands are not: it fails on a
  /// binary modified after signing, where `-d -r-` happily prints the
  /// requirement of the signature the modification broke. It answers with
  /// the run rather than a bool because on the failing side codesign's own
  /// account — which resource was sealed wrong — is the whole diagnosis.
  Future<ToolResult> verifies(String binary) =>
      tools.run('codesign', ['--verify', '--strict', binary]);

  /// The code directory hashes of a signed binary, one per hash algorithm its
  /// signature carries, each truncated to the 20 bytes the kernel compares.
  /// [hashes] is null when codesign cannot say; [display] is codesign's run
  /// either way, so a failure can show what it said.
  Future<({List<String>? hashes, ToolResult display})> codeDirectoryHashes(
    String binary,
  ) async {
    final display = await tools.run('codesign', ['-dvvv', binary]);
    if (!display.ok) return (hashes: null, display: display);
    final hashes = {
      for (final match in RegExp(
        r'^CandidateCDHash \w+=(\S+)$',
        multiLine: true,
      ).allMatches('${display.stdout}\n${display.stderr}'))
        match.group(1)!.toLowerCase(),
    };
    if (hashes.isEmpty || hashes.any((hash) => !_cdhash.hasMatch(hash))) {
      return (hashes: null, display: display);
    }
    return (hashes: hashes.toList()..sort(), display: display);
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

  /// The SHA-1 token `security find-identity` names the exact keychain
  /// identity by, which codesign selects it by.
  final String sha1;
}

/// Submits a signed binary to Apple and waits for a verdict.
class MacOsNotarizer {
  MacOsNotarizer({required this.tools, this.profile = 'rk-notary'});

  final Tools tools;

  /// The `notarytool` keychain profile rk expects, by convention rather than
  /// configuration. rk never sees the credential it holds.
  final String profile;

  /// Proves the configured profile can authenticate before producer work.
  ///
  /// Reading submission history is the lightest notarytool operation that
  /// exercises both the keychain profile and Apple's service. Merely finding
  /// a keychain item would defer an expired or malformed credential until
  /// after compilation and signing.
  Future<NotaryPreflightOutcome> preflight() async {
    final ToolResult result;
    try {
      result = await tools.run('xcrun', [
        'notarytool',
        'history',
        '--keychain-profile',
        profile,
        '--output-format',
        'json',
      ], timeout: const Duration(seconds: 45));
    } on Object catch (error) {
      return NotaryPreflightOutcome.failed(
        'notarytool could not be started',
        remedy:
            'install the Xcode command-line tools and verify the '
            '$profile credential with: xcrun notarytool history '
            '--keychain-profile $profile',
        transcript: '$error',
      );
    }
    if (result.ok) return const NotaryPreflightOutcome.ready();

    final account = '${result.stdout}\n${result.stderr}'.toLowerCase();
    final missing =
        account.contains('profile') ||
        account.contains('keychain') ||
        account.contains('credentials');
    return NotaryPreflightOutcome.failed(
      result.summary,
      remedy: missing
          ? 'store or replace the credential once: xcrun notarytool '
                'store-credentials $profile'
          : 'restore access to Apple\'s notarization service and verify the '
                '$profile credential with: xcrun notarytool history '
                '--keychain-profile $profile',
      transcript: result.transcript,
    );
  }

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
      final missing =
          result.summary.contains('profile') ||
          result.summary.contains('keychain');
      return NotarizeOutcome.failed(
        result.summary,
        remedy: missing
            ? 'store the credential once: xcrun notarytool '
                  'store-credentials $profile'
            : null,
        transcript: result.transcript,
      );
    }

    // One answer, read once: notarytool's JSON names the submission and
    // Apple's verdict.
    String? id;
    String? status;
    try {
      final answer = jsonDecode(result.stdout);
      if (answer is Map) {
        id = answer['id'] is String ? answer['id'] as String : null;
        status = answer['status'] is String ? answer['status'] as String : null;
      }
    } on FormatException {
      // Not JSON: no verdict, which is not an acceptance.
    }

    if (status != 'Accepted') {
      // A rejection exits 0, so the submit output is a status line and not a
      // reason. The reason is in Apple's log, which rk can fetch as easily
      // as it can tell a person to — and telling them to run a command that
      // needs an id rk already has is not a diagnosis.
      final reason = id == null ? null : await log(id);
      return NotarizeOutcome.failed(
        'Apple did not accept it',
        remedy: id == null
            ? null
            : 'the reason is in the log: xcrun notarytool log $id '
                  '--keychain-profile $profile',
        transcript: [
          result.transcript,
          if (reason != null && reason.ok) ...[
            '--- notarytool log $id ---',
            reason.stdout.trimRight(),
          ],
        ].join('\n'),
      );
    }
    return NotarizeOutcome.accepted(id);
  }

  /// Apple's log for a submission: what it checked, and why it refused.
  Future<ToolResult> log(String submissionId) => tools.run('xcrun', [
    'notarytool',
    'log',
    submissionId,
    '--keychain-profile',
    profile,
  ]);
}

class NotaryPreflightOutcome {
  const NotaryPreflightOutcome._(this.problem, this.remedy, this.transcript);
  const NotaryPreflightOutcome.ready() : this._(null, null, null);
  const NotaryPreflightOutcome.failed(
    String problem, {
    required String remedy,
    String? transcript,
  }) : this._(problem, remedy, transcript);

  final String? problem;
  final String? remedy;
  final String? transcript;

  bool get ok => problem == null;
}

class NotarizeOutcome {
  const NotarizeOutcome._(
    this.submissionId,
    this.problem,
    this.remedy, {
    this.transcript,
  });
  const NotarizeOutcome.accepted(String? id) : this._(id, null, null);
  const NotarizeOutcome.failed(
    String problem, {
    String? remedy,
    String? transcript,
  }) : this._(null, problem, remedy, transcript: transcript);

  /// Apple's id for an accepted submission, which a person can ask Apple
  /// about later.
  final String? submissionId;
  final String? problem;
  final String? remedy;

  /// notarytool's own words for a rejected or failed submission, with
  /// Apple's log when rk could fetch it.
  final String? transcript;

  bool get ok => problem == null;
}
