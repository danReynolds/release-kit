import 'dart:convert';
import 'dart:io';

import '../builds/capability.dart';
import '../builds/dart_cli.dart';
import '../destinations/github_release.dart';
import '../destinations/homebrew.dart';
import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/output.dart';
import '../engine/resolve.dart';
import '../engine/tools.dart';
import '../engine/verdict.dart';
import '../engine/workspace.dart';
import '../transforms/archive.dart';
import '../transforms/digest.dart';
import '../transforms/macos.dart';

/// The local half of shipping binaries, one checklist step at a time.
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
/// Reuse follows the RFC's identity rule, not existence: a file on disk is
/// not evidence of itself. The only artifacts a re-run may reuse are those
/// an external authority re-verifies now — a signed binary codesign accepts
/// at the right version, a zip Apple already notarized. Everything else is
/// rebuilt.
class BinaryChain {
  BinaryChain({
    required this.tools,
    required this.output,
    required this.workspace,
    required this.repositoryRoot,
    required this.capabilities,
  });

  final Tools tools;
  final Output output;
  final Workspace workspace;
  final String repositoryRoot;
  final HostCapabilities capabilities;

  // ---- the naming convention, shared with the expected-asset derivation ----

  static String binaryName(String platform, String executable) =>
      '$platform/$executable';

  static String zipName(String platform, String executable) =>
      '$platform/$executable.zip';

  static String archiveName(
    String executable,
    String version,
    String platform,
  ) =>
      '$executable-$version-$platform.tar.gz';

  String _projectDirectory(ResolvedProject project) =>
      project.pubspec.directory == '.'
          ? repositoryRoot
          : '$repositoryRoot/${project.pubspec.directory}';

  // ---- build ----

  Future<bool> buildStep(
    Step step,
    ResolvedProject project, {
    required String? publishedRequirement,
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
      return false;
    }

    final name = binaryName(platform, executable);

    // Reuse is by identity, not acceptability, and every leg is an external
    // authority answering *now*:
    //
    //   1. `codesign --verify --strict` — the bytes match the signature. The
    //      display commands are not this check: `-d -r-` prints the
    //      requirement, exit 0, for a binary modified after signing.
    //   2. The designated requirement equals the one users already
    //      installed. A Developer ID requirement carries no content hash, so
    //      equality proves who signed; leg 1 proves these bytes are theirs.
    //   3. The binary reports this release's version.
    //
    // No published baseline means no authority to be continuous with, so a
    // first release always rebuilds — a compile costs seconds, and the
    // artifact reuse exists for is the one Apple takes minutes to re-vouch,
    // which stays gated by its own step. What this refuses: a foreign
    // binary seeded into `.rk/work/` — invisible to git status, since
    // `.rk/` is ignored — walking out signed and published.
    if (platform.startsWith('macos-') &&
        publishedRequirement != null &&
        workspace.exists(name)) {
      final signer = MacOsSigner(tools: tools);
      final path = workspace.pathOf(name);
      if (await signer.verifies(path) &&
          await signer.designatedRequirement(path) == publishedRequirement &&
          await _versionMatches(name, project.version.canonical)) {
        output.step(
          step,
          mark: Mark.satisfied,
          verdict: Verdict.exact,
          detail: 'signed binary in the workspace — signature verified, '
              'identity matches the published release',
          note: 'signed binary in the workspace — signature verified, '
              'identity matches the published release',
        );
        return true;
      }
    }

    final activity = output.begin(step);
    File(workspace.pathOf(name)).parent.createSync(recursive: true);
    final built = await DartCliBuilder(
      tools: tools,
      capabilities: capabilities,
    ).build(
      platform: platform,
      entryPoint: 'bin/$executable.dart',
      output: workspace.pathOf(name),
      workingDirectory: _projectDirectory(project),
      expectedVersion: project.version.canonical,
    );
    if (!built.ok) {
      activity.failed(built.problem ?? 'the build failed');
      output.problem(
        Diagnostic(
          code: 'RK-BUILD-001',
          message: '$platform: the build did not produce a working binary',
          remedy: built.problem ?? 'see the compiler output',
        ),
        unit: step.unit,
      );
      return false;
    }
    workspace.ingest(name);
    activity.done('built');
    return true;
  }

  Future<bool> _versionMatches(String name, String version) async {
    final result = await tools.run(workspace.pathOf(name), ['--version']);
    return result.ok && result.stdout.contains(version);
  }

  // ---- sign ----

  /// Signs, then proves the produced identity against [publishedRequirement]
  /// when one exists.
  ///
  /// The requirement is derived from the release users already installed —
  /// asking the certificate about to sign what it will sign with is a
  /// tautology. Only a first signed release, which has no published binary
  /// to derive from, falls back to the declared `[identity]`.
  Future<bool> signStep(
    Step step,
    ResolvedProject project, {
    required String? publishedRequirement,
    required String? declaredTeam,
    required String? declaredCodeId,
  }) async {
    final platform = step.platform!;
    final name = binaryName(platform, project.executable!);
    if (!workspace.exists(name)) {
      return _missingArtifact(step, name, 'the build step produces it');
    }

    final team = publishedRequirement != null
        ? _teamOf(publishedRequirement) ?? declaredTeam
        : declaredTeam;
    if (team == null) {
      output.problem(
        Diagnostic(
          code: 'RK-SIGN-001',
          message: 'no signing identity is established for this project',
          remedy: publishedRequirement == null
              ? 'the first signed release states it once — add [identity] '
                  'with apple_team and code_id to release.toml. Every '
                  'release after it derives the identity from what is '
                  'already published.'
              : 'the published requirement names no team rk can read, and '
                  'no [identity] is declared',
        ),
        unit: step.unit,
      );
      return false;
    }

    final signer = MacOsSigner(tools: tools);
    final signed = await signer.sign(
      binary: workspace.pathOf(name),
      team: team,
      codeId: declaredCodeId ?? project.name,
    );
    if (!signed.ok) {
      output.problem(
        Diagnostic(
          code: 'RK-SIGN-002',
          message: '$platform: signing failed',
          remedy: signed.problem ?? 'see codesign\'s output',
        ),
        unit: step.unit,
      );
      return false;
    }
    workspace.ingest(name);

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
                'name. Fix the keychain, or — deliberately, for a planned '
                'identity change — remove the published baseline from the '
                'comparison by declaring [identity] anew.',
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
        output.halt(HaltKind.unfixableByRerun);
        return false;
      }
      output.step(
        step,
        mark: Mark.done,
        verdict: Verdict.exact,
        detail: 'signed · matches the published identity',
        note: 'signed · matches the published identity',
      );
    } else {
      output.step(
        step,
        mark: Mark.done,
        verdict: Verdict.exact,
        detail: 'signed · first release, baseline declared',
        note: 'signed · first release, baseline declared',
      );
    }
    return true;
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
  static String? _teamOf(String requirement) =>
      RegExp(r'subject\.OU\]\s*=\s*"?([A-Z0-9]+)"?')
          .firstMatch(requirement)
          ?.group(1);

  // ---- notarize ----

  Future<bool> notarizeStep(Step step, ResolvedProject project) async {
    final platform = step.platform!;
    final executable = project.executable!;
    final binary = binaryName(platform, executable);
    if (!workspace.exists(binary)) {
      return _missingArtifact(
          step,
          binary,
          'the build and sign steps '
          'produce it');
    }

    final signer = MacOsSigner(tools: tools);
    if (await signer.isNotarized(workspace.pathOf(binary))) {
      output.step(
        step,
        mark: Mark.satisfied,
        verdict: Verdict.exact,
        detail: 'Apple already notarized these exact bytes',
        note: 'Apple already notarized these exact bytes',
      );
      return true;
    }

    final zip = zipName(platform, executable);
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
        ),
        unit: step.unit,
      );
      return false;
    }
    workspace.ingest(zip);

    // The wait is Apple's, and silence during it reads as a hang — this is
    // the step Activity exists for.
    final activity = output.begin(
      step,
      typically: const Duration(minutes: 5),
    );
    activity.update('waiting on Apple');
    final notarized =
        await MacOsNotarizer(tools: tools).submit(workspace.pathOf(zip));
    if (!notarized.ok) {
      activity.failed(notarized.problem ?? 'Apple rejected the submission');
      output.problem(
        Diagnostic(
          code: 'RK-NOTARY-002',
          message: '$platform: notarization did not complete',
          remedy: notarized.remedy ?? notarized.problem ?? 'see notarytool',
        ),
        unit: step.unit,
      );
      return false;
    }
    activity.done('notarized');
    return true;
  }

  // ---- archive ----

  Future<bool> archiveStep(Step step, ResolvedProject project) async {
    final platform = step.platform!;
    final executable = project.executable!;
    final binary = workspace.readBytes(binaryName(platform, executable));
    if (binary == null) {
      return _missingArtifact(
        step,
        binaryName(platform, executable),
        'the build step produces it',
      );
    }

    final entries = <ArchiveEntry>[
      ArchiveEntry(name: executable, bytes: binary, executable: true),
    ];
    // LICENSE and README travel with the binary by convention, not by
    // configuration.
    final directory = _projectDirectory(project);
    for (final extra in const ['LICENSE', 'README.md']) {
      final file = File('$directory/$extra');
      if (file.existsSync()) {
        entries.add(ArchiveEntry(name: extra, bytes: file.readAsBytesSync()));
      }
    }

    final name = archiveName(
      executable,
      project.version.canonical,
      platform,
    );
    workspace.write(name, ArchiveBuilder.gzip(ArchiveBuilder.tar(entries)));
    output.step(
      step,
      mark: Mark.done,
      verdict: Verdict.exact,
      detail: name,
      note: name,
    );
    return true;
  }

  // ---- checksums ----

  Future<bool> checksumsStep(Step step, ResolvedProject project) async {
    final assets = <String, List<int>>{};
    for (final platform in project.binaryPlatforms) {
      final name = archiveName(
        project.executable!,
        project.version.canonical,
        platform,
      );
      final bytes = workspace.readBytes(name);
      if (bytes == null) {
        return _missingArtifact(step, name, 'the archive steps produce it');
      }
      assets[name] = bytes;
    }

    workspace.write('SHA256SUMS', utf8.encode(Checksums.render(assets)));
    output.step(
      step,
      mark: Mark.done,
      verdict: Verdict.exact,
      detail: '${assets.length} archives',
      note: '${assets.length} archives',
    );
    return true;
  }

  // ---- the public acts, gathering from the workspace by name ----

  /// The asset list a release of [project] ships, from the workspace — or
  /// null with an honest refusal when something is not there.
  List<ReleaseAsset>? gatherAssets(ResolvedProject project, String unit) {
    final assets = <ReleaseAsset>[];
    for (final platform in project.binaryPlatforms) {
      final name = archiveName(
        project.executable!,
        project.version.canonical,
        platform,
      );
      final bytes = workspace.readBytes(name);
      if (bytes == null) {
        output.problem(
          Diagnostic(
            code: 'RK-WORK-001',
            message: 'the workspace has no $name',
            remedy: 'the archive steps produce it — re-running runs them',
          ),
          unit: unit,
        );
        return null;
      }
      assets.add(ReleaseAsset(
        name: name,
        path: workspace.pathOf(name),
        bytes: bytes,
        platform: platform,
      ));
    }

    final sums = workspace.readBytes('SHA256SUMS');
    if (sums == null) {
      output.problem(
        Diagnostic(
          code: 'RK-WORK-001',
          message: 'the workspace has no SHA256SUMS',
          remedy: 'the checksums step produces it — re-running runs it',
        ),
        unit: unit,
      );
      return null;
    }
    assets.add(ReleaseAsset(
      name: 'SHA256SUMS',
      path: workspace.pathOf('SHA256SUMS'),
      bytes: sums,
      platform: null,
    ));
    return assets;
  }

  /// Publishes the gathered assets as one immutable release.
  Future<String?> publishRelease({
    required String repository,
    required String tag,
    required String title,
    required List<ReleaseAsset> assets,
  }) async {
    final release = GithubRelease(
      tools: tools,
      repository: repository,
      workingDirectory: repositoryRoot,
    );

    output.progress('publishing ${assets.length} assets');
    final published = await release.publish(
      tag: tag,
      title: title,
      assetPaths: assets.map((a) => a.path).toList(),
    );
    if (!published.ok) {
      output.line('github-release',
          mark: Mark.blocked, note: published.problem);
      // Three different things, and an operator acts differently on each: rk
      // never wrote; rk wrote and could not read it back, so re-running
      // classifies it; or rk read it back and it is permanently wrong, which
      // re-running cannot touch.
      output.halt(
        published.isTerminal
            ? HaltKind.actedAndUnfixable
            : published.mayHaveActed
                ? HaltKind.lostTrack
                : HaltKind.beforeActing,
      );
      if (published.permanent != null) {
        output.say(published.permanent!);
        output.say('the only way forward is the next version.');
      }
      return null;
    }
    output.line(
      'github-release',
      mark: Mark.done,
      note: '${assets.length} assets, immutable',
    );
    return published.url;
  }

  /// Moves the tap formula to this release.
  Future<bool> updateFormula({
    required String tap,
    required String repository,
    required String tag,
    required ResolvedProject project,
    required List<ReleaseAsset> assets,
  }) async {
    final executable = project.executable!;
    final formula = HomebrewFormula.render(
      className: HomebrewFormula.classNameFor(executable),
      description: 'Released by rk',
      homepage: 'https://github.com/$repository',
      version: project.version.canonical,
      repository: repository,
      tag: tag,
      executable: executable,
      assets: {
        for (final asset in assets)
          if (asset.platform != null)
            asset.platform!: PlatformAsset(
              name: asset.name,
              sha256: Sha256.hex(asset.bytes),
            ),
      },
    );

    final result = await HomebrewTap(
      tools: tools,
      tap: tap,
      checkout: workspace.pathOf('tap'),
    ).update(
      formulaPath: 'Formula/$executable.rb',
      contents: formula,
      message: '$executable ${project.version}',
    );

    if (!result.ok) {
      // A problem, not a bare line: a formula failure that never reached
      // `problems` was invisible to every --json caller.
      output.problem(
        Diagnostic(
          code: 'RK-BREW-001',
          message: 'the tap formula was not updated',
          remedy: result.problem ?? 'see the tap output',
        ),
      );
      return false;
    }
    output.line(
      'homebrew',
      mark: Mark.done,
      note: result.changed ? 'formula updated' : 'formula already current',
    );
    return true;
  }

  bool _missingArtifact(Step step, String name, String producedBy) {
    output.problem(
      Diagnostic(
        code: 'RK-WORK-001',
        message: 'the workspace has no $name',
        remedy: '$producedBy — re-running runs it',
      ),
      unit: step.unit,
    );
    return false;
  }
}

class ReleaseAsset {
  ReleaseAsset({
    required this.name,
    required this.path,
    required this.bytes,
    required this.platform,
  });

  final String name;
  final String path;
  final List<int> bytes;
  final String? platform;
}
