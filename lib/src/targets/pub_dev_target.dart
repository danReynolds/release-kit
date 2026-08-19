import 'dart:io';

import '../engine/assets.dart';
import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/publish_target.dart';
import '../engine/pubspec.dart';
import '../engine/registry.dart';
import '../engine/release_stage.dart';
import '../engine/resolve.dart';
import '../engine/stage_contract.dart';
import '../engine/stage_receipt.dart';
import '../engine/targets.dart';
import '../engine/verdict.dart';
import '../engine/yaml.dart';
import '../engine/version.dart';
import '../output/output.dart';
import '../output/progress.dart';
import 'target_module.dart';

final class PubDevTargetModule extends TargetModule {
  const PubDevTargetModule();

  @override
  String planNote(TargetExpectation target) =>
      '${target.identity} ${target.targetVersion}';

  @override
  PublishTarget get target => PublishTarget.pubDev;

  @override
  StepKind get stepKind => StepKind.publishRegistry;

  @override
  ProgressActivity get actActivity => ProgressActivity(
        running: 'publishing',
        failed: 'publish failed',
      );

  @override
  TargetSessionProvider get sessionProvider => const _PubDevSession();

  @override
  TargetExpectation expectation({
    required ResolvedUnit unit,
    required Step step,
    String? repository,
  }) {
    final project = unit.projects.firstWhere(
      (project) => project.name == step.project,
    );
    return TargetExpectation(
      label: 'pub.dev · ${project.name}',
      kindLabel: 'pub.dev',
      identity: project.name,
      coordinate: project.name,
      targetVersion: project.version.canonical,
      step: step,
      project: project,
      // pub publishes the staged source directory. There is no honest public
      // archive filename to invent for this row.
      artifacts: const [],
    );
  }

  @override
  Future<Inspection> inspectExact(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetExpectation target,
  ) {
    final reader = context.registry;
    if (reader == null) {
      return Future.value(
        const Inspection.unknown('the registry reader is not configured'),
      );
    }
    final exact = context.pubDev;
    if (exact == null) {
      return Future.value(
        const Inspection.unknown(
          'the exact pub.dev inspector was not configured',
        ),
      );
    }
    final stage = context.reusableStage(unit);
    String? expectedArchiveSha256;
    if (stage != null) {
      try {
        expectedArchiveSha256 = _pubArchive(stage, target.project!).sha256;
      } on Object catch (error) {
        return Future.value(
          Inspection.unknown(
            'the staged pub archive could not be read: $error',
          ),
        );
      }
    }
    return exact.inspectProject(
      target.project!,
      expectedArchiveSha256: expectedArchiveSha256,
    );
  }

  @override
  Future<Inspection> inspectLatest(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetExpectation target,
  ) async {
    final reader = context.registry;
    if (reader == null) {
      return const Inspection.unknown('the registry reader is not configured');
    }
    try {
      final package = await reader.lookup(target.coordinate);
      final latest = package?.latest;
      if (latest == null) {
        return const Inspection.absent(detail: 'no published package version');
      }
      final publishedRepository = latest.repository;
      final localRepository = target.project!.pubspec.repository;
      final publishedIdentity = _repositoryIdentity(publishedRepository);
      final localIdentity = _repositoryIdentity(localRepository);
      if (publishedIdentity != null &&
          localIdentity != null &&
          publishedIdentity != localIdentity) {
        return Inspection.conflict(
          '${target.coordinate} points to another repository on pub.dev',
          evidence: {
            'published repository': publishedRepository!,
            'this repository': localRepository!,
          },
        );
      }
      return Inspection.exact(
        detail: 'latest published package is ${latest.version}',
        evidence: {'version': latest.version.canonical},
      );
    } on Object catch (error) {
      return Inspection.unknown(
        'the latest pub.dev version could not be read: $error',
      );
    }
  }

  @override
  void invalidate(TargetReadContext context, TargetExpectation target) {
    context.registry?.forget(target.coordinate);
  }

  @override
  Diagnostic? aheadDiagnostic(
    ResolvedUnit unit,
    TargetExpectation target,
    Version publicVersion,
  ) {
    final project = target.project!;
    return Diagnostic(
      code: 'RK-MONO-002',
      message: '${project.name} ${project.version} is behind published version '
          '$publicVersion',
      source: SourceLocation(
        project.pubspec.path,
        project.pubspec.versionLine,
      ),
      remedy: 'a release moves forward — bump past $publicVersion',
    );
  }

  @override
  Diagnostic? diagnosticForInspection(
    ResolvedUnit unit,
    TargetExpectation target,
    Inspection inspection,
  ) {
    if (inspection.verdict != Verdict.conflict) return null;
    final published = inspection.evidence['published repository'];
    final local = inspection.evidence['this repository'];
    if (published == null || local == null) return null;
    final project = target.project!;
    return Diagnostic(
      code: 'RK-PUB-010',
      message: '${project.name} on pub.dev points to $published, not $local',
      source: SourceLocation(project.pubspec.path, project.pubspec.nameLine),
      remedy: 'choose an unclaimed package name in pubspec.yaml; pub.dev '
          'package names cannot be reclaimed by publishing a newer version',
    );
  }

  @override
  bool ownsDiagnostic(
    Diagnostic diagnostic,
    TargetExpectation target,
  ) =>
      (diagnostic.code == 'RK-MONO-002' || diagnostic.code == 'RK-PUB-010') &&
      diagnostic.source?.path == target.project?.pubspec.path;

  @override
  String conflictRemedy(
    ResolvedUnit unit,
    TargetExpectation target,
  ) =>
      'pub.dev versions are immutable. Bump the version and changelog, '
      'then stage the new release';

  @override
  Future<TargetReadinessOutcome> preflight(
    TargetReadinessContext context,
    ResolvedUnit unit,
  ) async {
    final redirected = unit.projects
        .where((project) => project.publish.contains(PublishTarget.pubDev))
        .any((project) => !isPubDevDestination(
              project.pubspec.effectivePublishDestination(context.environment),
            ));
    if (!redirected) return const TargetReady();
    return TargetNotReady(
      Diagnostic(
        code: 'RK-PUB-009',
        message: 'the native Dart configuration redirects pub.dev publication',
        remedy: 'rk will not publish a pub.dev target to an ambient or custom '
            'registry. Remove PUB_HOSTED_URL, or declare the intended native '
            'publish_to and use a future matching target. The URL is omitted '
            'because it may contain credentials.',
      ),
      unit: unit.name,
    );
  }

  @override
  String effectiveEndpoint(
    TargetReadinessContext context,
    ResolvedUnit unit,
    List<TargetExpectation> targets,
  ) {
    final endpoints = <String>[
      for (final target in targets)
        target.project!.pubspec
            .effectivePublishDestination(context.environment),
    ]..sort();
    return endpoints.join('\n');
  }

  @override
  Future<TargetActOutcome> act(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetExpectation target,
    Inspection inspected,
  ) async {
    final project = target.project!;
    final archive = _pubArchive(context.stage, project);
    final sourceRoot = context.stage.sourceRoot;
    final directory = project.pubspec.directory == '.'
        ? sourceRoot
        : '$sourceRoot/${project.pubspec.directory}';
    final code = await context.runInteractive(
      'dart',
      [
        'pub',
        'publish',
        '--from-archive',
        context.workspace.pathOf(archive.path),
        '--force',
      ],
      workingDirectory: directory,
    );
    context.reads.registry!.forget(project.name);
    if (code != 0) {
      if (code == 64) {
        return TargetActOutcome(
          ok: false,
          coordinate: '${project.name} ${project.version}',
          mayHaveActed: false,
          diagnostic: const Diagnostic(
            code: 'RK-PUB-011',
            message: 'this Dart SDK cannot publish the staged Pub archive',
            remedy: 'upgrade Dart to an SDK whose pub publish command '
                'supports native archive publication, then re-run. rk will '
                'not repackage the staged release at publication time.',
          ),
        );
      }
      return TargetActOutcome(
        ok: false,
        coordinate: '${project.name} ${project.version}',
        mayHaveActed: true,
        diagnostic: Diagnostic(
          code: 'RK-PUB-003',
          message: '${project.name}: dart pub publish did not complete',
          remedy: 'fix what dart pub reported and re-run. The login preflight '
              'confirms a current session, not uploader permission for this '
              'package; if the upload may have landed, re-running inspects '
              'public truth before acting',
        ),
        includeInspectionDetail: true,
        reconciledNote: 'publish response was lost',
      );
    }
    return TargetActOutcome(
      ok: true,
      coordinate: '${project.name} ${project.version}',
      mayHaveActed: true,
      successNote: 'published',
      includeInspectionDetail: true,
    );
  }

  @override
  Future<Inspection> settleAfterAct(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetExpectation target,
  ) async {
    var waited = Duration.zero;
    while (true) {
      invalidate(context.reads, target);
      final state = await inspectExact(context.reads, unit, target);
      if (!state.isAbsent || waited >= context.confirmDeadline) {
        if (state.isAbsent && waited >= context.confirmDeadline) {
          final project = target.project!;
          return Inspection.absent(
            detail: 'pub.dev does not report it after ${waited.inSeconds}s: '
                '${project.name} ${project.version}',
            evidence: state.evidence,
          );
        }
        return state;
      }
      await context.wait(context.confirmInterval);
      waited += context.confirmInterval;
    }
  }

  @override
  Future<TargetFailure> classifyFailure(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetExpectation target,
    Inspection state,
    TargetActOutcome act, {
    required bool actedBefore,
  }) async {
    final conflict = state.verdict == Verdict.conflict;
    final code = conflict ? 'RK-PUB-006' : act.diagnostic?.code ?? 'RK-PUB-005';
    final message = conflict
        ? '${act.coordinate ?? target.project?.name}: '
            '${state.detail ?? 'the public archive differs'}'
        : act.diagnostic?.message ??
            '${act.coordinate ?? target.project?.name}: the exact public '
                'archive could not be confirmed';
    final details = <String>[
      if (act.diagnostic?.remedy != null) act.diagnostic!.remedy!,
      if (act.problem != null) act.problem!,
      if (state.detail != null) state.detail!,
      ...state.evidence.entries.map((entry) => '${entry.key}: ${entry.value}'),
    ];
    final halt = conflict
        ? HaltKind.actedAndUnfixable
        : act.mayHaveActed || state.verdict == Verdict.unknown
            ? HaltKind.lostTrack
            : actedBefore
                ? HaltKind.stoppedPartway
                : HaltKind.beforeActing;
    return TargetFailure(
      diagnostic: Diagnostic(
        code: code,
        message: message,
        remedy: details.isEmpty
            ? 're-run; the shared destination inspection will classify the '
                'public target before any retry'
            : details.join('\n'),
      ),
      halt: halt,
      nextCommand: code == 'RK-PUB-005' ? 'rk status ${unit.name}' : null,
    );
  }

  @override
  Iterable<String> completionLines(
    ResolvedUnit unit,
    TargetExpectation target,
  ) =>
      [
        'pub.dev/packages/${target.project!.name}/versions/'
            '${target.project!.version}',
      ];

  @override
  TargetStage stage({
    required ResolvedUnit unit,
    required TargetExpectation target,
  }) {
    final archivePath = ReleaseAssets.pubArchivePath(target.project!);
    final contract = StageContributionContract(
      phase: StageContributionPhase.beforeArtifacts,
      step: StageStepContract(
        'pub-archive:${target.project!.name}',
        inputs: const {'step:source-snapshot'},
        outputs: {archivePath: 'pub-archive'},
      ),
    );
    return TargetStage(
      target: target,
      contract: contract,
      progress: [
        TargetStageProgress.row(
          id: 'source',
          label: 'package archive',
        ),
      ],
      prepare: (context) => _prepareStage(context, target.project!),
    );
  }

  Future<TargetStageOutcome> _prepareStage(
    TargetStageContext context,
    ResolvedProject project,
  ) async {
    final receiptName = context.contract.step.name;
    context.progress('source').begin(CommonProgressActivities.validating);
    final validation = await _packageArchive(context, project);
    if (validation.diagnostic case final diagnostic?) {
      return TargetStageFailure(
        diagnostic,
        unit: project.unitName,
      );
    }
    return TargetStageSuccess(
      StageStep(
        name: receiptName,
        inputs: [StageInput.step(context.sourceStep)],
        outputs: [
          StageArtifact.capture(
            stage: context.stage.directory,
            path: ReleaseAssets.pubArchivePath(project),
            type: 'pub-archive',
          ),
        ],
        evidence: const {'package_archive': 'staged'},
      ),
      notices: validation.notices,
    );
  }

  Future<({Diagnostic? diagnostic, List<String> notices})> _packageArchive(
    TargetStageContext context,
    ResolvedProject project,
  ) async {
    final sourceRoot = context.stage.sourceRoot;
    final directory = project.pubspec.directory == '.'
        ? sourceRoot
        : '$sourceRoot/${project.pubspec.directory}';

    // pub honours dependency overrides — the pubspec_overrides.yaml file
    // and the dependency_overrides: section of pubspec.yaml — at the
    // resolution root, and strips both from the published archive. A
    // tracked override therefore makes every local validation pass against
    // a dependency graph consumers never get; native validation even exits 0
    // with only a hint. Refusing is the honest check; simulating a
    // consumer was not.
    final masking = _maskedResolution(sourceRoot, directory);
    if (masking != null) {
      return (
        diagnostic: Diagnostic(
          code: 'RK-PUB-008',
          message: '${project.name}: tracked dependency overrides '
              'mask consumer resolution',
          remedy: '$masking is honoured locally and stripped from the '
              'published archive, so validation here would not see what '
              'consumers see. Remove it and re-stage.',
        ),
        notices: const <String>[],
      );
    }

    final archivePath = ReleaseAssets.pubArchivePath(project);
    final archive = File(context.workspace.pathOf(archivePath));
    archive.parent.createSync(recursive: true);
    final packaged = await context.tools.run(
      'dart',
      ['pub', 'publish', '--to-archive', archive.path],
      workingDirectory: directory,
    );
    final validation = '${packaged.stdout}\n${packaged.stderr}'.trim();
    context.attach(
      'pub-package-${project.name}.txt',
      validation,
    );

    if (!packaged.ok) {
      final lower = validation.toLowerCase();
      if (lower.contains('to-archive') &&
          (lower.contains('could not find') ||
              lower.contains('unknown option') ||
              lower.contains('unrecognized option'))) {
        return (
          diagnostic: Diagnostic(
            code: 'RK-PUB-011',
            message: 'this Dart SDK cannot stage the native Pub archive',
            remedy: 'upgrade Dart to an SDK whose pub publish command '
                'supports native archive staging, then re-run. rk does not '
                'reimplement Pub packaging or publish different bytes from '
                'the ones it staged.',
          ),
          notices: const <String>[],
        );
      }
      final summary = RegExp(r'Package has[^\n]*')
          .allMatches(validation)
          .map((match) => match.group(0)!)
          .lastOrNull;
      final warningsOnly = summary != null &&
          !summary.toLowerCase().contains('error') &&
          summary.toLowerCase().contains('warning');
      if (!warningsOnly || !archive.existsSync()) {
        return (
          diagnostic: Diagnostic(
            code: 'RK-PUB-001',
            message: 'pub refuses to publish ${project.name}',
            remedy: validation.isEmpty ? packaged.summary : validation,
          ),
          notices: const <String>[],
        );
      }
      final notices = <String>[
        'pub warns, and --force will publish past these:',
      ];
      for (final line in validation.split('\n')) {
        if (line.trimLeft().startsWith('*')) {
          notices.add(line.trim());
        }
      }
      return (diagnostic: null, notices: notices);
    }

    if (!archive.existsSync()) {
      return (
        diagnostic: Diagnostic(
          code: 'RK-PUB-011',
          message: 'Pub reported success without producing $archivePath',
          remedy: 'upgrade or repair the Dart SDK and re-run; rk publishes '
              'only the exact native archive recorded in its stage',
        ),
        notices: const <String>[],
      );
    }

    return (diagnostic: null, notices: const <String>[]);
  }

  /// What masks resolution for the staged package, or null when nothing
  /// does: the overrides file or a non-empty dependency_overrides section,
  /// at the package or at its resolution root. Pub resolves a workspace
  /// member (`resolution: workspace`) at the nearest ancestor declaring
  /// `workspace:`; every other package resolves at itself.
  String? _maskedResolution(String sourceRoot, String directory) {
    String describe(String path) {
      final prefix = '$sourceRoot/';
      return path.startsWith(prefix) ? path.substring(prefix.length) : path;
    }

    for (final root in {directory, _resolutionRoot(sourceRoot, directory)}) {
      final overrides = '$root/pubspec_overrides.yaml';
      if (File(overrides).existsSync()) {
        return describe(overrides);
      }
      final section =
          _pubspecMap('$root/pubspec.yaml')?.map('dependency_overrides');
      if (section != null && section.entries.isNotEmpty) {
        return 'the dependency_overrides section in '
            '${describe('$root/pubspec.yaml')}';
      }
    }
    return null;
  }

  String _resolutionRoot(String sourceRoot, String directory) {
    final member = _pubspecMap('$directory/pubspec.yaml');
    if (member?.string('resolution') != 'workspace') return directory;
    var dir = directory;
    while (dir != sourceRoot && dir.length > sourceRoot.length) {
      final cut = dir.lastIndexOf('/');
      if (cut < 0) break;
      dir = dir.substring(0, cut);
      if (_pubspecMap('$dir/pubspec.yaml')?.has('workspace') == true) {
        return dir;
      }
    }
    // A member whose root is not in the staged source resolves nowhere pub
    // can see; the package directory is the only root left to check.
    return directory;
  }

  YamlMap? _pubspecMap(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    return parseYaml(file.readAsStringSync(), path, Diagnostics());
  }

  @override
  Future<Iterable<TargetClaim>> firstClaims(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetExpectation target,
  ) async {
    final registry = context.registry;
    if (registry == null) return const [];
    try {
      if (await registry.lookup(target.coordinate) != null) return const [];
    } on RegistryUnavailable {
      return const [];
    }
    return [
      TargetClaim(
        registrar: 'pub.dev',
        name: target.coordinate,
        consequence: 'permanent: a package name cannot be renamed, '
            'reassigned, or released back',
      ),
    ];
  }

  @override
  String permanenceNotice(TargetExpectation target) =>
      'pub.dev never deletes a version. a version can be retracted, which '
      'hides it and removes nothing.';
}

final class _PubDevSession extends TargetSessionProvider {
  const _PubDevSession();

  @override
  String get id => 'dart-pub';

  @override
  ProgressActivity get activity => CommonProgressActivities.checkingSignIn;

  @override
  Future<TargetReadinessOutcome> acquire(
    TargetReadinessContext context,
    ResolvedUnit unit,
    List<TargetExpectation> targets,
  ) async {
    // A token already answers for this repository, and pub reads its secret
    // from the environment on every request. Signing in would create a second,
    // durable credential the release does not use.
    if (await _tokenConfigured(context)) {
      return const TargetReady(note: 'token configured');
    }
    // Asked quietly first. A session that is merely stale is refreshed and
    // checked against the provider without anyone typing anything, and pub
    // reports that at length — the address it prints is the one thing rk
    // could not have said itself, and it says it to a terminal that asked
    // about a release. Captured, that costs nothing and shows nothing.
    //
    // A session that needs the browser cannot be served on a pipe: pub
    // would print a URL nobody can see and wait. So the quiet attempt is
    // bounded, and anything but a clean answer is asked again attached,
    // where the operator can act on it.
    try {
      final quiet = await context.tools.run(
        'dart',
        const ['pub', 'login'],
        workingDirectory: context.git.root,
        timeout: const Duration(seconds: 20),
      );
      if (quiet.exitCode == 0) return const TargetReady(note: 'signed in');
    } on ProcessException {
      // The launcher itself failed; the attached attempt reports it.
    }

    int code;
    try {
      code = await context.runInteractive!(
        'dart',
        const ['pub', 'login'],
        workingDirectory: context.git.root,
      );
    } on ProcessException {
      code = -1;
    }
    if (code == 0) return const TargetReady(note: 'signed in');
    return TargetNotReady(
      Diagnostic(
        code: 'RK-PUB-007',
        message: 'dart pub login did not complete',
        remedy: 'Run dart pub login from a terminal, then re-run rk release '
            '${unit.name}. A successful login confirms a current session, '
            'not permission to publish every package.',
      ),
      unit: unit.name,
    );
  }

  /// Whether pub already has a token for pub.dev in this repository.
  ///
  /// Only presence is read. The secret itself stays where pub keeps it — for an
  /// `--env-var` token, in the environment at request time.
  Future<bool> _tokenConfigured(TargetReadinessContext context) async {
    try {
      final tokens = await context.tools.run(
        'dart',
        const ['pub', 'token', 'list'],
        workingDirectory: context.git.root,
      );
      if (!tokens.ok) return false;
      // A whole line, not a substring: a token for a lookalike host such as
      // https://pub.dev.example.com must not answer for pub.dev.
      return tokens.stdout
          .split('\n')
          .map((line) => line.trim())
          .any((line) => line == _pubDevUrl || line == '$_pubDevUrl/');
    } on ProcessException {
      // Nothing to ask. Publishing needs the same executable and refuses by
      // name, so this question goes unanswered rather than ending the run in a
      // crash.
      return false;
    }
  }

  @override
  Future<bool?> established(TargetReadinessContext context) async {
    // A token needs no stored session, so there is nothing to create or clear.
    if (await _tokenConfigured(context)) return true;
    return _sessionStored(context);
  }

  /// Whether this machine already holds a pub session, or null when rk
  /// cannot tell where one would be kept.
  ///
  /// This answers whether a session file is there — which is all the
  /// lifecycle needs, to know whether rk created the session it may have
  /// to clear. It is deliberately not used to skip the login preflight:
  /// `dart pub login` refreshes the stored token, checks it against the
  /// provider, and re-authorizes a session that has expired or been
  /// revoked. A file on disk proves none of that, and a session that is
  /// dead is a release that stops after the tag is public instead of
  /// before anything is.
  static bool? _sessionStored(TargetReadinessContext context) {
    final credentials = _pubCredentialsFile(context.environment);
    if (credentials == null) return null;
    try {
      return credentials.existsSync();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<String?> restore(TargetReadinessContext context) async {
    final out = await context.tools.run(
      'dart',
      const ['pub', 'logout'],
      workingDirectory: context.git.root,
    );
    return out.ok
        ? 'pub session cleared — it did not exist before this release'
        : 'pub session could not be cleared: ${out.summary}';
  }
}

const _pubDevUrl = 'https://pub.dev';

/// Where the pub client keeps the session `dart pub login` writes.
///
/// rk reads whether this exists, never what is in it, so it can leave the
/// machine's session as it found it. Null when the location cannot be derived,
/// which the caller treats as "do not touch".
File? _pubCredentialsFile(Map<String, String> environment) {
  const name = 'dart/pub-credentials.json';
  if (Platform.isWindows) {
    final appData = environment['APPDATA'];
    return appData == null ? null : File('$appData/$name');
  }
  final home = environment['HOME'];
  if (Platform.isMacOS) {
    return home == null
        ? null
        : File('$home/Library/Application Support/$name');
  }
  final config =
      environment['XDG_CONFIG_HOME'] ?? (home == null ? null : '$home/.config');
  return config == null ? null : File('$config/$name');
}

StageArtifact _pubArchive(ReleaseStage stage, ResolvedProject project) {
  final path = ReleaseAssets.pubArchivePath(project);
  final matches = stage
      .requireReceipt()
      .artifacts
      .where((artifact) => artifact.path == path)
      .toList();
  if (matches.length != 1 || matches.single.type != 'pub-archive') {
    throw StateError('the stage does not contain one native Pub archive');
  }
  return matches.single;
}

String? _repositoryIdentity(String? value) {
  if (value == null) return null;
  var text = value.trim();
  if (text.isEmpty) return null;
  final scp = RegExp(r'^[^@\s]+@([^:\s]+):(.+)$').firstMatch(text);
  if (scp != null) text = 'ssh://${scp.group(1)}/${scp.group(2)}';
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  var path = uri.path.replaceFirst(RegExp(r'^/+'), '');
  path = path.replaceFirst(RegExp(r'\.git$'), '');
  path = path.replaceFirst(RegExp(r'/+$'), '');
  if (path.isEmpty) return null;
  return '${uri.host.toLowerCase()}/${path.toLowerCase()}';
}
