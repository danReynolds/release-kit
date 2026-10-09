import 'dart:io';

import '../../engine/assets.dart';
import '../../engine/diagnostic.dart';
import '../../engine/publish_target.dart';
import '../../engine/resolve.dart';
import '../../engine/stage.dart';
import '../../engine/tools.dart';
import '../../engine/unit_release.dart';
import '../../engine/verdict.dart';
import '../target_module.dart';
import 'endpoint.dart';
import 'package_stage.dart';

final class PubDevTargetModule extends TargetModule {
  const PubDevTargetModule({this.endpoint = const PubEndpoint.pubDev()});

  final PubEndpoint endpoint;

  @override
  PublishTarget get target => PublishTarget.pubDev;

  /// A version on pub.dev is published: what is there is what its consumers
  /// get, whatever bytes a stage holds now. The lane's history comes from
  /// the same package lookup, which the registry reader caches.
  @override
  Future<TargetRead> read(
    TargetReadContext reads,
    ResolvedUnit unit,
    Target target, {
    Stage? stage,
  }) async {
    final history = readHistory(() => _history(reads, target));
    return (state: await _inspect(reads, target), history: await history);
  }

  /// After rk's own upload, the archive pub.dev reports must be the one it
  /// staged and uploaded: [stage]'s.
  Future<Inspection> _inspect(
    TargetReadContext context,
    Target target, {
    Stage? stage,
  }) {
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
    final project = target.project!;
    return exact.inspectProject(
      project,
      expectedArchiveSha256:
          stage?.receipt?.files[ReleaseAssets.pubArchivePath(project)]?.sha256,
    );
  }

  Future<TargetHistory> _history(
    TargetReadContext context,
    Target target,
  ) async {
    final reader = context.registry;
    if (reader == null) {
      return TargetHistory(
        inspection: const Inspection.unknown(
          'the registry reader is not configured',
        ),
      );
    }
    try {
      final package = await reader.lookup(target.coordinate);
      final latest = package?.latest;
      if (latest == null) {
        return TargetHistory(
          inspection: const Inspection.absent(
            detail: 'no published package version',
          ),
          claims: package == null
              ? [
                  TargetClaim(
                    registrar: 'pub.dev',
                    name: target.coordinate,
                    consequence:
                        'permanent: a package name cannot be '
                        'renamed, reassigned, or released back',
                  ),
                ]
              : const [],
        );
      }
      // pub.dev keeps the repository the latest version named. One that
      // differs is another project's package, which pub.dev will not let
      // this one upload to, or this repository's from before it moved. Both
      // refuse before the tag is pushed: an upload pub.dev refuses would
      // leave a tag no re-run can finish.
      final project = target.project!;
      final publishedRepository = latest.repository;
      final localRepository = project.pubspec.repository;
      final publishedIdentity = _repositoryIdentity(publishedRepository);
      final localIdentity = _repositoryIdentity(localRepository);
      if (publishedIdentity != null &&
          localIdentity != null &&
          publishedIdentity != localIdentity) {
        return TargetHistory(
          inspection: Inspection.conflict(
            '${target.coordinate} points to another repository on pub.dev',
            evidence: {
              'published repository': publishedRepository!,
              'this repository': localRepository!,
            },
          ),
          problems: [
            Diagnostic(
              code: 'RK-PUB-010',
              message:
                  '${project.name} on pub.dev points to '
                  '$publishedRepository, not $localRepository',
              source: SourceLocation(
                project.pubspec.path,
                project.pubspec.nameLine,
              ),
              remedy:
                  "if the package is another project's, choose an "
                  'unclaimed name in pubspec.yaml. If this repository '
                  'moved, publish this version once yourself with '
                  '`dart pub publish` in ${project.pubspec.directory}: '
                  'pub.dev then names the new repository, and rk release '
                  'finishes the rest',
            ),
          ],
        );
      }
      final inspection = Inspection.exact(
        detail: 'latest published package is ${latest.version}',
        evidence: {'version': latest.version.canonical},
      );
      return TargetHistory.versioned(
        inspection: inspection,
        target: target,
        regressionDiagnostic: (publicVersion) => Diagnostic(
          code: 'RK-MONO-002',
          message:
              '${project.name} ${project.version} is behind published '
              'version $publicVersion',
          source: SourceLocation(
            project.pubspec.path,
            project.pubspec.versionLine,
          ),
          remedy: 'a release moves forward — bump past $publicVersion',
        ),
      );
    } on Object catch (error) {
      return TargetHistory(
        inspection: Inspection.unknown(
          'the latest pub.dev version could not be read: $error',
        ),
      );
    }
  }

  @override
  ({Diagnostic diagnostic, String? next}) explain(
    ResolvedUnit unit,
    Target target,
    Inspection state, {
    TargetActOutcome? acted,
  }) => switch (acted) {
    null => (
      diagnostic: Diagnostic(
        code: 'RK-REL-001',
        message:
            '${target.label}: '
            '${state.detail ?? 'the published package does not match'}',
        remedy:
            'pub.dev versions are immutable. Bump the version and '
            'changelog, then stage the new release',
      ),
      next: null,
    ),
    _ when state.verdict == Verdict.conflict => (
      diagnostic: Diagnostic(
        code: 'RK-PUB-006',
        message:
            '${acted.coordinate ?? target.project?.name}: '
            '${state.detail ?? 'the public archive differs'}',
      ),
      next: null,
    ),
    _ => (
      diagnostic: Diagnostic(
        code: 'RK-PUB-005',
        message:
            '${acted.coordinate ?? target.project?.name}: the exact public '
            'archive could not be confirmed',
      ),
      next: 'rk status ${unit.name}',
    ),
  };

  /// Before staging, the native configuration must publish where this
  /// target does; with [signIn], after the yes, Pub must hold a token or a
  /// session for it.
  @override
  Future<TargetReadiness> ready(
    TargetReadinessContext context,
    ResolvedUnit unit, {
    required bool signIn,
  }) async {
    if (signIn) return _signIn(context, unit);
    final redirected = unit.projects
        .where((project) => project.publish.contains(PublishTarget.pubDev))
        .any(
          (project) => !endpoint.matches(
            project.pubspec.effectivePublishDestination(context.environment),
          ),
        );
    if (!redirected) return const TargetReadiness();
    return TargetReadiness.refused(
      Diagnostic(
        code: 'RK-PUB-009',
        message: endpoint.isPubDev
            ? 'the native Dart configuration redirects pub.dev publication'
            : 'the native Dart configuration differs from the composed registry endpoint',
        remedy: endpoint.isPubDev
            ? 'rk will not publish a pub.dev target to an ambient or custom '
                  'registry. Remove PUB_HOSTED_URL, or declare the intended native '
                  'publish_to and use a future matching target. The URL is omitted '
                  'because it may contain credentials.'
            : 'Match native PUB_HOSTED_URL to the explicit endpoint supplied '
                  'by the command composition.',
      ),
    );
  }

  @override
  Future<TargetActOutcome> publish(
    TargetReleaseContext context,
    ResolvedUnit unit,
    Target target,
    Inspection inspected,
  ) async {
    final project = target.project!;
    // Publication is non-interactive after the explicit session preflight.
    // Capture pub's output so it cannot write through RK's live multi-target
    // progress surface; the transcript is retained if the act fails. Pub
    // uploads the archive as it is, from an empty directory of its own
    // outside the stage.
    final scratch = Directory.systemTemp.createTempSync('rk-pub-publish-');
    final ToolResult result;
    try {
      result = await context.tools.run('dart', [
        'pub',
        'publish',
        '--from-archive',
        context.stage!.pathOf(ReleaseAssets.pubArchivePath(project)),
        '--force',
      ], workingDirectory: scratch.path);
    } finally {
      scratch.deleteSync(recursive: true);
    }
    context.reads.registry!.forget(project.name);
    if (!result.ok) {
      if (result.exitCode == 64) {
        return TargetActOutcome(
          ok: false,
          coordinate: '${project.name} ${project.version}',
          mayHaveActed: false,
          diagnostic: const Diagnostic(
            code: 'RK-PUB-011',
            message: 'this Dart SDK cannot publish the staged Pub archive',
            remedy:
                'upgrade Dart to an SDK whose pub publish command '
                'supports native archive publication, then re-run. rk will '
                'not repackage the staged release at publication time.',
          ),
        );
      }
      return TargetActOutcome(
        ok: false,
        coordinate: '${project.name} ${project.version}',
        mayHaveActed: true,
        problem: result.summary,
        evidence: result.transcript,
        diagnostic: Diagnostic(
          code: 'RK-PUB-003',
          message: '${project.name}: dart pub publish did not complete',
          remedy:
              'fix what dart pub reported and re-run. The login preflight '
              'confirms a current session, not uploader permission for this '
              'package; if the upload may have landed, re-running inspects '
              'public truth before acting',
        ),
        includeInspectionDetail: true,
        reconciledNote: 'publish response was lost',
      );
    }
    // The read-back says when pub.dev published it, and what it compared.
    return TargetActOutcome(
      ok: true,
      coordinate: '${project.name} ${project.version}',
      mayHaveActed: true,
      includeInspectionDetail: true,
    );
  }

  @override
  Future<Inspection> confirm(
    TargetReleaseContext context,
    ResolvedUnit unit,
    Target target,
    TargetActOutcome acted,
  ) async {
    // pub.dev can take minutes to list an upload it accepted. One it refused,
    // or that never arrived, is not worth that wait: a lost response shows
    // within a few reads.
    final deadline = acted.ok
        ? context.confirmDeadline
        : context.confirmInterval * 2;
    var waited = Duration.zero;
    while (true) {
      context.reads.registry?.forget(target.coordinate);
      final state = await _inspect(context.reads, target, stage: context.stage);
      // An answer settles it; a read that failed is asked again, as an
      // absence is, until the deadline.
      final settled =
          state.verdict == Verdict.exact || state.verdict == Verdict.conflict;
      if (settled || waited >= deadline) {
        if (state.isAbsent && waited >= deadline) {
          final project = target.project!;
          return Inspection.absent(
            detail:
                'pub.dev does not report it after ${waited.inSeconds}s: '
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
  Future<Produced> prepare(StageRun run, Work work) =>
      preparePubArchive(run, work);

  /// Pub's own session for this endpoint: a token, a stored session it
  /// refreshes quietly, or `dart pub login` at an attached terminal.
  Future<TargetReadiness> _signIn(
    TargetReadinessContext context,
    ResolvedUnit unit,
  ) async {
    // An environment-backed token needs no second durable credential.
    if (await _tokenConfigured(context)) {
      return const TargetReadiness(note: 'token configured');
    }
    if (!endpoint.isPubDev) {
      return TargetReadiness.refused(
        Diagnostic(
          code: 'RK-PUB-007',
          message: 'the composed local registry has no native Pub token',
          remedy:
              'Register its token using dart pub token add ${endpoint.origin}.',
        ),
      );
    }
    final runInteractive = context.runInteractive;
    final stored = _sessionStored(context) == true;
    if (runInteractive == null && !stored) return _terminalRequired(unit);
    // A stored session is checked quietly, so a current or refreshable one
    // does not surface provider chatter. Without one, pub opens a browser
    // login and waits on it, which only an attached terminal can answer.
    if (stored) {
      try {
        final quiet = await context.tools.run(
          'dart',
          const ['pub', 'login'],
          workingDirectory: context.git.root,
          timeout: const Duration(seconds: 20),
        );
        if (quiet.exitCode == 0) {
          return const TargetReadiness(note: 'signed in');
        }
      } on ProcessException {
        // The attached attempt below reports launcher failure to the operator.
      }
    }

    if (runInteractive == null) return _terminalRequired(unit);

    int code;
    try {
      code = await runInteractive('dart', const [
        'pub',
        'login',
      ], workingDirectory: context.git.root);
    } on ProcessException {
      code = -1;
    }
    if (code == 0) return const TargetReadiness(note: 'signed in');
    return TargetReadiness.refused(
      Diagnostic(
        code: 'RK-PUB-007',
        message: 'dart pub login did not complete',
        remedy:
            'Run dart pub login from a terminal, then re-run rk release '
            '${unit.name}. A successful login confirms a current session, '
            'not permission to publish every package.',
      ),
    );
  }

  static TargetReadiness _terminalRequired(ResolvedUnit unit) =>
      TargetReadiness.refused(
        Diagnostic(
          code: 'RK-PUB-007',
          message: 'dart pub login requires an attached terminal',
          remedy:
              'Run dart pub login from a terminal, then re-run rk release '
              '${unit.name}. Machine and redirected releases require an '
              'existing token or session.',
        ),
      );

  /// Whether Pub already has a token for this exact composed endpoint.
  Future<bool> _tokenConfigured(TargetReadinessContext context) async {
    try {
      final tokens = await context.tools.run('dart', const [
        'pub',
        'token',
        'list',
      ], workingDirectory: context.git.root);
      if (!tokens.ok) return false;
      return tokens.stdout
          .split('\n')
          .map((line) => line.trim())
          .any(endpoint.matches);
    } on ProcessException {
      return false;
    }
  }

  /// Whether this machine already holds a pub session, or null when rk
  /// cannot tell where one would be kept.
  static bool? _sessionStored(TargetReadinessContext context) {
    final credentials = _pubCredentialsFile(context.environment);
    if (credentials == null) return null;
    try {
      return credentials.existsSync();
    } on FileSystemException {
      return null;
    }
  }
}

/// Where the pub client keeps the session `dart pub login` writes.
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
