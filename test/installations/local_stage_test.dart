import 'dart:convert';
import 'dart:io';

import 'package:rk/src/builds/binary_artifact.dart';
import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/receipt.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/installations/local.dart';
import 'package:rk/src/installations/manager.dart';
import 'package:rk/src/installations/model.dart';
import 'package:rk/src/installations/store.dart';
import 'package:rk/src/transforms/archive.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

import '../rk_process.dart';
import 'fixtures.dart';

void main() {
  late _LocalStage fixture;
  setUp(() async => fixture = await _LocalStage.create());
  tearDown(() => fixture.scratch.deleteSync(recursive: true));

  test(
    'Local selects exact staged bundle without Dart and survives rk clean',
    () async {
      final stage = await fixture.stage();
      expect(fixture.store.selected(fixture.project), isNull);
      await fixture.apply(InstallationAction.install, dart: false);
      expect(fixture.store.selected(fixture.project), isNull);
      final prepared =
          (await fixture.provider(dart: false).inspect(fixture.project))
              .installation!;
      final message = await fixture.apply(InstallationAction.use, dart: false);
      final installed =
          (await fixture.provider(dart: false).inspect(fixture.project))
              .installation!;
      expect(installed.location, prepared.location);
      expect(installed.source, InstallationSource.local);
      expect(installed.build!.stage, stage.id.id);
      expect(installed.build!.description, startsWith('Installed from stage'));
      expect(message, contains('staged release'));
      expect(fixture.compiles, 0);
      expect(fixture.resolves, 0);
      final bundle = '${installed.location}/bundle';
      for (final entry in fixture.entries()) {
        expect(File('$bundle/${entry.name}').readAsBytesSync(), entry.bytes);
        expect(
          File('$bundle/${entry.name}').statSync().mode & 0x1ff,
          entry.executable ? 0x1ed : 0x1a4,
        );
      }
      expect(await fixture.launch(), '1.2.0\nstaged adapter\n');
      final clean = Rk(fixture.project.root).call(['clean', '--yes']);
      expect(clean.code, 0, reason: clean.all);
      expect(Directory(stage.path).existsSync(), isFalse);
      expect(await fixture.launch(), '1.2.0\nstaged adapter\n');
      await fixture.apply(InstallationAction.use, dart: false);
      expect(
        fixture.store.selected(fixture.project)!.location,
        installed.location,
      );
      expect(fixture.compiles, 0);
    },
  );

  for (final change in [
    'tracked edit',
    'untracked file',
    'new commit',
    'origin',
    'platform',
    'incomplete stage',
    'obsolete stage',
    'wrong identity',
    'missing archive',
  ]) {
    test('$change builds the checkout instead of selecting a stage', () async {
      final stage = await fixture.stage();
      var platform = 'linux-x64';
      switch (change) {
        case 'tracked edit':
          File(
            '${fixture.project.directory}/bin/orbit_main.dart',
          ).writeAsStringSync('// edited');
        case 'untracked file':
          File('${fixture.project.root}/new.dart').writeAsStringSync('// new');
        case 'new commit':
          fixture.git(['commit', '--allow-empty', '-qm', 'next']);
        case 'origin':
          final original = fixture.project;
          fixture.project = ExecutableProject(
            root: original.root,
            unit: original.unit,
            project: original.project,
            entrypoints: original.entrypoints,
            repository: 'other/orbit',
          );
        case 'platform':
          platform = 'linux-arm64';
        case 'missing archive':
          File(
            stage.pathOf(
              ReleaseAssets.archivePath(fixture.project.project, 'linux-x64'),
            ),
          ).deleteSync();
        default:
          final file = File(stage.pathOf('stage.json'));
          final json = jsonDecode(file.readAsStringSync()) as Map;
          if (change == 'incomplete stage') {
            (json['producers'] as Map).remove(Receipt.barrier);
          }
          if (change == 'obsolete stage') json['schema'] = 0;
          if (change == 'wrong identity') {
            json['stage']['head_commit'] = 'different';
          }
          file.writeAsStringSync(jsonEncode(json));
      }
      await fixture.apply(InstallationAction.use, platform: platform);
      expect(fixture.compiles, 1);
      expect(fixture.resolves, 1);
      expect(await fixture.launch(), 'development\n');
      final installed = (await fixture.provider().inspect(
        fixture.project,
      )).installation!;
      expect(installed.build!.stage, isNull);
    });
  }

  test(
    'archive changes at the same commit replace Local; failed installs keep it usable',
    () async {
      await fixture.stage();
      await fixture.apply(InstallationAction.use);
      final first = fixture.store.selected(fixture.project)!.location;
      final changed = await fixture.stage(adapter: 'new adapter');
      final path = changed.pathOf(
        ReleaseAssets.archivePath(fixture.project.project, 'linux-x64'),
      );
      final original = File(path).readAsBytesSync();
      File(path).writeAsBytesSync([0]);
      await expectLater(
        fixture.apply(InstallationAction.use),
        throwsA(isA<InstallationFailure>()),
      );
      expect(fixture.store.selected(fixture.project)!.location, first);
      expect(await fixture.launch(), '1.2.0\nstaged adapter\n');
      File(path).writeAsBytesSync(original);
      await fixture.stage(adapter: 'broken', version: 'wrong version');
      await expectLater(
        fixture.apply(InstallationAction.use),
        throwsA(isA<InstallationFailure>()),
      );
      expect(await fixture.launch(), '1.2.0\nstaged adapter\n');
      await fixture.stage(adapter: 'new adapter');
      await fixture.apply(InstallationAction.use);
      expect(await fixture.launch(), '1.2.0\nnew adapter\n');
      expect(fixture.compiles, 0);
      expect(Directory(first).existsSync(), isFalse);
    },
  );

  test('explicit source execution bypasses a matching stage', () async {
    await fixture.stage();
    final installed = await fixture
        .provider(live: true)
        .install(fixture.project, null, (_) {});
    expect(installed.checkout, isNull);
    expect(installed.commands['orbit']!.arguments, contains('run'));
    expect(fixture.resolves, 1);
    expect(fixture.compiles, 0);
    expect(
      Directory(fixture.store.localBuilds(fixture.project)).existsSync(),
      isFalse,
    );
  });

  test(
    'Use selects an already prepared stage while older Local stays active',
    () async {
      await fixture.stage();
      await fixture.apply(InstallationAction.use);
      final previous = fixture.store.selected(fixture.project)!.location;
      final stage = await fixture.stage(adapter: 'next adapter');
      await fixture.apply(InstallationAction.install);
      expect(fixture.store.selected(fixture.project)!.location, previous);
      expect(await fixture.launch(), '1.2.0\nstaged adapter\n');
      final prepared = Directory(fixture.store.localBuilds(fixture.project))
          .listSync()
          .whereType<Directory>()
          .singleWhere((d) => d.path != previous);
      Directory(stage.path).deleteSync(recursive: true);
      await fixture.apply(InstallationAction.use, dart: false);
      expect(fixture.store.selected(fixture.project)!.location, prepared.path);
      expect(await fixture.launch(), '1.2.0\nnext adapter\n');
      expect(fixture.compiles, 0);
    },
  );
}

class _LocalStage {
  _LocalStage(this.scratch, this.project) {
    dart = File('${scratch.path}/dart')..writeAsStringSync('compiler stand-in');
    tools = TestTools((exe, args, cwd, env) async {
      if (exe == dart.path) {
        if (args.contains('pub')) {
          resolves++;
        } else if (args.contains('compile')) {
          compiles++;
          final output = File(args[args.indexOf('-o') + 1]);
          output.writeAsStringSync('#!/bin/sh\nprintf "development\\n"\n');
          Process.runSync('/bin/chmod', ['755', output.path]);
        } else {
          fail('Unexpected compiler invocation: $args');
        }
        return ToolResult(exitCode: 0, stdout: '', stderr: '');
      }
      return const SystemTools().run(
        exe,
        args,
        workingDirectory: cwd,
        environment: env,
      );
    });
    store = InstallationStore('${scratch.path}/installed', tools);
  }
  final Directory scratch;
  ExecutableProject project;
  late final File dart;
  late final TestTools tools;
  late final InstallationStore store;
  int compiles = 0, resolves = 0;

  static Future<_LocalStage> create() async {
    final scratch = Directory.systemTemp.createTempSync('rk-local-stage-');
    final result = _LocalStage(
      scratch,
      fixture(scratch, commands: ['orbit'], binary: true),
    );
    File(
      '${result.project.root}/.gitignore',
    ).writeAsStringSync('.rk/\n.dart_tool/\npubspec.lock\n');
    result.git(['init', '-q']);
    result.git(['config', 'user.email', 'rk@example.test']);
    result.git(['config', 'user.name', 'rk tests']);
    result.git(['config', 'commit.gpgSign', 'false']);
    result.git([
      'remote',
      'add',
      'origin',
      'https://github.com/${result.project.repository}.git',
    ]);
    result.git(['add', '.']);
    result.git(['commit', '-qm', 'fixture']);
    return result;
  }

  void git(List<String> args) {
    final result = Process.runSync('git', args, workingDirectory: project.root);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  LocalInstallationProvider provider({
    bool dart = true,
    bool live = false,
    String platform = 'linux-x64',
  }) => LocalInstallationProvider(
    tools,
    dart ? this.dart.path : null,
    store,
    live: live,
    platform: platform,
  );

  Future<String> apply(
    InstallationAction action, {
    bool dart = true,
    String platform = 'linux-x64',
  }) =>
      InstallationManager(
        store: store,
        providers: {
          InstallationSource.local: provider(dart: dart, platform: platform),
        },
        environment: {'PATH': '${store.bin}:/usr/bin:/bin', 'SHELL': '/bin/sh'},
      ).apply(
        Operation(project, InstallationSource.local, action),
        progress: (_) {},
      );

  Future<String> launch() async {
    final result = await Process.run(
      '${store.bin}/orbit',
      [],
      workingDirectory: scratch.path,
      environment: {'PATH': '/usr/bin:/bin'},
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return result.stdout as String;
  }

  List<ArchiveEntry> entries({
    String adapter = 'staged adapter',
    String version = '1.2.0',
  }) {
    final artifact = BinaryArtifact.nativeBundle(
      'orbit',
      macos: false,
      libraries: ['libadapter.so'],
    );
    return [
      for (final file in artifact.files)
        ArchiveEntry(
          name: file.path,
          executable: file.executable,
          bytes: utf8.encode(
            file.path == BinaryArtifact.manifestName
                ? artifact.manifest
                : file.path == artifact.entryPoint
                ? '#!/bin/sh\nprintf "$version\\n"\ncat "\$(dirname "\$0")/../lib/libadapter.so"\n'
                : '$adapter\n',
          ),
        ),
    ];
  }

  Future<Stage> stage({
    String adapter = 'staged adapter',
    String version = '1.2.0',
  }) async {
    final git = await GitState.read(project.root);
    expect(git.isClean, isTrue);
    final stage = Stages(
      project.root,
    ).of(project.unit, git, WorkingTree(project.root, git: true));
    stage.begin();
    final path = ReleaseAssets.archivePath(project.project, 'linux-x64');
    final bytes = ArchiveBuilder.gzip(
      ArchiveBuilder.tar(entries(adapter: adapter, version: version)),
    );
    stage.write(path, bytes);
    final receipt = stage.receipt!.recording(Receipt.barrier, const {}, {
      path: StagedFile(
        producer: 'archive',
        size: bytes.length,
        sha256: Sha256.hex(bytes),
      ),
    });
    stage.write('stage.json', utf8.encode(receipt.encode()));
    return stage;
  }
}
