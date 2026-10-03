import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/native_dependencies.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/native/dart/archive_replay.dart';
import 'package:rk/src/native/dart/dependencies.dart';
import 'package:rk/src/native/dart/dependency_lock.dart';
import 'package:rk/src/native/dart/hosted_archive.dart';
import 'package:rk/src/native/dart/hosted_discovery.dart';
import 'package:rk/src/native/dart/package_archive.dart';
import 'package:rk/src/native/dart/stage_inputs.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

import 'support/native_pub_fixture.dart';

void main() {
  group('native lock preference', () {
    late NativePubFixture origin;
    setUp(() async => origin = await NativePubFixture.create());
    tearDown(() => origin.close());

    DartPackageManifest manifest(Directory directory) =>
        DartPackageManifest.parse(
          File('${directory.path}/pubspec.yaml').readAsStringSync(),
        );
    DartHostedDiscovery discovery() => DartHostedDiscovery(
      tools: const SystemTools(),
      compiler: origin.dart,
      defaultRegistry: origin.url,
    );
    DartDiscoveryCandidate candidate(Directory root) => DartDiscoveryCandidate(
      provider: NativeCandidate(
        package: NativePackage(
          ecosystem: 'dart',
          source: dartRegistryIdentity(origin.url),
          name: manifest(root).name,
        ),
        version: manifest(root).version,
        unit: 'core',
        project: manifest(root).name,
        producer: 'pub-archive:${manifest(root).name}',
      ),
      registry: origin.url,
      manifest: manifest(root),
    );
    Future<DartDependencyLock> getLock(Directory root) async {
      final result = await origin.run(root, [
        'pub',
        'get',
        '--no-example',
        '--no-precompile',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      return DartDependencyLock.parse(
        File('${root.path}/pubspec.lock').readAsStringSync(),
        path: 'pubspec.lock',
      );
    }

    test(
      'ordinary native get retains an older lock and replays its real bytes',
      () async {
        origin.host(
          origin.package(
            'remote1',
            'rk_fixture_remote',
            '1.0.0',
            library: 'const value = 7;\n',
          ),
        );
        final root = origin.package(
          'app',
          'rk_fixture_app',
          '0.1.0',
          dependencies: '  rk_fixture_remote: ^1.0.0\n',
          extra: {
            'bin/main.dart':
                "import 'package:rk_fixture_remote/rk_fixture_remote.dart';\nvoid main() => print(value);\n",
          },
        );
        final lock = await getLock(root);
        origin.host(
          origin.package(
            'remote2',
            'rk_fixture_remote',
            '1.1.0',
            library: 'const value = 100;\n',
          ),
        );
        final selected = await discovery().resolve(
          root: manifest(root),
          lock: lock,
        );
        expect(
          selected.packages['rk_fixture_remote']!.manifest.version,
          '1.0.0',
        );
        final unlocked = await discovery().resolve(root: manifest(root));
        expect(
          unlocked.packages['rk_fixture_remote']!.manifest.version,
          '1.1.0',
        );
        expect(
          (await discovery().verifyFrozen(
            root: manifest(root),
            frozen: selected,
            lock: lock,
          )).toJson(),
          selected.toJson(),
        );
        final replay = await DartArchiveReplay.prepare(
          root: root,
          tools: const SystemTools(),
          compiler: origin.dart,
          defaultRegistry: origin.url,
          discovered: selected.graph,
          archives: [
            await DartHostedArchive.fetch(
              selected.packages['rk_fixture_remote']!,
            ),
          ],
        );
        addTearDown(replay.close);
        final output = '${origin.directory.path}/app-bin';
        final compile = await replay.run([
          'compile',
          'exe',
          'bin/main.dart',
          '-o',
          output,
        ]);
        expect(compile.ok, isTrue, reason: compile.transcript);
        expect((await Process.run(output, [])).stdout, '7\n');
        expect(
          File('${root.path}/pubspec.lock').readAsStringSync(),
          lock.contents,
        );
      },
    );

    test(
      'transitive candidate refinement preserves original third-party lock preferences',
      () async {
        origin.host(origin.package('core_old', 'rk_fixture_core', '0.1.0'));
        origin.host(
          origin.package(
            'bridge1',
            'rk_fixture_bridge',
            '1.0.0',
            dependencies: '  rk_fixture_core: ">=0.1.0 <0.3.0"\n',
          ),
        );
        origin.host(origin.package('remote1', 'rk_fixture_remote', '1.0.0'));
        final root = origin.package(
          'app',
          'rk_fixture_app',
          '0.1.0',
          dependencies:
              '  rk_fixture_bridge: ^1.0.0\n  rk_fixture_remote: ^1.0.0\n',
        );
        final lock = await getLock(root);
        origin.host(
          origin.package(
            'bridge2',
            'rk_fixture_bridge',
            '1.1.0',
            dependencies: '  rk_fixture_core: ^0.1.0\n',
          ),
        );
        origin.host(origin.package('remote2', 'rk_fixture_remote', '1.1.0'));
        final local = candidate(
          origin.package('core_new', 'rk_fixture_core', '0.2.0'),
        );
        final result = await discovery().resolve(
          root: manifest(root),
          lock: lock,
          candidates: [local],
        );
        expect(result.packages['rk_fixture_core']!.candidate, same(local));
        expect(result.packages['rk_fixture_core']!.manifest.version, '0.2.0');
        expect(result.packages['rk_fixture_bridge']!.manifest.version, '1.0.0');
        expect(result.packages['rk_fixture_remote']!.manifest.version, '1.0.0');
        expect(jsonEncode(result.toJson()), isNot(contains('cache-')));
      },
    );

    test(
      'staged candidate can unlock only the incompatible part of the native solve',
      () async {
        origin.host(origin.package('core_old', 'rk_fixture_core', '0.1.0'));
        origin.host(
          origin.package(
            'bridge1',
            'rk_fixture_bridge',
            '1.0.0',
            dependencies: '  rk_fixture_core: ^0.1.0\n',
          ),
        );
        origin.host(origin.package('remote1', 'rk_fixture_remote', '1.0.0'));
        final root = origin.package(
          'app',
          'rk_fixture_app',
          '0.1.0',
          dependencies:
              '  rk_fixture_core: ">=0.1.0 <0.3.0"\n  rk_fixture_bridge: ^1.0.0\n  rk_fixture_remote: ^1.0.0\n',
        );
        final lock = await getLock(root);
        origin.host(
          origin.package(
            'bridge2',
            'rk_fixture_bridge',
            '1.1.0',
            dependencies: '  rk_fixture_core: ^0.2.0\n',
          ),
        );
        origin.host(origin.package('remote2', 'rk_fixture_remote', '1.1.0'));
        final local = candidate(
          origin.package('core_new', 'rk_fixture_core', '0.2.0'),
        );
        final result = await discovery().resolve(
          root: manifest(root),
          lock: lock,
          candidates: [local],
        );
        expect(result.packages['rk_fixture_core']!.candidate, same(local));
        expect(result.packages['rk_fixture_bridge']!.manifest.version, '1.1.0');
        expect(result.packages['rk_fixture_remote']!.manifest.version, '1.0.0');
      },
    );

    test(
      'legacy native lock forms preserve preferences without dependency metadata',
      () async {
        origin.host(origin.package('remote1', 'rk_fixture_remote', '1.0.0'));
        origin.host(origin.package('remote2', 'rk_fixture_remote', '1.1.0'));
        final root = origin.package(
          'app',
          'rk_fixture_app',
          '0.1.0',
          dependencies: '  rk_fixture_remote: ^1.0.0\n',
        );
        final text =
            'packages:\n  rk_fixture_remote:\n    description: rk_fixture_remote\n    source: hosted\n    version: "1.0.0"\n';
        File('${root.path}/pubspec.lock').writeAsStringSync(text);
        final native = await origin.run(root, [
          'pub',
          'get',
          '--no-example',
          '--no-precompile',
        ]);
        expect(
          native.exitCode,
          0,
          reason: '${native.stdout}\n${native.stderr}',
        );
        final nativeLock = readDartYamlDocument(
          File('${root.path}/pubspec.lock').readAsStringSync(),
        );
        expect(
          (nativeLock['packages'] as Map)['rk_fixture_remote']['version'],
          '1.0.0',
        );
        final original = DartDependencyLock.parse(text, path: 'pubspec.lock');
        final resolved = await discovery().resolve(
          root: manifest(root),
          lock: original,
        );
        expect(
          resolved.packages['rk_fixture_remote']!.manifest.version,
          '1.0.0',
        );
        final actual = DartDependencyLock.parse(
          File('${root.path}/pubspec.lock').readAsStringSync(),
          path: 'pubspec.lock',
        );
        final upper =
            jsonDecode(jsonEncode(actual.document)) as Map<String, dynamic>;
        upper['packages']['rk_fixture_remote']['description']['sha256'] =
            (upper['packages']['rk_fixture_remote']['description']['sha256']
                    as String)
                .toUpperCase();
        final uppercase = DartDependencyLock.parse(
          jsonEncode(upper),
          path: 'pubspec.lock',
        );
        expect(
          (await discovery().resolve(
            root: manifest(root),
            lock: uppercase,
          )).packages['rk_fixture_remote']!.manifest.version,
          '1.0.0',
        );
        for (final empty in [
          '',
          ' \n\t',
          'packages: null',
          'sdk: ">=2.0.0 <4.0.0"',
        ]) {
          File('${root.path}/pubspec.lock').writeAsStringSync(empty);
          final native = await origin.run(root, [
            'pub',
            'get',
            '--no-example',
            '--no-precompile',
          ]);
          expect(
            native.exitCode,
            0,
            reason: '${native.stdout}\n${native.stderr}',
          );
          final selected = await discovery().resolve(
            root: manifest(root),
            lock: DartDependencyLock.parse(empty, path: 'pubspec.lock'),
          );
          expect(
            selected.packages['rk_fixture_remote']!.manifest.version,
            '1.1.0',
          );
        }
      },
    );

    test(
      'placeholder metadata hashes cannot authorize changed committed external bytes',
      () async {
        final remote = origin.package('remote', 'rk_fixture_remote', '1.0.0');
        origin.host(remote);
        final root = origin.package(
          'app',
          'rk_fixture_app',
          '0.1.0',
          dependencies: '  rk_fixture_remote: ^1.0.0\n',
        );
        final lock = await getLock(root);
        File(
          '${remote.path}/lib/rk_fixture_remote.dart',
        ).writeAsStringSync('const value = 100;\n');
        origin.host(remote);
        await expectLater(
          discovery().resolve(root: manifest(root), lock: lock),
          throwsA(
            isA<StateError>().having(
              (e) => '$e',
              'integrity',
              contains('committed lockfile'),
            ),
          ),
        );
        // An explicitly selected current first-party candidate at that same
        // coordinate is a different provenance; its future archive is receipt-bound.
        final local = candidate(remote);
        final result = await discovery().resolve(
          root: manifest(root),
          lock: lock,
          candidates: [local],
        );
        expect(result.packages['rk_fixture_remote']!.candidate, same(local));
      },
    );
  });

  group('source operation inputs', () {
    const config =
        'schema = 2\n[release.app]\npath = "packages/app"\npublish = ["pub.dev"]\n';
    const root = 'name: app\nversion: 0.1.0\nenvironment:\n  sdk: ^3.10.4\n';
    const lock = 'packages: {}\nsdks:\n  dart: ">=3.10.4 <4.0.0"\n';
    ResolvedProject project(SourceTree source) {
      final diagnostics = Diagnostics();
      final parsed = ReleaseConfig.parse(config, 'release.toml', diagnostics)!;
      final resolution = Resolution.resolve(parsed, source, diagnostics)!;
      expect(diagnostics.isEmpty, isTrue);
      return resolution.allProjects.single;
    }

    DartStageInputs inputs(
      SourceTree source, {
      DartStageOperation operation = DartStageOperation.binary,
    }) => DartStageInputs.read(
      source: source,
      project: project(source),
      operation: operation,
    );

    test('lock binding and materialization preserve original BOM bytes', () {
      final source = MemorySourceTree({
        'packages/app/pubspec.yaml': root,
        'packages/app/pubspec.lock': '\uFEFF$lock',
      });
      final captured = inputs(source).lock!;
      final original = source.readBytes('packages/app/pubspec.lock')!;
      expect(captured.bytes, original);
      expect(captured.binding.sha256, Sha256.hex(original));
      expect(captured.contents, lock);
      expect(captured.binding.sha256, isNot(Sha256.hex(utf8.encode(lock))));
      expect(() => captured.bytes[0] = 0, throwsUnsupportedError);
      source.files['packages/app/pubspec.lock'] = lock;
      expect(
        () => inputs(
          source,
        ).requireMatches(inputs(source).root, captured.binding),
        throwsStateError,
      );
    });

    test(
      'ordinary binary uses its source lock while Pub ignores inherited lock',
      () {
        final source = MemorySourceTree({
          'packages/app/pubspec.yaml': root,
          'packages/app/pubspec.lock': lock,
        });
        final binary = inputs(source);
        expect(binary.lock!.binding.path, 'packages/app/pubspec.lock');
        expect(binary.lock!.contents, lock);
        expect(
          inputs(source, operation: DartStageOperation.pubArchive).lock,
          isNull,
        );
        expect(
          () => binary.requireMatches(binary.root, null),
          throwsStateError,
        );
        final other = DartDependencyLock.parse(
          '$lock\n# changed\n',
          path: 'packages/app/pubspec.lock',
        );
        expect(
          () => binary.requireMatches(binary.root, other.binding),
          throwsStateError,
        );
      },
    );

    test(
      'nested member uses independent workspace root lock instead of stray member lock',
      () {
        final source = MemorySourceTree({
          'pubspec.yaml':
              'name: workspace\nworkspace: [packages]\nenvironment:\n  sdk: ^3.10.4\n',
          'packages/pubspec.yaml':
              'name: group\nresolution: workspace\nworkspace: [app]\n',
          'packages/app/pubspec.yaml': '${root}resolution: workspace\n',
          'pubspec.lock': lock,
          'packages/pubspec.lock': 'stale group lock',
          'packages/app/pubspec.lock': 'stale member lock',
        });
        expect(inputs(source).lock!.binding.path, 'pubspec.lock');
        expect(inputs(source).lock!.contents, lock);
        source.files.remove('pubspec.lock');
        expect(inputs(source).lock, isNull);
        source.files['pubspec_overrides.yaml'] = 'resolution: null\n';
        expect(() => inputs(source), throwsStateError);
      },
    );

    test(
      'native workspace membership rejects excluded members before any discovery solve',
      () async {
        final origin = await NativePubFixture.create();
        addTearDown(origin.close);
        final source = MemorySourceTree({
          'pubspec.yaml':
              'name: workspace\nenvironment:\n  sdk: ^3.10.4\nworkspace: [packages/other]\n',
          'packages/app/pubspec.yaml': '${root}resolution: workspace\n',
          'packages/other/pubspec.yaml':
              '${root.replaceFirst('name: app', 'name: other')}resolution: workspace\n',
          'pubspec.lock': lock,
        });
        final discovery = DartHostedDiscovery(
          tools: const SystemTools(),
          compiler: origin.dart,
          defaultRegistry: origin.url,
        );
        await expectLater(
          inputs(source).discover(discovery: discovery),
          throwsA(
            isA<StateError>().having(
              (error) => '$error',
              'native source',
              contains('native workspace'),
            ),
          ),
        );
        expect(origin.requests, isEmpty);
        source.files['pubspec.yaml'] =
            'name: workspace\nenvironment:\n  sdk: ^3.10.4\nworkspace: [packages]\n';
        source.files['packages/pubspec.yaml'] =
            'name: group\nenvironment:\n  sdk: ^3.10.4\nresolution: workspace\nworkspace: [app, other]\n';
        final valid = inputs(source);
        final selected = await valid.discover(discovery: discovery);
        expect(selected.graph.roots, {'app'});
        expect(valid.lock!.binding.path, 'pubspec.lock');
        expect(origin.requests, isEmpty);
        source.files['packages/pubspec.yaml'] =
            'name: group\nenvironment:\n  sdk: ^3.10.4\nresolution: workspace\nworkspace: [other]\n';
        await expectLater(
          inputs(source).discover(discovery: discovery),
          throwsStateError,
        );
        source.files['packages/pubspec.yaml'] =
            'name: group\nenvironment:\n  sdk: ^3.10.4\nresolution: workspace\nworkspace: [app, other]\n';
        source.files['packages/app/pubspec.yaml'] = '${root}resolution: typo\n';
        await expectLater(
          inputs(source).discover(discovery: discovery),
          throwsStateError,
        );
        source.files['packages/app/pubspec.yaml'] =
            '${root}resolution: workspace\n';
        final version = await Process.run(origin.dart, ['--version']);
        if (!'${version.stdout}${version.stderr}'.contains('3.10.4')) {
          source.files.remove('packages/pubspec.yaml');
          source.files['pubspec.yaml'] =
              'name: workspace\nenvironment:\n  sdk: ^3.11.0\nworkspace: ["packages/*"]\n';
          expect(
            (await inputs(source).discover(discovery: discovery)).graph.roots,
            {'app'},
          );
        }
      },
    );

    test(
      'authoritative Git reads ignore mutable and untracked checkout inputs',
      () async {
        final directory = Directory.systemTemp.createTempSync(
          'rk-native-source-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        Future<String> git(List<String> args) async {
          final result = await Process.run(
            'git',
            args,
            workingDirectory: directory.path,
          );
          expect(result.exitCode, 0, reason: '${result.stderr}');
          return '${result.stdout}'.trim();
        }

        await git(['init', '--quiet']);
        final manifest = File('${directory.path}/packages/app/pubspec.yaml')
          ..parent.createSync(recursive: true);
        manifest.writeAsStringSync(root);
        File(
          '${directory.path}/packages/app/pubspec.lock',
        ).writeAsStringSync(lock);
        await git(['add', '.']);
        await git([
          '-c',
          'user.name=Fixture',
          '-c',
          'user.email=fixture@example.test',
          '-c',
          'commit.gpgsign=false',
          'commit',
          '--quiet',
          '-m',
          'source',
        ]);
        final state = await GitState.read(directory.path);
        manifest.writeAsStringSync(root.replaceFirst('0.1.0', '9.0.0'));
        File(
          '${directory.path}/packages/app/pubspec.lock',
        ).writeAsStringSync('malformed');
        File(
          '${directory.path}/packages/app/pubspec_overrides.yaml',
        ).writeAsStringSync('unexpected: true');
        final source = DartStageInputs.authoritativeSource(
          GitSourceTree(directory.path),
          state,
        );
        final original = inputs(source);
        expect(original.root.version, '0.1.0');
        expect(original.lock!.contents, lock);
        expect(source.exists('packages/app/pubspec_overrides.yaml'), isFalse);
        final forged = MemorySourceTree({
          'packages/app/pubspec.yaml': root.replaceFirst('0.1.0', '9.0.0'),
        });
        expect(
          inputs(
            DartStageInputs.authoritativeSource(forged, state),
          ).root.version,
          '0.1.0',
        );
        expect(
          inputs(
            DartStageInputs.authoritativeSource(
              FrozenSourceTree.capture(forged),
              state,
            ),
          ).lock!.contents,
          lock,
        );
      },
    );

    test(
      'lock bindings and YAML documents are bounded and immutable',
      () async {
        for (final text in [
          'packages: []',
          'packages: &recursive {x: *recursive}',
          'packages: {}\n#${'x' * (1024 * 1024)}',
        ]) {
          expect(
            () => DartDependencyLock.parse(text, path: 'pubspec.lock'),
            throwsFormatException,
          );
        }
        final parsed = DartDependencyLock.parse(lock, path: 'pubspec.lock');
        expect(
          () => (parsed.document['packages'] as Map)['bad'] = {},
          throwsUnsupportedError,
        );
        expect(
          () => DartLockBinding(path: '../pubspec.lock', sha256: 'a' * 64),
          throwsA(anything),
        );
        expect(
          DartLockBinding.fromJson(parsed.binding.toJson()).toJson(),
          parsed.binding.toJson(),
        );
      },
    );
  });
}
