import 'dart:convert';
import 'dart:io';

import '../../engine/diagnostic.dart';
import '../../engine/yaml.dart';

/// The packages of the workspace the package at [directory] belongs to, by
/// name with their directories: every package of the workspace whose
/// top-most root it resolves at, or the package alone. [unreadable] says
/// what kept rk from knowing the set; [packages] is then null.
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

/// The `pubspec_overrides.yaml` the stage writes over a package's own, so
/// that Pub resolves the package the way its consumers do. Within a
/// workspace ([inWorkspace]) the package becomes a root of its own, with no
/// workspace of its own either. Pub then applies no dependency override but
/// [fromSnapshot]: the repository packages the stage takes from its source,
/// by name, each with its path relative to the package.
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

/// The packages of [members] (a workspace's, by name with their
/// directories) that [package] reaches only through its development
/// dependencies, read from their pubspecs. Its consumers never resolve
/// them, so the stage takes them from this source. A member reaches what
/// its dependencies name: its own development dependencies count only where
/// it is the root.
Set<String> developmentMembers(Map<String, String> members, String package) {
  Iterable<String> named(String name, String section) =>
      _read('${members[name]}/pubspec.yaml').map?.map(section)?.keys ??
      const [];
  Set<String> reach(Iterable<String> from) {
    final reached = <String>{};
    final pending = [...from];
    while (pending.isNotEmpty) {
      final name = pending.removeLast();
      if (members.containsKey(name) && reached.add(name)) {
        pending.addAll(named(name, 'dependencies'));
      }
    }
    return reached;
  }

  if (!members.containsKey(package)) return const {};
  return reach(
    named(package, 'dev_dependencies'),
  ).difference(reach(named(package, 'dependencies')))..remove(package);
}

/// Whether the package at [directory] resolves with a workspace, as its
/// root or as one of its members.
bool inWorkspace(String directory) {
  final manifest = _read('$directory/pubspec.yaml').map;
  return manifest != null &&
      (manifest.has('workspace') || manifest.has('resolution'));
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
