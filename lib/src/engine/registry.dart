import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'verdict.dart';
import 'version.dart';

/// What pub.dev says about a package.
class RegistryPackage {
  RegistryPackage({required this.name, required this.versions});

  final String name;

  /// Published versions, newest publication first.
  final List<PublishedVersion> versions;

  bool get exists => versions.isNotEmpty;

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

/// Reads a package registry. Read-only: nothing here publishes.
///
/// An interface so a command can be exercised without a network, and so a
/// second registry — npm, RubyGems — attaches later without touching the
/// commands above it.
abstract class RegistryReader {
  /// The package, or null when it has never existed.
  Future<RegistryPackage?> lookup(String name);

  /// How the coordinate this release would publish to stands.
  Future<Inspection> inspect(String name, Version version);
}

/// Reads pub.dev. Read-only: nothing here publishes.
///
/// Every failure is reported as [Verdict.unknown] rather than absence — a
/// timeout is not evidence that a version does not exist.
class Registry implements RegistryReader {
  Registry({HttpClient? client, this.host = 'pub.dev'})
      : _client = client ?? HttpClient();

  final HttpClient _client;
  final String host;

  final _cache = <String, RegistryPackage?>{};

  /// Looks up [name], returning null when the package has never existed and
  /// throwing [RegistryUnavailable] when rk could not find out.
  @override
  Future<RegistryPackage?> lookup(String name) async {
    if (_cache.containsKey(name)) return _cache[name];

    final uri = Uri.https(host, '/api/packages/$name');

    // Reading the body and making sense of it are as fallible as connecting:
    // a captive portal answers 200 with HTML, and a truncated response
    // decodes to nothing. Everything is inside the guard so no failure here
    // can escape as a crash — the promise this class makes is that rk finds
    // out or says it could not.
    try {
      final request = await _client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response =
          await request.close().timeout(const Duration(seconds: 20));

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
          .timeout(const Duration(seconds: 20));

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
      // pub.dev accepts a package's first version only from an interactive
      // publish, so this is a fact about the ceremony, not a version check.
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

/// rk could not find out, which is not the same as finding nothing.
class RegistryUnavailable implements Exception {
  RegistryUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}
