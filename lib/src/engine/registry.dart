import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'resolve.dart';
import 'verdict.dart';
import 'version.dart';

/// Exact source-level inspection for a package publication target.
///
/// The provider adapter implements this; the release engine depends only on
/// the question it needs answered.
abstract interface class PublicationInspector {
  Future<Inspection> inspectProject(
    ResolvedProject project, {
    String? expectedArchiveSha256,
  });
}

/// What pub.dev says about a package.
class RegistryPackage {
  RegistryPackage({required this.name, required this.versions});

  final String name;

  /// Published versions, newest publication first.
  final List<PublishedVersion> versions;

  PublishedVersion? get latest {
    PublishedVersion? best;
    for (final published in versions) {
      if (best == null || published.version > best.version) best = published;
    }
    return best;
  }

  PublishedVersion? at(Version version) {
    for (final published in versions) {
      if (published.version == version) return published;
    }
    return null;
  }
}

class PublishedVersion {
  PublishedVersion({
    required this.version,
    required this.published,
    required this.archiveSha256,
    this.repository,
  });

  final Version version;
  final DateTime? published;
  final String? archiveSha256;

  /// The project repository declared by this published version's pubspec.
  final String? repository;
}

/// Reads a package registry. Read-only: nothing here publishes. The target
/// module owns the matching preflight, act, and read-back policy.
///
/// An interface so a command can be exercised without a network, and so a
/// second registry — npm, RubyGems — attaches later without touching the
/// commands above it.
abstract class RegistryReader {
  /// The package, or null when it has never existed.
  Future<RegistryPackage?> lookup(String name);

  /// Discards what is known about [name].
  ///
  /// Called after rk itself acts on the package. Successful lookups are
  /// cached for the run — one inspection sweep should not hammer the registry
  /// — but after rk publishes, its own knowledge is stale by its own hand,
  /// and a post-act verification that reads the memo the pre-act inspection
  /// wrote is a verification that cannot fire.
  void forget(String name);
}

/// Reads pub.dev. Read-only: nothing here publishes. The pub.dev target module
/// owns the matching preflight, act, and read-back policy.
///
/// Every failure is reported as [Verdict.unknown] rather than absence — a
/// timeout is not evidence that a version does not exist.
class Registry implements RegistryReader {
  Registry({
    HttpClient? client,
    this.host = 'pub.dev',
    this.secure = true,
    this.connectTimeout = const Duration(seconds: 20),
    this.responseTimeout = const Duration(seconds: 20),
  }) : _client = client ?? HttpClient();

  final HttpClient _client;
  final String host;

  /// Bounds opening the socket as well as waiting for provider bytes.
  ///
  /// `HttpClient.connectionTimeout` does not cover every custom client and
  /// proxy path. Timing out the future returned by `getUrl` keeps status from
  /// waiting forever before it even has a request to close.
  final Duration connectTimeout;
  final Duration responseTimeout;

  /// Whether to speak TLS. Always true in production; false lets a test point
  /// rk at a local server and prove the promise this class makes — that a
  /// failure becomes `unknown` and never `absent` — against the code that
  /// ships rather than against a fake that hand-writes the answer.
  final bool secure;

  final _cache = <String, RegistryPackage?>{};

  static const _acceptV2 = 'application/vnd.pub.v2+json';
  static const _userAgent =
      'release-kit (+https://github.com/danReynolds/release-kit)';

  /// Looks up [name], returning null when the package has never existed and
  /// throwing [RegistryUnavailable] when rk could not find out.
  @override
  Future<RegistryPackage?> lookup(String name) async {
    if (_cache.containsKey(name)) return _cache[name];

    final uri = secure
        ? Uri.https(host, '/api/packages/$name')
        : Uri.http(host, '/api/packages/$name');

    // Reading the body and making sense of it are as fallible as connecting:
    // a captive portal answers 200 with HTML, and a truncated response
    // decodes to nothing. Everything is inside the guard so no failure here
    // can escape as a crash — the promise this class makes is that rk finds
    // out or says it could not.
    try {
      final request = await _client.getUrl(uri).timeout(connectTimeout);
      request.headers.set(HttpHeaders.acceptHeader, _acceptV2);
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final response = await request.close().timeout(responseTimeout);

      // Only an authenticated negative means "not there".
      if (response.statusCode == 404) return _cache[name] = null;
      if (response.statusCode != 200) {
        throw RegistryUnavailable(
          '$host answered ${response.statusCode} for $name',
        );
      }

      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(responseTimeout);

      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw RegistryUnavailable('$host returned something unreadable');
      }
      final entries = decoded['versions'];
      if (entries is! List) {
        throw RegistryUnavailable('$host listed no versions for $name');
      }

      final versions = <PublishedVersion>[];
      for (final entry in entries) {
        if (entry is! Map) continue;
        final parsed = Version.tryParse(_text(entry['version']) ?? '');
        if (parsed == null) continue;
        versions.add(
          PublishedVersion(
            version: parsed,
            published: DateTime.tryParse(_text(entry['published']) ?? ''),
            archiveSha256: _text(entry['archive_sha256']),
            repository: entry['pubspec'] is Map
                ? _text((entry['pubspec'] as Map)['repository'])
                : null,
          ),
        );
      }

      return _cache[name] = RegistryPackage(name: name, versions: versions);
    } on RegistryUnavailable {
      rethrow;
    } on Object catch (error) {
      throw RegistryUnavailable('$host could not be read: $error');
    }
  }

  /// A field only when it really is text, so a number where a string was
  /// expected does not throw.
  static String? _text(Object? value) => value is String ? value : null;

  @override
  void forget(String name) => _cache.remove(name);

  void close() => _client.close(force: true);
}

/// rk could not find out, which is not the same as finding nothing.
class RegistryUnavailable implements Exception {
  RegistryUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}
