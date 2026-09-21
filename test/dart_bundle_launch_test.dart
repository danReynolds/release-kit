import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/builds/dart_cli.dart';
import 'package:rk/src/engine/stage_plan.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:test/test.dart';

void main() {
  test(
      'native launcher survives relocation and preserves argv, pid, signals and exit',
      () async {
    final root = Directory.systemTemp.createTempSync('rk-launcher-');
    addTearDown(() => root.deleteSync(recursive: true));
    File('${root.path}/main.dart').writeAsStringSync(r'''
import 'dart:convert';
import 'dart:io';
void main(List<String> args) {
  if (args.contains('--version')) { print('tool 1.2.3'); return; }
  if (args.contains('--wait')) {
    ProcessSignal.sigterm.watch().listen((_) => exit(23));
    print(pid);
    return;
  }
  print(jsonEncode(args));
  print(const String.fromEnvironment('test.identity'));
  exitCode = 7;
}
''');
    final compiler =
        DartCompilerIdentity.readResolved(Platform.resolvedExecutable);
    final platform =
        Abi.current() == Abi.macosArm64 ? 'macos-arm64' : 'macos-x64';
    final output = '${root.path}/initial/tool';
    final result = await DartCliBuilder(
            tools: const SystemTools(),
            compilerExecutable: compiler.executable,
            runtimeSha256: compiler.runtimeSha256,
            capabilities: HostCapabilities(
                hostPlatform: platform,
                containerRuntime: null,
                hasNativeAssets: false))
        .build(
            platform: platform,
            entryPoint: 'main.dart',
            output: output,
            workingDirectory: root.path,
            expectedVersion: '1.2.3',
            defines: {'test.identity': 'from-pubspec'});
    expect(result.ok, isTrue,
        reason: '${result.problem}\n${result.transcript}');
    Directory('${root.path}/initial')
        .renameSync('${root.path}/installed space');
    final link = Link('${root.path}/tool')
      ..createSync('${root.path}/installed space/tool');
    final args = ['a b', '', r'$HOME', 'line\nbreak', 'é'];
    final run = await Process.run(link.path, args, workingDirectory: '/');
    expect(run.exitCode, 7);
    expect(run.stdout, '${jsonEncode(args)}\nfrom-pubspec\n');
    final child =
        await Process.start(link.path, ['--wait'], workingDirectory: '/');
    addTearDown(() {
      child.kill(ProcessSignal.sigkill);
    });
    final pid = await child.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 10));
    expect(int.parse(pid), child.pid,
        reason: 'exec replaces the launcher without an intermediate process');
    child.kill(ProcessSignal.sigterm);
    expect(await child.exitCode.timeout(const Duration(seconds: 10)), 23);
    File('${root.path}/installed space/lib/tool/dartaotruntime').deleteSync();
    final missing = await Process.run(link.path, ['--version']);
    expect(missing.exitCode, 126);
    expect(
        missing.stderr, contains('could not start the installed application'));
  }, skip: !Platform.isMacOS, timeout: const Timeout(Duration(minutes: 2)));
}
