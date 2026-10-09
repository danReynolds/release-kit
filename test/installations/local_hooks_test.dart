import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/installations/local.dart';
import 'package:rk/src/installations/model.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/installations/store.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  test(
    'local launch with build hooks preserves cwd, entrypoint, arguments, stdin, stderr and exit status',
    () async {
      final scratch = Directory.systemTemp.createTempSync('rk hooks dollar\$ ');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final original = fixture(scratch, commands: ['orbit']);
      final project = ExecutableProject(
        root: original.root,
        unit: original.unit,
        entrypoints: original.entrypoints,
        project: ResolvedProject(
          unitName: original.project.unitName,
          config: original.project.config,
          pubspec: original.project.pubspec,
          dartDefines: {'probe.identity': r'identity $literal'},
        ),
      );
      final root = Directory(project.directory);
      final native = Directory('${scratch.path}/native_probe')..createSync();
      File('${native.path}/pubspec.yaml').writeAsStringSync(
        'name: local_native\nenvironment:\n  sdk: ^3.10.4\n'
        'dependencies:\n  hooks: 2.2.0\n  code_assets: 2.1.0\n',
      );
      final pubspec = File('${root.path}/pubspec.yaml');
      pubspec.writeAsStringSync(
        '${pubspec.readAsStringSync()}\ndependencies:\n'
        '  local_native:\n    path: ${native.path}\n',
      );
      File(
        '${native.path}/probe.c',
      ).writeAsStringSync('int probe(void) { return 41; }');
      File('${native.path}/hook/build.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync(r'''
import 'dart:io';
import 'package:hooks/hooks.dart';
import 'package:code_assets/code_assets.dart';
Future<void> main(List<String> args) => build(args, (input, output) async {
  if (!input.config.buildCodeAssets) return;
  final src = input.packageRoot.resolve('probe.c');
  final lib = input.outputDirectory.resolve(Platform.isMacOS ? 'libprobe.dylib' : 'libprobe.so');
  final result = await Process.run('cc', ['-shared', '-fPIC', if (Platform.isMacOS) '-Wl,-headerpad_max_install_names', src.toFilePath(), '-o', lib.toFilePath()]);
  if (result.exitCode != 0) throw StateError('${result.stderr}');
  output.dependencies.add(src);
  output.assets.code.add(CodeAsset(package: input.packageName, name: 'probe', file: lib, linkMode: DynamicLoadingBundled()));
});
''');
      final entry = File('${root.path}/bin/orbit_main.dart')
        ..writeAsStringSync(r'''
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
@Native<Int32 Function()>(assetId: 'package:local_native/probe')
external int probe();
Future<void> main(List<String> args) async {
  final input = await stdin.transform(utf8.decoder).join();
  print(jsonEncode({'cwd': Directory.current.path, 'script': Platform.script.toFilePath(), 'args': args, 'input': input, 'native': probe(), 'identity': const String.fromEnvironment('probe.identity')}));
  stderr.writeln('app stderr');
  exitCode = args.contains('nonzero') ? 7 : 0;
}
''');
      final store = InstallationStore(
        '${scratch.path}/data',
        const SystemTools(),
      );
      final provider = LocalInstallationProvider(
        const SystemTools(),
        Platform.resolvedExecutable,
        store,
      );
      final installed = await provider.install(project, null, (_) {});
      expect(installed.commands['orbit']!.workingDirectory, root.path);
      await store.activate(project, installed);
      final caller = Directory('${scratch.path}/caller')..createSync();
      // An unrelated, invalid package config must not influence the selected app.
      File('${caller.path}/.dart_tool/package_config.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"configVersion": 2, "packages": []}');
      Future<(int, String, String)> invoke(List<String> args) async {
        final process = await Process.start(
          '${store.bin}/orbit',
          args,
          workingDirectory: caller.path,
        );
        final out = process.stdout.transform(utf8.decoder).join();
        final err = process.stderr.transform(utf8.decoder).join();
        process.stdin.write('caller stdin\n');
        await process.stdin.close();
        return (await process.exitCode, await out, await err);
      }

      final first = await invoke(['space value', r'$literal', 'nonzero']);
      expect(first.$1, 7, reason: first.$3);
      final result = jsonDecode(first.$2) as Map;
      expect(
        Directory(result['cwd'] as String).resolveSymbolicLinksSync(),
        caller.resolveSymbolicLinksSync(),
      );
      expect(
        File(result['script'] as String).resolveSymbolicLinksSync(),
        entry.resolveSymbolicLinksSync(),
      );
      expect(result['args'], ['space value', r'$literal', 'nonzero']);
      expect(result['input'], 'caller stdin\n');
      expect(result['native'], 41);
      expect(result['identity'], r'identity $literal');
      expect(first.$3, contains('app stderr'));
    },
    skip: Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
