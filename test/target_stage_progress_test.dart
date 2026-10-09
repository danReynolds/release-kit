import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:rk/src/targets/target_module.dart';
import 'package:test/test.dart';

void main() {
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
