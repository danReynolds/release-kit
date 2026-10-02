import 'dart:convert';
import 'dart:io';

import 'package:rk/src/native/dart/resolution_graph.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

import 'support/native_pub_fixture.dart';

void main() {
  late NativePubFixture origin;
  late NativePubFixture discovery;
  setUp(() async {
    origin = await NativePubFixture.create();
    discovery = await NativePubFixture.create();
  });
  tearDown(() async {
    await discovery.close();
    await origin.close();
  });

  Future<File> pack(Directory package, String name) async {
    final archive = File('${origin.directory.path}/$name.tar.gz');
    final result = await origin.run(package, [
      'pub',
      'publish',
      '--to-archive',
      archive.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    return archive;
  }

  Future<void> preload(
    Directory consumer,
    File archive, {
    String? hosted,
  }) async {
    final result = await origin.run(
      consumer,
      ['pub', 'cache', 'preload', archive.path],
      cache: 'replay',
      hosted: hosted,
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  }

  Future<ProcessResult> get(Directory package, {bool replay = false}) => replay
      ? origin.run(package, [
          'pub',
          'get',
          '--offline',
          '--no-example',
          '--no-precompile',
        ], cache: 'replay')
      : discovery.run(package, [
          'pub',
          'get',
          '--no-example',
          '--no-precompile',
        ]);

  void expectOk(ProcessResult result) =>
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

  Map<String, String> sources() => {
    'default': discovery.url,
    origin.url: discovery.url,
  };

  test(
    'shadow native solve backtracks and original-source replay freezes exact archive inputs',
    () async {
      final core = origin.package(
        'core',
        'rk_fixture_core',
        '0.2.0',
        sdk: '^3.0.0',
      );
      final coreArchive = await pack(core, 'core');
      origin.host(origin.package('old-core', 'rk_fixture_core', '0.1.0'));
      discovery.discover(core, sources());
      for (final version in ['1.0.0', '2.0.0']) {
        final bridge = origin.package(
          'bridge$version',
          'rk_fixture_bridge',
          version,
          dependencies:
              '  rk_fixture_core:\n    hosted: ${origin.url}\n    version: ${version == '1.0.0' ? '^0.2.0' : '^0.1.0'}\n',
        );
        origin.host(bridge);
        discovery.discover(bridge, sources());
      }
      const requirements =
          '  rk_fixture_core: ">=0.1.0 <0.3.0"\n  rk_fixture_bridge: ">=1.0.0 <3.0.0"\n';
      final shadow = discovery.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: requirements,
        sdk: '^3.0.0',
      );
      discovery.rewriteSources(shadow, sources());
      expectOk(await get(shadow));
      final solved = discovery.lock(shadow)['packages'] as Map;
      expect((solved['rk_fixture_core'] as Map)['version'], '0.2.0');
      expect((solved['rk_fixture_bridge'] as Map)['version'], '1.0.0');

      // Nothing in discovery is a runtime artifact. A new, empty cache receives
      // native archives under the original identities, never discovery URLs.
      final consumer = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: requirements,
        sdk: '^3.0.0',
        library: "export 'package:rk_fixture_core/rk_fixture_core.dart';\n",
        extra: {
          'bin/main.dart':
              "import 'package:rk_fixture_consumer/rk_fixture_consumer.dart';\nvoid main() => print(value);\n",
        },
      );
      final manifest = File('${consumer.path}/pubspec.yaml').readAsStringSync();
      await preload(consumer, coreArchive);
      await preload(
        consumer,
        origin.hostedArchive('rk_fixture_bridge', '1.0.0'),
      );
      expectOk(await get(consumer, replay: true));
      final expectedGraph = discovery.graph(
        shadow,
        sources: {discovery.url: origin.url},
      );
      expect(origin.graph(consumer), expectedGraph);
      final nativeDiscovery = DartResolutionGraph.read(
        shadow,
        registryAliases: {discovery.url: origin.url},
      );
      final replayGraph = DartResolutionGraph.read(consumer);
      replayGraph.requireSameSelection(nativeDiscovery);
      replayGraph.requireArchives({
        'rk_fixture_core': Sha256.hex(coreArchive.readAsBytesSync()),
      });
      final before = origin.lock(consumer);
      final packages = before['packages'] as Map;
      final bound = packages['rk_fixture_core'] as Map;
      expect(bound['version'], '0.2.0');
      expect((bound['description'] as Map)['url'], origin.url);
      expect(
        (bound['description'] as Map)['sha256'],
        Sha256.hex(coreArchive.readAsBytesSync()),
      );
      expect((packages['rk_fixture_bridge'] as Map)['version'], '1.0.0');

      final archive = File('${origin.directory.path}/consumer.tar.gz');
      final packed = await origin.run(consumer, [
        'pub',
        'publish',
        '--to-archive',
        archive.path,
      ], cache: 'replay');
      expectOk(packed);
      DartResolutionGraph.read(consumer).requireSameArtifacts(replayGraph);
      DartResolutionGraph.read(consumer).requireArchives({
        'rk_fixture_core': Sha256.hex(coreArchive.readAsBytesSync()),
      });
      expect(origin.graph(consumer), expectedGraph);
      expect(
        origin.lock(consumer),
        before,
        reason: 'native packaging must retain frozen original-source bindings',
      );
      final extracted = origin.extract(archive, 'result');
      expect(
        File('${extracted.path}/pubspec.yaml').readAsStringSync(),
        manifest,
      );
      expect(
        File('${extracted.path}/pubspec_overrides.yaml').existsSync(),
        isFalse,
      );
      final config = File(
        '${consumer.path}/.dart_tool/package_config.json',
      ).readAsStringSync();
      expect(config, isNot(contains(discovery.directory.path)));
      expectOk(
        await origin.run(consumer, [
          'compile',
          'exe',
          'bin/main.dart',
          '-o',
          '${origin.directory.path}/consumer-bin',
        ], cache: 'replay'),
      );
      expect(
        (await Process.run('${origin.directory.path}/consumer-bin', [])).stdout,
        '42\n',
      );
      expect(origin.graph(consumer), expectedGraph);
      expect(origin.lock(consumer), before);
      DartResolutionGraph.read(consumer).requireSameArtifacts(replayGraph);
      expect(
        File(
          '${consumer.path}/.dart_tool/package_config.json',
        ).readAsStringSync(),
        config,
      );
      expect(
        [
          ...origin.requests,
          ...discovery.requests,
        ].where((r) => !r.startsWith('GET ')),
        isEmpty,
      );
      if (Platform.environment['RK_NATIVE_PROOF_REPORT'] case final path?) {
        File(path).writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert({
            'sdk': (await Process.run(origin.dart, ['--version'])).stdout.toString().trim(),
            'provider_version': '0.2.0',
            'consumer_version': '0.1.0',
            'selected_bridge': '1.0.0',
            'provider_archive_sha256': Sha256.hex(coreArchive.readAsBytesSync()),
            'provider_manifest_sha256': Sha256.hex(File('${core.path}/pubspec.yaml').readAsBytesSync()),
            'consumer_archive_sha256': Sha256.hex(archive.readAsBytesSync()),
            'consumer_manifest_sha256': Sha256.hex(utf8.encode(manifest)),
            'original_sources_replayed': true,
            'lock_unchanged_after_packaging': true,
            'consumer_output': '42',
          })}\n',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'selected candidate does not erase a hosted transitive contradiction',
    () async {
      final core = origin.package('core', 'rk_fixture_core', '0.2.0');
      discovery.discover(core, sources());
      discovery.discover(
        origin.package(
          'bridge',
          'rk_fixture_bridge',
          '2.0.0',
          dependencies: '  rk_fixture_core: ^0.1.0\n',
        ),
        sources(),
      );
      final shadow = discovery.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies:
            '  rk_fixture_core: ">=0.1.0 <0.3.0"\n  rk_fixture_bridge: 2.0.0\n',
      );
      discovery.rewriteSources(shadow, sources());
      final result = await get(shadow);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('version solving failed'));
    },
  );

  test('native discovery exposes a transitive-only artifact edge', () async {
    discovery.discover(
      origin.package('core', 'rk_fixture_core', '0.2.0'),
      sources(),
    );
    discovery.discover(
      origin.package(
        'bridge',
        'rk_fixture_bridge',
        '1.0.0',
        dependencies: '  rk_fixture_core: ^0.2.0\n',
      ),
      sources(),
    );
    final shadow = discovery.package(
      'consumer',
      'rk_fixture_consumer',
      '0.1.0',
      dependencies: '  rk_fixture_bridge: 1.0.0\n',
    );
    discovery.rewriteSources(shadow, sources());
    expectOk(await get(shadow));
    final graph =
        jsonDecode(
              File(
                '${shadow.path}/.dart_tool/package_graph.json',
              ).readAsStringSync(),
            )
            as Map;
    final bridge = (graph['packages'] as List).cast<Map>().singleWhere(
      (package) => package['name'] == 'rk_fixture_bridge',
    );
    expect(bridge['dependencies'], contains('rk_fixture_core'));
    expect(
      (discovery.lock(shadow)['packages'] as Map)['rk_fixture_core'],
      isNotNull,
    );
  });

  test(
    'source mapping keeps same-name other-registry packages separate',
    () async {
      final other = await NativePubFixture.create();
      final otherView = await NativePubFixture.create();
      addTearDown(other.close);
      addTearDown(otherView.close);
      final otherCore = other.package(
        'core',
        'rk_fixture_core',
        '0.2.0',
        library: 'const value = 99;\n',
      );
      other.host(otherCore);
      final mapping = {...sources(), other.url: otherView.url};
      otherView.discover(otherCore, mapping);
      discovery.discover(
        origin.package('core', 'rk_fixture_core', '0.2.0'),
        mapping,
      );
      final shadow = discovery.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies:
            '  rk_fixture_core:\n    hosted: ${other.url}\n    version: ^0.2.0\n',
      );
      discovery.rewriteSources(shadow, mapping);
      expectOk(await get(shadow));
      final bound =
          (discovery.lock(shadow)['packages'] as Map)['rk_fixture_core'] as Map;
      expect((bound['description'] as Map)['url'], otherView.url);
      expect(
        discovery.requests.where((r) => r.contains('rk_fixture_core')),
        isEmpty,
      );

      final consumer = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies:
            '  rk_fixture_core:\n    hosted: ${other.url}\n    version: ^0.2.0\n',
        extra: {
          'bin/main.dart':
              "import 'package:rk_fixture_core/rk_fixture_core.dart';\nvoid main() => print(value);\n",
        },
      );
      await preload(
        consumer,
        other.hostedArchive('rk_fixture_core', '0.2.0'),
        hosted: other.url,
      );
      expectOk(await get(consumer, replay: true));
      expectOk(
        await origin.run(consumer, [
          'compile',
          'exe',
          'bin/main.dart',
          '-o',
          '${origin.directory.path}/other-bin',
        ], cache: 'replay'),
      );
      expect(
        (await Process.run('${origin.directory.path}/other-bin', [])).stdout,
        '99\n',
      );

      discovery.discover(
        origin.package(
          'bridge',
          'rk_fixture_bridge',
          '1.0.0',
          dependencies: '  rk_fixture_core: ^0.2.0\n',
        ),
        mapping,
      );
      final conflicting = discovery.package(
        'conflict',
        'rk_fixture_conflict',
        '0.1.0',
        dependencies:
            '  rk_fixture_core:\n    hosted: ${other.url}\n    version: ^0.2.0\n  rk_fixture_bridge: 1.0.0\n',
      );
      discovery.rewriteSources(conflicting, mapping);
      final conflict = await get(conflicting);
      expect(
        conflict.exitCode,
        isNot(0),
        reason: '${conflict.stdout}\n${conflict.stderr}',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'native validation and compilation see omitted provider payload files',
    () async {
      final core = origin.package(
        'core',
        'rk_fixture_core',
        '0.2.0',
        extra: {'.pubignore': 'lib/rk_fixture_core.dart\n'},
      );
      final archive = await pack(core, 'core-omitted');
      final extracted = origin.extract(archive, 'omitted');
      expect(
        File('${extracted.path}/lib/rk_fixture_core.dart').existsSync(),
        isFalse,
      );
      final consumer = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: '  rk_fixture_core: ^0.2.0\n',
        library: "export 'package:rk_fixture_core/rk_fixture_core.dart';\n",
        extra: {
          'bin/main.dart':
              "import 'package:rk_fixture_consumer/rk_fixture_consumer.dart';\nvoid main() => print(value);\n",
        },
      );
      await preload(consumer, archive);
      expectOk(await get(consumer, replay: true));
      final packed = await origin.run(consumer, [
        'pub',
        'publish',
        '--to-archive',
        '${origin.directory.path}/broken-consumer.tar.gz',
      ], cache: 'replay');
      // Pub reports analyzer errors as warnings, so an archive can still exist.
      expect(
        '${packed.stdout}\n${packed.stderr}',
        contains('rk_fixture_core.dart'),
      );
      expect(
        '${packed.stdout}\n${packed.stderr}'.toLowerCase(),
        contains('potential issues'),
      );
      final compiled = await origin.run(consumer, [
        'compile',
        'exe',
        'bin/main.dart',
        '-o',
        '${origin.directory.path}/broken-bin',
      ], cache: 'replay');
      expect(compiled.exitCode, isNot(0));
      expect(
        '${compiled.stdout}\n${compiled.stderr}',
        contains('rk_fixture_core.dart'),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'provider dev dependencies do not become consumer requirements',
    () async {
      final helper = origin.package('helper', 'rk_fixture_helper', '0.1.0');
      final core = origin.package(
        'core',
        'rk_fixture_core',
        '0.2.0',
        development: '  rk_fixture_helper:\n    path: ${helper.path}\n',
      );
      final archive = await pack(core, 'core-with-dev');
      discovery.discover(core, sources());
      final shadow = discovery.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: '  rk_fixture_core: ^0.2.0\n',
      );
      discovery.rewriteSources(shadow, sources());
      expectOk(await get(shadow));
      expect(
        (discovery.lock(shadow)['packages'] as Map).keys,
        isNot(contains('rk_fixture_helper')),
      );
      helper.deleteSync(recursive: true);
      final consumer = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: '  rk_fixture_core: ^0.2.0\n',
      );
      await preload(consumer, archive);
      expectOk(await get(consumer, replay: true));
      expect(
        (origin.lock(consumer)['packages'] as Map).keys,
        isNot(contains('rk_fixture_helper')),
      );
    },
  );

  test(
    'dev-only helper back-edge survives and external probe checks only runtime',
    () async {
      final core = origin.package('core', 'rk_fixture_core', '0.2.0');
      final coreArchive = await pack(core, 'core');
      final helper = origin.package(
        'helper',
        'rk_fixture_helper',
        '0.1.0',
        dependencies: '  rk_fixture_consumer: ^0.1.0\n',
      );
      final consumer = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: '  rk_fixture_core: ^0.2.0\n',
        development: '  rk_fixture_helper: ^0.1.0\n',
        extra: {
          'pubspec_overrides.yaml':
              'dependency_overrides:\n  rk_fixture_helper:\n    path: ${helper.path}\n',
        },
      );
      File(
        '${consumer.path}/pubspec.yaml',
      ).writeAsStringSync('resolution: workspace\n', mode: FileMode.append);
      File('${consumer.path}/pubspec_overrides.yaml').writeAsStringSync(
        'resolution: null\nworkspace: []\n',
        mode: FileMode.append,
      );
      await preload(consumer, coreArchive);
      expectOk(await get(consumer, replay: true));
      final archive = File('${origin.directory.path}/consumer.tar.gz');
      expectOk(
        await origin.run(consumer, [
          'pub',
          'publish',
          '--to-archive',
          archive.path,
        ], cache: 'replay'),
      );
      final extracted = origin.extract(archive, 'extracted');
      expect(
        File('${extracted.path}/pubspec.yaml').readAsStringSync(),
        contains('resolution: workspace'),
      );
      expect(
        File('${extracted.path}/pubspec_overrides.yaml').existsSync(),
        isFalse,
      );
      helper.deleteSync(recursive: true);
      final probe = origin.package(
        'external',
        'rk_fixture_external',
        '0.1.0',
        dependencies: '  rk_fixture_consumer:\n    path: ${extracted.path}\n',
      );
      final unavailable = await origin.run(probe, [
        'pub',
        'get',
        '--no-example',
      ], cache: 'public-probe');
      expect(unavailable.exitCode, isNot(0));
      expect(unavailable.stderr, contains('rk_fixture_core'));
      expect(
        origin.requests.where((r) => r.contains('rk_fixture_helper')),
        isEmpty,
      );
      origin.host(core);
      expectOk(
        await origin.run(probe, [
          'pub',
          'get',
          '--no-example',
        ], cache: 'public-probe-available'),
      );
      expect(
        (origin.lock(probe)['packages'] as Map).keys,
        isNot(contains('rk_fixture_helper')),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'original archive replay rejects metadata that concealed a dependency',
    () async {
      final declared = origin.package('declared', 'rk_fixture_core', '0.2.0');
      discovery.discover(declared, sources());
      final shadow = discovery.package(
        'shadow',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: '  rk_fixture_core: ^0.2.0\n',
      );
      discovery.rewriteSources(shadow, sources());
      expectOk(await get(shadow));
      origin.host(origin.package('missing', 'rk_fixture_missing', '1.0.0'));
      final actual = origin.package(
        'actual',
        'rk_fixture_core',
        '0.2.0',
        dependencies: '  rk_fixture_missing: 1.0.0\n',
      );
      final archive = await pack(actual, 'actual');
      final consumer = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: '  rk_fixture_core: ^0.2.0\n',
      );
      await preload(consumer, archive);
      final replay = await get(consumer, replay: true);
      expect(replay.exitCode, isNot(0));
      expect(replay.stderr, contains('rk_fixture_missing'));
    },
  );
  test(
    'successful replay still exposes a concealed edge to an already selected package',
    () async {
      final shared = origin.package('shared', 'rk_fixture_shared', '1.0.0');
      origin.host(shared);
      discovery.discover(shared, sources());
      discovery.discover(
        origin.package('declared', 'rk_fixture_core', '0.2.0'),
        sources(),
      );
      const requirements =
          '  rk_fixture_core: ^0.2.0\n  rk_fixture_shared: 1.0.0\n';
      final shadow = discovery.package(
        'shadow',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: requirements,
      );
      discovery.rewriteSources(shadow, sources());
      expectOk(await get(shadow));
      final actual = origin.package(
        'actual',
        'rk_fixture_core',
        '0.2.0',
        dependencies: '  rk_fixture_shared: 1.0.0\n',
      );
      final archive = await pack(actual, 'actual');
      final consumer = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: requirements,
      );
      await preload(consumer, archive);
      await preload(
        consumer,
        origin.hostedArchive('rk_fixture_shared', '1.0.0'),
      );
      expectOk(await get(consumer, replay: true));
      final expectedGraph = discovery.graph(
        shadow,
        sources: {discovery.url: origin.url},
      );
      final actualGraph = origin.graph(consumer);
      expect(actualGraph.keys, unorderedEquals(expectedGraph.keys));
      expect(
        (actualGraph['rk_fixture_core'] as Map)['version'],
        (expectedGraph['rk_fixture_core'] as Map)['version'],
      );
      expect(
        (expectedGraph['rk_fixture_core'] as Map)['dependencies'],
        isEmpty,
      );
      expect((actualGraph['rk_fixture_core'] as Map)['dependencies'], [
        'rk_fixture_shared',
      ]);
      // A successful solve and identical coordinate set do not prove the planned
      // producer graph. Production must reject this full-graph mismatch.
      expect(actualGraph, isNot(equals(expectedGraph)));
      expect(
        () => DartResolutionGraph.read(consumer).requireSameSelection(
          DartResolutionGraph.read(
            shadow,
            registryAliases: {discovery.url: origin.url},
          ),
        ),
        throwsStateError,
      );
    },
  );
}
