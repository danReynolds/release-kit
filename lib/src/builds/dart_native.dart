import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import '../engine/tools.dart';
import 'capability.dart';

/// Use Pub's production dependency graph, like Dart's build command. A hook in
/// a dev dependency or unrelated workspace member must not change this build.
bool hasDartBuildHooks(String directory, String repositoryRoot) {
  final config = dartBuildFile(
    directory,
    repositoryRoot,
    '.dart_tool/package_config.json',
  );
  if (config == null) return false;
  final packages =
      (jsonDecode(config.readAsStringSync()) as Map)['packages'] as List;
  final roots = {
    for (final package in packages)
      package['name'] as String: Directory.fromUri(
        config.uri.resolve(package['rootUri'] as String),
      ).uri,
  };
  final graph =
      jsonDecode(
            File.fromUri(
              config.uri.resolve('package_graph.json'),
            ).readAsStringSync(),
          )
          as Map;
  final dependencies = {
    for (final package in graph['packages'] as List)
      package['name'] as String: (package['dependencies'] as List)
          .cast<String>(),
  };
  final pubspec = dartBuildFile(directory, repositoryRoot, 'pubspec.yaml')!;
  final name = (loadYaml(pubspec.readAsStringSync()) as Map)['name'] as String;
  final pending = [name];
  final visited = <String>{};
  while (pending.isNotEmpty) {
    final package = pending.removeLast();
    if (!visited.add(package)) continue;
    if (File.fromUri(roots[package]!.resolve('hook/build.dart')).existsSync()) {
      return true;
    }
    pending.addAll(dependencies[package] ?? const []);
  }
  return false;
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

/// Pub owns the lock beside the nearest pubspec whose resolution is not
/// `workspace`. An independent nested package must not inherit a parent's lock.
bool dartBuildIsLocked(String directory, String repositoryRoot) {
  var current = Directory(directory).absolute;
  final root = Directory(repositoryRoot).absolute.path;
  while (true) {
    final pubspec = File('${current.path}/pubspec.yaml');
    if (pubspec.existsSync()) {
      try {
        final manifest = loadYaml(pubspec.readAsStringSync());
        final overrides = File('${current.path}/pubspec_overrides.yaml');
        final override = overrides.existsSync()
            ? loadYaml(overrides.readAsStringSync())
            : null;
        final resolution = override is Map && override.containsKey('resolution')
            ? override['resolution']
            : manifest is Map
            ? manifest['resolution']
            : null;
        if (resolution != 'workspace') {
          return File('${current.path}/pubspec.lock').existsSync();
        }
      } on YamlException {
        // Let Pub report the malformed manifest in its normal build output.
        return false;
      }
    }
    if (current.path == root || current.parent.path == current.path) {
      return false;
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
  // Linux bind mounts retain container ownership. Run as the operator so the
  // output and hook cache remain removable by RK after success or failure.
  String? user;
  if (capabilities.hostPlatform.startsWith('linux-')) {
    final ids = await Future.wait([
      tools.run('id', const ['-u']),
      tools.run('id', const ['-g']),
    ]);
    if (ids.any(
      (id) => !id.ok || !RegExp(r'^\d+$').hasMatch(id.stdout.trim()),
    )) {
      return _failure('could not determine the Linux build user and group');
    }
    user = ids.map((id) => id.stdout.trim()).join(':');
  }
  return tools.run(runtime, [
    'run',
    '--rm',
    '--platform',
    'linux/${platform.endsWith('-x64') ? 'amd64' : 'arm64'}',
    if (user != null) ...[
      '--user',
      user,
      if (runtime == 'podman') '--userns=keep-id',
      '-e',
      'HOME=/tmp',
      '-e',
      'PUB_CACHE=/tmp/rk-pub-cache',
    ],
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
