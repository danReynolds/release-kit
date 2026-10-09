@Timeout(Duration(minutes: 2))
library;

import 'dart:io';
import 'package:test/test.dart';
import 'fixtures.dart';
import '../rk_process.dart';

void main() {
  // Each case runs the real CLI, with HOME, the pub cache and rk's own data
  // in a scratch directory.
  late Directory scratch;
  late Map<String, String> environment;
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('rk-install-cli-');
    environment = {
      'HOME': '${scratch.path}/home',
      'PUB_CACHE': '${scratch.path}/cache',
      'XDG_DATA_HOME': '${scratch.path}/data',
      'SHELL': '/bin/sh',
      'PATH': '${File(Platform.resolvedExecutable).parent.path}:/usr/bin:/bin',
    };
  });
  tearDown(() => scratch.deleteSync(recursive: true));
  Run rk(String directory, List<String> args) =>
      Rk(directory)([...args, '--json'], environment: environment);
  dynamic installations(Run run) => run.json['installations'];

  test(
    'CLI refuses outside a configured directory and validates arguments without acting',
    () {
      final outside = rk(scratch.path, ['use']);
      expect(outside.code, 1, reason: outside.all);
      expect(outside.problems.single['message'], contains('No rk setup'));
      final project = fixture(scratch);
      for (final args in [
        ['use', 'local', 'extra'],
        ['use', 'pub', '--latest'],
        ['install', 'pub', '--yes'],
      ]) {
        expect(rk(project.directory, args).code, 2, reason: '$args');
      }
      final unsupported = rk(project.directory, ['use', 'homebrew']);
      expect(unsupported.code, 1, reason: unsupported.all);
      expect(
        unsupported.problems.single['message'],
        contains('does not support'),
      );
      expect(Directory('${scratch.path}/data/rk').existsSync(), isFalse);
    },
  );

  test(
    'bare non-TTY use lists; explicit use works from a descendant and reports routing honestly',
    () async {
      final project = fixture(scratch);
      // Local runs the checkout as it is, so it takes a dependency that is
      // not published yet, which a release refuses (RK-DART-201).
      final dependency = Directory('${scratch.path}/unpublished')..createSync();
      File('${dependency.path}/pubspec.yaml').writeAsStringSync(
        'name: unpublished\nversion: 0.0.1\nenvironment:\n  sdk: ^3.10.4\n',
      );
      final manifest = File('${project.directory}/pubspec.yaml');
      manifest.writeAsStringSync(
        '${manifest.readAsStringSync()}\ndependencies:\n  unpublished:\n    path: ${dependency.path}\n',
      );
      final nested = Directory('${project.directory}/nested')..createSync();

      final listed = rk(nested.path, ['use', '-p', project.name]);
      expect(listed.code, 0, reason: listed.all);
      expect(installations(listed)['projects'].single['sources'].keys, [
        'local',
        'pub',
      ]);
      expect(Directory('${scratch.path}/data/rk').existsSync(), isFalse);

      final used = rk(nested.path, [
        'use',
        'local',
        '--project=${project.name}',
      ]);
      expect(used.code, 0, reason: used.all);
      final state = installations(used)['projects'].single;
      expect(state['selected'], 'local');
      expect(state['routing_problems'], hasLength(2));
      final entry = '${installations(used)['managed_bin']}/orbit';
      final result = await Process.run(
        entry,
        ['dogfood'],
        workingDirectory: nested.path,
        environment: environment,
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('dogfood'));
    },
  );

  test(
    'multi-project config lists each executable package, requires -p and excludes SDKs',
    () {
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
      final inventory = rk(scratch.path, ['use', '--list']);
      expect(inventory.code, 0, reason: inventory.all);
      expect(
        (installations(inventory)['projects'] as List).map((p) => p['project']),
        ['first', 'second'],
      );
      final ambiguous = rk(scratch.path, ['install', 'local']);
      expect(ambiguous.code, 1, reason: ambiguous.all);
      expect(ambiguous.problems.single['message'], contains('Choose one'));
      final filtered = rk(scratch.path, ['use', '--list', '-p', 'second']);
      expect(filtered.code, 0, reason: filtered.all);
      expect(installations(filtered)['projects'].single['project'], 'second');
      expect(rk(scratch.path, ['use', 'local', '-p', 'sdk']).code, 1);
    },
  );
}
