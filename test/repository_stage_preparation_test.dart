import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/native_dependencies.dart';
import 'package:rk/src/engine/native_stage_context.dart';
import 'package:rk/src/engine/native_stage_discovery.dart';
import 'package:rk/src/engine/release_stage.dart';
import 'package:rk/src/engine/repository_stage_preparation.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/engine/stage_contract.dart';
import 'package:rk/src/engine/stage_dependencies.dart';
import 'package:rk/src/engine/stage_plan.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:test/test.dart';

void main() {
  late RepositoryStageFixture f;
  setUp(() => f = RepositoryStageFixture());
  tearDown(() => f.root.deleteSync(recursive: true));

  test(
    'restores before eligibility and discovers the full scope before binding',
    () async {
      f.needs('app', 'app', [('core', 'nested/one'), ('core', 'nested/two')]);
      final plan = await f.resolve(['app', 'core', 'third']);
      expect(f.events, [
        'restore:app',
        'restore:core',
        'restore:third',
        'eligibility',
        'discover:app',
        'discover:core',
        'discover:third',
      ]);
      expect(plan.order.map((unit) => unit.name), ['core', 'app', 'third']);
      expect(Directory('${f.root.path}/.rk').existsSync(), isFalse);
      final core = await plan.bind(f.unit('core'));
      await f.complete(core);
      final app = await plan.bind(f.unit('app'));
      expect(app.dependencies.imports.map((i) => i.use.slot), [
        'nested/one',
        'nested/two',
      ]);
      expect(
        app.dependencies.imports.every(
          (i) => i.use.provider.version == 'release:core',
        ),
        isTrue,
      );
      expect(f.unit('core').version.canonical, '0.2.0');
      expect(f.unit('app').version.canonical, '0.1.0');
      await f.complete(app);
      for (final input in app.dependencies.imports) {
        expect(
          File(app.directory.resolve(input.archive.path)).readAsStringSync(),
          'core artifact',
        );
      }
      expect(() => plan.order.clear(), throwsUnsupportedError);
    },
  );

  test(
    'authenticated public recovery does not discover or offer a provider',
    () async {
      f.withoutPreparation.add('app');
      f.eligible.removeWhere((candidate) => candidate.unit == 'app');
      f.failDiscovery = 'app';
      final plan = await f.resolve(['app']);
      expect(plan.withoutPreparation, {'app'});
      final stage = f.stages(f.unit('app'));
      expect(await plan.bind(f.unit('app')), same(stage));
      expect(f.events, ['restore:app', 'eligibility']);
      expect(Directory('${f.root.path}/.rk').existsSync(), isFalse);
    },
  );

  test(
    'public recovery cannot authorize an outside unit or private candidate',
    () async {
      f.withoutPreparation.add('third');
      await expectLater(f.resolve(['app']), throwsStateError);
      f.withoutPreparation
        ..clear()
        ..add('app');
      await expectLater(f.resolve(['app']), throwsStateError);
      expect(f.events.where((event) => event.startsWith('discover:')), isEmpty);
    },
  );

  test(
    'late discovery failure leaves all bindings and stages untouched',
    () async {
      final before = f.stages(f.unit('app'));
      f.failDiscovery = 'third';
      await expectLater(f.resolve(['app', 'third']), throwsStateError);
      expect(f.stages(f.unit('app')), same(before));
      expect(Directory('${f.root.path}/.rk').existsSync(), isFalse);
    },
  );

  test(
    'one native package may occupy separate slots at different opaque versions',
    () async {
      f.samePackageIdentity = true;
      f.eligible = f.configuredCandidates();
      f.needs('app', 'app', [('core', 'nested/one'), ('third', 'nested/two')]);
      final plan = await f.resolve(['app', 'core', 'third']);
      for (final unit in plan.order) {
        await f.complete(await plan.bind(unit));
      }
      final imports = f.stages(f.unit('app')).dependencies.imports;
      expect(imports.map((i) => i.use.provider.package).toSet(), hasLength(1));
      expect(imports.map((i) => i.use.provider.version).toSet(), {
        'release:core',
        'release:third',
      });
      expect(imports.map((i) => i.use.slot).toSet(), {
        'nested/one',
        'nested/two',
      });
    },
  );

  for (final invalid in [
    'path',
    'type',
    'consumer',
    'owner',
    'provider',
    'source-snapshot',
    'complete-stage',
  ]) {
    test('invalid $invalid is rejected before any producer runs', () async {
      f.needs('app', 'app', [('core', 'core')], invalid: invalid);
      await expectLater(f.resolve(['app', 'core']), throwsStateError);
      expect(Directory('${f.root.path}/.rk').existsSync(), isFalse);
    });
  }

  test(
    'discovery cannot introduce an ecosystem outside its authority',
    () async {
      f.discoveries['app'] = DiscoveredNativeStage(
        contexts: [
          NativeStageContext(
            context: 'foreign',
            ecosystem: 'foreign',
            owner: 'app',
            format: 1,
            consumers: ['native:app'],
            bindings: const [],
            native: const {},
          ),
        ],
      );
      await expectLater(f.resolve(['app', 'core']), throwsStateError);
      expect(Directory('${f.root.path}/.rk').existsSync(), isFalse);
    },
  );

  test('actual producer cycle is diagnosed before unit grouping', () async {
    f.needs('app', 'app', [('core', 'core')]);
    f.needs('core', 'core', [('app', 'app')]);
    await expectLater(
      f.resolve(['app', 'core']),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('dependency cycle'), isNot(contains('interleaved'))),
        ),
      ),
    );
  });

  test(
    'acyclic producer graph with cyclic unit grouping is explicit',
    () async {
      final grouped = RepositoryStageFixture(grouped: true);
      addTearDown(() => grouped.root.deleteSync(recursive: true));
      grouped.needs('core', 'core', [('app', 'app')]);
      grouped.needs('app', 'app', [('helper', 'helper')]);
      await expectLater(
        grouped.resolve(['core', 'app']),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('interleaved release units'),
          ),
        ),
      );
    },
  );

  test(
    'same-unit requests bind producer outputs without import identity cycles',
    () async {
      final grouped = RepositoryStageFixture(grouped: true);
      addTearDown(() => grouped.root.deleteSync(recursive: true));
      grouped.needs('core', 'core', [('helper', 'helper')]);
      final plan = await grouped.resolve(['core']);
      final stage = await plan.bind(grouped.unit('core'));
      expect(stage.dependencies.imports, isEmpty);
      expect(stage.dependencies.local.single.use.provider.project, 'helper');
      expect(
        stage.producerDependencies('native:core'),
        contains('native:helper'),
      );
      await grouped.complete(stage);
    },
  );

  test(
    'named scope requires a completed authorized outside provider',
    () async {
      f.needs('app', 'app', [('core', 'core')]);
      await expectLater(f.resolve(['app']), throwsStateError);
      final provider = f.bindEmpty('core');
      provider.writeProgress(const []);
      expect(() => PreparedStageProvider.capture(provider), throwsStateError);
      await f.complete(provider);
      f.providers.add(PreparedStageProvider.capture(provider));
      final plan = await f.resolve(['app']);
      expect(plan.order.map((u) => u.name), ['app']);
      final fingerprint = provider.directory.fingerprint();
      final app = await plan.bind(f.unit('app'));
      expect(
        app.dependencies.imports.single.providerIdentity.id,
        provider.directory.identity.id,
      );
      expect(provider.directory.fingerprint(), fingerprint);
      expect(f.events.where((e) => e == 'discover:core'), isEmpty);
    },
  );

  test(
    'completed restored provider is satisfied without an artificial wait',
    () async {
      final provider = f.bindEmpty('core');
      await f.complete(provider);
      f.restored['core'] = provider;
      f.needs('app', 'app', [('core', 'core')]);
      final plan = await f.resolve(['app', 'core']);
      expect(plan.order.map((u) => u.name), ['app', 'core']);
      expect(
        (await plan.bind(f.unit('app'))).dependencies.imports,
        hasLength(1),
      );
      expect(f.events, isNot(contains('discover:core')));
    },
  );

  test(
    'incomplete restored provider finishes before fresh consumer can bind',
    () async {
      final provider = f.bindEmpty('core');
      provider.writeProgress(const []);
      f.restored['core'] = provider;
      f.needs('app', 'app', [('core', 'core')]);
      final before = f.stages(f.unit('app'));
      final plan = await f.resolve(['app', 'core']);
      expect(plan.order.map((u) => u.name), ['core', 'app']);
      await expectLater(plan.bind(f.unit('app')), throwsStateError);
      expect(f.stages(f.unit('app')), same(before));
      expect(await plan.bind(f.unit('core')), same(provider));
      await f.complete(provider);
      expect(
        (await plan.bind(f.unit('app'))).dependencies.imports,
        hasLength(1),
      );
    },
  );

  test(
    'restored copied imports do not require the original provider directory',
    () async {
      f.needs('app', 'app', [('core', 'core')]);
      final first = await f.resolve(['app', 'core']);
      final core = await first.bind(f.unit('core'));
      await f.complete(core);
      final app = await first.bind(f.unit('app'));
      await f.complete(app);
      Directory(core.directory.path).deleteSync(recursive: true);
      f.restored['app'] = app;
      f.eligible = [];
      f.events.clear();
      final next = await f.resolve(['app']);
      expect(await next.bind(f.unit('app')), same(app));
      expect(app.inspect().reusable, isTrue);
      expect(f.events, ['restore:app', 'eligibility']);
    },
  );

  for (final drift in [
    'intent',
    'compiler',
    'git',
    'binding',
    'provider',
    'configuration',
  ]) {
    test('$drift drift refuses before installing a consumer binding', () async {
      final provider = f.bindEmpty('core');
      await f.complete(provider);
      f.providers.add(PreparedStageProvider.capture(provider));
      f.needs('app', 'app', [('core', 'core')]);
      final before = f.stages(f.unit('app'));
      final plan = await f.resolve(['app']);
      var expected = before;
      switch (drift) {
        case 'intent':
          f.intentRevision++;
        case 'compiler':
          f.compilerDigest = 'c';
        case 'git':
          f.commit = '3';
        case 'binding':
          expected = f.bindEmpty('app');
        case 'provider':
          File(
            provider.directory.resolve('core.pkg'),
          ).writeAsStringSync('changed');
        case 'configuration':
          f.resolution.units.remove(f.unit('third'));
      }
      await expectLater(plan.bind(f.unit('app')), throwsStateError);
      expect(f.stages(f.unit('app')), same(expected));
      expect(Directory(before.directory.path).existsSync(), isFalse);
    });
  }

  test(
    'unused optional sibling is not pinned by the selected consumer',
    () async {
      final provider = f.bindEmpty('core');
      await f.complete(provider);
      f.providers.add(PreparedStageProvider.capture(provider));
      final plan = await f.resolve(['app']);
      Directory(provider.directory.path).deleteSync(recursive: true);
      final app = await plan.bind(f.unit('app'));
      expect(app.dependencies.imports, isEmpty);
      await f.complete(app);
    },
  );

  test('rejected saved state never falls through to fresh discovery', () async {
    f.failRestore = 'core';
    await expectLater(f.resolve(['app', 'core']), throwsStateError);
    expect(f.events, ['restore:app', 'restore:core']);
  });
}

final class RepositoryStageFixture implements NativeStageDiscovery {
  RepositoryStageFixture({bool grouped = false}) {
    final projects = grouped
        ? {
            'core': ['core', 'helper'],
            'app': ['app'],
            'third': ['third'],
          }
        : {
            'core': ['core'],
            'app': ['app'],
            'third': ['third'],
          };
    final config = StringBuffer('schema = 2\n');
    final files = <String, String>{};
    for (final entry in projects.entries) {
      config.writeln('[release.${entry.key}]');
      for (final project in entry.value) {
        config.writeln(
          '[[release.${entry.key}.project]]\npath = "$project"\npublish = ["pub.dev"]',
        );
        files['$project/pubspec.yaml'] =
            'name: $project\nversion: ${entry.key == 'core' ? '0.2.0' : '0.1.0'}\n';
      }
    }
    files['release.toml'] = config.toString();
    source = MemorySourceTree(files);
    final problems = Diagnostics();
    resolution = Resolution.resolve(
      ReleaseConfig.parse(config.toString(), 'release.toml', problems)!,
      source,
      problems,
    )!;
    expect(problems.found, isEmpty);
    stages = ReleaseStages(
      source: source,
      git: git,
      stageContracts:
          ({required unit, required repository, required sourceRoot}) => [
            for (final project in unit.projects)
              StageContributionContract(
                step: StageStepContract(
                  'native:${project.name}',
                  inputs: const {'step:source-snapshot'},
                  outputs: {'${project.name}.pkg': 'fixture-package'},
                ),
              ),
          ],
      compilerIdentity: () => DartCompilerIdentity.recorded(
        executable: '/sdk/dart',
        version: 'fixture',
        sha256: compilerDigest * 64,
      ),
      rkIdentity: () => RkImplementationIdentity.recorded(
        version: '0.1.0',
        stageSchema: stageSchemaVersion,
        sha256: 'b' * 64,
      ),
    );
    eligible = configuredCandidates();
  }

  final root = Directory.systemTemp.createTempSync(
    'rk-repository-preparation-',
  );
  late final MemorySourceTree source;
  late final Resolution resolution;
  late final ReleaseStages stages;
  final events = <String>[];
  final restored = <String, ReleaseStage>{};
  final discoveries = <String, DiscoveredNativeStage>{};
  final providers = <PreparedStageProvider>[];
  final withoutPreparation = <String>{};
  late List<NativeCandidate> eligible;
  String? failDiscovery;
  String? failRestore;
  String compilerDigest = 'a';
  String commit = '1';
  int intentRevision = 0;
  bool samePackageIdentity = false;
  ResolvedUnit unit(String name) => resolution.unit(name)!;
  GitState get git => GitState(
    root: root.path,
    head: commit * 40,
    headTree: '2' * 40,
    branch: 'main',
    isClean: true,
    uncommitted: const [],
    headIsPushed: true,
    tags: const [],
    signingConfigured: false,
    originUrl: 'example/repository',
  );

  @override
  Set<String> get ecosystems => const {'fixture'};
  @override
  List<NativeCandidate> configuredCandidates() => [
    for (final project in resolution.allProjects)
      NativeCandidate(
        package: NativePackage(
          ecosystem: 'fixture',
          source: 'registry:opaque',
          name: samePackageIdentity ? 'same-native-package' : project.name,
        ),
        version: 'release:${project.name}',
        unit: project.unitName,
        project: project.name,
        producer: 'native:${project.name}',
      ),
  ];
  @override
  Map<String, Object?> readIntent(ResolvedUnit unit) => {
    'revision': intentRevision,
  };
  @override
  Future<DiscoveredNativeStage> discover(
    ResolvedUnit unit, {
    required Iterable<NativeCandidate> candidates,
  }) async {
    events.add('discover:${unit.name}');
    if (failDiscovery == unit.name) throw StateError('native solve failed');
    return discoveries[unit.name] ?? DiscoveredNativeStage();
  }

  void needs(
    String unitName,
    String owner,
    List<(String, String)> requirements, {
    String? invalid,
  }) {
    final consumer = switch (invalid) {
      'consumer' => 'missing',
      'source-snapshot' || 'complete-stage' => invalid!,
      _ => 'native:$owner',
    };
    final requests = [
      for (final (project, slot) in requirements)
        PendingStageDependency(
          use: NativeArtifactUse(
            context: '$unitName:$owner',
            slot: slot,
            provider: invalid == 'provider'
                ? NativeCandidate(
                    package: const NativePackage(
                      ecosystem: 'fixture',
                      source: 'registry:opaque',
                      name: 'missing',
                    ),
                    version: 'opaque',
                    unit: 'missing',
                    project: 'missing',
                    producer: 'missing',
                  )
                : configuredCandidates().singleWhere(
                    (p) => p.project == project,
                  ),
            consumers: [consumer],
          ),
          path: invalid == 'path' ? 'wrong.pkg' : '$project.pkg',
          type: invalid == 'type' ? 'wrong-type' : 'fixture-package',
        ),
    ];
    discoveries[unitName] = DiscoveredNativeStage(
      contexts: [
        NativeStageContext(
          context: '$unitName:$owner',
          ecosystem: 'fixture',
          owner: invalid == 'owner' ? 'missing' : owner,
          format: 1,
          consumers: [consumer],
          bindings: [
            for (final request in requests)
              NativeStageBinding(
                slot: request.use.slot,
                package: request.use.provider.package,
                version: request.use.provider.version,
                provider: request.use.provider,
              ),
          ],
          native: const {'opaque': true},
        ),
      ],
      pending: requests,
    );
  }

  Future<RepositoryPreparationPlan> resolve(List<String> names) =>
      RepositoryStagePreparation(
        resolution: resolution,
        stages: stages,
        native: this,
        restore: (unit) async {
          events.add('restore:${unit.name}');
          if (failRestore == unit.name) {
            throw StateError('ambiguous saved stage');
          }
          return restored[unit.name];
        },
        refreshGit: () async => git,
      ).resolve(
        selected: names.map(unit),
        eligibility: (_) async {
          events.add('eligibility');
          return RepositoryStageCandidates(
            candidates: eligible.where(
              (p) =>
                  names.contains(p.unit) ||
                  providers.any((s) => s.stage.unit.name == p.unit) ||
                  discoveries.values.any(
                    (d) => d.pending.any((r) => r.use.provider.unit == p.unit),
                  ),
            ),
            providers: providers,
            withoutPreparation: withoutPreparation,
          );
        },
      );

  ReleaseStage bindEmpty(String name) => stages.bindDependencies(
    unit(name),
    StageDependencies(),
    intent: stages.intentFor(
      unit(name),
      currentGit: git,
      readInputs: () => readIntent(unit(name)),
    ),
  );

  Future<void> complete(
    ReleaseStage stage, {
    String artifactSuffix = '',
  }) async {
    final artifacts = await stage.materializeSource();
    final prior = [
      StageStep(
        name: 'source-snapshot',
        inputs: [
          StageInput.commit(stage.directory.identity),
          StageInput.tree(stage.directory.identity),
          StageInput.plan(stage.directory.identity),
        ],
        outputs: artifacts,
        evidence: {'commit': git.head, 'tree': git.headTree},
      ),
    ];
    stage.writeProgress(prior);
    if (stage.dependencies.hasImports) {
      prior.add(stage.dependencies.materialize(stage.directory, prior.first));
      stage.writeProgress(prior);
    }
    for (final producer in stage.producerNames.where(
      (p) => p.startsWith('native:'),
    )) {
      final project = producer.substring('native:'.length);
      stage.directory.writeBytesAtomically(
        '$project.pkg',
        utf8.encode('$project artifact$artifactSuffix'),
      );
      prior.add(
        StageStep(
          name: producer,
          inputs: stage.producerInputs(producer, prior),
          outputs: [
            StageArtifact.capture(
              stage: stage.directory,
              path: '$project.pkg',
              type: 'fixture-package',
            ),
          ],
        ),
      );
      stage.writeProgress(prior);
    }
    stage.finalize(releaseAssets: const []);
    expect(stage.inspect().issues, isEmpty);
  }
}
