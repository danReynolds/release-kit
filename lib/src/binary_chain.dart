import 'dart:convert';
import 'dart:io';

import 'builds/capability.dart';
import 'builds/dart_cli.dart';
import 'engine/assets.dart';
import 'engine/checklist.dart';
import 'engine/diagnostic.dart';
import 'output/output.dart';
import 'output/progress.dart';
import 'engine/resolve.dart';
import 'engine/stage_archive.dart';
import 'engine/tools.dart';
import 'engine/verdict.dart';
import 'engine/workspace.dart';
import 'transforms/archive.dart';
import 'transforms/digest.dart';
import 'transforms/macos.dart';

/// The local half of shipping binaries, one checklist step at a time.
///
/// It sits at the top of `lib/src` because it belongs to none of the
/// directories below it. It is not a verb — no argument parsing, no exit
/// codes; its API is buildStep, notarizeStep, and archiveStep, each called by
/// `commands/release.dart`. And it is not an
/// adapter by this codebase's own test, the one `destinations/git_tag.dart`
/// states: it holds an [Output] at thirty-odd sites, where every file in
/// `builds/`, `transforms/` and `destinations/` holds one at zero.
///
/// It lived in `commands/` until `ls` there exposed a non-command alongside
/// the operational verbs promised by the README and RFC.
///
/// This used to be one `produce()` that ran the whole chain inside the first
/// build step and handed a `_produced` list to the steps after it — which
/// made the checklist's ten steps a fiction: per-step verdicts were
/// invented, a mid-chain failure was reported against the wrong step, and
/// CI could never split what one step secretly did. Now each step is its own
/// act: it reads what it needs from the [Workspace] by name, does one thing,
/// and writes what it made back by name. Nothing is carried between steps
/// in memory (CI readiness, seam 1); the workspace is the interface
/// (seam 3).
///
/// Reuse is the coordinator's job, not this class's: a producer runs only
/// when the stage receipt lacks its step, and a validated receipt is the one
/// authority for skipping work. Every method here therefore does its work
/// unconditionally — a file on disk is not evidence of itself.
class BinaryChain {
  BinaryChain({
    required this.tools,
    required this.output,
    required this.workspace,
    required this.repositoryRoot,
    required this.capabilities,
    this.compilerExecutable = 'dart',
  });

  final Tools tools;
  final Output output;
  final Workspace workspace;
  final String repositoryRoot;
  final HostCapabilities capabilities;
  final String compilerExecutable;

  // ---- workspace-internal names ----
  //
  // These two are not public asset names: they name what lives under
  // `.rk/work/` between steps. The published grammar is ReleaseAssets.

  static String binaryName(
    String project,
    String platform,
    String executable,
  ) =>
      'producers/$project/$platform/$executable';

  static String zipName(
    String project,
    String platform,
    String executable,
  ) =>
      'producers/$project/$platform/$executable.zip';

  // ---- build ----

  /// Compiles — and on macOS signs — the platform binary, as one step.
  ///
  /// Signing is not resumable work worth its own receipt: a compile costs
  /// seconds, so a signing failure rebuilds rather than maintaining a
  /// transient unsigned intermediate every validator would have to know
  /// about. [signing] is present exactly when [step] is a macOS platform.
  Future<LocalProducerOutcome> buildStep(
    Step step,
    ResolvedProject project, {
    MacSigning? signing,
    ProgressHandle? progress,
  }) async {
    final platform = step.platform!;
    final executable = project.executable!;
    final capability = capabilities.resolve(platform);
    if (!capability.canProduce) {
      output.problem(
        Diagnostic(
          code: 'RK-HOST-001',
          message: 'this machine cannot produce $platform',
          remedy: capability.reason ?? 'it needs a different host',
        ),
        unit: step.unit,
      );
      return LocalProducerOutcome.failed(
        capability.reason ?? 'this host cannot produce $platform',
      );
    }

    final name = ReleaseAssets.binaryPath(project, platform);

    File(workspace.pathOf(name)).parent.createSync(recursive: true);
    final built = await DartCliBuilder(
      tools: tools,
      capabilities: capabilities,
      compilerExecutable: compilerExecutable,
    ).build(
      platform: platform,
      entryPoint: 'bin/$executable.dart',
      output: workspace.pathOf(name),
      workingDirectory: project.directoryIn(repositoryRoot),
      expectedVersion: project.version.canonical,
      onProgress: (event) {
        if (event == DartBuildEvent.testing) {
          progress?.begin(
            ProgressActivity(running: 'testing', failed: 'test failed'),
          );
        }
      },
    );
    if (!built.ok) {
      output.problem(
        Diagnostic(
          code: 'RK-BUILD-001',
          message: '$platform: the build did not produce a working binary',
          remedy: built.problem ?? 'see the compiler output',
          evidence: built.transcript,
        ),
        unit: step.unit,
      );
      return LocalProducerOutcome.failed(
        built.problem ?? 'the build failed',
      );
    }

    // The proof's absence travels with the artifact. `built` alone would
    // read as "checked", which is the claim rk must not make for a binary
    // nothing here could run.
    final smoke = built.unproven == null
        ? const {'status': 'passed'}
        : {'status': 'not-executed', 'reason': built.unproven};

    if (signing == null) {
      if (built.unproven case final unproven?) {
        output.step(
          step,
          verdict: Verdict.exact,
          detail: 'built, not executed — $unproven',
          note: 'built, not executed — $unproven',
          show: false,
        );
      }
      return LocalProducerOutcome.succeeded(
        outputs: [LocalProducerOutput(name, 'executable')],
        evidence: {'smoke': smoke},
      );
    }

    progress?.begin(
      ProgressActivity(running: 'signing', failed: 'signing failed'),
    );
    return _sign(step, name, smoke, signing);
  }

  /// The signing half of a macOS build.
  ///
  /// The requirement is derived from the release users already installed —
  /// asking the certificate about to sign what it will sign with is a
  /// tautology. [MacSigning.codeId] is resolved by the caller, before
  /// anything acts: it is read off the published binary, or declared, or the
  /// release was refused (RK-SIGN-009).
  Future<LocalProducerOutcome> _sign(
    Step step,
    String name,
    Map<String, Object?> smoke,
    MacSigning signing,
  ) async {
    final publishedRequirement = signing.publishedRequirement;
    final unsignedSha256 = Sha256.hex(workspace.readBytes(name)!);

    // Derived when a release exists to derive from; discovered otherwise.
    // Nothing is declared: a team a user types can only ever agree with the
    // certificate they have or contradict it.
    final team =
        publishedRequirement == null ? null : teamOf(publishedRequirement);

    if (publishedRequirement != null && team == null) {
      output.problem(
        Diagnostic(
          code: 'RK-SIGN-001',
          message: 'the published release names no team rk can read',
          remedy: 'its designated requirement carries no subject.OU, so rk '
              'cannot tell which certificate reproduces it',
        ),
        unit: step.unit,
      );
      return const LocalProducerOutcome.failed(
        'the published requirement has no readable team',
      );
    }

    final signer = MacOsSigner(tools: tools);
    final signed = await signer.sign(
      binary: workspace.pathOf(name),
      team: team,
      codeId: signing.codeId,
      selectedIdentity: signing.identity,
      expectedCertificateSha256: signing.certificateSha256,
    );
    if (!signed.ok) {
      output.problem(
        Diagnostic(
          code: 'RK-SIGN-002',
          message: '${step.platform}: signing failed',
          remedy: signed.problem ?? 'see codesign\'s output',
          evidence: signed.transcript,
        ),
        unit: step.unit,
      );
      return LocalProducerOutcome.failed(
        signed.problem ?? 'signing failed',
      );
    }

    // The proof: what was just signed must be the same program identity users
    // already installed. A new certificate, team, or rebuilt identity passes
    // every local check and fails only on users' machines — this is where it
    // fails here instead.
    if (publishedRequirement != null) {
      final produced = signed.requirement ?? '(unreadable)';
      if (produced != publishedRequirement) {
        output.problem(
          Diagnostic(
            code: 'RK-SIGN-003',
            message: 'the signature does not match the identity users '
                'already installed',
            remedy: 'signing with a different certificate ships what '
                'Gatekeeper treats as a different program under the same '
                'name. Fix the keychain so the published identity can be '
                'reproduced; a deliberate identity change is a migration rk '
                'does not automate, because it ships what macOS treats as a '
                'new program.',
          ),
          unit: step.unit,
        );
        output.step(
          step,
          mark: Mark.blocked,
          verdict: Verdict.conflict,
          evidence: {
            'published': publishedRequirement,
            'produced': produced,
          },
          show: true,
        );
        // The signing attempt changed private staged bytes, so the halt must
        // not claim that rk did nothing. Public release acts still have not
        // begun: staging is mandatory before the tag or any destination act.
        // The producer states the verdict; the coordinator speaks the halt
        // once, after every lane has rested.
        return LocalProducerOutcome.failed(
          'the produced signature differs from the published identity',
          output.report.acted
              ? HaltKind.actedAndUnfixable
              : HaltKind.unfixableByRerun,
        );
      }
    } else {
      // A first signed release makes an identity permanent, so it is named
      // rather than assumed: the certificate that signed and the identifier
      // every later release must reproduce.
    }
    // Run it again, now that it is signed. The smoke test above proved the
    // *built* binary works; signing is a separate act that can stop it from
    // starting at all, and every other check here is satisfied when it does —
    // the signature verifies, the designated requirement matches, notarization
    // succeeds, and Gatekeeper accepts a binary the kernel kills on launch.
    // Only executing the signed bytes distinguishes those.
    final signedSmoke = await tools.run(workspace.pathOf(name), const [
      '--version',
    ]);
    if (!signedSmoke.ok) {
      output.problem(
        Diagnostic(
          code: 'RK-SIGN-014',
          message: 'the signed binary does not run',
          remedy: 'It was built, it ran, and signing stopped it from '
              'starting. On macOS the usual cause is the hardened runtime '
              'refusing memory the program needs, which no signature or '
              'notarization check reports. Run it directly to see what the '
              'system says.',
          evidence: signedSmoke.transcript,
        ),
        unit: step.unit,
      );
      return LocalProducerOutcome.failed('the signed binary does not run');
    }

    final signedSha256 = Sha256.hex(workspace.readBytes(name)!);
    return LocalProducerOutcome.succeeded(
      outputs: [LocalProducerOutput(name, 'executable')],
      evidence: {
        'smoke': smoke,
        'signed_smoke': {'status': 'pass', 'command': '--version'},
        'signature': {
          'first_identity': publishedRequirement == null,
          'published_requirement': publishedRequirement,
          'designated_requirement': signed.requirement,
          'code_id': signing.codeId,
          if (signed.certificate != null) 'certificate': signed.certificate,
          if (signed.certificateSha256 != null)
            'certificate_sha256': signed.certificateSha256,
          'unsigned_sha256': unsignedSha256,
          'signed_sha256': signedSha256,
        },
      },
    );
  }

  /// The team id inside a designated requirement, which is the one fact
  /// needed to pick the certificate that can reproduce it.
  ///
  /// The quotes are optional because codesign's requirement printer only
  /// quotes an OU that needs quoting: a team id beginning with a digit
  /// prints as `leaf[subject.OU] = "2DC432GLL2"`, one beginning with a
  /// letter as `leaf[subject.OU] = Q6L2SF6YDW` — confirmed against real
  /// signed apps and a csreq round-trip. The quoted-only version of this
  /// returned null for every letter-leading team, which misread an
  /// established identity as "no team rk can read".
  static String? teamOf(String requirement) =>
      RegExp(r'subject\.OU\]\s*=\s*"?([A-Z0-9]+)"?')
          .firstMatch(requirement)
          ?.group(1);

  /// The code identifier inside a designated requirement — always quoted by
  /// codesign's printer, unlike the OU.
  ///
  /// Public because the preflight compares it against a declared one before
  /// anything acts; it had a one-line public forwarder around it for that,
  /// which is a module punched through for a single caller.
  static String? identifierOf(String requirement) =>
      RegExp(r'identifier "([^"]+)"').firstMatch(requirement)?.group(1);

  // ---- notarize ----

  Future<LocalProducerOutcome> notarizeStep(
    Step step,
    ResolvedProject project,
  ) async {
    final platform = step.platform!;
    final binary = ReleaseAssets.binaryPath(project, platform);
    if (!workspace.exists(binary)) {
      return _missingArtifact(step, binary, 'the build step produces it');
    }

    final resultName = ReleaseAssets.notaryResultPath(project, platform);
    final logName = ReleaseAssets.notaryLogPath(project, platform);

    final zip = ReleaseAssets.notaryInputPath(project, platform);
    final zipped = await tools.run(
      'ditto',
      [
        '-c',
        '-k',
        '--keepParent',
        workspace.pathOf(binary),
        workspace.pathOf(zip)
      ],
    );
    if (!zipped.ok) {
      output.problem(
        Diagnostic(
          code: 'RK-NOTARY-001',
          message: '$platform: the archive for notarization failed',
          remedy: zipped.summary,
          evidence: zipped.transcript,
        ),
        unit: step.unit,
      );
      return LocalProducerOutcome.failed(zipped.summary);
    }

    // The wait is Apple's, and silence during it reads as a hang — this is
    // the step Activity exists for.
    final notarized =
        await MacOsNotarizer(tools: tools).submit(workspace.pathOf(zip));
    if (!notarized.ok) {
      output.problem(
        Diagnostic(
          code: 'RK-NOTARY-002',
          message: '$platform: notarization did not complete',
          remedy: notarized.remedy ?? notarized.problem ?? 'see notarytool',
          evidence: notarized.transcript,
        ),
        unit: step.unit,
      );
      return LocalProducerOutcome.failed(
        notarized.problem ?? 'Apple rejected the submission',
      );
    }

    // The verdict and its log are stage evidence, receipt-bound for
    // diagnosis; a consumer verifies the binary with Apple directly.
    workspace.write(resultName, utf8.encode(notarized.raw ?? '{}'));
    final submission = notarized.submissionId;
    final log = submission == null
        ? null
        : await MacOsNotarizer(tools: tools).log(submission);
    if (log == null || !log.ok) {
      output.problem(
        Diagnostic(
          code: 'RK-NOTARY-003',
          message: '$platform: Apple accepted the submission and the log '
              'could not be fetched',
          remedy: log == null
              ? 'the submission id was not in notarytool\'s answer'
              : log.summary,
          evidence: log?.transcript,
        ),
        unit: step.unit,
      );
      return const LocalProducerOutcome.failed(
        'the notarization log could not be fetched',
      );
    }
    workspace.write(logName, utf8.encode(log.stdout));
    output.step(
      step,
      verdict: Verdict.exact,
      detail: 'notarized',
      show: false,
    );
    return _notaryOutcome(
      resultName: resultName,
      logName: logName,
      zipName: zip,
    );
  }

  // ---- archive ----

  Future<LocalProducerOutcome> archiveStep(
    Step step,
    ResolvedProject project,
  ) async {
    final platform = step.platform!;
    final executable = project.executable!;
    final binary = workspace.readBytes(ReleaseAssets.binaryPath(
      project,
      platform,
    ));
    if (binary == null) {
      return _missingArtifact(
        step,
        ReleaseAssets.binaryPath(project, platform),
        'the build step produces it',
      );
    }

    final entries = <ArchiveEntry>[
      ArchiveEntry(name: executable, bytes: binary, executable: true),
    ];
    // LICENSE and README travel with the binary by convention, not by
    // configuration.
    final directory = project.directoryIn(repositoryRoot);
    for (final extra in const ['LICENSE', 'README.md']) {
      final file = File('$directory/$extra');
      if (file.existsSync()) {
        entries.add(ArchiveEntry(name: extra, bytes: file.readAsBytesSync()));
      }
    }

    final name = ReleaseAssets.archivePath(project, platform);
    final bytes = ArchiveBuilder.gzip(ArchiveBuilder.tar(entries));
    workspace.write(name, bytes);
    output.step(
      step,
      show: false,
      mark: Mark.done,
      verdict: Verdict.exact,
      detail: name,
      note: name,
    );
    return LocalProducerOutcome.succeeded(
      outputs: [LocalProducerOutput(name, 'archive')],
      evidence: {
        'inventory': StageArchiveInventory.evidence(
          StageArchiveInventory.parse(bytes),
        ),
      },
    );
  }

  LocalProducerOutcome _notaryOutcome({
    required String resultName,
    required String logName,
    required String zipName,
  }) {
    final resultBytes = workspace.readBytes(resultName)!;
    final logBytes = workspace.readBytes(logName)!;
    Object? status;
    Object? submissionId;
    try {
      final decoded = jsonDecode(utf8.decode(resultBytes));
      if (decoded is Map) {
        status = decoded['status'];
        submissionId = decoded['id'];
      }
    } on Object {
      // The stage inspector owns the strict semantic decision. Carry the
      // evidence exactly as observed so it can refuse without this producer
      // inventing a successful status or submission id.
    }
    return LocalProducerOutcome.succeeded(
      outputs: [
        LocalProducerOutput(zipName, 'notary-input'),
        LocalProducerOutput(resultName, 'notary'),
        LocalProducerOutput(logName, 'notary'),
      ],
      evidence: {
        'notary': {
          'status': status,
          'submission_id': submissionId,
          'result_sha256': Sha256.hex(resultBytes),
          'log_sha256': Sha256.hex(logBytes),
        },
      },
    );
  }

  LocalProducerOutcome _missingArtifact(
    Step step,
    String name,
    String producedBy,
  ) {
    output.problem(
      Diagnostic(
        code: 'RK-WORK-001',
        message: 'the workspace has no $name',
        remedy: '$producedBy — re-running runs it',
      ),
      unit: step.unit,
    );
    return LocalProducerOutcome.failed('the workspace has no $name');
  }
}

/// What a macOS build needs to sign what it compiled.
///
/// Resolved by the coordinator before anything acts, so the one step that
/// makes an identity permanent never invents a value nothing stated.
final class MacSigning {
  const MacSigning({
    required this.publishedRequirement,
    required this.codeId,
    this.identity,
    this.certificateSha256,
  });

  /// The designated requirement of the release users already installed, or
  /// null on a first signed release.
  final String? publishedRequirement;

  final String codeId;
  final SigningIdentity? identity;
  final String? certificateSha256;
}

/// One stage-relative file a local producer created or authoritatively reused.
class LocalProducerOutput {
  const LocalProducerOutput(this.path, this.type);

  /// A workspace-relative path, never a host filesystem path.
  final String path;
  final String type;
}

/// The complete handoff from one local operation to the stage receipt writer.
///
/// Producers still render their established diagnostics. This value carries
/// only the machine facts the receipt needs: whether the operation completed,
/// which stage-relative outputs it owns, and the evidence learned while doing
/// the work. The receipt writer therefore does not have to rediscover semantic
/// facts from mutable workspace files after the operation returns.
class LocalProducerOutcome {
  LocalProducerOutcome.succeeded({
    required Iterable<LocalProducerOutput> outputs,
    Map<String, Object?> evidence = const {},
  })  : ok = true,
        problem = null,
        halt = null,
        outputs = List<LocalProducerOutput>.unmodifiable(outputs),
        evidence = Map<String, Object?>.unmodifiable(evidence);

  const LocalProducerOutcome.failed([this.problem, this.halt])
      : ok = false,
        outputs = const [],
        evidence = const {};

  final bool ok;
  final String? problem;

  /// The halt this failure asks for, when stronger than the default
  /// stopped-partway. The producer knows what its failure means; the
  /// coordinator speaks the halt exactly once, after the drain.
  final HaltKind? halt;

  final List<LocalProducerOutput> outputs;
  final Map<String, Object?> evidence;
}
