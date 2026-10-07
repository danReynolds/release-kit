import 'dart:convert';

import '../transforms/digest.dart';
import 'stage.dart';
import 'stage_inspection.dart';
import 'stage_receipt.dart';

/// Pure declaration checks: causal consistency between steps, not artifact
/// bytes. The receipt's identity binds every step to its source.
final class StageReceiptStructure {
  const StageReceiptStructure._();

  static List<StageIssue> validate(StageReceipt receipt) {
    final issues = <StageIssue>[];
    final priorSteps = <String, StageStep>{};
    final priorArtifacts = <String, StageArtifact>{};
    final completeIndexes = <int>[];
    if (receipt.steps.isEmpty) {
      if (receipt.plan == null) {
        _structure(
          issues,
          'receipt has neither a frozen plan nor producer steps',
        );
      }
      return issues;
    }
    for (var index = 0; index < receipt.steps.length; index++) {
      final step = receipt.steps[index];
      if (step.name == 'complete-stage') completeIndexes.add(index);

      for (final input in step.inputs) {
        final expected = _inputDigest(
          receipt.identity,
          input.name,
          priorSteps,
          priorArtifacts,
        );
        if (expected == null) {
          _structure(
            issues,
            '${step.name} names an input no earlier step produced: '
            '${input.name}',
          );
        } else if (expected != input.sha256) {
          _structure(
            issues,
            '${step.name} input digest differs from its producer: '
            '${input.name}',
          );
        }
      }
      for (final output in step.outputs) {
        priorArtifacts[output.path] = output;
      }
      priorSteps[step.name] = step;
    }

    if (!receipt.complete) {
      // Completion is derived from the terminal step, and step names are
      // unique by construction, so the one damaged shape left to name is a
      // finalizing step that is no longer terminal.
      if (completeIndexes.isNotEmpty) {
        _structure(issues, 'complete-stage must be the terminal step');
      }
      return issues;
    }

    final complete = receipt.steps.last;
    if (complete.outputs.length != 1 ||
        complete.outputs.single.path != 'release-manifest.json' ||
        complete.outputs.single.type != 'manifest') {
      _structure(
        issues,
        'complete-stage must produce only release-manifest.json',
      );
      return issues;
    }
    return issues;
  }

  static String? _inputDigest(
    StageIdentity identity,
    String name,
    Map<String, StageStep> priorSteps,
    Map<String, StageArtifact> priorArtifacts,
  ) {
    switch (name) {
      case 'stage:commit':
        return identity.headCommit == null
            ? null
            : Sha256.hex(utf8.encode(identity.headCommit!));
      case 'stage:tree':
        return identity.headTree == null
            ? null
            : Sha256.hex(utf8.encode(identity.headTree!));
      case 'stage:plan':
        return identity.planSha256;
    }
    if (name.startsWith('step:')) {
      return priorSteps[name.substring('step:'.length)]?.outputSha256;
    }
    return priorArtifacts[name]?.sha256;
  }
}

void _structure(List<StageIssue> issues, String message) {
  issues.add(
    StageIssue(StageIssueKind.invalidStructure, message, path: 'stage.json'),
  );
}
