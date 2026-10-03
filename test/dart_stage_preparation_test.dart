import 'dart:convert';
import 'dart:io';

import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/binary_chain.dart';
import 'package:rk/src/commands/release_stage_coordinator.dart';
import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/canonical_json.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/native_stage_context.dart';
import 'package:rk/src/engine/release_stage.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/engine/stage_dependencies.dart';
import 'package:rk/src/engine/stage_plan.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/native/dart/dependencies.dart';
import 'package:rk/src/native/dart/hosted_archive.dart';
import 'package:rk/src/native/dart/hosted_discovery.dart';
import 'package:rk/src/native/dart/package_archive.dart';
import 'package:rk/src/native/dart/resolution_graph.dart';
import 'package:rk/src/native/dart/stage_context.dart';
import 'package:rk/src/native/dart/stage_authorization.dart';
import 'package:rk/src/native/dart/stage_inputs.dart';
import 'package:rk/src/native/dart/stage_preparation.dart';
import 'package:rk/src/native/package_archive.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/targets/catalog.dart';
import 'package:test/test.dart';

import 'support/native_pub_fixture.dart';

void main() {
  DartStageAuthorization authorizer(
    _Fixture f, {
    Tools tools = const SystemTools(),
    String Function()? registry,
    bool unbound = false,
    Resolution? resolution,
    SourceTree? source,
  }) => DartStageAuthorization(
    resolution: resolution ?? f.resolution,
    source: source ?? f.source,
    git: unbound ? GitState.unbound(f.origin.directory.path) : f.git,
    tools: tools,
    compiler: f.origin.dart,
    defaultRegistry: registry ?? () => f.origin.url,
  );

  test(
    'native authorization keeps frozen hosted choices and refreshes only fetch handles',
    () async {
      final f = await _Fixture.create(sameUnit: false, committed: true);
      addTearDown(f.close);
      f.origin.host(Directory('${f.origin.directory.path}/core'));
      final unit = f.resolution.unit('app')!;
      final stage = await f.bind(unit, localCandidates: false);
      await f.prepare(stage);
      final before = CanonicalJson.encode(stage.dependencies.toJson());
      final frozen = DartStageContext.fromEnvelope(
        stage.dependencies.contexts.single,
      );
      expect(frozen.discovery.packages['rk_fixture_core']!.candidate, isNull);
      f.origin.host(
        f.origin.package('remote-new', 'rk_fixture_remote', '1.1.0'),
      );
      f.origin.archiveQuery = '?fresh-token=fixture';
      final auth = authorizer(f);
      final result = await auth.authorize(unit, _nativeReceipt(stage));
      expect(
        result.values.single.packages['rk_fixture_remote']!.manifest.version,
        '1.0.0',
      );
      final hosted = result.values.single.packages['rk_fixture_core']!;
      expect(hosted.candidate, isNull);
      expect(
        hosted.archiveSha256,
        frozen.discovery.packages['rk_fixture_core']!.archiveSha256,
      );
      expect(hosted.archiveUrl!.query, contains('fresh-token'));
      expect(CanonicalJson.encode(stage.dependencies.toJson()), before);
      final format2 = jsonDecode(before) as Map<String, Object?>;
      for (final context in format2['contexts'] as List) {
        (context as Map)['format'] = 2;
      }
      final legacy = StageDependencies.fromJson(format2);
      await auth.authorize(unit, _nativeReceipt(stage, dependencies: legacy));
      expect(legacy.contexts.single.format, 2);
      expect(
        CanonicalJson.encode(legacy.toJson()),
        CanonicalJson.encode(format2),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  for (final unbound in [false, true]) {
    test(
      'workspace intent reads ${unbound ? 'frozen' : 'committed'} manifests without mutation',
      () async {
        final f = await _Fixture.create(
          sameUnit: false,
          workspace: true,
          helpers: true,
          committed: true,
        );
        addTearDown(f.close);
        final auth = authorizer(f, unbound: unbound);
        final unit = f.resolution.unit('app')!;
        final intent = auth.readIntent(unit);
        expect(
          (intent['workspace_manifests'] as Map).keys,
          contains('support/helper/pubspec.yaml'),
        );
        expect(auth.readIntent(unit), intent);
        final provider = await f.bind(f.resolution.unit('core')!);
        await f.prepare(provider);
        final stage = await f.bind(unit);
        await f.prepare(stage);
        final before = CanonicalJson.encode(stage.dependencies.toJson());
        final result = await auth.authorize(unit, _nativeReceipt(stage));
        expect(
          result.values.single.packages['rk_fixture_helper']!.developmentSource,
          isNotNull,
        );
        expect(CanonicalJson.encode(stage.dependencies.toJson()), before);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  test(
    'native authorization requires even an empty root context before any command',
    () async {
      final f = await _Fixture.create(sameUnit: false, committed: true);
      addTearDown(f.close);
      final tools = _RefuseTools();
      final auth = authorizer(f, tools: tools);
      final requests = f.origin.requests.length;
      await expectLater(
        auth.authorize(
          f.resolution.unit('core')!,
          _nativeReceipt(f.stages(f.resolution.unit('core')!)),
        ),
        throwsStateError,
      );
      expect(tools.calls, 0);
      expect(f.origin.requests.length, requests);
    },
  );

  test(
    'source configuration and registry facts must match before native work',
    () async {
      final f = await _Fixture.create(sameUnit: false, committed: true);
      addTearDown(f.close);
      final changed = MemorySourceTree({
        ...f.source.files,
        'core/pubspec.yaml':
            '${f.source.files['core/pubspec.yaml']}publish_to: https://pub.dev\n',
      });
      final diagnostics = Diagnostics();
      final config = ReleaseConfig.parse(
        changed.read('release.toml')!,
        'release.toml',
        diagnostics,
      )!;
      final stale = Resolution.resolve(config, changed, diagnostics)!;
      expect(
        () => authorizer(f, resolution: stale),
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'current resolution',
            contains('configuration differs'),
          ),
        ),
      );
      // Mutating the live checkout and caller tree cannot replace the selected Git bytes.
      f.source.files['core/pubspec.yaml'] = 'not a manifest';
      File(
        '${f.origin.directory.path}/core/pubspec.yaml',
      ).writeAsStringSync('not a manifest');
      final auth = authorizer(f);
      expect(
        (auth.readIntent(f.resolution.unit('core')!)['operations'] as Map)
            .length,
        1,
      );
    },
  );

  test(
    'native authorization preserves distinct Pub and locked binary contexts',
    () async {
      final f = await _Fixture.create(
        sameUnit: false,
        binary: true,
        locked: true,
        workspace: true,
        committed: true,
      );
      addTearDown(f.close);
      final provider = await f.bind(f.resolution.unit('core')!);
      await f.prepare(provider);
      final unit = f.resolution.unit('app')!;
      final stage = await f.bind(unit);
      final auth = authorizer(f);
      final before = CanonicalJson.encode(stage.dependencies.toJson());
      final result = await auth.authorize(unit, _nativeReceipt(stage));
      expect(
        result['dart:pubArchive:rk_fixture_app']!
            .packages['rk_fixture_remote']!
            .manifest
            .version,
        '1.1.0',
      );
      expect(
        result['dart:binary:rk_fixture_app']!
            .packages['rk_fixture_remote']!
            .manifest
            .version,
        '1.0.0',
      );
      expect(CanonicalJson.encode(stage.dependencies.toJson()), before);
      final document = jsonDecode(before) as Map<String, Object?>;
      (document['contexts'] as List).removeWhere(
        (dynamic c) => c['context'] == 'dart:binary:rk_fixture_app',
      );
      for (final key in ['imports', 'external']) {
        (document[key] as List).removeWhere(
          (dynamic input) =>
              (key == 'imports' ? input['use']['context'] : input['context']) ==
              'dart:binary:rk_fixture_app',
        );
      }
      final tools = _RefuseTools();
      await expectLater(
        authorizer(f, tools: tools).authorize(
          unit,
          _nativeReceipt(
            stage,
            dependencies: StageDependencies.fromJson(document),
          ),
        ),
        throwsStateError,
      );
      expect(tools.calls, 0);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a registry change during native authorization refuses installation',
    () async {
      final f = await _Fixture.create(sameUnit: false, committed: true);
      addTearDown(f.close);
      final unit = f.resolution.unit('core')!;
      final stage = await f.bind(unit);
      var registry = f.origin.url;
      final tools = _MutatingTools(() => registry = 'https://pub.dev');
      final auth = authorizer(f, tools: tools, registry: () => registry);
      await expectLater(
        auth.authorize(unit, _nativeReceipt(stage)),
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'live input change',
            contains('intent changed'),
          ),
        ),
      );
      expect(tools.changed, isTrue);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  for (final sameUnit in [false, true]) {
    test(
      'native authorization rejects altered ${sameUnit ? 'local' : 'imported'} archive declarations before commands',
      () async {
        final f = await _Fixture.create(sameUnit: sameUnit, committed: true);
        addTearDown(f.close);
        if (!sameUnit) {
          await f.prepare(await f.bind(f.resolution.unit('core')!));
        }
        final unit = f.resolution.units.last;
        final stage = await f.bind(unit);
        for (final field in ['path', 'type', 'external hash']) {
          final document =
              jsonDecode(CanonicalJson.encode(stage.dependencies.toJson()))
                  as Map<String, Object?>;
          if (field == 'external hash') {
            ((document['external'] as List).single['archive']
                    as Map)['sha256'] =
                'f' * 64;
          } else {
            final input =
                (document[sameUnit ? 'local' : 'imports'] as List).single
                    as Map;
            final artifact = sameUnit ? input : input['original'] as Map;
            artifact[field] = field == 'path'
                ? 'unrelated/archive.tar.gz'
                : 'archive';
          }
          // Parsing alone accepts these coherent declarations. Current native
          // source/selection authority, not a shape parser, must reject them.
          final dependencies = StageDependencies.fromJson(document);
          final tools = _RefuseTools();
          final requests = f.origin.requests.length;
          await expectLater(
            authorizer(f, tools: tools).authorize(
              unit,
              _nativeReceipt(stage, dependencies: dependencies),
            ),
            throwsA(
              isA<StateError>().having(
                (e) => '$e',
                field,
                contains(
                  field == 'external hash'
                      ? 'external archive differs'
                      : '${sameUnit ? 'local input' : 'import'} differs',
                ),
              ),
            ),
          );
          expect(tools.calls, 0, reason: field);
          expect(f.origin.requests.length, requests, reason: field);
        }
        // A plan header can legitimately describe a future same-unit output.
        await authorizer(f).authorize(unit, _nativeReceipt(stage));
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  test(
    'native authorization rejects changed binary consumers and raw lock before commands',
    () async {
      final f = await _Fixture.create(
        sameUnit: false,
        binary: true,
        binaryPlatforms: ['linux-x64', 'macos-arm64'],
        locked: true,
        committed: true,
      );
      addTearDown(f.close);
      await f.prepare(await f.bind(f.resolution.unit('core')!));
      final unit = f.resolution.unit('app')!;
      final stage = await f.bind(unit);
      for (final change in [
        'missing consumer',
        'extra consumer',
        'lock hash',
      ]) {
        final document =
            jsonDecode(CanonicalJson.encode(stage.dependencies.toJson()))
                as Map<String, Object?>;
        const id = 'dart:binary:rk_fixture_app';
        final context =
            (document['contexts'] as List).singleWhere(
                  (dynamic c) => c['context'] == id,
                )
                as Map;
        if (change == 'lock hash') {
          context['native']['lockfile']['sha256'] = 'f' * 64;
        } else {
          final consumers = [...context['consumers'] as List];
          if (change == 'missing consumer') {
            consumers.removeLast();
          } else {
            consumers.add('build:rk_fixture_app:windows-x64');
          }
          context['consumers'] = consumers;
          for (final input in document['imports'] as List) {
            if (input['use']['context'] == id) {
              input['use']['consumers'] = consumers;
            }
          }
          for (final input in document['external'] as List) {
            if (input['context'] == id) input['consumers'] = consumers;
          }
        }
        final dependencies = StageDependencies.fromJson(document);
        final tools = _RefuseTools();
        final requests = f.origin.requests.length;
        await expectLater(
          authorizer(
            f,
            tools: tools,
          ).authorize(unit, _nativeReceipt(stage, dependencies: dependencies)),
          throwsStateError,
        );
        expect(tools.calls, 0, reason: change);
        expect(f.origin.requests.length, requests, reason: change);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  for (final sameUnit in [false, true]) {
    test(
      'native authorization verifies recorded ${sameUnit ? 'local' : 'imported'} producer evidence',
      () async {
        final f = await _Fixture.create(sameUnit: sameUnit, committed: true);
        addTearDown(f.close);
        if (!sameUnit) {
          await f.prepare(await f.bind(f.resolution.unit('core')!));
        }
        final unit = f.resolution.units.last;
        final stage = await f.bind(unit);
        await f.prepare(stage);
        await authorizer(f).authorize(unit, stage.requireReceipt());
        for (final change in [
          'missing graph',
          'changed selection',
          'changed archive',
          'missing completed producer',
          if (sameUnit) 'missing local provider',
        ]) {
          final document = jsonDecode(stage.requireReceipt().encode()) as Map;
          final steps = document['steps'] as List;
          final step =
              steps.singleWhere(
                    (dynamic s) => s['name'] == 'pub-archive:rk_fixture_app',
                  )
                  as Map;
          final evidence = step['evidence'] as Map;
          switch (change) {
            case 'missing graph':
              evidence.remove('native_resolution');
            case 'changed selection':
              evidence['native_resolution']['packages']['rk_fixture_remote']['version'] =
                  '1.0.1';
            case 'changed archive':
              evidence['native_resolution']['packages']['rk_fixture_core']['archive_sha256'] =
                  'f' * 64;
            case 'missing completed producer':
              steps.remove(step);
            case 'missing local provider':
              steps.removeWhere(
                (dynamic s) =>
                    s['name'] == 'pub-archive:rk_fixture_core' ||
                    s['name'] == 'complete-stage',
              );
          }
          final receipt = StageReceipt.parse(
            '${CanonicalJson.encode(document)}\n',
          );
          final tools = _RefuseTools();
          final requests = f.origin.requests.length;
          await expectLater(
            authorizer(f, tools: tools).authorize(unit, receipt),
            throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
          );
          expect(tools.calls, 0, reason: change);
          expect(f.origin.requests.length, requests, reason: change);
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  for (final sameUnit in [false, true]) {
    test(
      'real coordinator packages receipt-bound ${sameUnit ? 'same-unit' : 'cross-unit'} archives and reuses them',
      () async {
        final f = await _Fixture.create(sameUnit: sameUnit);
        addTearDown(f.close);
        final stages = <ReleaseStage>[];
        for (final unit in f.resolution.units) {
          final stage = await f.bind(unit);
          stages.add(stage);
          await f.prepare(stage);
          expect(stage.inspect().reusable, isTrue);
        }
        final stage = stages.last;
        final project = f.resolution.allProjects.singleWhere(
          (p) => p.name == 'rk_fixture_app',
        );
        final output = stage.requireReceipt().steps.singleWhere(
          (s) => s.name == 'pub-archive:${project.name}',
        );
        final graph = DartResolutionGraph.fromJson(
          output.evidence['native_resolution'],
        );
        final provider = stages.first
            .requireReceipt()
            .steps
            .singleWhere((s) => s.name == 'pub-archive:rk_fixture_core')
            .outputs
            .single;
        expect(
          graph.packages['rk_fixture_core']!.archiveSha256,
          provider.sha256,
        );
        expect(graph.packages['rk_fixture_remote']!.version, '1.0.0');
        final archive = await NativePackageArchive.read(
          File(stage.directory.resolve(ReleaseAssets.pubArchivePath(project))),
        );
        DartPackageManifest.fromArchive(
          archive,
        ).requireSameManifest(f.manifest(project));
        expect(
          archive.files.keys.any(
            (path) => path.endsWith('pubspec_overrides.yaml'),
          ),
          isFalse,
        );
        expect(
          output.inputs.any((input) => input.sha256 == provider.sha256),
          isTrue,
        );
        final frozen = DartStagePreparation.contextFor(
          stage,
          project,
          DartStageOperation.pubArchive,
          output.name,
        )!;
        // Production preparation reopens only receipt-bound inputs. It can
        // compile even after a completed cross-unit provider stage is removed.
        if (!sameUnit) {
          Directory(stages.first.directory.path).deleteSync(recursive: true);
        }
        final replay = await DartStagePreparation.open(
          stage: stage,
          project: project,
          context: frozen,
          producer: output.name,
          tools: const SystemTools(),
        );
        try {
          final executable = '${f.origin.directory.path}/consumer-bin';
          final compiled = await replay.replay.run([
            'compile',
            'exe',
            'bin/main.dart',
            '-o',
            executable,
          ]);
          expect(compiled.ok, isTrue, reason: compiled.transcript);
          expect((await Process.run(executable, [])).stdout, '49\n');
        } finally {
          replay.close();
        }
        final receipt = stage.requireReceipt().encode();
        final requests = f.origin.requests.length;
        await f.prepare(stage);
        expect(stage.requireReceipt().encode(), receipt);
        expect(f.origin.requests.length, requests);
        expect(
          f.origin.requests.every((request) => request.startsWith('GET ')),
          isTrue,
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  for (final helpers in [false, true]) {
    test(
      'bound binary producer uses verified archives ${helpers ? 'and source helpers' : 'with a legacy language root'}',
      () async {
        final f = await _Fixture.create(
          sameUnit: false,
          binary: true,
          workspace: helpers,
          helpers: helpers,
          committed: true,
        );
        addTearDown(f.close);
        final provider = await f.bind(f.resolution.unit('core')!);
        await f.prepare(provider);
        final stage = await f.bind(f.resolution.unit('app')!);
        final source = StageStep(
          name: 'source-snapshot',
          inputs: [
            StageInput.commit(stage.directory.identity),
            StageInput.tree(stage.directory.identity),
            StageInput.plan(stage.directory.identity),
          ],
          outputs: await stage.materializeSource(),
          evidence: {'commit': f.git.head, 'tree': f.git.headTree},
        );
        stage.writeProgress([source]);
        final imports = stage.dependencies.materialize(stage.directory, source);
        stage.writeProgress([source, imports]);
        final project = stage.unit.projects.single;
        final capabilities = HostCapabilities.inspect();
        final step = Checklist.derive(
          stage.unit,
          f.resolution,
          Diagnostics(),
        ).steps.singleWhere((s) => s.kind == StepKind.build);
        final output = Output(sink: f.log.write, isTerminal: false);
        final tools = _ObservedTools();
        final built = await BinaryChain(
          tools: tools,
          output: output,
          workspace: stage.directory.workspace,
          repositoryRoot: stage.sourceRoot,
          capabilities: capabilities,
          compilerExecutable: f.origin.dart,
          launcherCompiler: stage.launcherCompiler,
          stage: stage,
        ).buildStep(step, project);
        expect(built.ok, isTrue, reason: f.log.toString());
        expect(
          tools.compileTimeouts,
          [null],
          reason: 'archive replay must not impose a new build timeout',
        );
        expect(
          tools.launcherSources.every(
            (path) => !path.startsWith(stage.directory.path),
          ),
          isTrue,
        );
        final binary = stage.directory.resolve(
          ReleaseAssets.binaryPath(project, capabilities.hostPlatform),
        );
        expect(
          (await Process.run(binary, [])).stdout,
          helpers ? '0.1.0 value=93\n' : '0.1.0 value=49\n',
        );
        final graph = DartResolutionGraph.fromJson(
          built.evidence['native_resolution'],
        );
        expect(
          graph.packages['rk_fixture_core']!.archiveSha256,
          provider
              .requireReceipt()
              .steps
              .singleWhere((s) => s.name == 'pub-archive:rk_fixture_core')
              .outputs
              .single
              .sha256,
        );
        final buildName = 'build:${project.name}:${capabilities.hostPlatform}';
        // This authorizes native evidence from a real compile. It does not
        // confer the separate signing/completion authority that this unsigned
        // macOS fixture intentionally lacks.
        await authorizer(f).authorize(
          stage.unit,
          StageReceipt(
            identity: stage.directory.identity,
            plan: stage.resolvedPlan,
            steps: [
              source,
              imports,
              StageStep(
                name: buildName,
                inputs: stage.producerInputs(buildName, [source, imports]),
                outputs: [
                  for (final output in built.outputs)
                    StageArtifact.capture(
                      stage: stage.directory,
                      path: output.path,
                      type: output.type,
                    ),
                ],
                evidence: built.evidence,
              ),
            ],
          ),
        );
        // The unsigned build is deliberately not recorded as a signed/completed
        // macOS stage. Its pending canonical outputs must not block Pub preparation.
        final context = DartStagePreparation.contextFor(
          stage,
          project,
          DartStageOperation.pubArchive,
          'pub-archive:${project.name}',
        )!;
        final concurrent = await DartStagePreparation.open(
          stage: stage,
          project: project,
          context: context,
          producer: 'pub-archive:${project.name}',
          tools: const SystemTools(),
        );
        concurrent.close();
        expect(stage.inspect().reusable, isFalse);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  test(
    'receipt-bound Pub replay packages and compiles two helpers including a workspace ancestor',
    () async {
      final f = await _Fixture.create(
        sameUnit: false,
        workspace: true,
        helpers: true,
      );
      addTearDown(f.close);
      final provider = await f.bind(f.resolution.unit('core')!);
      await f.prepare(provider);
      final stage = await f.bind(f.resolution.unit('app')!);
      await f.prepare(stage);
      expect(stage.inspect().reusable, isTrue, reason: f.log.toString());
      final project = stage.unit.projects.single;
      final producer = 'pub-archive:${project.name}';
      final context = DartStagePreparation.contextFor(
        stage,
        project,
        DartStageOperation.pubArchive,
        producer,
      )!;
      expect(context.envelope.format, 3);
      expect(context.developmentSources.map((s) => s.manifestPath).toSet(), {
        'pubspec.yaml',
        'support/helper/pubspec.yaml',
      });
      expect(
        context.envelope.bindings.map((b) => b.slot),
        isNot(contains('rk_fixture_helper')),
      );
      final requests = f.origin.requests.length;
      final prepared = await DartStagePreparation.open(
        stage: stage,
        project: project,
        context: context,
        producer: producer,
        tools: const SystemTools(),
      );
      try {
        expect(
          f.origin.requests.length,
          requests,
          reason:
              'prepared constraint gate uses verified metadata without public reads',
        );
        final sources = prepared.replay.developmentSources!;
        expect(sources.bindings.length, 2);
        expect(
          sources.directoryFor('rk_fixture_workspace_helper').path,
          sources.root.path,
        );
        final executable = '${f.origin.directory.path}/helper-consumer';
        final compiled = await prepared.replay.run([
          'compile',
          'exe',
          'test/uses_helpers.dart',
          '-o',
          executable,
        ]);
        expect(compiled.ok, isTrue, reason: compiled.transcript);
        expect((await Process.run(executable, [])).stdout, '44\n');
        File(
          '${prepared.replay.root.path}/generated-by-consumer.txt',
        ).writeAsStringSync('scratch');
        prepared.replay.verify();
        expect(
          File(
            '${sources.root.path}/app/generated-by-consumer.txt',
          ).existsSync(),
          isFalse,
        );
        final archive = await NativePackageArchive.read(
          File(stage.directory.resolve(ReleaseAssets.pubArchivePath(project))),
        );
        DartPackageManifest.fromArchive(
          archive,
        ).requireSameManifest(f.manifest(project));
        expect(
          archive.files.keys.any(
            (name) => name.endsWith('pubspec_overrides.yaml'),
          ),
          isFalse,
        );
        final helperFile = File(
          '${sources.root.path}/support/helper/lib/rk_fixture_helper.dart',
        );
        final original = helperFile.readAsStringSync();
        helperFile.writeAsStringSync(original.replaceFirst('+ 1', '+ 9'));
        expect(prepared.replay.verify, throwsStateError);
        helperFile.writeAsStringSync(original);
        prepared.replay.verify();
        final extra = File('${sources.root.path}/extra.dart')
          ..writeAsStringSync('extra');
        expect(prepared.replay.verify, throwsStateError);
        extra.deleteSync();
        final overrides = File(
          '${sources.root.path}/support/helper/pubspec_overrides.yaml',
        );
        final originalOverrides = overrides.readAsStringSync();
        overrides.writeAsStringSync('resolution: workspace\n');
        expect(prepared.replay.verify, throwsStateError);
        overrides.writeAsStringSync(originalOverrides);
        if (!Platform.isWindows) {
          final mode = helperFile.statSync().mode & 0xfff;
          await Process.run('chmod', ['755', helperFile.path]);
          expect(prepared.replay.verify, throwsStateError);
          await Process.run('chmod', [mode.toRadixString(8), helperFile.path]);
        }
        prepared.replay.verify();
      } finally {
        prepared.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'bound preparation refuses a helper path not authorized by its source receipt',
    () async {
      final f = await _Fixture.create(
        sameUnit: false,
        workspace: true,
        helpers: true,
      );
      addTearDown(f.close);
      f.source.files['spare/helper/pubspec.yaml'] = f.source.read(
        'support/helper/pubspec.yaml',
      )!;
      final provider = await f.bind(f.resolution.unit('core')!);
      await f.prepare(provider);
      final stage = await f.bind(
        f.resolution.unit('app')!,
        transform: (envelope) {
          final document = jsonDecode(jsonEncode(envelope.toJson())) as Map;
          document['native']['resolution']['packages']['rk_fixture_helper']['development_source']['manifest_path'] =
              'spare/helper/pubspec.yaml';
          return NativeStageContext.fromJson(document);
        },
      );
      final source = StageStep(
        name: 'source-snapshot',
        inputs: [
          StageInput.commit(stage.directory.identity),
          StageInput.tree(stage.directory.identity),
          StageInput.plan(stage.directory.identity),
        ],
        outputs: await stage.materializeSource(),
        evidence: {'commit': f.git.head, 'tree': f.git.headTree},
      );
      stage.writeProgress([source]);
      final imports = stage.dependencies.materialize(stage.directory, source);
      stage.writeProgress([source, imports]);
      final project = stage.unit.projects.single;
      final producer = 'pub-archive:${project.name}';
      final context = DartStagePreparation.contextFor(
        stage,
        project,
        DartStageOperation.pubArchive,
        producer,
      )!;
      await expectLater(
        DartStagePreparation.open(
          stage: stage,
          project: project,
          context: context,
          producer: producer,
          tools: const SystemTools(),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'source authority',
            contains('differs from the selected snapshot'),
          ),
        ),
      );
    },
  );

  for (final changed in ['helper', 'manifest', 'lock', 'absent lock']) {
    test(
      'preparation refuses $changed mutation during workspace authorization',
      () async {
        final binary = changed != 'helper';
        final f = await _Fixture.create(
          sameUnit: false,
          workspace: true,
          helpers: true,
          binary: binary,
          locked: changed == 'lock',
        );
        addTearDown(f.close);
        f.source.files['fixture-marker'] = f.origin.directory.path;
        final provider = await f.bind(f.resolution.unit('core')!);
        await f.prepare(provider);
        final stage = await f.bind(f.resolution.unit('app')!);
        final source = StageStep(
          name: 'source-snapshot',
          inputs: [
            StageInput.commit(stage.directory.identity),
            StageInput.tree(stage.directory.identity),
            StageInput.plan(stage.directory.identity),
          ],
          outputs: await stage.materializeSource(),
          evidence: {'commit': f.git.head, 'tree': f.git.headTree},
        );
        stage.writeProgress([source]);
        final imports = stage.dependencies.materialize(stage.directory, source);
        stage.writeProgress([source, imports]);
        final project = stage.unit.projects.single;
        final producer = binary
            ? 'build:${project.name}:${project.binaryPlatforms.single}'
            : 'pub-archive:${project.name}';
        final context = DartStagePreparation.contextFor(
          stage,
          project,
          binary ? DartStageOperation.binary : DartStageOperation.pubArchive,
          producer,
        )!;
        final tools = _WorkspaceMutatingTools(f.origin.directory.path, (
          mirror,
        ) {
          final file = File(switch (changed) {
            'helper' =>
              '${mirror.path}/helpers/support/helper/lib/rk_fixture_helper.dart',
            'manifest' => '${mirror.path}/source/app/pubspec.yaml',
            _ => '${mirror.path}/source/pubspec.lock',
          });
          file.writeAsStringSync(
            changed == 'helper'
                ? 'const value = 999;\n'
                : '${file.existsSync() ? file.readAsStringSync() : 'packages: {}\n'}# changed during authorization\n',
          );
        });
        await expectLater(
          DartStagePreparation.open(
            stage: stage,
            project: project,
            context: context,
            producer: producer,
            tools: tools,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => '$e',
              'source freeze',
              contains(
                changed == 'helper'
                    ? 'native development'
                    : changed == 'manifest'
                    ? 'source root changed'
                    : 'source lock changed',
              ),
            ),
          ),
        );
        expect(tools.changed, isTrue);
      },
    );
  }

  test(
    'portable native context refuses inconsistent roots, slots and consumers',
    () {
      final root = DartPackageManifest.fromMap({
        'name': 'app',
        'version': '0.1.0',
      });
      final discovery = DartDiscoveryResult.fromJson({
        'graph': {
          'roots': ['app'],
          'packages': {
            'app': {
              'name': 'app',
              'version': '0.1.0',
              'source': 'root',
              'dependencies': [],
              'devDependencies': [],
            },
          },
        },
        'packages': <String, Object?>{},
      });
      final context = DartStageContext.discovered(
        root: root,
        defaultRegistry: 'https://pub.dev',
        operation: DartStageOperation.pubArchive,
        consumers: ['pub-archive:app'],
        discovery: discovery,
      );
      for (final change in <void Function(Map<String, dynamic>)>[
        (m) => m['format'] = 1,
        (m) => m['format'] = 99,
        (m) => m['owner'] = 'other',
        (m) => m['consumers'] = ['pub-archive:other'],
        (m) => m['native']['operation'] = 'binary',
        (m) => m['native']['root_manifest']['version'] = '9.0.0',
        (m) =>
            m['native']['default_registry'] = 'https://user:token@example.test',
        (m) =>
            m['native']['resolution']['graph']['packages']['app']['archive_sha256'] =
                'a' * 64,
        (m) => m['native']['resolution']['graph']['packages']['ghost'] = {
          'name': 'ghost',
          'version': '1.0.0',
          'source': 'sdk:${'a' * 64}',
          'dependencies': [],
          'devDependencies': [],
        },
      ]) {
        final document =
            jsonDecode(jsonEncode(context.envelope.toJson()))
                as Map<String, dynamic>;
        change(document);
        expect(
          () => DartStageContext.fromEnvelope(
            NativeStageContext.fromJson(document),
          ),
          throwsA(isA<FormatException>()),
        );
      }
      expect(
        DartStageContext.fromEnvelope(
          NativeStageContext.fromJson(context.envelope.toJson()),
        ).envelope.toJson(),
        context.envelope.toJson(),
      );
    },
  );

  for (final (workspace, bom) in [
    for (final workspace in [false, true])
      for (final bom in [false, true]) (workspace, bom),
  ]) {
    test(
      'bound binary replays the ${workspace ? 'workspace' : 'ordinary'} source lock independently of Pub${bom ? ' with BOM' : ''}',
      () async {
        final f = await _Fixture.create(
          sameUnit: false,
          binary: true,
          locked: true,
          workspace: workspace,
        );
        addTearDown(f.close);
        if (bom) {
          final path = workspace ? 'pubspec.lock' : 'app/pubspec.lock';
          f.source.files[path] = '\uFEFF${f.source.files[path]}';
        }
        final provider = await f.bind(f.resolution.unit('core')!);
        await f.prepare(provider);
        final stage = await f.bind(f.resolution.unit('app')!);
        final source = StageStep(
          name: 'source-snapshot',
          inputs: [
            StageInput.commit(stage.directory.identity),
            StageInput.tree(stage.directory.identity),
            StageInput.plan(stage.directory.identity),
          ],
          outputs: await stage.materializeSource(),
          evidence: {'commit': f.git.head, 'tree': f.git.headTree},
        );
        stage.writeProgress([source]);
        final imports = stage.dependencies.materialize(stage.directory, source);
        stage.writeProgress([source, imports]);
        final project = stage.unit.projects.single;
        final producer =
            'build:${project.name}:${project.binaryPlatforms.single}';
        final context = DartStagePreparation.contextFor(
          stage,
          project,
          DartStageOperation.binary,
          producer,
        )!;
        expect(
          context.lock!.path,
          workspace ? 'pubspec.lock' : 'app/pubspec.lock',
        );
        expect(
          context.discovery.packages['rk_fixture_remote']!.manifest.version,
          '1.0.0',
        );
        final pub = DartStagePreparation.contextFor(
          stage,
          project,
          DartStageOperation.pubArchive,
          'pub-archive:${project.name}',
        )!;
        expect(pub.lock, isNull);
        expect(
          pub.discovery.packages['rk_fixture_remote']!.manifest.version,
          '1.1.0',
        );
        final preparation = await DartStagePreparation.open(
          stage: stage,
          project: project,
          context: context,
          producer: producer,
          tools: const SystemTools(),
        );
        try {
          final output = '${f.origin.directory.path}/locked-bin';
          final compiled = await preparation.replay.run([
            'compile',
            'exe',
            'bin/main.dart',
            '-o',
            output,
          ]);
          expect(compiled.ok, isTrue, reason: compiled.transcript);
          expect((await Process.run(output, [])).stdout, '0.1.0 value=49\n');
          expect(
            preparation.replay.graph.packages['rk_fixture_remote']!.version,
            '1.0.0',
          );
        } finally {
          preparation.close();
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}

StageReceipt _nativeReceipt(
  ReleaseStage stage, {
  StageDependencies? dependencies,
}) {
  final saved = StageReceiptStore(stage.directory).read();
  final plan = <String, Object?>{
    ...stage.resolvedPlan!,
    if (dependencies != null) 'dependency_inputs': dependencies.toJson(),
  };
  final identity = StageIdentity.forPlan(
    headCommit: stage.directory.identity.headCommit!,
    headTree: stage.directory.identity.headTree!,
    resolvedPlan: plan,
  );
  return StageReceipt(
    identity: identity,
    plan: plan,
    steps: [
      for (final step in saved?.steps ?? <StageStep>[])
        StageStep(
          name: step.name,
          outputs: step.outputs,
          evidence: step.evidence,
          inputs: [
            for (final input in step.inputs)
              input.name == 'stage:plan' ? StageInput.plan(identity) : input,
          ],
        ),
    ],
  );
}

final class _Fixture {
  _Fixture(
    this.origin,
    this.source,
    this.resolution, {
    this.commit,
    this.treeHash,
  }) {
    stages = ReleaseStages(
      source: source,
      git: git,
      stageContracts: catalog.stageContractResolver(resolution),
      compilerIdentity: () => DartCompilerIdentity.readResolved(origin.dart),
      rkIdentity: () => RkImplementationIdentity.recorded(
        version: '0.1.0',
        stageSchema: stageSchemaVersion,
        sha256: 'b' * 64,
      ),
    );
  }
  final String? commit;
  final String? treeHash;
  final NativePubFixture origin;
  final MemorySourceTree source;
  final Resolution resolution;
  final catalog = TargetCatalog.builtIn();
  late final ReleaseStages stages;
  final log = StringBuffer();
  GitState get git => GitState(
    root: origin.directory.path,
    head: commit ?? '1' * 40,
    headTree: treeHash ?? '2' * 40,
    branch: 'main',
    isClean: true,
    uncommitted: const [],
    headIsPushed: true,
    tags: const [],
    signingConfigured: false,
    originUrl: 'example/repository',
  );

  static Future<_Fixture> create({
    required bool sameUnit,
    bool binary = false,
    List<String>? binaryPlatforms,
    bool locked = false,
    bool workspace = false,
    bool helpers = false,
    bool committed = false,
  }) async {
    final origin = await NativePubFixture.create();
    try {
      origin.host(
        origin.package(
          'remote',
          'rk_fixture_remote',
          '1.0.0',
          library: 'const value = 7;\n',
        ),
      );
      final core = origin.package(
        'core',
        'rk_fixture_core',
        '0.2.0',
        sdk: '^3.0.0',
      );
      final app = origin.package(
        'app',
        'rk_fixture_app',
        sameUnit ? '0.2.0' : '0.1.0',
        sdk: '^3.0.0',
        dependencies:
            '  rk_fixture_core: ^0.2.0\n  rk_fixture_remote: ^1.0.0\n',
        extra: {
          'bin/main.dart':
              "import 'package:rk_fixture_core/rk_fixture_core.dart' as core;\nimport 'package:rk_fixture_remote/rk_fixture_remote.dart' as remote;\nvoid main() => print(core.value + remote.value);\n",
        },
      );
      String? lock;
      if (locked) {
        final seed = origin.package(
          'lock-seed',
          'rk_fixture_seed',
          '0.1.0',
          dependencies: '  rk_fixture_remote: ^1.0.0\n',
        );
        final result = await origin.run(seed, [
          'pub',
          'get',
          '--no-example',
          '--no-precompile',
        ]);
        if (result.exitCode != 0) {
          throw StateError('${result.stdout}\n${result.stderr}');
        }
        lock = File('${seed.path}/pubspec.lock').readAsStringSync();
        origin.host(
          origin.package(
            'remote2',
            'rk_fixture_remote',
            '1.1.0',
            library: 'const value = 100;\n',
          ),
        );
        File('${app.path}/pubspec.lock').writeAsStringSync(
          workspace ? 'stray member lock must be ignored' : lock,
        );
      }
      if (workspace) {
        for (final root in [app, core]) {
          final file = File('${root.path}/pubspec.yaml');
          file.writeAsStringSync(
            '${file.readAsStringSync().replaceFirst('^3.0.0', '^3.10.4')}resolution: workspace\n',
          );
        }
      }
      if (binary) {
        File('${app.path}/pubspec.yaml').writeAsStringSync(
          'executables:\n  main: main\n',
          mode: FileMode.append,
        );
        final main = File('${app.path}/bin/main.dart');
        main.writeAsStringSync(
          main.readAsStringSync().replaceFirst(
            'print(core.value + remote.value)',
            "print('0.1.0 value=\${core.value + remote.value}')",
          ),
        );
      }
      var config = sameUnit
          ? '''schema = 2
[release.bundle]
[[release.bundle.project]]
path = "core"
publish = ["pub.dev"]
[[release.bundle.project]]
path = "app"
publish = ["pub.dev"]
'''
          : '''schema = 2
[release.core]
path = "core"
publish = ["pub.dev"]
[release.app]
path = "app"
publish = ["pub.dev"]
''';
      if (binary) {
        config = config.replaceFirst(
          '[release.app]\npath = "app"\npublish = ["pub.dev"]',
          '[release.app]\npath = "app"\npublish = ["pub.dev", "git-tag", "github-release"]\nbinary_platforms = ${jsonEncode(binaryPlatforms ?? [HostCapabilities.inspect().hostPlatform])}',
        );
      }
      Directory? helper;
      if (helpers) {
        if (!workspace) {
          throw ArgumentError('helper fixture requires workspace');
        }
        File('${app.path}/pubspec.yaml').writeAsStringSync(
          'dev_dependencies:\n  rk_fixture_helper: any\n  rk_fixture_workspace_helper: any\n',
          mode: FileMode.append,
        );
        if (binary) {
          final main = File('${app.path}/bin/main.dart');
          main.writeAsStringSync(
            "import 'package:rk_fixture_workspace_helper/rk_fixture_workspace_helper.dart' as helper;\n${main.readAsStringSync().replaceAll('core.value + remote.value', 'core.value + remote.value + helper.value')}",
          );
        }
        helper = origin.package(
          'support/helper',
          'rk_fixture_helper',
          '0.0.0',
          dependencies: '  rk_fixture_app: ^${sameUnit ? '0.2.0' : '0.1.0'}\n',
          development: '  deliberately_missing: any\n',
          library:
              "import 'package:rk_fixture_app/rk_fixture_app.dart' as app;\nconst value = app.value + 1;\n",
        );
        final manifest = File('${helper.path}/pubspec.yaml');
        manifest.writeAsStringSync(
          manifest.readAsStringSync().replaceFirst(
            'version: 0.0.0\n',
            'publish_to: none\nresolution: workspace\n',
          ),
        );
        File(
          '${app.path}/test/uses_helpers.dart',
        ).parent.createSync(recursive: true);
        File('${app.path}/test/uses_helpers.dart').writeAsStringSync(
          "import 'package:rk_fixture_workspace_helper/rk_fixture_workspace_helper.dart';\nvoid main() => print(value);\n",
        );
      }
      final source = MemorySourceTree({
        'release.toml': config,
        if (workspace)
          'pubspec.yaml': helpers
              ? 'name: rk_fixture_workspace_helper\npublish_to: none\nenvironment:\n  sdk: ^3.10.4\nworkspace: [core, app, support/helper]\ndependencies:\n  rk_fixture_helper: any\n'
              : 'name: workspace\nenvironment:\n  sdk: ^3.10.4\nworkspace: [core, app]\n',
        if (helpers)
          'lib/rk_fixture_workspace_helper.dart':
              "import 'package:rk_fixture_helper/rk_fixture_helper.dart' as helper;\nconst value = helper.value + 1;\n",
        if (workspace && lock != null) 'pubspec.lock': lock,
        for (final root in [core, app, if (helper != null) helper])
          for (final file in root.listSync(recursive: true).whereType<File>())
            file.path.substring(origin.directory.path.length + 1): file
                .readAsStringSync(),
      });
      final diagnostics = Diagnostics();
      final parsed = ReleaseConfig.parse(config, 'release.toml', diagnostics)!;
      final resolution = Resolution.resolve(parsed, source, diagnostics);
      if (resolution == null || diagnostics.isNotEmpty) {
        throw StateError(
          'invalid native fixture: ${diagnostics.found.map((d) => d.message).join('; ')}',
        );
      }
      String? commit;
      String? treeHash;
      if (committed) {
        for (final entry in source.files.entries) {
          final file = File('${origin.directory.path}/${entry.key}');
          file.parent.createSync(recursive: true);
          file.writeAsStringSync(entry.value);
        }
        Future<String> git(List<String> args) async {
          final result = await Process.run(
            'git',
            args,
            workingDirectory: origin.directory.path,
          );
          if (result.exitCode != 0) {
            throw StateError('fixture Git failed: ${result.stderr}');
          }
          return '${result.stdout}'.trim();
        }

        await git(['add', '--', ...source.files.keys]);
        await git([
          '-c',
          'user.name=RK fixture',
          '-c',
          'user.email=fixture@example.test',
          '-c',
          'commit.gpgsign=false',
          'commit',
          '--quiet',
          '-m',
          'native authorization source',
        ]);
        commit = await git(['rev-parse', 'HEAD']);
        treeHash = await git(['rev-parse', 'HEAD^{tree}']);
      }
      return _Fixture(
        origin,
        source,
        resolution,
        commit: commit,
        treeHash: treeHash,
      );
    } on Object {
      await origin.close();
      rethrow;
    }
  }

  DartPackageManifest manifest(ResolvedProject project) =>
      DartPackageManifest.parse(source.read(project.pubspec.path)!);

  Future<ReleaseStage> bind(
    ResolvedUnit unit, {
    NativeStageContext Function(NativeStageContext)? transform,
    bool localCandidates = true,
  }) async {
    final contexts = <DartStageContext>[];
    final imports = <ImportedStageDependency>[];
    final local = <LocalStageDependency>[];
    final external = <ExternalStageDependency>[];
    for (final project in unit.projects) {
      for (final operation in [
        DartStageOperation.pubArchive,
        if (project.binaryPlatforms.isNotEmpty) DartStageOperation.binary,
      ]) {
        final inputs = DartStageInputs.read(
          source: source,
          project: project,
          operation: operation,
        );
        final discovery = await inputs.discover(
          discovery: DartHostedDiscovery(
            tools: const SystemTools(),
            compiler: origin.dart,
            defaultRegistry: origin.url,
          ),
          candidates: [
            for (final p in resolution.allProjects)
              if (localCandidates && p.name != project.name)
                DartDiscoveryCandidate(
                  provider: dartCandidate(p, defaultRegistry: origin.url),
                  registry: origin.url,
                  manifest: manifest(p),
                ),
          ],
        );
        var context = DartStageContext.discovered(
          root: inputs.root,
          lock: inputs.lock,
          defaultRegistry: origin.url,
          operation: operation,
          consumers: operation == DartStageOperation.pubArchive
              ? ['pub-archive:${project.name}']
              : [
                  for (final platform in project.binaryPlatforms)
                    'build:${project.name}:$platform',
                ],
          discovery: discovery,
        );
        if (transform != null) {
          context = DartStageContext.fromEnvelope(transform(context.envelope));
        }
        contexts.add(context);
        for (final binding in context.envelope.bindings) {
          final selected = discovery.packages[binding.slot]!;
          if (binding.provider case final provider?) {
            final providerProject = resolution.allProjects.singleWhere(
              (p) => p.name == provider.project,
            );
            final use = NativeArtifactUse(
              context: context.envelope.context,
              slot: binding.slot,
              provider: provider,
              consumers: context.envelope.consumers,
            );
            final path = ReleaseAssets.pubArchivePath(providerProject);
            if (provider.unit == unit.name) {
              local.add(
                LocalStageDependency(use: use, path: path, type: 'pub-archive'),
              );
            } else {
              imports.add(
                ImportedStageDependency.fromProvider(
                  use: use,
                  provider: stages(resolution.unit(provider.unit)!),
                  path: path,
                  type: 'pub-archive',
                ),
              );
            }
          } else {
            final archive = await DartHostedArchive.fetch(selected);
            external.add(
              ExternalStageDependency.fromBytes(
                context: context.envelope.context,
                binding: binding,
                consumers: context.envelope.consumers,
                bytes: archive.archive.bytes,
                expectedSha256: archive.archive.sha256,
              ),
            );
          }
        }
      }
    }
    return stages.bindDependencies(
      unit,
      StageDependencies(
        contexts: contexts.map((c) => c.envelope),
        imports: imports,
        local: local,
        external: external,
      ),
    );
  }

  Future<void> prepare(ReleaseStage stage) async {
    final diagnostics = Diagnostics();
    final checklist = Checklist.derive(stage.unit, resolution, diagnostics);
    expect(diagnostics.isEmpty, isTrue);
    final targets = catalog.derive(
      stage.unit,
      checklist,
      repository: git.originUrl,
    );
    final output = Output(sink: log.write, isTerminal: false);
    final coordinator = ReleaseStageCoordinator(
      initialGit: git,
      output: output,
      refreshGit: () async => git,
      refreshStage: stages.refresh,
      tools: const SystemTools(),
      capabilities: HostCapabilities(
        hostPlatform: 'linux-x64',
        containerRuntime: null,
        hasNativeAssets: false,
      ),
      stageFor: stages.call,
      stageOnly: true,
    );
    final result = await coordinator.prepare(
      unit: stage.unit,
      checklist: checklist,
      targets: targets,
      targetStages: catalog.stages(unit: stage.unit, targets: targets),
      stage: stage,
      inspected: stage.inspect(),
      claims: const [],
    );
    expect(
      result,
      isNotNull,
      reason:
          '${log.toString()}\n${output.report.encode(exit: result == null ? 1 : 0)}',
    );
  }

  Future<void> close() => origin.close();
}

final class _ObservedTools implements Tools {
  final compileTimeouts = <Duration?>[];
  final launcherSources = <String>[];
  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) {
    if (arguments.contains('compile')) compileTimeouts.add(timeout);
    if (executable.endsWith('clang')) {
      launcherSources.addAll(arguments.where((arg) => arg.endsWith('.c')));
    }
    return const SystemTools().run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      timeout: timeout,
    );
  }

  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) => throw StateError('native fixture must not authenticate or publish');
}

/// The unique marker confines this mutation to this fixture's private mirror.
final class _WorkspaceMutatingTools implements Tools {
  _WorkspaceMutatingTools(this.marker, this.mutate);
  final String marker;
  final void Function(Directory) mutate;
  bool changed = false;
  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    final result = await const SystemTools().run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      timeout: timeout,
    );
    if (!changed && arguments.contains('workspace')) {
      for (final entry
          in Directory.systemTemp
              .listSync(followLinks: false)
              .whereType<Directory>()) {
        if (!entry.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('rk-dart-source-')) {
          continue;
        }
        final file = File('${entry.path}/helpers/fixture-marker');
        if (file.existsSync() && file.readAsStringSync() == marker) {
          mutate(entry);
          changed = true;
          break;
        }
      }
    }
    return result;
  }

  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) => throw StateError('unexpected interactive native operation');
}

final class _RefuseTools implements Tools {
  int calls = 0;
  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    calls++;
    throw StateError('unexpected native command');
  }

  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    calls++;
    throw StateError('unexpected interactive command');
  }
}

final class _MutatingTools implements Tools {
  _MutatingTools(this.mutate);
  final void Function() mutate;
  bool changed = false;
  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) {
    if (!changed) {
      changed = true;
      mutate();
    }
    return const SystemTools().run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      timeout: timeout,
    );
  }

  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) => throw StateError('unexpected interactive authorization');
}
