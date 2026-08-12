/// The receipt-side description of the local producer pipeline.
///
/// `Checklist.localProducerSteps` owns the steps, their order, and their
/// dependency edges; this file owns what each of those steps must leave in
/// the receipt — its producer name, its exact inputs and outputs, and the
/// evidence that proves it ran. The coordinator and the contract both read
/// these, so the pipeline is declared once and validated everywhere.
library;

import 'dart:convert';
import 'dart:io';

import 'assets.dart';
import 'checklist.dart';
import 'resolve.dart';
import 'stage.dart';
import 'stage_contract.dart';
import 'stage_inspection.dart';
import 'stage_receipt.dart';

/// The receipt producer name for one local checklist step.
String receiptNameFor(Step step) => switch (step.kind) {
      StepKind.build => 'build:${step.project}:${step.platform}',
      StepKind.notarize => 'notarize:${step.project}:${step.platform}',
      StepKind.archive => 'archive:${step.project}:${step.platform}',
      StepKind.checksums => 'bundle:checksums',
      _ => throw StateError('${step.kind.name} is not a local producer'),
    };

bool isMacosBuildReceipt(String name) {
  final parts = name.split(':');
  return parts.length == 3 &&
      parts.first == 'build' &&
      parts.last.startsWith('macos-');
}

String archiveReceiptName(String project, String platform) =>
    'archive:$project:$platform';

/// The ordered receipt contracts for every local producer of [unit].
List<StageStepContract> localProducerContracts(ResolvedUnit unit) => [
      for (final step in Checklist.localProducerSteps(unit))
        contractFor(unit, step),
    ];

/// The receipt contract one local checklist step must satisfy.
StageStepContract contractFor(ResolvedUnit unit, Step step) {
  if (step.kind == StepKind.checksums) {
    return StageStepContract(
      receiptNameFor(step),
      inputs: {
        for (final contribution in ReleaseAssets.contributionsFor(unit))
          contribution.stagedPath,
      },
      outputs: {ReleaseAssets.checksumPath: 'checksums'},
      validate: _checksumsEvidence,
    );
  }
  final project = unit.project(step.project!);
  final platform = step.platform;
  final binary =
      platform == null ? null : ReleaseAssets.binaryPath(project, platform);

  switch (step.kind) {
    case StepKind.build:
      return StageStepContract(
        receiptNameFor(step),
        inputs: const {'step:source-snapshot'},
        outputs: {binary!: 'executable'},
        validate: _buildEvidence,
      );

    case StepKind.notarize:
      return StageStepContract(
        receiptNameFor(step),
        inputs: {binary!},
        outputs: {
          ReleaseAssets.notaryResultPath(project, platform!): 'notary',
          ReleaseAssets.notaryLogPath(project, platform): 'notary',
          ReleaseAssets.notaryInputPath(project, platform): 'notary-input',
        },
        validate: _notaryEvidence,
      );

    case StepKind.archive:
      return StageStepContract(
        receiptNameFor(step),
        inputs: {binary!},
        outputs: {
          ReleaseAssets.archivePath(project, platform!): 'archive',
        },
      );

    case StepKind.checksums:
      throw StateError('checksums are handled by the unit bundle');

    default:
      throw StateError('${step.kind.name} is not a local producer');
  }
}

/// A build proves its smoke outcome, and a macOS build its signature too.
Iterable<StageIssue> _buildEvidence(
  StageContractContext context,
  StageStep step,
) {
  final issues = <StageIssue>[];
  final smoke = step.evidence['smoke'];
  final status = smoke is Map ? smoke['status'] : null;
  final reason = smoke is Map ? smoke['reason'] : null;
  if (status != 'passed' &&
      !(status == 'not-executed' && reason is String && reason.isNotEmpty)) {
    issues.add(_structure('${step.name} has invalid smoke-test evidence'));
  }
  if (isMacosBuildReceipt(step.name) && step.evidence['signature'] == null) {
    issues.add(_structure('${step.name} has no signature evidence'));
  }
  return issues;
}

/// Notarization is an identified Accepted submission whose published files
/// are digest-bound to the receipt.
Iterable<StageIssue> _notaryEvidence(
  StageContractContext context,
  StageStep step,
) {
  final notary = step.evidence['notary'];
  final result = step.outputs
      .where((output) => output.path.endsWith('.notary-result.json'))
      .firstOrNull;
  final log = step.outputs
      .where((output) => output.path.endsWith('.notary-log.json'))
      .firstOrNull;
  final submission = notary is Map ? notary['submission_id'] : null;
  if (notary is! Map ||
      notary['status'] != 'Accepted' ||
      submission is! String ||
      submission.isEmpty ||
      result == null ||
      log == null ||
      notary['result_sha256'] != result.sha256 ||
      notary['log_sha256'] != log.sha256 ||
      !_acceptedNotaryFile(context.stage, result.path, submission) ||
      !_logNamesSubmission(context.stage, log.path, submission)) {
    return [
      StageIssue(
        StageIssueKind.invalidNotary,
        '${step.name} has invalid Accepted-submission evidence',
        path: 'stage.json',
      ),
    ];
  }
  return const [];
}

/// The checksums evidence binds every archive input, and the file agrees.
Iterable<StageIssue> _checksumsEvidence(
  StageContractContext context,
  StageStep step,
) {
  final checksums = step.evidence['checksums'];
  final publicNameByPath = {
    for (final contribution in ReleaseAssets.contributionsFor(context.unit))
      contribution.stagedPath: contribution.publicName,
  };
  final expected = {
    for (final input in step.inputs)
      publicNameByPath[input.name] ?? input.name: input.sha256,
  };
  final output = step.outputs.firstOrNull;
  if (checksums is! Map ||
      !_sameMap(checksums, expected) ||
      output == null ||
      !_checksumFileMatches(context.stage, output.path, expected)) {
    return [
      const StageIssue(
        StageIssueKind.invalidChecksums,
        'checksums evidence does not exactly bind every archive input',
        path: ReleaseAssets.checksumPath,
      ),
    ];
  }
  return const [];
}

/// Apple's log carries the submission under `id` or `jobId`; when it names
/// one, it must be the submission the result named — a log for different
/// bytes is not evidence about these.
bool _logNamesSubmission(
  StageDirectory stage,
  String path,
  String submission,
) {
  try {
    final decoded = jsonDecode(File(stage.resolve(path)).readAsStringSync());
    if (decoded is! Map) return false;
    final named = decoded['id'] ?? decoded['jobId'];
    return named == null || named == submission;
  } on Object {
    return false;
  }
}

bool _acceptedNotaryFile(
  StageDirectory stage,
  String path,
  String submission,
) {
  try {
    final decoded = jsonDecode(File(stage.resolve(path)).readAsStringSync());
    return decoded is Map &&
        decoded['status'] == 'Accepted' &&
        decoded['id'] == submission;
  } on Object {
    return false;
  }
}

bool _checksumFileMatches(
  StageDirectory stage,
  String path,
  Map<String, String> expected,
) {
  try {
    final found = <String, String>{};
    for (final line in File(stage.resolve(path)).readAsLinesSync()) {
      if (line.isEmpty) continue;
      final match =
          RegExp(r'^([0-9a-f]{64})  ([^/\\\u0000]+)$').firstMatch(line);
      if (match == null || found.containsKey(match.group(2))) return false;
      found[match.group(2)!] = match.group(1)!;
    }
    return _sameMap(found, expected);
  } on Object {
    return false;
  }
}

bool _sameMap(Map left, Map right) =>
    left.length == right.length &&
    left.entries.every((entry) => right[entry.key] == entry.value);

StageIssue _structure(String message) => StageIssue(
      StageIssueKind.invalidStructure,
      message,
      path: 'stage.json',
    );
