import 'dart:io';

import '../../engine/assets.dart';
import '../../engine/diagnostic.dart';
import '../../engine/file_mode.dart';
import '../../engine/release_stage.dart';
import '../../engine/resolve.dart';
import '../../engine/stage.dart';
import '../../engine/stage_contract.dart';
import '../../engine/stage_inspection.dart';
import '../../engine/stage_receipt.dart';
import '../../engine/targets.dart';
import '../../engine/tools.dart';
import '../../native/dart/package_archive.dart';
import '../../native/dart/stage_context.dart';
import '../../native/dart/stage_preparation.dart';
import '../../native/package_archive.dart';
import '../../output/progress.dart';
import '../target_module.dart';
import 'resolution.dart';

/// Pub's native package archive contribution to the reusable release stage.
///
/// Packaging, override detection, diagnostics, and the receipt contract stay
/// together because they describe one private input to the pub.dev lifecycle.
TargetStage pubDevPackageStage({
  required TargetPlan target,
  required ResolvedUnit unit,
}) {
  final archivePath = ReleaseAssets.pubArchivePath(target.project!);
  final contract = StageContributionContract(
    step: StageStepContract(
      'pub-archive:${target.project!.name}',
      inputs: const {'step:source-snapshot'},
      outputs: {archivePath: 'pub-archive'},
      validateEvidence: (context, step) =>
          step.evidence['package_archive'] == 'staged'
          ? const []
          : [
              StageIssue(
                StageIssueKind.invalidStructure,
                '${step.name} has no staged native package evidence',
                path: 'stage.json',
              ),
            ],
    ),
  );
  return TargetStage(
    target: target,
    contract: contract,
    planLabel: 'package archive',
    progress: [TargetStageProgress.row(id: 'source', label: 'package archive')],
    prepare: (context) => _prepareStage(context, target.project!, {
      for (final project in unit.projects) project.name,
    }),
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
  Set<String> releasedWith,
) async {
  final receiptName = context.contract.step.name;
  context.progress('source').begin(CommonProgressActivities.validating);
  Map<String, Object?>? nativeResolution;
  final validation = await _packageArchive(
    context,
    project,
    releasedWith,
    onResolution: (graph) => nativeResolution = graph,
  );
  if (validation.diagnostic case final diagnostic?) {
    return TargetStageFailure(diagnostic, unit: project.unitName);
  }
  return TargetStageSuccess(
    StageStep(
      name: receiptName,
      inputs: context.stage.enforceUnitContract
          ? context.stage.producerInputs(receiptName, context.priorSteps)
          : [StageInput.step(context.sourceStep)],
      outputs: [
        StageArtifact.capture(
          stage: context.stage.directory,
          path: ReleaseAssets.pubArchivePath(project),
          type: 'pub-archive',
        ),
      ],
      evidence: {
        'package_archive': 'staged',
        if (nativeResolution != null) 'native_resolution': nativeResolution,
      },
    ),
    warnings: validation.warnings,
  );
}

/// Stages [project]'s Pub archive. [releasedWith] names the packages its
/// unit releases, itself included.
Future<({Diagnostic? diagnostic, List<Diagnostic> warnings})> _packageArchive(
  TargetStageContext context,
  ResolvedProject project,
  Set<String> releasedWith, {
  required void Function(Map<String, Object?> graph) onResolution,
}) async {
  final sourceRoot = context.stage.sourceRoot;
  final sourceDirectory = project.pubspec.directory == '.'
      ? sourceRoot
      : '$sourceRoot/${project.pubspec.directory}';

  // What rk reads of the workspace names where overrides are declared and
  // finds Flutter packages early. It does not decide what is overridden: Pub
  // does, below, from the snapshot it validates.
  final packages = resolutionPackages(sourceRoot, sourceDirectory).packages;

  // A Flutter package, or any package resolved with one in its workspace,
  // needs a Flutter SDK's Dart, whose pub finds its own Flutter. The Dart rk
  // identified for this stage is the one that packages and publishes; a
  // standalone one would depend on an ambient FLUTTER_ROOT the stage does
  // not record.
  if (packages != null && needsFlutter(packages.values)) {
    final dart = context.stage.compiler?.executable;
    if (dart != null && !dartInFlutterSdk(dart)) {
      return (
        diagnostic: _flutterDiagnostic(project.name, dart),
        warnings: const <Diagnostic>[],
      );
    }
  }
  final declared = packages == null
      ? const <DependencyOverride>[]
      : dependencyOverrides(sourceRoot, packages);

  final archivePath = ReleaseAssets.pubArchivePath(project);
  final archive = File(context.workspace.pathOf(archivePath));
  archive.parent.createSync(recursive: true);
  final frozen = DartStagePreparation.contextFor(
    context.stage,
    project,
    DartStageOperation.pubArchive,
    context.contract.step.name,
  );
  Directory? workspace;
  Directory? consumer;
  DartStagePreparation? native;
  late final ToolResult packaged;
  late final String resolvedAs;
  try {
    if (frozen != null) {
      native = await DartStagePreparation.open(
        stage: context.stage,
        project: project,
        context: frozen,
        producer: context.contract.step.name,
        tools: context.tools,
      );
      packaged = await native.replay.run([
        'pub',
        'publish',
        '--to-archive',
        archive.path,
      ]);
      if (archive.existsSync()) {
        DartPackageManifest.fromArchive(
          await NativePackageArchive.read(archive),
        ).requireSameManifest(frozen.root);
      }
      onResolution(native.replay.graph.toJson());
      resolvedAs =
          'Pub validated ${project.name} using the exact receipt-bound '
          'dependency archives, with original requirements and registry identities.';
    } else {
      workspace = _mirrorSourceSnapshot(context);
      // Records left in the snapshot are not Pub's answer for it, and a
      // lockfile holds versions its consumers do not get.
      _removePubRecords(_join(workspace.path, const ['source']));
      final checked = await _checkWorkspace(
        context,
        project,
        _packageDirectory(workspace, project),
        declared,
        releasedWith,
      );
      if (checked.diagnostic case final diagnostic?) {
        return (diagnostic: diagnostic, warnings: const <Diagnostic>[]);
      }

      // Pub validates against the versions it resolves, so it resolves the
      // package the way its consumers do, in a second mirror: as a root of its
      // own, from its own pubspec, with no lockfile and no dependency override
      // but the workspace packages its consumers cannot take from pub.dev yet
      // (see [snapshotPackages]). The rest of the workspace constrains only
      // local resolutions. Pub leaves overrides files out of archives, so the
      // one written here does not change what is published.
      consumer = _mirrorSourceSnapshot(context);
      final directory = _packageDirectory(consumer, project);
      _removePubRecords(_join(consumer.path, const ['source']));
      File(
        _join(directory, const ['pubspec_overrides.yaml']),
      ).writeAsStringSync(
        consumerOverrides(
          checked.fromSnapshot,
          inWorkspace: checked.inWorkspace,
        ),
      );
      final get = await context.tools.run(
        'dart',
        const ['pub', 'get', '--no-example'],
        workingDirectory: directory,
        environment: const {'PUB_SUMMARY_ONLY': '0'},
      );
      final report = '${get.stdout}\n${get.stderr}'.trim();
      final unexpected = reportedOverrides(
        report,
      ).difference(checked.fromSnapshot.keys.toSet());
      if (!get.ok || unexpected.isNotEmpty) {
        return (
          diagnostic: _consumerDiagnostic(
            project.name,
            !get.ok
                ? 'dart pub get failed: ${_firstLine(get.stderr)}'
                : 'Pub applied overrides rk did not write: '
                      '${unexpected.join(', ')}',
            report,
          ),
          warnings: const <Diagnostic>[],
        );
      }
      final names = checked.fromSnapshot.keys.toList()..sort();
      final taken = names.isEmpty
          ? ''
          : ' but ${names.join(', ')} from this snapshot, in the '
                'pubspec_overrides.yaml rk wrote';
      resolvedAs =
          'Pub validated ${project.name} the way its consumers resolve it: as '
          'a root of its own, with no lockfile and no dependency override'
          '$taken.';
      packaged = await context.tools.run('dart', [
        'pub',
        'publish',
        '--to-archive',
        archive.path,
      ], workingDirectory: directory);
    }
  } finally {
    native?.close();
    workspace?.deleteSync(recursive: true);
    consumer?.deleteSync(recursive: true);
  }
  final validation = '${packaged.stdout}\n${packaged.stderr}'.trim();
  context.attach(
    'pub-package-${project.name}.txt',
    '$resolvedAs\n\n$validation',
  );
  final findings = _validationFindings(validation);

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
  }
  // Pub refuses an archive with errors. With warnings alone, current Pub
  // writes the archive and exits 0; earlier Pub exited non-zero and said
  // so in a summary.
  final summary = RegExp(
    r'Package has[^\n]*',
  ).allMatches(validation).map((match) => match.group(0)!).lastOrNull;
  final refused =
      findings.errors.isNotEmpty ||
      (!packaged.ok &&
          (summary == null ||
              summary.toLowerCase().contains('error') ||
              !summary.toLowerCase().contains('warning')));
  if (refused || (!packaged.ok && !archive.existsSync())) {
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

  final warnings = [
    ...findings.warnings,
    if (findings.warnings.isEmpty && !packaged.ok)
      'Pub reported package warnings',
  ];
  return (
    diagnostic: null,
    warnings: [
      for (final warning in warnings)
        Diagnostic(
          code: 'RK-PUB-012',
          message: 'pub validation for ${project.name}: ${_headline(warning)}',
          remedy:
              'fix or consciously accept this warning before release; '
              'rk publishes past it only after explicit authorization',
          evidence: warning.contains('\n') ? warning : null,
        ),
    ],
  );
}

/// What resolving the workspace's mirror decides: a refusal, or the
/// workspace packages the consumer resolution takes from the snapshot, by
/// name with their paths relative to the staged package, and whether that
/// package is part of a workspace at all.
typedef _WorkspaceCheck = ({
  Diagnostic? diagnostic,
  Map<String, String> fromSnapshot,
  bool inWorkspace,
});

/// Resolves the workspace at [directory], the staged package's directory in
/// a mirror of the snapshot, and refuses what reaches the package's
/// consumers from it: overrides, and packages from a path or Git.
Future<_WorkspaceCheck> _checkWorkspace(
  TargetStageContext context,
  ResolvedProject project,
  String directory,
  List<DependencyOverride> declared,
  Set<String> releasedWith,
) async {
  _WorkspaceCheck refuse(Diagnostic diagnostic) =>
      (diagnostic: diagnostic, fromSnapshot: const {}, inWorkspace: false);

  // Pub honours dependency overrides where it resolves and strips them
  // from the published archive, so Pub decides what is overridden: its
  // compact report lists what it read from every package's declarations,
  // `pub get` reports each override it applied, and its lockfile marks them
  // too.
  final get = await context.tools.run(
    'dart',
    const ['pub', 'get', '--no-example'],
    workingDirectory: directory,
    environment: const {'PUB_SUMMARY_ONLY': '0'},
  );
  final deps = get.ok
      ? await context.tools.run('dart', const [
          'pub',
          'deps',
          '--json',
        ], workingDirectory: directory)
      : get;
  final compact = get.ok
      ? await context.tools.run('dart', const [
          'pub',
          'deps',
          '--style=compact',
        ], workingDirectory: directory)
      : get;
  final root = get.ok ? resolvedRoot(directory) : null;
  // `pub deps --json` fails in one layout Pub resolves (see
  // [recordedGraph]); `pub get` recorded the same graph.
  final graph = deps.ok
      ? deps.stdout
      : root == null
      ? null
      : recordedGraph(root);
  final reached = graph == null
      ? null
      : runtimeDependencies(graph, project.name);
  final unhosted = reached == null
      ? null
      : unhostedDependencies(graph!, reached);
  final flutter = graph == null ? null : usesFlutter(graph);
  final members = graph == null ? null : workspacePackages(graph);
  final siblings = graph == null
      ? null
      : snapshotPackages(graph, project.name, releasedWith);
  final overridden = root == null ? null : overriddenPackages(root);
  final directories = root == null ? null : packageDirectories(root);
  final String? unknown = !get.ok
      ? 'dart pub get failed: ${_firstLine(get.stderr)}'
      : graph == null && !deps.ok
      ? 'dart pub deps failed: ${_firstLine(deps.stderr)}'
      : !compact.ok
      ? 'dart pub deps failed: ${_firstLine(compact.stderr)}'
      : reached == null ||
            unhosted == null ||
            flutter == null ||
            members == null ||
            siblings == null
      ? 'dart pub deps did not print a dependency graph rk reads'
      : root == null
      ? 'Pub left no record of where it resolved ${project.name}'
      : overridden == null
      ? 'rk cannot read the lockfile Pub wrote'
      : directories == null || !siblings.every(directories.containsKey)
      ? 'rk cannot read the package configuration Pub wrote'
      : null;
  if (unknown != null) {
    return refuse(_unresolvedDiagnostic(project.name, unknown));
  }
  // Resolved with Flutter packages rk's reading did not see.
  if (flutter!) {
    final dart = context.stage.compiler?.executable;
    if (dart != null && !dartInFlutterSdk(dart)) {
      return refuse(_flutterDiagnostic(project.name, dart));
    }
  }
  String declaredIn(String package) =>
      declared.where((o) => o.package == package).firstOrNull?.declaredIn ??
      declared
          .where((o) => o.package == everyPackage)
          .firstOrNull
          ?.declaredIn ??
      'an override Pub applied, which rk did not find declared';
  final all = {
    ...declaredOverrides(compact.stdout),
    ...reportedOverrides('${get.stdout}\n${get.stderr}'),
    ...overridden!,
    for (final o in declared)
      if (o.package != everyPackage) o.package,
  };
  final masking = [
    for (final name in all)
      if (name == project.name || reached!.contains(name))
        (package: name, declaredIn: declaredIn(name)),
  ];
  if (masking.isNotEmpty) {
    return refuse(_maskingDiagnostic(project.name, masking));
  }
  // A reached package from a path or Git source is refused whatever
  // declared it: consumers can only receive hosted and SDK packages.
  if (unhosted!.isNotEmpty) {
    return refuse(_unhostedDiagnostic(project.name, unhosted));
  }
  if (all.isNotEmpty) {
    context.attach(
      'pub-overrides-${project.name}.txt',
      'Dependency overrides that do not reach ${project.name}\'s '
          'dependencies, so its consumers resolve what Pub validated:\n'
          '${[for (final name in all) '  $name (${declaredIn(name)})'].join('\n')}\n',
    );
  }
  final here = _canonical(directory);
  return (
    diagnostic: null,
    fromSnapshot: {
      for (final name in siblings!)
        name: _relativePath(here, _canonical(directories![name]!)),
    },
    inWorkspace: members!.length > 1,
  );
}

/// The staged package's directory in [mirror].
String _packageDirectory(Directory mirror, ResolvedProject project) {
  final source = _join(mirror.path, const ['source']);
  return project.pubspec.directory == '.'
      ? source
      : _join(source, StagePath.segments(project.pubspec.directory));
}

/// Pub's validation findings in [output], by the heading Pub lists them
/// under: "Package validation found the following" errors, or potential
/// issues, its warnings. Hints are neither. Each finding is its bullet's
/// text with its continuation lines.
({List<String> errors, List<String> warnings}) _validationFindings(
  String output,
) {
  final heading = RegExp(
    r'^Package validation found the following (?:\d+ )?'
    r'(error|potential issue|hint)s?:$',
  );
  final errors = <String>[];
  final warnings = <String>[];
  List<String>? section;
  final item = <String>[];
  void finish() {
    while (item.isNotEmpty && item.last.trim().isEmpty) {
      item.removeLast();
    }
    if (item.isNotEmpty) section?.add(item.join('\n'));
    item.clear();
  }

  for (final raw in output.split('\n')) {
    final line = raw.trimRight();
    final match = heading.firstMatch(line);
    if (match != null) {
      finish();
      section = switch (match.group(1)) {
        'error' => errors,
        'potential issue' => warnings,
        _ => <String>[],
      };
    } else if (section == null) {
      continue;
    } else if (line.startsWith('* ')) {
      finish();
      item.add(line.substring(2));
    } else if (line.isEmpty || line.startsWith(' ')) {
      if (item.isNotEmpty) {
        item.add(line.startsWith('  ') ? line.substring(2) : line.trimLeft());
      }
    } else {
      finish();
      section = null;
    }
  }
  finish();
  return (errors: errors, warnings: warnings);
}

/// A finding's first line, and its last when the first introduces a list.
String _headline(String finding) {
  final lines = [
    for (final line in finding.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];
  if (lines.length > 1 && lines.first.endsWith(':')) {
    return '${lines.first} ${lines.last}';
  }
  return lines.isEmpty ? finding : lines.first;
}

/// [path] with symbolic links resolved, when it exists.
String _canonical(String path) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return path;
  }
}

/// The path from directory [from] to [to], `/`-separated as a pubspec
/// writes it.
String _relativePath(String from, String to) {
  List<String> parts(String path) =>
      path.split(RegExp(r'[/\\]')).where((part) => part.isNotEmpty).toList();
  final a = parts(from);
  final b = parts(to);
  var common = 0;
  while (common < a.length && common < b.length && a[common] == b[common]) {
    common++;
  }
  return [
    for (var i = common; i < a.length; i++) '..',
    ...b.sublist(common),
  ].join('/');
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

Diagnostic _unresolvedDiagnostic(String package, String why) => Diagnostic(
  code: 'RK-PUB-016',
  message: 'rk could not resolve which packages $package reaches',
  remedy:
      '$why. rk resolves the staged snapshot to see which dependency '
      'overrides reach $package, and without that it cannot tell whether '
      'validation here matches what consumers resolve. Fix the resolution, '
      'then re-stage.',
);

Diagnostic _consumerDiagnostic(String package, String why, String report) =>
    Diagnostic(
      code: 'RK-PUB-017',
      message: 'Pub cannot resolve $package the way its consumers do',
      remedy:
          '$why. rk validates $package against the versions its consumers '
          'get: Pub resolves it alone, from its own pubspec, with no lockfile '
          'and no dependency overrides, and takes from pub.dev every package '
          'that is not released with it or needed only to develop it. Make '
          '$package resolve that way, for example by publishing what it '
          'depends on, then re-stage.',
      evidence: report.isEmpty ? null : report,
    );

String _firstLine(String text) {
  var line = text.trim().split('\n').first.trim();
  while (line.endsWith('.')) {
    line = line.substring(0, line.length - 1);
  }
  return line.isEmpty ? 'no output' : line;
}

Diagnostic _flutterDiagnostic(String package, String dart) => Diagnostic(
  code: 'RK-PUB-014',
  message:
      '$package resolves with Flutter packages, and the Dart rk uses is not '
      'part of a Flutter SDK',
  remedy:
      '$dart is a standalone Dart SDK. rk stages Flutter packages with a '
      'Flutter SDK\'s Dart, which the stage records. Put your Flutter SDK\'s '
      'bin directory first on PATH so rk uses its dart, then re-stage.',
);

/// Deletes Pub's records under [directory]: every `.dart_tool` directory
/// and lockfile. They describe some earlier resolution: a pointer to
/// another root would send rk to a lockfile Pub did not write for this one,
/// and a lockfile holds versions consumers do not get. Pub never archives
/// them.
void _removePubRecords(String directory) {
  final stale = <FileSystemEntity>[];
  for (final entry in Directory(
    directory,
  ).listSync(recursive: true, followLinks: false)) {
    final name = entry.path.split(Platform.pathSeparator).last;
    if (entry is Directory && name == '.dart_tool' ||
        entry is File && name == 'pubspec.lock') {
      stale.add(entry);
    }
  }
  for (final entry in stale) {
    if (entry.existsSync()) entry.deleteSync(recursive: true);
  }
}
