import 'dart:convert';
import 'dart:io';

import 'builds/capability.dart';
import 'builds/dart_cli.dart';
import 'destinations/github_release.dart';
import 'destinations/homebrew.dart';
import 'engine/assets.dart';
import 'engine/checklist.dart';
import 'engine/diagnostic.dart';
import 'output/output.dart';
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
/// codes; its API is buildStep, signStep, notarizeStep, archiveStep,
/// checksumsStep, each called by `commands/release.dart`. And it is not an
/// adapter by this codebase's own test, the one `destinations/git_tag.dart`
/// states: it holds an [Output] at thirty-odd sites, where every file in
/// `builds/`, `transforms/` and `destinations/` holds one at zero.
///
/// It lived in `commands/` until `ls` there exposed a non-command alongside
/// the three verbs promised by the README and RFC.
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

  static String binaryName(String platform, String executable) =>
      '$platform/$executable';

  static String zipName(String platform, String executable) =>
      '$platform/$executable.zip';

  // ---- build ----

  Future<LocalProducerOutcome> buildStep(
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
      return LocalProducerOutcome.failed(
        capability.reason ?? 'this host cannot produce $platform',
      );
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
        return LocalProducerOutcome.succeeded(
          outputs: [LocalProducerOutput(name, 'executable')],
          evidence: const {
            'smoke': {'status': 'passed'},
          },
        );
      }
    }

    final activity = output.begin(step);
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
      return LocalProducerOutcome.failed(
        built.problem ?? 'the build failed',
      );
    }
    workspace.ingest(name);

    // The proof's absence travels with the artifact. `built` alone would
    // read as "checked", which is the claim rk must not make for a binary
    // nothing here could run.
    final unproven = built.unproven;
    if (unproven != null) {
      activity.done('built, not executed');
      output.step(
        step,
        mark: Mark.done,
        verdict: Verdict.exact,
        detail: 'built, not executed — $unproven',
        note: 'built, not executed — $unproven',
        show: false,
      );
      return LocalProducerOutcome.succeeded(
        outputs: [LocalProducerOutput(name, 'executable')],
        evidence: {
          'smoke': {
            'status': 'not-executed',
            'reason': unproven,
          },
        },
      );
    }
    activity.done('built');
    return LocalProducerOutcome.succeeded(
      outputs: [LocalProducerOutput(name, 'executable')],
      evidence: const {
        'smoke': {'status': 'passed'},
      },
    );
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
  /// tautology.
  ///
  /// [codeId] is resolved by the caller, before anything acts, and is
  /// non-null by construction: it is read off the published binary, or
  /// declared, or the release was refused (RK-SIGN-009). This step used to
  /// resolve it itself and fall back to the package name — inventing, at the
  /// one moment that makes the answer permanent, a value nothing had stated.
  Future<LocalProducerOutcome> signStep(
    Step step,
    ResolvedProject project, {
    required String? publishedRequirement,
    required String codeId,
    SigningIdentity? signingIdentity,
    String? certificateSha256,
  }) async {
    final platform = step.platform!;
    final name = binaryName(platform, project.executable!);
    if (!workspace.exists(name)) {
      return _missingArtifact(step, name, 'the build step produces it');
    }
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
      codeId: codeId,
      selectedIdentity: signingIdentity,
      expectedCertificateSha256: certificateSha256,
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
      return LocalProducerOutcome.failed(
        signed.problem ?? 'signing failed',
      );
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
        output.halt(output.report.acted
            ? HaltKind.actedAndUnfixable
            : HaltKind.unfixableByRerun);
        return const LocalProducerOutcome.failed(
          'the produced signature differs from the published identity',
        );
      }
      output.step(
        step,
        mark: Mark.done,
        verdict: Verdict.exact,
        detail: 'signed · matches the published identity',
        note: 'signed · matches the published identity',
      );
    } else {
      // A first signed release makes an identity permanent, so it is named
      // rather than assumed: the certificate that signed and the identifier
      // every later release must reproduce.
      output.step(
        step,
        mark: Mark.done,
        verdict: Verdict.exact,
        detail: 'signed · first release · ${signed.certificate ?? 'unknown '
            'certificate'} · $codeId',
        note: 'signed · first release · ${signed.certificate ?? 'unknown '
            'certificate'} · $codeId',
      );
    }
    final signedSha256 = Sha256.hex(workspace.readBytes(name)!);
    return LocalProducerOutcome.succeeded(
      outputs: [LocalProducerOutput(name, 'executable')],
      evidence: {
        'signature': {
          'first_identity': publishedRequirement == null,
          'published_requirement': publishedRequirement,
          'designated_requirement': signed.requirement,
          'code_id': codeId,
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
    final executable = project.executable!;
    final binary = binaryName(platform, executable);
    if (!workspace.exists(binary)) {
      return _missingArtifact(
          step,
          binary,
          'the build and sign steps '
          'produce it');
    }

    final resultName = ReleaseAssets.notaryResultName(
      executable,
      project.version.canonical,
      platform,
    );
    final logName = ReleaseAssets.notaryLogName(
      executable,
      project.version.canonical,
      platform,
    );

    final signer = MacOsSigner(tools: tools);
    if (await signer.isNotarized(workspace.pathOf(binary)) &&
        workspace.exists(resultName) &&
        workspace.exists(logName)) {
      // Apple vouches for the bytes; the evidence files vouch for the
      // release. Both or neither: notarized bytes without the result and
      // log would publish a release missing two of its expected assets.
      output.step(
        step,
        mark: Mark.satisfied,
        verdict: Verdict.exact,
        detail: 'Apple already notarized these exact bytes',
        note: 'Apple already notarized these exact bytes',
      );
      return _notaryOutcome(
        resultName: resultName,
        logName: logName,
        zipName: workspace.exists(zipName(platform, executable))
            ? zipName(platform, executable)
            : null,
      );
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
      return LocalProducerOutcome.failed(zipped.summary);
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
      return LocalProducerOutcome.failed(
        notarized.problem ?? 'Apple rejected the submission',
      );
    }

    // The verdict and its log become published assets, so a user who
    // trusts neither can ask Apple with the submission id inside them.
    workspace.write(resultName, utf8.encode(notarized.raw ?? '{}'));
    final submission = notarized.submissionId;
    final log = submission == null
        ? null
        : await MacOsNotarizer(tools: tools).log(submission);
    if (log == null || !log.ok) {
      activity.failed('the notarization log could not be fetched');
      output.problem(
        Diagnostic(
          code: 'RK-NOTARY-003',
          message: '$platform: Apple accepted the submission and the log '
              'could not be fetched',
          remedy: log == null
              ? 'the submission id was not in notarytool\'s answer'
              : log.summary,
        ),
        unit: step.unit,
      );
      return const LocalProducerOutcome.failed(
        'the notarization log could not be fetched',
      );
    }
    workspace.write(logName, utf8.encode(log.stdout));
    activity.done('notarized');
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
    final directory = project.directoryIn(repositoryRoot);
    for (final extra in const ['LICENSE', 'README.md']) {
      final file = File('$directory/$extra');
      if (file.existsSync()) {
        entries.add(ArchiveEntry(name: extra, bytes: file.readAsBytesSync()));
      }
    }

    final name = ReleaseAssets.archiveName(
      executable,
      project.version.canonical,
      platform,
    );
    final bytes = ArchiveBuilder.gzip(ArchiveBuilder.tar(entries));
    workspace.write(name, bytes);
    output.step(
      step,
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

  // ---- checksums ----

  Future<LocalProducerOutcome> checksumsStep(
    Step step,
    ResolvedProject project,
  ) async {
    final assets = <String, List<int>>{};
    for (final platform in project.binaryPlatforms) {
      final name = ReleaseAssets.archiveName(
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

    workspace.write(
        ReleaseAssets.checksums, utf8.encode(Checksums.render(assets)));
    output.step(
      step,
      mark: Mark.done,
      verdict: Verdict.exact,
      detail: '${assets.length} archives',
      note: '${assets.length} archives',
    );
    return LocalProducerOutcome.succeeded(
      outputs: const [
        LocalProducerOutput(ReleaseAssets.checksums, 'checksums'),
      ],
      evidence: {
        'checksums': {
          for (final entry in assets.entries)
            entry.key: Sha256.hex(entry.value),
        },
      },
    );
  }

  // ---- the public acts, gathering from the workspace by name ----

  /// The asset list a release of [project] ships, from the workspace — or
  /// null with an honest refusal when something is not there.
  ///
  /// The set mirrors [Inspector.expectedAssets] by construction: what this
  /// gathers is what a later inspection expects, and the real keybay 0.1.0
  /// release is the reference shape — archives, notary evidence per macOS
  /// platform, the formula, the checksums.
  List<ReleaseAsset>? gatherAssets(
    ResolvedProject project,
    String unit, {
    bool includeFinal = true,
  }) {
    final assets = <ReleaseAsset>[];
    ReleaseAsset? named(String name, String producer, {String? platform}) {
      final bytes = workspace.readBytes(name);
      if (bytes == null) {
        output.problem(
          Diagnostic(
            code: 'RK-WORK-001',
            message: 'the workspace has no $name',
            remedy: '$producer — re-running runs it',
          ),
          unit: unit,
        );
        return null;
      }
      return ReleaseAsset(
        name: name,
        path: workspace.pathOf(name),
        bytes: bytes,
        platform: platform,
      );
    }

    for (final platform in project.binaryPlatforms) {
      final executable = project.executable!;
      final version = project.version.canonical;
      final archive = named(
        ReleaseAssets.archiveName(executable, version, platform),
        'the archive steps produce it',
        platform: platform,
      );
      if (archive == null) return null;
      assets.add(archive);

      if (platform.startsWith('macos-')) {
        for (final evidence in [
          ReleaseAssets.notaryResultName(executable, version, platform),
          ReleaseAssets.notaryLogName(executable, version, platform),
        ]) {
          final asset = named(evidence, 'the notarize step produces it');
          if (asset == null) return null;
          assets.add(asset);
        }
      }
    }

    final sums =
        named(ReleaseAssets.checksums, 'the checksums step produces it');
    if (sums == null) return null;
    assets.add(sums);

    if (includeFinal) {
      if (project.channels.contains('homebrew')) {
        final formula = named(
          ReleaseAssets.formulaName(project.executable!),
          'the staging phase renders it',
        );
        if (formula == null) return null;
        assets.add(formula);
      }
      final manifest = named(
        ReleaseAssets.manifest,
        'the complete-stage step produces it',
      );
      if (manifest == null) return null;
      assets.add(manifest);
    }
    return assets;
  }

  /// Renders the formula from the gathered assets and writes it into the
  /// workspace, returning it as an asset.
  ///
  /// Written before the release is created, because it ships with the
  /// release — and the tap step then reads these same bytes, so the formula
  /// in the tap and the one in the release cannot differ.
  ReleaseAsset renderFormula({
    required ResolvedProject project,
    required String repository,
    required String tag,
    required List<ReleaseAsset> assets,
  }) {
    final executable = project.executable!;
    final contents = HomebrewFormula.render(
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
    final name = ReleaseAssets.formulaName(executable);
    final bytes = utf8.encode(contents);
    workspace.write(name, bytes);
    return ReleaseAsset(
      name: name,
      path: workspace.pathOf(name),
      bytes: bytes,
      platform: null,
    );
  }

  /// Publishes the gathered assets as one immutable release.
  Future<PublishOutcome> publishRelease({
    required String repository,
    required String tag,
    required String title,
    required String notesPath,
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
      notesPath: notesPath,
      assetPaths: assets.map((a) => a.path).toList(),
      assetSha256: {
        for (final asset in assets) asset.name: Sha256.hex(asset.bytes),
      },
      assetSizes: {
        for (final asset in assets) asset.name: asset.bytes.length,
      },
    );
    // Do not classify or render an ambiguous response here. ReleaseCommand
    // immediately performs the shared exact destination inspection, which is
    // the only read allowed to decide whether a public effect exists.
    return published;
  }

  /// Moves the tap formula to this release — the same bytes the release
  /// itself shipped, read from the workspace rather than re-rendered, so
  /// the two copies cannot drift.
  Future<TapOutcome> updateFormula({
    required String tap,
    required ResolvedProject project,
    required HomebrewUpdateAuthority authority,
  }) async {
    final executable = project.executable!;
    final formula = workspace.readBytes(ReleaseAssets.formulaName(executable));
    if (formula == null) {
      return TapOutcome.failed(
        'the workspace has no ${ReleaseAssets.formulaName(executable)}; '
        'the github-release step produces it — re-running runs it',
      );
    }

    final formulaPath = 'Formula/$executable.rb';
    final Directory scratch;
    try {
      scratch = Directory.systemTemp.createTempSync('rk-tap-');
    } on FileSystemException catch (error) {
      return TapOutcome.failed(
        'a temporary checkout could not be created: $error',
      );
    }
    final checkout = '${scratch.path}/tap';
    final result = await HomebrewTap(
      tools: tools,
      tap: tap,
      checkout: checkout,
    ).update(
      formulaPath: formulaPath,
      contents: utf8.decode(formula),
      message: '$executable ${project.version}',
      authority: authority,
    );
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      // Public truth, not scratch cleanup, decides the step.
    }

    // The shared Homebrew inspector performs the one authoritative readback.
    // Returning the command outcome keeps a lost push response distinct from
    // a private clone/write failure without pre-empting that public truth.
    return result;
  }

  LocalProducerOutcome _notaryOutcome({
    required String resultName,
    required String logName,
    required String? zipName,
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
        if (zipName != null) LocalProducerOutput(zipName, 'notary-input'),
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
        outputs = List<LocalProducerOutput>.unmodifiable(outputs),
        evidence = Map<String, Object?>.unmodifiable(evidence);

  const LocalProducerOutcome.failed([this.problem])
      : ok = false,
        outputs = const [],
        evidence = const {};

  final bool ok;
  final String? problem;
  final List<LocalProducerOutput> outputs;
  final Map<String, Object?> evidence;
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
