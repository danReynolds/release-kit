import 'dart:io';

import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/builds/dart_cli.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/transforms/archive.dart';
import 'package:test/test.dart';

import 'support/native_cli_fixture.dart';

/// Linux can exercise the stock SDK without declarations. macOS needs the
/// temporary SDK helper until upstream supports separate AOT bundle output.
/// Set RK_NATIVE_TEST_PLATFORMS to include container targets for qualification.
void main() {
  final host = HostCapabilities.detect();
  final helper = Platform.environment['RK_DART_BUILD_TOOL'];
  final image = Platform.environment['RK_DART_BUILD_IMAGE'];
  final compiler =
      Platform.environment['RK_NATIVE_TEST_DART'] ??
      Platform.resolvedExecutable;
  final platforms =
      Platform.environment['RK_NATIVE_TEST_PLATFORMS']?.split(',') ??
      [host.hostPlatform];
  test(
    'an independent nested CLI ignores parent locks and development hooks',
    () async {
      final root = Directory.systemTemp.createTempSync('rk-independent-cli-');
      addTearDown(() => root.deleteSync(recursive: true));
      File('${root.path}/pubspec.yaml').writeAsStringSync('name: parent\n');
      final parentLock = File('${root.path}/pubspec.lock')
        ..writeAsStringSync('unrelated lock');
      final child = Directory('${root.path}/packages/child')
        ..createSync(recursive: true);
      File('${child.path}/pubspec.yaml').writeAsStringSync('''
name: child
environment:
  sdk: ^3.10.4
dev_dependencies:
  hook_fixture:
    path: hook_fixture
''');
      File('${child.path}/bin/child.dart')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync("void main() => print('1.2.3');\n");
      File('${child.path}/hook_fixture/pubspec.yaml')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          'name: hook_fixture\nenvironment:\n  sdk: ^3.10.4\n',
        );
      File('${child.path}/hook_fixture/hook/build.dart')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          "void main() => throw StateError('development hook must not run');\n",
        );
      final built =
          await DartCliBuilder(
            tools: const SystemTools(),
            capabilities: host,
            compilerExecutable: compiler,
            nativeBuildTool: '/no-helper-needed',
          ).build(
            platform: host.hostPlatform,
            entryPoint: 'bin/child.dart',
            output: '${root.path}/built/child',
            workingDirectory: child.path,
            repositoryRoot: root.path,
            expectedVersion: '1.2.3',
          );
      expect(built.ok, isTrue, reason: '${built.problem}\n${built.transcript}');
      expect(parentLock.readAsStringSync(), 'unrelated lock');
      expect(File('${child.path}/pubspec.lock').existsSync(), isTrue);
      expect(built.artifact!.layout, Platform.isMacOS ? 'dart-aot' : 'single');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  for (final platform in platforms) {
    test(
      '$platform native hooks survive archive relocation and call the adapter',
      () async {
        final root = Directory.systemTemp.createTempSync('rk-native-real-');
        addTearDown(() => root.deleteSync(recursive: true));
        final source = Directory('${root.path}/source')..createSync();
        nativeCliFixture(source);
        // Commit-style locked dependencies: the builder must preserve these.
        final resolved = await Process.run(compiler, [
          '--suppress-analytics',
          'pub',
          'get',
        ], workingDirectory: source.path);
        expect(resolved.exitCode, 0, reason: '${resolved.stderr}');
        final lock = File('${source.path}/pubspec.lock').readAsStringSync();
        final declarations = helper != null || image != null;
        final built =
            await DartCliBuilder(
              tools: const SystemTools(),
              capabilities: host,
              compilerExecutable: compiler,
            ).build(
              platform: platform,
              entryPoint: 'bin/probe.dart',
              output: '${root.path}/built/renamed',
              workingDirectory: source.path,
              expectedVersion: '1.2.3',
              defines: declarations
                  ? {'fixture.identity': 'configured=value'}
                  : {},
            );
        expect(
          built.ok,
          isTrue,
          reason: '${built.problem}\n${built.transcript}',
        );
        expect(built.unproven, isNull);
        expect(File('${source.path}/pubspec.lock').readAsStringSync(), lock);
        final artifact = built.artifact!;
        final compressed = ArchiveBuilder.gzip(
          ArchiveBuilder.tar([
            for (final file in artifact.files)
              ArchiveEntry(
                name: file.path,
                bytes: File(
                  '${root.path}/built/${file.path}',
                ).readAsBytesSync(),
                executable: file.executable,
              ),
          ]),
        );
        final installed = Directory('${root.path}/installed space')
          ..createSync();
        ArchiveReader.decode(compressed).extractTo(installed);
        source.deleteSync(recursive: true);
        Directory('${root.path}/built').deleteSync(recursive: true);
        final link = Link('${root.path}/command')
          ..createSync('${installed.path}/${artifact.entryPoint}');
        Future<ProcessResult> run() => platform == host.hostPlatform
            ? Process.run(link.path, [], workingDirectory: '/')
            : Process.run('docker', [
                'run', '--rm', '--network=none', '--platform',
                'linux/${platform.endsWith('-x64') ? 'amd64' : 'arm64'}',
                '-v', '${installed.path}:/installed:ro',
                // No SDK, compiler, source tree, cache or development libs.
                'debian:trixie-slim', '/installed/${artifact.entryPoint}',
              ]);
        final result = await run();
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(
          result.stdout,
          '42|${declarations ? 'configured=value' : 'default'}\n',
        );
        final native = artifact.files.singleWhere(
          (file) => file.path.endsWith(
            platform.startsWith('macos-') ? 'libanswer.dylib' : 'libanswer.so',
          ),
        );
        File('${installed.path}/${native.path}').deleteSync();
        final missing = await run();
        expect(
          missing.exitCode,
          isNot(0),
          reason: 'the adapter must require its bundled library',
        );
      },
      skip: platform.startsWith('macos-') && helper == null
          ? 'set RK_DART_BUILD_TOOL to the matching native build helper'
          : false,
      timeout: const Timeout(Duration(minutes: 10)),
    );
  }
}
