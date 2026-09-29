import 'dart:convert';
import 'dart:io';

import '../../engine/diagnostic.dart';
import '../../engine/yaml.dart';

/// A dependency override that Pub honours where it resolves the staged
/// package and strips from the published archive: the package it replaces
/// ([everyPackage] when the overrides file cannot be read) and where it is
/// declared, relative to the source root.
typedef DependencyOverride = ({String package, String declaredIn});

/// Stands for every package when an overrides file cannot be read.
const everyPackage = '*';

/// Every override that applies where Pub resolves [directory]: a
/// `pubspec_overrides.yaml` or `dependency_overrides` section at the package
/// or at the workspace root it resolves from.
List<DependencyOverride> dependencyOverrides(
  String sourceRoot,
  String directory,
) {
  String describe(String path) {
    final prefix = '$sourceRoot/';
    return path.startsWith(prefix) ? path.substring(prefix.length) : path;
  }

  final found = <DependencyOverride>[];
  for (final root in {directory, resolutionRoot(sourceRoot, directory)}) {
    final file = '$root/pubspec_overrides.yaml';
    if (File(file).existsSync()) {
      final names = _manifest(file)?.map('dependency_overrides')?.keys;
      if (names == null || names.isEmpty) {
        found.add((package: everyPackage, declaredIn: describe(file)));
      } else {
        for (final name in names) {
          found.add((package: name, declaredIn: describe(file)));
        }
      }
    }
    final section = _manifest(
      '$root/pubspec.yaml',
    )?.map('dependency_overrides');
    for (final name in section?.keys ?? const <String>[]) {
      found.add((
        package: name,
        declaredIn:
            'the dependency_overrides section in '
            '${describe('$root/pubspec.yaml')}',
      ));
    }
  }
  return found;
}

/// Where Pub resolves the package at [directory]: its nearest ancestor
/// declaring `workspace:` when the package has `resolution: workspace`,
/// otherwise the package itself.
String resolutionRoot(String sourceRoot, String directory) {
  final member = _manifest('$directory/pubspec.yaml');
  if (member?.string('resolution') != 'workspace') return directory;
  var dir = directory;
  while (dir != sourceRoot && dir.length > sourceRoot.length) {
    final cut = dir.lastIndexOf('/');
    if (cut < 0) break;
    dir = dir.substring(0, cut);
    if (_manifest('$dir/pubspec.yaml')?.has('workspace') == true) return dir;
  }
  return directory;
}

/// The packages [package] brings to its consumers, from `pub deps --json`:
/// its own dependencies without its dev dependencies, and everything those
/// depend on. Null when the output does not describe [package] that way.
Set<String>? runtimeDependencies(String pubDepsJson, String package) {
  final Object? decoded;
  try {
    decoded = jsonDecode(pubDepsJson);
  } on FormatException {
    return null;
  }
  if (decoded is! Map || decoded['packages'] is! List) return null;
  final packages = <String, Map<Object?, Object?>>{
    for (final entry in (decoded['packages'] as List).whereType<Map>())
      if (entry['name'] case final String name) name: entry,
  };
  if (!packages.containsKey(package)) return null;
  final reached = <String>{};
  final pending = [package];
  while (pending.isNotEmpty) {
    final entry = packages[pending.removeLast()];
    if (entry == null) continue;
    // A root package (the one staged, or a workspace member it depends on)
    // keeps its dev dependencies to itself; any other package lists only
    // what its consumers receive.
    final edges = entry['kind'] == 'root'
        ? entry['directDependencies']
        : entry['dependencies'];
    if (edges is! List) return null;
    for (final name in edges.whereType<String>()) {
      if (reached.add(name)) pending.add(name);
    }
  }
  return reached;
}

/// The overrides among [overrides] that change what [package]'s consumers
/// resolve: those of [package], of anything in [reached], or of every
/// package. With [reached] unknown, every override counts.
List<DependencyOverride> maskingOverrides(
  List<DependencyOverride> overrides,
  String package,
  Set<String>? reached,
) => [
  for (final override in overrides)
    if (reached == null ||
        override.package == everyPackage ||
        override.package == package ||
        reached.contains(override.package))
      override,
];

/// Whether resolving the package at [directory] needs the Flutter SDK: it,
/// or any package in the workspace it resolves with, depends on a Flutter
/// SDK package or constrains the Flutter version.
bool needsFlutter(String sourceRoot, String directory) {
  final root = resolutionRoot(sourceRoot, directory);
  final manifests = {'$directory/pubspec.yaml', '$root/pubspec.yaml'};
  final members = _manifest('$root/pubspec.yaml')?.list('workspace')?.strings;
  for (final member in members ?? const <String>[]) {
    manifests.add('$root/$member/pubspec.yaml');
  }
  for (final path in manifests) {
    final manifest = _manifest(path);
    if (manifest == null) continue;
    if (manifest.map('environment')?.has('flutter') == true) return true;
    for (final section in const ['dependencies', 'dev_dependencies']) {
      final dependencies = manifest.map(section);
      for (final name in dependencies?.keys ?? const <String>[]) {
        if (dependencies!.map(name)?.string('sdk') == 'flutter') return true;
      }
    }
  }
  return false;
}

/// Whether [executable] is a Flutter SDK's Dart: the `bin/dart` beside
/// `bin/flutter`, or the Dart SDK Flutter keeps in `bin/cache/dart-sdk`.
/// Pub finds Flutter from where that Dart lives; a standalone Dart SDK's pub
/// cannot resolve Flutter packages. Symbolic links are followed first, so a
/// standalone `dart` that merely shares a directory with a `flutter` link
/// does not count.
bool dartInFlutterSdk(String executable) {
  final String resolved;
  try {
    resolved = File(executable).resolveSymbolicLinksSync();
  } on FileSystemException {
    return false;
  }
  bool isFlutterBin(Directory bin) =>
      (File('${bin.path}/flutter').existsSync() ||
          File('${bin.path}/flutter.bat').existsSync()) &&
      Directory('${bin.path}/cache/dart-sdk').existsSync();
  String name(Directory directory) =>
      directory.path.split(Platform.pathSeparator).last;

  final bin = File(resolved).parent;
  if (isFlutterBin(bin)) return true;
  final sdk = bin.parent;
  final cache = sdk.parent;
  return name(bin) == 'bin' &&
      name(sdk) == 'dart-sdk' &&
      name(cache) == 'cache' &&
      isFlutterBin(cache.parent);
}

YamlMap? _manifest(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  return parseYaml(file.readAsStringSync(), path, Diagnostics());
}
