import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tar/tar.dart';

import '../../engine/native_dependencies.dart';
import '../../engine/canonical_json.dart';
import '../../engine/tools.dart';
import '../../transforms/digest.dart';
import 'dependencies.dart';
import 'dependency_lock.dart';
import 'development_source.dart';
import 'package_archive.dart';
import 'resolution_graph.dart';
import 'version_constraints.dart';

export 'dependencies.dart' show dartHostedRegistry;

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
    this.developmentSource,
    this.archiveUrl,
    this.archiveSha256,
    this.retracted = false,
  });
  final String registry;
  final DartPackageManifest manifest;
  final DartDiscoveryCandidate? candidate;
  final DartDevelopmentSource? developmentSource;
  final Uri? archiveUrl;
  final String? archiveSha256;
  final bool retracted;

  /// Restores metadata without a fetch credential or source authorization.
  /// A frozen external selection must be reauthorized at its exact registry
  /// coordinate before it is adopted by a later invocation.
  factory DartDiscoveredPackage.fromJson(Object? value) {
    if (value is! Map ||
        value.keys.any(
          (key) => !const {
            'registry',
            'manifest',
            'manifest_sha256',
            'candidate',
            'development_source',
            'archive_sha256',
          }.contains(key),
        ) ||
        value['registry'] is! String ||
        value['manifest'] is! Map) {
      throw const FormatException('invalid frozen native package');
    }
    final registry = _registry(value['registry'] as String);
    final development = value.containsKey('development_source')
        ? DartDevelopmentSource.fromJson(value['development_source'])
        : null;
    final manifest = development == null
        ? DartPackageManifest.fromMap(value['manifest'])
        : DartPackageManifest.developmentSource(value['manifest']);
    if (development != null) {
      development.manifest.requireSameManifest(manifest);
      if (development.registry != registry) {
        throw const FormatException('development source registry differs');
      }
    }
    if (manifest.sha256 != value['manifest_sha256']) {
      throw const FormatException('frozen native manifest digest differs');
    }
    final isCandidate = value.containsKey('candidate');
    final digest = value['archive_sha256'];
    if ([
              isCandidate,
              development != null,
              value.containsKey('archive_sha256'),
            ].where((present) => present).length !=
            1 ||
        (value.containsKey('archive_sha256') &&
            (digest is! String ||
                !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)))) {
      throw const FormatException('invalid frozen native package provenance');
    }
    return DartDiscoveredPackage._(
      registry: registry,
      manifest: manifest,
      candidate: isCandidate
          ? DartDiscoveryCandidate(
              provider: NativeCandidate.fromJson(value['candidate']),
              registry: registry,
              manifest: manifest,
            )
          : null,
      developmentSource: development,
      archiveSha256: digest as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'registry': registry,
    'manifest': manifest.fields,
    'manifest_sha256': manifest.sha256,
    if (candidate case final local?) 'candidate': local.provider.toJson(),
    if (developmentSource case final source?)
      'development_source': source.toJson(),
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

  /// Structural restore only; no native solve or registry authentication occurs.
  factory DartDiscoveryResult.fromJson(Object? value) {
    if (value is! Map ||
        value.length != 2 ||
        !value.containsKey('graph') ||
        value['packages'] is! Map) {
      throw const FormatException('invalid frozen native discovery');
    }
    final graph = DartResolutionGraph.fromJson(value['graph']);
    final packages = <String, DartDiscoveredPackage>{};
    for (final entry in (value['packages'] as Map).entries) {
      final selected = DartDiscoveredPackage.fromJson(entry.value);
      final node = graph.packages[entry.key];
      if (entry.key != selected.manifest.name ||
          node == null ||
          node.version != selected.manifest.version ||
          node.source != dartRegistryIdentity(selected.registry)) {
        throw const FormatException(
          'frozen native metadata disagrees with graph',
        );
      }
      packages[entry.key as String] = selected;
    }
    for (final node in graph.packages.values) {
      if (node.archiveSha256 != null ||
          (node.source.startsWith('hosted:') &&
              !packages.containsKey(node.name)) ||
          (!node.source.startsWith('hosted:') &&
              node.source != 'root' &&
              !node.source.startsWith('sdk:'))) {
        throw const FormatException(
          'unsupported or incomplete frozen discovery graph',
        );
      }
    }
    return DartDiscoveryResult._(graph, packages);
  }

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
    Iterable<DartDevelopmentSource> developmentSources = const [],
    DartDependencyLock? lock,
  }) async {
    final helpers = developmentSources.toList();
    final providers = candidates.toList();
    final promotedPaths = <String, List<String>>{};
    while (true) {
      final session = _Session(
        this,
        root,
        providers,
        developmentSources: helpers,
        lock: lock,
      );
      try {
        return await session.resolve();
      } on _RuntimeDevelopmentSources catch (promotion) {
        // Re-solve from the original lock with fresh metadata/cache. A source
        // helper never gets relabeled as archive evidence when a runtime path
        // appears; ordinary candidate/hosted policy must supply real bytes.
        promotedPaths.addAll(promotion.paths);
        final count = helpers.length;
        helpers.removeWhere(
          (source) => promotion.names.contains(source.manifest.name),
        );
        if (count == helpers.length) rethrow;
      } on StateError catch (error) {
        if (promotedPaths.isEmpty) rethrow;
        throw StateError(
          'development source requires a runtime archive on '
          '${promotedPaths.values.map((path) => path.join(' -> ')).join('; ')}. '
          'Archive resolution failed after removing source-helper eligibility. '
          'RK does not search older bridge versions to restore that eligibility.\n$error',
        );
      } finally {
        await session.close();
      }
    }
  }

  /// Reauthorize exact frozen choices against current authoritative source
  /// candidates and current registry metadata. Native Pub verifies the original
  /// requirements using only these versions; it cannot select a newer release
  /// or turn a previously hosted binding into a now-available local candidate.
  /// The caller must separately authenticate root/source intent and stage proof.
  Future<DartDiscoveryResult> verifyFrozen({
    required DartPackageManifest root,
    required DartDiscoveryResult frozen,
    Iterable<DartDiscoveryCandidate> candidates = const [],
    Iterable<DartDevelopmentSource> developmentSources = const [],
    DartDependencyLock? lock,
  }) async {
    final current = candidates.toList();
    final selected = <DartDiscoveryCandidate>[];
    final helpers = <DartDevelopmentSource>[];
    final currentHelpers = developmentSources.toList();
    for (final package in frozen.packages.values) {
      if (package.developmentSource case final recorded?) {
        final matches = currentHelpers.where(
          (source) =>
              source.manifest.name == recorded.manifest.name &&
              source.registry == recorded.registry,
        );
        if (matches.length != 1) {
          throw StateError(
            'frozen development source is not a current workspace member',
          );
        }
        matches.single.requireSameSource(recorded);
        helpers.add(matches.single);
      }
      final provider = package.candidate;
      if (provider == null) continue;
      final matches = current.where(
        (candidate) =>
            CanonicalJson.encode(candidate.provider.toJson()) ==
            CanonicalJson.encode(provider.provider.toJson()),
      );
      if (matches.length != 1) {
        throw StateError(
          'frozen provider ${package.manifest.name} ${package.manifest.version} does not match one current configured candidate',
        );
      }
      final candidate = matches.single;
      candidate.manifest.requireSameManifest(package.manifest);
      selected.add(candidate);
    }
    final session = _Session(
      this,
      root,
      selected,
      developmentSources: helpers,
      frozen: frozen,
      lock: lock,
    );
    try {
      final result = await session.resolve();
      result.graph.requireSameSelection(frozen.graph);
      return result;
    } finally {
      await session.close();
    }
  }
}

final class _Session {
  _Session(
    this.options,
    this.root,
    this.candidates, {
    required this.developmentSources,
    this.frozen,
    this.lock,
  });
  final DartHostedDiscovery options;
  final DartPackageManifest root;
  final List<DartDiscoveryCandidate> candidates;
  final List<DartDevelopmentSource> developmentSources;
  final DartDiscoveryResult? frozen;
  final DartDependencyLock? lock;
  final HttpClient client = HttpClient();
  final Directory directory = Directory.systemTemp.createTempSync(
    'rk-dart-discovery-',
  );
  final Map<String, Future<_Shadow>> shadows = {};
  final Map<(String, String), Future<List<DartDiscoveredPackage>>> listings =
      {};
  final Map<(String, String), DartDiscoveredPackage> available = {};
  final Map<(String, String), DartDiscoveredPackage> pinned = {};
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
      available[key] = DartDiscoveredPackage._(
        registry: candidate.registry,
        manifest: candidate.manifest,
        candidate: candidate,
      );
      if (frozen != null) pinned[key] = available[key]!;
    }
    final helperKeys = <(String, String)>{};
    for (final source in developmentSources) {
      final key = (source.registry, source.manifest.name);
      if (!helperKeys.add(key) || source.manifest.name == root.name) {
        throw StateError('duplicate or root development source');
      }
      available[key] = DartDiscoveredPackage._(
        registry: source.registry,
        manifest: source.manifest,
        developmentSource: source,
      );
      if (frozen != null) pinned[key] = available[key]!;
    }
    _requireNoRuntimeSources([root]);
    _requireSupported(root, isRoot: true);
    _selectFrom([root], root: root.name);
    if (frozen case final recorded?) {
      // Authenticate before starting Pub. A digest/source refusal is final,
      // not a transient shadow-server error Pub should retry for half a minute.
      await _authorizeFrozen(recorded).timeout(const Duration(minutes: 2));
    }
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
    for (var pass = 0; pass <= available.length; pass++) {
      // Each preference refinement starts a fresh native solve. Pub's metadata
      // cache must not retain the unrestricted listing from the previous pass.
      if (lock case final original?) {
        File('${directory.path}/pubspec.lock').writeAsStringSync(
          await original.forDiscovery(
            (registry) async => (await _shadow(registry)).url,
            defaultRegistry: options.defaultRegistry,
          ),
        );
      }
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
        final chosen = matches.single;
        // Pub can unify a root by name regardless of the incoming registry.
        // Inspect original edges in every selected manifest: a helper may
        // reach the root indirectly through an ordinary hosted bridge.
        final dependencies = chosen.manifest.fields['dependencies'];
        if (dependencies is Map && dependencies.containsKey(root.name)) {
          final backEdge = _hosted(
            dependencies[root.name],
            options.defaultRegistry,
          );
          if (backEdge == null ||
              backEdge.registry != options.defaultRegistry) {
            throw StateError(
              'native package ${chosen.manifest.name} has a root back-edge with a different source',
            );
          }
        }
        selected[package.name] = chosen;
      }
      _requireNoRuntimeSources([
        root,
        ...selected.values.map((value) => value.manifest),
      ]);
      final prior = pinned.length;
      _selectFrom([
        root,
        ...selected.values.map((value) => value.manifest),
      ], root: root.name);
      if (pinned.length == prior) {
        for (final package in selected.values) {
          if (package.candidate == null && package.developmentSource == null) {
            lock?.requireExternalIntegrity(
              name: package.manifest.name,
              registry: package.registry,
              version: package.manifest.version,
              sha256: package.archiveSha256!,
            );
          }
        }
        return DartDiscoveryResult._(graph, selected);
      }
      File('${directory.path}/pubspec.lock').deleteSync();
      Directory('${directory.path}/.dart_tool').deleteSync(recursive: true);
    }
    throw StateError('native candidate discovery did not converge');
  }

  void _requireNoRuntimeSources(Iterable<DartPackageManifest> manifests) {
    final byName = {for (final manifest in manifests) manifest.name: manifest};
    final paths = <String, List<String>>{
      root.name: [root.name],
    };
    final pending = [root.name];
    while (pending.isNotEmpty) {
      final name = pending.removeLast();
      final dependencies = byName[name]?.fields['dependencies'];
      if (dependencies is! Map) continue;
      for (final dependency in dependencies.keys.cast<String>()) {
        if (paths.containsKey(dependency)) continue;
        paths[dependency] = [...paths[name]!, dependency];
        pending.add(dependency);
      }
    }
    final promoted = <String, List<String>>{
      for (final source in developmentSources)
        if (paths.containsKey(source.manifest.name))
          source.manifest.name: paths[source.manifest.name]!,
    };
    if (promoted.isNotEmpty) {
      if (frozen != null) {
        throw StateError(
          'frozen development source is runtime reachable: ${promoted.keys.join(', ')}',
        );
      }
      throw _RuntimeDevelopmentSources(promoted);
    }
  }

  Future<void> _authorizeFrozen(DartDiscoveryResult recorded) async {
    final registries = {
      options.defaultRegistry,
      ...recorded.packages.values.map((package) => package.registry),
    };
    if (registries.length > options.maxRegistries) {
      throw StateError('native verification exceeds the registry limit');
    }
    final packages = recorded.packages.values.toList();
    for (var start = 0; start < packages.length; start += 8) {
      await Future.wait([
        for (final package in packages.skip(start).take(8))
          _listing(package.registry, package.manifest.name),
      ]);
    }
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
    final expected = frozen?.packages[name];
    if (frozen != null && (expected == null || expected.registry != registry)) {
      throw StateError(
        'native verification requested an unfrozen dependency $name',
      );
    }
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
          '$registry/api/packages/${Uri.encodeComponent(name)}'
          '${expected == null ? '' : '/versions/${Uri.encodeComponent(expected.manifest.version)}'}',
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
              (expected == null &&
                  (metadata['name'] != name ||
                      metadata['versions'] is! List))) {
            throw FormatException(
              'registry returned invalid metadata for $name',
            );
          }
          final versions = <String>{};
          for (final item
              in expected == null ? metadata['versions'] as List : [metadata]) {
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
        values.add(candidate);
      }
      if (expected != null) {
        final matches = values
            .where(
              (value) => value.manifest.version == expected.manifest.version,
            )
            .toList();
        if (matches.length != 1 ||
            CanonicalJson.encode(matches.single.toJson()) !=
                CanonicalJson.encode(expected.toJson())) {
          throw StateError(
            'registry or configured source no longer authorizes frozen ${expected.manifest.name} ${expected.manifest.version} with its recorded manifest and archive digest',
          );
        }
        return matches;
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
            : versions.where((value) => identical(value, chosen)).toList();
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

final class _RuntimeDevelopmentSources implements Exception {
  _RuntimeDevelopmentSources(this.paths);
  final Map<String, List<String>> paths;
  Set<String> get names => paths.keys.toSet();
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

String _registry(String value) => dartHostedRegistry(value);

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
