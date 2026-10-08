import 'dart:io';

import '../../engine/assets.dart';
import '../../engine/diagnostic.dart';
import '../../engine/release_stage.dart';
import '../../engine/resolve.dart';
import '../../engine/stage.dart';
import '../../engine/stage_contract.dart';
import '../../engine/stage_receipt.dart';
import '../../engine/stage_source.dart';
import '../../engine/targets.dart';
import '../../engine/tools.dart';
import '../../output/progress.dart';
import '../target_module.dart';
import 'resolution.dart';

/// Pub's native package archive contribution to the reusable release stage.
///
/// Packaging, how Pub resolves the package, diagnostics, and the receipt
/// contract stay together because they describe one private input to the
/// pub.dev lifecycle.
TargetStage pubDevPackageStage({
  required TargetPlan target,
  required ResolvedUnit unit,
}) {
  final archivePath = ReleaseAssets.pubArchivePath(target.project!);
  final contract = StageStepContract(
    'pub-archive:${target.project!.name}',
    outputs: {archivePath: 'pub-archive'},
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
  final receiptName = context.contract.name;
  context.progress('source').begin(CommonProgressActivities.validating);
  final validation = await _packageArchive(context, project);
  if (validation.diagnostic case final diagnostic?) {
    return TargetStageFailure(diagnostic, unit: project.unitName);
  }
  return TargetStageSuccess(
    StageStep(
      name: receiptName,
      outputs: [
        StageArtifact.capture(
          stage: context.stage.directory,
          path: ReleaseAssets.pubArchivePath(project),
          type: 'pub-archive',
        ),
      ],
    ),
    warnings: validation.warnings,
  );
}

/// Stages [project]'s Pub archive.
Future<({Diagnostic? diagnostic, List<Diagnostic> warnings})> _packageArchive(
  TargetStageContext context,
  ResolvedProject project,
) async {
  final archivePath = ReleaseAssets.pubArchivePath(project);
  void requireAbsentDestination() {
    final destination = context.stage.directory.resolve(archivePath);
    if (FileSystemEntity.typeSync(destination, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError(
        'refusing to replace an existing Pub archive: $archivePath',
      );
    }
  }

  requireAbsentDestination();
  // Native validation can fail after opening its output. Keep that output
  // outside the receipt tree until validation succeeds, so a failed producer
  // cannot leave partial bytes or empty canonical directories behind.
  final scratch = Directory.systemTemp.createTempSync('rk-pub-archive-');
  try {
    final archive = File(_join(scratch.path, StagePath.segments(archivePath)));
    archive.parent.createSync(recursive: true);
    final result = await _packageArchiveTo(context, project, archive: archive);
    if (result.diagnostic == null) {
      requireAbsentDestination();
      if (FileSystemEntity.typeSync(archive.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw StateError('native Pub output is not a regular archive file');
      }
      context.stage.directory.writeBytesAtomically(
        archivePath,
        archive.readAsBytesSync(),
      );
    }
    return result;
  } finally {
    scratch.deleteSync(recursive: true);
  }
}

Future<({Diagnostic? diagnostic, List<Diagnostic> warnings})> _packageArchiveTo(
  TargetStageContext context,
  ResolvedProject project, {
  required File archive,
}) async {
  final archivePath = ReleaseAssets.pubArchivePath(project);
  // Pub validates against the versions it resolves, so it resolves the
  // package the way its consumers do, in a mirror of the source: as a root
  // of its own, from its own pubspec, with no lockfile and no dependency
  // override but the repository packages it takes from this source. Pub
  // leaves overrides files out of archives, so the one written here does
  // not change what is published.
  final consumer = _mirrorSource(context, project);
  late final ToolResult packaged;
  late final String resolvedAs;
  late final Set<String> takenFromSource;
  try {
    final sourceRoot = _join(consumer.path, const ['source']);
    String inSource(String directory) => directory == '.'
        ? sourceRoot
        : _join(sourceRoot, StagePath.segments(directory));
    final directory = inSource(project.pubspec.directory);

    // The repository packages Pub takes from this source, by name with
    // their directories: those the release plan names (see
    // [TargetStageContext.fromSource]), and members of the package's
    // workspace that only its development needs.
    final members =
        resolutionPackages(sourceRoot, directory).packages ?? const {};
    final development = {
      for (final name in developmentMembers(members, project.name))
        name: members[name]!,
    };
    final fromSource = {
      for (final MapEntry(key: name, value: path) in context.fromSource.entries)
        name: inSource(path),
      ...development,
    }..remove(project.name);
    // The mirror holds the package and what the plan takes from this
    // source; what only its development needs is known now, from the
    // workspace's pubspecs.
    final developing = [
      for (final path in development.values)
        if (path != directory)
          path == sourceRoot ? '.' : path.substring(sourceRoot.length + 1),
    ];
    if (developing.isNotEmpty) {
      context.source.export(
        sourceRoot,
        only: (path) => developing.any(
          (member) =>
              member == '.' || path == member || path.startsWith('$member/'),
        ),
      );
      _removePubRecords(sourceRoot);
    }

    // A Flutter package, or one that takes a Flutter package from this
    // source, needs a Flutter SDK's Dart, whose pub finds its own Flutter.
    if (needsFlutter([directory, ...fromSource.values])) {
      final dart = context.stage.sdk.executable;
      if (!dartInFlutterSdk(dart)) {
        return (
          diagnostic: _flutterDiagnostic(project.name, dart),
          warnings: const <Diagnostic>[],
        );
      }
    }

    File(_join(directory, const ['pubspec_overrides.yaml'])).writeAsStringSync(
      consumerOverrides({
        for (final MapEntry(key: name, value: path) in fromSource.entries)
          name: _relativePath(directory, path),
      }, inWorkspace: inWorkspace(directory)),
    );
    takenFromSource = fromSource.keys.toSet();
    final names = fromSource.keys.toList()..sort();
    final taken = names.isEmpty
        ? ''
        : ' but ${names.join(', ')} from this source, in the '
              'pubspec_overrides.yaml rk wrote';
    resolvedAs =
        'Pub validated ${project.name} the way its consumers resolve it: as '
        'a root of its own, with no lockfile and no dependency override'
        '$taken.';
    // Pub resolves the package before it validates and archives it, and
    // names each override it applied in a full report, which
    // PUB_SUMMARY_ONLY would turn off.
    packaged = await context.tools.run(
      'dart',
      ['pub', 'publish', '--to-archive', archive.path],
      workingDirectory: directory,
      environment: const {'PUB_SUMMARY_ONLY': '0'},
    );
  } finally {
    consumer.deleteSync(recursive: true);
  }
  final validation = '${packaged.stdout}\n${packaged.stderr}'.trim();
  context.attach(
    'pub-package-${project.name}.txt',
    '$resolvedAs\n\n$validation',
  );
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
  // Pub's solver explains a resolution it cannot make, and stops there.
  final unresolved =
      !packaged.ok && validation.contains('version solving failed');
  final unexpected = reportedOverrides(validation).difference(takenFromSource);
  if (unresolved || unexpected.isNotEmpty) {
    return (
      diagnostic: _consumerDiagnostic(
        project.name,
        unresolved
            ? 'Pub could not resolve it: ${_firstLine(packaged.stderr)}'
            : 'Pub applied overrides rk did not write: '
                  '${unexpected.join(', ')}',
        validation,
      ),
      warnings: const <Diagnostic>[],
    );
  }
  final findings = _validationFindings(validation);

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

/// Exports the source outside the repository before invoking Pub.
///
/// Release stages deliberately live under `.rk/`, which repositories normally
/// ignore, and Pub walks ancestor Git ignore rules when it builds a package:
/// beneath a repository, the whole package can look ignored and produce an
/// empty archive. The mirror holds, with their modes and under `source/`,
/// the files a Dart build of the package reads (see
/// [StageSourceSnapshot.dartBuildInputs]), and is deleted after the archive
/// command finishes.
Directory _mirrorSource(TargetStageContext context, ResolvedProject project) {
  final mirror = Directory.systemTemp.createTempSync('rk-pub-source-');
  try {
    final gitControl = _gitControlAncestor(mirror.path);
    if (gitControl != null) {
      throw StateError(
        'the system temporary directory is inside a Git worktree: '
        '$gitControl',
      );
    }
    final source = _join(mirror.path, const ['source']);
    context.source.export(
      source,
      only: StageSourceSnapshot.dartBuildInputs(
        project.pubspec.directory,
        packages: context.fromSource.values,
      ),
    );
    // Records the source tracks are not Pub's answer for it, and a lockfile
    // holds versions its consumers do not get.
    _removePubRecords(source);
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

Diagnostic _consumerDiagnostic(String package, String why, String report) =>
    Diagnostic(
      code: 'RK-PUB-017',
      message: 'Pub cannot resolve $package the way its consumers do',
      remedy:
          '$why. rk validates $package against the versions its consumers '
          'get: Pub resolves it alone, from its own pubspec, with no lockfile '
          'and no dependency overrides, and takes from pub.dev everything but '
          'the packages of this repository that are not published there yet '
          'or that only its development needs. Make $package resolve that '
          'way, for example by publishing what it depends on, then re-stage.',
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
