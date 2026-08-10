import 'dart:io';

import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/registry.dart';
import '../engine/resolve.dart';
import '../engine/source_tree.dart';
import '../engine/stage_contract.dart';
import '../engine/stage_inspection.dart';
import '../engine/stage_receipt.dart';
import '../engine/targets.dart';
import '../engine/verdict.dart';
import '../engine/version.dart';
import '../output/output.dart';
import 'target_module.dart';

final class PubDevTargetModule extends TargetModule {
  const PubDevTargetModule();

  @override
  StepKind get stepKind => StepKind.publishRegistry;

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
      return Future.value(const Inspection.unknown('not read: --offline'));
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
    return exact.inspectProject(
      target.project!,
      expectedSource:
          stage == null ? null : SnapshotSourceTree(stage.sourceRoot),
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
      return const Inspection.unknown('not read: --offline');
    }
    try {
      final package = await reader.lookup(target.coordinate);
      final latest = package?.latest;
      return latest == null
          ? const Inspection.absent(detail: 'no published package version')
          : Inspection.exact(
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
      message: '${project.name} $publicVersion is already published, and this '
          'would publish ${project.version}',
      source: SourceLocation(
        project.pubspec.path,
        project.pubspec.versionLine,
      ),
      remedy: 'a release moves forward — bump past $publicVersion',
    );
  }

  @override
  bool ownsDiagnostic(
    Diagnostic diagnostic,
    TargetExpectation target,
  ) =>
      diagnostic.code == 'RK-MONO-002' &&
      diagnostic.source?.path == target.project?.pubspec.path;

  @override
  String conflictRemedy(
    ResolvedUnit unit,
    TargetExpectation target,
  ) =>
      'pub.dev versions are immutable. Bump the version and changelog, '
      'then stage the new release';

  @override
  Future<bool> preflight(
    TargetPreflightContext context,
    ResolvedUnit unit,
  ) async {
    int code;
    try {
      code = await context.tools.runInteractive(
        'dart',
        const ['pub', 'login'],
        workingDirectory: context.git.root,
      );
    } on ProcessException {
      code = -1;
    }
    if (code == 0) return true;

    context.output.problem(
      Diagnostic(
        code: 'RK-PUB-007',
        message: 'dart pub login did not complete',
        remedy: 'Run dart pub login from a terminal, then re-run rk release '
            '${unit.name}. A successful login confirms a current session, '
            'not permission to publish every package.',
      ),
      unit: unit.name,
    );
    context.output.halt(HaltKind.beforeActing);
    return false;
  }

  @override
  Future<TargetActOutcome> act(
    TargetReleaseContext context,
    ResolvedUnit unit,
    TargetExpectation target,
    Inspection inspected,
  ) async {
    final project = target.project!;
    final sourceRoot = context.stage.sourceRoot;
    final directory = project.pubspec.directory == '.'
        ? sourceRoot
        : '$sourceRoot/${project.pubspec.directory}';
    final code = await context.tools.runInteractive(
      'dart',
      const ['pub', 'publish', '--force'],
      workingDirectory: directory,
    );
    context.reads.registry!.forget(project.name);
    if (code != 0) {
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
        reconciledNote:
            'publish response was lost · public archive confirmed exact',
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
    final contract = StageContributionContract(
      phase: StageContributionPhase.beforeArtifacts,
      step: StageStepContract(
        'pub-preflight:${target.project!.name}',
        inputs: const {'step:source-snapshot'},
        validate: (_, step) {
          const expected = {
            'publish_dry_run': 'passed',
            'consumer_resolve': 'passed',
          };
          final evidence = step.evidence;
          final exact = evidence.length == expected.length &&
              expected.entries.every(
                (entry) => evidence[entry.key] == entry.value,
              );
          return exact
              ? const []
              : [
                  StageIssue(
                    StageIssueKind.invalidStructure,
                    '${step.name} does not prove both package preflights',
                    path: 'stage.json',
                  ),
                ];
        },
      ),
    );
    return TargetStage(
      target: target,
      contract: contract,
      prepare: (context) => _prepareStage(context, target.project!),
    );
  }

  Future<StageStep?> _prepareStage(
    TargetStageContext context,
    ResolvedProject project,
  ) async {
    final receiptName = context.contract.step.name;
    if (!await _publishPreflight(context, project)) {
      return null;
    }
    return StageStep(
      name: receiptName,
      inputs: [StageInput.step(context.sourceStep)],
      evidence: const {
        'publish_dry_run': 'passed',
        'consumer_resolve': 'passed',
      },
    );
  }

  Future<bool> _publishPreflight(
    TargetStageContext context,
    ResolvedProject project,
  ) async {
    final sourceRoot = context.stage.sourceRoot;
    final directory = project.pubspec.directory == '.'
        ? sourceRoot
        : '$sourceRoot/${project.pubspec.directory}';
    final dry = await context.tools.run(
      'dart',
      const ['pub', 'publish', '--dry-run'],
      workingDirectory: directory,
    );
    final validation = '${dry.stdout}\n${dry.stderr}'.trim();
    context.output.report.attach(
      'pub-dry-run-${project.name}.txt',
      validation,
    );

    if (!dry.ok) {
      final summary = RegExp(r'Package has[^\n]*')
          .allMatches(validation)
          .map((match) => match.group(0)!)
          .lastOrNull;
      final warningsOnly = summary != null &&
          !summary.toLowerCase().contains('error') &&
          summary.toLowerCase().contains('warning');
      if (!warningsOnly) {
        context.output.problem(
          Diagnostic(
            code: 'RK-PUB-001',
            message: 'pub refuses to publish ${project.name}',
            remedy: validation.isEmpty ? dry.summary : validation,
          ),
          unit: project.unitName,
        );
        context.output.halt(HaltKind.beforeActing);
        return false;
      }
      context.output.say(
        'pub warns, and --force will publish past these:',
        depth: 1,
      );
      for (final line in validation.split('\n')) {
        if (line.trimLeft().startsWith('*')) {
          context.output.say(line.trim(), depth: 2);
        }
      }
    }

    return _consumerResolve(context, project, directory);
  }

  Future<bool> _consumerResolve(
    TargetStageContext context,
    ResolvedProject project,
    String directory,
  ) async {
    final probe = Directory.systemTemp.createTempSync('rk-consumer-');
    try {
      File('${probe.path}/pubspec.yaml').writeAsStringSync('''
name: rk_consumer_probe
publish_to: none
environment:
  sdk: '>=3.0.0 <4.0.0'
dependencies:
  ${project.name}: ${project.version}
dependency_overrides:
  ${project.name}:
    path: ${directory.replaceAll('\\', '/')}
''');
      final resolved = await context.tools.run(
        'dart',
        const ['pub', 'get', '--no-precompile'],
        workingDirectory: probe.path,
      );
      if (!resolved.ok) {
        context.output.problem(
          Diagnostic(
            code: 'RK-PUB-002',
            message: '${project.name}: consumers could not resolve this',
            remedy: '${resolved.summary}\n'
                'the probe resolves as a Dart consumer on this SDK; a '
                'package needing Flutter or a newer SDK than the probe '
                'models is a limit rk has not lifted yet — see the ledger',
          ),
          unit: project.unitName,
        );
        context.output.halt(HaltKind.beforeActing);
        return false;
      }
      return true;
    } finally {
      probe.deleteSync(recursive: true);
    }
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
