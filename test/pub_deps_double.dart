import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/tools.dart';
import 'package:yaml/yaml.dart' as yaml;

/// What Pub reports and records when the pub.dev stage resolves its mirror of
/// the source snapshot. Each report can be set on its own, so a test can
/// prove the stage reads it.
final class PubResolution {
  const PubResolution({
    this.reported = const {},
    this.declared = const {},
    this.lock = const {},
    this.graph,
    this.depsJsonFails = false,
    this.recordsGraph = true,
    this.consumerFailure,
    this.consumerAlsoReports = const {},
  });

  /// An override Pub shows everywhere it would: `pub get` reports it, the
  /// compact report lists it under [declaringPackage], and the lockfile marks
  /// it with [type]. For an override of the root's own dependency, Pub
  /// writes `direct main` or `direct dev` there instead.
  factory PubResolution.overriding(
    Set<String> packages, {
    String declaringPackage = 'keybay',
    String type = 'direct overridden',
  }) => PubResolution(
    reported: packages,
    declared: {declaringPackage: packages},
    lock: {for (final name in packages) name: type},
  );

  /// Overrides `pub get` reports with a `!` line. Pub prints them only in a
  /// full report, which the environment variable `PUB_SUMMARY_ONLY` turns
  /// off; the double assumes the caller's environment sets it, as Flutter's
  /// tooling does, unless the call itself sets it to `0`.
  final Set<String> reported;

  /// Each package's `dependency overrides:` in `pub deps --style=compact`.
  final Map<String, Set<String>> declared;

  /// Lockfile entries: package to the dependency type Pub writes.
  final Map<String, String> lock;

  /// What `pub deps --json` prints; by default the package alone. `pub get`
  /// records the same graph in `.dart_tool/package_graph.json`, with each
  /// package's source in the lockfile.
  final String? graph;

  /// Whether `pub deps --json` fails after `pub get` succeeded, as Dart
  /// 3.12's does when a member's pubspec overrides a package the member's
  /// overrides file leaves out.
  final bool depsJsonFails;

  /// Whether `pub get` writes `.dart_tool/package_graph.json`, as Pub does
  /// from Dart 3.8.
  final bool recordsGraph;

  /// Why `pub get` fails where the stage resolves the package the way its
  /// consumers do; null when it succeeds.
  final String? consumerFailure;

  /// Overrides `pub get` reports there besides the ones the stage wrote.
  final Set<String> consumerAlsoReports;
}

/// `dart pub get --no-example` in [workingDirectory]: writes Pub's records
/// and prints its report. Pub resolves at the first package, walking up,
/// whose pubspec (with its overrides file) is not a workspace member, and
/// writes the lockfile, package configuration and package graph there.
/// Inside a workspace, the package also gets a pointer to that root, which
/// Pub writes only for workspaces.
///
/// A package whose overrides file the stage wrote is a root of its own, as
/// its consumers resolve it: Pub then applies that file's overrides and no
/// others.
ToolResult pubGetIn(
  String workingDirectory, {
  PubResolution resolution = const PubResolution(),
  Map<String, String>? environment,
}) {
  final consumer = _consumerOverrides(workingDirectory);
  if (consumer != null && resolution.consumerFailure != null) {
    return ToolResult(
      exitCode: 1,
      stdout: 'Resolving dependencies...\n',
      stderr: '${resolution.consumerFailure}\n',
    );
  }
  final root = consumer == null
      ? _resolutionRoot(workingDirectory)
      : workingDirectory;
  final graph = consumer == null
      ? jsonDecode(resolution.graph ?? _packageAlone(workingDirectory))
            as Map<String, Object?>
      : jsonDecode(_packageAlone(workingDirectory)) as Map<String, Object?>;
  final packages = [
    for (final entry in graph['packages'] as List)
      entry as Map<String, Object?>,
  ];
  final dartTool = Directory('$root/.dart_tool')..createSync(recursive: true);
  final located = consumer == null
      ? _workspacePackages(root)
      : {
          _name(workingDirectory)!: workingDirectory,
          for (final MapEntry(key: name, value: path) in consumer.entries)
            name: '$workingDirectory/$path',
        };
  final config = {
    'configVersion': 2,
    'packages': [
      for (final MapEntry(key: name, value: dir) in located.entries)
        {
          'name': name,
          'rootUri': _relative('${dartTool.path}/', dir),
          'packageUri': 'lib/',
        },
    ],
  };
  File(
    '${dartTool.path}/package_config.json',
  ).writeAsStringSync('${jsonEncode(config)}\n');
  if (resolution.recordsGraph) {
    final recorded = {
      'roots': [
        for (final package in packages)
          if (package['kind'] == 'root') package['name'],
      ],
      'packages': [
        for (final package in packages)
          {
            'name': package['name'],
            'version': '1.0.0',
            if (package['kind'] == 'root') ...{
              'dependencies': package['directDependencies'],
              'devDependencies': package['devDependencies'] ?? const [],
            } else
              'dependencies': package['dependencies'],
          },
      ],
      'configVersion': 1,
    };
    File(
      '${dartTool.path}/package_graph.json',
    ).writeAsStringSync('${jsonEncode(recorded)}\n');
  }
  // Every package the graph resolved besides the roots, with its source;
  // and the typed entries a test sets, which are path overrides otherwise.
  final types = consumer == null
      ? resolution.lock
      : {for (final name in consumer.keys) name: 'direct overridden'};
  final resolved = {
    for (final package in packages)
      if (package['kind'] != 'root') package['name'] as String: package,
  };
  File('$root/pubspec.lock').writeAsStringSync(
    _lockfile({
      for (final MapEntry(key: name, value: package) in resolved.entries)
        name: (
          type: types[name] ?? 'transitive',
          source: package['source'] as String,
        ),
      for (final MapEntry(key: name, value: type) in types.entries)
        if (!resolved.containsKey(name)) name: (type: type, source: 'path'),
    }),
  );
  if (consumer == null && _isWorkspace(root)) {
    for (final dir in {root, workingDirectory}) {
      final depth = dir.length > root.length
          ? dir.substring(root.length + 1).split('/').length
          : 0;
      File('$dir/.dart_tool/pub/workspace_ref.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          '${jsonEncode({'workspaceRoot': List.filled(depth + 2, '..').join('/')})}\n',
        );
    }
  }
  final fullReport = environment?['PUB_SUMMARY_ONLY'] == '0';
  final reported = consumer == null
      ? resolution.reported
      : {...consumer.keys, ...resolution.consumerAlsoReports};
  return ToolResult(
    exitCode: 0,
    stdout: [
      'Resolving dependencies...',
      if (fullReport)
        for (final name in reported)
          '! $name 9.9.9 from path ../$name (overridden)',
      fullReport ? 'Got dependencies!' : 'Got dependencies.',
      '',
    ].join('\n'),
    stderr: '',
  );
}

/// `dart pub deps --json` in [workingDirectory].
ToolResult pubDepsJsonIn(
  String workingDirectory, {
  PubResolution resolution = const PubResolution(),
}) => resolution.depsJsonFails
    ? ToolResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Null check operator used on a null value\n',
      )
    : ToolResult(
        exitCode: 0,
        stdout: resolution.graph ?? _packageAlone(workingDirectory),
        stderr: '',
      );

/// `dart pub deps --style=compact` in [workingDirectory]: each package with
/// its declared overrides.
ToolResult pubDepsCompactIn(
  String workingDirectory, {
  PubResolution resolution = const PubResolution(),
}) => ToolResult(
  exitCode: 0,
  stdout: [
    'Dart SDK 3.12.2',
    '${_name(workingDirectory)} 0.2.0',
    '',
    for (final MapEntry(key: package, value: names)
        in resolution.declared.entries) ...[
      '$package 1.0.0',
      '',
      'dependency overrides:',
      for (final name in names) '- $name 9.9.9',
      '',
    ],
  ].join('\n'),
  stderr: '',
);

/// The overrides in the `pubspec_overrides.yaml` the stage wrote at
/// [directory], name to path; null when it wrote none there.
Map<String, String>? _consumerOverrides(String directory) {
  final file = File('$directory/pubspec_overrides.yaml');
  if (!file.existsSync()) return null;
  final source = file.readAsStringSync();
  if (!source.startsWith('# Written by rk')) return null;
  final overrides = (yaml.loadYaml(source) as Map)['dependency_overrides'];
  return {
    for (final MapEntry(:key, :value) in (overrides as Map).entries)
      key as String: (value as Map)['path'] as String,
  };
}

/// The ancestor a `resolution: workspace` package resolves at: the nearest
/// one declaring `workspace:`, followed up while that one is a member too.
String _resolutionRoot(String directory) {
  var root = directory;
  while (_pubspec(
    root,
  ).contains(RegExp(r'^resolution: workspace', multiLine: true))) {
    var dir = root;
    do {
      dir = File(dir).parent.path;
    } while (dir.length > 1 && !_isWorkspace(dir));
    if (dir.length <= 1) return root;
    root = dir;
  }
  return root;
}

bool _isWorkspace(String directory) =>
    _pubspec(directory).contains(RegExp(r'^workspace:', multiLine: true));

/// Every package under [root], the workspace Pub resolves there, by name.
Map<String, String> _workspacePackages(String root) => {
  for (final entry in Directory(root).listSync(recursive: true))
    if (entry is File &&
        entry.path.endsWith('/pubspec.yaml') &&
        !entry.path.contains('/.dart_tool/') &&
        _name(entry.parent.path) != null)
      _name(entry.parent.path)!: entry.parent.path,
  if (_name(root) != null) _name(root)!: root,
};

String _pubspec(String directory) {
  final file = File('$directory/pubspec.yaml');
  return file.existsSync() ? file.readAsStringSync() : '';
}

String? _name(String directory) => RegExp(
  r'^name:\s*(\S+)',
  multiLine: true,
).firstMatch(_pubspec(directory))?.group(1);

/// [to] relative to the directory [from], as Pub writes a `rootUri`.
String _relative(String from, String to) {
  final a = from.split('/').where((part) => part.isNotEmpty).toList();
  final b = Uri.directory(
    to,
  ).normalizePath().path.split('/').where((part) => part.isNotEmpty).toList();
  var common = 0;
  while (common < a.length && common < b.length && a[common] == b[common]) {
    common++;
  }
  final up = [for (var i = common; i < a.length; i++) '..'];
  return '${[...up, ...b.sublist(common)].join('/')}/';
}

String _lockfile(Map<String, ({String type, String source})> lock) {
  if (lock.isEmpty) return '# Generated by pub\npackages: {}\n';
  return [
    '# Generated by pub',
    'packages:',
    for (final MapEntry(key: name, value: entry) in lock.entries) ...[
      '  $name:',
      '    dependency: "${entry.type}"',
      '    description:',
      '      path: "../$name"',
      '      relative: true',
      '    source: ${entry.source}',
      '    version: "9.9.9"',
    ],
    '',
  ].join('\n');
}

String _packageAlone(String directory) {
  final name = _name(directory);
  return jsonEncode({
    'root': name,
    'packages': [
      {
        'name': name,
        'kind': 'root',
        'source': 'root',
        'dependencies': <String>[],
        'directDependencies': <String>[],
        'devDependencies': <String>[],
      },
    ],
  });
}
