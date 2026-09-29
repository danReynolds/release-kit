@Timeout(Duration(minutes: 2))
library;

import 'dart:io';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/installations/store.dart';
import 'package:test/test.dart';

void main() {
  test(
    'retained native, AOT and JIT snapshots work after the original is removed',
    () async {
      final root = Directory.systemTemp.createTempSync('rk-manager-test-');
      addTearDown(() => root.deleteSync(recursive: true));
      final store = InstallationStore(
        '${root.path}/data with spaces',
        const SystemTools(),
      );
      final dart = Platform.resolvedExecutable;
      final sdkBin = File(dart).parent.path;
      for (final kind in ['exe', 'aot-snapshot', 'jit-snapshot']) {
        final source = Directory('${root.path}/$kind')..createSync();
        final script = File('${source.path}/main.dart')
          ..writeAsStringSync(
            '''import 'package:rk/src/installations/recovery.dart';
import 'package:rk/src/installations/store.dart';
import 'package:rk/src/engine/tools.dart';
Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == 'keep') {
    print(await preserveManager(InstallationStore(args[1], const SystemTools()), const SystemTools(), (_) {}));
  } else { print("retained: \$args"); }
}''',
          );
        final program = '${source.path}/program';
        final compile = await Process.run(dart, [
          '--suppress-analytics',
          'compile',
          kind,
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          '-o',
          program,
          script.path,
        ]);
        expect(compile.exitCode, 0, reason: '${compile.stderr}');
        final executable = kind == 'exe'
            ? program
            : kind == 'aot-snapshot'
            ? '$sdkBin/dartaotruntime'
            : dart;
        final retained = await store.retainManager(
          executable,
          program: kind == 'exe' ? null : program,
        );
        expect(
          await store.retainManager(
            executable,
            program: kind == 'exe' ? null : program,
          ),
          retained,
        );
        source.deleteSync(recursive: true);
        final run = await Process.run(retained, [
          'use',
          'argument with spaces',
        ]);
        expect(run.exitCode, 0, reason: '$kind: ${run.stderr}');
        expect(run.stdout, 'retained: [use, argument with spaces]\n');
        final again = await Process.run(retained, ['keep', store.root]);
        expect(
          again.exitCode,
          0,
          reason: '$kind second preservation: ${again.stderr}',
        );
        final recovery = (again.stdout as String).trim();
        expect(File(recovery).existsSync(), isTrue);
        final rerun = await Process.run(recovery, ['use', '--help']);
        expect(rerun.exitCode, 0, reason: '$kind: ${rerun.stderr}');
        expect(rerun.stdout, 'retained: [use, --help]\n');
      }
    },
  );
}
