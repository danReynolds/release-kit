import '../../engine/checklist.dart';
import '../../engine/diagnostic.dart';
import '../../engine/publish_target.dart';
import '../../engine/pubspec.dart';
import '../../engine/resolve.dart';
import '../../engine/targets.dart';
import '../../engine/verdict.dart';
import '../../output/output.dart';
import '../../output/progress.dart';
import '../target_module.dart';
import 'package_stage.dart';
import 'session.dart';

final class PubDevTargetModule extends TargetModule {
  const PubDevTargetModule();

  @override
  PublishTarget get target => PublishTarget.pubDev;

  @override
  ProgressActivity get publishActivity => ProgressActivity(
        running: 'publishing',
        failed: 'publish failed',
      );

  @override
  TargetSessionProvider get authentication => const PubDevSession();

  @override
  TargetPlan plan({
    required ResolvedUnit unit,
    required Step step,
    String? repository,
  }) {
    final project = unit.projects.firstWhere(
      (project) => project.name == step.project,
    );
    return TargetPlan(
      label: 'pub.dev · ${project.name}',
      kindLabel: 'pub.dev',
      identity: project.name,
      planNote: '${project.name} ${project.version.canonical}',
      coordinate: project.name,
      targetVersion: project.version.canonical,
      step: step,
      project: project,
      permanenceNotice:
          'pub.dev never deletes a version. a version can be retracted, '
          'which hides it and removes nothing.',
      // pub publishes the staged source directory. There is no honest public
      // archive filename to invent for this row.
      artifacts: const [],
    );
  }

  @override
  Future<Inspection> inspectCandidate(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetPlan target,
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
        expectedArchiveSha256 =
            requirePubArchive(stage, target.project!).sha256;
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
  Future<TargetHistory> inspectHistory(
    TargetReadContext context,
    ResolvedUnit unit,
    TargetPlan target, {
    bool fresh = false,
  }) async {
    final reader = context.registry;
    if (reader == null) {
      return TargetHistory(
        inspection: const Inspection.unknown(
          'the registry reader is not configured',
        ),
      );
    }
    if (fresh) reader.forget(target.coordinate);
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
                    consequence: 'permanent: a package name cannot be '
                        'renamed, reassigned, or released back',
                  ),
                ]
              : const [],
        );
      }
      final publishedRepository = latest.repository;
      final localRepository = target.project!.pubspec.repository;
      final publishedIdentity = _repositoryIdentity(publishedRepository);
      final localIdentity = _repositoryIdentity(localRepository);
      if (publishedIdentity != null &&
          localIdentity != null &&
          publishedIdentity != localIdentity) {
        final inspection = Inspection.conflict(
          '${target.coordinate} points to another repository on pub.dev',
          evidence: {
            'published repository': publishedRepository!,
            'this repository': localRepository!,
          },
        );
        final project = target.project!;
        return TargetHistory(
          inspection: inspection,
          problems: [
            Diagnostic(
              code: 'RK-PUB-010',
              message: '${project.name} on pub.dev points to '
                  '$publishedRepository, not $localRepository',
              source: SourceLocation(
                project.pubspec.path,
                project.pubspec.nameLine,
              ),
              remedy: 'choose an unclaimed package name in pubspec.yaml; '
                  'pub.dev package names cannot be reclaimed by publishing '
                  'a newer version',
            ),
          ],
        );
      }
      final inspection = Inspection.exact(
        detail: 'latest published package is ${latest.version}',
        evidence: {'version': latest.version.canonical},
      );
      final project = target.project!;
      return TargetHistory.versioned(
        inspection: inspection,
        target: target,
        regressionDiagnostic: (publicVersion) => Diagnostic(
          code: 'RK-MONO-002',
          message: '${project.name} ${project.version} is behind published '
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
  String conflictRemedy(
    ResolvedUnit unit,
    TargetPlan target,
  ) =>
      'pub.dev versions are immutable. Bump the version and changelog, '
      'then stage the new release';

  @override
  Future<TargetReadinessOutcome> checkReadiness(
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
  String destinationBinding(
    TargetReadinessContext context,
    ResolvedUnit unit,
    List<TargetPlan> targets,
  ) {
    final endpoints = <String>[
      for (final target in targets)
        target.project!.pubspec
            .effectivePublishDestination(context.environment),
    ]..sort();
    return endpoints.join('\n');
  }

  @override
  Future<TargetActOutcome> publish(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetPlan target,
    Inspection inspected,
  ) async {
    final project = target.project!;
    final archive = requirePubArchive(context.stage, project);
    final sourceRoot = context.stage.sourceRoot;
    final directory = project.pubspec.directory == '.'
        ? sourceRoot
        : '$sourceRoot/${project.pubspec.directory}';
    // Publication is non-interactive after the explicit session preflight.
    // Capture pub's output so it cannot write through RK's live multi-target
    // progress surface; the transcript is retained if the act fails.
    final result = await context.tools.run(
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
    if (!result.ok) {
      if (result.exitCode == 64) {
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
        problem: result.summary,
        evidence: result.transcript,
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
  Future<Inspection> confirmPublication(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetPlan target,
  ) async {
    var waited = Duration.zero;
    while (true) {
      context.reads.registry?.forget(target.coordinate);
      final state = await inspectCandidate(context.reads, unit, target);
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
  Future<TargetFailure> classifyUnconfirmedPublication(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetPlan target,
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
        evidence: act.evidence ?? act.diagnostic?.evidence,
      ),
      halt: halt,
      nextCommand: code == 'RK-PUB-005' ? 'rk status ${unit.name}' : null,
    );
  }

  @override
  TargetStage stageInput({
    required ResolvedUnit unit,
    required TargetPlan target,
  }) =>
      pubDevPackageStage(target: target);
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
