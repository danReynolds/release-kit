import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/native/dart/archive_replay.dart';
import 'package:rk/src/native/dart/dependencies.dart';
import 'package:rk/src/native/dart/package_archive.dart';
import 'package:rk/src/native/dart/package_configuration.dart';
import 'package:rk/src/native/dart/public_consumer.dart';
import 'package:rk/src/native/package_archive.dart';
import 'package:test/test.dart';

import 'support/native_pub_fixture.dart';

void main() {
  late NativePubFixture origin;
  setUp(() async => origin = await NativePubFixture.create());
  tearDown(() => origin.close());

  Future<DartReplayArchive> prospective(Directory root) async {
    origin.host(root);
    final manifest = DartPackageManifest.parse(
      File('${root.path}/pubspec.yaml').readAsStringSync(),
    );
    final file = origin.hostedArchive(manifest.name, manifest.version);
    final archive = await NativePackageArchive.read(file);
    origin.packageStatus[manifest.name] = HttpStatus.notFound;
    return DartReplayArchive(
      registry: origin.url,
      archive: archive,
      discoveredManifest: manifest,
    );
  }

  for (final workspace in [false, true]) {
    test(
      'prospective hosted consumer preserves runtime back-edge with workspace=$workspace and no dev helpers',
      () async {
        final root = origin.package(
          'consumer',
          'consumer',
          '0.2.0',
          dependencies: '  bridge: ^1.0.0\n',
          development: '  unpublished_helper: any\n',
        );
        if (workspace) {
          File('${root.path}/pubspec.yaml').writeAsStringSync(
            'resolution: workspace\nworkspace: [absent_member]\n',
            mode: FileMode.append,
          );
        }
        origin.host(
          origin.package(
            'bridge',
            'bridge',
            '1.0.0',
            dependencies: '  consumer: ">=0.1.0 <0.3.0"\n',
          ),
        );
        final input = await prospective(root);
        origin.requests.clear();
        final tools = _ProbeTools();
        final graph = await DartPublicConsumer.resolve(
          consumer: input,
          tools: tools,
          compiler: origin.dart,
          defaultRegistry: origin.url,
        );
        expect(
          graph.packages['consumer']!.source,
          dartRegistryIdentity(origin.url),
        );
        expect(graph.packages['consumer']!.archiveSha256, input.archive.sha256);
        expect(graph.packages['consumer']!.dependencies, {'bridge'});
        expect(graph.packages['bridge']!.dependencies, {'consumer'});
        expect(graph.packages.containsKey('unpublished_helper'), isFalse);
        expect(
          origin.requests.any(
            (request) => request.contains('unpublished_helper'),
          ),
          isFalse,
        );
        expect(origin.requests, contains('GET /packages/bridge-1.0.0.tar.gz'));
        expect(tools.preloads, 1);
        expect(
          tools.roots.every((root) => !Directory(root).existsSync()),
          isTrue,
        );
      },
    );
  }

  test(
    'public-only SDK branch is checked by the actual native consumer solve',
    () async {
      final input = await prospective(
        origin.package(
          'consumer',
          'consumer',
          '0.2.0',
          dependencies: '  flutter:\n    sdk: flutter\n',
        ),
      );
      final tools = _ProbeTools();
      await expectLater(
        DartPublicConsumer.resolve(
          consumer: input,
          tools: tools,
          compiler: origin.dart,
          defaultRegistry: origin.url,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'native SDK refusal',
            contains('flutter'),
          ),
        ),
      );
      // The fixture SDK is standalone Dart. This proves an SDK branch still
      // reaches native resolution rather than being accepted by projection alone.
      expect(tools.preloads, 1);
      expect(tools.gets, 1);
    },
  );

  test(
    'fresh public range selects newer dependency without changing prospective bytes',
    () async {
      final input = await prospective(
        origin.package(
          'consumer',
          'consumer',
          '0.2.0',
          dependencies: '  bridge: ^1.0.0\n',
        ),
      );
      origin.host(origin.package('old', 'bridge', '1.0.0'));
      origin.host(origin.package('new', 'bridge', '1.1.0'));
      final graph = await DartPublicConsumer.resolve(
        consumer: input,
        tools: const SystemTools(),
        compiler: origin.dart,
        defaultRegistry: origin.url,
      );
      expect(graph.packages['bridge']!.version, '1.1.0');
      expect(graph.packages['consumer']!.archiveSha256, input.archive.sha256);
    },
  );

  for (final failure in [
    'missing runtime',
    'incompatible backedge',
    'wrong registry',
  ]) {
    test(
      'public consumer refuses $failure with no staged dependency fallback',
      () async {
        final other = await NativePubFixture.create();
        addTearDown(other.close);
        final input = await prospective(
          origin.package(
            'consumer',
            'consumer',
            '0.2.0',
            dependencies: '  bridge: ^1.0.0\n',
          ),
        );
        final edge = switch (failure) {
          'missing runtime' => '  missing: any\n',
          'incompatible backedge' => '  consumer: ^0.1.0\n',
          _ =>
            '  consumer:\n    hosted:\n      name: consumer\n      url: ${other.url}\n    version: ^0.2.0\n',
        };
        origin.host(
          origin.package('bridge', 'bridge', '1.0.0', dependencies: edge),
        );
        final tools = _ProbeTools();
        await expectLater(
          DartPublicConsumer.resolve(
            consumer: input,
            tools: tools,
            compiler: origin.dart,
            defaultRegistry: origin.url,
          ),
          throwsStateError,
        );
        expect(tools.preloads, 1);
        expect(
          tools.roots.every((root) => !Directory(root).existsSync()),
          isTrue,
        );
      },
    );
  }

  test(
    'successful native get cannot replace prospective consumer with same-version public bytes',
    () async {
      final input = await prospective(
        origin.package(
          'consumer',
          'consumer',
          '0.2.0',
          dependencies: '  bridge: ^1.0.0\n',
        ),
      );
      origin.host(origin.package('bridge', 'bridge', '1.0.0'));
      origin.packageStatus.remove('consumer');
      origin.host(
        origin.package(
          'replacement',
          'consumer',
          '0.2.0',
          dependencies: '  bridge: ^1.0.0\n',
          library: 'const replacement = 99;\n',
        ),
      );
      await expectLater(
        DartPublicConsumer.resolve(
          consumer: input,
          tools: const SystemTools(),
          compiler: origin.dart,
          defaultRegistry: origin.url,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => '$error',
            'integrity',
            contains('verified archive for consumer'),
          ),
        ),
      );
      expect(origin.requests, contains('GET /packages/consumer-0.2.0.tar.gz'));
    },
  );

  for (final mutation in ['payload', 'packageUri']) {
    test(
      'public consumer checks cached $mutation after native success',
      () async {
        final input = await prospective(
          origin.package('consumer', 'consumer', '0.2.0'),
        );
        final tools = _ProbeTools(
          afterGet: (root) {
            if (mutation == 'payload') {
              final location = dartPackageLocations(
                Directory(root),
              )['consumer']!;
              File(
                '${Directory.fromUri(location.root).path}/lib/consumer.dart',
              ).writeAsStringSync('changed native cache bytes');
            } else {
              final file = File('$root/.dart_tool/package_config.json');
              final config = jsonDecode(file.readAsStringSync()) as Map;
              for (final package in config['packages'] as List) {
                if (package['name'] == 'consumer') package['packageUri'] = '.';
              }
              file.writeAsStringSync(jsonEncode(config));
            }
          },
        );
        await expectLater(
          DartPublicConsumer.resolve(
            consumer: input,
            tools: tools,
            compiler: origin.dart,
            defaultRegistry: origin.url,
          ),
          throwsA(
            mutation == 'payload'
                ? isA<FormatException>().having(
                    (e) => e.message,
                    'detail',
                    contains('native package cache differs'),
                  )
                : isA<StateError>().having(
                    (e) => e.message,
                    'detail',
                    contains('public consumer package configuration'),
                  ),
          ),
        );
        expect(
          tools.roots.every((root) => !Directory(root).existsSync()),
          isTrue,
        );
      },
    );
  }

  test(
    'prospective registry and implicit runtime registry remain distinct',
    () async {
      final other = await NativePubFixture.create();
      addTearDown(other.close);
      final input = await prospective(
        origin.package(
          'consumer',
          'consumer',
          '0.2.0',
          dependencies: '  bridge: ^1.0.0\n',
        ),
      );
      origin.host(
        origin.package(
          'bridge',
          'bridge',
          '1.0.0',
          dependencies:
              '  consumer:\n    hosted:\n      name: consumer\n      url: ${other.url}\n    version: ^0.2.0\n',
        ),
      );
      final graph = await DartPublicConsumer.resolve(
        consumer: DartReplayArchive(
          registry: other.url,
          archive: input.archive,
          discoveredManifest: input.discoveredManifest,
        ),
        tools: const SystemTools(),
        compiler: origin.dart,
        defaultRegistry: origin.url,
      );
      expect(
        graph.packages['consumer']!.source,
        dartRegistryIdentity(other.url),
      );
      expect(
        graph.packages['bridge']!.source,
        dartRegistryIdentity(origin.url),
      );
      expect(other.requests, contains('GET /api/packages/consumer'));
      expect(
        other.requests.any((request) => request.contains('bridge')),
        isFalse,
      );
    },
  );
}

final class _ProbeTools implements Tools {
  _ProbeTools({this.afterGet});
  final void Function(String root)? afterGet;
  int preloads = 0;
  int gets = 0;
  final roots = <String>[];

  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    expect(arguments.contains('publish'), isFalse);
    expect(arguments.contains('--offline'), isFalse);
    expect(arguments.contains('--enforce-lockfile'), isFalse);
    if (arguments.contains('preload')) preloads++;
    if (arguments.contains('get')) gets++;
    roots.add(workingDirectory!);
    final result = await const SystemTools().run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      timeout: timeout,
    );
    if (arguments.contains('get') && result.ok) {
      afterGet?.call(workingDirectory);
    }
    return result;
  }

  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) => throw StateError('public check must not acquire a session');
}
