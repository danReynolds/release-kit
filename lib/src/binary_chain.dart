import 'dart:io';

import 'builds/capability.dart';
import 'builds/dart_cli.dart';
import 'builds/macos_identity.dart';
import 'engine/assets.dart';
import 'engine/diagnostic.dart';
import 'output/output.dart';
import 'output/progress.dart';
import 'engine/resolve.dart';
import 'engine/stage.dart';
import 'engine/tools.dart';
import 'engine/unit_release.dart';
import 'engine/verdict.dart';
import 'transforms/archive.dart';
import 'targets/target_module.dart';
import 'transforms/macos.dart';

/// The local half of shipping binaries, one step at a time: buildStep,
/// notarizeStep and archiveStep, each run by the stage runner.
///
/// Each step is its own act: it reads what it needs from the [Stage] by
/// name, does one thing, and writes what it made back by name. Nothing is
/// carried between steps in memory; the stage is the interface.
///
/// Reuse is the coordinator's job, not this class's: a producer runs only
/// when the stage receipt lacks its step, and a validated receipt is the one
/// authority for skipping work. Every method here therefore does its work
/// unconditionally — a file on disk is not evidence of itself.
class BinaryChain {
  BinaryChain({
    required this.tools,
    required this.output,
    required this.stage,
    required this.repositoryRoot,
    required this.capabilities,
    this.compilerExecutable = 'dart',
  });

  final Tools tools;
  final Output output;

  /// Where each step finds what an earlier one made, and leaves its own.
  final Stage stage;
  final String repositoryRoot;
  final HostCapabilities capabilities;
  final String compilerExecutable;

  // ---- build ----

  /// Compiles — and on macOS signs — the platform binary, as one step.
  ///
  /// Signing is not resumable work worth its own receipt: a compile costs
  /// seconds, so a signing failure rebuilds rather than maintaining a
  /// transient unsigned intermediate every validator would have to know
  /// about. [signing] is present exactly when [step] is a macOS platform.
  Future<Produced> buildStep(
    Work step,
    ResolvedProject project, {
    MacIdentity? signing,
    ProgressHandle? progress,
  }) async {
    // The release refused a platform this host cannot produce before any
    // work began (RK-HOST-001).
    final platform = step.platform!;
    final executable = project.executable!;

    final name = ReleaseAssets.binaryPath(project, platform);

    File(stage.pathOf(name)).parent.createSync(recursive: true);
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
          output: stage.pathOf(name),
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
      return const Produced.failed();
    }

    // The proof's absence travels with the artifact. `built` alone would
    // read as "checked", which is the claim rk must not make for a binary
    // nothing here could run.
    final smoke = built.unproven == null
        ? const {'status': 'passed'}
        : {'status': 'not-executed', 'reason': built.unproven};

    if (signing == null) {
      if (built.unproven case final unproven?) {
        output.record(
          step,
          verdict: Verdict.exact,
          detail: 'built, not executed — $unproven',
        );
      }
      return Produced(
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
  /// tautology. [MacIdentity.codeId] is settled before anything acts: it is
  /// read off the published binary, or declared, or the release was refused
  /// (RK-SIGN-009).
  Future<Produced> _sign(
    Work step,
    ResolvedProject project,
    Map<String, Object?> smoke,
    MacIdentity signing,
  ) async {
    final platform = step.platform!;
    final artifact = ReleaseAssets.binaryArtifact(project, platform);
    final root = ReleaseAssets.binaryRoot(project, platform);
    final published = signing.publishedRequirement;
    Produced fail(String code, String message, {String? transcript}) {
      output.problem(
        Diagnostic(
          code: code,
          message: message,
          remedy: 'rk will not notarize or publish these bytes.',
          evidence: transcript,
        ),
        unit: step.unit,
      );
      return const Produced.failed();
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
        binary: stage.pathOf(name),
        identity: signing.identity!,
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
        final reading = await signer.codeDirectoryHashes(stage.pathOf(name));
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
      stage.pathOf('$root/${artifact.identityFile}'),
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
      // The difference itself, not the fact of one: both requirements are
      // printed as well as recorded.
      final evidence = {'published': published, 'produced': requirement};
      output.record(step, verdict: Verdict.conflict, evidence: evidence);
      output.line(
        step.summary,
        mark: Mark.blocked,
        depth: 1,
        state: RuntimeState.failure,
      );
      for (final MapEntry(:key, :value) in evidence.entries) {
        output.line('$key  $value', depth: 2, role: VisualRole.secondary);
      }
      return Produced.failed(
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
      'certificate': signing.certificate,
    };
    final signedSmoke = await tools.run(
      stage.pathOf('$root/${artifact.entryPoint}'),
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
    return Produced(
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

  // ---- notarize ----

  Future<Produced> notarizeStep(Work step, ResolvedProject project) async {
    final platform = step.platform!;
    for (final path in ReleaseAssets.binaryOutputs(project, platform)) {
      if (!File(stage.pathOf(path)).existsSync()) {
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
        File(stage.pathOf('$root/${file.path}')).copySync(copy.path);
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
        return const Produced.failed();
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
        return const Produced.failed();
      }
      output.record(step, verdict: Verdict.exact, detail: 'notarized');
      // Apple's verdict is about the signed files, which the archive step
      // packs as they are; a consumer asks Apple about the exact bytes.
      return Produced(
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

  Future<Produced> archiveStep(Work step, ResolvedProject project) async {
    final platform = step.platform!;
    final artifact = ReleaseAssets.binaryArtifact(project, platform);
    final root = ReleaseAssets.binaryRoot(project, platform);
    final entries = <ArchiveEntry>[];
    for (final file in artifact.files) {
      final name = '$root/${file.path}';
      final bytes = stage.readBytes(name);
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
    stage.write(name, ArchiveBuilder.gzip(ArchiveBuilder.tar(entries)));
    output.record(step, verdict: Verdict.exact, detail: name);
    return const Produced();
  }

  Produced _missingArtifact(Work step, String name, String producedBy) {
    output.problem(
      Diagnostic(
        code: 'RK-WORK-001',
        message: 'the workspace has no $name',
        remedy: '$producedBy — re-running runs it',
      ),
      unit: step.unit,
    );
    return const Produced.failed();
  }
}
