import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../engine/tools.dart';
import 'archive_replay.dart';
import 'dependencies.dart';
import 'package_configuration.dart';
import 'resolution_graph.dart';

/// Resolves an ordinary hosted consumer before that consumer is published.
/// Only its exact prospective archive enters the otherwise empty native cache.
/// Every dependency comes from its original public source, without stage
/// overrides, inherited locks, helper snapshots or metadata shadow servers.
abstract final class DartPublicConsumer {
  static Future<DartResolutionGraph> resolve({
    required DartReplayArchive consumer,
    required Tools tools,
    required String compiler,
    required String defaultRegistry,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final registry = dartHostedRegistry(defaultRegistry);
    final prospectiveRegistry = dartHostedRegistry(consumer.registry);
    final directory = Directory.systemTemp.createTempSync(
      'rk-public-consumer-',
    );
    try {
      final cache = Directory('${directory.path}/cache')..createSync();
      final root = Directory('${directory.path}/root')..createSync();
      final random = Random.secure();
      final name =
          'rk_public_probe_${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
      final originalEnvironment =
          consumer.discoveredManifest.fields['environment'];
      final manifest = jsonEncode({
        'name': name,
        'publish_to': 'none',
        'environment': {
          'sdk':
              originalEnvironment is Map && originalEnvironment['sdk'] is String
              ? originalEnvironment['sdk']
              : '^3.10.4',
        },
        'dependencies': {
          consumer.name: {
            'hosted': {'name': consumer.name, 'url': prospectiveRegistry},
            'version': consumer.version,
          },
        },
      });
      File('${root.path}/pubspec.yaml').writeAsStringSync(manifest);
      final input = File('${directory.path}/consumer.tar.gz')
        ..writeAsBytesSync(consumer.archive.bytes, flush: true);
      final environment = {
        'PUB_CACHE': cache.path,
        'PUB_HOSTED_URL': registry,
        'PUB_ENVIRONMENT': 'rk-public-consumer',
        'PUB_SUMMARY_ONLY': '0',
      };
      final preload = await tools.run(
        compiler,
        ['--suppress-analytics', 'pub', 'cache', 'preload', input.path],
        workingDirectory: root.path,
        environment: {...environment, 'PUB_HOSTED_URL': prospectiveRegistry},
        timeout: timeout,
      );
      _requireSuccess('preloading the prospective consumer', preload);
      // This is solely the prospective package binding. No dependency version
      // is inherited or pinned. Pub may update it, so verify its exact identity
      // and extraction after get instead of using --enforce-lockfile.
      File('${root.path}/pubspec.lock').writeAsStringSync(
        jsonEncode({
          'packages': {
            consumer.name: {
              'dependency': 'direct main',
              'description': {
                'name': consumer.name,
                'url': prospectiveRegistry,
                'sha256': consumer.archive.sha256,
              },
              'source': 'hosted',
              'version': consumer.version,
            },
          },
        }),
      );
      final get = await tools.run(
        compiler,
        const [
          '--suppress-analytics',
          'pub',
          'get',
          '--no-example',
          '--no-precompile',
        ],
        workingDirectory: root.path,
        environment: environment,
        timeout: timeout,
      );
      _requireSuccess('resolving the public runtime dependencies', get);
      if (File('${root.path}/pubspec.yaml').readAsStringSync() != manifest ||
          FileSystemEntity.typeSync(
                '${root.path}/pubspec_overrides.yaml',
                followLinks: false,
              ) !=
              FileSystemEntityType.notFound) {
        throw StateError('public probe root or overrides changed');
      }
      final graph = DartResolutionGraph.fromJson(
        DartResolutionGraph.read(root).toJson(),
      );
      final prospective = graph.packages[consumer.name];
      if (graph.roots.length != 1 ||
          !graph.roots.contains(name) ||
          prospective?.version != consumer.version ||
          prospective?.source != dartRegistryIdentity(prospectiveRegistry) ||
          graph.packages.values.any(
            (package) =>
                package.name != name &&
                (package.dependencies.contains(name) ||
                    (!package.source.startsWith('hosted:') &&
                        !package.source.startsWith('sdk:'))),
          )) {
        throw StateError(
          'public consumer changed its prospective identity or uses an unsupported source',
        );
      }
      graph.requireArchives({consumer.name: consumer.archive.sha256});
      final location = dartPackageLocations(root)[consumer.name];
      if (location == null ||
          location.root.scheme != 'file' ||
          location.root.hasQuery ||
          location.root.hasFragment ||
          location.packageUri != 'lib/') {
        throw StateError('public consumer package configuration is invalid');
      }
      final installed = Directory.fromUri(
        location.root,
      ).resolveSymbolicLinksSync();
      final cacheRoot = cache.resolveSymbolicLinksSync();
      if (!installed.startsWith('$cacheRoot${Platform.pathSeparator}')) {
        throw StateError('public consumer escaped its isolated archive cache');
      }
      consumer.archive.requireExtracted(Directory(installed));
      return graph;
    } finally {
      directory.deleteSync(recursive: true);
    }
  }
}

void _requireSuccess(String operation, ToolResult result) {
  if (!result.ok) {
    throw StateError(
      'native Pub failed while $operation:\n${result.transcript}',
    );
  }
}
