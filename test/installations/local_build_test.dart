@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/installations/local.dart';
import 'package:rk/src/installations/manager.dart';
import 'package:rk/src/installations/model.dart';
import 'package:rk/src/installations/store.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  test(
    'compiled Local snapshots all commands, rebuilds explicitly and survives failed rebuilds',
    () async {
      final scratch = Directory.systemTemp.createTempSync(
        'rk compiled dollar\$ ',
      );
      addTearDown(() => scratch.deleteSync(recursive: true));
      final original = fixture(scratch);
      final project = ExecutableProject(
        root: original.root,
        unit: original.unit,
        entrypoints: {...original.entrypoints, 'alias': 'orbit_main'},
        project: ResolvedProject(
          unitName: original.project.unitName,
          config: original.project.config,
          pubspec: original.project.pubspec,
          dartDefines: {'identity': r'configured $literal'},
        ),
      );
      final entry = File('${project.directory}/bin/orbit_main.dart');
      entry.writeAsStringSync(
        entry.readAsStringSync().replaceFirst(
          "print('orbit')",
          "print(const String.fromEnvironment('identity'))",
        ),
      );
      final store = InstallationStore(
        '${scratch.path}/data',
        const SystemTools(),
      );
      final provider = LocalInstallationProvider(
        const SystemTools(),
        Platform.resolvedExecutable,
        store,
      );
      final pub = StubProvider(InstallationSource.pub);
      final manager = InstallationManager(
        store: store,
        providers: {provider.source: provider, pub.source: pub},
        environment: {'PATH': '${store.bin}:/usr/bin:/bin', 'SHELL': '/bin/sh'},
      );
      Future<String> apply(InstallationAction action) => manager.apply(
        Operation(project, provider.source, action),
        progress: (_) {},
      );
      final caller = Directory('${scratch.path}/caller with space')
        ..createSync();
      Future<ProcessResult> launch([String command = 'orbit']) => Process.run(
        '${store.bin}/$command',
        ['a b', r'$(touch bad)', "it's"],
        workingDirectory: caller.path,
        // Compiled launches do not need Dart on PATH.
        environment: {'PATH': '/usr/bin:/bin'},
      );
      await apply(InstallationAction.install);
      expect(store.selected(project), isNull);
      final prepared = (await provider.inspect(project)).installation!;
      expect(prepared.checkout, project.directory);
      expect(prepared.toJson()['mode'], 'compiled');
      await apply(InstallationAction.use);
      expect(Directory(prepared.location).existsSync(), isFalse);
      final selected = store.selected(project)!.location;
      final first = await launch();
      expect(first.exitCode, 0, reason: '${first.stderr}');
      expect(
        first.stdout,
        'configured \$literal\n${caller.resolveSymbolicLinksSync()}\na b|\$(touch bad)|it\'s\n',
      );
      expect((await launch('orbit_admin')).stdout, startsWith('orbit_admin\n'));
      expect((await launch('alias')).stdout, first.stdout);

      entry.writeAsStringSync(
        "void main(List<String> args) => print('edited');",
      );
      expect((await launch()).stdout, first.stdout);
      // Preparing an updated copy does not replace the selected copy.
      await apply(InstallationAction.install);
      expect(store.selected(project)!.location, selected);
      expect(
        (await provider.inspect(project)).installation!.location,
        selected,
      );
      expect((await launch()).stdout, first.stdout);

      final second = File('${project.directory}/bin/orbit_admin_main.dart');
      final valid = second.readAsStringSync();
      second.writeAsStringSync('invalid Dart source');
      final builds = Directory(store.localBuilds(project));
      final before = builds.listSync().map((e) => e.path).toSet();
      await expectLater(
        apply(InstallationAction.use),
        throwsA(isA<InstallationFailure>()),
      );
      expect(builds.listSync().map((e) => e.path).toSet(), before);
      expect(store.selected(project)!.location, selected);
      expect((await launch()).stdout, first.stdout);
      expect((await launch('orbit_admin')).stdout, startsWith('orbit_admin\n'));
      second.writeAsStringSync(valid);

      await apply(InstallationAction.use);
      expect((await launch()).stdout, 'edited\n');
      expect(Directory(selected).existsSync(), isFalse);
      expect(builds.listSync(), hasLength(1));
      // Even moving the checkout does not break the selected snapshot.
      final moved = Directory(
        project.directory,
      ).renameSync('${project.directory}-moved');
      expect((await launch()).stdout, 'edited\n');
      expect(File('${caller.path}/bad').existsSync(), isFalse);
      moved.renameSync(project.directory);

      await manager.apply(
        Operation(project, pub.source, InstallationAction.use),
        progress: (_) {},
      );
      expect((await provider.inspect(project)).installation, isNotNull);
      await apply(InstallationAction.uninstall);
      expect(builds.existsSync(), isFalse);
      expect(entry.existsSync(), isTrue);
    },
    skip: Platform.isWindows,
  );
}
