import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:rk/src/builds/binary_artifact.dart';
import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/release_manifest.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/installations/manager.dart';
import 'package:rk/src/installations/model.dart';
import 'package:rk/src/installations/store.dart';
import 'package:rk/src/targets/github_release/installation.dart';
import 'package:rk/src/targets/homebrew/installation.dart';
import 'package:rk/src/targets/pub_dev/installation.dart';
import 'package:rk/src/transforms/archive.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';
import 'fixtures.dart';

void main() {
  late Directory scratch;
  setUp(
    () => scratch = Directory.systemTemp.createTempSync('rk-provider-test-'),
  );
  tearDown(() => scratch.deleteSync(recursive: true));

  test(
    'extracts RK single-file and complete multi-file release layouts',
    () async {
      for (final artifact in [
        BinaryArtifact.single('orbit'),
        BinaryArtifact.dartBundle('orbit'),
      ]) {
        final encoded = ArchiveBuilder.gzip(
          ArchiveBuilder.tar([
            for (final file in artifact.files)
              ArchiveEntry(
                name: file.path,
                bytes: utf8.encode(
                  file.path == BinaryArtifact.manifestName
                      ? artifact.manifest
                      : 'bytes',
                ),
                executable: file.executable,
              ),
            ArchiveEntry(name: 'LICENSE', bytes: utf8.encode('License')),
            ArchiveEntry(name: 'README.md', bytes: utf8.encode('Readme')),
          ]),
        );
        final decoded = await decodeInstallationArchive(encoded, 'orbit');
        expect(decoded.files.keys.toSet(), {
          ...artifact.files.map((f) => f.path),
          'LICENSE',
          'README.md',
        });
        expect(decoded.artifact.isBundle, artifact.isBundle);
      }
    },
  );

  test(
    'refuses archive traversal, duplicates, links and incomplete layouts',
    () async {
      final bundle = BinaryArtifact.dartBundle('orbit');
      for (final files in [
        [
          ArchiveEntry(name: '../orbit', bytes: [1]),
        ],
        [
          ArchiveEntry(name: '/orbit', bytes: [1]),
        ],
        [
          ArchiveEntry(name: 'orbit', bytes: [1]),
          ArchiveEntry(name: 'orbit', bytes: [2]),
        ],
        [
          ArchiveEntry(name: 'orbit', bytes: [1]),
          ArchiveEntry(name: 'surprise', bytes: [2]),
        ],
        [
          ArchiveEntry(
            name: BinaryArtifact.manifestName,
            bytes: utf8.encode(bundle.manifest),
          ),
          ArchiveEntry(name: 'orbit', bytes: [1]),
        ],
      ]) {
        await expectLater(
          decodeInstallationArchive(
            ArchiveBuilder.gzip(ArchiveBuilder.tar(files)),
            'orbit',
          ),
          throwsA(isA<InstallationFailure>()),
        );
      }
      final link = Archive()..add(ArchiveFile.symlink('orbit', '/bin/sh'));
      await expectLater(
        decodeInstallationArchive(
          gzip.encode(TarEncoder().encode(link)),
          'orbit',
        ),
        throwsA(isA<InstallationFailure>()),
      );
    },
  );

  test(
    'GitHub selects the configured release unit, verifies checksum and installs exact files',
    () async {
      final project = fixture(scratch, commands: ['orbit'], binary: true);
      final store = InstallationStore(
        '${scratch.path}/store',
        const SystemTools(),
      );
      final archive = Uint8List.fromList(
        ArchiveBuilder.gzip(
          ArchiveBuilder.tar([
            ArchiveEntry(
              name: 'orbit',
              bytes: utf8.encode('#!/bin/sh\nprintf "release 1.1.0\\n"\n'),
              executable: true,
            ),
          ]),
        ),
      );
      final name = ReleaseAssets.archiveName('orbit', '1.1.0', 'linux-x64');
      var corrupt = false;
      final manifest = ReleaseManifest(
        unit: 'app',
        version: '1.1.0',
        tag: 'v1.1.0',
        commit: 'a' * 40,
        artifacts: [
          ReleaseManifestArtifact(
            name: name,
            type: 'archive',
            size: archive.length,
            sha256: Sha256.hex(archive),
          ),
        ],
      );
      final provider = GithubInstallationProvider(
        const SystemTools(),
        store,
        'linux-x64',
        fetch: (uri, limit, {check}) async {
          if (uri.host == 'api.github.com') {
            return Uint8List.fromList(
              utf8.encode(
                jsonEncode([
                  {
                    'tag_name': 'docs-v5.0.0',
                    'draft': false,
                    'prerelease': false,
                  },
                  {'tag_name': 'v2.0.0', 'draft': true, 'prerelease': false},
                  {
                    'tag_name': 'v4.0.0',
                    'draft': false,
                    'prerelease': false,
                    'assets': [
                      {'name': ReleaseAssets.manifest},
                      {'name': 'orbit-4.0.0-linux-arm64.tar.gz'},
                    ],
                  },
                  {'tag_name': 'v1.1.0', 'draft': false, 'prerelease': false},
                ]),
              ),
            );
          }
          if (uri.path.endsWith(ReleaseAssets.manifest)) {
            return Uint8List.fromList(utf8.encode(manifest.encode()));
          }
          expect(uri.pathSegments.last, name);
          expect(limit, archive.length);
          return corrupt ? Uint8List(archive.length) : archive;
        },
      );
      corrupt = true;
      await expectLater(
        provider.install(project, null, (_) {}),
        throwsA(isA<InstallationFailure>()),
      );
      expect(Directory(store.root).existsSync(), isFalse);
      corrupt = false;
      final installed = await provider.install(project, null, (_) {});
      expect(installed.version, '1.1.0');
      expect(
        (await Process.run(installed.commands['orbit']!.executable, [])).stdout,
        'release 1.1.0\n',
      );
      expect(
        (await provider.inspect(project)).installation!.location,
        installed.location,
      );
      await provider.uninstall(project);
      expect(Directory(installed.location).existsSync(), isFalse);
      expect((await provider.inspect(project)).installation, isNull);
      expect(Directory(project.directory).existsSync(), isTrue);
    },
  );

  test(
    'Pub recognizes hosted activations and refuses path activations',
    () async {
      final project = fixture(scratch);
      final cache = '${scratch.path}/cache';
      final global = Directory('$cache/global_packages/${project.name}')
        ..createSync(recursive: true);
      final lock = File('${global.path}/pubspec.lock');
      void hosted() => lock.writeAsStringSync('''packages:
  ${project.name}:
    source: hosted
    version: 1.2.0
    description:
      name: ${project.name}
      url: "https://pub.dev"
''');
      final config = File('${global.path}/.dart_tool/package_config.json')
        ..createSync(recursive: true);
      config.writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': project.name,
              'rootUri': Directory(project.directory).uri.toString(),
            },
          ],
        }),
      );
      final calls = <List<String>>[];
      final tools = TestTools((exe, args, cwd, env) async {
        calls.add(args);
        expect(env!['PUB_CACHE'], cache);
        hosted();
        return ok();
      });
      final provider = PubInstallationProvider(tools, '/dart', {
        'HOME': scratch.path,
        'PUB_CACHE': cache,
      });
      expect((await provider.inspect(project)).installation, isNull);
      expect((await provider.inspect(project)).problem, contains('incomplete'));
      expect(
        (await provider.inspect(project)).problem,
        contains('dart pub global activate --no-executables ${project.name}'),
      );
      final installed = await provider.install(project, null, (_) {});
      expect(calls.single, contains('--no-executables'));
      expect(
        installed.commands['orbit']!.arguments.last,
        'orbit_cli:orbit_main',
      );
      expect(installed.commands.length, 2);
      config.writeAsStringSync('{"packages": {}}');
      await expectLater(provider.inspect(project), throwsFormatException);
      lock.writeAsStringSync('packages:\n  orbit_cli:\n    source: path\n');
      expect(
        (await provider.inspect(project)).problem,
        contains('Already activated from a local path'),
      );
      expect(
        (await provider.inspect(project)).problem,
        contains('dart pub global deactivate orbit_cli'),
      );
    },
  );

  test(
    'Homebrew reads its installation from the opt link and the keg receipt, asking brew only for its prefix',
    () async {
      final project = fixture(scratch, commands: ['orbit'], binary: true);
      final brew = FakeHomebrew('${scratch.path}/brew');
      final provider = HomebrewInstallationProvider(brew.tools, '/brew');
      expect((await provider.inspect(project)).installation, isNull);
      brew.pour('someone/else/orbit', '3.0.0');
      expect(
        (await provider.inspect(project)).installation,
        isNull,
        reason: 'A formula of the same name from another tap is not ours.',
      );
      Directory('${brew.prefix}/Cellar').deleteSync(recursive: true);
      Link('${brew.prefix}/opt/orbit').deleteSync();
      final result = await provider.install(project, null, (_) {});
      expect(result.version, '1.2.0');
      expect(
        result.commands['orbit']!.executable,
        '${brew.prefix}/opt/orbit/bin/orbit',
      );
      expect(brew.calls, [
        ['--prefix'],
        ['install', '--formula', '--skip-link', project.formula],
      ]);
      expect(
        brew.environments.every(
          (environment) => environment?['HOMEBREW_NO_INSTALL_UPGRADE'] == '1',
        ),
        isTrue,
      );
    },
  );

  test(
    'a Homebrew selection keeps running after brew upgrades it and removes the old keg',
    () async {
      final project = fixture(scratch, commands: ['orbit'], binary: true);
      final brew = FakeHomebrew('${scratch.path}/brew');
      final store = InstallationStore('${scratch.path}/data', brew.tools);
      final manager = InstallationManager(
        store: store,
        providers: {
          InstallationSource.homebrew: HomebrewInstallationProvider(
            brew.tools,
            '/brew',
          ),
        },
        environment: {'PATH': '${store.bin}:/usr/bin:/bin'},
      );
      await manager.act(
        project,
        InstallationSource.homebrew,
        InstallationAction.use,
        progress: (_) {},
      );
      Future<ProcessResult> orbit() => Process.run('${store.bin}/orbit', []);
      expect((await orbit()).stdout, 'brew 1.2.0\n');
      // `brew upgrade`, run outside rk: a new keg, and the old one cleaned up.
      brew.pour(project.formula, '1.3.0', keepOld: false);
      final upgraded = await orbit();
      expect(upgraded.exitCode, 0, reason: '${upgraded.stderr}');
      expect(upgraded.stdout, 'brew 1.3.0\n');
    },
  );

  group('GitHub downloads', () {
    late ExecutableProject project;
    late InstallationStore store;
    late FakeReleases releases;
    late GithubInstallationProvider github;
    late StubProvider local;
    late InstallationManager manager;
    late Directory downloads;
    setUp(() {
      project = fixture(scratch, commands: ['orbit'], binary: true);
      store = InstallationStore('${scratch.path}/data', const SystemTools());
      releases = FakeReleases(project, ['1.1.0']);
      github = GithubInstallationProvider(
        const SystemTools(),
        store,
        'linux-x64',
        fetch: releases.fetch,
      );
      local = StubProvider(InstallationSource.local);
      manager = InstallationManager(
        store: store,
        providers: {github.source: github, local.source: local},
        environment: {'PATH': '${store.bin}:/usr/bin:/bin'},
      );
      downloads = Directory(store.downloads(project));
    });
    Future<String> act(InstallationSource source, InstallationAction action) =>
        manager.act(project, source, action, progress: (_) {});
    Future<String> orbit() async =>
        (await Process.run('${store.bin}/orbit', [])).stdout as String;

    test(
      'an update replaces the previous download; uninstall removes every one',
      () async {
        await act(github.source, InstallationAction.use);
        expect(await orbit(), 'release 1.1.0\n');
        releases.publish('1.2.0');
        await manager.download(
          project,
          github.source,
          await manager.latest(project, github.source),
          progress: (_) {},
        );
        expect(await orbit(), 'release 1.2.0\n');
        expect(downloads.listSync(), hasLength(1));
        await act(local.source, InstallationAction.use);
        await act(github.source, InstallationAction.uninstall);
        expect(downloads.existsSync(), isFalse);
      },
    );

    test(
      'an update interrupted before routing finishes when it runs again',
      () async {
        await act(github.source, InstallationAction.use);
        releases.publish('1.2.0');
        final release = await manager.latest(project, github.source);
        // The update unpacked and renamed its download, then stopped.
        await github.install(project, release, (_) {});
        expect(await orbit(), 'release 1.1.0\n');
        final fetched = releases.archiveFetches;
        await manager.download(
          project,
          github.source,
          release,
          progress: (_) {},
        );
        expect(await orbit(), 'release 1.2.0\n');
        expect(downloads.listSync(), hasLength(1));
        expect(releases.archiveFetches, fetched);
      },
    );

    test(
      'a renamed origin keeps its download, and uninstall still removes it',
      () async {
        await act(github.source, InstallationAction.use);
        final renamed = ExecutableProject(
          root: project.root,
          unit: project.unit,
          project: project.project,
          entrypoints: project.entrypoints,
          repository: 'owner/renamed',
        );
        Future<String> actRenamed(
          InstallationSource source,
          InstallationAction action,
        ) => manager.act(renamed, source, action, progress: (_) {});
        final state = await manager.inspect(renamed);
        expect(state.sources[github.source]!.installation!.version, '1.1.0');
        await actRenamed(local.source, InstallationAction.use);
        await actRenamed(github.source, InstallationAction.uninstall);
        expect(downloads.existsSync(), isFalse);
      },
    );

    test(
      'a re-run after an interrupted install finishes it without downloading again',
      () async {
        // Interrupted after unpacking, before rk routed anything; and an
        // earlier run that stopped while unpacking.
        await github.install(project, null, (_) {});
        Directory('${downloads.path}/preparing-interrupted').createSync();
        final fetched = releases.archiveFetches;
        await act(github.source, InstallationAction.use);
        expect(releases.archiveFetches, fetched);
        expect(await orbit(), 'release 1.1.0\n');
        expect(downloads.listSync(), hasLength(1));
      },
    );
  });
}
