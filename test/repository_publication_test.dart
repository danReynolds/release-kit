import 'dart:io';

import 'package:rk/src/commands/release_preparation.dart';
import 'package:rk/src/commands/release_publication_coordinator.dart';
import 'package:rk/src/commands/repository_publication.dart';
import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/native_dependencies.dart';
import 'package:rk/src/engine/native_publication.dart';
import 'package:rk/src/engine/publish_target.dart';
import 'package:rk/src/engine/release_stage.dart';
import 'package:rk/src/engine/repository_stage_preparation.dart';
import 'package:rk/src/engine/stage_dependencies.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:rk/src/engine/targets.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:test/test.dart';

import 'repository_stage_preparation_test.dart' show RepositoryStageFixture;

void main() {
  late RepositoryStageFixture f;
  setUp(() => f = RepositoryStageFixture());
  tearDown(() => f.root.deleteSync(recursive: true));

  Future<List<PublicationPlan>> prepare(List<String> names) async {
    final plan = await f.resolve(names);
    for (final unit in plan.order) {
      await f.complete(await plan.bind(unit));
    }
    return [for (final name in names) publication(f.stages(f.unit(name)))];
  }

  test(
    'opaque native versions and slots order exact independent units',
    () async {
      f.samePackageIdentity = true;
      f.eligible = f.configuredCandidates();
      f.needs('app', 'app', [('core', 'one'), ('third', 'two')]);
      final prepared = await prepare(['app', 'core', 'third']);
      final native = _Native();
      final plans = await repositoryPublications(
        prepared: prepared,
        native: native,
      );
      expect(plans.map((p) => p.unit.name), ['core', 'third', 'app']);
      final app = plans.last;
      expect(
        app.nativeChecks.values.single.requirements
            .map((r) => r.use.slot)
            .toSet(),
        {'one', 'two'},
      );
      expect(
        app.nativeChecks.values.single.requirements
            .map((r) => r.use.provider.package)
            .toSet(),
        hasLength(1),
      );
      expect(native.verifications, 0);
      expect(() => plans.clear(), throwsUnsupportedError);
    },
  );

  test(
    'named publication keeps copied proof after provider directory is deleted',
    () async {
      f.needs('app', 'app', [('core', 'core')]);
      final prepared = await prepare(['app', 'core']);
      final provider = f.stages(f.unit('core'));
      Directory(provider.directory.path).deleteSync(recursive: true);
      final plans = await repositoryPublications(
        prepared: [prepared.first],
        native: _Native(),
      );
      expect(plans.map((p) => p.unit.name), ['app']);
      expect(
        plans
            .single
            .nativeChecks
            .values
            .single
            .requirements
            .single
            .use
            .provider
            .unit,
        'core',
      );
      expect(
        plans.single.steps
            .expand((s) => s.needs)
            .any((id) => id.startsWith('core/')),
        isFalse,
      );
    },
  );

  test(
    'same-unit runtime edge replaces a conflicting source-only guess',
    () async {
      f.root.deleteSync(recursive: true);
      f = RepositoryStageFixture(grouped: true);
      f.needs('core', 'core', [('helper', 'helper')]);
      final prepared = await prepare(['core']);
      final original = prepared.single;
      final steps = original.steps
          .map(
            (step) => step.project == 'helper'
                ? step.withNeeds([...step.needs, 'core/package/core'])
                : step,
          )
          .toList();
      final guessed = copy(original, steps: steps);
      final plans = await repositoryPublications(
        prepared: [guessed],
        native: _Native(),
      );
      final publications = plans.single.publicSteps;
      expect(publications.map((step) => step.project), ['helper', 'core']);
      expect(publications.last.needs, contains('core/package/helper'));
      expect(publications.first.needs, isNot(contains('core/package/core')));
      expect(
        plans.single.targets
            .singleWhere((target) => target.project!.name == 'core')
            .step
            .needs,
        publications.last.needs,
      );
    },
  );

  test(
    'native runtime exclusion removes source prerequisites and guessed edges',
    () async {
      f.needs('app', 'app', [('core', 'core')]);
      final prepared = await prepare(['app', 'core']);
      final app = prepared.first;
      final sourceOnly = Step(
        id: 'app/requires/guessed',
        kind: StepKind.prerequisite,
        unit: 'app',
        summary: 'guessed dependency',
        needs: [],
      );
      final guessed = copy(
        app,
        steps: [
          sourceOnly,
          ...app.steps.map(
            (step) => step.isPublic
                ? step.withNeeds([...step.needs, sourceOnly.id])
                : step,
          ),
        ],
      );
      final plans = await repositoryPublications(
        prepared: [guessed, prepared.last],
        native: _Native(includeRuntime: false),
      );
      expect(plans.map((p) => p.unit.name), ['app', 'core']);
      expect(
        plans.first.steps.any((s) => s.kind == StepKind.prerequisite),
        isFalse,
      );
      expect(
        plans.first.steps.expand((s) => s.needs),
        isNot(contains(sourceOnly.id)),
      );
    },
  );

  test(
    'provider archive mismatch is rejected before consent or verification',
    () async {
      f.needs('app', 'app', [('core', 'core')]);
      final prepared = await prepare(['app', 'core']);
      final core = f.stages(f.unit('core'));
      final file = File(core.directory.resolve('core.pkg'));
      file.writeAsStringSync('different archive');
      final native = _Native();
      await expectLater(
        repositoryPublications(prepared: prepared, native: native),
        throwsStateError,
      );
      expect(native.verifications, 0);
    },
  );

  test(
    'a different valid provider output cannot replace a frozen consumer commitment',
    () async {
      f.needs('app', 'app', [('core', 'core')]);
      final prepared = await prepare(['app', 'core']);
      final core = f.stages(f.unit('core'));
      core.reset();
      await f.complete(core, artifactSuffix: ' changed');
      expect(core.inspect().reusable, isTrue);
      await expectLater(
        repositoryPublications(prepared: prepared, native: _Native()),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('provider archive differs from the consumer commitment'),
          ),
        ),
      );
    },
  );

  Future<void> importedCycle({required bool interleaved}) async {
    if (interleaved) {
      f.root.deleteSync(recursive: true);
      f = RepositoryStageFixture(grouped: true);
    }
    final base = f.bindEmpty('core');
    await f.complete(base);
    f.providers.add(PreparedStageProvider.capture(base));
    f.needs('app', 'app', [(interleaved ? 'helper' : 'core', 'input')]);
    final appPlan = await f.resolve(['app']);
    final app = await appPlan.bind(f.unit('app'));
    await f.complete(app);
    f.providers
      ..clear()
      ..add(PreparedStageProvider.capture(app));
    f.needs('core', 'core', [('app', 'input')]);
    final corePlan = await f.resolve(['core']);
    final core = await corePlan.bind(f.unit('core'));
    await f.complete(core);
    await expectLater(
      repositoryPublications(
        prepared: [publication(app), publication(core)],
        native: _Native(),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          interleaved
              ? contains('interleaved release units')
              : allOf(
                  contains('dependency cycle'),
                  isNot(contains('interleaved')),
                ),
        ),
      ),
    );
  }

  test(
    'actual publication target cycle is diagnosed before unit grouping',
    () => importedCycle(interleaved: false),
  );
  test(
    'acyclic public targets requiring unit interleaving refuse explicitly',
    () => importedCycle(interleaved: true),
  );

  for (final corruption in ['missing', 'extra', 'duplicate', 'archive']) {
    test(
      'native $corruption coverage cannot widen or weaken publication',
      () async {
        f.needs('app', 'app', [('core', 'core')]);
        final prepared = await prepare(['app', 'core']);
        await expectLater(
          repositoryPublications(
            prepared: prepared,
            native: _Native(corruption: corruption),
          ),
          throwsStateError,
        );
      },
    );
  }
}

PublicationPlan publication(ReleaseStage stage) {
  final barrier = Step(
    id: '${stage.unit.name}/stage/complete',
    kind: StepKind.completeStage,
    unit: stage.unit.name,
    summary: 'private stage',
    needs: [],
  );
  final targets = [
    for (final project in stage.unit.projects)
      TargetPlan(
        label: project.name,
        coordinate: project.name,
        targetVersion: 'release:${project.name}',
        step: Step(
          id: '${stage.unit.name}/package/${project.name}',
          kind: StepKind.publishRegistry,
          target: PublishTarget.pubDev,
          unit: stage.unit.name,
          project: project.name,
          summary: project.name,
          needs: [barrier.id],
        ),
        kindLabel: 'fixture',
        identity: project.name,
        planNote: '',
        artifacts: ['${project.name}.pkg'],
        project: project,
        packageProducer: 'native:${project.name}',
      ),
  ];
  return PublicationPlan(
    unit: stage.unit,
    steps: [barrier, ...targets.map((t) => t.step)],
    publicSteps: targets.map((t) => t.step),
    targets: targets,
    states: {
      for (final target in targets) target.step.id: const Inspection.absent(),
    },
    endpointBaselines: {},
    actions: {
      for (final target in targets) target.step.id: ReleaseAction.notAttempted,
    },
    prepared: PreparedRelease(claims: [], signing: null),
    stage: stage,
    recoversWithoutStage: false,
  );
}

PublicationPlan copy(PublicationPlan plan, {required List<Step> steps}) =>
    PublicationPlan(
      unit: plan.unit,
      steps: steps,
      publicSteps: steps.where((s) => s.isPublic),
      targets: plan.targets,
      states: plan.states,
      endpointBaselines: plan.endpointBaselines,
      actions: plan.actions,
      prepared: plan.prepared,
      stage: plan.stage,
      recoversWithoutStage: plan.recoversWithoutStage,
    );

final class _Native implements NativePublication {
  _Native({this.includeRuntime = true, this.corruption});
  final bool includeRuntime;
  final String? corruption;
  int verifications = 0;
  @override
  Set<String> get ecosystems => {'fixture'};
  @override
  Future<List<NativePublicationCheck>> prepare(ReleaseStage stage) async {
    final receipt = stage.requireReceipt();
    final uses = <(NativeArtifactUse, StageArtifact)>[
      for (final input in stage.dependencies.imports)
        (input.use, input.archive),
      for (final input in stage.dependencies.local)
        (
          input.use,
          receipt.artifacts.singleWhere(
            (artifact) => artifact.path == input.path,
          ),
        ),
    ];
    final checks = <NativePublicationCheck>[
      for (final project in stage.unit.projects)
        _Check('native:${project.name}', [
          if (includeRuntime)
            for (final (use, archive) in uses)
              if (use.consumers.contains('native:${project.name}'))
                NativePublicArchiveRequirement(
                  use: use,
                  archive: corruption == 'archive'
                      ? StageArtifact(
                          path: archive.path,
                          type: archive.type,
                          mode: archive.mode,
                          size: archive.size,
                          sha256: '0' * 64,
                        )
                      : archive,
                  causes: [
                    NativeRequirement(
                      context: use.context,
                      owner: project.name,
                      slot: use.slot,
                      consumer: 'hosted-bridge',
                      package: use.provider.package,
                      constraint: 'opaque-native-constraint',
                      kind: 'runtime',
                      location: const SourceLocation('manifest', 1),
                      phases: [DependencyPhase.publication],
                    ),
                  ],
                ),
        ], () => verifications++),
    ];
    switch (corruption) {
      case 'missing':
        checks.clear();
      case 'extra':
        checks.add(_Check('unknown', [], () {}));
      case 'duplicate':
        checks.add(checks.first);
    }
    return checks;
  }
}

final class _Check implements NativePublicationCheck {
  _Check(
    this.producer,
    Iterable<NativePublicArchiveRequirement> requirements,
    this.onVerify,
  ) : requirements = List.unmodifiable(requirements);
  @override
  final String producer;
  @override
  final List<NativePublicArchiveRequirement> requirements;
  final void Function() onVerify;
  @override
  Future<NativePublicationOutcome> verify() async {
    onVerify();
    return NativePublicationReady(evidence: {});
  }
}
