import 'dart:io';

import 'package:test/test.dart';

import 'support/native_pub_fixture.dart';

void main() {
  late NativePubFixture fixture;
  setUp(() async => fixture = await NativePubFixture.create());
  tearDown(() async => fixture.close());

  Future<Directory> stagedCore() async {
    final source = fixture.package('provider', 'rk_fixture_core', '0.2.0');
    final archive = File('${fixture.directory.path}/core.tar.gz');
    final packed = await fixture.run(source, [
      'pub',
      'publish',
      '--to-archive',
      archive.path,
    ]);
    expect(packed.exitCode, 0, reason: '${packed.stdout}\n${packed.stderr}');
    final extracted = fixture.extract(archive, 'workspace/core');
    expect(
      File('${extracted.path}/pubspec.yaml').readAsStringSync(),
      File('${source.path}/pubspec.yaml').readAsStringSync(),
    );
    return extracted;
  }

  test(
    'native workspace stages independent versions from the provider archive',
    () async {
      final core = await stagedCore();
      final consumer = fixture.package(
        'workspace/consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies: '  rk_fixture_core: 0.2.0\n',
        library: "export 'package:rk_fixture_core/rk_fixture_core.dart';\n",
        extra: {
          'bin/main.dart':
              "import 'package:rk_fixture_consumer/rk_fixture_consumer.dart';\nvoid main() => print(value);\n",
        },
      );
      final original = File('${consumer.path}/pubspec.yaml').readAsStringSync();
      fixture.workspace('workspace', [consumer, core]);
      final got = await fixture.run(consumer, ['pub', 'get']);
      expect(got.exitCode, 0, reason: '${got.stdout}\n${got.stderr}');
      final packed = await fixture.run(consumer, [
        'pub',
        'publish',
        '--to-archive',
        '${fixture.directory.path}/consumer.tar.gz',
      ]);
      expect(packed.exitCode, 0, reason: '${packed.stdout}\n${packed.stderr}');
      final result = fixture.extract(
        File('${fixture.directory.path}/consumer.tar.gz'),
        'result',
      );
      expect(File('${result.path}/pubspec.yaml').readAsStringSync(), original);
      expect(
        File('${result.path}/pubspec_overrides.yaml').existsSync(),
        isFalse,
      );
      final compiled = await fixture.run(consumer, [
        'compile',
        'exe',
        'bin/main.dart',
        '-o',
        '${fixture.directory.path}/consumer',
      ]);
      expect(
        compiled.exitCode,
        0,
        reason: '${compiled.stdout}\n${compiled.stderr}',
      );
      final ran = await Process.run('${fixture.directory.path}/consumer', []);
      expect(ran.stdout, '42\n');
      expect(
        fixture.requests.where((request) => !request.startsWith('GET ')),
        isEmpty,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'native workspace preserves hosted transitive backtracking',
    () async {
      final core = await stagedCore();
      fixture.host(
        fixture.package(
          'bridge1',
          'rk_fixture_bridge',
          '1.0.0',
          dependencies: '  rk_fixture_core: ^0.2.0\n',
        ),
      );
      fixture.host(
        fixture.package(
          'bridge2',
          'rk_fixture_bridge',
          '2.0.0',
          dependencies: '  rk_fixture_core: ^0.1.0\n',
        ),
      );
      final consumer = fixture.package(
        'workspace/consumer',
        'rk_fixture_consumer',
        '0.1.0',
        dependencies:
            '  rk_fixture_core: ^0.2.0\n  rk_fixture_bridge: ">=1.0.0 <3.0.0"\n',
      );
      fixture.workspace('workspace', [consumer, core]);
      final got = await fixture.run(consumer, ['pub', 'get']);
      expect(got.exitCode, 0, reason: '${got.stdout}\n${got.stderr}');
      expect(got.stdout, contains('rk_fixture_bridge 1.0.0'));
      expect(
        fixture.requests,
        contains('GET /packages/rk_fixture_bridge-1.0.0.tar.gz'),
      );
      expect(
        fixture.requests,
        isNot(contains('GET /packages/rk_fixture_bridge-2.0.0.tar.gz')),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('workspace rejects an incompatible transitive constraint', () async {
    final core = await stagedCore();
    fixture.host(
      fixture.package(
        'bridge',
        'rk_fixture_bridge',
        '1.0.0',
        dependencies: '  rk_fixture_core: ^0.1.0\n',
      ),
    );
    final consumer = fixture.package(
      'workspace/consumer',
      'rk_fixture_consumer',
      '0.1.0',
      dependencies: '  rk_fixture_core: ^0.2.0\n  rk_fixture_bridge: 1.0.0\n',
    );
    fixture.workspace('workspace', [consumer, core]);
    final got = await fixture.run(consumer, ['pub', 'get']);
    expect(got.exitCode, isNot(0), reason: '${got.stdout}\n${got.stderr}');
    expect(got.stderr, contains('version solving failed'));
  });

  test(
    'workspace rejects an otherwise compatible older SDK constraint',
    () async {
      final core = await stagedCore();
      final consumer = fixture.package(
        'workspace/consumer',
        'rk_fixture_consumer',
        '0.1.0',
        sdk: '^3.0.0',
        dependencies: '  rk_fixture_core: ^0.2.0\n',
      );
      fixture.workspace('workspace', [consumer, core]);
      final got = await fixture.run(consumer, ['pub', 'get']);
      expect(got.exitCode, isNot(0), reason: '${got.stdout}\n${got.stderr}');
      expect(got.stderr, contains('requires at least language version'));
    },
  );

  test('workspace does not enforce explicit source identity', () async {
    final other = await NativePubFixture.create();
    addTearDown(other.close);
    other.host(
      other.package(
        'other-core',
        'rk_fixture_core',
        '0.2.0',
        library: 'const value = 99;\n',
      ),
    );
    final core = await stagedCore();
    final consumer = fixture.package(
      'workspace/consumer',
      'rk_fixture_consumer',
      '0.1.0',
      dependencies:
          '  rk_fixture_core:\n    hosted: ${other.url}\n    version: ^0.2.0\n',
    );
    fixture.workspace('workspace', [consumer, core]);
    final got = await fixture.run(consumer, ['pub', 'get']);
    expect(got.exitCode, 0, reason: '${got.stdout}\n${got.stderr}');
    expect(other.requests, isEmpty);
  });

  test('workspace discovers a transitive-only staged dependency', () async {
    final core = await stagedCore();
    fixture.host(
      fixture.package(
        'bridge',
        'rk_fixture_bridge',
        '1.0.0',
        dependencies: '  rk_fixture_core: ^0.2.0\n',
      ),
    );
    final consumer = fixture.package(
      'workspace/consumer',
      'rk_fixture_consumer',
      '0.1.0',
      dependencies: '  rk_fixture_bridge: 1.0.0\n',
    );
    fixture.workspace('workspace', [consumer, core]);
    final got = await fixture.run(consumer, ['pub', 'get']);
    expect(got.exitCode, 0, reason: '${got.stdout}\n${got.stderr}');
    final graph = File(
      '${fixture.directory.path}/workspace/.dart_tool/package_graph.json',
    ).readAsStringSync();
    expect(graph, contains('rk_fixture_core'));
  });

  test(
    'native preloaded original-source archive can be packed from an offline solve',
    () async {
      await stagedCore();
      final consumer = fixture.package(
        'preload/consumer',
        'rk_fixture_consumer',
        '0.1.0',
        sdk: '^3.0.0',
        dependencies: '  rk_fixture_core: ^0.2.0\n',
        library: "export 'package:rk_fixture_core/rk_fixture_core.dart';\n",
      );
      final preload = await fixture.run(consumer, [
        'pub',
        'cache',
        'preload',
        '${fixture.directory.path}/core.tar.gz',
      ]);
      expect(
        preload.exitCode,
        0,
        reason: '${preload.stdout}\n${preload.stderr}',
      );
      final get = await fixture.run(consumer, ['pub', 'get', '--offline']);
      expect(get.exitCode, 0, reason: '${get.stdout}\n${get.stderr}');
      final packed = await fixture.run(consumer, [
        'pub',
        'publish',
        '--to-archive',
        '${fixture.directory.path}/preload-consumer.tar.gz',
      ]);
      expect(packed.exitCode, 0, reason: '${packed.stdout}\n${packed.stderr}');
    },
  );
}
