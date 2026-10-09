import 'dart:io';
import 'dart:convert';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/installations/local.dart';
import 'package:rk/src/installations/manager.dart';
import 'package:rk/src/installations/model.dart';
import 'package:rk/src/installations/shell_routing.dart';
import 'package:rk/src/installations/store.dart';
import 'package:test/test.dart';
import 'fixtures.dart';

void main() {
  late Directory scratch;
  late ExecutableProject project;
  late InstallationStore store;
  late StubProvider local, pub;
  late InstallationManager manager;
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('rk-install-test-');
    project = fixture(scratch);
    store = InstallationStore('${scratch.path}/data', const SystemTools());
    local = StubProvider(InstallationSource.local);
    pub = StubProvider(InstallationSource.pub);
    manager = InstallationManager(
      store: store,
      providers: {local.source: local, pub.source: pub},
      environment: {'PATH': '${store.bin}:/usr/bin:/bin'},
    );
  });
  tearDown(() => scratch.deleteSync(recursive: true));
  Future<String> act(
    InstallationSource source,
    InstallationAction action, {
    InstallationCancellation? cancel,
  }) => manager.act(
    project,
    source,
    action,
    progress: (_) {},
    cancellation: cancel,
  );

  test(
    'interprocess lock refuses a second writer and recovers after release',
    () async {
      Directory(store.root).createSync(recursive: true);
      final script = File('${scratch.path}/lock.dart')
        ..writeAsStringSync('''
import 'dart:io';
void main(List<String> args) {
  final lock = File(args.single).openSync(mode: FileMode.append);
  lock.lockSync(FileLock.exclusive);
  stdout.writeln('locked');
  stdin.readLineSync();
  lock.closeSync();
}
''');
      final child = await Process.start(Platform.resolvedExecutable, [
        script.path,
        '${store.root}/install.lock',
      ]);
      addTearDown(() => child.kill());
      expect(
        await child.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first,
        'locked',
      );
      await expectLater(
        act(local.source, InstallationAction.use),
        throwsA(isA<InstallationFailure>()),
      );
      expect(local.installs, 0);
      child.stdin.writeln();
      await child.stdin.close();
      expect(await child.exitCode, 0);
      await act(local.source, InstallationAction.use);
      expect(store.selected(project)!.source, local.source);
    },
  );

  test(
    'native PATH ownership prevents removing an active external installation',
    () async {
      final native = File('${scratch.path}/native/ orbit')
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\nexit 0\n');
      await Process.run('/bin/chmod', ['700', native.path]);
      final bin = Directory('${scratch.path}/native-bin')..createSync();
      Link('${bin.path}/orbit').createSync(native.path);
      pub.installed = Installation(
        source: pub.source,
        version: '1.2.0',
        location: native.parent.path,
        commands: {'orbit': LaunchCommand(native.path)},
        exportedPaths: [native.path],
      );
      final external = InstallationManager(
        store: store,
        providers: manager.providers,
        environment: {'PATH': bin.path},
      );
      final state = await external.inspect(project);
      expect(state.currentSources['orbit'], pub.source);
      await expectLater(
        external.act(
          project,
          pub.source,
          InstallationAction.uninstall,
          progress: (_) {},
        ),
        throwsA(isA<InstallationFailure>()),
      );
      expect(pub.removals, 0);
    },
  );

  test(
    'install does not select; use switches every exported command',
    () async {
      await act(local.source, InstallationAction.install);
      expect(store.selected(project), isNull);
      expect(Directory(store.bin).existsSync(), isFalse);
      await act(local.source, InstallationAction.use);
      for (final command in project.commands) {
        expect(
          (await Process.run('${store.bin}/$command', [
            'hello world',
            r'$HOME',
          ])).stdout,
          'local $command hello world \$HOME\n',
        );
      }
      await act(pub.source, InstallationAction.install);
      expect(store.selected(project)!.source, local.source);
      await act(pub.source, InstallationAction.use);
      expect(
        pub.installs,
        1,
        reason: 'reuse installed source without upgrading',
      );
      for (final command in project.commands) {
        expect(
          (await Process.run('${store.bin}/$command', [])).stdout,
          'pub $command\n',
        );
      }
      expect(store.routingProblems(project, manager.environment), isEmpty);
    },
  );

  test(
    'rk install local says it prepared the checkout, which is not installed until selected',
    () async {
      final provider = LocalInstallationProvider(
        TestTools((_, _, _, _) async => ok()),
        Platform.resolvedExecutable,
        store,
      );
      final live = InstallationManager(
        store: store,
        providers: {provider.source: provider},
        environment: manager.environment,
      );
      final message = await live.act(
        project,
        provider.source,
        InstallationAction.install,
        progress: (_) {},
      );
      final state = await live.inspect(project);
      expect(state.sources[provider.source]!.installation, isNull);
      expect(message, contains('prepared'));
      expect(message, isNot(contains('installed')));
    },
  );

  test(
    'failed or cancelled preparation leaves old selection runnable',
    () async {
      await act(local.source, InstallationAction.use);
      pub.fail = true;
      await expectLater(
        act(pub.source, InstallationAction.use),
        throwsA(isA<InstallationFailure>()),
      );
      expect(store.selected(project)!.source, local.source);
      pub.fail = false;
      final cancel = InstallationCancellation();
      pub.preparing = () async => cancel.cancel();
      await expectLater(
        act(pub.source, InstallationAction.use, cancel: cancel),
        throwsA(isA<InstallationFailure>()),
      );
      expect(store.selected(project)!.source, local.source);
      expect((await pub.inspect(project)).installation, isNotNull);
      expect(
        (await Process.run('${store.bin}/orbit', [])).stdout,
        'local orbit\n',
      );
    },
  );

  test(
    'refuses unsupported sources, active removal, and command collisions before installing',
    () async {
      await expectLater(
        act(InstallationSource.github, InstallationAction.use),
        throwsA(isA<InstallationFailure>()),
      );
      Directory(store.bin).createSync(recursive: true);
      File('${store.bin}/orbit').writeAsStringSync('somebody else');
      await expectLater(
        act(local.source, InstallationAction.use),
        throwsA(isA<InstallationFailure>()),
      );
      expect(local.installs, 0);
      File('${store.bin}/orbit').deleteSync();
      await act(local.source, InstallationAction.use);
      await expectLater(
        act(local.source, InstallationAction.uninstall),
        throwsA(isA<InstallationFailure>()),
      );
      expect(local.removals, 0);
      await act(pub.source, InstallationAction.use);
      await act(local.source, InstallationAction.uninstall);
      expect(store.selected(project)!.source, pub.source);
      expect(Directory(project.directory).existsSync(), isTrue);
      expect(
        (await Process.run('${store.bin}/orbit', [])).stdout,
        'pub orbit\n',
      );
    },
  );

  test(
    'switching back and forth leaves nothing behind but the launchers',
    () async {
      await act(local.source, InstallationAction.use);
      await act(pub.source, InstallationAction.install);
      await act(pub.source, InstallationAction.use);
      await act(local.source, InstallationAction.use);
      await act(pub.source, InstallationAction.install);
      final state =
          Directory(store.root)
              .listSync(recursive: true)
              .whereType<File>()
              .map((file) => file.path.substring(store.root.length + 1))
              .toList()
            ..sort();
      expect(state, ['bin/orbit', 'bin/orbit_admin', 'install.lock']);
      expect(store.selected(project)!.source, local.source);
    },
  );

  test(
    'a project whose origin changed keeps its selection and takes its own launchers back',
    () async {
      await act(pub.source, InstallationAction.use);
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
      expect((await manager.inspect(renamed)).selected, pub.source);
      await expectLater(
        actRenamed(pub.source, InstallationAction.uninstall),
        throwsA(isA<InstallationFailure>()),
      );
      expect(pub.removals, 0);
      await actRenamed(local.source, InstallationAction.use);
      expect(
        (await Process.run('${store.bin}/orbit', [])).stdout,
        'local orbit\n',
      );
    },
  );

  test(
    'a selection rk 0.1.14 made keeps running, and its source is not removed',
    () async {
      // What 0.1.14 wrote: a launcher per command that names the project by
      // a hash and forwards to its current generation, which records the
      // source in installation.json.
      final hash = '0123456789abcdef' * 4;
      final projects = '${store.root}/projects/$hash';
      final generation = '$projects/generations/pub-1-1';
      File('$generation/installation.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'source': 'pub',
            'version': '1.2.0',
            'location': '/fixture',
            'managed': false,
            'exported_paths': <String>[],
            'commands': <String, Object>{},
          }),
        );
      Link('$projects/current').createSync('generations/pub-1-1');
      for (final command in project.commands) {
        final target = '$projects/current/bin/$command';
        File('$generation/bin/$command')
          ..createSync(recursive: true)
          ..writeAsStringSync('#!/bin/sh\nexec /bin/echo legacy $command\n');
        File('${store.bin}/$command')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            "#!/bin/sh\n# rk-managed:$hash\nif [ ! -x '$target' ]; then\n"
            "  printf '%s\\n' 'rk: $command has no usable selection. Run rk use from its configured repository.' >&2\n"
            "  exit 127\nfi\nexec '$target' \"\$@\"\n",
          );
        for (final file in [
          '$generation/bin/$command',
          '${store.bin}/$command',
        ]) {
          await Process.run('/bin/chmod', ['700', file]);
        }
      }
      pub.installed = Installation(
        source: pub.source,
        version: '1.2.0',
        location: '/fixture',
        commands: const {},
      );
      expect((await manager.inspect(project)).selected, pub.source);
      await expectLater(
        act(pub.source, InstallationAction.uninstall),
        throwsA(isA<InstallationFailure>()),
      );
      expect(pub.removals, 0);
      expect(
        (await Process.run('${store.bin}/orbit', [])).stdout,
        'legacy orbit\n',
      );
      await act(local.source, InstallationAction.use);
      expect(
        (await Process.run('${store.bin}/orbit', [])).stdout,
        'local orbit\n',
      );
    },
  );

  test(
    'a switch interrupted between commands keeps both sources it runs',
    () async {
      await act(pub.source, InstallationAction.use);
      // The switch to Local wrote orbit's launcher, then stopped.
      final first = ExecutableProject(
        root: project.root,
        unit: project.unit,
        project: project.project,
        entrypoints: {'orbit': project.entrypoints['orbit']!},
        repository: project.repository,
      );
      await manager.act(
        first,
        local.source,
        InstallationAction.use,
        progress: (_) {},
      );
      final state = await manager.inspect(project);
      expect(state.currentSources, {
        'orbit': local.source,
        'orbit_admin': pub.source,
      });
      expect(state.routing.single, contains('run rk use local again'));
      await expectLater(
        act(pub.source, InstallationAction.uninstall),
        throwsA(isA<InstallationFailure>()),
      );
      expect(pub.removals, 0);
    },
  );

  test('a package name that is not a Dart identifier is refused', () {
    // A line break in the name would add a line to the launcher's script.
    expect(
      () => fixture(scratch, name: '"orbit\\ntouch pwned"'),
      throwsA(isA<InstallationFailure>()),
    );
  });

  group('another project exporting the same command', () {
    late ExecutableProject other;
    setUp(
      () => other = fixture(scratch, name: 'other', commands: ['orbit_admin']),
    );
    Future<String> actOther(InstallationSource source) =>
        manager.act(other, source, InstallationAction.use, progress: (_) {});

    test('cannot take over a command this project selected', () async {
      await act(local.source, InstallationAction.use);
      await expectLater(
        actOther(pub.source),
        throwsA(
          isA<InstallationFailure>().having(
            (e) => e.message,
            'message',
            contains(project.name),
          ),
        ),
      );
      expect(
        (await Process.run('${store.bin}/orbit_admin', [])).stdout,
        'local orbit_admin\n',
      );
      expect((await manager.inspect(other)).selected, isNull);
    });

    test('is reported where it took a command over', () async {
      await act(local.source, InstallationAction.use);
      File('${store.bin}/orbit_admin').deleteSync();
      var state = await manager.inspect(project);
      expect(state.selected, local.source);
      expect(state.currentSources['orbit_admin'], isNull);
      expect(state.routing.single, contains('run rk use local again'));
      await actOther(pub.source);
      state = await manager.inspect(project);
      expect(state.currentSources, {
        'orbit': local.source,
        'orbit_admin': null,
      });
      expect(state.routing.single, contains('selected for other'));
      expect(state.currentSource, isNull);
    });
  });

  test(
    'native local launch preserves caller directory, arguments and edits in mapped scripts',
    () async {
      final environment = {
        ...Platform.environment,
        'HOME': scratch.path,
        'PUB_CACHE': '${scratch.path}/pub-cache',
      };
      final tools = TestTools(
        (exe, args, cwd, env) => const SystemTools().run(
          exe,
          args,
          workingDirectory: cwd,
          environment: {...environment, ...?env},
        ),
      );
      final provider = LocalInstallationProvider(
        tools,
        Platform.resolvedExecutable,
        store,
      );
      final live = InstallationManager(
        store: store,
        providers: {provider.source: provider},
        environment: environment,
      );
      await live.act(
        project,
        provider.source,
        InstallationAction.use,
        progress: (_) {},
      );
      final caller = Directory('${scratch.path}/caller with space')
        ..createSync();
      Future<ProcessResult> launch() => Process.run(
        '${store.bin}/orbit',
        ['a b', r'$(touch bad)', "it's"],
        workingDirectory: caller.path,
        environment: environment,
      );
      final first = await launch();
      expect(first.exitCode, 0, reason: '${first.stderr}');
      expect(
        first.stdout,
        'orbit\n${caller.resolveSymbolicLinksSync()}\na b|\$(touch bad)|it\'s\n',
      );
      final script = File('${project.directory}/bin/orbit_main.dart');
      script.writeAsStringSync(
        script.readAsStringSync().replaceFirst(
          "print('orbit')",
          "print('edited')",
        ),
      );
      expect((await launch()).stdout, startsWith('edited\n'));
      script.deleteSync();
      final missing = await launch();
      expect(missing.exitCode, 127);
      expect(missing.stderr, contains('no longer available'));
      expect(File('${caller.path}/bad').existsSync(), isFalse);
    },
  );

  test(
    'fish setup is persisted in an isolated config and resolves managed commands',
    () async {
      final fish = findExecutable('fish', Platform.environment);
      if (fish == null) return;
      await act(local.source, InstallationAction.use);
      final env = {
        ...Platform.environment,
        'HOME': scratch.path,
        'XDG_CONFIG_HOME': '${scratch.path}/fish-config',
        'SHELL': fish,
        'PATH': '/usr/bin:/bin',
      };
      final message = await ShellRouting(
        store,
        const SystemTools(),
        env,
      ).ensure(project);
      expect(message, equals('Ready at the next prompt.'));
      final resolved = await Process.run(fish, [
        '-c',
        'command -s orbit; orbit',
      ], environment: env);
      expect(resolved.exitCode, 0, reason: '${resolved.stderr}');
      expect(resolved.stdout, '${store.bin}/orbit\nlocal orbit\n');
      expect(
        File('${scratch.path}/fish-config/fish/fish_variables').existsSync(),
        isTrue,
      );
    },
  );
}
