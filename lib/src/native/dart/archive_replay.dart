import 'dart:convert';
import 'dart:io';

import '../../engine/tools.dart';
import '../../engine/canonical_json.dart';
import '../../transforms/digest.dart';
import '../package_archive.dart';
import 'dependencies.dart';
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
  });

  final Directory root;
  final Tools tools;
  final String compiler;
  final String defaultRegistry;
  final Directory directory;
  final List<DartReplayArchive> archives;
  late final DartResolutionGraph graph;
  late final String _packageConfiguration;
  late final String _rootManifestSha256;
  bool _closed = false;

  static Future<DartArchiveReplay> prepare({
    required Directory root,
    required Tools tools,
    required String compiler,
    required String defaultRegistry,
    required DartResolutionGraph discovered,
    required Iterable<DartReplayArchive> archives,
  }) async {
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
    final hosted = discovered.packages.values
        .where((package) => package.source.startsWith('hosted:'))
        .map((package) => package.name)
        .toSet();
    if (hosted.length != names.length || !hosted.containsAll(names)) {
      throw StateError(
        'native replay requires every discovered hosted archive',
      );
    }
    final replay = DartArchiveReplay._(
      root: root,
      tools: tools,
      compiler: compiler,
      defaultRegistry: defaultRegistry,
      directory: Directory.systemTemp.createTempSync('rk-dart-replay-'),
      archives: List.unmodifiable(selected),
    );
    try {
      replay._rootManifestSha256 = Sha256.hex(
        File('${root.path}/pubspec.yaml').readAsBytesSync(),
      );
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
      ]);
      _requireSuccess('replaying the discovered dependency graph', get);
      final graph = DartResolutionGraph.read(root);
      graph.requireSameSelection(discovered);
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

  Future<ToolResult> run(List<String> arguments) {
    if (_closed) throw StateError('native replay environment is closed');
    verify();
    return _run(arguments).then((result) {
      verify();
      return result;
    });
  }

  Future<ToolResult> _run(List<String> arguments) {
    return tools.run(
      compiler,
      ['--suppress-analytics', ...arguments],
      workingDirectory: root.path,
      environment: environment,
      timeout: const Duration(minutes: 2),
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
    DartResolutionGraph.read(root).requireSameArtifacts(graph);
    if (_readPackageConfiguration() != _packageConfiguration) {
      throw StateError('native replay package configuration changed');
    }
    final configFile = File('${root.path}/.dart_tool/package_config.json');
    final config = jsonDecode(configFile.readAsStringSync());
    if (config is! Map ||
        config['configVersion'] != 2 ||
        config['packages'] is! List) {
      throw const FormatException(
        'native replay has no supported package configuration',
      );
    }
    final locations = <String, Uri>{};
    for (final package in config['packages'] as List) {
      if (package is! Map ||
          package['name'] is! String ||
          package['rootUri'] is! String ||
          locations.containsKey(package['name'])) {
        throw const FormatException(
          'invalid native replay package configuration',
        );
      }
      locations[package['name'] as String] = configFile.uri.resolve(
        package['rootUri'] as String,
      );
    }
    final cache = Directory(
      '${directory.path}/cache',
    ).resolveSymbolicLinksSync();
    for (final input in archives) {
      final uri = locations[input.name];
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
