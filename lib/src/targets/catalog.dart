import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/publish_target.dart';
import '../engine/resolve.dart';
import '../engine/stage_contract.dart';
import '../engine/targets.dart';
import 'git_tag/module.dart';
import 'github_release/module.dart';
import 'homebrew/module.dart';
import 'pub_dev/module.dart';
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
    final byTarget = <PublishTarget, TargetModule>{};
    for (final module in modules) {
      if (byTarget[module.target] != null) {
        throw StateError('two target modules handle '
            '${module.target.configName}');
      }
      byTarget[module.target] = module;
    }
    final missing =
        PublishTarget.values.toSet().difference(byTarget.keys.toSet());
    if (missing.isNotEmpty) {
      throw StateError(
        'missing target modules: '
        '${missing.map((target) => target.configName).join(', ')}',
      );
    }
    _byTarget = Map.unmodifiable(byTarget);
  }

  factory TargetCatalog.builtIn() => _builtIn;

  static final TargetCatalog _builtIn = TargetCatalog._();
  static final targetStepKinds = Set<StepKind>.unmodifiable(
    StepKind.values.where((kind) => kind.isPublic),
  );

  final List<TargetModule> modules;
  late final Map<PublishTarget, TargetModule> _byTarget;

  TargetModule? moduleForStep(Step step) => _byTarget[step.target];

  TargetModule moduleForTarget(TargetPlan target) => _byTarget[target.target]!;

  List<TargetPlan> derive(
    ResolvedUnit unit,
    Checklist checklist, {
    String? repository,
  }) {
    final targets = <TargetPlan>[];
    for (final step in checklist.steps) {
      final module = _byTarget[step.target];
      if (module == null) {
        if (step.isPublic) {
          throw StateError(
              'public step ${step.kind.name} has no target module');
        }
        continue;
      }
      final target = module.plan(
        unit: unit,
        step: step,
        repository: repository,
      );
      if (target.step.id != step.id ||
          !target.step.isPublic ||
          target.target != module.target) {
        throw StateError('${module.runtimeType} derived the wrong target');
      }
      if (step.isPermanent != (target.permanenceNotice != null)) {
        throw StateError(
          '${module.runtimeType} must explain every permanent target',
        );
      }
      targets.add(target);
    }
    return List<TargetPlan>.unmodifiable(targets);
  }

  List<TargetStage> stages({
    required ResolvedUnit unit,
    required Iterable<TargetPlan> targets,
  }) {
    final stages = <TargetStage>[];
    for (final target in targets) {
      final module = moduleForTarget(target);
      final stage = module.stageInput(unit: unit, target: target);
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
