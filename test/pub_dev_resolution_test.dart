import 'dart:convert';
import 'dart:io';

import 'package:rk/src/targets/pub_dev/resolution.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart' as yaml;

/// `pub deps --json` for a workspace, in the shape Pub 3.12 prints: two
/// members, one of which reaches a Git-overridden package through its own
/// dependencies, and a third whose pubspec declares that override.
final _workspaceDeps = jsonEncode({
  'root': 'example_workspace',
  'packages': [
    {
      'name': 'example_workspace',
      'kind': 'root',
      'dependencies': <String>[],
      'directDependencies': <String>[],
      'devDependencies': <String>[],
    },
    {
      'name': 'core',
      'kind': 'root',
      'dependencies': ['collection', 'test'],
      'directDependencies': ['collection'],
      'devDependencies': ['test'],
    },
    {
      'name': 'host',
      'kind': 'root',
      'dependencies': ['core', 'widgets', 'lints'],
      'directDependencies': ['core', 'widgets'],
      'devDependencies': ['lints'],
    },
    {
      'name': 'pinner',
      'kind': 'root',
      // An override declared in a member is reported as a dependency that is
      // neither direct nor dev.
      'dependencies': ['overridden'],
      'directDependencies': <String>[],
      'devDependencies': <String>[],
    },
    {
      'name': 'widgets',
      'kind': 'direct',
      'dependencies': ['overridden'],
      'directDependencies': ['overridden'],
    },
    {
      'name': 'overridden',
      'kind': 'transitive',
      'dependencies': ['meta'],
      'directDependencies': ['meta'],
    },
    for (final leaf in ['collection', 'meta', 'test', 'lints'])
      {
        'name': leaf,
        'kind': 'transitive',
        'dependencies': <String>[],
        'directDependencies': <String>[],
      },
  ],
});

/// [_workspaceDeps] with one package entry changed by [edit].
String _edited(void Function(List<Object?> packages) edit) {
  final decoded = jsonDecode(_workspaceDeps) as Map<String, Object?>;
  edit(decoded['packages'] as List<Object?>);
  return jsonEncode(decoded);
}

void main() {
  group('runtimeDependencies', () {
    test('follows dependencies, not dev dependencies', () {
      expect(runtimeDependencies(_workspaceDeps, 'core'), {'collection'});
    });

    test('reaches through workspace members and hosted packages', () {
      expect(runtimeDependencies(_workspaceDeps, 'host'), {
        'core',
        'collection',
        'widgets',
        'overridden',
        'meta',
      });
    });

    test('answers null when the output does not describe the package', () {
      expect(runtimeDependencies(_workspaceDeps, 'absent'), isNull);
      expect(runtimeDependencies('not json', 'core'), isNull);
      expect(runtimeDependencies('{"packages": 3}', 'core'), isNull);
      expect(
        runtimeDependencies(
          jsonEncode({
            'packages': [
              {'name': 'core', 'kind': 'root'},
            ],
          }),
          'core',
        ),
        isNull,
        reason: 'without its dependency list, a package cannot be placed',
      );
    });

    test('answers null rather than a smaller graph for a reshaped one', () {
      // An edge to a package the output does not list.
      final unlisted = _edited(
        (packages) =>
            packages.removeWhere((p) => (p as Map)['name'] == 'widgets'),
      );
      // An edge that is not a package name.
      final objectEdge = _edited((packages) {
        final host = packages.firstWhere((p) => (p as Map)['name'] == 'host');
        ((host as Map)['directDependencies'] as List).add({'name': 'x'});
      });
      // An entry that is not a package.
      final stray = _edited((packages) => packages.add('widgets'));
      // The same package twice.
      final twice = _edited(
        (packages) => packages.add({
          'name': 'core',
          'kind': 'transitive',
          'dependencies': <String>[],
        }),
      );
      for (final json in [unlisted, objectEdge, stray, twice]) {
        expect(runtimeDependencies(json, 'host'), isNull, reason: json);
      }
    });
  });

  group('unhostedDependencies', () {
    String graph(Map<String, String?> sources) => jsonEncode({
      'packages': [
        {'name': 'member', 'kind': 'root', 'source': 'root'},
        for (final MapEntry(key: name, value: source) in sources.entries)
          {'name': name, 'kind': 'transitive', 'source': ?source},
      ],
    });

    test('names reached packages Pub took from a path or Git', () {
      final json = graph({
        'fork': 'path',
        'pinned': 'git',
        'hosted': 'hosted',
        'flutter': 'sdk',
      });
      expect(
        unhostedDependencies(json, {'fork', 'pinned', 'hosted', 'flutter'}),
        {'fork': 'path', 'pinned': 'git'},
      );
      expect(unhostedDependencies(json, {'hosted'}), isEmpty);
    });

    test('leaves out workspace packages, which consumers get published', () {
      expect(unhostedDependencies(graph({}), {'member'}), isEmpty);
    });

    test('answers null for a package without its source', () {
      expect(unhostedDependencies(graph({'fork': null}), {'fork'}), isNull);
      expect(unhostedDependencies(graph({}), {'absent'}), isNull);
    });
  });

  group('maskingOverrides', () {
    const overridden = (package: 'overridden', declaredIn: 'pubspec.yaml');
    const unreadable = (package: everyPackage, declaredIn: 'overrides.yaml');

    test('an override the package does not reach does not mask it', () {
      final reached = runtimeDependencies(_workspaceDeps, 'core');
      expect(maskingOverrides([overridden], 'core', reached), isEmpty);
    });

    test('an override reached through a dependency masks the package', () {
      final reached = runtimeDependencies(_workspaceDeps, 'host');
      expect(maskingOverrides([overridden], 'host', reached), [overridden]);
    });

    test('an override of the package itself masks it', () {
      const own = (package: 'core', declaredIn: 'pubspec.yaml');
      expect(maskingOverrides([own], 'core', const {}), [own]);
    });

    test('an unreadable declaration and an unknown graph mask', () {
      expect(maskingOverrides([unreadable], 'core', const {}), [unreadable]);
      expect(maskingOverrides([overridden], 'core', null), [overridden]);
    });
  });

  group('snapshotPackages', () {
    // In the fixture, host depends on core (a workspace package) and on
    // widgets; core develops with test; pinner overrides a package.
    test('takes a runtime dependency from the snapshot only when it is '
        'released with the package', () {
      expect(snapshotPackages(_workspaceDeps, 'host', {'host'}), isEmpty);
      expect(snapshotPackages(_workspaceDeps, 'host', {'host', 'core'}), {
        'core',
      });
      expect(snapshotPackages(_workspaceDeps, 'core', {'core'}), isEmpty);
    });

    test('takes what only development needs from the snapshot', () {
      // core develops with host, which brings core itself and widgets.
      final graph = _edited((packages) {
        (packages[1] as Map)['devDependencies'] = ['test', 'host'];
      });
      expect(snapshotPackages(graph, 'core', {'core'}), {'host'});
    });

    test('leaves a package reached both ways to the runtime rule', () {
      // host develops with pinner too, and pinner is also a runtime
      // dependency through widgets: consumers take it from pub.dev.
      final graph = _edited((packages) {
        (packages[2] as Map)['devDependencies'] = ['lints', 'pinner'];
        (packages[4] as Map)['dependencies'] = ['overridden', 'pinner'];
      });
      expect(snapshotPackages(graph, 'host', {'host'}), isEmpty);
      expect(snapshotPackages(graph, 'host', {'host', 'pinner'}), {'pinner'});
    });

    test('follows hosted packages to a workspace package they depend on', () {
      final graph = _edited((packages) {
        (packages[4] as Map)['dependencies'] = ['overridden', 'pinner'];
      });
      expect(snapshotPackages(graph, 'host', {'host', 'pinner'}), {'pinner'});
    });

    test('is unknown for an incomplete graph', () {
      expect(snapshotPackages(_workspaceDeps, 'absent', const {}), isNull);
      final missingDev = _edited((packages) {
        (packages[2] as Map).remove('devDependencies');
      });
      expect(snapshotPackages(missingDev, 'host', const {}), isNull);
      final dangling = _edited((packages) {
        (packages[1] as Map)['devDependencies'] = ['nowhere'];
      });
      expect(snapshotPackages(dangling, 'core', const {}), isNull);
    });

    test('names every workspace package', () {
      expect(workspacePackages(_workspaceDeps), {
        'example_workspace',
        'core',
        'host',
        'pinner',
      });
    });
  });

  group('consumerOverrides', () {
    test('overrides nothing for a package alone', () {
      expect(
        consumerOverrides(const {}, inWorkspace: false),
        '# Written by rk: resolve this package the way its consumers do.\n'
        'dependency_overrides: {}\n',
      );
    });

    test('makes a workspace package a root, with its siblings by path', () {
      final written = consumerOverrides(const {
        'widgets': '../widgets',
        'core': '../odd "dir"\\name',
      }, inWorkspace: true);
      expect(
        written,
        '# Written by rk: resolve this package the way its consumers do.\n'
        'resolution: null\n'
        'workspace: []\n'
        'dependency_overrides:\n'
        '  core:\n'
        '    path: "../odd \\"dir\\"\\\\name"\n'
        '  widgets:\n'
        '    path: "../widgets"\n',
      );
      // What Pub's YAML reader makes of it.
      final read = yaml.loadYaml(written) as Map;
      expect(read.containsKey('resolution'), isTrue);
      expect(read['resolution'], isNull);
      expect(read['workspace'], isEmpty);
      expect(read['dependency_overrides'], {
        'core': {'path': '../odd "dir"\\name'},
        'widgets': {'path': '../widgets'},
      });
    });
  });

  group('the workspace', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('rk-resolution-'));
    tearDown(() => root.deleteSync(recursive: true));

    void write(String path, String contents) {
      File('${root.path}/$path')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(contents);
    }

    String member(String name, [String more = '']) =>
        'name: $name\nversion: 1.0.0\nresolution: workspace\n$more';

    void workspace({String members = '  - packages/*\n', String more = ''}) {
      write(
        'pubspec.yaml',
        'name: example_workspace\npublish_to: none\n'
            'workspace:\n$members$more',
      );
      write('packages/core/pubspec.yaml', member('core'));
      write('packages/host/pubspec.yaml', member('host'));
    }

    Map<String, String>? packagesOf(String dir) =>
        resolutionPackages(root.path, '${root.path}/$dir').packages;

    List<DependencyOverride> overridesOf(String dir) =>
        dependencyOverrides(root.path, packagesOf(dir)!);

    String? unreadable(String dir) =>
        resolutionPackages(root.path, '${root.path}/$dir').unreadable;

    test('is every package of the workspace, members matched by glob', () {
      workspace();
      // A directory without a pubspec is not a member; a hidden one is.
      Directory('${root.path}/packages/docs').createSync(recursive: true);
      write('packages/.tool/pubspec.yaml', member('tool'));
      expect(packagesOf('packages/core'), {
        'example_workspace': root.path,
        'core': '${root.path}/packages/core',
        'host': '${root.path}/packages/host',
        'tool': '${root.path}/packages/.tool',
      });
    });

    test('is read from the top-most root of nested workspaces', () {
      write(
        'pubspec.yaml',
        'name: top\npublish_to: none\nworkspace:\n  - pkgs\n',
      );
      write(
        'pkgs/pubspec.yaml',
        'name: middle\npublish_to: none\nresolution: workspace\n'
            'workspace:\n  - "**/keybay"\n',
      );
      write('pkgs/deep/keybay/pubspec.yaml', member('keybay'));
      expect(packagesOf('pkgs/deep/keybay')!.keys, {'top', 'middle', 'keybay'});
    });

    test('matches member patterns as Pub does', () {
      for (final members in [
        '  - ./packages/*\n',
        '  - packages/../packages/*/\n',
        '  - packages/{core,host}\n',
        '  - packages/[ch]o[!x]*\n',
        '  - packages/core\n  - packages/h?st\n',
        // `**` never matches the root it starts from.
        '  - "**"\n',
      ]) {
        workspace(members: members);
        expect(packagesOf('packages/core')!.keys.toSet(), {
          'example_workspace',
          'core',
          'host',
        }, reason: members);
      }
    });

    test('matches glob segments case-sensitively, as Pub does', () {
      workspace(members: '  - Packages/*\n');
      expect(packagesOf('packages/core'), isNull);
    });

    test('is unknown, and says why, when it cannot be read', () {
      workspace(members: '  - packages/*\n  - tools/*\n');
      expect(
        unreadable('packages/core'),
        'pubspec.yaml lists workspace member "tools/*", which matches no '
        'package',
      );

      workspace(members: '  - ../elsewhere/*\n');
      expect(
        unreadable('packages/core'),
        contains('a pattern rk does not read'),
      );

      workspace(members: '  - packages/{core,{host}}\n');
      expect(
        unreadable('packages/core'),
        contains('a pattern rk does not read'),
      );

      // Valid YAML rk does not read (an anchor) leaves the root unknown
      // rather than empty.
      workspace(more: 'dependency_overrides: &pins\n  leaf: 1.0.0\n');
      expect(unreadable('packages/core'), 'pubspec.yaml is not YAML rk reads');

      // Nor does a pubspec that is not UTF-8.
      workspace();
      File('${root.path}/packages/host/pubspec.yaml').writeAsBytesSync([
        ...utf8.encode('name: host\ndescription: '),
        0xff,
        0xfe,
        10,
      ]);
      expect(
        unreadable('packages/core'),
        'packages/host/pubspec.yaml is not YAML rk reads',
      );
    });

    test('a package its workspace does not list is unknown', () {
      workspace(members: '  - packages/core\n');
      expect(
        unreadable('packages/host'),
        'packages/host/pubspec.yaml is not one of the packages its workspace '
        'lists',
      );
    });

    test('a member with no workspace above it is unknown', () {
      write('packages/core/pubspec.yaml', member('core'));
      expect(packagesOf('packages/core'), isNull);
    });

    test('a package outside any workspace is resolved alone', () {
      write('pubspec.yaml', 'name: solo\nversion: 1.0.0\n');
      expect(resolutionPackages(root.path, root.path).packages, {
        'solo': root.path,
      });
    });

    test("overrides are read from every package, a sibling's included", () {
      workspace(
        more:
            'dependency_overrides:\n'
            '  pinned:\n    git: https://example.com/x.git\n',
      );
      write(
        'packages/host/pubspec.yaml',
        member('host', 'dependency_overrides:\n  leaf:\n    path: ../fork\n'),
      );
      write(
        'packages/core/pubspec_overrides.yaml',
        'dependency_overrides:\n  other: 1.0.0\n',
      );
      expect(overridesOf('packages/core').toSet(), {
        (
          package: 'pinned',
          declaredIn: 'the dependency_overrides section in pubspec.yaml',
        ),
        (
          package: 'leaf',
          declaredIn:
              'the dependency_overrides section in packages/host/pubspec.yaml',
        ),
        (package: 'other', declaredIn: 'packages/core/pubspec_overrides.yaml'),
      });
    });

    test('an overrides file replaces the section, as Pub reads it', () {
      workspace();
      write(
        'packages/core/pubspec.yaml',
        member('core', 'dependency_overrides:\n  ignored: 1.0.0\n'),
      );
      write(
        'packages/core/pubspec_overrides.yaml',
        'dependency_overrides:\n  used: 1.0.0\n',
      );
      expect(overridesOf('packages/core'), [
        (package: 'used', declaredIn: 'packages/core/pubspec_overrides.yaml'),
      ]);

      // One without the key leaves the section in force.
      write('packages/core/pubspec_overrides.yaml', 'other: true\n');
      expect(overridesOf('packages/core').single.package, 'ignored');

      // A null section declares nothing, and still replaces the pubspec's.
      write(
        'packages/core/pubspec_overrides.yaml',
        'dependency_overrides: ~\n',
      );
      expect(overridesOf('packages/core'), isEmpty);
    });

    test('what rk cannot read as a package name overrides everything', () {
      workspace();
      write(
        'packages/core/pubspec_overrides.yaml',
        'dependency_overrides:\n  "{leaf": {path: fork}\n',
      );
      write(
        'packages/host/pubspec_overrides.yaml',
        'dependency_overrides: 3\n',
      );
      expect(overridesOf('packages/core').map((o) => o.package), [
        everyPackage,
        everyPackage,
      ]);

      write('packages/host/pubspec_overrides.yaml', '- not a map\n');
      write('packages/core/pubspec_overrides.yaml', 'dependency_overrides:\n');
      expect(overridesOf('packages/core'), [
        (
          package: everyPackage,
          declaredIn: 'packages/host/pubspec_overrides.yaml',
        ),
      ]);
    });

    test('a Flutter member makes every member need Flutter', () {
      workspace();
      write(
        'packages/host/pubspec.yaml',
        member('host', 'dependencies:\n  flutter:\n    sdk: flutter\n'),
      );
      expect(needsFlutter(packagesOf('packages/core')!.values), isTrue);
    });

    test('a Flutter SDK constraint alone needs Flutter', () {
      workspace();
      write(
        'packages/host/pubspec.yaml',
        member('host', 'environment:\n  flutter: ">=3.0.0"\n'),
      );
      expect(needsFlutter(packagesOf('packages/core')!.values), isTrue);
    });

    test('a Dart-only workspace does not need Flutter', () {
      workspace();
      expect(needsFlutter(packagesOf('packages/core')!.values), isFalse);
    });
  });

  group("Pub's records", () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('rk-records-'));
    tearDown(() => root.deleteSync(recursive: true));

    void write(String path, String contents) {
      File('${root.path}/$path')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(contents);
    }

    /// What Dart 3.12's `pub get` records for a workspace whose member b
    /// pins args in its pubspec and replaces that section in its overrides
    /// file, where `pub deps --json` then fails.
    void recordCrashLayout() {
      write(
        '.dart_tool/package_graph.json',
        jsonEncode({
          'roots': ['a', 'b', 'ws'],
          'packages': [
            {
              'name': 'ws',
              'version': '0.0.0',
              'dependencies': <String>[],
              'devDependencies': <String>[],
            },
            {
              'name': 'a',
              'version': '1.0.0',
              'dependencies': ['leaf', 'path'],
              'devDependencies': <String>[],
            },
            {
              'name': 'b',
              'version': '1.0.0',
              'dependencies': <String>[],
              'devDependencies': <String>[],
            },
            {'name': 'meta', 'version': '1.16.0', 'dependencies': <String>[]},
            {'name': 'leaf', 'version': '9.9.9', 'dependencies': <String>[]},
            {'name': 'path', 'version': '1.8.0', 'dependencies': <String>[]},
          ],
          'configVersion': 1,
        }),
      );
      write('pubspec.lock', '''
# Generated by pub
# See https://dart.dev/tools/pub/glossary#lockfile
packages:
  leaf:
    dependency: "direct overridden"
    description:
      path: "ext/fork"
      relative: true
    source: path
    version: "9.9.9"
  meta:
    dependency: "direct overridden"
    description:
      name: meta
      sha256: e3641ec5d63ebf0d9b41bd43201a66e3fc79a65db5f61fc181f04cd27aab950c
      url: "https://pub.dev"
    source: hosted
    version: "1.16.0"
  path:
    dependency: "direct overridden"
    description:
      name: path
      sha256: "2ad4cddff7f5cc0e2d13069f2a3f7a73ca18f66abd6f5ecf215219cdb3638edb"
      url: "https://pub.dev"
    source: hosted
    version: "1.8.0"
sdks:
  dart: ">=3.11.0 <4.0.0"
''');
    }

    test('the graph pub get recorded reads as pub deps prints it', () {
      recordCrashLayout();
      final graph = recordedGraph(root.path)!;
      expect(runtimeDependencies(graph, 'a'), {'leaf', 'path'});
      expect(runtimeDependencies(graph, 'b'), isEmpty);
      expect(unhostedDependencies(graph, {'leaf', 'path'}), {'leaf': 'path'});
      expect(usesFlutter(graph), isFalse);
      expect(workspacePackages(graph), {'ws', 'a', 'b'});
      expect(snapshotPackages(graph, 'a', {'a'}), isEmpty);
    });

    test('the recorded graph takes a Flutter package from the SDK', () {
      recordCrashLayout();
      write(
        '.dart_tool/package_graph.json',
        jsonEncode({
          'roots': ['a'],
          'packages': [
            {
              'name': 'a',
              'dependencies': ['flutter'],
              'devDependencies': <String>[],
            },
            {'name': 'flutter', 'dependencies': <String>[]},
          ],
        }),
      );
      write(
        'pubspec.lock',
        'packages:\n'
            '  flutter:\n'
            '    dependency: "direct main"\n'
            '    description: flutter\n'
            '    source: sdk\n'
            '    version: "0.0.0"\n',
      );
      expect(usesFlutter(recordedGraph(root.path)!), isTrue);
    });

    test('the recorded graph is unknown without both records, or when they '
        'disagree', () {
      expect(recordedGraph(root.path), isNull);
      recordCrashLayout();
      File('${root.path}/pubspec.lock').deleteSync();
      expect(recordedGraph(root.path), isNull, reason: 'no lockfile');
      recordCrashLayout();
      write(
        'pubspec.lock',
        'packages:\n'
            '  meta:\n'
            '    dependency: "direct overridden"\n'
            '    source: hosted\n'
            '    version: "1.16.0"\n',
      );
      expect(recordedGraph(root.path), isNull, reason: 'leaf is not locked');
      recordCrashLayout();
      write(
        '.dart_tool/package_graph.json',
        '{"roots": ["a"], "packages": [{"name": "a", "dependencies": "leaf"}]}',
      );
      expect(recordedGraph(root.path), isNull, reason: 'edges not a list');
      write('.dart_tool/package_graph.json', '{"packages": []}');
      expect(recordedGraph(root.path), isNull, reason: 'no roots');
    });

    test("each package's directory, from Pub's package configuration", () {
      write(
        '.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'leaf', 'rootUri': '../ext/fork', 'packageUri': 'lib/'},
            {
              'name': 'meta',
              'rootUri': 'file:///cache/hosted/pub.dev/meta-1.16.0/',
              'packageUri': 'lib/',
            },
            {'name': 'ws', 'rootUri': '../', 'packageUri': 'lib/'},
            {'name': 'a', 'rootUri': '../a', 'packageUri': 'lib/'},
          ],
        }),
      );
      expect(packageDirectories(root.path), {
        'leaf': '${root.path}/ext/fork',
        'meta': '/cache/hosted/pub.dev/meta-1.16.0',
        'ws': root.path,
        'a': '${root.path}/a',
      });
      write('.dart_tool/package_config.json', '{"packages": [{"name": 1}]}');
      expect(packageDirectories(root.path), isNull);
      File('${root.path}/.dart_tool/package_config.json').deleteSync();
      expect(packageDirectories(root.path), isNull);
    });

    test('pub get reports every override it applied', () {
      expect(
        reportedOverrides('''
Resolving dependencies...
Downloading packages...
! leaf 9.9.9 from path ext/fork (overridden)
! meta 1.16.0 (overridden in ./pubspec_overrides.yaml) (1.19.0 available)
+ path 1.9.1
  collection 1.19.1 (1.20.0 available)
Got dependencies!
'''),
        {'leaf', 'meta'},
      );
      expect(reportedOverrides('Got dependencies!\n'), isEmpty);
      // Pub accepts dotted package names from some hosts.
      expect(
        reportedOverrides('! foo.bar 2.0.0 from path ../fork (overridden)\n'),
        {'foo.bar'},
      );
    });

    test("Pub's compact report lists what it read from every package", () {
      // As `dart pub deps --style=compact` prints a workspace whose member
      // host overrides leaf in its pubspec_overrides.yaml.
      expect(
        declaredOverrides('''
Dart SDK 3.12.2
Flutter SDK 3.44.4
ws 0.0.0

keybay 1.0.0

dependencies:
- leaf 9.9.9

host 1.0.0

dev dependencies:
- other 1.0.0

dependency overrides:
- leaf 9.9.9
- meta 1.16.0 [collection]

transitive dependencies:
- collection 1.19.1
'''),
        {'leaf', 'meta'},
      );
      expect(
        declaredOverrides('keybay 1.0.0\n\ndependencies:\n- leaf 1.0.0\n'),
        isEmpty,
      );
    });

    test('a package from an SDK means Flutter', () {
      String graph(String source) => jsonEncode({
        'packages': [
          {'name': 'flutter', 'kind': 'direct', 'source': source},
        ],
      });
      expect(usesFlutter(graph('sdk')), isTrue);
      expect(usesFlutter(graph('hosted')), isFalse);
      expect(usesFlutter('not json'), isNull);
    });

    test('a member points at the root it resolved from', () {
      write(
        'packages/keybay/.dart_tool/pub/workspace_ref.json',
        '{"workspaceRoot": "../../../.."}',
      );
      expect(resolvedRoot('${root.path}/packages/keybay'), root.path);
    });

    test('a package resolved alone is its own root', () {
      write('.dart_tool/package_config.json', '{}');
      expect(resolvedRoot(root.path), root.path);
      expect(resolvedRoot('${root.path}/elsewhere'), isNull);
      write('bad/.dart_tool/pub/workspace_ref.json', '[1]');
      expect(resolvedRoot('${root.path}/bad'), isNull);
    });

    test(
      'the lockfile marks overrides, except of the root\'s own dependencies',
      () {
        // Pub writes `direct overridden` only for a package the root does not
        // depend on itself; path is overridden too, but recorded as direct.
        write('pubspec.lock', '''
# Generated by pub
packages:
  leaf:
    dependency: "direct overridden"
    source: path
    version: "9.9.9"
  meta:
    dependency: transitive
    source: hosted
    version: "1.16.0"
  path:
    dependency: "direct main"
    source: hosted
    version: "1.8.0"
sdks:
  dart: ">=3.6.0 <4.0.0"
''');
        expect(overriddenPackages(root.path), {'leaf'});
      },
    );

    test(
      'an empty lockfile marks nothing; a missing or odd one is unknown',
      () {
        write('pubspec.lock', 'packages: {}\n');
        expect(overriddenPackages(root.path), isEmpty);
        write('pubspec.lock', 'packages:\n  leaf:\n    source: path\n');
        expect(overriddenPackages(root.path), isNull);
        File('${root.path}/pubspec.lock').deleteSync();
        expect(overriddenPackages(root.path), isNull);
      },
    );
  });

  group('dartInFlutterSdk', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('rk-flutter-'));
    tearDown(() => root.deleteSync(recursive: true));

    String file(String path) {
      final created = File('${root.path}/$path')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('');
      return created.path;
    }

    void flutterSdk(String at) {
      file('$at/bin/flutter');
      file('$at/bin/dart');
      file('$at/bin/cache/dart-sdk/bin/dart');
    }

    test("a Flutter SDK's bin/dart and its cached Dart SDK are Flutter's", () {
      flutterSdk('flutter');
      expect(dartInFlutterSdk('${root.path}/flutter/bin/dart'), isTrue);
      expect(
        dartInFlutterSdk('${root.path}/flutter/bin/cache/dart-sdk/bin/dart'),
        isTrue,
      );
    });

    test("a link to Flutter's dart is followed", () {
      flutterSdk('flutter');
      Link(
        '${root.path}/usr/local/bin/dart',
      ).createSync('${root.path}/flutter/bin/dart', recursive: true);
      expect(dartInFlutterSdk('${root.path}/usr/local/bin/dart'), isTrue);
    });

    test(
      'a standalone Dart SDK is not, even linked from a Flutter-like bin',
      () {
        flutterSdk('flutter');
        final dart = file('dart-sdk/bin/dart');
        // Read without following the link, brew/bin would pass for a Flutter
        // SDK's bin: it holds a flutter and a cache/dart-sdk.
        Link('${root.path}/brew/bin/dart').createSync(dart, recursive: true);
        Link(
          '${root.path}/brew/bin/flutter',
        ).createSync('${root.path}/flutter/bin/flutter');
        Directory(
          '${root.path}/brew/bin/cache/dart-sdk',
        ).createSync(recursive: true);
        expect(dartInFlutterSdk(dart), isFalse);
        expect(dartInFlutterSdk('${root.path}/brew/bin/dart'), isFalse);
        expect(dartInFlutterSdk('${root.path}/missing/dart'), isFalse);
      },
    );
  });
}
