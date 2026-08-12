import 'dart:io';

import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/publish_target.dart';
import '../engine/pubspec.dart';
import '../engine/registry.dart';
import '../engine/resolve.dart';
import '../engine/source_tree.dart';
import '../engine/stage_contract.dart';
import '../engine/stage_inspection.dart';
import '../engine/stage_receipt.dart';
import '../engine/targets.dart';
import '../engine/verdict.dart';
import '../engine/yaml.dart';
import '../engine/version.dart';
import '../output/output.dart';
import 'target_module.dart';

final class PubDevTargetModule extends TargetModule {
  const PubDevTargetModule();

  @override
  PublishTarget get target => PublishTarget.pubDev;

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
      kindLabel: 'pub.dev',
      identity: project.name,
      coordinate: project.name,
      targetVersion: project.version.canonical,
      step: step,
      project: project,
      // pub publishes the staged source directory. There is no honest public
      // archive filename to invent for this row.
      artifacts: const [],
      // Git-bound status can compare the immutable commit immediately.
      // Unbound status deliberately returns unknown until this invocation has
      // captured the exact source snapshot, so release may stage then decide.
      exactComparisonNeedsStage: true,
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
      return const Inspection.unknown('the registry reader is not configured');
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
    TargetReadinessContext context,
    ResolvedUnit unit,
  ) async {
    final redirected = unit.projects
        .where((project) => project.publish.contains(PublishTarget.pubDev))
        .any((project) => !isPubDevDestination(
              project.pubspec.effectivePublishDestination(context.environment),
            ));
    if (!redirected) return true;
    context.output.problem(
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
    context.output.halt(HaltKind.beforeActing);
    return false;
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
  Future<TargetSession?> acquireSession(
    TargetReadinessContext context,
    ResolvedUnit unit,
    List<TargetExpectation> targets,
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
    if (code == 0) {
      return TargetSession(
        endpoint: effectiveEndpoint(context, unit, targets),
      );
    }

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
    return null;
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
          const expected = {'publish_dry_run': 'passed'};
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
                    '${step.name} does not prove the publish dry run',
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
      evidence: const {'publish_dry_run': 'passed'},
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

    // pub honours dependency overrides — the pubspec_overrides.yaml file
    // and the dependency_overrides: section of pubspec.yaml — at the
    // resolution root, and strips both from the published archive. A
    // tracked override therefore makes every local validation pass against
    // a dependency graph consumers never get; the dry run even exits 0
    // with only a hint. Refusing is the honest check; simulating a
    // consumer was not.
    final masking = _maskedResolution(sourceRoot, directory);
    if (masking != null) {
      context.output.problem(
        Diagnostic(
          code: 'RK-PUB-008',
          message: '${project.name}: tracked dependency overrides '
              'mask consumer resolution',
          remedy: '$masking is honoured locally and stripped from the '
              'published archive, so validation here would not see what '
              'consumers see. Remove it and re-stage.',
        ),
        unit: project.unitName,
      );
      context.output.halt(HaltKind.beforeActing);
      return false;
    }

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

    return true;
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
