import 'package:rk/src/engine/native_dependencies.dart';
import 'package:rk/src/native/dart/dependencies.dart';
import 'package:rk/src/native/dart/hosted_discovery.dart';
import 'package:rk/src/native/dart/package_archive.dart';
import 'package:rk/src/native/dart/publication.dart';
import 'package:rk/src/native/dart/stage_context.dart';
import 'package:test/test.dart';

const registry = 'https://pub.example.test';

void main() {
  test(
    'runtime projection includes transitive hosted causes and independent versions',
    () {
      final context = _context(
        root: _manifest(
          'app',
          dependencies: {'bridge': '^1.0.0', 'core': '^0.2.0'},
        ),
        selected: [
          _manifest(
            'bridge',
            version: '1.0.0',
            dependencies: {'core': '>=0.2.0 <0.3.0'},
          ),
          _manifest('core', version: '0.2.0'),
        ],
        candidates: {'core'},
      );
      final requirements = dartPublicRequirements(
        context,
        rootManifestPath: 'app/pubspec.yaml',
      );
      expect(requirements.map((r) => r.consumer), ['app', 'bridge']);
      expect(requirements.map((r) => r.slot), everyElement('core'));
      expect(requirements.map((r) => r.owner), everyElement('app'));
      expect(requirements.map((r) => r.location.path), [
        'app/pubspec.yaml',
        'hosted/bridge-1.0.0/pubspec.yaml',
      ]);
      expect(
        requirements.every(
          (r) =>
              r.phases.length == 1 &&
              r.phases.contains(DependencyPhase.publication),
        ),
        isTrue,
      );
    },
  );

  test('dev-only first-party package does not create public obligations', () {
    final context = _context(
      root: _manifest('app', development: {'bridge': 'any'}),
      selected: [
        _manifest('bridge', dependencies: {'core': 'any'}),
        _manifest('core'),
      ],
      candidates: {'core'},
    );
    expect(
      dartPublicRequirements(context, rootManifestPath: 'pubspec.yaml'),
      isEmpty,
    );
  });

  test('development helper back-edge does not become a public obligation', () {
    final context = _context(
      root: _manifest('app', development: {'helper': 'any'}),
      selected: [
        _manifest('helper', dependencies: {'app': '^0.1.0'}),
      ],
      helpers: {'helper'},
    );
    expect(
      dartPublicRequirements(context, rootManifestPath: 'pubspec.yaml'),
      isEmpty,
    );
    expect(context.envelope.bindings, isEmpty);
  });

  for (final mismatch in ['constraint', 'registry']) {
    test(
      '$mismatch dev shadow cannot donate transitive public requirements',
      () {
        final context = _context(
          root: _manifest(
            'app',
            dependencies: {
              'bridge': mismatch == 'constraint'
                  ? '^2.0.0'
                  : {
                      'hosted': {
                        'name': 'bridge',
                        'url': 'https://other.example.test',
                      },
                      'version': 'any',
                    },
            },
            development: {'bridge': 'any'},
          ),
          selected: [
            _manifest(
              'bridge',
              version: '1.0.0',
              dependencies: {'core': 'any'},
            ),
            _manifest('core'),
          ],
          candidates: {'core'},
        );
        expect(
          dartPublicRequirements(context, rootManifestPath: 'pubspec.yaml'),
          isEmpty,
        );
      },
    );
  }

  test(
    'compatible runtime and development names retain original runtime cause',
    () {
      final context = _context(
        root: _manifest(
          'app',
          dependencies: {'core': '^0.2.0'},
          development: {'core': '>=0.2.0 <0.3.0'},
        ),
        selected: [_manifest('core', version: '0.2.0')],
        candidates: {'core'},
      );
      expect(
        dartPublicRequirements(
          context,
          rootManifestPath: 'pubspec.yaml',
        ).single.constraint,
        '^0.2.0',
      );
    },
  );

  test('binary contexts never create package publication obligations', () {
    final context = _context(
      root: _manifest('app', dependencies: {'core': 'any'}),
      selected: [_manifest('core')],
      candidates: {'core'},
      binary: true,
    );
    expect(
      dartPublicRequirements(context, rootManifestPath: 'pubspec.yaml'),
      isEmpty,
    );
  });

  test(
    'runtime SDK branch reaching staged provider is explicitly unsupported',
    () {
      final context = _context(
        root: _manifest(
          'app',
          dependencies: {
            'sdk_package': {'sdk': 'flutter'},
          },
        ),
        selected: [_manifest('core')],
        candidates: {'core'},
        sdkDependencies: {
          'sdk_package': ['core'],
        },
      );
      expect(
        () => dartPublicRequirements(context, rootManifestPath: 'pubspec.yaml'),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'detail',
            contains('SDK-mediated staged runtime provider'),
          ),
        ),
      );
    },
  );

  test(
    'public-only SDK branch remains eligible for the real public consumer check',
    () {
      final context = _context(
        root: _manifest(
          'app',
          dependencies: {
            'sdk_package': {'sdk': 'flutter'},
          },
        ),
        selected: [_manifest('remote')],
        sdkDependencies: {
          'sdk_package': ['remote'],
        },
      );
      expect(
        dartPublicRequirements(context, rootManifestPath: 'pubspec.yaml'),
        isEmpty,
      );
    },
  );
}

DartPackageManifest _manifest(
  String name, {
  String version = '0.1.0',
  Map<String, Object?> dependencies = const {},
  Map<String, Object?> development = const {},
}) => DartPackageManifest.fromMap({
  'name': name,
  'version': version,
  'environment': {'sdk': '^3.0.0'},
  if (dependencies.isNotEmpty) 'dependencies': dependencies,
  if (development.isNotEmpty) 'dev_dependencies': development,
});

DartStageContext _context({
  required DartPackageManifest root,
  required List<DartPackageManifest> selected,
  Set<String> candidates = const {},
  Set<String> helpers = const {},
  Map<String, List<String>> sdkDependencies = const {},
  bool binary = false,
}) {
  List<String> edges(DartPackageManifest manifest, String section) =>
      (manifest.fields[section] as Map?)?.keys.cast<String>().toList() ?? [];
  Map<String, Object?> node(
    DartPackageManifest manifest, {
    bool isRoot = false,
  }) => {
    'name': manifest.name,
    'version': manifest.version,
    'source': isRoot ? 'root' : dartRegistryIdentity(registry),
    'dependencies': edges(manifest, 'dependencies'),
    'devDependencies': isRoot
        ? edges(manifest, 'dev_dependencies')
        : <String>[],
  };
  final discovery = DartDiscoveryResult.fromJson({
    'graph': {
      'roots': [root.name],
      'packages': {
        root.name: node(root, isRoot: true),
        for (final manifest in selected) manifest.name: node(manifest),
        for (final sdk in sdkDependencies.entries)
          sdk.key: {
            'name': sdk.key,
            'version': '0.0.0',
            'source': 'sdk:${'a' * 64}',
            'dependencies': sdk.value,
            'devDependencies': <String>[],
          },
      },
    },
    'packages': {
      for (final manifest in selected)
        manifest.name: {
          'registry': registry,
          'manifest': manifest.fields,
          'manifest_sha256': manifest.sha256,
          if (candidates.contains(manifest.name))
            'candidate': NativeCandidate(
              package: NativePackage(
                ecosystem: 'dart',
                source: dartRegistryIdentity(registry),
                name: manifest.name,
              ),
              version: manifest.version,
              unit: manifest.name,
              project: manifest.name,
              producer: 'pub-archive:${manifest.name}',
            ).toJson()
          else if (helpers.contains(manifest.name))
            'development_source': {
              'manifest_path': 'support/${manifest.name}/pubspec.yaml',
              'registry': registry,
              'manifest': manifest.fields,
            }
          else
            'archive_sha256': 'b' * 64,
        },
    },
  });
  return DartStageContext.discovered(
    root: root,
    defaultRegistry: registry,
    operation: binary
        ? DartStageOperation.binary
        : DartStageOperation.pubArchive,
    consumers: [
      binary ? 'build:${root.name}:linux-x64' : 'pub-archive:${root.name}',
    ],
    discovery: discovery,
  );
}
