import 'dart:convert';
import 'dart:io';

import 'package:rk/src/targets/pub_dev/resolution.dart';
import 'package:test/test.dart';

/// `pub deps --json` for a workspace: two members, one of which reaches a
/// Git-overridden package through its own dependencies.
final _workspaceDeps = jsonEncode({
  'root': 'example_workspace',
  'packages': [
    {
      'name': 'example_workspace',
      'kind': 'root',
      'dependencies': ['core', 'host', 'overridden'],
      'directDependencies': ['core', 'host'],
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

    test('an unreadable overrides file and an unknown graph mask', () {
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

    void workspace({String overrides = '', String hostDeps = ''}) {
      write(
        'pubspec.yaml',
        'name: example_workspace\n'
            'publish_to: none\n'
            'workspace:\n  - packages/core\n  - packages/host\n'
            '$overrides',
      );
      write(
        'packages/core/pubspec.yaml',
        'name: core\nversion: 1.0.0\nresolution: workspace\n',
      );
      write(
        'packages/host/pubspec.yaml',
        'name: host\nversion: 1.0.0\nresolution: workspace\n$hostDeps',
      );
    }

    test('overrides are found at the workspace root', () {
      workspace(
        overrides:
            'dependency_overrides:\n'
            '  overridden:\n    git: https://example.com/x.git\n',
      );
      expect(dependencyOverrides(root.path, '${root.path}/packages/core'), [
        (
          package: 'overridden',
          declaredIn: 'the dependency_overrides section in pubspec.yaml',
        ),
      ]);
    });

    test('a pubspec_overrides.yaml names its packages, or every package', () {
      workspace();
      write(
        'pubspec_overrides.yaml',
        'dependency_overrides:\n  a:\n    path: ../a\n  b: 1.0.0\n',
      );
      write('packages/core/pubspec_overrides.yaml', 'nothing: here\n');
      expect(dependencyOverrides(root.path, '${root.path}/packages/core'), [
        (
          package: everyPackage,
          declaredIn: 'packages/core/pubspec_overrides.yaml',
        ),
        (package: 'a', declaredIn: 'pubspec_overrides.yaml'),
        (package: 'b', declaredIn: 'pubspec_overrides.yaml'),
      ]);
    });

    test('a Flutter member makes every member need Flutter', () {
      workspace(hostDeps: 'dependencies:\n  flutter:\n    sdk: flutter\n');
      expect(needsFlutter(root.path, '${root.path}/packages/core'), isTrue);
      expect(needsFlutter(root.path, '${root.path}/packages/host'), isTrue);
    });

    test('a Flutter SDK constraint alone needs Flutter', () {
      workspace(hostDeps: 'environment:\n  flutter: ">=3.0.0"\n');
      expect(needsFlutter(root.path, '${root.path}/packages/core'), isTrue);
    });

    test('a Dart-only workspace does not need Flutter', () {
      workspace();
      expect(needsFlutter(root.path, '${root.path}/packages/core'), isFalse);
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

    test('a link to Flutter\'s dart is followed', () {
      flutterSdk('flutter');
      Link(
        '${root.path}/usr/local/bin/dart',
      ).createSync('${root.path}/flutter/bin/dart', recursive: true);
      expect(dartInFlutterSdk('${root.path}/usr/local/bin/dart'), isTrue);
    });

    test('a standalone Dart SDK is not, even beside a flutter link', () {
      flutterSdk('flutter');
      final dart = file('dart-sdk/bin/dart');
      Link('${root.path}/brew/bin/dart').createSync(dart, recursive: true);
      Link(
        '${root.path}/brew/bin/flutter',
      ).createSync('${root.path}/flutter/bin/flutter');
      expect(dartInFlutterSdk(dart), isFalse);
      expect(dartInFlutterSdk('${root.path}/brew/bin/dart'), isFalse);
      expect(dartInFlutterSdk('${root.path}/missing/dart'), isFalse);
    });
  });
}
