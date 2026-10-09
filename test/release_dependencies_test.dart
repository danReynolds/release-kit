import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:test/test.dart';

void main() {
  group('a staged package takes from this source', () {
    test('what is not published yet, through each other', () async {
      expect(await _fromSource(_stack(), 'app'), ['core', 'mid', 'testkit']);
    });

    test('nothing for a published version or what it needs', () async {
      // Consumers get mid 0.3.0 from pub.dev, with whatever core it asks
      // for there; testkit still brings the core this source has.
      expect(await _fromSource(_stack(), 'app', published: {'mid@0.3.0'}), [
        'core',
        'testkit',
      ]);
      expect(
        await _fromSource(
          _stack(),
          'app',
          published: {'mid@0.3.0', 'core@0.2.0'},
        ),
        ['testkit'],
      );
    });

    test('what only its development needs, even when published', () async {
      expect(
        await _fromSource(
          _stack(),
          'app',
          published: {'mid@0.3.0', 'core@0.2.0', 'testkit@0.1.0'},
        ),
        ['testkit'],
      );
    });

    test('nothing whose version does not satisfy the requirement', () async {
      final resolution = _stack({
        'mid': 'dependencies:\n  core: ^0.1.0\n',
        'app': 'dependencies:\n  mid: ^0.2.0\n',
      });
      expect(await _fromSource(resolution, 'app'), isEmpty);
      expect(await _fromSource(resolution, 'mid'), isEmpty);
    });

    test(
      'a development need it also has at runtime, by the runtime rule',
      () async {
        final resolution = _stack({
          'app':
              'dependencies:\n  mid: ^0.3.0\n'
              'dev_dependencies:\n  mid: ^0.3.0\n',
        });
        expect(
          await _fromSource(resolution, 'app', published: {'mid@0.3.0'}),
          isEmpty,
        );
      },
    );

    test('never the package itself', () async {
      // core develops with testkit, whose need of core is core itself.
      final resolution = _stack({
        'core': 'dev_dependencies:\n  testkit: ^0.1.0\n',
      });
      expect(await _fromSource(resolution, 'core'), ['testkit']);
    });
  });

  group('a requirement is met by this repository', () {
    List<String> requires(Resolution resolution, String project) => [
      for (final provider in resolution.dependencyPlan.requires(
        resolution.allProjects.singleWhere((p) => p.name == project),
      ))
        provider.name,
    ];

    test('when it names pub.dev, by default, by URL or by its old name', () {
      for (final hosted in [
        '',
        '    hosted: https://pub.dev\n',
        '    hosted: https://pub.dartlang.org\n',
      ]) {
        final resolution = _stack({
          'mid': 'dependencies:\n  core:\n    version: ^0.2.0\n$hosted',
        });
        expect(requires(resolution, 'mid'), ['core'], reason: hosted);
      }
    });

    test('not when it names another registry', () {
      final resolution = _stack({
        'mid':
            'dependencies:\n  core:\n    version: ^0.2.0\n'
            '    hosted: https://packages.example.com\n',
      });
      expect(requires(resolution, 'mid'), isEmpty);
    });

    test('when it states no constraint at all', () {
      final resolution = _stack({'mid': 'dependencies:\n  core:\n'});
      expect(requires(resolution, 'mid'), ['core']);
    });
  });
}

/// A repository of four units: app needs mid, which needs core, and app
/// develops with testkit, which needs core too. [manifests] replaces any
/// package's pubspec body after its name and version.
Resolution _stack([Map<String, String> manifests = const {}]) {
  final diagnostics = Diagnostics();
  final config = ReleaseConfig.parse(
    [
      'schema = 2',
      for (final name in ['core', 'mid', 'app', 'testkit']) ...[
        '[release.$name]',
        'path = "$name"',
        'publish = ["pub.dev"]',
      ],
    ].join('\n'),
    'release.toml',
    diagnostics,
  )!;
  const versions = {
    'core': '0.2.0',
    'mid': '0.3.0',
    'app': '1.0.0',
    'testkit': '0.1.0',
  };
  const bodies = {
    'core': '',
    'mid': 'dependencies:\n  core: ^0.2.0\n',
    'app':
        'dependencies:\n  mid: ^0.3.0\n'
        'dev_dependencies:\n  testkit: ^0.1.0\n',
    'testkit': 'dependencies:\n  core: ^0.2.0\n',
  };
  final result = Resolution.resolve(
    config,
    MemorySourceTree({
      for (final MapEntry(key: name, value: version) in versions.entries)
        '$name/pubspec.yaml':
            'name: $name\nversion: $version\n'
            '${manifests[name] ?? bodies[name]}',
    }),
    diagnostics,
  );
  expect(diagnostics.found, isEmpty);
  return result!;
}

Future<List<String>> _fromSource(
  Resolution resolution,
  String project, {
  Set<String> published = const {},
}) async {
  final sourced = await resolution.dependencyPlan.fromSource(
    resolution.allProjects.singleWhere((p) => p.name == project),
    (package, version) async => published.contains('$package@$version'),
  );
  return [for (final sibling in sourced) sibling.name]..sort();
}
