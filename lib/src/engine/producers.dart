/// The receipt-side description of the local producer pipeline.
///
/// `Checklist.localProducerSteps` owns the steps, their order, and their
/// dependency edges; this file owns each step's producer name, what it reads
/// from earlier producers, and what it writes.
library;

import 'assets.dart';
import 'checklist.dart';
import 'resolve.dart';
import 'stage_contract.dart';

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
      return StageStepContract(receiptNameFor(step), outputs: binaries);

    case StepKind.notarize:
      return StageStepContract(
        receiptNameFor(step),
        inputs: binaries.keys.toSet(),
        outputs: {
          ReleaseAssets.notaryResultPath(project, platform!): 'notary',
          ReleaseAssets.notaryLogPath(project, platform): 'notary',
          ReleaseAssets.notaryInputPath(project, platform): 'notary-input',
        },
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
      );

    case StepKind.buildAssets:
      return StageStepContract(
        receiptNameFor(step),
        outputs: ReleaseAssets.assetOutputs(project),
      );
    default:
      throw StateError('${step.kind.name} is not a local producer');
  }
}
