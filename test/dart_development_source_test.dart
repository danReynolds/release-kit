import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/native_dependencies.dart';
import 'package:rk/src/engine/native_stage_context.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/native/dart/dependencies.dart';
import 'package:rk/src/native/dart/development_source.dart';
import 'package:rk/src/native/dart/hosted_discovery.dart';
import 'package:rk/src/native/dart/package_archive.dart';
import 'package:rk/src/native/dart/stage_inputs.dart';
import 'package:rk/src/native/dart/stage_context.dart';
import 'package:test/test.dart';

import 'support/native_pub_fixture.dart';

void main() {
  late NativePubFixture origin;
  setUp(() async => origin = await NativePubFixture.create());
  tearDown(() => origin.close());

  DartPackageManifest manifest(Directory root) => DartPackageManifest.parse(
    File('${root.path}/pubspec.yaml').readAsStringSync(),
  );
  DartHostedDiscovery discovery() => DartHostedDiscovery(
    tools: const SystemTools(),
    compiler: origin.dart,
    defaultRegistry: origin.url,
  );
  DartDevelopmentSource helper(Directory root) => DartDevelopmentSource(
    manifestPath:
        '${root.path.substring(origin.directory.path.length + 1)}/pubspec.yaml',
    registry: origin.url,
    manifest: DartPackageManifest.developmentSource(
      readDartYamlDocument(
        File('${root.path}/pubspec.yaml').readAsStringSync(),
      ),
    ),
  );
  DartDiscoveryCandidate candidate(Directory root) => DartDiscoveryCandidate(
    provider: NativeCandidate(
      package: NativePackage(
        ecosystem: 'dart',
        source: dartRegistryIdentity(origin.url),
        name: manifest(root).name,
      ),
      version: manifest(root).version,
      unit: 'helper',
      project: manifest(root).name,
      producer: 'pub-archive:${manifest(root).name}',
    ),
    registry: origin.url,
    manifest: manifest(root),
  );

  test(
    'native helper back-edge and ignored development dependencies retain source provenance',
    () async {
      final root = origin.package(
        'core',
        'rk_fixture_core',
        '0.2.0',
        development: '  rk_fixture_helper: ^1.0.0\n',
      );
      final source = helper(
        origin.package(
          'helper',
          'rk_fixture_helper',
          '1.0.0',
          dependencies: '  rk_fixture_core: ^0.2.0\n',
          development: '  rk_fixture_missing: any\n',
        ),
      );
      final selected = await discovery().resolve(
        root: manifest(root),
        developmentSources: [source],
      );
      final package = selected.packages['rk_fixture_helper']!;
      expect(package.developmentSource, same(source));
      expect(package.candidate, isNull);
      expect(package.archiveSha256, isNull);
      expect(package.archiveUrl, isNull);
      expect(selected.packages.containsKey('rk_fixture_missing'), isFalse);
      expect(selected.graph.packages['rk_fixture_helper']!.dependencies, {
        'rk_fixture_core',
      });
      expect(
        origin.requests,
        isNot(contains('GET /api/packages/rk_fixture_helper')),
      );
      final frozen = DartDiscoveryResult.fromJson(selected.toJson());
      expect(
        (await discovery().verifyFrozen(
          root: manifest(root),
          frozen: frozen,
          developmentSources: [source],
        )).toJson(),
        frozen.toJson(),
      );
      await expectLater(
        discovery().verifyFrozen(root: manifest(root), frozen: frozen),
        throwsStateError,
      );
      await expectLater(
        discovery().verifyFrozen(
          root: manifest(root),
          frozen: frozen,
          developmentSources: [
            DartDevelopmentSource(
              manifestPath: 'elsewhere/pubspec.yaml',
              registry: source.registry,
              manifest: source.manifest,
            ),
          ],
        ),
        throwsStateError,
      );
      final forged = jsonDecode(jsonEncode(selected.toJson())) as Map;
      (forged['packages']['rk_fixture_helper'] as Map)['archive_sha256'] =
          'a' * 64;
      expect(() => DartDiscoveryResult.fromJson(forged), throwsFormatException);
    },
  );

  test(
    'unversioned private helper uses native 0.0.0 without rewriting original manifest',
    () async {
      final root = origin.package(
        'core',
        'rk_fixture_core',
        '0.2.0',
        development: '  rk_fixture_helper: any\n',
      );
      final directory = origin.package(
        'helper',
        'rk_fixture_helper',
        '1.0.0',
        dependencies: '  rk_fixture_core: ^0.2.0\n',
      );
      final file = File('${directory.path}/pubspec.yaml');
      file.writeAsStringSync(
        file.readAsStringSync().replaceFirst(
          'version: 1.0.0\n',
          'publish_to: none\n',
        ),
      );
      final original = file.readAsStringSync();
      final source = helper(directory);
      final selected = await discovery().resolve(
        root: manifest(root),
        developmentSources: [source],
      );
      expect(selected.graph.packages['rk_fixture_helper']!.version, '0.0.0');
      expect(source.manifest.fields.containsKey('version'), isFalse);
      expect(file.readAsStringSync(), original);
      expect(
        DartDiscoveryResult.fromJson(selected.toJson()).toJson(),
        selected.toJson(),
      );
      expect(() => DartPackageManifest.parse(original), throwsFormatException);
    },
  );

  test(
    'native constraints reject incompatible root back-edge before overrides',
    () async {
      final root = origin.package(
        'core',
        'rk_fixture_core',
        '0.2.0',
        development: '  rk_fixture_helper: ^1.0.0\n',
      );
      final source = helper(
        origin.package(
          'helper',
          'rk_fixture_helper',
          '1.0.0',
          dependencies: '  rk_fixture_core: ^0.1.0\n',
        ),
      );
      await expectLater(
        discovery().resolve(root: manifest(root), developmentSources: [source]),
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'native failure',
            contains('version solving failed'),
          ),
        ),
      );
      expect(File('${root.path}/pubspec_overrides.yaml').existsSync(), isFalse);
    },
  );

  test(
    'native transitive inbound constraint cannot be bypassed by helper mapping',
    () async {
      final root = origin.package(
        'core',
        'rk_fixture_core',
        '0.2.0',
        development:
            '  rk_fixture_helper: ^1.0.0\n  rk_fixture_bridge: ^1.0.0\n',
      );
      final source = helper(
        origin.package('helper', 'rk_fixture_helper', '1.0.0'),
      );
      origin.host(
        origin.package(
          'bridge',
          'rk_fixture_bridge',
          '1.0.0',
          dependencies: '  rk_fixture_helper: ^2.0.0\n',
        ),
      );
      await expectLater(
        discovery().resolve(root: manifest(root), developmentSources: [source]),
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'native failure',
            contains('version solving failed'),
          ),
        ),
      );
    },
  );

  test(
    'runtime diamond promotes helper to archive candidate or hosted resolution',
    () async {
      final root = origin.package(
        'core',
        'rk_fixture_core',
        '0.2.0',
        dependencies: '  rk_fixture_bridge: ^1.0.0\n',
        development: '  rk_fixture_helper: ^1.0.0\n',
      );
      final directory = origin.package('helper', 'rk_fixture_helper', '1.0.0');
      final source = helper(directory);
      origin.host(
        origin.package(
          'bridge',
          'rk_fixture_bridge',
          '1.0.0',
          dependencies: '  rk_fixture_helper: ^1.0.0\n',
        ),
      );
      final local = candidate(directory);
      final selected = await discovery().resolve(
        root: manifest(root),
        developmentSources: [source],
        candidates: [local],
      );
      expect(selected.packages['rk_fixture_helper']!.candidate, same(local));
      expect(selected.packages['rk_fixture_helper']!.developmentSource, isNull);
      origin.host(directory);
      final hosted = await discovery().resolve(
        root: manifest(root),
        developmentSources: [source],
      );
      expect(hosted.packages['rk_fixture_helper']!.developmentSource, isNull);
      expect(hosted.packages['rk_fixture_helper']!.archiveSha256, isNotNull);
      final frozen = DartDiscoveryResult.fromJson(hosted.toJson());
      expect(
        (await discovery().verifyFrozen(
          root: manifest(root),
          frozen: frozen,
          developmentSources: [source],
          candidates: [local],
        )).toJson(),
        frozen.toJson(),
      );
    },
  );

  test(
    'promotion refusal names runtime path and bounded bridge-version policy',
    () async {
      final root = origin.package(
        'core',
        'rk_fixture_core',
        '0.2.0',
        dependencies: '  rk_fixture_bridge: ^1.0.0\n',
        development: '  rk_fixture_helper: ^1.0.0\n',
      );
      final source = helper(
        origin.package('helper', 'rk_fixture_helper', '1.0.0'),
      );
      origin.host(origin.package('bridge-old', 'rk_fixture_bridge', '1.0.0'));
      origin.host(
        origin.package(
          'bridge-new',
          'rk_fixture_bridge',
          '1.1.0',
          dependencies: '  rk_fixture_helper: ^1.0.0\n',
        ),
      );
      await expectLater(
        discovery().resolve(root: manifest(root), developmentSources: [source]),
        throwsA(
          isA<StateError>()
              .having(
                (e) => '$e',
                'runtime path',
                contains(
                  'rk_fixture_core -> rk_fixture_bridge -> rk_fixture_helper',
                ),
              )
              .having(
                (e) => '$e',
                'bounded policy',
                contains('does not search older bridge versions'),
              ),
        ),
      );
    },
  );

  test(
    'original runtime declaration prohibits source with a duplicate development requirement',
    () async {
      final root = origin.package(
        'core',
        'rk_fixture_core',
        '0.2.0',
        dependencies: '  rk_fixture_helper: ^1.0.0\n',
        development: '  rk_fixture_helper: ^2.0.0\n',
      );
      final directory = origin.package('helper', 'rk_fixture_helper', '2.0.0');
      final source = helper(directory);
      await expectLater(
        discovery().resolve(root: manifest(root), developmentSources: [source]),
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'runtime path',
            contains('rk_fixture_core -> rk_fixture_helper'),
          ),
        ),
      );
      origin.host(directory);
      await expectLater(
        discovery().resolve(root: manifest(root), developmentSources: [source]),
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'native constraint conflict',
            contains('version solving failed'),
          ),
        ),
      );
    },
  );

  test(
    'same-name helper cannot capture another registry or unsupported runtime path',
    () async {
      final other = await NativePubFixture.create();
      addTearDown(other.close);
      final source = helper(
        origin.package('helper', 'rk_fixture_helper', '1.0.0'),
      );
      final root = origin.package(
        'core',
        'rk_fixture_core',
        '0.2.0',
        development:
            '  rk_fixture_helper:\n    hosted: ${other.url}\n    version: ^1.0.0\n',
      );
      other.host(other.package('helper', 'rk_fixture_helper', '1.0.0'));
      final selected = await discovery().resolve(
        root: manifest(root),
        developmentSources: [source],
      );
      expect(selected.packages['rk_fixture_helper']!.registry, other.url);
      expect(selected.packages['rk_fixture_helper']!.developmentSource, isNull);
      final file = File('${root.path}/pubspec.yaml');
      file.writeAsStringSync(
        file.readAsStringSync().replaceFirst(
          'hosted: ${other.url}',
          'path: ../helper',
        ),
      );
      await expectLater(
        discovery().resolve(root: manifest(root), developmentSources: [source]),
        throwsStateError,
      );
    },
  );

  test(
    'root back-edge from a different registry is refused even if Pub unifies root name',
    () async {
      final other = await NativePubFixture.create();
      addTearDown(other.close);
      final root = origin.package(
        'core',
        'rk_fixture_core',
        '0.2.0',
        development: '  rk_fixture_helper: ^1.0.0\n',
      );
      final source = helper(
        origin.package(
          'helper',
          'rk_fixture_helper',
          '1.0.0',
          dependencies:
              '  rk_fixture_core:\n    hosted: ${other.url}\n    version: ^0.2.0\n',
        ),
      );
      await expectLater(
        discovery().resolve(root: manifest(root), developmentSources: [source]),
        throwsStateError,
      );
    },
  );

  test('indirect hosted back-edge cannot hide another root registry', () async {
    final other = await NativePubFixture.create();
    addTearDown(other.close);
    final root = origin.package(
      'core',
      'rk_fixture_core',
      '0.2.0',
      development: '  rk_fixture_helper: ^1.0.0\n',
    );
    final source = helper(
      origin.package(
        'helper',
        'rk_fixture_helper',
        '1.0.0',
        dependencies: '  rk_fixture_bridge: ^1.0.0\n',
      ),
    );
    origin.host(
      origin.package(
        'bridge',
        'rk_fixture_bridge',
        '1.0.0',
        dependencies:
            '  rk_fixture_core:\n    hosted: ${other.url}\n    version: ^0.2.0\n',
      ),
    );
    await expectLater(
      discovery().resolve(root: manifest(root), developmentSources: [source]),
      throwsA(
        isA<StateError>().having(
          (e) => '$e',
          'source guard',
          contains(
            'rk_fixture_bridge has a root back-edge with a different source',
          ),
        ),
      ),
    );
  });

  test(
    'archive-only stage contexts refuse helper evidence until receipt-bound replay exists',
    () async {
      final root = origin.package(
        'core',
        'rk_fixture_core',
        '0.2.0',
        development: '  rk_fixture_helper: ^1.0.0\n',
      );
      final source = helper(
        origin.package('helper', 'rk_fixture_helper', '1.0.0'),
      );
      final selected = await discovery().resolve(
        root: manifest(root),
        developmentSources: [source],
      );
      final refusal = isA<FormatException>().having(
        (e) => '$e',
        'replay boundary',
        contains('source-helper contexts require receipt-bound replay support'),
      );
      expect(
        () => DartStageContext.discovered(
          root: manifest(root),
          defaultRegistry: origin.url,
          operation: DartStageOperation.pubArchive,
          consumers: ['pub-archive:rk_fixture_core'],
          discovery: selected,
        ),
        throwsA(refusal),
      );
      final serialized = NativeStageContext(
        context: 'dart:pubArchive:rk_fixture_core',
        ecosystem: 'dart',
        owner: 'rk_fixture_core',
        format: 2,
        consumers: ['pub-archive:rk_fixture_core'],
        bindings: [
          NativeStageBinding(
            slot: 'rk_fixture_helper',
            package: NativePackage(
              ecosystem: 'dart',
              source: dartRegistryIdentity(origin.url),
              name: 'rk_fixture_helper',
            ),
            version: '1.0.0',
          ),
        ],
        native: {
          'root_manifest': manifest(root).fields,
          'default_registry': origin.url,
          'operation': 'pubArchive',
          'resolution': selected.toJson(),
          'lockfile': null,
        },
      );
      expect(
        () => DartStageContext.fromEnvelope(
          NativeStageContext.fromJson(serialized.toJson()),
        ),
        throwsA(refusal),
      );
    },
  );

  test(
    'source reader returns only native-authorized workspace paths and unversioned manifests',
    () async {
      const config =
          'schema = 2\n[release.core]\npath = "packages/core"\npublish = ["pub.dev"]\n';
      const core =
          'name: core\nversion: 0.2.0\nresolution: workspace\nenvironment:\n  sdk: ^3.10.4\n';
      const helperText =
          'name: helper\npublish_to: none\nresolution: workspace\nenvironment:\n  sdk: ^3.10.4\n';
      final files = {
        'pubspec.yaml':
            'name: workspace\npublish_to: none\nenvironment:\n  sdk: ^3.10.4\nworkspace:\n  - packages/core\n  - support/helper\n',
        'packages/core/pubspec.yaml': core,
        'support/helper/pubspec.yaml': helperText,
        'unrelated/pubspec.yaml': 'name: unrelated\nversion: 1.0.0\n',
      };
      DartStageInputs inputs(SourceTree source) {
        final diagnostics = Diagnostics();
        final parsed = ReleaseConfig.parse(
          config,
          'release.toml',
          diagnostics,
        )!;
        final project = Resolution.resolve(
          parsed,
          source,
          diagnostics,
        )!.allProjects.single;
        expect(diagnostics.isEmpty, isTrue);
        return DartStageInputs.read(
          source: source,
          project: project,
          operation: DartStageOperation.pubArchive,
        );
      }

      final sources = await inputs(MemorySourceTree(files)).developmentSources(
        tools: const SystemTools(),
        compiler: origin.dart,
        defaultRegistry: origin.url,
      );
      expect(sources.map((s) => s.manifest.name), contains('helper'));
      expect(sources.map((s) => s.manifest.name), isNot(contains('unrelated')));
      final selected = sources.singleWhere((s) => s.manifest.name == 'helper');
      expect(selected.manifestPath, 'support/helper/pubspec.yaml');
      expect(selected.manifest.version, '0.0.0');
      expect(selected.manifest.fields.containsKey('version'), isFalse);
      expect(
        DartDevelopmentSource.fromJson(selected.toJson()).toJson(),
        selected.toJson(),
      );
      await expectLater(
        inputs(
          MemorySourceTree({...files}..remove('support/helper/pubspec.yaml')),
        ).developmentSources(
          tools: const SystemTools(),
          compiler: origin.dart,
          defaultRegistry: origin.url,
        ),
        throwsStateError,
      );
      await expectLater(
        inputs(
          MemorySourceTree({
            ...files,
            'support/helper/pubspec_overrides.yaml':
                'dependency_overrides: {}\n',
          }),
        ).developmentSources(
          tools: const SystemTools(),
          compiler: origin.dart,
          defaultRegistry: origin.url,
        ),
        throwsStateError,
      );
      expect(
        () => DartDevelopmentSource(
          manifestPath: '../helper/pubspec.yaml',
          registry: origin.url,
          manifest: selected.manifest,
        ),
        throwsA(anything),
      );
    },
  );
}
