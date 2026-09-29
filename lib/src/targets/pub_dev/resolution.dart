import 'dart:convert';
import 'dart:io';

import '../../engine/diagnostic.dart';
import '../../engine/yaml.dart';

/// A dependency override that Pub honours where it resolves the staged
/// package and strips from the published archive: the package it replaces
/// ([everyPackage] when the declaration cannot be read) and where it is
/// declared, relative to the source root.
typedef DependencyOverride = ({String package, String declaredIn});

/// Stands for every package when a declaration cannot be read.
const everyPackage = '*';

/// The packages Pub resolves together with the one at [directory], by name:
/// every package of the workspace whose top-most root it resolves at, or the
/// package alone.
///
/// Pub applies any of these packages' overrides to all of them, so all of
/// them are read. [unreadable] names the manifest or member pattern that
/// kept rk from knowing the set; [packages] is then null.
typedef ResolutionPackages = ({
  Map<String, String>? packages,
  String? unreadable,
});

ResolutionPackages resolutionPackages(String sourceRoot, String directory) {
  String describe(String path) => _relative(sourceRoot, path);
  final root = _topRoot(sourceRoot, directory);
  if (root.unreadable != null) {
    return (packages: null, unreadable: describe(root.unreadable!));
  }
  final packages = <String, String>{};
  String? visit(String dir) {
    final manifest = _read('$dir/pubspec.yaml');
    if (manifest.map == null) return describe('$dir/pubspec.yaml');
    final name = manifest.map!.string('name');
    if (name == null || packages.containsKey(name)) {
      return describe('$dir/pubspec.yaml');
    }
    packages[name] = dir;
    if (!manifest.map!.has('workspace')) return null;
    final members = manifest.map!.list('workspace');
    if (members == null || members.strings.length != members.items.length) {
      return '${describe('$dir/pubspec.yaml')} (its workspace list)';
    }
    for (final pattern in members.strings) {
      final matched = _expand(dir, pattern);
      if (matched == null) {
        return '${describe('$dir/pubspec.yaml')} (workspace member "$pattern")';
      }
      for (final member in matched) {
        final problem = visit(member);
        if (problem != null) return problem;
      }
    }
    return null;
  }

  final problem = visit(root.directory!);
  if (problem != null) return (packages: null, unreadable: problem);
  return (packages: packages, unreadable: null);
}

/// Every override declared by [packages] (their directories): each one's
/// `pubspec_overrides.yaml`, or its pubspec's `dependency_overrides` section
/// when that file declares none, since Pub lets the file replace the section.
List<DependencyOverride> dependencyOverrides(
  String sourceRoot,
  Iterable<String> packages,
) {
  final found = <DependencyOverride>[];
  void declare(YamlNode? section, String where) {
    if (section == null || (section is YamlScalar && section.value.isEmpty)) {
      return;
    }
    if (section is! YamlMap) {
      found.add((package: everyPackage, declaredIn: where));
      return;
    }
    for (final name in section.keys) {
      // A key Pub would not read as a package name is one rk has misread.
      found.add((
        package: _packageName.hasMatch(name) ? name : everyPackage,
        declaredIn: where,
      ));
    }
  }

  for (final dir in packages) {
    final file = '$dir/pubspec_overrides.yaml';
    final overrides = _read(file);
    if (overrides.exists) {
      if (overrides.map == null) {
        found.add((
          package: everyPackage,
          declaredIn: _relative(sourceRoot, file),
        ));
        continue;
      }
      if (overrides.map!.has('dependency_overrides')) {
        declare(
          overrides.map!['dependency_overrides'],
          _relative(sourceRoot, file),
        );
        continue;
      }
    }
    final pubspec = '$dir/pubspec.yaml';
    final where =
        'the dependency_overrides section in ${_relative(sourceRoot, pubspec)}';
    final manifest = _read(pubspec).map;
    if (manifest == null) {
      found.add((package: everyPackage, declaredIn: where));
      continue;
    }
    declare(manifest['dependency_overrides'], where);
  }
  return found;
}

/// The packages [package] brings to its consumers, from `pub deps --json`:
/// its own dependencies without its dev dependencies, and everything those
/// depend on. Null when the output does not describe the graph completely.
Set<String>? runtimeDependencies(String pubDepsJson, String package) {
  final packages = _packages(pubDepsJson);
  if (packages == null || !packages.containsKey(package)) return null;
  final reached = <String>{};
  final pending = [package];
  while (pending.isNotEmpty) {
    final entry = packages[pending.removeLast()];
    if (entry == null) return null;
    // A root package (the one staged, or a workspace member it depends on)
    // keeps its dev dependencies and overrides to itself; any other package
    // lists only what its consumers receive.
    final edges = _strings(
      entry['kind'] == 'root'
          ? entry['directDependencies']
          : entry['dependencies'],
    );
    if (edges == null) return null;
    for (final name in edges) {
      if (reached.add(name)) pending.add(name);
    }
  }
  return reached;
}

/// The workspace packages Pub resolved (`kind: root`), each with the
/// overrides it reports applying: what it depends on beyond its direct and
/// dev dependencies. Null when the output does not have that shape.
///
/// Pub reports overrides declared in pubspecs and in the root's
/// `pubspec_overrides.yaml`, not those in a member's overrides file, so this
/// checks rk's own reading rather than replacing it.
Map<String, Set<String>>? appliedOverrides(String pubDepsJson) {
  final packages = _packages(pubDepsJson);
  if (packages == null) return null;
  final applied = <String, Set<String>>{};
  for (final MapEntry(key: name, value: entry) in packages.entries) {
    if (entry['kind'] != 'root') continue;
    final all = _strings(entry['dependencies']);
    final direct = _strings(entry['directDependencies']);
    final dev = _strings(entry['devDependencies']);
    if (all == null || direct == null || dev == null) return null;
    applied[name] = all.toSet().difference({...direct, ...dev});
  }
  return applied;
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

/// Whether resolving [packages] (directories) needs the Flutter SDK: one of
/// them depends on a Flutter SDK package or constrains the Flutter version.
bool needsFlutter(Iterable<String> packages) {
  for (final dir in packages) {
    final manifest = _read('$dir/pubspec.yaml').map;
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
/// Pub in that SDK finds its own Flutter. Symbolic links are followed first,
/// so a standalone `dart` that merely shares a directory with a `flutter`
/// link does not count.
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

final _packageName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// Where Pub resolves the package at [directory]: while a package declares
/// `resolution: workspace`, the nearest ancestor declaring `workspace:`,
/// and that one's root in turn when it is itself a member, up to the
/// top-most root. [unreadable] names a manifest that could not be read.
({String? directory, String? unreadable}) _topRoot(
  String sourceRoot,
  String directory,
) {
  var root = directory;
  while (true) {
    final manifest = _read('$root/pubspec.yaml');
    if (manifest.map == null) {
      return (directory: null, unreadable: '$root/pubspec.yaml');
    }
    if (manifest.map!.string('resolution') != 'workspace') {
      return (directory: root, unreadable: null);
    }
    String? parent;
    var dir = root;
    while (dir.length > sourceRoot.length) {
      final cut = dir.lastIndexOf('/');
      if (cut < 0) break;
      dir = dir.substring(0, cut);
      final ancestor = _read('$dir/pubspec.yaml');
      if (!ancestor.exists) continue;
      if (ancestor.map == null) {
        return (directory: null, unreadable: '$dir/pubspec.yaml');
      }
      if (ancestor.map!.has('workspace')) {
        parent = dir;
        break;
      }
    }
    // A member with no workspace above it does not resolve at all.
    if (parent == null) {
      return (directory: null, unreadable: '$root/pubspec.yaml');
    }
    root = parent;
  }
}

/// The package directories [pattern] names under [base], as Pub matches a
/// workspace entry: a path, or a glob of `*`, `?` and `**` segments whose
/// matches count only where they hold a `pubspec.yaml`. Null for a literal
/// path without one, or for glob syntax rk does not expand.
List<String>? _expand(String base, String pattern) {
  var path = pattern;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path.isEmpty || path.startsWith('/') || path.contains('\\')) return null;
  if (!path.contains(RegExp(r'[*?\[\]{}]'))) {
    return File('$base/$path/pubspec.yaml').existsSync()
        ? ['$base/$path']
        : null;
  }
  if (path.contains(RegExp(r'[\[\]{}]'))) return null;
  final segments = path.split('/');
  if (segments.any((s) => s.isEmpty || s == '.' || s == '..')) return null;

  RegExp segment(String glob) => RegExp(
    '^${glob.split('').map((c) => switch (c) {
      '*' => '[^/]*',
      '?' => '[^/]',
      _ => RegExp.escape(c),
    }).join()}\$',
  );

  final matches = <String>{};
  void walk(String dir, int index) {
    if (index == segments.length) {
      if (File('$dir/pubspec.yaml').existsSync()) matches.add(dir);
      return;
    }
    final glob = segments[index];
    if (glob == '**') {
      walk(dir, index + 1);
      for (final child in _children(dir)) {
        walk(child, index);
      }
      return;
    }
    final match = segment(glob);
    for (final child in _children(dir)) {
      if (match.hasMatch(child.split('/').last)) walk(child, index + 1);
    }
  }

  walk(base, 0);
  return matches.toList()..sort();
}

List<String> _children(String dir) {
  try {
    return [
      for (final entry in Directory(dir).listSync(followLinks: false))
        if (entry is Directory) entry.path,
    ]..sort();
  } on FileSystemException {
    return const [];
  }
}

Map<String, Map<Object?, Object?>>? _packages(String pubDepsJson) {
  final Object? decoded;
  try {
    decoded = jsonDecode(pubDepsJson);
  } on FormatException {
    return null;
  }
  if (decoded is! Map || decoded['packages'] is! List) return null;
  final packages = <String, Map<Object?, Object?>>{};
  for (final entry in decoded['packages'] as List) {
    if (entry is! Map || entry['name'] is! String) return null;
    if (packages.containsKey(entry['name'])) return null;
    packages[entry['name'] as String] = entry;
  }
  return packages;
}

List<String>? _strings(Object? value) {
  if (value is! List) return null;
  final strings = <String>[];
  for (final item in value) {
    if (item is! String) return null;
    strings.add(item);
  }
  return strings;
}

String _relative(String sourceRoot, String path) {
  final prefix = '$sourceRoot/';
  return path.startsWith(prefix) ? path.substring(prefix.length) : path;
}

/// A manifest at [path]: whether it exists, and its contents when rk can
/// read them. A file that exists but does not parse has a null [map].
({bool exists, YamlMap? map}) _read(String path) {
  final file = File(path);
  if (!file.existsSync()) return (exists: false, map: null);
  return (
    exists: true,
    map: parseYaml(file.readAsStringSync(), path, Diagnostics()),
  );
}
