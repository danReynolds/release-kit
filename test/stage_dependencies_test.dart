import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/commands/release_stage_coordinator.dart';
import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/canonical_json.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/native_dependencies.dart';
import 'package:rk/src/engine/native_stage_context.dart';
import 'package:rk/src/engine/publish_target.dart';
import 'package:rk/src/engine/release_stage.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/engine/stage_contract.dart';
import 'package:rk/src/engine/stage_intent.dart';
import 'package:rk/src/engine/stage_lookup.dart';
import 'package:rk/src/engine/stage_store.dart';
import 'package:rk/src/engine/stage_dependencies.dart';
import 'package:rk/src/engine/stage_plan.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:rk/src/engine/targets.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/targets/target_module.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

void main() {
  late _Fixture f;
  setUp(() => f = _Fixture());
  tearDown(() => f.close());

  StageDependencies externalDependencies() {
    final external = f.external();
    return StageDependencies(
      external: [external],
      contexts: [
        f.context([external.binding]),
      ],
    );
  }

  test(
    'header intent lookup and authorized adoption restore the same stage',
    () async {
      final nativeFacts = <String, Object?>{
        'registry': 'fixture-registry',
        'policy': 1,
      };
      final intent = f.stages.intentFor(
        f.app,
        currentGit: f.git,
        readInputs: () => nativeFacts,
      );
      final stage = f.stages.bindDependencies(
        f.app,
        externalDependencies(),
        intent: intent,
      );
      final store = StageStore(f.root.path);
      expect(store.intentHintPath(intent.sha256), isNull);
      stage.writeProgress(const []);
      expect(File(store.intentHintPath(intent.sha256)!).existsSync(), isTrue);
      final before = stage.directory.fingerprint();
      final restarted = f.resolver();
      final current = restarted.intentFor(
        f.app,
        currentGit: f.git,
        readInputs: () => nativeFacts,
      );
      final lookup = await StageLookup(store).find(current);
      expect(lookup.kind, StageLookupKind.found);
      var authorizations = 0;
      final adopted = await restarted.adoptFrozen(
        f.app,
        currentGit: f.git,
        receipt: lookup.receipt!,
        intent: current,
        authorize: (saved, git) async {
          authorizations++;
          return StageDependencies.fromJson(saved.plan!['dependency_inputs']);
        },
      );
      expect(authorizations, 1);
      expect(adopted.directory.identity.id, stage.directory.identity.id);
      expect(
        restarted.refresh(f.app, f.git).directory.identity.id,
        stage.directory.identity.id,
      );
      expect(stage.directory.fingerprint(), before);
      expect(adopted.inspect().canRestartSource, isTrue);
      expect(adopted.inspect().validProgress, isFalse);
      expect(adopted.requireProducerProgress, throwsStateError);
    },
  );

  for (final obstruction in ['file', 'directory', 'symlink']) {
    test(
      'unavailable advisory hint ($obstruction) does not prevent a durable header',
      () async {
        final intent = f.stages.intentFor(
          f.app,
          currentGit: f.git,
          readInputs: () => {},
        );
        final store = StageStore(f.root.path);
        final hint = store.intentHintPath(intent.sha256, create: true)!;
        final sentinel = File('${f.root.path}/sentinel')
          ..writeAsStringSync('unchanged');
        switch (obstruction) {
          case 'file':
            Directory(File(hint).parent.path).deleteSync();
            File(File(hint).parent.path).writeAsStringSync('not a directory');
          case 'directory':
            Directory(hint).createSync();
          case 'symlink':
            Link(hint).createSync(sentinel.path);
        }
        final stage = f.stages.bindDependencies(
          f.app,
          externalDependencies(),
          intent: intent,
        );
        stage.writeProgress(const []);
        expect(stage.inspect().canRestartSource, isTrue);
        expect(
          (await StageLookup(store).find(intent)).receipt!.identity.id,
          stage.directory.identity.id,
        );
        expect(sentinel.readAsStringSync(), 'unchanged');
        if (obstruction == 'directory') {
          expect(Directory(hint).existsSync(), isTrue);
        }
        if (obstruction == 'symlink') {
          expect(Link(hint).targetSync(), sentinel.path);
        }
      },
    );
  }

  test('refresh rereads native facts not present in the base binary plan', () {
    final binary = _Fixture(binaryOnly: true);
    addTearDown(binary.close);
    var registry = 'https://first.example';
    final intent = binary.stages.intentFor(
      binary.app,
      currentGit: binary.git,
      readInputs: () => {'registry': registry},
    );
    expect(CanonicalJson.encode(intent.basePlan), isNot(contains(registry)));
    final stage = binary.stages.bindDependencies(
      binary.app,
      StageDependencies(contexts: [binary.context([])]),
      intent: intent,
    );
    registry = 'https://second.example';
    final changed = binary.stages.intentFor(
      binary.app,
      currentGit: binary.git,
      readInputs: () => {'registry': registry},
    );
    expect(changed.base.id, intent.base.id);
    expect(changed.sha256, isNot(intent.sha256));
    expect(
      () => binary.stages.refresh(binary.app, binary.git),
      throwsStateError,
    );
    expect(binary.stages(binary.app), same(stage));
  });

  test(
    'native input drift during authorization cannot adopt saved intent',
    () async {
      var registry = 'first-registry';
      final intent = f.stages.intentFor(
        f.app,
        currentGit: f.git,
        readInputs: () => {'registry': registry},
      );
      final stage = f.stages.bindDependencies(
        f.app,
        externalDependencies(),
        intent: intent,
      );
      stage.writeProgress(const []);
      final restarted = f.resolver();
      final baseline = restarted(f.app);
      final current = restarted.intentFor(
        f.app,
        currentGit: f.git,
        readInputs: () => {'registry': registry},
      );
      await expectLater(
        restarted.adoptFrozen(
          f.app,
          currentGit: f.git,
          receipt: StageReceiptStore(stage.directory).read()!,
          intent: current,
          authorize: (saved, git) async {
            registry = 'second-registry';
            return StageDependencies.fromJson(saved.plan!['dependency_inputs']);
          },
        ),
        throwsStateError,
      );
      expect(restarted(f.app), same(baseline));
    },
  );

  test('fresh source or compiler identity invalidates captured intent', () {
    final intent = f.stages.intentFor(
      f.app,
      currentGit: f.git,
      readInputs: () => {},
    );
    expect(
      () => f
          .resolver(compilerDigest: () => 'c')
          .bindDependencies(f.app, externalDependencies(), intent: intent),
      throwsStateError,
    );
    final saved = f.stages.bindDependencies(
      f.app,
      externalDependencies(),
      intent: intent,
    );
    expect(
      () => f.stages.refresh(f.app, f.gitAt(head: '3' * 40)),
      throwsStateError,
    );
    expect(f.stages(f.app), same(saved));
    expect(saved.resolvedPlan![StageIntent.planKey], intent.sha256);
  });

  for (final state in [
    'complete',
    'source',
    'header',
    'source residue',
    'pending output',
  ]) {
    test(
      'transactional adoption restores $state without writing disk',
      () async {
        final stage = f.stages.bindDependencies(f.app, externalDependencies());
        if (state == 'complete') {
          await f.complete(stage, 'complete consumer');
        } else if (state == 'source' || state == 'pending output') {
          await f.start(stage);
          if (state == 'pending output') {
            stage.directory.writeBytesAtomically(
              'app.pkg',
              utf8.encode('unfinished'),
            );
          }
        } else {
          stage.writeProgress(const []);
          if (state == 'source residue') {
            stage.directory.writeBytesAtomically(
              'source/partial',
              utf8.encode('unfinished'),
            );
          }
        }
        final receipt = StageReceiptStore(stage.directory).read()!;
        final before = stage.directory.fingerprint();
        final restarted = f.resolver();
        final baseline = restarted(f.app);
        var authorizations = 0;
        final restored = await restarted.adoptFrozen(
          f.app,
          currentGit: f.git,
          receipt: receipt,
          authorize: (frozen, currentGit) async {
            authorizations++;
            expect(frozen.encode(), receipt.encode());
            expect(currentGit.head, f.git.head);
            expect(restarted(f.app), same(baseline));
            return StageDependencies.fromJson(
              frozen.plan!['dependency_inputs'],
            );
          },
        );
        expect(authorizations, 1);
        expect(restored.directory.identity.id, receipt.identity.id);
        expect(restarted(f.app), same(restored));
        expect(
          restarted.refresh(f.app, f.git).directory.identity.id,
          receipt.identity.id,
        );
        expect(
          stage.directory.fingerprint(),
          before,
          reason: 'adoption cannot clean or materialize bytes',
        );
        if (state == 'header' || state == 'source residue') {
          expect(restored.inspect().canRestartSource, isTrue);
          expect(restored.requireProducerProgress, throwsStateError);
        } else if (state == 'pending output') {
          expect(restored.requireProducerProgress().steps.map((s) => s.name), [
            'source-snapshot',
          ]);
        }
      },
    );
  }

  for (final failure in [
    'native authorization',
    'new selection',
    'Git',
    'toolchain',
    'contract',
    'receipt',
    'receipt progress',
    'artifact',
  ]) {
    test('$failure rejection preserves the current resolver binding', () async {
      final stage = f.stages.bindDependencies(f.app, externalDependencies());
      await f.complete(stage, 'complete consumer');
      final receipt = stage.requireReceipt();
      var compilerDigest = 'a';
      final restarted = f.resolver(
        compilerDigest: () => compilerDigest,
        changedContract: failure == 'contract',
      );
      final baseline = restarted.bindDependencies(
        f.app,
        StageDependencies(
          contexts: [
            f.context([], native: {'fixture': 'previous'}),
          ],
        ),
      );
      final before = CanonicalJson.encode(baseline.dependencies.toJson());
      await expectLater(
        restarted.adoptFrozen(
          f.app,
          currentGit: failure == 'Git' ? f.gitAt(head: '3' * 40) : f.git,
          receipt: receipt,
          authorize: (frozen, currentGit) async {
            switch (failure) {
              case 'native authorization':
                throw StateError('fixture native authorization rejected');
              case 'new selection':
                return StageDependencies();
              case 'toolchain':
                compilerDigest = 'c';
              case 'receipt':
                File(
                  stage.directory.resolve('stage.json'),
                ).writeAsStringSync('{}\n');
              case 'receipt progress':
                StageReceiptStore(stage.directory).write(
                  StageReceipt(
                    identity: frozen.identity,
                    plan: frozen.plan,
                    steps: frozen.steps.take(1),
                  ),
                );
              case 'artifact':
                File(
                  stage.directory.resolve('app.pkg'),
                ).writeAsStringSync('changed consumer');
            }
            return StageDependencies.fromJson(
              frozen.plan!['dependency_inputs'],
            );
          },
        ),
        throwsStateError,
      );
      expect(restarted(f.app), same(baseline));
      expect(
        CanonicalJson.encode(restarted(f.app).dependencies.toJson()),
        before,
      );
      expect(
        restarted.refresh(f.app, f.git).dependencies.toJson(),
        baseline.dependencies.toJson(),
      );
    });
  }

  test('slow authorization cannot overwrite a newer binding', () async {
    final stage = f.stages.bindDependencies(f.app, externalDependencies());
    await f.complete(stage, 'complete consumer');
    final restarted = f.resolver();
    final started = Completer<void>();
    final continueAuthorization = Completer<void>();
    final adopting = restarted.adoptFrozen(
      f.app,
      currentGit: f.git,
      receipt: stage.requireReceipt(),
      authorize: (frozen, currentGit) async {
        started.complete();
        await continueAuthorization.future;
        return StageDependencies.fromJson(frozen.plan!['dependency_inputs']);
      },
    );
    final refused = expectLater(
      adopting,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'binding generation',
          contains('stage binding changed'),
        ),
      ),
    );
    await started.future;
    final newer = restarted.bindDependencies(
      f.app,
      StageDependencies(
        contexts: [
          f.context([], native: {'fixture': 'newer'}),
        ],
      ),
    );
    continueAuthorization.complete();
    await refused;
    expect(restarted(f.app), same(newer));
    expect(
      restarted.refresh(f.app, f.git).directory.identity.id,
      newer.directory.identity.id,
    );
  });

  test(
    'file at source root refuses adoption without changing the binding',
    () async {
      final stage = f.stages.bindDependencies(f.app, externalDependencies());
      stage.writeProgress(const []);
      stage.directory.writeBytesAtomically(
        'source',
        utf8.encode('not a directory'),
      );
      final receipt = StageReceiptStore(stage.directory).read()!;
      final before = stage.directory.fingerprint();
      final restarted = f.resolver();
      final baseline = restarted(f.app);
      expect(stage.inspect().canRestartSource, isFalse);
      await expectLater(
        restarted.adoptFrozen(
          f.app,
          currentGit: f.git,
          receipt: receipt,
          authorize: (frozen, _) async =>
              StageDependencies.fromJson(frozen.plan!['dependency_inputs']),
        ),
        throwsStateError,
      );
      expect(restarted(f.app), same(baseline));
      expect(
        restarted.refresh(f.app, f.git).directory.identity.id,
        baseline.directory.identity.id,
      );
      expect(stage.directory.fingerprint(), before);
    },
  );

  test(
    'coordinator imports before invoking the consuming native producer',
    () async {
      final provider = f.stages(f.core);
      await f.complete(provider, 'provider payload');
      final imported = f.import(provider);
      final external = f.external();
      final context = f.context([f.binding(imported.use), external.binding]);
      final stage = f.stages.bindDependencies(
        f.app,
        StageDependencies(
          imports: [imported],
          external: [external],
          contexts: [context],
        ),
      );
      final buffer = StringBuffer();
      final output = Output(sink: buffer.write, isTerminal: false);
      final coordinator = ReleaseStageCoordinator(
        initialGit: f.git,
        output: output,
        refreshGit: () async => f.git,
        refreshStage: f.stages.refresh,
        tools: _NoTools(),
        capabilities: HostCapabilities(
          hostPlatform: 'linux-x64',
          containerRuntime: null,
          hasNativeAssets: false,
        ),
        stageFor: f.stages.call,
        stageOnly: true,
      );
      final target = TargetPlan(
        label: 'Fixture',
        kindLabel: 'Fixture',
        identity: 'app',
        coordinate: 'app@release:green',
        targetVersion: 'release:green',
        planNote: 'native package',
        artifacts: const [],
        project: f.app.projects.single,
        step: Step(
          id: 'app/package',
          kind: StepKind.publishRegistry,
          unit: 'app',
          summary: 'publish fixture',
          needs: const [],
          target: PublishTarget.pubDev,
        ),
      );
      var productions = 0;
      final targetStage = TargetStage(
        target: target,
        planLabel: 'fixture package',
        contract: stage.targetContributions.single,
        prepare: (context) async {
          productions++;
          expect(context.contract.step.inputs, contains(imported.archive.path));
          expect(context.contract.step.inputs, contains(external.archive.path));
          expect(
            File(
              stage.directory.resolve(external.archive.path),
            ).readAsStringSync(),
            'published payload',
          );
          expect(context.stage.inspect().validProgress, isTrue);
          expect(
            context.priorSteps.map((step) => step.name),
            contains('dependency-inputs'),
          );
          final dependency = context.stage.requireProducerArtifact(
            producer: StageDependencies.importProducer,
            path: imported.archive.path,
            type: imported.archive.type,
          );
          expect(
            File(stage.directory.resolve(dependency.path)).readAsStringSync(),
            'provider payload',
          );
          return TargetStageSuccess(
            f.output(stage, 'app', 'built consumer', context.priorSteps),
          );
        },
      );
      for (var run = 0; run < 2; run++) {
        final prepared = await coordinator.prepare(
          unit: f.app,
          checklist: Checklist(
            unit: f.app,
            steps: [
              Step(
                id: 'app/stage/complete',
                kind: StepKind.completeStage,
                unit: 'app',
                summary: 'complete stage',
                needs: const [],
              ),
            ],
          ),
          targets: [target],
          targetStages: [targetStage],
          stage: stage,
          inspected: stage.inspect(),
          claims: const [],
        );
        expect(prepared, isNotNull, reason: buffer.toString());
        expect(stage.inspect().reusable, isTrue);
      }
      expect(productions, 1);
    },
  );

  test(
    'portable consumer survives provider cleanup and resolver restart',
    () async {
      final provider = f.stages(f.core);
      await f.complete(provider, 'verified provider bytes');
      final imported = f.import(provider);
      final dependencies = StageDependencies(imports: [imported]);
      final consumer = f.stages.bindDependencies(f.app, dependencies);
      await f.complete(consumer, 'consumer bytes');

      expect(consumer.producerDependencies('native:app'), {
        StageDependencies.importProducer,
        'source-snapshot',
      });
      final input = consumer
          .requireReceipt()
          .steps
          .singleWhere((step) => step.name == 'native:app')
          .inputs
          .singleWhere((input) => input.name == imported.archive.path);
      expect(input.sha256, imported.original.sha256);
      expect(
        File(
          consumer.directory.resolve(imported.archive.path),
        ).readAsStringSync(),
        'verified provider bytes',
      );
      expect(
        CanonicalJson.encode(dependencies.toJson()),
        isNot(contains(f.root.path)),
      );
      expect(imported.use.provider.version, 'release:blue');

      Directory(provider.directory.path).deleteSync(recursive: true);
      final restored = StageDependencies.fromJson(
        jsonDecode(jsonEncode(dependencies.toJson())),
      );
      final fresh = await f.resolver().adoptFrozen(
        f.app,
        currentGit: f.git,
        receipt: consumer.requireReceipt(),
        authorize: (_, _) async => restored,
      );
      expect(fresh.directory.identity.id, consumer.directory.identity.id);
      expect(fresh.inspect().issues, isEmpty);
      expect(fresh.inspect().reusable, isTrue);
      expect(
        f.stages.refresh(f.app, f.git).directory.identity.id,
        consumer.directory.identity.id,
      );
    },
  );

  test(
    'changed dependency bytes produce a different consumer identity',
    () async {
      final provider = f.stages(f.core);
      await f.complete(provider, 'first');
      final first = f.stages.bindDependencies(
        f.app,
        StageDependencies(imports: [f.import(provider)]),
      );
      provider.reset();
      await f.complete(provider, 'second');
      final second = f.stages.bindDependencies(
        f.app,
        StageDependencies(imports: [f.import(provider)]),
      );
      expect(second.directory.identity.id, isNot(first.directory.identity.id));
      expect(f.stages(f.app), same(second));
      expect(
        f.stages.refresh(f.app, f.git).directory.identity.id,
        second.directory.identity.id,
      );
    },
  );

  test(
    'rebinding restored declarations refreshes provider handles without changing identity',
    () async {
      final provider = f.stages(f.core);
      await f.complete(provider, 'provider');
      final acquired = StageDependencies(imports: [f.import(provider)]);
      final restored = StageDependencies.fromJson(acquired.toJson());
      final unavailable = f.stages.bindDependencies(f.app, restored);
      final source = await f.start(unavailable);
      expect(
        () =>
            unavailable.dependencies.materialize(unavailable.directory, source),
        throwsStateError,
      );
      final repaired = f.stages.bindDependencies(f.app, acquired);
      expect(repaired.directory.identity.id, unavailable.directory.identity.id);
      final imported = repaired.dependencies.materialize(
        repaired.directory,
        source,
      );
      repaired.writeProgress([source, imported]);
      expect(repaired.inspect().validProgress, isTrue);
      expect(f.stages(f.app), same(repaired));
    },
  );

  test(
    'provider completion, owner and producer contract are required',
    () async {
      final provider = f.stages(f.core);
      await f.start(provider);
      expect(() => f.import(provider), throwsStateError);
      await f.finish(provider, 'provider');
      expect(() => f.import(provider, unit: 'app'), throwsStateError);
      expect(() => f.import(provider, project: 'unknown'), throwsStateError);
      expect(
        () => ImportedStageDependency.fromProvider(
          use: f.use(),
          provider: provider,
          path: 'core.pkg',
          type: 'wrong-type',
        ),
        throwsStateError,
      );
      expect(
        () => f.import(provider, producer: 'source-snapshot'),
        throwsStateError,
      );
    },
  );

  test('provider tampering after selection cannot become an import', () async {
    final provider = f.stages(f.core);
    await f.complete(provider, 'provider');
    final imported = f.import(provider);
    final consumer = f.stages.bindDependencies(
      f.app,
      StageDependencies(imports: [imported]),
    );
    final source = await f.start(consumer);
    File(provider.directory.resolve('core.pkg')).writeAsStringSync('tampered');
    expect(
      () => consumer.dependencies.materialize(consumer.directory, source),
      throwsStateError,
    );
    expect(
      File(consumer.directory.resolve(imported.archive.path)).existsSync(),
      isFalse,
    );
  });

  test(
    'self-consistent rewritten receipt cannot replace frozen input bytes',
    () async {
      final provider = f.stages(f.core);
      await f.complete(provider, 'provider');
      final imported = f.import(provider);
      final consumer = f.stages.bindDependencies(
        f.app,
        StageDependencies(imports: [imported]),
      );
      await f.complete(consumer, 'consumer');
      _rewrite(consumer, imported.archive.path, 'forged dependency');
      expect(consumer.inspect().reusable, isFalse);
      expect(
        consumer.inspect().issues.map((issue) => issue.message),
        contains('dependency input differs from the frozen release plan'),
      );
    },
  );

  test('missing import or forged provider proof refuses reuse', () async {
    final provider = f.stages(f.core);
    await f.complete(provider, 'provider');
    final imported = f.import(provider);
    final consumer = f.stages.bindDependencies(
      f.app,
      StageDependencies(imports: [imported]),
    );
    await f.complete(consumer, 'consumer');
    _rewrite(consumer, imported.proof.path, '{}\n');
    expect(consumer.inspect().reusable, isFalse);
    expect(
      consumer.inspect().issues.any(
        (issue) => issue.message.contains('provider proof is invalid'),
      ),
      isTrue,
    );
    File(consumer.directory.resolve(imported.archive.path)).deleteSync();
    expect(consumer.inspect().reusable, isFalse);
  });

  test(
    'same-unit handoff uses verified producer output before completion',
    () async {
      f.close();
      f = _Fixture(appVersion: '0.2.0');
      final unit = ResolvedUnit(
        name: 'bundle',
        publish: const {},
        tagPattern: null,
        tagWasDeclared: false,
        homebrewTap: null,
        projects: [...f.core.projects, ...f.app.projects],
        location: f.core.location,
      );
      final dependency = LocalStageDependency(
        use: f.use(unit: 'bundle'),
        path: 'core.pkg',
        type: 'fixture-package',
      );
      final stage = f.stages.bindDependencies(
        unit,
        StageDependencies(local: [dependency]),
      );
      final identity = stage.directory.identity.id;
      final source = await f.start(stage);
      expect(
        () => stage.requireProducerArtifact(
          producer: 'native:core',
          path: 'core.pkg',
          type: 'fixture-package',
        ),
        throwsStateError,
      );
      final provider = f.output(stage, 'core', 'core from package', [source]);
      stage.writeProgress([source, provider]);
      expect(stage.inspect().validProgress, isTrue);
      // A concurrent consumer has started writing its declared output. The
      // recorded provider remains readable, without adopting pending bytes or
      // weakening restart/publication inspection of the whole stage.
      stage.directory.writeBytesAtomically('app.pkg', utf8.encode('in flight'));
      expect(stage.inspect().validProgress, isFalse);
      final artifact = stage.requireProducerArtifact(
        producer: 'native:core',
        path: 'core.pkg',
        type: 'fixture-package',
      );
      expect(
        () => stage.requireProducerArtifact(
          producer: 'native:app',
          path: 'app.pkg',
          type: 'fixture-package',
        ),
        throwsStateError,
      );
      stage.directory.writeBytesAtomically(
        'unknown.pkg',
        utf8.encode('unowned'),
      );
      expect(stage.requireProducerProgress, throwsStateError);
      File(stage.directory.resolve('unknown.pkg')).deleteSync();
      expect(stage.producerDependencies('native:app'), {
        'source-snapshot',
        'native:core',
      });
      final consumer = f.output(
        stage,
        'app',
        'app built from ${artifact.sha256}',
        [source, provider],
      );
      expect(consumer.inputs.map((input) => input.name), contains('core.pkg'));
      expect(
        consumer.inputs.singleWhere((input) => input.name == 'core.pkg').sha256,
        artifact.sha256,
      );
      stage.writeProgress([source, provider, consumer]);
      stage.finalize(releaseAssets: const []);
      expect(stage.inspect().reusable, isTrue);
      expect(stage.directory.identity.id, identity);
    },
  );

  test(
    'artifact uses preserve separate native slots and opaque versions',
    () async {
      final provider = f.stages(f.core);
      await f.complete(provider, 'provider');
      final a = f.import(provider);
      final b = ImportedStageDependency.fromProvider(
        use: f.use(slot: 'nested/core'),
        provider: provider,
        path: 'core.pkg',
        type: 'fixture-package',
      );
      final deps = StageDependencies(imports: [b, a]);
      expect(deps.imports.map((i) => i.archive.path).toSet().length, 2);
      expect(
        CanonicalJson.encode(deps.toJson()),
        CanonicalJson.encode(StageDependencies(imports: [a, b]).toJson()),
      );
      expect(() => StageDependencies(imports: [a, a]), throwsArgumentError);
    },
  );

  test(
    'unknown consumers and circular local declarations are rejected',
    () async {
      final provider = f.stages(f.core);
      await f.complete(provider, 'provider');
      final imported = ImportedStageDependency.fromProvider(
        use: f.use(consumers: ['not-a-producer']),
        provider: provider,
        path: 'core.pkg',
        type: 'fixture-package',
      );
      final stage = f.stages.bindDependencies(
        f.app,
        StageDependencies(imports: [imported]),
      );
      expect(() => stage.producerNames, throwsStateError);
      final self = f.stages.bindDependencies(
        f.core,
        StageDependencies(
          local: [
            LocalStageDependency(
              use: f.use(consumers: ['native:core']),
              path: 'core.pkg',
              type: 'fixture-package',
            ),
          ],
        ),
      );
      expect(() => self.producerNames, throwsStateError);
    },
  );

  test('serialized path, digest and declaration changes fail closed', () async {
    final provider = f.stages(f.core);
    await f.complete(provider, 'provider');
    final dependencies = StageDependencies(imports: [f.import(provider)]);
    for (final mutate in <void Function(Map)>[
      (json) => ((json['imports'] as List).single['archive'] as Map)['path'] =
          'source/pubspec.yaml',
      (json) => ((json['imports'] as List).single['archive'] as Map)['sha256'] =
          'f' * 64,
      (json) => (json['imports'] as List).single['unexpected'] = true,
    ]) {
      final json = jsonDecode(jsonEncode(dependencies.toJson())) as Map;
      mutate(json);
      expect(() => StageDependencies.fromJson(json), throwsFormatException);
    }
  });

  test(
    'native context data is immutable and affects even an archive-free stage identity',
    () {
      final data = <String, Object?>{
        'graph': <String, Object?>{'choice': 'original'},
      };
      final context = f.context([], native: data);
      final before = StageDependencies(contexts: [context]);
      final first = f.stages.bindDependencies(f.app, before);
      (data['graph'] as Map)['choice'] = 'changed';
      (context.native['graph'] as Map)['choice'] = 'mutated through getter';
      expect((context.native['graph'] as Map)['choice'], 'original');
      expect(before.isEmpty, isFalse);
      expect(before.hasImports, isFalse);
      final restored = StageDependencies.fromJson(before.toJson());
      expect(
        f.resolver().bindDependencies(f.app, restored).directory.identity.id,
        first.directory.identity.id,
      );
      final changed = f.stages.bindDependencies(
        f.app,
        StageDependencies(contexts: [f.context([], native: data)]),
      );
      expect(changed.directory.identity.id, isNot(first.directory.identity.id));
    },
  );

  test(
    'external archive survives restore and rejects a self-consistent forged receipt',
    () async {
      final external = f.external();
      final dependencies = StageDependencies(
        external: [external],
        contexts: [
          f.context([external.binding]),
        ],
      );
      final stage = f.stages.bindDependencies(f.app, dependencies);
      await f.complete(stage, 'consumer');
      final restored = f.resolver().bindDependencies(
        f.app,
        StageDependencies.fromJson(dependencies.toJson()),
      );
      expect(restored.directory.identity.id, stage.directory.identity.id);
      expect(
        restored.inspect().reusable,
        isTrue,
        reason: 'existing copies need no expired download handle',
      );
      _rewrite(stage, external.archive.path, 'forged external payload');
      expect(restored.inspect().reusable, isFalse);
    },
  );

  test(
    'external bytes freeze before materialization and handles can be reacquired',
    () async {
      final bytes = utf8.encode('published payload');
      final selected = f.external();
      final input = ExternalStageDependency.fromBytes(
        context: selected.context,
        binding: selected.binding,
        consumers: selected.consumers,
        bytes: bytes,
        expectedSha256: Sha256.hex(bytes),
      );
      bytes[0] = 0;
      final dependencies = StageDependencies(
        external: [input],
        contexts: [
          f.context([input.binding]),
        ],
      );
      final restored = f.stages.bindDependencies(
        f.app,
        StageDependencies.fromJson(dependencies.toJson()),
      );
      final source = await f.start(restored);
      expect(
        () => restored.dependencies.materialize(restored.directory, source),
        throwsStateError,
      );
      final rebound = f.stages.bindDependencies(f.app, dependencies);
      expect(rebound.directory.identity.id, restored.directory.identity.id);
      final imported = rebound.dependencies.materialize(
        rebound.directory,
        source,
      );
      rebound.writeProgress([source, imported]);
      expect(
        File(rebound.directory.resolve(input.archive.path)).readAsStringSync(),
        'published payload',
      );
      expect(
        () => ExternalStageDependency.fromBytes(
          context: input.context,
          binding: input.binding,
          consumers: input.consumers,
          bytes: [0],
          expectedSha256: input.archive.sha256,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'native coverage rejects missing, extra, conflicting slots and wrong consumers',
    () {
      final external = f.external();
      final context = f.context([external.binding]);
      for (final build in <StageDependencies Function()>[
        () => StageDependencies(contexts: [context]),
        () =>
            StageDependencies(external: [external], contexts: [f.context([])]),
        () => StageDependencies(external: [external]),
        () => StageDependencies(
          external: [external, external],
          contexts: [context],
        ),
        () => StageDependencies(
          external: [external],
          contexts: [context, context],
        ),
        () => StageDependencies(
          external: [external],
          contexts: [
            f.context([external.binding], name: 'other'),
          ],
        ),
        () => StageDependencies(
          external: [external],
          contexts: [
            f.context([external.binding], consumers: ['unknown']),
          ],
        ),
        () => StageDependencies(
          external: [external],
          contexts: [
            f.context([
              NativeStageBinding(
                slot: external.binding.slot,
                package: external.binding.package,
                version: 'other-version',
              ),
            ]),
          ],
        ),
      ]) {
        expect(build, throwsArgumentError);
      }
      final wrongOwner = f.stages.bindDependencies(
        f.app,
        StageDependencies(
          external: [external],
          contexts: [
            f.context([external.binding], owner: 'core'),
          ],
        ),
      );
      expect(() => wrongOwner.producerNames, throwsStateError);
      final unknownConsumer = f.stages.bindDependencies(
        f.app,
        StageDependencies(
          contexts: [
            f.context([], consumers: ['unknown']),
          ],
        ),
      );
      expect(() => unknownConsumer.producerNames, throwsStateError);
    },
  );
}

void _rewrite(ReleaseStage stage, String path, String bytes) {
  final previous = stage.requireReceipt();
  File(stage.directory.resolve(path)).writeAsStringSync(bytes);
  final rewritten = <StageStep>[];
  for (final step in previous.steps) {
    final inputHashes = {
      for (final prior in rewritten) 'step:${prior.name}': prior.outputSha256,
      for (final prior in rewritten)
        for (final artifact in prior.outputs) artifact.path: artifact.sha256,
    };
    rewritten.add(
      StageStep(
        name: step.name,
        evidence: step.evidence,
        inputs: [
          for (final input in step.inputs)
            StageInput(
              name: input.name,
              sha256: inputHashes[input.name] ?? input.sha256,
            ),
        ],
        outputs: [
          for (final artifact in step.outputs)
            if (artifact.path == path)
              StageArtifact.capture(
                stage: stage.directory,
                path: path,
                type: artifact.type,
              )
            else
              artifact,
        ],
      ),
    );
  }
  StageReceiptStore(stage.directory).write(
    StageReceipt(
      identity: previous.identity,
      plan: previous.plan,
      steps: rewritten,
    ),
  );
}

final class _Fixture {
  _Fixture({String appVersion = '0.1.0', bool binaryOnly = false}) {
    if (binaryOnly) {
      source.files['release.toml'] = source.files['release.toml']!.replaceFirst(
        '[release.app]\npath = "app"\npublish = ["pub.dev"]',
        '[release.app]\npath = "app"\npublish = ["git-tag", "github-release"]\nbinary_platforms = ["linux-x64"]',
      );
      source.files['app/pubspec.yaml'] =
          '${source.files['app/pubspec.yaml']}publish_to: none\nexecutables:\n  app: app\n';
      source.files['app/bin/app.dart'] = 'void main() {}\n';
    }
    source.files['app/pubspec.yaml'] = source.files['app/pubspec.yaml']!
        .replaceFirst('0.1.0', appVersion);
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse(
      source.files['release.toml']!,
      'release.toml',
      diagnostics,
    )!;
    resolution = Resolution.resolve(config, source, diagnostics)!;
    expect(diagnostics.isEmpty, isTrue);
    stages = resolver();
  }

  final root = Directory.systemTemp.createTempSync('rk-dependency-receipts-');
  final source = MemorySourceTree({
    'release.toml': '''
schema = 2
[release.core]
path = "core"
publish = ["pub.dev"]
[release.app]
path = "app"
publish = ["pub.dev"]
''',
    'core/pubspec.yaml':
        'name: core\nversion: 0.2.0\nenvironment:\n  sdk: ^3.10.4\n',
    'app/pubspec.yaml':
        'name: app\nversion: 0.1.0\nenvironment:\n  sdk: ^3.10.4\n',
  });
  late final Resolution resolution;
  late final ReleaseStages stages;
  ResolvedUnit get core => resolution.unit('core')!;
  ResolvedUnit get app => resolution.unit('app')!;
  GitState get git => gitAt();
  GitState gitAt({String? head}) => GitState(
    root: root.path,
    head: head ?? '1' * 40,
    headTree: '2' * 40,
    branch: 'main',
    isClean: true,
    uncommitted: const [],
    headIsPushed: true,
    tags: const [],
    signingConfigured: false,
    originUrl: 'example/repository',
  );

  ReleaseStages resolver({
    String Function()? compilerDigest,
    bool changedContract = false,
  }) => ReleaseStages(
    source: source,
    git: git,
    stageContracts:
        ({required unit, required repository, required sourceRoot}) => [
          for (final project in unit.projects)
            StageContributionContract(
              step: StageStepContract(
                'native:${project.name}',
                inputs: const {'step:source-snapshot'},
                outputs: {
                  '${project.name}${changedContract ? '.different' : ''}.pkg':
                      'fixture-package',
                },
              ),
            ),
        ],
    compilerIdentity: () => DartCompilerIdentity.recorded(
      executable: '/sdk/dart',
      version: 'fixture',
      sha256: (compilerDigest?.call() ?? 'a') * 64,
    ),
    rkIdentity: () => RkImplementationIdentity.recorded(
      version: '0.1.0',
      stageSchema: stageSchemaVersion,
      sha256: 'b' * 64,
    ),
  );

  NativeArtifactUse use({
    String unit = 'core',
    String project = 'core',
    String producer = 'native:core',
    String slot = 'core',
    List<String> consumers = const ['native:app'],
  }) => NativeArtifactUse(
    context: 'app/hosted-bridge',
    slot: slot,
    consumers: consumers,
    provider: NativeCandidate(
      package: const NativePackage(
        ecosystem: 'fixture',
        source: 'fixture-registry',
        name: 'scope/core',
      ),
      version: 'release:blue',
      unit: unit,
      project: project,
      producer: producer,
    ),
  );

  ImportedStageDependency import(
    ReleaseStage provider, {
    String unit = 'core',
    String project = 'core',
    String producer = 'native:core',
  }) => ImportedStageDependency.fromProvider(
    use: use(unit: unit, project: project, producer: producer),
    provider: provider,
    path: 'core.pkg',
    type: 'fixture-package',
  );

  NativeStageBinding binding(NativeArtifactUse use) => NativeStageBinding(
    slot: use.slot,
    package: use.provider.package,
    version: use.provider.version,
    provider: use.provider,
  );

  NativeStageContext context(
    List<NativeStageBinding> bindings, {
    String name = 'app/hosted-bridge',
    String owner = 'app',
    List<String> consumers = const ['native:app'],
    Map<String, Object?> native = const {'fixture': 'selected'},
  }) => NativeStageContext(
    context: name,
    ecosystem: 'fixture',
    owner: owner,
    format: 1,
    consumers: consumers,
    bindings: bindings,
    native: native,
  );

  ExternalStageDependency external() {
    final bytes = utf8.encode('published payload');
    return ExternalStageDependency.fromBytes(
      context: 'app/hosted-bridge',
      binding: NativeStageBinding(
        slot: 'nested/remote-slot',
        package: const NativePackage(
          ecosystem: 'fixture',
          source: 'remote-registry',
          name: 'remote/package',
        ),
        version: 'release:published',
      ),
      consumers: ['native:app'],
      bytes: bytes,
      expectedSha256: Sha256.hex(bytes),
    );
  }

  Future<StageStep> start(ReleaseStage stage) async {
    final artifacts = await stage.materializeSource();
    final step = StageStep(
      name: 'source-snapshot',
      inputs: [
        StageInput.commit(stage.directory.identity),
        StageInput.tree(stage.directory.identity),
        StageInput.plan(stage.directory.identity),
      ],
      outputs: artifacts,
      evidence: {'commit': git.head, 'tree': git.headTree},
    );
    stage.writeProgress([step]);
    return step;
  }

  StageStep output(
    ReleaseStage stage,
    String project,
    String bytes,
    List<StageStep> prior,
  ) {
    final path = '$project.pkg';
    stage.directory.writeBytesAtomically(path, utf8.encode(bytes));
    return StageStep(
      name: 'native:$project',
      inputs: stage.producerInputs('native:$project', prior),
      outputs: [
        StageArtifact.capture(
          stage: stage.directory,
          path: path,
          type: 'fixture-package',
        ),
      ],
    );
  }

  Future<void> finish(ReleaseStage stage, String bytes) async {
    final prior = StageReceiptStore(stage.directory).read()!.steps.toList();
    if (stage.dependencies.hasImports) {
      prior.add(stage.dependencies.materialize(stage.directory, prior.first));
      stage.writeProgress(prior);
    }
    prior.add(output(stage, stage.unit.projects.single.name, bytes, prior));
    stage.writeProgress(prior);
    stage.finalize(releaseAssets: const []);
    expect(stage.inspect().issues, isEmpty);
  }

  Future<void> complete(ReleaseStage stage, String bytes) async {
    await start(stage);
    await finish(stage, bytes);
  }

  void close() => root.deleteSync(recursive: true);
}

final class _NoTools implements Tools {
  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async => throw StateError(
    'unexpected native/public command: $executable $arguments',
  );
  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async => throw StateError('unexpected publication session');
}
