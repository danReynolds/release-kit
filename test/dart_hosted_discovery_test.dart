import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/native_dependencies.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/native/dart/archive_replay.dart';
import 'package:rk/src/native/dart/dependencies.dart';
import 'package:rk/src/native/dart/hosted_discovery.dart';
import 'package:rk/src/native/dart/hosted_archive.dart';
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

  Future<DartDiscoveryResult> verify(
    Directory root,
    DartDiscoveryResult frozen,
    List<DartDiscoveryCandidate> candidates,
  ) => DartHostedDiscovery(
    tools: const SystemTools(),
    compiler: origin.dart,
    defaultRegistry: origin.url,
  ).verifyFrozen(root: manifest(root), frozen: frozen, candidates: candidates);

  test(
    'frozen verification authenticates exact versions without adopting newer registry or provider truth',
    () async {
      final core = origin.package('core', 'rk_fixture_core', '0.2.0');
      final local = candidate(core);
      origin.host(
        origin.package(
          'bridge1',
          'rk_fixture_bridge',
          '1.0.0',
          dependencies: '  rk_fixture_core: ^0.2.0\n',
        ),
      );
      final root = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: '  rk_fixture_bridge: ^1.0.0\n',
      );
      final original = await discover(root, [local]);
      final frozen = DartDiscoveryResult.fromJson(original.toJson());
      origin.host(core);
      origin.host(
        origin.package(
          'bridge2',
          'rk_fixture_bridge',
          '1.1.0',
          dependencies: '  rk_fixture_core: ^0.1.0\n',
        ),
      );
      origin.archiveQuery = '?signed=refreshed-fetch';
      origin.requests.clear();
      final verified = await verify(root, frozen, [local]);
      expect(verified.toJson(), frozen.toJson());
      expect(verified.packages['rk_fixture_core']!.candidate, same(local));
      expect(
        verified.packages['rk_fixture_bridge']!.archiveUrl!.query,
        'signed=refreshed-fetch',
      );
      expect(origin.requests, [
        'GET /api/packages/rk_fixture_bridge/versions/1.0.0',
      ]);
      expect(jsonEncode(verified.toJson()), isNot(contains('refreshed-fetch')));
    },
  );

  test(
    'frozen hosted choice stays hosted when an eligible local stage later appears',
    () async {
      final core = origin.package('core', 'rk_fixture_core', '0.2.0');
      origin.host(core);
      final root = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: '  rk_fixture_core: ^0.2.0\n',
      );
      final frozen = DartDiscoveryResult.fromJson(
        (await discover(root, [])).toJson(),
      );
      final verified = await verify(root, frozen, [candidate(core)]);
      expect(verified.packages['rk_fixture_core']!.candidate, isNull);
      expect(verified.toJson(), frozen.toJson());
    },
  );

  test(
    'frozen verification rejects forged integrity and changed real registry archives',
    () async {
      final core = origin.package('core', 'rk_fixture_core', '0.2.0');
      origin.host(core);
      final root = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: '  rk_fixture_core: ^0.2.0\n',
      );
      final frozen = await discover(root, []);
      final document =
          jsonDecode(jsonEncode(frozen.toJson())) as Map<String, dynamic>;
      document['packages']['rk_fixture_core']['archive_sha256'] = 'a' * 64;
      await expectLater(
        verify(root, DartDiscoveryResult.fromJson(document), []),
        throwsA(
          isA<StateError>().having(
            (e) => e.toString(),
            'source proof',
            contains('no longer authorizes frozen'),
          ),
        ),
      );
      File(
        '${core.path}/lib/rk_fixture_core.dart',
      ).writeAsStringSync('const value = 100;\n');
      origin.host(core);
      await expectLater(
        verify(root, frozen, []),
        throwsA(
          isA<StateError>().having(
            (e) => e.toString(),
            'registry drift',
            contains('no longer authorizes frozen'),
          ),
        ),
      );
    },
  );

  test(
    'frozen local choice requires current source and native root constraints',
    () async {
      final core = origin.package('core', 'rk_fixture_core', '0.2.0');
      final local = candidate(core);
      final root = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: '  rk_fixture_core: ^0.2.0\n',
      );
      final frozen = await discover(root, [local]);
      await expectLater(verify(root, frozen, []), throwsStateError);
      final pubspec = File('${core.path}/pubspec.yaml');
      final original = pubspec.readAsStringSync();
      pubspec.writeAsStringSync('$original\ncustom: changed\n');
      await expectLater(
        verify(root, frozen, [candidate(core)]),
        throwsFormatException,
      );
      pubspec.writeAsStringSync(original);
      final rootFile = File('${root.path}/pubspec.yaml');
      rootFile.writeAsStringSync(
        rootFile.readAsStringSync().replaceFirst(
          'rk_fixture_core: ^0.2.0',
          'rk_fixture_core: ^0.1.0',
        ),
      );
      await expectLater(
        verify(root, frozen, [local]),
        throwsA(
          isA<StateError>().having(
            (e) => e.toString(),
            'native constraint',
            contains('version solving failed'),
          ),
        ),
      );
    },
  );

  test(
    'frozen verification checks causal edges beyond authenticated coordinates',
    () async {
      final core = candidate(
        origin.package('core', 'rk_fixture_core', '0.2.0'),
      );
      origin.host(
        origin.package(
          'bridge',
          'rk_fixture_bridge',
          '1.0.0',
          dependencies: '  rk_fixture_core: ^0.2.0\n',
        ),
      );
      final root = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies:
            '  rk_fixture_core: ^0.2.0\n  rk_fixture_bridge: ^1.0.0\n',
      );
      final resolved = await discover(root, [core]);
      final document =
          jsonDecode(jsonEncode(resolved.toJson())) as Map<String, dynamic>;
      document['graph']['packages']['rk_fixture_bridge']['dependencies'] =
          <String>[];
      await expectLater(
        verify(root, DartDiscoveryResult.fromJson(document), [core]),
        throwsA(
          isA<StateError>().having(
            (e) => e.toString(),
            'graph drift',
            contains('graph changed'),
          ),
        ),
      );
    },
  );

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
          await DartHostedArchive.fetch(result.packages['rk_fixture_bridge']!),
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
    other.requests.clear();
    await expectLater(
      DartHostedDiscovery(
        tools: const SystemTools(),
        compiler: origin.dart,
        defaultRegistry: origin.url,
        maxRegistries: 1,
      ).verifyFrozen(
        root: manifest(root),
        frozen: DartDiscoveryResult.fromJson(result.toJson()),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.toString(),
          'pre-fetch registry bound',
          contains('registry limit'),
        ),
      ),
    );
    expect(other.requests, isEmpty);
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

  for (final destination in ['default', 'custom', 'none']) {
    test('root back-edge uses its $destination publication source', () async {
      final custom = await NativePubFixture.create();
      addTearDown(custom.close);
      final rootRegistry = destination == 'custom' ? custom.url : origin.url;
      final root = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '1.0.0',
        dependencies:
            '  rk_fixture_bridge:\n    hosted: ${custom.url}\n    version: ^1.0.0\n',
      );
      if (destination != 'default') {
        File('${root.path}/pubspec.yaml').writeAsStringSync(
          'publish_to: ${destination == 'custom' ? custom.url : 'none'}\n',
          mode: FileMode.append,
        );
      }
      custom.host(
        custom.package(
          'bridge',
          'rk_fixture_bridge',
          '1.0.0',
          dependencies:
              '  rk_fixture_consumer:\n    hosted: $rootRegistry\n    version: ^1.0.0\n',
        ),
      );
      final direct = await origin.run(root, [
        'pub',
        'get',
        '--no-example',
        '--no-precompile',
      ]);
      expect(direct.exitCode, 0, reason: '${direct.stdout}\n${direct.stderr}');
      final result = await discover(root, []);
      expect(result.graph.packages['rk_fixture_bridge']!.dependencies, {
        'rk_fixture_consumer',
      });
      final frozen = DartDiscoveryResult.fromJson(result.toJson());
      expect((await verify(root, frozen, [])).toJson(), frozen.toJson());
    });
  }

  test(
    'custom publication source cannot acquire a default-registry back-edge',
    () async {
      final custom = await NativePubFixture.create();
      addTearDown(custom.close);
      final root = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '1.0.0',
        dependencies: '  rk_fixture_bridge: ^1.0.0\n',
      );
      File(
        '${root.path}/pubspec.yaml',
      ).writeAsStringSync('publish_to: ${custom.url}\n', mode: FileMode.append);
      origin.host(
        origin.package(
          'bridge',
          'rk_fixture_bridge',
          '1.0.0',
          dependencies: '  rk_fixture_consumer: ^1.0.0\n',
        ),
      );
      await expectLater(
        discover(root, []),
        throwsA(
          isA<StateError>().having(
            (error) => '$error',
            'source guard',
            contains('root back-edge with a different source'),
          ),
        ),
      );
    },
  );

  test(
    'an explicit shorthand retains its original native SDK feature gate',
    () async {
      origin.host(origin.package('core', 'rk_fixture_core', '0.1.0'));
      final bad = origin.package(
        'bad',
        'rk_fixture_bad',
        '0.1.0',
        sdk: '">=2.12.0 <4.0.0"',
        dependencies:
            '  rk_fixture_core:\n    hosted: ${origin.url}\n    version: ^0.1.0\n',
      );
      final direct = await origin.run(bad, [
        'pub',
        'get',
        '--no-example',
        '--no-precompile',
      ]);
      expect(direct.exitCode, isNot(0));
      expect(
        '${direct.stdout}\n${direct.stderr}',
        contains('minimum SDK constraint of 2.15'),
      );
      await expectLater(
        discover(bad, []),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'native SDK gate',
            contains('minimum SDK constraint of 2.15'),
          ),
        ),
      );
      origin.host(bad);
      final consumer = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: '  rk_fixture_bad: ^0.1.0\n',
      );
      await expectLater(
        discover(consumer, []),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'provider SDK gate',
            contains('minimum SDK constraint of 2.15'),
          ),
        ),
      );
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
    final fetched = await DartHostedArchive.fetch(
      result.packages['rk_fixture_core']!,
    );
    expect(
      fetched.archive.sha256,
      result.packages['rk_fixture_core']!.archiveSha256,
    );
  });

  for (final malformed in ['json', 'utf8']) {
    test(
      'malformed $malformed metadata fails once without disclosing signed URLs',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          request.response.headers.contentType = ContentType.json;
          request.response.add([
            ...utf8.encode(
              '{"url":"https://cdn.test/a?token=temporary-secret",',
            ),
            if (malformed == 'utf8') 0xff,
            ...utf8.encode('bad}'),
          ]);
          await request.response.close();
        });
        final root = manifest(
          origin.package(
            'consumer',
            'rk_fixture_consumer',
            '1.0.0',
            dependencies: '  rk_fixture_dependency: any\n',
          ),
        );
        await expectLater(
          DartHostedDiscovery(
            tools: const SystemTools(),
            compiler: origin.dart,
            defaultRegistry: 'http://127.0.0.1:${server.port}',
          ).resolve(root: root),
          throwsA(
            isA<StateError>()
                .having(
                  (error) => '$error',
                  'safe diagnostic',
                  isNot(contains('temporary-secret')),
                )
                .having(
                  (error) =>
                      RegExp('malformed metadata').allMatches('$error').length,
                  'terminal shadow failure is not retried',
                  1,
                ),
          ),
        );
      },
    );
  }

  test(
    'external archive download checks bounds and the preselected integrity',
    () async {
      final core = origin.package('core', 'rk_fixture_core', '0.1.0');
      origin.host(core);
      final root = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: '  rk_fixture_core: ^0.1.0\n',
      );
      final selected = (await discover(root, [])).packages['rk_fixture_core']!;
      await expectLater(
        DartHostedArchive.fetch(selected, maxCompressedBytes: 1),
        throwsStateError,
      );
      File(
        '${core.path}/lib/rk_fixture_core.dart',
      ).writeAsStringSync('different bytes');
      origin.host(core);
      await expectLater(
        DartHostedArchive.fetch(selected),
        throwsFormatException,
      );
    },
  );

  test(
    'malformed and unsupported redirects never disclose signed query tokens',
    () async {
      origin.archiveQuery = '?token=initial-secret';
      origin.host(origin.package('core', 'rk_fixture_core', '0.1.0'));
      final root = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: '  rk_fixture_core: ^0.1.0\n',
      );
      final selected = (await discover(root, [])).packages['rk_fixture_core']!;
      for (final redirect in [
        'https://[invalid?token=redirect-secret',
        'file:///no-archive?token=redirect-secret',
      ]) {
        origin.archiveRedirect = redirect;
        await expectLater(
          DartHostedArchive.fetch(selected),
          throwsA(
            isA<StateError>().having(
              (error) => error.toString(),
              'redacted error',
              allOf(
                isNot(contains('initial-secret')),
                isNot(contains('redirect-secret')),
                contains('rk_fixture_core'),
              ),
            ),
          ),
        );
      }
    },
  );

  test('historical SDK lower bounds retain compatible hosted syntax', () async {
    origin.host(origin.package('core', 'rk_fixture_core', '0.1.0'));
    origin.host(
      origin.package(
        'bridge',
        'rk_fixture_bridge',
        '1.0.0',
        sdk: '">=2.12.0 <4.0.0"',
        dependencies: '  rk_fixture_core: ^0.1.0\n',
      ),
    );
    final root = origin.package(
      'consumer',
      'rk_fixture_consumer',
      '0.1.0',
      dependencies: '  rk_fixture_bridge: ^1.0.0\n',
    );
    final result = await discover(root, []);
    expect(
      result.packages['rk_fixture_bridge']!.manifest.fields['environment'],
      {'sdk': '>=2.12.0 <4.0.0'},
    );
    expect(
      result.graph.packages['rk_fixture_core']!.source,
      dartRegistryIdentity(origin.url),
    );
  });

  test(
    'unused historical source types do not veto a supported selected version',
    () async {
      origin.host(
        origin.package(
          'legacy',
          'rk_fixture_bridge',
          '0.1.0',
          dependencies:
              '  legacy:\n    git: https://unused.invalid/package.git\n',
        ),
      );
      origin.host(origin.package('current', 'rk_fixture_bridge', '1.0.0'));
      final root = origin.package(
        'consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: '  rk_fixture_bridge: ^1.0.0\n',
      );
      final result = await discover(root, []);
      expect(result.packages.keys, ['rk_fixture_bridge']);
      expect(result.packages['rk_fixture_bridge']!.manifest.version, '1.0.0');
    },
  );

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
