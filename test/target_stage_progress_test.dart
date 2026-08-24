import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/publish_target.dart';
import 'package:rk/src/engine/stage_contract.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:rk/src/engine/targets.dart';
import 'package:rk/src/targets/target_module.dart';
import 'package:test/test.dart';

TargetPlan _target() => TargetPlan(
      label: 'Example',
      kindLabel: 'Example',
      identity: 'example',
      planNote: 'example assets',
      coordinate: 'example/1.0.0',
      targetVersion: '1.0.0',
      step: Step(
        id: 'tool/example',
        kind: StepKind.publishRelease,
        unit: 'tool',
        summary: 'publish example',
        needs: const [],
        target: PublishTarget.githubRelease,
      ),
      artifacts: const ['one.txt', 'two.txt'],
    );

StageContributionContract _contract() => const StageContributionContract(
      step: StageStepContract(
        'example-stage',
        outputs: {'private/one': 'one', 'private/two': 'two'},
      ),
    );

void main() {
  test('one contribution can bind two outputs and a validation-only row', () {
    final stage = TargetStage(
      target: _target(),
      contract: _contract(),
      planLabel: 'test input',
      progress: [
        TargetStageProgress.output(
          id: 'one',
          output: 'private/one',
          artifact: 'one.txt',
        ),
        TargetStageProgress.output(
          id: 'two',
          output: 'private/two',
          artifact: 'two.txt',
        ),
        TargetStageProgress.row(
          id: 'validation',
          label: 'package metadata',
        ),
      ],
      prepare: (_) async =>
          TargetStageSuccess(StageStep(name: 'example-stage')),
    );

    expect(stage.progress.map((row) => row.id), ['one', 'two', 'validation']);
  });

  test('private intermediate outputs do not need progress rows', () {
    final stage = TargetStage(
      target: _target(),
      contract: _contract(),
      planLabel: 'test input',
      progress: [
        TargetStageProgress.output(
          id: 'one',
          output: 'private/one',
          artifact: 'one.txt',
        ),
      ],
      prepare: (_) async =>
          TargetStageSuccess(StageStep(name: 'example-stage')),
    );
    expect(stage.progress.single.output, 'private/one');
  });

  test('target warnings survive in a reusable stage receipt', () {
    final outcome = TargetStageSuccess(
      StageStep(name: 'example-stage'),
      warnings: const [
        Diagnostic(
          code: 'RK-PUB-012',
          message: 'pub validation reported one warning',
          remedy: 'review it before release',
        ),
      ],
    );

    final restored = recordedTargetStageWarnings(outcome.step);
    expect(restored.single.code, 'RK-PUB-012');
    expect(restored.single.message, contains('one warning'));
    expect(restored.single.remedy, 'review it before release');
  });
}
