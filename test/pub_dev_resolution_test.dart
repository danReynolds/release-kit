import 'dart:convert';
import 'dart:io';

import 'package:rk/src/targets/pub_dev/resolution.dart';
import 'package:test/test.dart';

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

  group('appliedOverrides', () {
    test('reads what each workspace package depends on beyond its own', () {
      expect(appliedOverrides(_workspaceDeps), {
        'example_workspace': <String>{},
        'core': <String>{},
        'host': <String>{},
        'pinner': {'overridden'},
      });
    });

    test('answers null for a root package without its lists', () {
      final bare = _edited((packages) {
        final core = packages.firstWhere((p) => (p as Map)['name'] == 'core');
        (core as Map).remove('devDependencies');
      });
      expect(appliedOverrides(bare), isNull);
      expect(appliedOverrides('[]'), isNull);
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
        dependencyOverrides(root.path, packagesOf(dir)!.values);

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

    test('is unknown when a manifest or member cannot be read', () {
      workspace(members: '  - packages/missing\n');
      expect(
        resolutionPackages(root.path, '${root.path}/packages/core').unreadable,
        'pubspec.yaml (workspace member "packages/missing")',
      );

      workspace(members: '  - packages/{core,host}\n');
      expect(packagesOf('packages/core'), isNull, reason: 'brace globs');

      // Valid YAML rk does not read (an anchor) leaves the root unknown
      // rather than empty.
      workspace(more: 'dependency_overrides: &pins\n  leaf: 1.0.0\n');
      expect(
        resolutionPackages(root.path, '${root.path}/packages/core').unreadable,
        'pubspec.yaml',
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
