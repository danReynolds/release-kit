import 'dart:io';

import 'git.dart';
import 'resolve.dart';
import 'timings.dart';

/// The Dart SDK rk builds with: the `dart` on PATH, followed through a
/// Flutter or version-manager wrapper to the SDK's own executable, beside
/// which `dartaotruntime` and the SDK's LICENSE live.
///
/// Read once per process, and only when something is built: a stage is
/// named by what it is built from, not by the tools that built it.
final class DartSdk {
  const DartSdk({required this.executable, required this.version});

  /// The SDK's `dart`, never a wrapper script.
  final String executable;

  /// What `dart --version` printed.
  final String version;

  /// The SDK selected by PATH, read the first time it is asked for.
  static DartSdk ambient() =>
      _ambient ??= read(path: Platform.environment['PATH'] ?? '');
  static DartSdk? _ambient;

  Map<String, Object?> toJson() => {
    'executable': executable,
    'version': version,
  };

  /// The SDK the `dart` first on [path] runs.
  static DartSdk read({required String path}) {
    final executable = _sdkExecutable(_resolveOnPath('dart', path));
    final ProcessResult result;
    try {
      result = timedRunSync(executable, const ['--version']);
    } on Object catch (error) {
      throw DartSdkUnavailable('dart --version could not run: $error');
    }
    final version = [
      '${result.stdout}'.trim(),
      '${result.stderr}'.trim(),
    ].where((part) => part.isNotEmpty).join('\n');
    if (result.exitCode != 0 || version.isEmpty) {
      throw DartSdkUnavailable(
        'dart --version exited ${result.exitCode}'
        '${version.isEmpty ? '' : ': $version'}',
      );
    }
    return DartSdk(executable: executable, version: version);
  }
}

class DartSdkUnavailable implements Exception {
  const DartSdkUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'the Dart SDK could not be found: $reason';
}

/// What a stage is built from, beyond the commit's own bytes: the unit's
/// configuration and the repository it is published from.
///
/// Git's commit and tree already name every source byte. The tools that
/// build a stage do not name it: a stage built before a toolchain update is
/// still the same release of the same commit, and a partly published release
/// must still find it afterwards.
Map<String, Object?> stagePlanFor(ResolvedUnit unit, GitState git) => {
  'unit': {
    'name': unit.name,
    'version': unit.version.canonical,
    'tag': unit.tag,
    'tag_pattern': unit.tagPattern,
    'homebrew_tap': unit.homebrewTap,
    'targets': unit.publish.map((target) => target.configName).toList()..sort(),
  },
  'source_binding': git.isBound ? 'git' : 'unbound',
  if (git.isBound) 'repository': git.originUrl,
  'projects': [
    for (final project in unit.projects)
      {
        'name': project.name,
        'version': project.version.canonical,
        'path': project.pubspec.directory,
        'executable': project.executable,
        'dart_defines': project.dartDefines,
        'targets': project.publish.map((target) => target.configName).toList()
          ..sort(),
        'binary_platforms': [...project.binaryPlatforms]..sort(),
        if (project.buildsAssets) 'build': project.build,
        if (project.buildsAssets) 'assets': project.assets,
      },
  ],
};

String _resolveOnPath(String command, String path) {
  if (path.isEmpty) throw const DartSdkUnavailable('PATH is empty');
  final separator = Platform.isWindows ? ';' : ':';
  final extensions = Platform.isWindows
      ? (Platform.environment['PATHEXT'] ?? '.EXE;.BAT;.CMD')
            .split(';')
            .where((extension) => extension.isNotEmpty)
            .toList()
      : const [''];
  for (final entry in path.split(separator)) {
    final directory = entry.isEmpty ? Directory.current.path : entry;
    for (final extension in extensions) {
      final candidate = File(
        '$directory${Platform.pathSeparator}$command$extension',
      ).absolute;
      if (FileSystemEntity.typeSync(candidate.path, followLinks: true) !=
          FileSystemEntityType.file) {
        continue;
      }
      try {
        return candidate.resolveSymbolicLinksSync();
      } on Object {
        return candidate.path;
      }
    }
  }
  throw const DartSdkUnavailable('dart is not on PATH');
}

/// The SDK executable behind [selected]: itself when `dartaotruntime` sits
/// beside it; Flutter's bundled SDK for Flutter's `bin/dart` script; and
/// otherwise whatever the command reports it runs, for a version manager's
/// shim, at the cost of starting a VM once.
String _sdkExecutable(String selected) {
  bool isSdk(String dart) =>
      File('${File(dart).parent.path}/dartaotruntime').existsSync();
  if (isSdk(selected)) return selected;
  final flutter = '${File(selected).parent.path}/cache/dart-sdk/bin/dart';
  if (File(flutter).existsSync() && isSdk(flutter)) return flutter;

  final probe = Directory.systemTemp.createTempSync('rk-dart-sdk-');
  try {
    final script = File('${probe.path}/sdk.dart')
      ..writeAsStringSync(
        "import 'dart:io'; void main() => print(Platform.resolvedExecutable);\n",
      );
    final result = timedRunSync(selected, [
      script.path,
    ], workingDirectory: probe.path);
    final path = '${result.stdout}'.trim().split('\n').last;
    if (result.exitCode == 0 &&
        File(path).isAbsolute &&
        File(path).existsSync() &&
        isSdk(path)) {
      return File(path).resolveSymbolicLinksSync();
    }
    return selected;
  } finally {
    probe.deleteSync(recursive: true);
  }
}
