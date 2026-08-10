import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/resolve.dart';
import '../engine/stage_contract.dart';
import '../engine/targets.dart';
import 'git_tag_target.dart';
import 'github_release_target.dart';
import 'homebrew_target.dart';
import 'pub_dev_target.dart';
import 'target_module.dart';

/// The fixed, compile-time catalog of public targets rk understands.
///
/// This is deliberately not a plugin registry. Adding a target is a source
/// change, and the coverage check makes a new public checklist step fail fast
/// until exactly one built-in module owns it.
final class TargetCatalog {
  TargetCatalog._()
      : modules = const [
          GitTagTargetModule(),
          PubDevTargetModule(),
          GithubReleaseTargetModule(),
          HomebrewTargetModule(),
        ] {
    final byStep = <StepKind, TargetModule>{};
    for (final module in modules) {
      if (byStep[module.stepKind] != null) {
        throw StateError('two target modules handle ${module.stepKind.name}');
      }
      if (!module.stepKind.isPublic) {
        throw StateError('${module.stepKind.name} is not a public step');
      }
      byStep[module.stepKind] = module;
    }
    final missing = targetStepKinds.difference(byStep.keys.toSet());
    if (missing.isNotEmpty) {
      throw StateError(
        'missing target modules: ${missing.map((kind) => kind.name).join(', ')}',
      );
    }
    _byStep = Map.unmodifiable(byStep);
  }

  factory TargetCatalog.builtIn() => _builtIn;

  static final TargetCatalog _builtIn = TargetCatalog._();
  static final targetStepKinds = Set<StepKind>.unmodifiable(
    StepKind.values.where((kind) => kind.isPublic),
  );

  final List<TargetModule> modules;
  late final Map<StepKind, TargetModule> _byStep;

  TargetModule? moduleForStep(Step step) => _byStep[step.kind];

  TargetModule moduleForTarget(TargetExpectation target) =>
      _byStep[target.step.kind]!;

  List<TargetExpectation> derive(
    ResolvedUnit unit,
    Checklist checklist, {
    String? repository,
  }) {
    final targets = <TargetExpectation>[];
    for (final step in checklist.steps) {
      final module = _byStep[step.kind];
      if (module == null) {
        if (step.isPublic) {
          throw StateError(
              'public step ${step.kind.name} has no target module');
        }
        continue;
      }
      final target = module.expectation(
        unit: unit,
        step: step,
        repository: repository,
      );
      if (target.step.id != step.id || target.step.kind != module.stepKind) {
        throw StateError('${module.runtimeType} derived the wrong target');
      }
      if (step.isPermanent != (module.permanenceNotice(target) != null)) {
        throw StateError(
          '${module.runtimeType} must explain every permanent target',
        );
      }
      targets.add(target);
    }
    return List<TargetExpectation>.unmodifiable(targets);
  }

  List<TargetStage> stages({
    required ResolvedUnit unit,
    required Iterable<TargetExpectation> targets,
  }) {
    final stages = <TargetStage>[];
    for (final target in targets) {
      final module = moduleForTarget(target);
      final stage = module.stage(unit: unit, target: target);
      if (stage != null) stages.add(stage);
    }
    return orderStageContributions(stages, (stage) => stage.contract);
  }

  StageContractResolver stageContractResolver(Resolution resolution) => ({
        required ResolvedUnit unit,
        required String? repository,
        required String sourceRoot,
      }) {
        final diagnostics = Diagnostics();
        final checklist = Checklist.derive(unit, resolution, diagnostics);
        if (diagnostics.isNotEmpty) {
          throw StateError(
            'target stage contract could not be derived: '
            '${diagnostics.found.map((item) => item.message).join('; ')}',
          );
        }
        final targets = derive(unit, checklist, repository: repository);
        return List<StageContributionContract>.unmodifiable([
          for (final stage in stages(unit: unit, targets: targets))
            stage.contract,
        ]);
      };
}
