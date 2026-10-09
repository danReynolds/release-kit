import 'dart:io';

import 'builds/capability.dart';
import 'builds/dart_cli.dart';
import 'engine/assets.dart';
import 'engine/checklist.dart';
import 'engine/diagnostic.dart';
import 'output/output.dart';
import 'output/progress.dart';
import 'engine/resolve.dart';
import 'engine/release_stage.dart';
import 'engine/tools.dart';
import 'engine/verdict.dart';
import 'engine/workspace.dart';
import 'transforms/archive.dart';
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
    this.stage,
  });

  final Tools tools;
  final Output output;
  final Workspace workspace;
  final String repositoryRoot;
  final HostCapabilities capabilities;
  final String compilerExecutable;
  final ReleaseStage? stage;

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
    // The release refused a platform this host cannot produce before any
    // work began (RK-HOST-001).
    final platform = step.platform!;
    final executable = project.executable!;

    final name = ReleaseAssets.binaryPath(project, platform);

    File(workspace.pathOf(name)).parent.createSync(recursive: true);
    // Pub resolves the build in the lane's copy of the commit, through its
    // own cache and lockfile, as `dart compile` does anywhere.
    final built =
        await DartCliBuilder(
          tools: tools,
          capabilities: capabilities,
          compilerExecutable: compilerExecutable,
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
      return LocalProducerOutcome.failed(built.problem ?? 'the build failed');
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
          for (final entry in ReleaseAssets.binaryOutputs(
            project,
            platform,
          ).entries)
            LocalProducerOutput(entry.key, entry.value),
        ],
        evidence: {
          'smoke': smoke,
          'artifact': ReleaseAssets.binaryArtifact(project, platform).toJson(),
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
    LocalProducerOutcome fail(
      String code,
      String message, {
      String? transcript,
    }) {
      output.problem(
        Diagnostic(
          code: code,
          message: message,
          remedy: 'rk will not notarize or publish these bytes.',
          evidence: transcript,
        ),
        unit: step.unit,
      );
      return LocalProducerOutcome.failed(message);
    }

    final signer = MacOsSigner(tools: tools);
    final signatures = <String, Map<String, Object?>>{};
    // Library validation admits any library signed by the same team, so the
    // runtime's signature also admits only the modules this bundle ships.
    // Those are signed first and their final code hashes go into it.
    final shipped = <String>{};
    for (final file in artifact.signingOrder) {
      final name = '$root/${file.path}';
      final codeId = '${signing.codeId}${file.codeSuffix}';
      final pins = file.path == artifact.identityFile
          ? (shipped.toList()..sort())
          : const <String>[];
      final signed = await signer.sign(
        binary: workspace.pathOf(name),
        identity: signing.identity,
        codeId: codeId,
        pinnedLibraries: pins,
      );
      if (!signed.ok) {
        return fail(
          'RK-SIGN-002',
          signed.summary,
          transcript: signed.transcript,
        );
      }
      final record = <String, Object?>{'code_id': codeId};
      if (file.loadedByIdentity) {
        final reading = await signer.codeDirectoryHashes(
          workspace.pathOf(name),
        );
        final hashes = reading.hashes;
        if (hashes == null) {
          return fail(
            'RK-SIGN-017',
            'the code hash of ${file.path} could not be read',
            transcript: reading.display.transcript,
          );
        }
        shipped.addAll(hashes);
        record['cdhashes'] = hashes;
      }
      if (pins.isNotEmpty) record['pinned_library_cdhashes'] = pins;
      signatures[file.path] = record;
    }

    // The process identity users' Keychain items and permissions are tied
    // to: the runtime's designated requirement, which must be the one
    // already published.
    final requirement = await signer.designatedRequirement(
      workspace.pathOf('$root/${artifact.identityFile}'),
    );
    if (requirement == null) {
      return fail('RK-SIGN-002', 'the signature could not be read back');
    }
    if (published != null && requirement != published) {
      output.problem(
        Diagnostic(
          code: 'RK-SIGN-003',
          message:
              'the signature does not match the identity users already installed',
          remedy:
              'Restore the published signing identity. A deliberate identity migration requires a separate plan.',
        ),
        unit: step.unit,
      );
      output.step(
        step,
        mark: Mark.blocked,
        verdict: Verdict.conflict,
        evidence: {'published': published, 'produced': requirement},
        show: true,
      );
      return LocalProducerOutcome.failed(
        'the produced signature differs from the published identity',
        output.report.actedPublicly
            ? HaltKind.actedAndUnfixable
            : HaltKind.unfixableByRerun,
      );
    }
    signatures[artifact.identityFile] = {
      ...signatures[artifact.identityFile]!,
      'first_identity': published == null,
      'published_requirement': published,
      'designated_requirement': requirement,
      'certificate': signing.identity.name,
    };
    final signedSmoke = await tools.run(
      workspace.pathOf('$root/${artifact.entryPoint}'),
      const ['--version'],
      timeout: const Duration(minutes: 2),
    );
    if (!signedSmoke.ok ||
        !signedSmoke.stdout.contains(project.version.canonical)) {
      return fail(
        'RK-SIGN-014',
        'the signed binary does not run or reports the wrong version',
        transcript: signedSmoke.transcript,
      );
    }
    return LocalProducerOutcome.succeeded(
      outputs: [
        for (final entry in ReleaseAssets.binaryOutputs(
          project,
          platform,
        ).entries)
          LocalProducerOutput(entry.key, entry.value),
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
  static String? teamOf(String requirement) => RegExp(
    r'subject\.OU\]\s*=\s*"?([A-Z0-9]+)"?',
  ).firstMatch(requirement)?.group(1);

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
    final match = RegExp(
      r'identifier\s+(?:"([^"]+)"|([^\s"]+))',
    ).firstMatch(requirement);
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

    // The zip is Apple's input only: built beside the stage, never in it,
    // from the artifact's files exactly as the build left them, and nothing
    // else that is there, such as what an interrupted codesign left.
    final scratch = Directory.systemTemp.createTempSync('rk-notary-');
    try {
      final root = ReleaseAssets.binaryRoot(project, platform);
      final payload = '${scratch.path}/payload';
      for (final file in ReleaseAssets.binaryArtifact(
        project,
        platform,
      ).files) {
        final copy = File('$payload/${file.path}')
          ..parent.createSync(recursive: true);
        File(workspace.pathOf('$root/${file.path}')).copySync(copy.path);
      }
      final zip = '${scratch.path}/${project.executable}.zip';
      final zipped = await tools.run('ditto', ['-c', '-k', payload, zip]);
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
      final notarized = await MacOsNotarizer(tools: tools).submit(zip);
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
      output.step(
        step,
        verdict: Verdict.exact,
        detail: 'notarized',
        show: false,
      );
      // Apple's verdict is about the signed files, which the archive step
      // packs as they are; a consumer asks Apple about the exact bytes.
      return LocalProducerOutcome.succeeded(
        outputs: const [],
        evidence: {
          'notary': {
            'status': 'Accepted',
            'submission_id': notarized.submissionId,
          },
        },
      );
    } finally {
      scratch.deleteSync(recursive: true);
    }
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
      entries.add(
        ArchiveEntry(
          name: file.path,
          bytes: bytes,
          executable: file.executable,
        ),
      );
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
    workspace.write(name, ArchiveBuilder.gzip(ArchiveBuilder.tar(entries)));
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
    required this.identity,
  });

  /// The designated requirement of the release users already installed, or
  /// null on a first signed release.
  final String? publishedRequirement;

  final String codeId;

  /// The certificate the preflight chose: the one Developer ID on a first
  /// release, or the one for the published release's team.
  final SigningIdentity identity;
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
  }) : ok = true,
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
