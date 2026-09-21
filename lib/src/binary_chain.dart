import 'dart:convert';
import 'dart:io';

import 'builds/capability.dart';
import 'builds/dart_cli.dart';
import 'builds/launcher_compiler.dart';
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
/// adapter by this codebase's own test, the one `targets/git_tag/client.dart`
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
    this.runtimeSha256,
    this.runtimeLicenseSha256,
    this.launcherCompiler,
  });

  final Tools tools;
  final Output output;
  final Workspace workspace;
  final String repositoryRoot;
  final HostCapabilities capabilities;
  final String compilerExecutable;
  final String? runtimeSha256;
  final String? runtimeLicenseSha256;
  final LauncherCompiler? launcherCompiler;

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
      'producers/$project/notary/$platform/$executable.zip';

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
      runtimeSha256: runtimeSha256,
      runtimeLicenseSha256: runtimeLicenseSha256,
      launcherCompiler: launcherCompiler,
    ).build(
      platform: platform,
      entryPoint: 'bin/$executable.dart',
      output: workspace.pathOf(name),
      workingDirectory: project.directoryIn(repositoryRoot),
      expectedVersion: project.version.canonical,
      defines: project.dartDefines,
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
        outputs: [
          for (final entry
              in ReleaseAssets.binaryOutputs(project, platform).entries)
            LocalProducerOutput(entry.key, entry.value)
        ],
        evidence: {
          'smoke': smoke,
          'artifact': ReleaseAssets.binaryArtifact(project, platform).toJson()
        },
      );
    }

    progress?.begin(
      ProgressActivity(running: 'signing', failed: 'signing failed'),
    );
    return _sign(step, project, smoke, signing);
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
    ResolvedProject project,
    Map<String, Object?> smoke,
    MacSigning signing,
  ) async {
    final platform = step.platform!;
    final artifact = ReleaseAssets.binaryArtifact(project, platform);
    final root = ReleaseAssets.binaryRoot(project, platform);
    final published = signing.publishedRequirement;
    final team = published == null ? null : teamOf(published);
    LocalProducerOutcome fail(String code, String message,
        {String? transcript}) {
      output.problem(
          Diagnostic(
              code: code,
              message: message,
              remedy: 'rk will not notarize or publish these bytes.',
              evidence: transcript),
          unit: step.unit);
      return LocalProducerOutcome.failed(message);
    }

    if (published != null && team == null) {
      return fail(
          'RK-SIGN-001', 'the published requirement has no readable team');
    }
    final signer = MacOsSigner(tools: tools);
    final signatures = <String, Map<String, Object?>>{};
    String? fingerprint = signing.certificateSha256;
    for (final file in artifact.signedFiles) {
      final name = '$root/${file.path}';
      final codeId = '${signing.codeId}${file.codeSuffix}';
      final unsigned = Sha256.hex(workspace.readBytes(name)!);
      final signed = await signer.sign(
        binary: workspace.pathOf(name),
        team: team,
        codeId: codeId,
        selectedIdentity: signing.identity,
        expectedCertificateSha256: fingerprint,
      );
      if (!signed.ok) {
        return fail('RK-SIGN-002', signed.problem ?? 'signing failed',
            transcript: signed.transcript);
      }
      fingerprint ??= signed.certificateSha256;
      if (identifierOf(signed.requirement!) != codeId) {
        return fail(
            'RK-SIGN-003', 'the signature names a different code identifier');
      }
      if (file.path == artifact.identityFile &&
          published != null &&
          signed.requirement != published) {
        output.problem(
            Diagnostic(
                code: 'RK-SIGN-003',
                message:
                    'the signature does not match the identity users already installed',
                remedy:
                    'Restore the published signing identity. A deliberate identity migration requires a separate plan.'),
            unit: step.unit);
        output.step(step,
            mark: Mark.blocked,
            verdict: Verdict.conflict,
            evidence: {'published': published, 'produced': signed.requirement!},
            show: true);
        return LocalProducerOutcome.failed(
            'the produced signature differs from the published identity',
            output.report.acted
                ? HaltKind.actedAndUnfixable
                : HaltKind.unfixableByRerun);
      }
      signatures[file.path] = {
        'first_identity': published == null,
        'published_requirement':
            file.path == artifact.identityFile ? published : null,
        'designated_requirement': signed.requirement,
        'code_id': codeId,
        'certificate': signed.certificate,
        'certificate_sha256': signed.certificateSha256,
        'unsigned_sha256': unsigned,
        'signed_sha256': Sha256.hex(workspace.readBytes(name)!),
      };
    }
    final signedSmoke = await tools.run(
        workspace.pathOf('$root/${artifact.entryPoint}'), const ['--version'],
        timeout: const Duration(minutes: 2));
    if (!signedSmoke.ok ||
        !signedSmoke.stdout.contains(project.version.canonical)) {
      return fail('RK-SIGN-014',
          'the signed binary does not run or reports the wrong version',
          transcript: signedSmoke.transcript);
    }
    for (final file in artifact.signedFiles) {
      final name = '$root/${file.path}';
      final verified = await signer.verifies(workspace.pathOf(name));
      if (!verified.ok ||
          signatures[file.path]!['signed_sha256'] !=
              Sha256.hex(workspace.readBytes(name)!)) {
        return fail('RK-SIGN-015',
            'the signature did not verify after the signed smoke test',
            transcript: verified.transcript);
      }
      signatures[file.path]!['verified_after_smoke'] = true;
    }
    return LocalProducerOutcome.succeeded(
      outputs: [
        for (final entry
            in ReleaseAssets.binaryOutputs(project, platform).entries)
          LocalProducerOutput(entry.key, entry.value)
      ],
      evidence: {
        'artifact': artifact.toJson(),
        'smoke': smoke,
        'signed_smoke': {'status': 'pass', 'command': '--version'},
        // Keep the process identity at the same receipt location for recovery.
        'signature': signatures[artifact.identityFile],
        'signatures': signatures,
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
  /// The program identity named by a designated requirement.
  ///
  /// codesign quotes an identifier only when it has to. `rk` prints bare while
  /// `"io.github.danreynolds.keybay.cli"` is quoted, so reading only the quoted
  /// form leaves a program unable to recognise its own published identity —
  /// which surfaces on the second release, never the first, because the first
  /// has no published requirement to read.
  static String? identifierOf(String requirement) {
    final match =
        RegExp(r'identifier\s+(?:"([^"]+)"|([^\s"]+))').firstMatch(requirement);
    if (match == null) return null;
    return match.group(1) ?? match.group(2);
  }

  // ---- notarize ----

  Future<LocalProducerOutcome> notarizeStep(
    Step step,
    ResolvedProject project,
  ) async {
    final platform = step.platform!;
    for (final path in ReleaseAssets.binaryOutputs(project, platform).keys) {
      if (!workspace.exists(path)) {
        return _missingArtifact(step, path, 'the build step produces it');
      }
    }

    final resultName = ReleaseAssets.notaryResultPath(project, platform);
    final logName = ReleaseAssets.notaryLogPath(project, platform);

    final zip = ReleaseAssets.notaryInputPath(project, platform);
    File(workspace.pathOf(zip)).parent.createSync(recursive: true);
    final payload = Directory.systemTemp.createTempSync('rk-notary-payload-');
    final ToolResult zipped;
    try {
      for (final file
          in ReleaseAssets.binaryArtifact(project, platform).files) {
        final destination = File('${payload.path}/${file.path}');
        destination.parent.createSync(recursive: true);
        File(workspace.pathOf(
                '${ReleaseAssets.binaryRoot(project, platform)}/${file.path}'))
            .copySync(destination.path);
      }
      zipped = await tools.run(
        'ditto',
        ['-c', '-k', payload.path, workspace.pathOf(zip)],
      );
    } finally {
      payload.deleteSync(recursive: true);
    }
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
    final artifact = ReleaseAssets.binaryArtifact(project, platform);
    final root = ReleaseAssets.binaryRoot(project, platform);
    final entries = <ArchiveEntry>[];
    for (final file in artifact.files) {
      final name = '$root/${file.path}';
      final bytes = workspace.readBytes(name);
      if (bytes == null) {
        return _missingArtifact(step, name, 'the build step produces it');
      }
      entries.add(ArchiveEntry(
          name: file.path, bytes: bytes, executable: file.executable));
    }
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
    final contents = StageArchiveInventory.decode(bytes);

    if (platform.startsWith('macos-')) {
      final verificationDirectory =
          Directory.systemTemp.createTempSync('rk-archive-verify-');
      try {
        contents.extractTo(verificationDirectory);
        for (final file in artifact.signedFiles) {
          final verified = await MacOsSigner(tools: tools)
              .verifies('${verificationDirectory.path}/${file.path}');
          if (!verified.ok) {
            output.problem(
                Diagnostic(
                    code: 'RK-SIGN-016',
                    message:
                        'the macOS signature does not verify in the final archive',
                    remedy: 'rk will not publish the archive.',
                    evidence: verified.transcript),
                unit: step.unit);
            return const LocalProducerOutcome.failed(
                'the final archived signature did not verify');
          }
        }
        final smoke = await tools.run(
            '${verificationDirectory.path}/${artifact.entryPoint}',
            const ['--version'],
            timeout: const Duration(minutes: 2));
        if (!smoke.ok || !smoke.stdout.contains(project.version.canonical)) {
          return const LocalProducerOutcome.failed(
              'the final archived program did not run with the expected version');
        }
        for (final file in artifact.signedFiles) {
          if (Sha256.hex(File('${verificationDirectory.path}/${file.path}')
                  .readAsBytesSync()) !=
              Sha256.hex(contents.files[file.path]!)) {
            return const LocalProducerOutcome.failed(
                'the final archived program changed during its smoke test');
          }
        }
      } finally {
        verificationDirectory.deleteSync(recursive: true);
      }
    }
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
          contents.inventory,
        ),
        if (platform.startsWith('macos-'))
          'signature': {
            'status': 'valid',
            'scope': 'archive-extracted',
            'files': [for (final file in artifact.signedFiles) file.path],
            'smoke': 'passed',
          },
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
