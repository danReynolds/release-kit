import 'dart:ffi';
import 'dart:io';

import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/builds/dart_cli.dart';
import 'package:rk/src/engine/stage_plan.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/transforms/macos.dart';
import 'package:test/test.dart';

void main() {
  // Ad-hoc signatures carry no team, so library validation stays off here and
  // the library load constraint alone decides what the runtime may load. A
  // Developer ID release applies both checks.
  test('a pinned runtime runs its own module and refuses any other', () async {
    final root = Directory.systemTemp.createTempSync('rk-pin-');
    addTearDown(() => root.deleteSync(recursive: true));
    File('${root.path}/main.dart')
        .writeAsStringSync("void main() => print('tool 1.2.3');\n");
    File('${root.path}/other.dart')
        .writeAsStringSync("void main() => print('another module');\n");
    final compiler =
        DartCompilerIdentity.readResolved(Platform.resolvedExecutable);
    final platform =
        Abi.current() == Abi.macosArm64 ? 'macos-arm64' : 'macos-x64';
    final built = await DartCliBuilder(
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
            output: '${root.path}/bundle/tool',
            workingDirectory: root.path,
            expectedVersion: '1.2.3');
    expect(built.ok, isTrue, reason: '${built.problem}\n${built.transcript}');
    final launcher = '${root.path}/bundle/tool';
    final runtime = '${root.path}/bundle/lib/tool/dartaotruntime';
    final module = '${root.path}/bundle/lib/tool/app.aot';
    final other = '${root.path}/other.aot';
    final compiled = await Process.run(compiler.executable,
        ['compile', 'aot-snapshot', 'other.dart', '-o', other],
        workingDirectory: root.path);
    expect(compiled.exitCode, 0, reason: '${compiled.stderr}');

    // Files the builder's smoke test already ran are never rewritten in place:
    // the kernel caches a file's signature, so each change lands as a new
    // file renamed over the old one.
    void replace(String path, String source) {
      File(source).copySync('$path.new');
      File('$path.new').renameSync(path);
    }

    Future<void> adHoc(String path, [List<String> options = const []]) async {
      File(path).copySync('$path.unsigned');
      final signed = await Process.run(
          'codesign', ['--force', ...options, '--sign', '-', '$path.unsigned']);
      expect(signed.exitCode, 0, reason: '${signed.stderr}');
      replace(path, '$path.unsigned');
    }

    await adHoc(module);
    await adHoc(other);
    final signer = MacOsSigner(tools: const SystemTools());
    final hashes = await signer.codeDirectoryHashes(module);
    expect(hashes, isNotEmpty);
    final constraint = File('${root.path}/constraint.plist')
      ..writeAsStringSync(libraryConstraintPlist(hashes!));
    await adHoc(runtime, [
      '--enforce-constraint-validity',
      '--library-constraint',
      constraint.path,
    ]);
    expect(await signer.admittedLibraries(runtime), hashes.toSet());

    final own = await Process.run(launcher, ['--version']);
    expect(own.exitCode, 0, reason: '${own.stderr}');
    expect(own.stdout, contains('tool 1.2.3'));

    replace(module, other);
    final swapped = await Process.run(launcher, ['--version']);
    expect(swapped.exitCode, isNot(0),
        reason: 'the pinned runtime ran a module it does not admit');
    expect(swapped.stdout, isNot(contains('another module')));
    expect(swapped.stderr, contains('library load'),
        reason: 'the refusal must come from the constraint');

    // The refusal is the pin's: the same runtime without it runs the swap.
    await adHoc(runtime);
    expect(await signer.admittedLibraries(runtime), isEmpty);
    final unpinned = await Process.run(launcher, ['--version']);
    expect(unpinned.exitCode, 0, reason: '${unpinned.stderr}');
    expect(unpinned.stdout, contains('another module'));
  }, skip: !Platform.isMacOS, timeout: const Timeout(Duration(minutes: 3)));
}
