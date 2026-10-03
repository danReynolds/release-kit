import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/native_dependencies.dart';
import 'package:rk/src/engine/native_stage_authorization.dart';
import 'package:rk/src/engine/native_stage_context.dart';
import 'package:rk/src/engine/release_stage.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/stage_contract.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/engine/stage_intent.dart';
import 'package:rk/src/engine/stage_dependencies.dart';
import 'package:rk/src/engine/stage_plan.dart';
import 'package:rk/src/engine/stage_proof.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:rk/src/engine/stage_restoration.dart';
import 'package:rk/src/engine/stage_source.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

void main() {
  late _Fixture f;
  setUp(() async => f = await _Fixture.create());
  tearDown(() => f.root.deleteSync(recursive: true));

  test('only conclusive absence permits fresh discovery', () async {
    final current = f.resolver();
    final restore = await f.restorer(current);
    expect(await restore.restore('app'), isNull);
    expect(f.authority.authorized, isEmpty);
    expect(Directory('${f.root.path}/.rk').existsSync(), isFalse);
    await expectLater(
      restore.restore('app', recoveryStageId: 'f' * 64),
      throwsStateError,
    );
    Directory(
      '${f.root.path}/.rk/work/stages/${'e' * 64}',
    ).createSync(recursive: true);
    await expectLater(restore.restore('app'), throwsStateError);
  });

  test(
    'absence cannot authorize discovery with changed current inputs',
    () async {
      final current = f.resolver();
      final restore = await StageRestoration.create(
        stages: current,
        resolution: f.resolution,
        currentGit: f.git,
        authority: f.authority,
        refreshGit: () async {
          f.authority.registry = 'changed';
          return f.git;
        },
      );
      await expectLater(restore.restore('app'), throwsStateError);
      expect(f.authority.authorized, isEmpty);
      expect(Directory('${f.root.path}/.rk').existsSync(), isFalse);
    },
  );

  test('completed root restores identically without writes', () async {
    final stage = f.bind('app');
    await f.complete(stage);
    final before = stage.directory.fingerprint();
    final current = f.resolver();
    final restored = (await (await f.restorer(current)).restore('app'))!;
    expect(restored.directory.identity.id, stage.directory.identity.id);
    expect(restored.inspect().reusable, isTrue);
    expect(current(f.unit('app')), same(restored));
    expect(stage.directory.fingerprint(), before);
    expect(f.authority.authorized, ['app']);
    expect(f.authority.retained, ['app']);
  });

  test(
    'header-only restore recovers exact inputs but produces nothing',
    () async {
      final provider = f.bind('core');
      await f.complete(provider);
      final input = f.import(provider, 'app');
      final external = f.external('app');
      final stage = f.bind('app', imports: [input], external: [external]);
      f.header(stage);
      final before = stage.directory.fingerprint();
      final current = f.resolver();
      final cached = current(f.unit('core'));
      final restored = (await (await f.restorer(current)).restore('app'))!;
      expect(restored.dependencies.toJson(), stage.dependencies.toJson());
      expect(stage.directory.fingerprint(), before);
      expect(
        current(f.unit('core')),
        same(cached),
        reason: 'providers stay read-only',
      );
      expect(f.authority.recovered, ['app']);
      await f.complete(restored);
      expect(restored.inspect().reusable, isTrue);
      expect(
        File(restored.directory.resolve(input.archive.path)).readAsStringSync(),
        'core artifact',
      );
    },
  );

  test(
    'source residue is retried using authorized source and frozen choices',
    () async {
      final stage = f.bind('app');
      f.header(stage);
      stage.directory.writeBytesAtomically(
        'source/app/pubspec.yaml',
        utf8.encode('incomplete'),
      );
      final current = f.resolver();
      final restored = (await (await f.restorer(current)).restore('app'))!;
      expect(restored.inspect().canRestartSource, isTrue);
      await f.complete(restored);
      expect(restored.inspect().reusable, isTrue);
    },
  );

  test(
    'C uses copied B and ancestral A proof after both provider directories are deleted',
    () async {
      final a = f.bind('core');
      await f.complete(a);
      final b = f.bind('app', imports: [f.import(a, 'app')]);
      await f.complete(b);
      final c = f.bind('third', imports: [f.import(b, 'third')]);
      await f.complete(c);
      Directory(a.directory.path).deleteSync(recursive: true);
      Directory(b.directory.path).deleteSync(recursive: true);
      final before = c.directory.fingerprint();
      final restored = (await (await f.restorer(
        f.resolver(),
      )).restore('third'))!;
      expect(restored.inspect().reusable, isTrue);
      expect(f.authority.authorized.toSet(), {'core', 'app', 'third'});
      expect(f.authority.retained, ['third']);
      expect(f.authority.recovered, isEmpty);
      expect(c.directory.fingerprint(), before);
      expect(Directory(a.directory.path).existsSync(), isFalse);
      expect(Directory(b.directory.path).existsSync(), isFalse);
    },
  );

  for (final missing in ['archive', 'proof', 'external']) {
    test(
      'recorded missing $missing never falls back to provider or registry',
      () async {
        final a = f.bind('core');
        await f.complete(a);
        final imported = f.import(a, 'app');
        final external = f.external('app');
        final stage = f.bind('app', imports: [imported], external: [external]);
        await f.complete(stage);
        final path = switch (missing) {
          'archive' => imported.archive.path,
          'proof' => imported.proof.path,
          _ => external.archive.path,
        };
        File(stage.directory.resolve(path)).deleteSync();
        final current = f.resolver();
        final cached = current(f.unit('app'));
        await expectLater(
          (await f.restorer(current)).restore('app'),
          throwsA(anything),
        );
        expect(current(f.unit('app')), same(cached));
        expect(f.authority.recovered, isEmpty);
        expect(f.authority.authorized, isEmpty);
        expect(File(stage.directory.resolve(path)).existsSync(), isFalse);
      },
    );
  }

  test(
    'missing pending exact provider cannot select a different stage',
    () async {
      final provider = f.bind('core');
      await f.complete(provider);
      final stage = f.bind('app', imports: [f.import(provider, 'app')]);
      f.header(stage);
      Directory(provider.directory.path).deleteSync(recursive: true);
      final replacement = f.bind('core', native: 'other frozen selection');
      await f.complete(replacement);
      await expectLater(
        (await f.restorer(f.resolver())).restore('app'),
        throwsStateError,
      );
      expect(f.authority.authorized, isEmpty);
    },
  );

  test(
    'changed pending provider receipt is refused before native commands',
    () async {
      final provider = f.bind('core');
      await f.complete(provider);
      final stage = f.bind('app', imports: [f.import(provider, 'app')]);
      f.header(stage);
      final saved = provider.requireReceipt();
      StageReceiptStore(provider.directory).write(
        StageReceipt(
          identity: saved.identity,
          plan: saved.plan,
          steps: saved.steps.take(saved.steps.length - 1),
        ),
      );
      await expectLater(
        (await f.restorer(f.resolver())).restore('app'),
        throwsA(anything),
      );
      expect(f.authority.authorized, isEmpty);
    },
  );

  for (final change in [
    'provider-bytes',
    'root-receipt',
    'registry',
    'compiler',
    'provider-contract',
    'git',
  ]) {
    test('late $change change refuses all bindings transactionally', () async {
      final provider = f.bind('core');
      await f.complete(provider);
      final stage = f.bind(
        'app',
        imports: [f.import(provider, 'app')],
        external: [f.external('app')],
      );
      f.header(stage);
      final current = f.resolver();
      final cachedRoot = current(f.unit('app'));
      final cachedProvider = current(f.unit('core'));
      f.authority.onRecover = () async {
        switch (change) {
          case 'provider-bytes':
            File(
              provider.directory.resolve('core.pkg'),
            ).writeAsStringSync('tampered');
          case 'root-receipt':
            File(stage.directory.resolve('stage.json')).writeAsStringSync('{}');
          case 'registry':
            f.authority.registry = 'changed';
          case 'compiler':
            f.compilerDigest = 'd';
          case 'provider-contract':
            f.changedContractUnit = 'core';
          case 'git':
            f.gitCommand(['commit', '--allow-empty', '-m', 'moved HEAD']);
        }
      };
      await expectLater(
        (await f.restorer(current)).restore('app'),
        throwsA(anything),
      );
      expect(current(f.unit('app')), same(cachedRoot));
      expect(current(f.unit('core')), same(cachedProvider));
    });
  }

  test('changed external recovery declaration is refused', () async {
    final stage = f.bind('app', external: [f.external('app')]);
    f.header(stage);
    f.authority.changedRecovery = true;
    await expectLater(
      (await f.restorer(f.resolver())).restore('app'),
      throwsStateError,
    );
  });

  test('native policy runs even when serialized contexts are empty', () async {
    final unit = f.unit('app');
    final stage = f.stages.bindDependencies(
      unit,
      StageDependencies(),
      intent: f.intent(f.stages, unit),
    );
    f.header(stage);
    f.authority.requireContext = true;
    await expectLater(
      (await f.restorer(f.resolver())).restore('app'),
      throwsStateError,
    );
    expect(f.authority.authorized, ['app']);
  });

  test(
    'unknown imported ecosystem cannot bypass empty-context policy',
    () async {
      final a = f.bind('core');
      await f.complete(a);
      final stage = f.stages.bindDependencies(
        f.unit('app'),
        StageDependencies(imports: [f.import(a, 'app', ecosystem: 'unknown')]),
        intent: f.intent(f.stages, f.unit('app')),
      );
      f.header(stage);
      await expectLater(
        (await f.restorer(f.resolver())).restore('app'),
        throwsStateError,
      );
      expect(f.authority.authorized, isEmpty);
    },
  );

  test(
    'ambiguous frozen choices require explicit recovery instead of selecting newest',
    () async {
      final a = f.bind('app', native: 'one');
      await f.complete(a);
      final b = f.bind('app', native: 'two');
      await f.complete(b);
      final restore = await f.restorer(f.resolver());
      await expectLater(restore.restore('app'), throwsStateError);
      expect(f.authority.authorized, isEmpty);
      final recovered = await restore.restore(
        'app',
        recoveryStageId: a.directory.identity.id,
      );
      expect(recovered!.directory.identity.id, a.directory.identity.id);
    },
  );

  for (final limit in ['stages', 'edges', 'bytes', 'depth', 'proof reads']) {
    test('combined graph enforces $limit bound before native work', () async {
      final a = f.bind('core');
      await f.complete(a);
      final b = f.bind('app', imports: [f.import(a, 'app')]);
      await f.complete(b);
      final c = f.bind('third', imports: [f.import(b, 'third')]);
      await f.complete(c);
      final limits = switch (limit) {
        'stages' => const StageProofLimits(stages: 2),
        'edges' => const StageProofLimits(edges: 1),
        'bytes' => StageProofLimits(
          bytes: utf8.encode(c.requireReceipt().encode()).length,
        ),
        'depth' => const StageProofLimits(depth: 2),
        _ => const StageProofLimits(expandedBytes: 1),
      };
      await expectLater(
        (await f.restorer(f.resolver(), limits: limits)).restore('third'),
        throwsA(anything),
      );
      expect(f.authority.authorized, isEmpty);
    });
  }

  for (final target in ['retained provider', 'proof-only ancestor']) {
    test(
      'pre-install handoff rechecks $target without installing bindings',
      () async {
        final a = f.bind('core');
        await f.complete(a);
        final b = f.bind('app', imports: [f.import(a, 'app')]);
        if (target == 'proof-only ancestor') {
          await f.complete(b);
          Directory(a.directory.path).deleteSync(recursive: true);
        } else {
          f.header(b);
        }
        final current = f.resolver();
        final cached = current(f.unit('app'));
        var finalBoundary = false;
        var reads = 0;
        var changed = false;
        // Two nodes are rechecked by _authorize (intent + candidate each).
        // The fifth compiler read is adoptFrozen's root reconstruction, after
        // that authorizer returned and before its pre-install closure check.
        f.onCompilerRead = () {
          if (finalBoundary && ++reads == 5) {
            changed = true;
            if (target == 'retained provider') {
              File(
                a.directory.resolve('core.pkg'),
              ).writeAsStringSync('changed after authorization');
            } else {
              f.authority.registries['core'] = 'new registry';
            }
          }
        };
        final restore = await StageRestoration.create(
          stages: current,
          resolution: f.resolution,
          currentGit: f.git,
          authority: f.authority,
          refreshGit: () async {
            finalBoundary = true;
            return f.git;
          },
        );
        await expectLater(restore.restore('app'), throwsA(anything));
        expect(changed, isTrue);
        expect(current(f.unit('app')), same(cached));
      },
    );
  }

  for (final changed in ['build', 'targets', 'dependency']) {
    test(
      'current source tree does not authorize stale parsed $changed facts',
      () async {
        final original = f.unit('app');
        final project = original.projects.single;
        final config = project.config;
        final stalePubspec = changed == 'dependency'
            ? Resolution.resolve(
                ReleaseConfig.parse(
                  f.files['release.toml']!,
                  'release.toml',
                  Diagnostics(),
                )!,
                MemorySourceTree({
                  ...f.files,
                  'app/pubspec.yaml':
                      '${f.files['app/pubspec.yaml']}dependencies:\n  stale: ^1.0.0\n',
                }),
                Diagnostics(),
              )!.unit('app')!.projects.single.pubspec
            : project.pubspec;
        final stale = ResolvedUnit(
          name: original.name,
          publish: original.publish,
          tagPattern: original.tagPattern,
          tagWasDeclared: original.tagWasDeclared,
          location: original.location,
          projects: [
            ResolvedProject(
              unitName: project.unitName,
              pubspec: stalePubspec,
              config: ProjectConfig(
                path: config.path,
                publish: changed == 'targets' ? {} : config.publish,
                binaryPlatforms: config.binaryPlatforms,
                location: config.location,
                build: changed == 'build' ? ['stale-build'] : config.build,
                assets: changed == 'build' ? ['stale-output'] : config.assets,
              ),
            ),
          ],
        );
        final resolution = Resolution(
          units: [
            for (final unit in f.resolution.units)
              unit.name == 'app' ? stale : unit,
          ],
          tree: f.resolution.tree,
        );
        await expectLater(
          StageRestoration.create(
            stages: f.resolver(),
            resolution: resolution,
            currentGit: f.git,
            authority: f.authority,
          ),
          throwsStateError,
        );
        expect(f.authority.authorized, isEmpty);
      },
    );
  }

  test(
    'mutable resolved collections are rechecked after authorization',
    () async {
      final stage = f.bind('app', external: [f.external('app')]);
      f.header(stage);
      final current = f.resolver();
      final unit = f.unit('app');
      final cached = current(unit);
      f.authority.onRecover = () async {
        f.resolution.units.removeAt(0);
      };
      await expectLater(
        (await f.restorer(current)).restore('app'),
        throwsStateError,
      );
      expect(current(unit), same(cached));
    },
  );

  test('bound restoration refuses mutable or falsely bound source', () async {
    final memory = MemorySourceTree(f.files);
    await expectLater(f.restorer(f.resolver(source: memory)), throwsStateError);
    final unbound = await StageSourceSnapshot.capture(memory);
    await expectLater(
      f.restorer(f.resolver(source: unbound)),
      throwsStateError,
    );
  });

  test('bound restoration refuses a different committed inventory', () async {
    final other = await _Fixture.create(extraSource: 'different bytes');
    try {
      await expectLater(
        f.restorer(f.resolver(source: GitSourceTree(other.root.path))),
        throwsA(anything),
      );
    } finally {
      other.root.deleteSync(recursive: true);
    }
  });

  test(
    'fresh configuration is authoritative over caller stale resolution',
    () async {
      final stage = f.bind('app');
      await f.complete(stage);
      final staleFiles = {
        ...f.files,
        'app/pubspec.yaml': f.files['app/pubspec.yaml']!.replaceFirst(
          '0.1.0',
          '9.0.0',
        ),
      };
      final diagnostics = Diagnostics();
      final config = ReleaseConfig.parse(
        staleFiles['release.toml']!,
        'release.toml',
        diagnostics,
      )!;
      final stale = Resolution.resolve(
        config,
        MemorySourceTree(staleFiles),
        diagnostics,
      )!;
      final current = f.resolver();
      current(stale.unit('app')!);
      final restored = await (await f.restorer(current)).restore('app');
      expect(restored!.unit.version.toString(), '0.1.0');
      expect(restored.directory.identity.id, stage.directory.identity.id);
    },
  );

  test(
    'unbound source is same-invocation immutable and never reused by a new resolver',
    () async {
      final source = FrozenSourceTree.capture(MemorySourceTree(f.files));
      final git = GitState.unbound(f.root.path);
      final current = f.resolver(source: source, git: git);
      final unit = f.unit('app');
      final stage = current.bindDependencies(
        unit,
        StageDependencies(),
        intent: current.intentFor(
          unit,
          currentGit: git,
          readInputs: () => f.authority.readIntent(unit),
        ),
      );
      f.header(stage);
      final restore = await StageRestoration.create(
        resolution: f.resolution,
        stages: current,
        currentGit: git,
        authority: f.authority,
      );
      expect(
        (await restore.restore('app'))!.directory.identity.id,
        stage.directory.identity.id,
      );
      final different = f.resolver(source: source, git: git);
      expect(
        await (await StageRestoration.create(
          resolution: f.resolution,
          stages: different,
          currentGit: git,
          authority: f.authority,
        )).restore('app'),
        isNull,
      );
      await expectLater(
        StageRestoration.create(
          resolution: f.resolution,
          stages: f.resolver(source: MemorySourceTree(f.files), git: git),
          currentGit: git,
          authority: f.authority,
        ),
        throwsStateError,
      );
    },
  );
}

final class _Fixture {
  _Fixture(this.root, this.files, this.git, this.resolution);
  static Future<_Fixture> create({String? extraSource}) async {
    final root = Directory.systemTemp.createTempSync('rk-restoration-');
    final files = <String, String>{
      'release.toml': '''schema = 2
[release.core]
path = "core"
publish = ["pub.dev"]
[release.app]
path = "app"
publish = ["pub.dev"]
[release.third]
path = "third"
publish = ["pub.dev"]
''',
      for (final name in ['core', 'app', 'third'])
        '$name/pubspec.yaml':
            'name: $name\nversion: ${name == 'core' ? '0.2.0' : '0.1.0'}\nenvironment:\n  sdk: ^3.10.4\n',
      if (extraSource != null) 'extra.txt': extraSource,
    };
    for (final entry in files.entries) {
      File('${root.path}/${entry.key}')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(entry.value);
    }
    void git(List<String> args) {
      final result = Process.runSync('git', args, workingDirectory: root.path);
      if (result.exitCode != 0) throw StateError('${result.stderr}');
    }

    git(['init', '-q']);
    git(['config', 'user.name', 'RK Test']);
    git(['config', 'user.email', 'rk@example.test']);
    git(['config', 'commit.gpgsign', 'false']);
    git(['add', '.']);
    git(['commit', '-qm', 'source']);
    final state = await GitState.read(root.path);
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse(
      files['release.toml']!,
      'release.toml',
      diagnostics,
    )!;
    final resolution = Resolution.resolve(
      config,
      GitCommitSourceTree(root.path, state.head),
      diagnostics,
    )!;
    expect(diagnostics.isEmpty, isTrue);
    return _Fixture(root, files, state, resolution);
  }

  final Directory root;
  final Map<String, String> files;
  final GitState git;
  final Resolution resolution;
  final authority = _Authority();
  String compilerDigest = 'a';
  void Function()? onCompilerRead;
  String? changedContractUnit;
  late final stages = resolver();
  ResolvedUnit unit(String name) => resolution.unit(name)!;
  void gitCommand(List<String> args) {
    final result = Process.runSync('git', args, workingDirectory: root.path);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  ReleaseStages resolver({SourceTree? source, GitState? git}) => ReleaseStages(
    source: source ?? GitSourceTree(root.path),
    git: git ?? this.git,
    stageContracts: ({required unit, required repository, required sourceRoot}) => [
      for (final project in unit.projects)
        StageContributionContract(
          step: StageStepContract(
            'native:${project.name}',
            inputs: const {'step:source-snapshot'},
            outputs: {
              '${project.name}${changedContractUnit == unit.name ? '.different' : ''}.pkg':
                  'fixture-package',
            },
          ),
        ),
    ],
    compilerIdentity: () {
      onCompilerRead?.call();
      return DartCompilerIdentity.recorded(
        executable: '/sdk/dart',
        version: 'fixture',
        sha256: compilerDigest * 64,
      );
    },
    rkIdentity: () => RkImplementationIdentity.recorded(
      version: '0.1.0',
      stageSchema: stageSchemaVersion,
      sha256: 'b' * 64,
    ),
  );
  Future<StageRestoration> restorer(
    ReleaseStages stages, {
    StageProofLimits limits = const StageProofLimits(),
  }) => StageRestoration.create(
    resolution: resolution,
    stages: stages,
    currentGit: git,
    authority: authority,
    limits: limits,
  );
  StageIntent intent(ReleaseStages stages, ResolvedUnit unit) =>
      stages.intentFor(
        unit,
        currentGit: git,
        readInputs: () => authority.readIntent(unit),
      );
  ReleaseStage bind(
    String name, {
    List<ImportedStageDependency> imports = const [],
    List<ExternalStageDependency> external = const [],
    String native = 'selected',
  }) {
    final unit = this.unit(name);
    return stages.bindDependencies(
      unit,
      StageDependencies(
        imports: imports,
        external: external,
        contexts: [
          NativeStageContext(
            context: '$name/native',
            ecosystem: 'fixture',
            owner: name,
            format: 1,
            consumers: ['native:$name'],
            native: {'selection': native},
            bindings: [
              for (final input in imports)
                NativeStageBinding(
                  slot: input.use.slot,
                  package: input.use.provider.package,
                  version: input.use.provider.version,
                  provider: input.use.provider,
                ),
              for (final input in external) input.binding,
            ],
          ),
        ],
      ),
      intent: intent(stages, unit),
    );
  }

  ImportedStageDependency import(
    ReleaseStage provider,
    String consumer, {
    String ecosystem = 'fixture',
  }) => ImportedStageDependency.fromProvider(
    use: NativeArtifactUse(
      context: '$consumer/native',
      slot: provider.unit.name,
      consumers: ['native:$consumer'],
      provider: NativeCandidate(
        package: NativePackage(
          ecosystem: ecosystem,
          source: 'fixture-registry',
          name: provider.unit.name,
        ),
        version: provider.unit.version.toString(),
        unit: provider.unit.name,
        project: provider.unit.name,
        producer: 'native:${provider.unit.name}',
      ),
    ),
    provider: provider,
    path: '${provider.unit.name}.pkg',
    type: 'fixture-package',
  );
  ExternalStageDependency external(String name) =>
      ExternalStageDependency.fromBytes(
        context: '$name/native',
        binding: NativeStageBinding(
          slot: 'remote',
          package: const NativePackage(
            ecosystem: 'fixture',
            source: 'fixture-registry',
            name: 'remote',
          ),
          version: '1.0.0',
        ),
        consumers: ['native:$name'],
        bytes: utf8.encode('remote bytes'),
        expectedSha256: Sha256.hex(utf8.encode('remote bytes')),
      );
  void header(ReleaseStage stage) => StageReceiptStore(stage.directory).write(
    StageReceipt(
      identity: stage.directory.identity,
      plan: stage.resolvedPlan,
      steps: const [],
    ),
  );
  Future<void> complete(ReleaseStage stage) async {
    final artifacts = await stage.materializeSource();
    final source = StageStep(
      name: 'source-snapshot',
      inputs: [
        StageInput.commit(stage.directory.identity),
        StageInput.tree(stage.directory.identity),
        StageInput.plan(stage.directory.identity),
      ],
      outputs: artifacts,
      evidence: {'commit': git.head, 'tree': git.headTree},
    );
    final steps = [source];
    stage.writeProgress(steps);
    if (stage.dependencies.hasImports) {
      steps.add(stage.dependencies.materialize(stage.directory, source));
      stage.writeProgress(steps);
    }
    final name = stage.unit.name;
    stage.directory.writeBytesAtomically(
      '$name.pkg',
      utf8.encode('$name artifact'),
    );
    steps.add(
      StageStep(
        name: 'native:$name',
        inputs: stage.producerInputs('native:$name', steps),
        outputs: [
          StageArtifact.capture(
            stage: stage.directory,
            path: '$name.pkg',
            type: 'fixture-package',
          ),
        ],
      ),
    );
    stage.writeProgress(steps);
    stage.finalize(releaseAssets: const []);
    expect(stage.inspect().issues, isEmpty);
  }
}

final class _Authority implements NativeStageAuthority {
  String registry = 'fixture-registry';
  final registries = <String, String>{};
  bool requireContext = false;
  bool changedRecovery = false;
  Future<void> Function()? onRecover;
  final authorized = <String>[];
  final retained = <String>[];
  final recovered = <String>[];
  @override
  Set<String> get ecosystems => const {'fixture'};
  @override
  Map<String, Object?> readIntent(ResolvedUnit unit) {
    return {'unit': unit.name, 'registry': registries[unit.name] ?? registry};
  }

  @override
  Future<AuthorizedNativeStage> authorize(
    ResolvedUnit unit,
    StageReceipt receipt,
  ) async {
    authorized.add(unit.name);
    if (requireContext && receipt.plan!['dependency_inputs'] == null) {
      throw StateError('missing expected native context');
    }
    return _Authorized(this, unit.name);
  }
}

final class _Authorized implements AuthorizedNativeStage {
  _Authorized(this.authority, this.name);
  final _Authority authority;
  final String name;
  @override
  Future<void> validateRetained(
    ReleaseStage stage,
    StageReceipt receipt,
  ) async {
    authority.retained.add(name);
  }

  @override
  Future<ExternalStageDependency> recoverExternal(
    ExternalStageDependency input,
  ) async {
    authority.recovered.add(name);
    await authority.onRecover?.call();
    final bytes = utf8.encode(
      authority.changedRecovery ? 'changed archive' : 'remote bytes',
    );
    return ExternalStageDependency.fromBytes(
      context: input.context,
      binding: input.binding,
      consumers: input.consumers,
      bytes: bytes,
      expectedSha256: Sha256.hex(bytes),
    );
  }
}
