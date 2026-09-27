import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:rk/src/builds/binary_artifact.dart';
import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/release_manifest.dart';
import 'package:rk/src/engine/tools.dart';
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
        fetch: (uri, limit) async {
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
        provider.install(project, (_) {}),
        throwsA(isA<InstallationFailure>()),
      );
      expect(Directory(store.root).existsSync(), isFalse);
      corrupt = false;
      final installed = await provider.install(project, (_) {});
      expect(installed.version, '1.1.0');
      expect(
        (await Process.run(installed.commands['orbit']!.executable, [])).stdout,
        'release 1.1.0\n',
      );
      await store.record(project, installed);
      expect(
        (await provider.inspect(project)).installation!.location,
        installed.location,
      );
      File(installed.commands['orbit']!.executable).deleteSync();
      final broken = await provider.inspect(project);
      expect(broken.problem, contains('incomplete'));
      expect(
        broken.installation,
        isNotNull,
        reason: 'Known owned bytes can still be removed.',
      );
      await provider.uninstall(project, installed);
      expect(Directory(installed.location).existsSync(), isFalse);
      final forged = Installation(
        source: InstallationSource.github,
        version: '1.1.0',
        location: project.directory,
        commands: installed.commands,
        managed: true,
      );
      await expectLater(
        provider.uninstall(project, forged),
        throwsA(isA<InstallationFailure>()),
      );
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
      final installed = await provider.install(project, (_) {});
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
        contains('different source'),
      );
    },
  );

  test(
    'Homebrew uses exact formula identity and installs without linking or upgrading',
    () async {
      final project = fixture(scratch, commands: ['orbit'], binary: true);
      final cellar = '${scratch.path}/Cellar/orbit';
      File('$cellar/1.2.0/bin/orbit')
        ..createSync(recursive: true)
        ..writeAsStringSync('binary');
      var installed = false;
      final calls = <List<String>>[];
      final tools = TestTools((exe, args, cwd, env) async {
        calls.add(args);
        expect(env!['HOMEBREW_NO_INSTALL_UPGRADE'], '1');
        if (args.first == 'list') {
          expect(args, ['list', '--formula', '--full-name', '-1']);
          return ok(
            'someone/else/orbit\n${installed ? project.formula : ''}\n',
          );
        }
        if (args.first == 'info') {
          expect(args, ['info', '--json=v2', '--formula', project.formula]);
          return ok(
            jsonEncode({
              'formulae': [
                {
                  'full_name': 'someone/else/orbit',
                  'installed': [
                    {'version': '3.0.0'},
                  ],
                },
                if (installed)
                  {
                    'full_name': project.formula,
                    'name': 'orbit',
                    'linked_keg': '1.2.0',
                    'installed': [
                      {'version': '1.2.0'},
                    ],
                  },
              ],
            }),
          );
        }
        if (args.first == '--cellar') {
          expect(args, ['--cellar']);
          return ok('${scratch.path}/Cellar');
        }
        if (args.first == '--prefix') return ok('${scratch.path}/brew');
        if (args.first == 'install') {
          installed = true;
          return ok();
        }
        throw StateError('unexpected $args');
      });
      final provider = HomebrewInstallationProvider(tools, '/brew');
      expect((await provider.inspect(project)).installation, isNull);
      expect(
        calls,
        [
          ['list', '--formula', '--full-name', '-1'],
        ],
        reason:
            'A different tap is not our installation or a reason to query it.',
      );
      final result = await provider.install(project, (_) {});
      expect(result.commands['orbit']!.executable, '$cellar/1.2.0/bin/orbit');
      expect(calls.where((c) => c.first == 'install').single, [
        'install',
        '--formula',
        '--skip-link',
        project.formula,
      ]);
    },
  );
}
