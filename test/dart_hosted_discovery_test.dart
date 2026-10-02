import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/native_dependencies.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/native/dart/archive_replay.dart';
import 'package:rk/src/native/dart/dependencies.dart';
import 'package:rk/src/native/dart/hosted_discovery.dart';
import 'package:rk/src/native/dart/package_archive.dart';
import 'package:rk/src/native/package_archive.dart';
import 'package:test/test.dart';

import 'support/native_pub_fixture.dart';

void main() {
  late NativePubFixture origin;
  setUp(() async => origin = await NativePubFixture.create());
  tearDown(() => origin.close());

  DartPackageManifest manifest(Directory root) => DartPackageManifest.parse(
    File('${root.path}/pubspec.yaml').readAsStringSync(),
  );
  DartDiscoveryCandidate candidate(Directory root, {String? registry}) {
    final source = registry ?? origin.url;
    final value = manifest(root);
    return DartDiscoveryCandidate(
      provider: NativeCandidate(
        package: NativePackage(
          ecosystem: 'dart',
          source: dartRegistryIdentity(source),
          name: value.name,
        ),
        version: value.version,
        unit: value.name,
        project: value.name,
        producer: 'pub-archive:${value.name}',
      ),
      registry: source,
      manifest: value,
    );
  }

  Future<DartDiscoveryResult> discover(
    Directory root,
    List<DartDiscoveryCandidate> candidates,
  ) => DartHostedDiscovery(
    tools: const SystemTools(),
    compiler: origin.dart,
    defaultRegistry: origin.url,
  ).resolve(root: manifest(root), candidates: candidates);

  test(
    'production discovery backtracks then real archive replay compiles the selected inputs',
    () async {
      final core = origin.package('core', 'rk_fixture_core', '0.2.0');
      final local = candidate(core);
      for (final version in ['1.0.0', '2.0.0']) {
        origin.host(
          origin.package(
            'bridge$version',
            'rk_fixture_bridge',
            version,
            dependencies:
                '  rk_fixture_core: ${version == '1.0.0' ? '^0.2.0' : '^0.1.0'}\n',
          ),
        );
      }
      final consumer = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies:
            '  rk_fixture_core: ^0.2.0\n  rk_fixture_bridge: ">=1.0.0 <3.0.0"\n',
        extra: {
          'bin/main.dart':
              "import 'package:rk_fixture_core/rk_fixture_core.dart';\nvoid main() => print(value);\n",
        },
      );
      final original = File('${consumer.path}/pubspec.yaml').readAsStringSync();
      final result = await discover(consumer, [local]);
      expect(result.packages['rk_fixture_core']!.candidate, same(local));
      expect(result.packages['rk_fixture_bridge']!.manifest.version, '1.0.0');
      expect(
        result.graph.packages['rk_fixture_core']!.source,
        dartRegistryIdentity(origin.url),
      );
      expect(
        origin.requests.every(
          (request) => request.startsWith('GET /api/packages/'),
        ),
        isTrue,
        reason: 'discovery must fetch metadata, never real package payloads',
      );
      expect(
        origin.requests.any((request) => request.contains('rk_fixture_core')),
        isFalse,
        reason:
            'a directly selected unpublished candidate needs no registry lookup',
      );
      final coreFile = File('${origin.directory.path}/core.tar.gz');
      final packed = await origin.run(core, [
        'pub',
        'publish',
        '--to-archive',
        coreFile.path,
      ]);
      expect(packed.exitCode, 0, reason: '${packed.stdout}\n${packed.stderr}');
      final replay = await DartArchiveReplay.prepare(
        root: consumer,
        tools: const SystemTools(),
        compiler: origin.dart,
        defaultRegistry: origin.url,
        discovered: result.graph,
        archives: [
          DartReplayArchive(
            registry: origin.url,
            archive: await NativePackageArchive.read(coreFile),
            discoveredManifest: result.packages['rk_fixture_core']!.manifest,
          ),
          DartReplayArchive(
            registry: origin.url,
            archive: await NativePackageArchive.read(
              origin.hostedArchive('rk_fixture_bridge', '1.0.0'),
              expectedSha256:
                  result.packages['rk_fixture_bridge']!.archiveSha256,
            ),
            discoveredManifest: result.packages['rk_fixture_bridge']!.manifest,
          ),
        ],
      );
      addTearDown(replay.close);
      final output = '${origin.directory.path}/consumer-bin';
      final compiled = await replay.run([
        'compile',
        'exe',
        'bin/main.dart',
        '-o',
        output,
      ]);
      expect(compiled.ok, isTrue, reason: compiled.transcript);
      replay.verify();
      expect((await Process.run(output, [])).stdout, '42\n');
      expect(
        File('${consumer.path}/pubspec.yaml').readAsStringSync(),
        original,
      );
      final serialized = jsonEncode(result.toJson());
      expect(serialized, isNot(contains('rk-dart-discovery-')));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'transitive discovery prefers a compatible local candidate over a newer public version',
    () async {
      final local = candidate(
        origin.package('core', 'rk_fixture_core', '0.2.0'),
      );
      origin.host(origin.package('public-core', 'rk_fixture_core', '0.3.0'));
      origin.host(
        origin.package(
          'bridge',
          'rk_fixture_bridge',
          '1.0.0',
          dependencies: '  rk_fixture_core: ">=0.2.0 <0.4.0"\n',
        ),
      );
      final root = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: '  rk_fixture_bridge: ^1.0.0\n',
      );
      final result = await discover(root, [local]);
      expect(result.packages['rk_fixture_core']!.candidate, same(local));
      expect(
        result.graph.packages['rk_fixture_bridge']!.dependencies,
        contains('rk_fixture_core'),
      );
      expect(result.packages['rk_fixture_core']!.manifest.version, '0.2.0');
    },
  );

  test(
    'incompatible and ineligible local packages retain normal hosted fallback',
    () async {
      final local = candidate(
        origin.package('core', 'rk_fixture_core', '0.2.0'),
      );
      origin.host(origin.package('public-core', 'rk_fixture_core', '0.1.0'));
      final root = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: '  rk_fixture_core: ^0.1.0\n',
      );
      for (final eligible in [
        <DartDiscoveryCandidate>[local],
        <DartDiscoveryCandidate>[],
      ]) {
        final result = await discover(root, eligible);
        expect(result.packages['rk_fixture_core']!.candidate, isNull);
        expect(result.packages['rk_fixture_core']!.manifest.version, '0.1.0');
        expect(result.packages['rk_fixture_core']!.archiveSha256, isNotNull);
      }
    },
  );

  test(
    'selected local candidate keeps a real transitive contradiction visible',
    () async {
      final local = candidate(
        origin.package('core', 'rk_fixture_core', '0.2.0'),
      );
      origin.host(origin.package('public-core', 'rk_fixture_core', '0.1.0'));
      origin.host(
        origin.package(
          'bridge',
          'rk_fixture_bridge',
          '2.0.0',
          dependencies: '  rk_fixture_core: ^0.1.0\n',
        ),
      );
      final root = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies:
            '  rk_fixture_core: ">=0.1.0 <0.3.0"\n  rk_fixture_bridge: 2.0.0\n',
      );
      await expectLater(
        discover(root, [local]),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'native diagnostic',
            contains('version solving failed'),
          ),
        ),
      );
    },
  );

  test('same-name other registry does not acquire the local candidate', () async {
    final other = await NativePubFixture.create();
    addTearDown(other.close);
    other.host(other.package('core', 'rk_fixture_core', '0.2.0'));
    final local = candidate(origin.package('core', 'rk_fixture_core', '0.2.0'));
    final root = origin.package(
      'consumer',
      'rk_fixture_consumer',
      '0.1.0',
      dependencies:
          '  rk_fixture_core:\n    hosted: ${other.url}\n    version: ^0.2.0\n',
    );
    final result = await discover(root, [local]);
    expect(result.packages['rk_fixture_core']!.candidate, isNull);
    expect(result.packages['rk_fixture_core']!.registry, other.url);
    expect(origin.requests, isEmpty);
  });

  test(
    'default dependencies in another registry still refer to the original default',
    () async {
      final other = await NativePubFixture.create();
      addTearDown(other.close);
      other.host(
        other.package(
          'bridge',
          'rk_fixture_bridge',
          '1.0.0',
          dependencies: '  rk_fixture_core: ^0.2.0\n',
        ),
      );
      final local = candidate(
        origin.package('core', 'rk_fixture_core', '0.2.0'),
      );
      final root = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies:
            '  rk_fixture_bridge:\n    hosted: ${other.url}\n    version: ^1.0.0\n',
      );
      final result = await discover(root, [local]);
      expect(result.packages['rk_fixture_core']!.candidate, same(local));
      expect(result.packages['rk_fixture_core']!.registry, origin.url);
      expect(result.packages['rk_fixture_bridge']!.registry, other.url);
    },
  );

  test(
    'workspace membership is detached only inside owned discovery scratch',
    () async {
      final local = candidate(
        origin.package('core', 'rk_fixture_core', '0.2.0'),
      );
      final root = origin.package(
        'workspace/consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: '  rk_fixture_core: ^0.2.0\n',
      );
      File(
        '${root.path}/pubspec.yaml',
      ).writeAsStringSync('resolution: workspace\n', mode: FileMode.append);
      final original = File('${root.path}/pubspec.yaml').readAsStringSync();
      final result = await discover(root, [local]);
      expect(result.packages['rk_fixture_core']!.candidate, same(local));
      expect(File('${root.path}/pubspec.yaml').readAsStringSync(), original);
      expect(File('${root.path}/pubspec_overrides.yaml').existsSync(), isFalse);
    },
  );

  test('signed archive URLs remain temporary fetch details', () async {
    origin.archiveQuery = '?token=temporary-secret&expiry=123';
    origin.host(origin.package('core', 'rk_fixture_core', '0.1.0'));
    final root = origin.package(
      'consumer',
      'rk_fixture_consumer',
      '0.1.0',
      dependencies: '  rk_fixture_core: ^0.1.0\n',
    );
    final result = await discover(root, []);
    expect(
      result.packages['rk_fixture_core']!.archiveUrl!.query,
      contains('temporary-secret'),
    );
    expect(jsonEncode(result.toJson()), isNot(contains('temporary-secret')));
  });

  test(
    'dependency-only dev metadata cannot acquire registries or affect the solve',
    () async {
      final core = origin.package(
        'core',
        'rk_fixture_core',
        '0.1.0',
        development:
            '  ignored:\n    hosted: http://unreachable.invalid\n    version: any\n',
      );
      origin.host(core);
      final root = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: '  rk_fixture_core: ^0.1.0\n',
      );
      final result = await discover(root, []);
      expect(result.packages.keys, ['rk_fixture_core']);
      expect(
        result.packages['rk_fixture_core']!.manifest.fields['dev_dependencies'],
        isNotNull,
        reason:
            'the full original manifest still authorizes the later real archive',
      );
    },
  );

  test(
    'failed speculative metadata requests do not override native success',
    () async {
      final unavailable = await NativePubFixture.create();
      addTearDown(unavailable.close);
      unavailable.packageStatus['rk_fixture_broken'] = 500;
      origin.host(origin.package('old-bridge', 'rk_fixture_bridge', '1.0.0'));
      origin.host(
        origin.package(
          'new-bridge',
          'rk_fixture_bridge',
          '2.0.0',
          dependencies:
              '  rk_fixture_broken:\n    hosted: ${unavailable.url}\n    version: any\n',
        ),
      );
      final root = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: '  rk_fixture_bridge: 1.0.0\n',
      );
      final result = await discover(root, []);
      expect(result.packages.keys, ['rk_fixture_bridge']);
      expect(result.packages['rk_fixture_bridge']!.manifest.version, '1.0.0');
    },
  );

  test('metadata fetch and registry expansion have explicit bounds', () async {
    origin.host(origin.package('core', 'rk_fixture_core', '0.1.0'));
    final root = manifest(
      origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: '  rk_fixture_core: ^0.1.0\n',
      ),
    );
    await expectLater(
      DartHostedDiscovery(
        tools: const SystemTools(),
        compiler: origin.dart,
        defaultRegistry: origin.url,
        maxMetadataBytes: 10,
      ).resolve(root: root),
      throwsA(
        isA<StateError>().having(
          (error) => error.toString(),
          'bounded diagnostic',
          contains('metadata limit'),
        ),
      ),
    );
    await expectLater(
      DartHostedDiscovery(
        tools: const SystemTools(),
        compiler: origin.dart,
        defaultRegistry: origin.url,
        maxRegistries: 0,
      ).resolve(root: root),
      throwsStateError,
    );
  });
}
