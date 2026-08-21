import 'dart:io';

import '../../engine/assets.dart';
import '../../engine/diagnostic.dart';
import '../../engine/release_stage.dart';
import '../../engine/resolve.dart';
import '../../engine/stage_contract.dart';
import '../../engine/stage_receipt.dart';
import '../../engine/targets.dart';
import '../../engine/yaml.dart';
import '../../output/progress.dart';
import '../target_module.dart';

/// Pub's native package archive contribution to the reusable release stage.
///
/// Packaging, override detection, diagnostics, and the receipt contract stay
/// together because they describe one private input to the pub.dev lifecycle.
TargetStage pubDevPackageStage({required TargetPlan target}) {
  final archivePath = ReleaseAssets.pubArchivePath(target.project!);
  final contract = StageContributionContract(
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

/// The one native Pub archive frozen in a completed stage.
StageArtifact requirePubArchive(
  ReleaseStage stage,
  ResolvedProject project,
) {
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

  // Pub honours dependency overrides at the resolution root and strips them
  // from the published archive. Refusing is the honest consumer check: native
  // validation otherwise succeeds against a graph consumers never receive.
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
  context.attach('pub-package-${project.name}.txt', validation);

  if (!packaged.ok) {
    final lower = validation.toLowerCase();
    if (lower.contains('to-archive') &&
        (lower.contains('could not find') ||
            lower.contains('unknown option') ||
            lower.contains('unrecognized option'))) {
      return (
        diagnostic: const Diagnostic(
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
      if (line.trimLeft().startsWith('*')) notices.add(line.trim());
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

/// What masks resolution for the staged package, or null when nothing does.
String? _maskedResolution(String sourceRoot, String directory) {
  String describe(String path) {
    final prefix = '$sourceRoot/';
    return path.startsWith(prefix) ? path.substring(prefix.length) : path;
  }

  for (final root in {directory, _resolutionRoot(sourceRoot, directory)}) {
    final overrides = '$root/pubspec_overrides.yaml';
    if (File(overrides).existsSync()) return describe(overrides);
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
    if (_pubspecMap('$dir/pubspec.yaml')?.has('workspace') == true) return dir;
  }
  return directory;
}

YamlMap? _pubspecMap(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  return parseYaml(file.readAsStringSync(), path, Diagnostics());
}
