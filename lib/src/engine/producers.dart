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
  StepKind.buildAssets => 'assets:${step.project}',
  _ => throw StateError('${step.kind.name} is not a local producer'),
};

bool isMacosBuildReceipt(String name) {
  final parts = name.split(':');
  return parts.length == 3 &&
      parts.first == 'build' &&
      parts.last.startsWith('macos-');
}

bool isMacosArchiveReceipt(String name) {
  final parts = name.split(':');
  return parts.length == 3 &&
      parts.first == 'archive' &&
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
  final project = unit.project(step.project!);
  final platform = step.platform;
  final binaries = platform == null
      ? <String, String>{}
      : ReleaseAssets.binaryOutputs(project, platform);

  switch (step.kind) {
    case StepKind.build:
      return StageStepContract(
        receiptNameFor(step),
        outputs: binaries,
        validateEvidence: _buildEvidence,
      );

    case StepKind.notarize:
      return StageStepContract(
        receiptNameFor(step),
        inputs: binaries.keys.toSet(),
        outputs: {
          ReleaseAssets.notaryResultPath(project, platform!): 'notary',
          ReleaseAssets.notaryLogPath(project, platform): 'notary',
          ReleaseAssets.notaryInputPath(project, platform): 'notary-input',
        },
        validateEvidence: _notaryEvidence,
        validate: _notaryFiles,
      );

    case StepKind.archive:
      return StageStepContract(
        receiptNameFor(step),
        inputs: {
          ...binaries.keys,
          if (platform!.startsWith('macos-'))
            'step:notarize:${project.name}:$platform',
        },
        outputs: {ReleaseAssets.archivePath(project, platform): 'archive'},
        validateEvidence: _archiveEvidence,
      );

    case StepKind.buildAssets:
      return StageStepContract(
        receiptNameFor(step),
        outputs: ReleaseAssets.assetOutputs(project),
        validateEvidence: _assetEvidence,
      );
    default:
      throw StateError('${step.kind.name} is not a local producer');
  }
}

/// A project's build records the command rk ran for it.
Iterable<StageIssue> _assetEvidence(
  StageEvidenceContext context,
  StageStep step,
) {
  final command = step.evidence['command'];
  if (command is List &&
      command.isNotEmpty &&
      command.every((argument) => argument is String)) {
    return const [];
  }
  return [_structure('${step.name} does not record the command it ran')];
}

/// A macOS archive proves the signature on its extracted executable, not
/// merely on the source file that entered the archive builder.
Iterable<StageIssue> _archiveEvidence(
  StageEvidenceContext context,
  StageStep step,
) {
  if (!isMacosArchiveReceipt(step.name)) return const [];
  final signature = step.evidence['signature'];
  if (signature is Map &&
      signature['status'] == 'valid' &&
      signature['scope'] == 'archive-extracted') {
    return const [];
  }
  return [_structure('${step.name} has no final archive signature evidence')];
}

/// A build proves its smoke outcome, and a macOS build its signature too.
Iterable<StageIssue> _buildEvidence(
  StageEvidenceContext context,
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
  } else if (isMacosBuildReceipt(step.name)) {
    final signedSmoke = step.evidence['signed_smoke'];
    final signature = step.evidence['signature'];
    if (signedSmoke is! Map ||
        signedSmoke['status'] != 'pass' ||
        signedSmoke['command'] != '--version' ||
        signature is! Map ||
        signature['verified_after_smoke'] != true) {
      issues.add(
        _structure('${step.name} has no post-smoke signature evidence'),
      );
    }
  }
  return issues;
}

/// Notarization is an identified Accepted submission whose published files
/// are digest-bound to the receipt.
Iterable<StageIssue> _notaryEvidence(
  StageEvidenceContext context,
  StageStep step,
) => _notarySubmission(step) == null ? [_invalidNotary(step)] : const [];

/// The metadata can be checked after provider cleanup; the files themselves
/// must additionally be read whenever the actual stage is inspected.
Iterable<StageIssue> _notaryFiles(
  StageContractContext context,
  StageStep step,
) {
  final submission = _notarySubmission(step);
  if (submission == null) return const []; // Evidence validation owns this.
  if (!_acceptedNotaryFile(
        context.stage,
        submission.result.path,
        submission.id,
      ) ||
      !_logNamesSubmission(context.stage, submission.log.path, submission.id)) {
    return [_invalidNotary(step)];
  }
  return const [];
}

({String id, StageArtifact result, StageArtifact log})? _notarySubmission(
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
      notary['log_sha256'] != log.sha256) {
    return null;
  }
  return (id: submission, result: result, log: log);
}

StageIssue _invalidNotary(StageStep step) => StageIssue(
  StageIssueKind.invalidNotary,
  '${step.name} has invalid Accepted-submission evidence',
  path: 'stage.json',
);

/// Apple's log carries the submission under `id` or `jobId`; when it names
/// one, it must be the submission the result named — a log for different
/// bytes is not evidence about these.
bool _logNamesSubmission(StageDirectory stage, String path, String submission) {
  try {
    final decoded = jsonDecode(File(stage.resolve(path)).readAsStringSync());
    if (decoded is! Map) return false;
    final named = decoded['id'] ?? decoded['jobId'];
    return named == null || named == submission;
  } on Object {
    return false;
  }
}

bool _acceptedNotaryFile(StageDirectory stage, String path, String submission) {
  try {
    final decoded = jsonDecode(File(stage.resolve(path)).readAsStringSync());
    return decoded is Map &&
        decoded['status'] == 'Accepted' &&
        decoded['id'] == submission;
  } on Object {
    return false;
  }
}

StageIssue _structure(String message) =>
    StageIssue(StageIssueKind.invalidStructure, message, path: 'stage.json');
