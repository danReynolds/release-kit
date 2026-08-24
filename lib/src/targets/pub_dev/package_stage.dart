import 'dart:io';

import '../../engine/assets.dart';
import '../../engine/diagnostic.dart';
import '../../engine/file_mode.dart';
import '../../engine/release_stage.dart';
import '../../engine/resolve.dart';
import '../../engine/stage.dart';
import '../../engine/stage_contract.dart';
import '../../engine/stage_receipt.dart';
import '../../engine/targets.dart';
import '../../engine/tools.dart';
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
    planLabel: 'package archive',
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
    warnings: validation.warnings,
  );
}

Future<({Diagnostic? diagnostic, List<Diagnostic> warnings})> _packageArchive(
  TargetStageContext context,
  ResolvedProject project,
) async {
  final sourceRoot = context.stage.sourceRoot;
  final sourceDirectory = project.pubspec.directory == '.'
      ? sourceRoot
      : '$sourceRoot/${project.pubspec.directory}';

  // Pub honours dependency overrides at the resolution root and strips them
  // from the published archive. Refusing is the honest consumer check: native
  // validation otherwise succeeds against a graph consumers never receive.
  final masking = _maskedResolution(sourceRoot, sourceDirectory);
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
      warnings: const <Diagnostic>[],
    );
  }

  final archivePath = ReleaseAssets.pubArchivePath(project);
  final archive = File(context.workspace.pathOf(archivePath));
  archive.parent.createSync(recursive: true);
  final mirror = _mirrorSourceSnapshot(context);
  late final ToolResult packaged;
  try {
    final mirroredSource = _join(mirror.path, const ['source']);
    final directory = project.pubspec.directory == '.'
        ? mirroredSource
        : _join(
            mirroredSource,
            StagePath.segments(project.pubspec.directory),
          );
    packaged = await context.tools.run(
      'dart',
      ['pub', 'publish', '--to-archive', archive.path],
      workingDirectory: directory,
    );
  } finally {
    mirror.deleteSync(recursive: true);
  }
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
        warnings: const <Diagnostic>[],
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
          remedy: 'fix the validation errors reported by Pub, then stage '
              '${project.name} again',
          evidence: validation.isEmpty ? packaged.summary : validation,
        ),
        warnings: const <Diagnostic>[],
      );
    }
    final details = <String>[
      for (final line in validation.split('\n'))
        if (line.trimLeft().startsWith('*'))
          line.trim().replaceFirst(RegExp(r'^\*\s*'), ''),
    ];
    if (details.isEmpty) details.add('Pub reported package warnings');
    return (
      diagnostic: null,
      warnings: [
        for (final detail in details)
          Diagnostic(
            code: 'RK-PUB-012',
            message: 'pub validation for ${project.name}: $detail',
            remedy: 'fix or consciously accept this warning before release; '
                'rk publishes past it only after explicit authorization',
          ),
      ],
    );
  }

  if (!archive.existsSync()) {
    return (
      diagnostic: Diagnostic(
        code: 'RK-PUB-011',
        message: 'Pub reported success without producing $archivePath',
        remedy: 'upgrade or repair the Dart SDK and re-run; rk publishes '
            'only the exact native archive recorded in its stage',
      ),
      warnings: const <Diagnostic>[],
    );
  }

  return (diagnostic: null, warnings: const <Diagnostic>[]);
}

/// Copies the recorded snapshot outside the repository before invoking Pub.
///
/// Release stages deliberately live under `.rk/`, which repositories normally
/// ignore. Pub walks ancestor Git ignore rules when it builds a package; run
/// directly in the stage, that makes the whole package look ignored and can
/// produce an empty archive. The mirror contains only receipt-bound source
/// files, retains their modes and the workspace layout, and is deleted after
/// the native archive command finishes.
Directory _mirrorSourceSnapshot(TargetStageContext context) {
  final mirror = Directory.systemTemp.createTempSync('rk-pub-source-');
  try {
    if (_isWithin(
      mirror.path,
      context.stage.directory.repositoryRoot,
    )) {
      throw StateError(
        'the system temporary directory is inside the release repository',
      );
    }

    final modes = <String, String>{};
    for (final artifact in context.sourceStep.outputs) {
      final parts = StagePath.segments(artifact.path);
      if (artifact.type != 'source' ||
          parts.length < 2 ||
          parts.first != 'source') {
        throw StateError(
          'the source snapshot contains a non-source artifact: '
          '${artifact.path}',
        );
      }
      final destination = File(_join(mirror.path, parts));
      destination.parent.createSync(recursive: true);
      File(context.stage.directory.resolve(artifact.path))
          .copySync(destination.path);
      modes[destination.path] = artifact.mode;
    }
    setFileModes(modes);
    return mirror;
  } on Object {
    if (mirror.existsSync()) mirror.deleteSync(recursive: true);
    rethrow;
  }
}

bool _isWithin(String path, String root) {
  final absolutePath = Directory(path).absolute.path;
  final absoluteRoot = Directory(root).absolute.path;
  return absolutePath == absoluteRoot ||
      absolutePath.startsWith('$absoluteRoot${Platform.pathSeparator}');
}

String _join(String root, Iterable<String> parts) =>
    [root, ...parts].join(Platform.pathSeparator);

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
