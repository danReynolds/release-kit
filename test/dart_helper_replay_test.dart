import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/native_stage_context.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/native/dart/archive_replay.dart';
import 'package:rk/src/native/dart/development_source.dart';
import 'package:rk/src/native/dart/hosted_discovery.dart';
import 'package:rk/src/native/dart/package_archive.dart';
import 'package:rk/src/native/dart/replay_sources.dart';
import 'package:rk/src/native/dart/stage_context.dart';
import 'package:rk/src/native/package_archive.dart';
import 'package:test/test.dart';

import 'support/native_pub_fixture.dart';

void main() {
  late NativePubFixture origin;
  late Directory root;
  late Directory helper;
  setUp(() async {
    origin = await NativePubFixture.create();
    root = origin.package(
      'core',
      'rk_fixture_core',
      '0.2.0',
      development: '  rk_fixture_helper: ^1.0.0\n',
    );
    helper = origin.package(
      'helper',
      'rk_fixture_helper',
      '1.0.0',
      dependencies: '  rk_fixture_core: ^0.2.0\n',
    );
  });
  tearDown(() => origin.close());
  DartPackageManifest manifest(Directory directory) =>
      DartPackageManifest.parse(
        File('${directory.path}/pubspec.yaml').readAsStringSync(),
      );
  DartDevelopmentSource binding() => DartDevelopmentSource(
    manifestPath: 'helper/pubspec.yaml',
    registry: origin.url,
    manifest: manifest(helper),
  );
  Future<DartDiscoveryResult> discover() => DartHostedDiscovery(
    tools: const SystemTools(),
    compiler: origin.dart,
    defaultRegistry: origin.url,
  ).resolve(root: manifest(root), developmentSources: [binding()]);
  DartReplaySources snapshot() {
    final copy = Directory('${origin.directory.path}/helper-snapshot')
      ..createSync();
    for (final file in helper.listSync(recursive: true).whereType<File>()) {
      final target = File(
        '${copy.path}/helper/${file.path.substring(helper.path.length + 1)}',
      );
      target.parent.createSync(recursive: true);
      target.writeAsBytesSync(file.readAsBytesSync());
    }
    File(
      '${copy.path}/helper/pubspec_overrides.yaml',
    ).writeAsStringSync('resolution: null\nworkspace: []\n');
    return DartReplaySources.capture(root: copy, bindings: [binding()]);
  }

  Future<DartArchiveReplay> prepare(
    DartDiscoveryResult discovery,
    DartReplaySources sources, {
    List<DartReplayArchive> archives = const [],
    Tools tools = const SystemTools(),
  }) => DartArchiveReplay.prepare(
    root: root,
    tools: tools,
    compiler: origin.dart,
    defaultRegistry: origin.url,
    discovered: discovery.graph,
    discovery: discovery,
    developmentSources: sources,
    archives: archives,
  );

  test(
    'forged matching graph cannot bypass incompatible original helper back-edge',
    () async {
      final selected = await discover();
      final helperFile = File('${helper.path}/pubspec.yaml');
      helperFile.writeAsStringSync(
        helperFile.readAsStringSync().replaceFirst('^0.2.0', '^0.1.0'),
      );
      final bad = binding();
      final document = jsonDecode(jsonEncode(selected.toJson())) as Map;
      final package = document['packages']['rk_fixture_helper'] as Map;
      package['manifest'] = bad.manifest.fields;
      package['manifest_sha256'] = bad.manifest.sha256;
      package['development_source'] = bad.toJson();
      final forged = DartDiscoveryResult.fromJson(document);
      final context = DartStageContext.discovered(
        root: manifest(root),
        defaultRegistry: origin.url,
        operation: DartStageOperation.pubArchive,
        consumers: ['pub-archive:rk_fixture_core'],
        discovery: forged,
      );
      expect(context.developmentSources.single.manifest.version, '1.0.0');
      await expectLater(
        prepare(context.discovery, snapshot()),
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'native constraints',
            contains('version solving failed'),
          ),
        ),
      );
      expect(File('${root.path}/pubspec_overrides.yaml').existsSync(), isFalse);
    },
  );

  test(
    'forged selected graph cannot bypass original root incoming constraint',
    () async {
      final selected = await discover();
      final file = File('${root.path}/pubspec.yaml');
      file.writeAsStringSync(
        file.readAsStringSync().replaceFirst('^1.0.0', '^2.0.0'),
      );
      await expectLater(
        prepare(selected, snapshot()),
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'native constraints',
            contains('version solving failed'),
          ),
        ),
      );
      expect(File('${root.path}/pubspec_overrides.yaml').existsSync(), isFalse);
    },
  );

  test(
    'original manifests defeat forged runtime reachability in context and native replay',
    () async {
      final selected = await discover();
      final bridge = origin.package(
        'bridge',
        'rk_fixture_bridge',
        '1.0.0',
        dependencies: '  rk_fixture_helper: ^1.0.0\n',
      );
      origin.host(bridge);
      final archive = await NativePackageArchive.read(
        origin.hostedArchive('rk_fixture_bridge', '1.0.0'),
      );
      final input = DartReplayArchive(
        registry: origin.url,
        archive: archive,
        discoveredManifest: manifest(bridge),
      );
      File('${root.path}/pubspec.yaml').writeAsStringSync(
        'dependencies:\n  rk_fixture_bridge: ^1.0.0\n',
        mode: FileMode.append,
      );
      final document = jsonDecode(jsonEncode(selected.toJson())) as Map;
      final graph = document['graph']['packages'] as Map;
      graph['rk_fixture_core']['dependencies'] = ['rk_fixture_bridge'];
      graph['rk_fixture_bridge'] = {
        'name': 'rk_fixture_bridge',
        'version': '1.0.0',
        'source': input.source,
        'dependencies': [],
        'devDependencies': [],
      };
      document['packages']['rk_fixture_bridge'] = {
        'registry': origin.url,
        'manifest': input.discoveredManifest.fields,
        'manifest_sha256': input.discoveredManifest.sha256,
        'archive_sha256': archive.sha256,
      };
      final forged = DartDiscoveryResult.fromJson(document);
      expect(
        () => DartStageContext.discovered(
          root: manifest(root),
          defaultRegistry: origin.url,
          operation: DartStageOperation.pubArchive,
          consumers: ['pub-archive:rk_fixture_core'],
          discovery: forged,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => '$e',
            'runtime guard',
            contains('runtime reachable'),
          ),
        ),
      );
      await expectLater(
        prepare(forged, snapshot(), archives: [input]),
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'native runtime guard',
            contains('runtime reachable'),
          ),
        ),
      );
      expect(File('${root.path}/pubspec_overrides.yaml').existsSync(), isFalse);
    },
  );

  test(
    'native helper location, library URI, source inventory and override integrity stay bound',
    () async {
      final selected = await discover();
      final sources = snapshot();
      final replay = await prepare(selected, sources);
      addTearDown(replay.close);
      final configFile = File('${root.path}/.dart_tool/package_config.json');
      final original = configFile.readAsStringSync();
      for (final field in ['rootUri', 'packageUri']) {
        final config = jsonDecode(original) as Map;
        final package = (config['packages'] as List).cast<Map>().singleWhere(
          (p) => p['name'] == 'rk_fixture_helper',
        );
        package[field] = field == 'rootUri' ? helper.uri.toString() : '../';
        configFile.writeAsStringSync(jsonEncode(config));
        expect(
          replay.verify,
          throwsA(
            isA<StateError>().having(
              (e) => '$e',
              'location guard',
              contains('outside its verified source'),
            ),
          ),
        );
        configFile.writeAsStringSync(original);
      }
      final overrides = File('${root.path}/pubspec_overrides.yaml');
      final originalOverrides = overrides.readAsStringSync();
      overrides.writeAsStringSync('{}');
      expect(replay.verify, throwsStateError);
      overrides.writeAsStringSync(originalOverrides);
      final helperDir = sources.directoryFor('rk_fixture_helper');
      final moved = helperDir.renameSync('${helperDir.path}-moved');
      Link(helperDir.path).createSync(moved.path);
      expect(replay.verify, throwsStateError);
      Link(helperDir.path).deleteSync();
      moved.renameSync(helperDir.path);
      replay.verify();
    },
  );

  test(
    'source mutation during native work is detected after the operation',
    () async {
      final selected = await discover();
      final sources = snapshot();
      final tools = _MutatingTools();
      final replay = await prepare(selected, sources, tools: tools);
      addTearDown(replay.close);
      tools.afterRun = () => File(
        '${sources.root.path}/helper/lib/rk_fixture_helper.dart',
      ).writeAsStringSync('const value = 999;\n');
      await expectLater(replay.run(['--version']), throwsStateError);
    },
  );

  test(
    'root cannot change after native constraint verification and acquire path overrides',
    () async {
      final selected = await discover();
      final sources = snapshot();
      final tools = _MutatingTools();
      tools.afterRun = () {
        final file = File('${root.path}/pubspec.yaml');
        file.writeAsStringSync(
          file.readAsStringSync().replaceFirst('^1.0.0', '^2.0.0'),
        );
      };
      await expectLater(
        prepare(selected, sources, tools: tools),
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'root guard',
            contains('root changed during constraint verification'),
          ),
        ),
      );
      expect(File('${root.path}/pubspec_overrides.yaml').existsSync(), isFalse);
    },
  );

  test(
    'format 3 cannot disguise a helper as an external archive slot',
    () async {
      final selected = await discover();
      final context = DartStageContext.discovered(
        root: manifest(root),
        defaultRegistry: origin.url,
        operation: DartStageOperation.pubArchive,
        consumers: ['pub-archive:rk_fixture_core'],
        discovery: selected,
      );
      final document = jsonDecode(jsonEncode(context.envelope.toJson())) as Map;
      document['bindings'] = [
        {
          'slot': 'rk_fixture_helper',
          'package': {
            'ecosystem': 'dart',
            'source': selected.graph.packages['rk_fixture_helper']!.source,
            'name': 'rk_fixture_helper',
          },
          'version': '1.0.0',
          'provider': null,
        },
      ];
      expect(
        () => DartStageContext.fromEnvelope(
          NativeStageContext.fromJson(document),
        ),
        throwsFormatException,
      );
    },
  );
}

final class _MutatingTools extends Tools {
  void Function()? afterRun;
  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) => throw StateError('unexpected interactive native operation');
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
    afterRun?.call();
    return result;
  }
}
