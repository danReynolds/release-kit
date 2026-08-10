import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';

import '../transforms/digest.dart';
import 'resolve.dart';
import 'source_tree.dart';
import 'verdict.dart';
import 'version.dart';

/// Exact source-level inspection for a package publication target.
///
/// The provider adapter implements this; the release engine depends only on
/// the question it needs answered.
abstract interface class PublicationInspector {
  Future<Inspection> inspectProject(
    ResolvedProject project, {
    SourceTree? expectedSource,
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
    required this.archiveUrl,
    required this.archiveSha256,
  });

  final Version version;
  final DateTime? published;
  final String? archiveUrl;
  final String? archiveSha256;
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

  /// How the coordinate this release would publish to stands.
  Future<Inspection> inspect(String name, Version version);

  /// Discards what is known about [name].
  ///
  /// Called after rk itself acts on the package. Successful lookups are
  /// cached for the run — one inspection sweep should not hammer the registry
  /// — but after rk publishes, its own knowledge is stale by its own hand,
  /// and a post-act verification that reads the memo the pre-act inspection
  /// wrote is a verification that cannot fire.
  void forget(String name);

  /// The bytes of [version]'s published archive, proven against the digest
  /// the registry states for it.
  ///
  /// Throws [RegistryUnavailable] when rk could not fetch them, and
  /// [ArchiveTampered] when it could and they do not match the stated digest
  /// — different failures, opposite instructions: one says try again, the
  /// other says stop and look.
  Future<List<int>> archive(PublishedVersion version);
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
    this.archiveResponseTimeout = const Duration(seconds: 60),
    this.archiveBodyTimeout = const Duration(seconds: 120),
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
  final Duration archiveResponseTimeout;
  final Duration archiveBodyTimeout;

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
            archiveUrl: _text(entry['archive_url']),
            archiveSha256: _text(entry['archive_sha256']),
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

  /// Classifies the coordinate this release would publish to.
  @override
  Future<Inspection> inspect(String name, Version version) async {
    final RegistryPackage? package;
    try {
      package = await lookup(name);
    } on RegistryUnavailable catch (error) {
      return Inspection.unknown(error.message);
    }

    if (package == null) {
      // Absent, and the detail says which kind: the package itself is not
      // there, so releasing claims the name as well as the version.
      return const Inspection.absent(detail: 'the package does not exist yet');
    }

    final published = package.at(version);
    if (published == null) {
      return const Inspection.absent();
    }
    return Inspection.exact(
      detail: published.published == null
          ? 'already published'
          : 'published ${_ago(published.published!)}',
    );
  }

  @override
  void forget(String name) => _cache.remove(name);

  @override
  Future<List<int>> archive(PublishedVersion version) async {
    final url = version.archiveUrl;
    if (url == null) {
      throw RegistryUnavailable(
        '$host lists no archive for ${version.version}',
      );
    }

    final List<int> bytes;
    try {
      final request =
          await _client.getUrl(Uri.parse(url)).timeout(connectTimeout);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/octet-stream',
      );
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final response = await request.close().timeout(archiveResponseTimeout);
      if (response.statusCode != 200) {
        throw RegistryUnavailable(
          'the archive answered ${response.statusCode}',
        );
      }
      bytes = await response
          .fold<BytesBuilder>(BytesBuilder(), (b, chunk) => b..add(chunk))
          .then((b) => b.takeBytes())
          .timeout(archiveBodyTimeout);
    } on RegistryUnavailable {
      rethrow;
    } on Object catch (error) {
      throw RegistryUnavailable('the archive could not be fetched: $error');
    }

    final stated = version.archiveSha256;
    if (stated != null && Sha256.hex(bytes) != stated.toLowerCase()) {
      // Not unavailability: the registry served bytes that do not match its
      // own stated digest. Retrying will not help and proceeding would verify
      // source against content nobody vouches for.
      throw ArchiveTampered(
        stated: stated,
        actual: Sha256.hex(bytes),
      );
    }
    return bytes;
  }

  void close() => _client.close(force: true);

  static String _ago(DateTime when) {
    final days = DateTime.now().toUtc().difference(when.toUtc()).inDays;
    if (days < 1) return 'today';
    if (days == 1) return 'yesterday';
    if (days < 60) return '$days days ago';
    final months = days ~/ 30;
    if (months < 24) return '$months months ago';
    return '${days ~/ 365} years ago';
  }
}

/// The registry served an archive that does not match its own stated digest.
class ArchiveTampered implements Exception {
  ArchiveTampered({required this.stated, required this.actual});

  final String stated;
  final String actual;

  @override
  String toString() =>
      'the archive does not match the digest the registry states for it '
      '(stated $stated, got $actual)';
}

/// rk could not find out, which is not the same as finding nothing.
class RegistryUnavailable implements Exception {
  RegistryUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}
