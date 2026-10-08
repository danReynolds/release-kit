@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'fixtures.dart';
import '../support/compiled_rk.dart';

void main() {
  // Each case runs a separate real CLI process, sharing one compiled rk.
  late final executable = compiledRk();
  late Directory scratch;
  late Map<String, String> environment;
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('rk-install-cli-');
    environment = {
      ...Platform.environment,
      'HOME': '${scratch.path}/home',
      'PUB_CACHE': '${scratch.path}/cache',
      'XDG_DATA_HOME': '${scratch.path}/data',
      'SHELL': '/bin/sh',
      'PATH': '${File(Platform.resolvedExecutable).parent.path}:/usr/bin:/bin',
    };
  });
  tearDown(() => scratch.deleteSync(recursive: true));
  Future<(int, Map<String, dynamic>)> run(
    String root,
    List<String> args,
  ) async {
    final result = await Process.run(
      executable,
      [...args, '--json'],
      workingDirectory: root,
      environment: environment,
    );
    expect(result.stderr, isEmpty);
    expect(result.stdout, isNot(contains('\x1b')));
    return (
      result.exitCode,
      jsonDecode(result.stdout as String) as Map<String, dynamic>,
    );
  }

  test(
    'CLI refuses outside a configured directory and validates arguments without acting',
    () async {
      final (code, report) = await run(scratch.path, ['use']);
      expect(code, 1);
      expect(report['problems'].single['message'], contains('No rk setup'));
      final project = fixture(scratch);
      for (final args in [
        ['use', 'local', '-p'],
        ['use', 'local', '--list'],
        ['install', 'pub', '--yes'],
        ['use', 'local', 'extra'],
        ['use', 'pub', '--latest'],
        ['install', '--latest'],
        ['install', 'local', '--latest'],
        ['install', 'pub', '--latest', '--list'],
      ]) {
        final (code, _) = await run(project.directory, args);
        expect(code, 2);
      }
      final (unsupported, detail) = await run(project.directory, [
        'use',
        'homebrew',
      ]);
      expect(unsupported, 1);
      expect(
        detail['problems'].single['message'],
        contains('does not support'),
      );
      expect(Directory('${scratch.path}/data/rk').existsSync(), isFalse);
    },
  );

  test(
    'bare non-TTY use lists; explicit use works from a descendant and reports routing honestly',
    () async {
      final project = fixture(scratch);
      final nested = Directory('${project.directory}/nested')..createSync();
      final (listed, report) = await run(nested.path, [
        'use',
        '-p',
        project.name,
      ]);
      expect(listed, 0);
      expect(report['installations']['projects'].single['sources'].keys, [
        'local',
        'pub',
      ]);
      expect(Directory('${scratch.path}/data/rk').existsSync(), isFalse);
      final (installed, prepared) = await run(nested.path, [
        'install',
        'local',
      ]);
      expect(installed, 0, reason: '$prepared');
      expect(prepared['installations']['projects'].single['selected'], isNull);
      final (used, selected) = await run(nested.path, [
        'use',
        'local',
        '--project=${project.name}',
      ]);
      expect(used, 0, reason: '$selected');
      final state = selected['installations']['projects'].single;
      expect(state['selected'], 'local');
      expect(state['routing_problems'], hasLength(2));
      final entry = '${selected['installations']['managed_bin']}/orbit';
      final result = await Process.run(
        entry,
        ['dogfood'],
        workingDirectory: nested.path,
        environment: environment,
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('dogfood'));
      final (removal, refused) = await run(nested.path, [
        'uninstall',
        'local',
        '--yes',
      ]);
      expect(removal, 1);
      expect(refused['problems'].single['message'], contains('selected'));
    },
  );

  test(
    'local accepts development dependencies while release resolution refuses them',
    () async {
      final project = fixture(scratch);
      final dependency = Directory('${scratch.path}/unpublished')..createSync();
      File('${dependency.path}/pubspec.yaml').writeAsStringSync(
        'name: unpublished\nversion: 0.0.1\nenvironment:\n  sdk: ^3.10.4\n',
      );
      final manifest = File('${project.directory}/pubspec.yaml');
      manifest.writeAsStringSync(
        '${manifest.readAsStringSync()}\ndependencies:\n  unpublished:\n    path: ${dependency.path}\n',
      );
      final tree = FileSystemSourceTree(project.directory);
      final diagnostics = Diagnostics();
      final config = ReleaseConfig.parse(
        tree.read('release.toml')!,
        'release.toml',
        diagnostics,
      )!;
      expect(Resolution.resolve(config, tree, diagnostics), isNull);
      expect(
        diagnostics.found.map((problem) => problem.code),
        contains('RK-DART-201'),
      );
      final (used, selected) = await run(project.directory, ['use', 'local']);
      expect(used, 0, reason: '$selected');
      final entry = '${selected['installations']['managed_bin']}/orbit';
      final result = await Process.run(
        entry,
        ['development'],
        workingDirectory: scratch.path,
        environment: environment,
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('development'));
    },
  );

  test(
    'multi-project config lists each executable package, requires -p and excludes SDKs',
    () async {
      fixture(scratch, name: 'first');
      fixture(scratch, name: 'second');
      final sdk = Directory('${scratch.path}/sdk')..createSync();
      File(
        '${sdk.path}/pubspec.yaml',
      ).writeAsStringSync('name: sdk\nversion: 1.0.0\n');
      File('${scratch.path}/release.toml').writeAsStringSync('''schema = 2
[release.first]
path = "first"
publish = ["pub.dev"]
[release.second]
path = "second"
publish = ["pub.dev"]
[release.sdk]
path = "sdk"
publish = ["pub.dev"]
''');
      final (listed, inventory) = await run(scratch.path, ['use', '--list']);
      expect(listed, 0, reason: '$inventory');
      expect(
        (inventory['installations']['projects'] as List).map(
          (p) => p['project'],
        ),
        ['first', 'second'],
      );
      final (ambiguous, refused) = await run(scratch.path, [
        'install',
        'local',
      ]);
      expect(ambiguous, 1);
      expect(refused['problems'].single['message'], contains('Choose one'));
      final (filtered, result) = await run(scratch.path, [
        'use',
        '--list',
        '-p',
        'second',
      ]);
      expect(filtered, 0);
      expect(result['installations']['projects'].single['project'], 'second');
      final (library, _) = await run(scratch.path, [
        'use',
        'local',
        '-p',
        'sdk',
      ]);
      expect(library, 1);
    },
  );
}
