import 'dart:io';
import 'dart:isolate';

import '../engine/tools.dart';
import 'model.dart';
import 'provider.dart';
import 'store.dart';

/// Preserve and verify this manager before changing one of its installations.
/// Native binaries and runtime/snapshot bundles are copied. Source runs compile
/// a standalone build so recovery does not depend on a mutable checkout.
Future<String> preserveManager(
  InstallationStore store,
  Tools tools,
  void Function(String) progress,
) async {
  progress('Preserving this manager for recovery…');
  final executable = File(
    Platform.resolvedExecutable,
  ).resolveSymbolicLinksSync();
  final name = executable.split(Platform.pathSeparator).last;
  final runtime = {
    'dart',
    'dart.exe',
    'dartvm',
    'dartvm.exe',
    'dartaotruntime',
    'dartaotruntime.exe',
  }.contains(name);
  String retained;
  if (!runtime) {
    retained = await store.retainManager(executable);
  } else {
    final script = Platform.script;
    if (script.scheme != 'file') {
      throw const InstallationFailure(
        'This manager cannot retain its running build.',
        'Run a native rk executable before changing rk installations.',
      );
    }
    if (!script.path.endsWith('.dart')) {
      retained = await store.retainManager(
        executable,
        program: script.toFilePath(),
      );
    } else {
      final temporary = Directory.systemTemp.createTempSync('rk-manager-');
      try {
        final output = '${temporary.path}/rk';
        final packages = await Isolate.packageConfig;
        await checked(tools, executable, [
          '--suppress-analytics',
          'compile',
          'exe',
          script.toFilePath(),
          if (packages != null) '--packages=${packages.toFilePath()}',
          '-o',
          output,
        ]);
        retained = await store.retainManager(output);
      } finally {
        temporary.deleteSync(recursive: true);
      }
    }
  }
  // Validate the relocated entry point before any installation is changed.
  await checked(tools, retained, ['use', '--help']);
  return retained;
}
