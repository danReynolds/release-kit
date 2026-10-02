import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tar/tar.dart';

import '../../engine/native_dependencies.dart';
import '../../engine/pubspec.dart';
import '../../engine/tools.dart';
import '../../transforms/digest.dart';
import 'dependencies.dart';
import 'package_archive.dart';
import 'resolution_graph.dart';
import 'version_constraints.dart';

/// A caller-authorized provider in the selected preparation scope. A manifest
/// is solver metadata, not an artifact; production must still supply its exact
/// verified archive after scheduling the selected provider.
final class DartDiscoveryCandidate {
  DartDiscoveryCandidate({
    required this.provider,
    required String registry,
    required this.manifest,
  }) : registry = _registry(registry) {
    if (provider.package.ecosystem != 'dart' ||
        provider.package.name != manifest.name ||
        provider.version != manifest.version ||
        provider.package.source != dartRegistryIdentity(this.registry)) {
      throw ArgumentError('native candidate and original manifest disagree');
    }
  }
  final NativeCandidate provider;
  final String registry;
  final DartPackageManifest manifest;
}

/// Original metadata for one native selected slot. Shadow archive hashes and
/// loopback addresses deliberately do not become reusable package identities.
final class DartDiscoveredPackage {
  DartDiscoveredPackage._({
    required this.registry,
    required this.manifest,
    this.candidate,
    this.archiveUrl,
    this.archiveSha256,
    this.retracted = false,
  });
  final String registry;
  final DartPackageManifest manifest;
  final DartDiscoveryCandidate? candidate;
  final Uri? archiveUrl;
  final String? archiveSha256;
  final bool retracted;

  Map<String, Object?> toJson() => {
    'registry': registry,
    'manifest': manifest.fields,
    'manifest_sha256': manifest.sha256,
    if (candidate case final local?) 'candidate': local.provider.toJson(),
    // Signed archive URLs expire; freeze the registry coordinate and digest,
    // never a temporary fetch credential.
    if (archiveSha256 case final hash?) 'archive_sha256': hash,
  };
}

final class DartDiscoveryResult {
  DartDiscoveryResult._(this.graph, Map<String, DartDiscoveredPackage> packages)
    : packages = Map.unmodifiable(packages);
  final DartResolutionGraph graph;
  final Map<String, DartDiscoveredPackage> packages;

  Map<String, Object?> toJson() => {
    'graph': graph.toJson(includeIntegrity: false),
    'packages': {
      for (final name in packages.keys.toList()..sort())
        name: packages[name]!.toJson(),
    },
  };
}

/// Ephemeral, metadata-only Pub view. Native Pub still chooses versions and
/// backtracks. Each original registry has a distinct shadow; only source URLs
/// change, never constraints. No credentials, archive payload or publication
/// calls are proxied. Every listener, cache and root belongs to this solve.
final class DartHostedDiscovery {
  DartHostedDiscovery({
    required this.tools,
    required this.compiler,
    String defaultRegistry = 'https://pub.dev',
    this.timeout = const Duration(seconds: 30),
    this.maxMetadataBytes = 16 * 1024 * 1024,
    this.maxTotalMetadataBytes = 128 * 1024 * 1024,
    this.maxRegistries = 64,
    this.maxPackages = 2048,
  }) : defaultRegistry = _registry(defaultRegistry);

  final Tools tools;
  final String compiler;
  final String defaultRegistry;
  final Duration timeout;
  final int maxMetadataBytes;
  final int maxTotalMetadataBytes;
  final int maxRegistries;
  final int maxPackages;

  Future<DartDiscoveryResult> resolve({
    required DartPackageManifest root,
    Iterable<DartDiscoveryCandidate> candidates = const [],
  }) async {
    final session = _Session(this, root, candidates.toList());
    try {
      return await session.resolve();
    } finally {
      await session.close();
    }
  }
}

final class _Session {
  _Session(this.options, this.root, this.candidates);
  final DartHostedDiscovery options;
  final DartPackageManifest root;
  final List<DartDiscoveryCandidate> candidates;
  final HttpClient client = HttpClient();
  final Directory directory = Directory.systemTemp.createTempSync(
    'rk-dart-discovery-',
  );
  final Map<String, Future<_Shadow>> shadows = {};
  final Map<(String, String), Future<List<DartDiscoveredPackage>>> listings =
      {};
  final Map<(String, String), DartDiscoveryCandidate> available = {};
  final Map<(String, String), DartDiscoveryCandidate> pinned = {};
  final Map<String, String> aliases = {};
  final List<Object> errors = [];
  final Set<Future<void>> responses = {};
  int received = 0;
  bool closed = false;

  Future<DartDiscoveryResult> resolve() async {
    client.connectionTimeout = options.timeout;
    for (final candidate in candidates) {
      final key = (candidate.registry, candidate.manifest.name);
      if (available.containsKey(key)) {
        throw StateError('multiple eligible native providers for ${key.$2}');
      }
      available[key] = candidate;
    }
    _requireSupported(root, isRoot: true);
    _selectFrom([root], root: root.name);
    final shadow = await _shadow(options.defaultRegistry);
    final mapped = await _remap(root, includeDevelopment: true);
    // A root may be a workspace member in source. The owned discovery root
    // resolves by itself, without changing the original packaged manifest.
    File(
      '${directory.path}/pubspec.yaml',
    ).writeAsStringSync(jsonEncode(mapped));
    if (root.fields.containsKey('resolution') ||
        root.fields.containsKey('workspace')) {
      File(
        '${directory.path}/pubspec_overrides.yaml',
      ).writeAsStringSync('resolution: null\nworkspace: []\n');
    }
    for (var pass = 0; pass <= candidates.length; pass++) {
      // Each preference refinement starts a fresh native solve. Pub's metadata
      // cache must not retain the unrestricted listing from the previous pass.
      final result = await options.tools.run(
        options.compiler,
        const [
          '--suppress-analytics',
          'pub',
          'get',
          '--no-example',
          '--no-precompile',
        ],
        workingDirectory: directory.path,
        environment: {
          'PUB_HOSTED_URL': shadow.url,
          'PUB_CACHE': '${directory.path}/cache-$pass',
          'PUB_ENVIRONMENT': 'rk-dependency-discovery',
          'PUB_SUMMARY_ONLY': '0',
        },
        timeout: const Duration(minutes: 2),
      );
      // Failed speculative prefetches must not invalidate a successful native
      // solve. Every selected node still requires complete metadata below.
      if (!result.ok) {
        throw StateError(
          'native dependency discovery failed:\n${errors.join('\n')}\n${result.transcript}',
        );
      }
      final graph = DartResolutionGraph.read(
        directory,
        registryAliases: aliases,
      );
      final selected = <String, DartDiscoveredPackage>{};
      for (final package in graph.packages.values) {
        if (graph.roots.contains(package.name) ||
            package.source.startsWith('sdk:')) {
          continue;
        }
        final matches = <DartDiscoveredPackage>[];
        for (final entry in listings.entries) {
          if (entry.key.$2 != package.name ||
              dartRegistryIdentity(entry.key.$1) != package.source) {
            continue;
          }
          matches.addAll(
            (await entry.value).where(
              (value) => value.manifest.version == package.version,
            ),
          );
        }
        if (matches.length != 1) {
          throw StateError(
            'native discovery has no unique original metadata for ${package.name}',
          );
        }
        _requireSupported(matches.single.manifest, isRoot: false);
        selected[package.name] = matches.single;
      }
      final prior = pinned.length;
      _selectFrom([
        root,
        ...selected.values.map((value) => value.manifest),
      ], root: root.name);
      if (pinned.length == prior) return DartDiscoveryResult._(graph, selected);
      File('${directory.path}/pubspec.lock').deleteSync();
      Directory('${directory.path}/.dart_tool').deleteSync(recursive: true);
    }
    throw StateError('native candidate discovery did not converge');
  }

  void _selectFrom(
    Iterable<DartPackageManifest> manifests, {
    required String root,
  }) {
    final incoming = <(String, String), List<String>>{};
    for (final manifest in manifests) {
      final dependencies = _dependencies(
        manifest,
        includeDevelopment: manifest.name == root,
      );
      for (final dependency in dependencies.entries) {
        final hosted = _hosted(dependency.value, options.defaultRegistry);
        if (hosted == null) continue;
        (incoming[(hosted.registry, dependency.key)] ??= []).add(
          hosted.constraint,
        );
      }
    }
    for (final entry in incoming.entries) {
      final candidate = available[entry.key];
      if (candidate != null &&
          entry.value.every(
            (constraint) =>
                dartConstraintAllows(constraint, candidate.manifest.version),
          )) {
        pinned[entry.key] = candidate;
      }
    }
  }

  Future<_Shadow> _shadow(String registry) {
    if (closed) throw StateError('native discovery environment is closed');
    final canonical = _registry(registry);
    if (!shadows.containsKey(canonical) &&
        shadows.length >= options.maxRegistries) {
      throw StateError('native discovery exceeds the registry limit');
    }
    return shadows.putIfAbsent(canonical, () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final shadow = _Shadow(canonical, server);
      aliases[shadow.url] = canonical;
      server.listen((request) {
        final pending = _respond(
          shadow,
          request,
        ).catchError((Object error) => errors.add(error));
        responses.add(pending);
        unawaited(pending.whenComplete(() => responses.remove(pending)));
      });
      return shadow;
    });
  }

  Future<Map<String, Object?>> _remap(
    DartPackageManifest manifest, {
    bool includeDevelopment = false,
  }) async {
    final result = {...manifest.fields};
    for (final section in [
      'dependencies',
      if (includeDevelopment) 'dev_dependencies',
    ]) {
      final original = result[section];
      if (original == null) continue;
      if (original is! Map<String, Object?>) {
        throw const FormatException('invalid native dependency map');
      }
      final mapped = <String, Object?>{};
      for (final entry in original.entries) {
        final hosted = _hosted(entry.value, options.defaultRegistry);
        if (hosted == null) {
          mapped[entry.key] = entry.value;
          continue;
        }
        final destination = (await _shadow(hosted.registry)).url;
        final details = entry.value is Map
            ? Map<String, Object?>.from(entry.value as Map)
            : <String, Object?>{'version': entry.value ?? 'any'};
        final source = details['hosted'];
        mapped[entry.key] = {
          ...details,
          'hosted': source is Map
              ? {...source, 'url': destination}
              : source is String
              ? destination
              // Hosted URL shorthand requires a >=2.15 language lower bound.
              // Use long form when injecting a default source. Preserve an
              // explicit shorthand's syntax so its native SDK gate still runs.
              : {'name': entry.key, 'url': destination},
        };
      }
      result[section] = mapped;
    }
    return result;
  }

  Future<List<DartDiscoveredPackage>> _listing(String registry, String name) {
    final key = (registry, name);
    if (!listings.containsKey(key) && listings.length >= options.maxPackages) {
      throw StateError('native discovery exceeds the package limit');
    }
    return listings.putIfAbsent(key, () async {
      final candidate = available[key];
      // A pinned provider is authoritative for this private solve. No public
      // listing is needed, including for an entirely unpublished package.
      final values = <DartDiscoveredPackage>[];
      if (!pinned.containsKey(key)) {
        final uri = Uri.parse(
          '$registry/api/packages/${Uri.encodeComponent(name)}',
        );
        final request = await client.getUrl(uri).timeout(options.timeout);
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/vnd.pub.v2+json',
        );
        request.followRedirects = false;
        final response = await request.close().timeout(options.timeout);
        if (response.statusCode == HttpStatus.ok) {
          final bytes = BytesBuilder(copy: false);
          await for (final chunk in response.timeout(options.timeout)) {
            received += chunk.length;
            if (bytes.length + chunk.length > options.maxMetadataBytes ||
                received > options.maxTotalMetadataBytes) {
              throw StateError('native discovery exceeds the metadata limit');
            }
            bytes.add(chunk);
          }
          final metadata = jsonDecode(utf8.decode(bytes.takeBytes()));
          if (metadata is! Map ||
              metadata['name'] != name ||
              metadata['versions'] is! List) {
            throw FormatException(
              'registry returned invalid metadata for $name',
            );
          }
          final versions = <String>{};
          for (final item in metadata['versions'] as List) {
            if (item is! Map ||
                item['version'] is! String ||
                !versions.add(item['version'] as String)) {
              throw FormatException(
                'registry returned invalid or duplicate versions for $name',
              );
            }
            final manifest = DartPackageManifest.fromMap(item['pubspec']);
            if (manifest.name != name || manifest.version != item['version']) {
              throw FormatException(
                'registry manifest coordinate disagrees for $name',
              );
            }
            // Ignore the public copy of a configured candidate coordinate.
            // Only its declared source manifest can stand for this release.
            if (candidate?.manifest.version == manifest.version) continue;
            final hash = item['archive_sha256'];
            final url = item['archive_url'];
            if (hash is! String ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
                url is! String) {
              throw FormatException(
                'registry omits native archive integrity for $name',
              );
            }
            final archiveUrl = _url(url, allowQuery: true);
            values.add(
              DartDiscoveredPackage._(
                registry: registry,
                manifest: manifest,
                archiveUrl: archiveUrl,
                archiveSha256: hash,
                retracted: item['retracted'] == true,
              ),
            );
          }
        } else if (response.statusCode == HttpStatus.notFound) {
          await response.drain<void>().timeout(options.timeout);
        } else {
          throw StateError(
            'registry $registry answered ${response.statusCode} for $name',
          );
        }
      }
      if (candidate != null) {
        values.add(
          DartDiscoveredPackage._(
            registry: registry,
            manifest: candidate.manifest,
            candidate: candidate,
          ),
        );
      }
      return values;
    });
  }

  Future<void> _respond(_Shadow shadow, HttpRequest request) async {
    try {
      if (closed || request.method != 'GET') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final path = request.uri.pathSegments;
      if (path.length == 3 && path[0] == 'api' && path[1] == 'packages') {
        final name = path[2];
        if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(name)) {
          throw const FormatException('invalid native package name');
        }
        final versions = await _listing(shadow.registry, name);
        final chosen = pinned[(shadow.registry, name)];
        final visible = chosen == null
            ? versions
            : versions.where((value) => value.candidate == chosen).toList();
        if (visible.isEmpty) {
          request.response.statusCode = HttpStatus.notFound;
          return;
        }
        final entries = <Map<String, Object?>>[];
        for (final value in visible) {
          final transformed = await _remap(value.manifest);
          final payload = _payload(transformed);
          final key = Sha256.hex(payload);
          // Only metadata gets served. No selected package implementation can
          // accidentally be compiled from this discovery cache.
          shadow.payloads[key] = payload;
          entries.add({
            'version': value.manifest.version,
            'pubspec': transformed,
            'archive_url': '${shadow.url}/archives/$key',
            'archive_sha256': key,
            if (value.retracted) 'retracted': true,
          });
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'name': name, 'versions': entries}));
      } else if (path.length == 2 &&
          path[0] == 'archives' &&
          shadow.payloads.containsKey(path[1])) {
        request.response.add(shadow.payloads[path[1]]!);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
    } on Object catch (error) {
      errors.add(error);
      request.response.statusCode = HttpStatus.badGateway;
    } finally {
      await request.response.close();
    }
  }

  Future<void> close() async {
    closed = true;
    client.close(force: true);
    for (final pending in shadows.values.toList()) {
      try {
        await (await pending).server.close(force: true);
      } on Object {
        // A listener which failed to bind has nothing to close.
      }
    }
    await Future.wait(
      responses.toList(),
    ).timeout(options.timeout, onTimeout: () => const <void>[]);
    directory.deleteSync(recursive: true);
  }
}

final class _Shadow {
  _Shadow(this.registry, this.server);
  final String registry;
  final HttpServer server;
  final Map<String, List<int>> payloads = {};
  String get url => 'http://127.0.0.1:${server.port}';
}

List<int> _payload(Map<String, Object?> manifest) {
  final bytes = utf8.encode(jsonEncode(manifest));
  late List<int> tar;
  final sink = tarConverterWith(format: OutputFormat.gnuLongName)
      .startChunkedConversion(
        ByteConversionSink.withCallback((value) => tar = value),
      );
  sink.add(TarEntry.data(TarHeader(name: 'pubspec.yaml', mode: 0x1a4), bytes));
  sink.close();
  return gzip.encode(tar);
}

Map<String, Object?> _dependencies(
  DartPackageManifest manifest, {
  required bool includeDevelopment,
}) => {
  if (manifest.fields['dependencies']
      case final Map<String, Object?> dependencies)
    ...dependencies,
  if (includeDevelopment)
    if (manifest.fields['dev_dependencies']
        case final Map<String, Object?> development)
      ...development,
};

({String registry, String constraint})? _hosted(
  Object? dependency,
  String defaultRegistry,
) {
  if (dependency is Map && ['path', 'git', 'sdk'].any(dependency.containsKey)) {
    return null;
  }
  if (dependency == null || dependency is String) {
    return (
      registry: defaultRegistry,
      constraint: dependency as String? ?? 'any',
    );
  }
  if (dependency is! Map) {
    throw const FormatException('invalid native dependency');
  }
  final source = dependency['hosted'];
  final url = source is Map ? source['url'] : source;
  final version = dependency['version'];
  if ((url != null && url is! String) ||
      (version != null && version is! String)) {
    throw const FormatException('invalid native hosted requirement');
  }
  return (
    registry: _registry(url as String? ?? defaultRegistry),
    constraint: version as String? ?? 'any',
  );
}

void _requireSupported(DartPackageManifest manifest, {required bool isRoot}) {
  final overrides = manifest.fields['dependency_overrides'];
  if (isRoot && overrides is Map && overrides.isNotEmpty) {
    throw StateError(
      'native discovery requires authorized development helpers; runtime overrides are not accepted',
    );
  }
  for (final entry in _dependencies(
    manifest,
    includeDevelopment: isRoot,
  ).entries) {
    if (entry.value case final Map value
        when value.containsKey('path') || value.containsKey('git')) {
      throw StateError(
        'native discovery needs an explicit source binding for ${manifest.name} -> ${entry.key}',
      );
    }
  }
}

String _registry(String value) {
  final canonical = canonicalPublishDestination(value);
  final normalized = canonical == 'https://pub.dartlang.org'
      ? 'https://pub.dev'
      : canonical;
  return _url(normalized).toString().replaceFirst(RegExp(r'/$'), '');
}

Uri _url(String value, {bool allowQuery = false}) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (!allowQuery && uri.hasQuery) ||
      uri.hasFragment ||
      (uri.scheme != 'https' &&
          !(uri.scheme == 'http' &&
              const {'127.0.0.1', 'localhost', '::1'}.contains(uri.host)))) {
    throw FormatException(
      'unsupported or credential-bearing native registry URL',
    );
  }
  return uri;
}
