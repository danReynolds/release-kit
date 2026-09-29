import 'dart:io';

import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/builds/dart_cli.dart';
import 'package:rk/src/engine/stage_plan.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/targets/homebrew/client.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

/// Installs a real bundle through Homebrew, which changes the host's Homebrew
/// installation. It runs only where RK_BREW_INSTALL_TEST=1, as in CI's macOS
/// job.
void main() {
  final enabled =
      Platform.isMacOS &&
      Platform.environment['RK_BREW_INSTALL_TEST'] == '1' &&
      HostCapabilities.inspect().hostPlatform == 'macos-arm64';

  test(
    'Homebrew installs the bundle without rewriting its signed files',
    () async {
      const name = 'rkbrewprobe';
      const tap = 'rk-test/probe';
      final environment = {
        'HOMEBREW_NO_AUTO_UPDATE': '1',
        'HOMEBREW_NO_ANALYTICS': '1',
        'HOMEBREW_NO_ENV_HINTS': '1',
      };
      Future<ProcessResult> brew(List<String> arguments) =>
          Process.run('brew', arguments, environment: environment);

      final root = Directory.systemTemp.createTempSync('rk-brew-');
      addTearDown(() => root.deleteSync(recursive: true));
      File(
        '${root.path}/main.dart',
      ).writeAsStringSync("void main() => print('$name 1.2.3');\n");
      final compiler = DartCompilerIdentity.readResolved(
        Platform.resolvedExecutable,
      );
      final capabilities = HostCapabilities.inspect();
      final built =
          await DartCliBuilder(
            tools: const SystemTools(),
            compilerExecutable: compiler.executable,
            runtimeSha256: compiler.runtimeSha256,
            capabilities: capabilities,
          ).build(
            platform: 'macos-arm64',
            entryPoint: 'main.dart',
            output: '${root.path}/bundle/$name',
            workingDirectory: root.path,
            expectedVersion: '1.2.3',
          );
      expect(built.ok, isTrue, reason: '${built.problem}\n${built.transcript}');
      const signedFiles = [
        name,
        'lib/$name/dartaotruntime',
        'lib/$name/app.aot',
      ];
      final staged = {
        for (final file in signedFiles)
          file: Sha256.hex(File('${root.path}/bundle/$file').readAsBytesSync()),
      };

      final archive = '${root.path}/$name-1.2.3-macos-arm64.tar.gz';
      final packed = await Process.run('tar', [
        '-czf',
        archive,
        '-C',
        '${root.path}/bundle',
        '.',
      ]);
      expect(packed.exitCode, 0, reason: '${packed.stderr}');
      final formula = HomebrewFormula.render(
        className: 'Rkbrewprobe',
        description: 'rk Homebrew install probe',
        homepage: 'https://github.com/danReynolds/release-kit',
        version: '1.2.3',
        repository: 'danReynolds/release-kit',
        tag: 'v1.2.3',
        assets: {
          'macos-arm64': PlatformAsset(
            name: '$name-1.2.3-macos-arm64.tar.gz',
            sha256: Sha256.hex(File(archive).readAsBytesSync()),
          ),
        },
        executable: name,
      ).replaceFirst(RegExp(r'url "https://[^"]+"'), 'url "file://$archive"');

      final created = await brew(['tap-new', '--no-git', tap]);
      expect(created.exitCode, 0, reason: '${created.stderr}');
      addTearDown(() async {
        await brew(['uninstall', '--force', name]);
        await brew(['untap', '--force', tap]);
      });
      final tapPath = (await brew([
        '--repository',
        tap,
      ])).stdout.toString().trim();
      File('$tapPath/Formula/$name.rb')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(formula);

      final installed = await brew(['install', '$tap/$name']);
      expect(
        installed.exitCode,
        0,
        reason: '${installed.stdout}\n${installed.stderr}',
      );
      final prefix = (await brew(['--prefix', name])).stdout.toString().trim();
      for (final file in signedFiles) {
        expect(
          Sha256.hex(File('$prefix/libexec/$file').readAsBytesSync()),
          staged[file],
          reason:
              'Homebrew changed $file; the signed runtime would refuse '
              'a re-signed module',
        );
      }
      final version = await Process.run('$prefix/bin/$name', ['--version']);
      expect(version.exitCode, 0, reason: '${version.stderr}');
      expect(version.stdout, contains('1.2.3'));
      final tested = await brew(['test', '$tap/$name']);
      expect(tested.exitCode, 0, reason: '${tested.stdout}\n${tested.stderr}');
    },
    skip: enabled
        ? false
        : 'installs into Homebrew; set RK_BREW_INSTALL_TEST=1 on a '
              'disposable arm64 macOS host',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
