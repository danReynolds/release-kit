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
/// them are read. [unreadable] says what kept rk from knowing the set;
/// [packages] is then null.
typedef ResolutionPackages = ({
  Map<String, String>? packages,
  String? unreadable,
});

ResolutionPackages resolutionPackages(String sourceRoot, String directory) {
  String describe(String path) => _relative(sourceRoot, path);
  final root = _topRoot(sourceRoot, directory);
  if (root.directory == null) {
    return (packages: null, unreadable: root.unreadable!(describe));
  }
  final packages = <String, String>{};
  String? visit(String dir) {
    final manifest = _read('$dir/pubspec.yaml');
    final file = describe('$dir/pubspec.yaml');
    if (manifest.map == null) return '$file is not YAML rk reads';
    final name = manifest.map!.string('name');
    if (name == null) return '$file names no package';
    if (packages.containsKey(name)) {
      return 'two packages of the workspace are named $name';
    }
    packages[name] = dir;
    if (!manifest.map!.has('workspace')) return null;
    final members = manifest.map!.list('workspace');
    if (members == null || members.strings.length != members.items.length) {
      return '$file has a workspace that is not a list of paths';
    }
    for (final pattern in members.strings) {
      final matched = _expand(dir, pattern);
      if (matched == null) {
        return '$file lists workspace member "$pattern", a pattern rk does '
            'not read';
      }
      if (matched.isEmpty) {
        return '$file lists workspace member "$pattern", which matches no '
            'package';
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
  if (!packages.values.contains(directory)) {
    return (
      packages: null,
      unreadable:
          '${describe('$directory/pubspec.yaml')} is not one of the packages '
          'its workspace lists',
    );
  }
  return (packages: packages, unreadable: null);
}

/// Every override declared by [packages] (name to directory), as rk reads
/// them: each one's `pubspec_overrides.yaml`, or its pubspec's
/// `dependency_overrides` section when that file declares none. The stage
/// names declarations with this; Pub's lockfile decides what is overridden.
List<DependencyOverride> dependencyOverrides(
  String sourceRoot,
  Map<String, String> packages,
) {
  final found = <DependencyOverride>[];
  void declare(YamlNode? section, String where) {
    // An empty or null section declares nothing.
    if (section == null ||
        (section is YamlScalar &&
            !section.quoted &&
            const {'', '~', 'null', 'Null', 'NULL'}.contains(section.value))) {
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

  for (final dir in packages.values) {
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

/// The packages `dart pub get` reports it overrode, from its [output]: a
/// `!` line for each, such as `! leaf 9.9.9 from path ../fork (overridden)`.
/// Pub prints these only in a full report, which `PUB_SUMMARY_ONLY` turns
/// off, so the stage runs it with that set to `0`.
Set<String> reportedOverrides(String output) => {
  for (final match in RegExp(
    r'^! (\S+) .*\(overridden',
    multiLine: true,
  ).allMatches(output))
    match.group(1)!,
};

/// The overrides Pub read from every package of the workspace, from
/// `dart pub deps --style=compact`: each package's `dependency overrides:`
/// section, as Pub parsed its pubspec and overrides file. Unlike
/// [reportedOverrides], the report does not depend on `PUB_SUMMARY_ONLY`.
Set<String> declaredOverrides(String compact) {
  final names = <String>{};
  var inOverrides = false;
  for (final line in compact.split('\n')) {
    if (line.trim() == 'dependency overrides:') {
      inOverrides = true;
      continue;
    }
    if (!inOverrides) continue;
    final entry = RegExp(r'^- (\S+)').firstMatch(line);
    if (entry == null) {
      inOverrides = false;
      continue;
    }
    names.add(entry.group(1)!);
  }
  return names;
}

/// Whether the resolved graph in [pubDepsJson] takes a package from an SDK,
/// which only Flutter provides. Null when the output is not a graph.
bool? usesFlutter(String pubDepsJson) {
  final packages = _packages(pubDepsJson);
  if (packages == null) return null;
  return packages.values.any((entry) => entry['source'] == 'sdk');
}

/// Where Pub resolved the package at [directory], as Pub records it after
/// resolving: the root its `.dart_tool/pub/workspace_ref.json` points to, or
/// the package itself when Pub wrote its package configuration there. Null
/// when Pub left neither.
String? resolvedRoot(String directory) {
  final reference = File('$directory/.dart_tool/pub/workspace_ref.json');
  if (reference.existsSync()) {
    final Object? decoded;
    try {
      decoded = jsonDecode(reference.readAsStringSync());
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
    final relative = decoded is Map ? decoded['workspaceRoot'] : null;
    if (relative is! String) return null;
    final root = Uri.directory(
      '$directory/.dart_tool/pub/',
    ).resolve(relative.endsWith('/') ? relative : '$relative/');
    final path = root.toFilePath();
    return path.length > 1 && path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
  }
  return File('$directory/.dart_tool/package_config.json').existsSync()
      ? directory
      : null;
}

/// The packages the lockfile Pub wrote at [root] marks overridden. Pub
/// records an overridden direct dependency of the root as direct, so this
/// complements [reportedOverrides] rather than replacing it. Null when there
/// is no lockfile rk can read.
Set<String>? overriddenPackages(String root) {
  final lock = _read('$root/pubspec.lock');
  if (lock.map == null) return null;
  final packages = lock.map!['packages'];
  if (packages is YamlScalar && packages.value.isEmpty) return {};
  if (packages is! YamlMap) return null;
  final overridden = <String>{};
  for (final name in packages.keys) {
    final dependency = packages.map(name)?.string('dependency');
    if (dependency == null) return null;
    if (dependency.contains('overridden')) overridden.add(name);
  }
  return overridden;
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

/// The packages in [reached] that Pub resolved from a path or Git source,
/// with that source. Consumers of a published package receive only hosted
/// and SDK packages, so each one is overridden, or a dependency Pub refuses
/// to publish, whatever declared it. Workspace packages are left out:
/// consumers receive their published versions, which rk's prerequisites
/// require. Null when the output does not say where a package came from.
Map<String, String>? unhostedDependencies(
  String pubDepsJson,
  Set<String> reached,
) {
  final packages = _packages(pubDepsJson);
  if (packages == null) return null;
  final unhosted = <String, String>{};
  for (final name in reached) {
    final entry = packages[name];
    final source = entry?['source'];
    if (entry == null || source is! String) return null;
    if (entry['kind'] == 'root' || source == 'hosted' || source == 'sdk') {
      continue;
    }
    unhosted[name] = source;
  }
  return unhosted;
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

/// The dependency graph `dart pub get` recorded where it resolved at
/// [root], in the shape rk reads from `dart pub deps --json`: the edges
/// from `.dart_tool/package_graph.json`, and each package's source from the
/// lockfile. `pub deps --json` fails when a workspace member's pubspec
/// overrides a package that the member's overrides file leaves out: that
/// command follows the pubspec, and Pub never resolved the package. Pub
/// writes the graph file from Dart 3.8. Null when either record is missing,
/// or they do not describe the same packages.
String? recordedGraph(String root) {
  final Object? decoded;
  try {
    decoded = jsonDecode(
      File('$root/.dart_tool/package_graph.json').readAsStringSync(),
    );
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
  if (decoded is! Map || decoded['packages'] is! List) return null;
  final roots = _strings(decoded['roots']);
  if (roots == null) return null;
  final locked = _read('$root/pubspec.lock').map?['packages'];
  final packages = <Map<String, Object?>>[];
  for (final entry in decoded['packages'] as List) {
    if (entry is! Map || entry['name'] is! String) return null;
    final name = entry['name'] as String;
    final dependencies = _strings(entry['dependencies']);
    if (dependencies == null) return null;
    if (roots.contains(name)) {
      final dev = _strings(entry['devDependencies']);
      if (dev == null) return null;
      packages.add({
        'name': name,
        'kind': 'root',
        'source': 'root',
        'dependencies': [...dependencies, ...dev],
        'directDependencies': dependencies,
        'devDependencies': dev,
      });
      continue;
    }
    final source = locked is YamlMap
        ? locked.map(name)?.string('source')
        : null;
    if (source == null) return null;
    packages.add({
      'name': name,
      'kind': 'transitive',
      'source': source,
      'dependencies': dependencies,
      'directDependencies': dependencies,
    });
  }
  return jsonEncode({'packages': packages});
}

/// The workspace packages in [pubDepsJson], by name.
Set<String>? workspacePackages(String pubDepsJson) => _packages(
  pubDepsJson,
)?.entries.where((e) => e.value['kind'] == 'root').map((e) => e.key).toSet();

/// The workspace packages that resolving [package] the way its consumers do
/// takes from the snapshot rather than from pub.dev, from [pubDepsJson]:
/// those it reaches through its dependencies that are released with it
/// ([releasedWith], its unit's packages, staged before any of them is
/// published), and those it reaches only through its dev dependencies,
/// which its consumers never resolve. Any other workspace package it
/// reaches, its consumers take from pub.dev, and so does the resolution.
/// Null when the output does not describe the graph completely.
Set<String>? snapshotPackages(
  String pubDepsJson,
  String package,
  Set<String> releasedWith,
) {
  final packages = _packages(pubDepsJson);
  final start = packages?[package];
  if (packages == null || start == null) return null;
  final runtime = runtimeDependencies(pubDepsJson, package);
  final dev = _strings(start['devDependencies']);
  if (runtime == null || dev == null) return null;
  // Everything the dev dependencies bring, as a workspace package brings
  // its own dependencies but not its dev dependencies.
  final developed = <String>{};
  final pending = [...dev];
  while (pending.isNotEmpty) {
    final name = pending.removeLast();
    if (!developed.add(name)) continue;
    final entry = packages[name];
    if (entry == null) return null;
    final edges = _strings(
      entry['kind'] == 'root'
          ? entry['directDependencies']
          : entry['dependencies'],
    );
    if (edges == null) return null;
    pending.addAll(edges);
  }
  bool workspace(String name) => packages[name]?['kind'] == 'root';
  return {
    for (final name in runtime)
      if (workspace(name) && releasedWith.contains(name)) name,
    for (final name in developed)
      if (workspace(name) && !runtime.contains(name)) name,
  }..remove(package);
}

/// Each package's directory, by name, from the package configuration Pub
/// wrote at [root]. Null when there is none rk reads.
Map<String, String>? packageDirectories(String root) {
  final Object? decoded;
  try {
    decoded = jsonDecode(
      File('$root/.dart_tool/package_config.json').readAsStringSync(),
    );
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
  if (decoded is! Map || decoded['packages'] is! List) return null;
  final base = Uri.directory('$root/.dart_tool/');
  final directories = <String, String>{};
  for (final entry in decoded['packages'] as List) {
    if (entry is! Map) return null;
    final name = entry['name'];
    final rootUri = entry['rootUri'];
    if (name is! String || rootUri is! String) return null;
    final path = base.resolve(rootUri).toFilePath();
    directories[name] = path.length > 1 && path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
  }
  return directories;
}

/// The `pubspec_overrides.yaml` the stage writes over a package's own, so
/// that Pub resolves the package the way its consumers do. Within a
/// workspace ([inWorkspace]) the package becomes a root of its own, with no
/// workspace of its own either. Pub then applies no dependency override but
/// [fromSnapshot]: the workspace packages the package reaches, by name, each
/// with its path relative to the package.
String consumerOverrides(
  Map<String, String> fromSnapshot, {
  required bool inWorkspace,
}) {
  final names = fromSnapshot.keys.toList()..sort();
  return [
    '# Written by rk: resolve this package the way its consumers do.',
    if (inWorkspace) ...['resolution: null', 'workspace: []'],
    if (names.isEmpty)
      'dependency_overrides: {}'
    else ...[
      'dependency_overrides:',
      for (final name in names) ...[
        '  $name:',
        '    path: ${jsonEncode(fromSnapshot[name])}',
      ],
    ],
    '',
  ].join('\n');
}

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
/// top-most root. When there is none, [unreadable] says why, given a way to
/// describe paths.
({String? directory, String Function(String Function(String))? unreadable})
_topRoot(String sourceRoot, String directory) {
  String Function(String Function(String)) unreadable(String file) =>
      (describe) => '${describe(file)} is not YAML rk reads';
  var root = directory;
  while (true) {
    final manifest = _read('$root/pubspec.yaml');
    if (manifest.map == null) {
      return (directory: null, unreadable: unreadable('$root/pubspec.yaml'));
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
        return (directory: null, unreadable: unreadable('$dir/pubspec.yaml'));
      }
      if (ancestor.map!.has('workspace')) {
        parent = dir;
        break;
      }
    }
    // A member with no workspace above it does not resolve at all.
    if (parent == null) {
      final file = '$root/pubspec.yaml';
      return (
        directory: null,
        unreadable: (describe) =>
            '${describe(file)} declares resolution: workspace, and no '
            'workspace above it lists it',
      );
    }
    root = parent;
  }
}

/// The package directories [pattern] names under [base], as Pub matches a
/// workspace entry: a path, or a glob whose matches count only where they
/// hold a `pubspec.yaml`. Globs take `*`, `?`, `**`, `[...]` classes and
/// `{a,b}` alternatives, matched case-sensitively as Pub matches them. Empty when nothing matches; null for a pattern that leaves
/// [base], or for glob syntax rk does not read.
List<String>? _expand(String base, String pattern) {
  if (pattern.startsWith('/') || pattern.contains(r'\')) return null;
  // `./` and `..` are resolved; a pattern may not climb out of its base.
  final segments = <String>[];
  for (final segment in pattern.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isEmpty || segments.last == '**') return null;
      segments.removeLast();
      continue;
    }
    segments.add(segment);
  }
  if (segments.isEmpty) return null;
  final glob = RegExp(r'[*?\[\]{}]');
  if (!segments.any(glob.hasMatch)) {
    final path = '$base/${segments.join('/')}';
    return File('$path/pubspec.yaml').existsSync() ? [path] : const [];
  }

  // Pub matches glob segments case-sensitively everywhere.
  const caseSensitive = true;
  final matchers = <RegExp?>[];
  for (final segment in segments) {
    if (segment == '**') {
      matchers.add(null);
      continue;
    }
    final matcher = _segment(segment, caseSensitive);
    if (matcher == null) return null;
    matchers.add(matcher);
  }

  final matches = <String>{};
  void walk(String dir, int index) {
    if (index == segments.length) {
      // `**` never matches the directory the pattern starts from.
      if (dir != base && File('$dir/pubspec.yaml').existsSync()) {
        matches.add(dir);
      }
      return;
    }
    final matcher = matchers[index];
    if (matcher == null) {
      walk(dir, index + 1);
      for (final child in _children(dir)) {
        walk(child, index);
      }
      return;
    }
    for (final child in _children(dir)) {
      if (matcher.hasMatch(child.split('/').last)) walk(child, index + 1);
    }
  }

  walk(base, 0);
  return matches.toList()..sort();
}

/// One path segment of a glob as a regular expression, or null for syntax
/// rk does not read: a nested or unclosed `{`, an unclosed `[`, or `**`
/// inside a segment.
RegExp? _segment(String glob, bool caseSensitive) {
  if (glob.contains('**')) return null;
  final pattern = StringBuffer('^');
  var inBraces = false;
  for (var i = 0; i < glob.length; i++) {
    final c = glob[i];
    switch (c) {
      case '*':
        pattern.write('[^/]*');
      case '?':
        pattern.write('[^/]');
      case '{':
        if (inBraces) return null;
        inBraces = true;
        pattern.write('(?:');
      case '}':
        if (!inBraces) return null;
        inBraces = false;
        pattern.write(')');
      case ',' when inBraces:
        pattern.write('|');
      case '[':
        final close = glob.indexOf(']', i + 2);
        if (close < 0) return null;
        var body = glob.substring(i + 1, close);
        final negated = body.startsWith('!') || body.startsWith('^');
        if (negated) body = body.substring(1);
        if (body.isEmpty) return null;
        final escaped = body.replaceAllMapped(
          RegExp(r'[\\\]\[^]'),
          (m) => '\\${m[0]}',
        );
        pattern.write(negated ? '[^/$escaped]' : '[$escaped]');
        i = close;
      case ']':
        return null;
      default:
        pattern.write(RegExp.escape(c));
    }
  }
  if (inBraces) return null;
  pattern.write(r'$');
  return RegExp(pattern.toString(), caseSensitive: caseSensitive);
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
/// read them. A file that exists but is not UTF-8 or does not parse has a
/// null [map].
({bool exists, YamlMap? map}) _read(String path) {
  final file = File(path);
  if (!file.existsSync()) return (exists: false, map: null);
  final String source;
  try {
    source = file.readAsStringSync();
  } on FileSystemException {
    return (exists: true, map: null);
  } on FormatException {
    return (exists: true, map: null);
  }
  return (exists: true, map: parseYaml(source, path, Diagnostics()));
}
