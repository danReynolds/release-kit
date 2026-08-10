import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/resolve.dart';
import '../engine/stage_contract.dart';
import '../engine/targets.dart';
import 'git_tag_target.dart';
import 'github_release_target.dart';
import 'homebrew_target.dart';
import 'pub_dev_target.dart';
import 'target_release.dart';

/// The complete, compile-time catalog of public targets rk understands.
///
/// Construction is fail-fast: adding a public step or target kind without one
/// module cannot silently produce a checklist that nobody inspects or acts on.
final class TargetCatalog {
  TargetCatalog(Iterable<TargetReleaseModule> modules)
      : modules = List<TargetReleaseModule>.unmodifiable(modules) {
    final byStep = <StepKind, TargetReleaseModule>{};
    final byKind = <ReleaseTargetKind, TargetReleaseModule>{};
    for (final module in this.modules) {
      if (byStep.containsKey(module.stepKind)) {
        throw ArgumentError(
            'two target modules handle ${module.stepKind.name}');
      }
      if (byKind.containsKey(module.kind)) {
        throw ArgumentError('two target modules handle ${module.kind.name}');
      }
      byStep[module.stepKind] = module;
      byKind[module.kind] = module;
    }
    final missingSteps = targetStepKinds.difference(byStep.keys.toSet());
    final extraSteps = byStep.keys.toSet().difference(targetStepKinds);
    final missingKinds = ReleaseTargetKind.values.toSet().difference(
          byKind.keys.toSet(),
        );
    if (missingSteps.isNotEmpty ||
        extraSteps.isNotEmpty ||
        missingKinds.isNotEmpty) {
      throw ArgumentError([
        if (missingSteps.isNotEmpty)
          'missing target steps: ${missingSteps.map((kind) => kind.name).join(', ')}',
        if (extraSteps.isNotEmpty)
          'non-target steps registered: ${extraSteps.map((kind) => kind.name).join(', ')}',
        if (missingKinds.isNotEmpty)
          'missing target kinds: ${missingKinds.map((kind) => kind.name).join(', ')}',
      ].join('; '));
    }
    _byStep = Map.unmodifiable(byStep);
    _byKind = Map.unmodifiable(byKind);
  }

  factory TargetCatalog.builtIn() => TargetCatalog(const [
        GitTagTargetModule(),
        PubDevTargetModule(),
        GithubReleaseTargetModule(),
        HomebrewTargetModule(),
      ]);

  static final targetStepKinds = Set<StepKind>.unmodifiable(
    StepKind.values.where((kind) => kind.isPublic),
  );

  final List<TargetReleaseModule> modules;
  late final Map<StepKind, TargetReleaseModule> _byStep;
  late final Map<ReleaseTargetKind, TargetReleaseModule> _byKind;

  TargetReleaseModule? moduleForStep(Step step) => _byStep[step.kind];

  TargetReleaseModule moduleForTarget(TargetExpectation target) =>
      _byKind[target.kind]!;

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
      if (target.kind != module.kind ||
          target.step.id != step.id ||
          target.step.kind != module.stepKind) {
        throw StateError('${module.runtimeType} derived the wrong target');
      }
      if (module.isPermanent != step.isPermanent) {
        throw StateError(
          '${module.runtimeType} permanence disagrees with ${step.kind.name}',
        );
      }
      if (module.isPermanent != (module.permanenceNotice(target) != null)) {
        throw StateError(
          '${module.runtimeType} must explain every permanent target',
        );
      }
      targets.add(target);
    }
    return List<TargetExpectation>.unmodifiable(targets);
  }

  List<TargetStageBinding> stageBindings({
    required ResolvedUnit unit,
    required Iterable<TargetExpectation> targets,
    required String? repository,
    required String sourceRoot,
  }) {
    final bindings = <TargetStageBinding>[];
    for (final target in targets) {
      final module = moduleForTarget(target);
      final contract = module.stageContract(
        unit: unit,
        target: target,
        repository: repository,
        sourceRoot: sourceRoot,
      );
      if (contract == null) continue;
      bindings.add(TargetStageBinding(
        module: module,
        target: target,
        contract: contract,
      ));
    }
    return orderStageContributions(
      bindings,
      (binding) => binding.contract,
    );
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
        final targets = derive(
          unit,
          checklist,
          repository: repository,
        );
        return List<StageContributionContract>.unmodifiable([
          for (final binding in stageBindings(
            unit: unit,
            targets: targets,
            repository: repository,
            sourceRoot: sourceRoot,
          ))
            binding.contract,
        ]);
      };
}
