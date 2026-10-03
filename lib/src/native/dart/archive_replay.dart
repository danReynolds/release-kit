import 'dart:convert';
import 'dart:io';

import '../../engine/tools.dart';
import '../../engine/canonical_json.dart';
import '../../transforms/digest.dart';
import '../package_archive.dart';
import 'dependencies.dart';
import 'dependency_lock.dart';
import 'hosted_discovery.dart';
import 'replay_sources.dart';
import 'package_archive.dart';
import 'resolution_graph.dart';

/// One real native archive, selected during discovery and verified against its
/// original manifest. No source checkout can satisfy this input.
final class DartReplayArchive {
  DartReplayArchive({
    required this.registry,
    required this.archive,
    required this.discoveredManifest,
  }) {
    DartPackageManifest.fromArchive(
      archive,
    ).requireSameManifest(discoveredManifest);
  }

  final String registry;
  final NativePackageArchive archive;
  final DartPackageManifest discoveredManifest;
  String get name => discoveredManifest.name;
  String get version => discoveredManifest.version;
  String get source => dartRegistryIdentity(registry);
}

/// Shared isolated native environment for packaging and compilation. The
/// caller supplies a private source mirror and already-discovered native graph.
/// Only selected verified archives enter its cache; get runs offline against
/// original source identities and unmodified dependency requirements.
final class DartArchiveReplay {
  DartArchiveReplay._({
    required this.root,
    required this.tools,
    required this.compiler,
    required this.defaultRegistry,
    required this.directory,
    required this.archives,
    required this.developmentSources,
  });

  final Directory root;
  final Tools tools;
  final String compiler;
  final String defaultRegistry;
  final Directory directory;
  final List<DartReplayArchive> archives;
  final DartReplaySources? developmentSources;
  late final DartResolutionGraph graph;
  late final String _packageConfiguration;
  late final String _rootManifestSha256;
  late final String? _overridesSha256;
  bool _closed = false;

  static Future<DartArchiveReplay> prepare({
    required Directory root,
    required Tools tools,
    required String compiler,
    required String defaultRegistry,
    required DartResolutionGraph discovered,
    required Iterable<DartReplayArchive> archives,
    DartReplaySources? developmentSources,
    DartDiscoveryResult? discovery,
    DartDependencyLock? discoveryLock,
  }) async {
    final originalRoot = File('${root.path}/pubspec.yaml').readAsBytesSync();
    final originalRootSha256 = Sha256.hex(originalRoot);
    final selected = archives.toList();
    final names = <String>{};
    for (final input in selected) {
      final package = discovered.packages[input.name];
      if (!names.add(input.name) ||
          package == null ||
          package.version != input.version ||
          package.source != input.source) {
        throw StateError(
          'native replay archive does not match discovery: ${input.name} ${input.version}',
        );
      }
    }
    if (developmentSources case final sources?) {
      sources.verify();
      if (discovery == null) {
        throw StateError(
          'native source replay requires original discovery metadata',
        );
      }
      discovered.requireSameSelection(discovery.graph);
      final consumer = root.resolveSymbolicLinksSync();
      final sourceRoot = sources.root.path;
      if (consumer == sourceRoot ||
          consumer.startsWith('$sourceRoot${Platform.pathSeparator}') ||
          sourceRoot.startsWith('$consumer${Platform.pathSeparator}')) {
        throw StateError(
          'development snapshot overlaps mutable consumer source',
        );
      }
      for (final binding in sources.bindings.values) {
        final package = discovered.packages[binding.manifest.name];
        if (!names.add(binding.manifest.name) ||
            package == null ||
            package.version != binding.manifest.version ||
            package.source != dartRegistryIdentity(binding.registry)) {
          throw StateError('native source replay differs from discovery');
        }
      }
      final recorded = discovery.packages.values
          .where((package) => package.developmentSource != null)
          .map((package) => package.manifest.name)
          .toSet();
      if (recorded.length != sources.bindings.length ||
          !recorded.containsAll(sources.bindings.keys)) {
        throw StateError(
          'native source replay must include exactly the frozen helpers',
        );
      }
      await DartHostedDiscovery(
        tools: tools,
        compiler: compiler,
        defaultRegistry: defaultRegistry,
      ).verifyPrepared(
        root: DartPackageManifest.parse(utf8.decode(originalRoot)),
        frozen: discovery,
        archives: selected.map(
          (archive) => (
            registry: archive.registry,
            manifest: archive.discoveredManifest,
            sha256: archive.archive.sha256,
          ),
        ),
        developmentSources: sources.bindings.values,
        lock: discoveryLock,
      );
      sources.verify();
      if (Sha256.hex(File('${root.path}/pubspec.yaml').readAsBytesSync()) !=
          originalRootSha256) {
        throw StateError(
          'native replay root changed during constraint verification',
        );
      }
      final overrideFile = File('${root.path}/pubspec_overrides.yaml');
      final overrides = overrideFile.existsSync()
          ? readDartYamlDocument(overrideFile.readAsStringSync())
          : <String, Object?>{};
      if (overrides.keys.any(
            (key) => key != 'resolution' && key != 'workspace',
          ) ||
          (overrides.containsKey('resolution') &&
              overrides['resolution'] != null) ||
          (overrides.containsKey('workspace') &&
              (overrides['workspace'] is! List ||
                  (overrides['workspace'] as List).isNotEmpty))) {
        throw StateError('native helper replay found unauthorized overrides');
      }
      overrideFile.writeAsStringSync(
        jsonEncode({
          ...overrides,
          'dependency_overrides': {
            for (final name in sources.bindings.keys)
              name: {'path': sources.directoryFor(name).path},
          },
        }),
      );
    }
    final hosted = discovered.packages.values
        .where((package) => package.source.startsWith('hosted:'))
        .map((package) => package.name)
        .toSet();
    if (hosted.length != names.length || !hosted.containsAll(names)) {
      throw StateError(
        'native replay requires every discovered archive or verified development source',
      );
    }
    final replay = DartArchiveReplay._(
      root: root,
      tools: tools,
      compiler: compiler,
      defaultRegistry: defaultRegistry,
      directory: Directory.systemTemp.createTempSync('rk-dart-replay-'),
      archives: List.unmodifiable(selected),
      developmentSources: developmentSources,
    );
    try {
      replay._rootManifestSha256 = originalRootSha256;
      replay._overridesSha256 = replay._readOverridesDigest();
      Directory('${replay.directory.path}/cache').createSync();
      for (final (index, input) in selected.indexed) {
        final file = File('${replay.directory.path}/input-$index.tar.gz')
          ..writeAsBytesSync(input.archive.bytes, flush: true);
        final result = await tools.run(
          compiler,
          ['--suppress-analytics', 'pub', 'cache', 'preload', file.path],
          workingDirectory: root.path,
          environment: {
            ...replay.environment,
            'PUB_HOSTED_URL': input.registry,
          },
          timeout: const Duration(minutes: 2),
        );
        _requireSuccess('preloading ${input.name} ${input.version}', result);
      }
      final get = await replay._run(const [
        'pub',
        'get',
        '--offline',
        '--no-example',
        '--no-precompile',
      ], timeout: const Duration(minutes: 2));
      _requireSuccess('replaying the discovered dependency graph', get);
      final graph = DartResolutionGraph.read(root);
      replay._verifyDevelopmentLocations();
      graph.requireSameSelection(
        discovered,
        verifiedDevelopmentSources: {
          if (developmentSources case final sources?)
            for (final binding in sources.bindings.values)
              binding.manifest.name: dartRegistryIdentity(binding.registry),
        },
      );
      graph.requireArchives({
        for (final input in selected) input.name: input.archive.sha256,
      });
      replay.graph = graph;
      replay._packageConfiguration = replay._readPackageConfiguration();
      replay.verify();
      return replay;
    } on Object {
      replay.close();
      rethrow;
    }
  }

  Map<String, String> get environment => {
    'PUB_CACHE': '${directory.path}/cache',
    'PUB_HOSTED_URL': defaultRegistry,
    'PUB_ENVIRONMENT': 'rk-dependency-replay',
    'PUB_SUMMARY_ONLY': '0',
  };

  Future<ToolResult> run(List<String> arguments, {Duration? timeout}) {
    if (_closed) throw StateError('native replay environment is closed');
    verify();
    return _run(arguments, timeout: timeout).then((result) {
      verify();
      return result;
    });
  }

  Future<ToolResult> _run(List<String> arguments, {Duration? timeout}) {
    return tools.run(
      compiler,
      ['--suppress-analytics', ...arguments],
      workingDirectory: root.path,
      environment: environment,
      timeout: timeout,
    );
  }

  /// Recheck after packaging/compilation. The cache directory and package
  /// configuration are private scratch, not independent binding authority.
  void verify() {
    if (_closed) throw StateError('native replay environment is closed');
    if (Sha256.hex(File('${root.path}/pubspec.yaml').readAsBytesSync()) !=
        _rootManifestSha256) {
      throw StateError('native replay root manifest changed');
    }
    if (_readOverridesDigest() != _overridesSha256) {
      throw StateError('native replay overrides changed');
    }
    _verifyDevelopmentLocations();
    DartResolutionGraph.read(root).requireSameArtifacts(graph);
    if (_readPackageConfiguration() != _packageConfiguration) {
      throw StateError('native replay package configuration changed');
    }
    final locations = _locations();
    final cache = Directory(
      '${directory.path}/cache',
    ).resolveSymbolicLinksSync();
    for (final input in archives) {
      final uri = locations[input.name]?.root;
      if (uri == null || uri.scheme != 'file') {
        throw StateError('native replay omits ${input.name}');
      }
      final installed = Directory.fromUri(uri);
      final canonical = installed.resolveSymbolicLinksSync();
      if (!canonical.startsWith('$cache${Platform.pathSeparator}')) {
        throw StateError(
          'native replay resolved ${input.name} outside its isolated archive cache',
        );
      }
      input.archive.requireExtracted(Directory(canonical));
    }
  }

  Map<String, ({Uri root, String packageUri})> _locations() {
    final configFile = File('${root.path}/.dart_tool/package_config.json');
    final config = jsonDecode(configFile.readAsStringSync());
    if (config is! Map ||
        config['configVersion'] != 2 ||
        config['packages'] is! List) {
      throw const FormatException(
        'native replay has no supported package configuration',
      );
    }
    final locations = <String, ({Uri root, String packageUri})>{};
    for (final package in config['packages'] as List) {
      if (package is! Map ||
          package['name'] is! String ||
          package['rootUri'] is! String ||
          package['packageUri'] is! String ||
          locations.containsKey(package['name'])) {
        throw const FormatException(
          'invalid native replay package configuration',
        );
      }
      locations[package['name'] as String] = (
        root: configFile.uri.resolve(package['rootUri'] as String),
        packageUri: package['packageUri'] as String,
      );
    }
    return locations;
  }

  void _verifyDevelopmentLocations() {
    final sources = developmentSources;
    if (sources == null) return;
    sources.verify();
    final locations = _locations();
    for (final name in sources.bindings.keys) {
      final location = locations[name];
      if (location == null ||
          location.root.scheme != 'file' ||
          location.root.hasQuery ||
          location.root.hasFragment ||
          location.packageUri != 'lib/' ||
          Directory.fromUri(location.root).resolveSymbolicLinksSync() !=
              sources.directoryFor(name).path) {
        throw StateError(
          'native helper $name resolved outside its verified source directory',
        );
      }
    }
  }

  String? _readOverridesDigest() {
    final file = File('${root.path}/pubspec_overrides.yaml');
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw StateError('native replay overrides are not a regular file');
    }
    return Sha256.hex(file.readAsBytesSync());
  }

  String _readPackageConfiguration() => CanonicalJson.encode(
    jsonDecode(
      File('${root.path}/.dart_tool/package_config.json').readAsStringSync(),
    ),
  );

  void close() {
    if (_closed) return;
    _closed = true;
    directory.deleteSync(recursive: true);
  }
}

void _requireSuccess(String operation, ToolResult result) {
  if (!result.ok) {
    throw StateError(
      'native Pub failed while $operation:\n${result.transcript}',
    );
  }
}
