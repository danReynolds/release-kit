import 'dart:convert';
import 'dart:io';

import '../engine/tools.dart';
import 'capability.dart';

/// The resolved package map is Dart's inventory of dependencies. Reading only
/// their hook entry points selects the compiler; Dart still owns hook execution.
bool hasDartBuildHooks(String directory, String repositoryRoot) {
  final config = dartBuildFile(
    directory,
    repositoryRoot,
    '.dart_tool/package_config.json',
  );
  if (config == null) return false;
  final packages =
      (jsonDecode(config.readAsStringSync()) as Map)['packages'] as List;
  return packages.any((package) {
    final root = Directory.fromUri(
      config.uri.resolve(package['rootUri'] as String),
    ).uri;
    return File.fromUri(root.resolve('hook/build.dart')).existsSync();
  });
}

File? dartBuildFile(String directory, String repositoryRoot, String name) {
  var current = Directory(directory).absolute;
  final root = Directory(repositoryRoot).absolute.path;
  while (true) {
    final file = File('${current.path}/$name');
    if (file.existsSync()) return file;
    if (current.path == root || current.parent.path == current.path) {
      return null;
    }
    current = current.parent;
  }
}

/// Native hooks run on the target OS/architecture. A Linux container is an
/// ordinary build environment supplied by the operator, not an RK SDK manager.
Future<ToolResult> buildDartNative({
  required Tools tools,
  required HostCapabilities capabilities,
  required String compiler,
  required String platform,
  required String directory,
  required String repositoryRoot,
  required String entryPoint,
  required String output,
  required Map<String, String> defines,
  required bool locked,
  String? helper,
  String? image,
}) async {
  final macos = platform.startsWith('macos-');
  List<String> arguments(String destination) => [
    if (macos) '--format=aot-snapshot',
    for (final name in defines.keys.toList()..sort())
      '-D$name=${defines[name]}',
    '--target',
    entryPoint,
    '--output',
    destination,
  ];
  if (platform == capabilities.hostPlatform) {
    var useHelper = helper != null;
    if (!useHelper && (macos || defines.isNotEmpty)) {
      final help = await tools.run(compiler, [
        'build',
        'cli',
        '--help',
      ], workingDirectory: directory);
      useHelper =
          !help.ok ||
          (macos && !help.stdout.contains('--format')) ||
          (defines.isNotEmpty && !help.stdout.contains('--define'));
    }
    if (useHelper) {
      final sdk = File(compiler).absolute.parent.parent.path;
      try {
        return await tools.run(helper ?? 'rk-dart-build', [
          sdk,
          ...arguments(output),
        ], workingDirectory: directory);
      } on ProcessException {
        return _failure(
          'This SDK needs the RK Dart build patch for native assets with '
          '${macos ? 'separate AOT output' : 'compile-time declarations'}. '
          'Install the matching helper and set RK_DART_BUILD_TOOL to rk-dart-build. '
          'See https://github.com/danReynolds/release-kit/releases/tag/dart-build-patch-3.13.5-1',
        );
      }
    }
    return tools.run(compiler, [
      'build',
      'cli',
      ...arguments(output),
    ], workingDirectory: directory);
  }
  final runtime = await capabilities.containerRuntime();
  if (!platform.startsWith('linux-') ||
      runtime == null ||
      image == null ||
      image.isEmpty) {
    return _failure(
      '$platform native hooks need a matching build environment. '
      'Start Docker or Podman and set RK_DART_BUILD_IMAGE to a Linux image '
      'with Dart and the dependencies required by the package hooks.',
    );
  }
  final root = Directory(repositoryRoot).absolute.path;
  final working = Directory(directory).absolute.path;
  if (working != root && !working.startsWith('$root/')) {
    return _failure(
      'the native build directory must be inside the staged repository',
    );
  }
  return tools.run(runtime, [
    'run',
    '--rm',
    '--platform',
    'linux/${platform.endsWith('-x64') ? 'amd64' : 'arm64'}',
    '-v',
    '$root:/src',
    '-v',
    '${Directory(output).parent.path}:/out',
    '-w',
    '/src${working.substring(root.length)}',
    image,
    'sh',
    '-c',
    _containerBuild,
    'rk-native-build',
    locked ? 'locked' : 'unlocked',
    defines.isEmpty ? 'ordinary' : 'defines',
    ...arguments(
      '/out/${Directory(output).uri.pathSegments.where((part) => part.isNotEmpty).last}',
    ),
  ]);
}

// Only fixed shell code: application paths and declarations are positional
// arguments. A container gets its own package map and Pub cache; host paths in
// the first resolution cannot leak into the target's hooks.
const _containerBuild = r'''
set -eu
if [ "$1" = locked ]; then
  dart --suppress-analytics pub get --enforce-lockfile
else
  dart --suppress-analytics pub get
fi
shift
declarations=$1
shift
if [ "$declarations" = defines ] && ! dart build cli --help | grep -q -- --define; then
  dart_path=$(readlink -f "$(command -v dart)")
  exec rk-dart-build "$(dirname "$(dirname "$dart_path")")" "$@"
fi
exec dart build cli "$@"
''';

ToolResult _failure(String message) =>
    ToolResult(exitCode: 64, stdout: '', stderr: message);

/// Accept every regular library the SDK produced, retaining nested paths.
/// Unexpected output is refused rather than silently left out of a release.
List<String> dartNativeLibraries(String bundle, String entry) {
  final root = Directory(bundle);
  final libraries = <String>[];
  var foundEntry = false;
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    final relative = entity.path.substring(root.path.length + 1);
    if (entity is Directory) continue;
    if (entity is! File) {
      throw FormatException(
        'Dart bundle contains a non-regular file: $relative',
      );
    }
    if (relative == entry) {
      foundEntry = true;
    } else if (relative.startsWith('lib/')) {
      libraries.add(relative.substring(4));
    } else {
      throw FormatException('unexpected Dart bundle file: $relative');
    }
  }
  if (!foundEntry) throw FormatException('Dart bundle is missing $entry');
  return libraries..sort();
}
