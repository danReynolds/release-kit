import 'dart:convert';
import 'dart:io';

import 'package:rk/src/targets/pub_dev/resolution.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart' as yaml;

void main() {
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

    test('one Flutter package among them needs Flutter', () {
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
    test('a member only development reaches comes from the source', () {
      workspace();
      write(
        'packages/core/pubspec.yaml',
        member(
          'core',
          'dependencies:\n  host: ^1.0.0\n'
              'dev_dependencies:\n  helper: any\n  tools: any\n',
        ),
      );
      // A dev helper's own needs come too; a member the package also
      // reaches at runtime follows the runtime rule instead.
      write(
        'packages/helper/pubspec.yaml',
        member('helper', 'dependencies:\n  fixtures: any\n  host: any\n'),
      );
      write('packages/fixtures/pubspec.yaml', member('fixtures'));
      // What a member develops with stays its own.
      write(
        'packages/host/pubspec.yaml',
        member('host', 'dev_dependencies:\n  bench: any\n'),
      );
      write('packages/bench/pubspec.yaml', member('bench'));
      final members = packagesOf('packages/core')!;
      expect(developmentMembers(members, 'core'), {'helper', 'fixtures'});
      expect(developmentMembers(members, 'host'), {'bench'});
      expect(developmentMembers(members, 'missing'), isEmpty);
      expect(
        developmentMembers({'solo': root.path}, 'solo'),
        isEmpty,
        reason: 'a package alone has no members to take',
      );
    });

    test('a root or member resolves with its workspace', () {
      workspace();
      write('solo/pubspec.yaml', 'name: solo\nversion: 1.0.0\n');
      expect(inWorkspace(root.path), isTrue);
      expect(inWorkspace('${root.path}/packages/core'), isTrue);
      expect(inWorkspace('${root.path}/solo'), isFalse);
    });
  });

  group('reportedOverrides', () {
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
