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
import '../../output/progress.dart';
import '../target_module.dart';
import 'resolution.dart';

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
    progress: [TargetStageProgress.row(id: 'source', label: 'package archive')],
    prepare: (context) => _prepareStage(context, target.project!),
  );
}

/// The one native Pub archive frozen in a completed stage.
StageArtifact requirePubArchive(ReleaseStage stage, ResolvedProject project) {
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
    return TargetStageFailure(diagnostic, unit: project.unitName);
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

  // Pub resolves a workspace member together with every package of its
  // workspace and applies any of their overrides to all of them, so the
  // whole workspace is read, or the stage refused when rk cannot read it.
  final resolution = resolutionPackages(sourceRoot, sourceDirectory);
  final packages = resolution.packages;
  if (packages == null) {
    return (
      diagnostic: Diagnostic(
        code: 'RK-PUB-015',
        message:
            '${project.name}: rk cannot read the workspace it resolves with',
        remedy:
            '${resolution.unreadable}. Any package of a workspace can '
            'override what ${project.name} is validated against, so rk reads '
            'them all, and stages nothing it cannot read. Write the workspace '
            'in the YAML and member patterns rk reads, then re-stage.',
      ),
      warnings: const <Diagnostic>[],
    );
  }

  // A Flutter package, or any package resolved with one in its workspace,
  // needs a Flutter SDK's Dart, whose pub finds its own Flutter. The Dart rk
  // identified for this stage is the one that packages and publishes; a
  // standalone one would depend on an ambient FLUTTER_ROOT the stage does
  // not record.
  if (needsFlutter(packages.values)) {
    final dart = context.stage.compiler?.executable;
    if (dart != null && !dartInFlutterSdk(dart)) {
      return (
        diagnostic: Diagnostic(
          code: 'RK-PUB-014',
          message:
              '${project.name} resolves with Flutter packages, and the '
              'Dart rk uses is not part of a Flutter SDK',
          remedy:
              '$dart is a standalone Dart SDK. rk stages Flutter packages '
              'with a Flutter SDK\'s Dart, which the stage records. Put your '
              'Flutter SDK\'s bin directory first on PATH so rk uses its '
              'dart, then re-stage.',
        ),
        warnings: const <Diagnostic>[],
      );
    }
  }

  // Pub honours dependency overrides where it resolves and strips them from
  // the published archive. An override that reaches this package's
  // dependencies masks what its consumers resolve, so it refuses; one that
  // reaches only other packages in the workspace does not.
  final declared = dependencyOverrides(sourceRoot, packages);

  final archivePath = ReleaseAssets.pubArchivePath(project);
  final archive = File(context.workspace.pathOf(archivePath));
  archive.parent.createSync(recursive: true);
  final mirror = _mirrorSourceSnapshot(context);
  late final ToolResult packaged;
  try {
    final mirroredSource = _join(mirror.path, const ['source']);
    final directory = project.pubspec.directory == '.'
        ? mirroredSource
        : _join(mirroredSource, StagePath.segments(project.pubspec.directory));
    if (declared.overrides.isNotEmpty || packages.length > 1) {
      // Resolved where Pub will validate the archive, from the same snapshot.
      final deps = await context.tools.run('dart', const [
        'pub',
        'deps',
        '--json',
      ], workingDirectory: directory);
      final graph = deps.ok ? deps.stdout : null;
      final reached = graph == null
          ? null
          : runtimeDependencies(graph, project.name);
      final reported = graph == null ? null : reportedOverrides(graph);
      final unhosted = reached == null
          ? null
          : unhostedDependencies(graph!, reached);
      final String? unknown = !deps.ok
          ? 'dart pub deps failed: ${_firstLine(deps.stderr)}'
          : reached == null || reported == null || unhosted == null
          ? 'dart pub deps did not print a dependency graph rk reads'
          : !_sameNames(reported.keys, packages.keys)
          ? _differentPackages(reported.keys, packages.keys)
          : null;
      if (unknown != null) {
        return (
          diagnostic: _unresolvedDiagnostic(
            project.name,
            unknown,
            declared.overrides,
          ),
          warnings: const <Diagnostic>[],
        );
      }
      // What Pub reports declaring checks rk's reading, except where a
      // package's overrides file replaces the section Pub still reports.
      final all = [...declared.overrides];
      for (final MapEntry(key: member, value: names) in reported!.entries) {
        if (declared.replaced.contains(member)) continue;
        for (final name in names) {
          if (all.any((o) => o.package == name)) continue;
          all.add((
            package: name,
            declaredIn: 'an override Pub reports $member declaring',
          ));
        }
      }
      // Declared overrides are named where they are declared; a reached
      // package from a path or Git source is refused whatever declared it,
      // which catches a declaration rk could not see.
      final masking = maskingOverrides(all, project.name, reached);
      if (masking.isNotEmpty) {
        return (
          diagnostic: _maskingDiagnostic(project.name, masking),
          warnings: const <Diagnostic>[],
        );
      }
      if (unhosted!.isNotEmpty) {
        return (
          diagnostic: _unhostedDiagnostic(project.name, unhosted),
          warnings: const <Diagnostic>[],
        );
      }
      if (all.isNotEmpty) {
        context.attach(
          'pub-overrides-${project.name}.txt',
          'Dependency overrides that do not reach ${project.name}\'s '
              'dependencies, so its consumers resolve what Pub validated:\n'
              '${[for (final o in all) '  ${o.package} (${o.declaredIn})'].join('\n')}\n',
        );
      }
    }
    packaged = await context.tools.run('dart', [
      'pub',
      'publish',
      '--to-archive',
      archive.path,
    ], workingDirectory: directory);
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
          remedy:
              'upgrade Dart to an SDK whose pub publish command '
              'supports native archive staging, then re-run. rk does not '
              'reimplement Pub packaging or publish different bytes from '
              'the ones it staged.',
        ),
        warnings: const <Diagnostic>[],
      );
    }
    final summary = RegExp(
      r'Package has[^\n]*',
    ).allMatches(validation).map((match) => match.group(0)!).lastOrNull;
    final warningsOnly =
        summary != null &&
        !summary.toLowerCase().contains('error') &&
        summary.toLowerCase().contains('warning');
    if (!warningsOnly || !archive.existsSync()) {
      return (
        diagnostic: Diagnostic(
          code: 'RK-PUB-001',
          message: 'pub refuses to publish ${project.name}',
          remedy:
              'fix the validation errors reported by Pub, then stage '
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
            remedy:
                'fix or consciously accept this warning before release; '
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
        remedy:
            'upgrade or repair the Dart SDK and re-run; rk publishes '
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
    final gitControl = _gitControlAncestor(mirror.path);
    if (gitControl != null) {
      throw StateError(
        'the system temporary directory is inside a Git worktree: '
        '$gitControl',
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
      File(
        context.stage.directory.resolve(artifact.path),
      ).copySync(destination.path);
      modes[destination.path] = artifact.mode;
    }
    setFileModes(modes);
    return mirror;
  } on Object {
    if (mirror.existsSync()) mirror.deleteSync(recursive: true);
    rethrow;
  }
}

String? _gitControlAncestor(String path) {
  var current = Directory(Directory(path).resolveSymbolicLinksSync());
  while (true) {
    final marker = _join(current.path, const ['.git']);
    if (FileSystemEntity.typeSync(marker, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return marker;
    }
    final parent = current.parent;
    if (parent.path == current.path) return null;
    current = parent;
  }
}

String _join(String root, Iterable<String> parts) =>
    [root, ...parts].join(Platform.pathSeparator);

Diagnostic _maskingDiagnostic(
  String package,
  List<DependencyOverride> masking,
) {
  final where = {for (final o in masking) o.declaredIn}.join(' and ');
  final named = {
    for (final o in masking)
      if (o.package != everyPackage) o.package,
  };
  final String remedy;
  if (named.isEmpty) {
    remedy =
        '$where is honoured locally, stripped from the published archive, '
        'and overrides packages rk cannot name. Remove it and re-stage.';
  } else if (named.length == 1 && named.single == package) {
    remedy =
        '$where overrides $package itself. Pub honours that locally and '
        'strips it from the published archive, so validation here would not '
        'see what consumers see. Remove the override and re-stage.';
  } else {
    final reached = named.where((name) => name != package).toList();
    final them = reached.length == 1 ? 'it' : 'them';
    remedy =
        '$package depends on ${reached.join(', ')}, overridden by $where. '
        'Pub honours that locally and strips it from the published archive, '
        'so validation here would not see what consumers see. Publish or '
        'pin $them, remove the override, and re-stage.';
  }
  return Diagnostic(
    code: 'RK-PUB-008',
    message: '$package: tracked dependency overrides mask consumer resolution',
    remedy: remedy,
  );
}

Diagnostic _unhostedDiagnostic(String package, Map<String, String> unhosted) {
  final names = [
    for (final MapEntry(key: name, value: source) in unhosted.entries)
      '$name (from $source)',
  ];
  return Diagnostic(
    code: 'RK-PUB-008',
    message: '$package: tracked dependency overrides mask consumer resolution',
    remedy:
        '$package depends on ${names.join(', ')}, which consumers cannot '
        'receive: they resolve every dependency from pub.dev or the SDK. An '
        'override or dependency somewhere in the workspace points '
        '${unhosted.length == 1 ? 'it' : 'them'} elsewhere, so validation '
        'here would not see what consumers see. Publish the package, remove '
        'what points at the ${unhosted.length == 1 ? 'copy' : 'copies'}, and '
        're-stage.',
  );
}

Diagnostic _unresolvedDiagnostic(
  String package,
  String why,
  List<DependencyOverride> declared,
) {
  final overrides = {for (final o in declared) o.declaredIn};
  return Diagnostic(
    code: 'RK-PUB-016',
    message: 'rk could not resolve which packages $package reaches',
    remedy:
        '$why. rk resolves the staged snapshot to see which dependency '
        'overrides reach $package'
        '${overrides.isEmpty ? '' : ' (declared in ${overrides.join(' and ')})'}'
        ', and without that it cannot tell whether validation here matches '
        'what consumers resolve. Fix the resolution, then re-stage.',
  );
}

String _firstLine(String text) {
  final line = text.trim().split('\n').first.trim();
  return line.isEmpty ? 'no output' : line;
}

String _differentPackages(Iterable<String> pub, Iterable<String> rk) {
  final onlyPub = pub.toSet().difference(rk.toSet()).toList()..sort();
  final onlyRk = rk.toSet().difference(pub.toSet()).toList()..sort();
  return [
    if (onlyPub.isNotEmpty)
      'Pub resolved ${onlyPub.join(', ')}, which rk did not read',
    if (onlyRk.isNotEmpty)
      'rk read ${onlyRk.join(', ')}, which Pub did not resolve',
  ].join('; ');
}

bool _sameNames(Iterable<String> a, Iterable<String> b) {
  final left = a.toSet();
  final right = b.toSet();
  return left.length == right.length && left.containsAll(right);
}
