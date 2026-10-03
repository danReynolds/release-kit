import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../package_archive.dart';
import 'archive_replay.dart';
import 'hosted_discovery.dart';
import 'package_archive.dart';

/// Downloads one already-selected external coordinate. Native metadata fixes
/// its digest and complete original manifest before any bytes can enter a
/// stage. A signed fetch URL is transient and never part of archive identity.
abstract final class DartHostedArchive {
  /// Verifies an exact public coordinate against the original staged manifest
  /// and compressed bytes. This never populates a consumer's native cache.
  static Future<DartReplayArchive> fetchPublic({
    required String registry,
    required DartPackageManifest manifest,
    required String expectedSha256,
    Duration timeout = const Duration(minutes: 2),
    int maxMetadataBytes = 16 * 1024 * 1024,
    int maxCompressedBytes = 128 * 1024 * 1024,
  }) async {
    final source = dartHostedRegistry(registry);
    final client = HttpClient()..connectionTimeout = timeout;
    final deadline = Timer(timeout, () => client.close(force: true));
    late final DartDiscoveredPackage selected;
    try {
      final uri = Uri.parse(
        '$source/api/packages/${Uri.encodeComponent(manifest.name)}'
        '/versions/${Uri.encodeComponent(manifest.version)}',
      );
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.pub.v2+json',
      );
      request.followRedirects = false;
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw StateError(
          'public coordinate ${manifest.name} ${manifest.version} at $source '
          'answered ${response.statusCode}',
        );
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        if (bytes.length + chunk.length > maxMetadataBytes) {
          throw StateError('public coordinate metadata exceeds the byte limit');
        }
        bytes.addAll(chunk);
      }
      Object? metadata;
      try {
        metadata = jsonDecode(utf8.decode(bytes));
      } on FormatException {
        throw const FormatException('public coordinate metadata is malformed');
      }
      selected = DartDiscoveredPackage.fromHostedMetadata(
        registry: source,
        metadata: metadata,
      );
      selected.manifest.requireSameManifest(manifest);
      if (selected.archiveSha256 != expectedSha256) {
        throw StateError(
          'public archive bytes differ from staged ${manifest.name} ${manifest.version}',
        );
      }
    } on HttpException {
      throw StateError(
        'public coordinate HTTP request failed for ${manifest.name}',
      );
    } on SocketException {
      throw StateError(
        'public coordinate connection failed for ${manifest.name}',
      );
    } on TimeoutException {
      throw StateError(
        'public coordinate request timed out for ${manifest.name}',
      );
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
    return fetch(
      selected,
      timeout: timeout,
      maxCompressedBytes: maxCompressedBytes,
    );
  }

  static Future<DartReplayArchive> fetch(
    DartDiscoveredPackage selected, {
    Duration timeout = const Duration(minutes: 2),
    int maxCompressedBytes = 128 * 1024 * 1024,
  }) async {
    final url = selected.archiveUrl;
    final digest = selected.archiveSha256;
    if (selected.candidate != null || url == null || digest == null) {
      throw ArgumentError(
        'only an authorized external coordinate can be downloaded',
      );
    }
    final directory = Directory.systemTemp.createTempSync(
      'rk-native-download-',
    );
    final client = HttpClient()..connectionTimeout = timeout;
    final deadline = Timer(timeout, () => client.close(force: true));
    try {
      final file = File('${directory.path}/archive.tar.gz');
      late final HttpClientResponse response;
      try {
        final request = await client.getUrl(url).timeout(timeout);
        // No registry session or authorization header crosses to a CDN. Native
        // archive URLs may redirect; the frozen digest authorizes the bytes.
        request.maxRedirects = 5;
        response = await request.close().timeout(timeout);
      } on Object catch (error) {
        // Redirect parsing can throw FormatException or ArgumentError with
        // the entire signed Location. Sanitize the transport boundary only;
        // archive/manifest diagnostics below retain their useful detail.
        throw StateError(
          'native archive request failed for ${selected.manifest.name} ${selected.manifest.version} (${error.runtimeType})',
        );
      }
      if (response.statusCode != HttpStatus.ok) {
        throw StateError(
          'native archive download for ${selected.manifest.name} ${selected.manifest.version} answered ${response.statusCode}',
        );
      }
      var received = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk in response.timeout(timeout)) {
          received += chunk.length;
          if (received > maxCompressedBytes) {
            throw StateError('native archive download exceeds the byte limit');
          }
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      final archive = await NativePackageArchive.read(
        file,
        expectedSha256: digest,
        maxCompressedBytes: maxCompressedBytes,
      );
      return DartReplayArchive(
        registry: selected.registry,
        archive: archive,
        discoveredManifest: selected.manifest,
      );
    } on HttpException {
      // HTTP errors may include a signed fetch URL. Keep that temporary
      // credential out of diagnostics and persisted stage evidence.
      throw StateError(
        'native archive HTTP transfer failed for ${selected.manifest.name} ${selected.manifest.version}',
      );
    } on SocketException {
      throw StateError(
        'native archive connection failed for ${selected.manifest.name} ${selected.manifest.version}',
      );
    } on TimeoutException {
      throw StateError(
        'native archive download timed out for ${selected.manifest.name} ${selected.manifest.version}',
      );
    } finally {
      deadline.cancel();
      client.close(force: true);
      directory.deleteSync(recursive: true);
    }
  }
}
