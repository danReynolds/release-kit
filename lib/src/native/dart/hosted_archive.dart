import 'dart:async';
import 'dart:io';

import '../package_archive.dart';
import 'archive_replay.dart';
import 'hosted_discovery.dart';

/// Downloads one already-selected external coordinate. Native metadata fixes
/// its digest and complete original manifest before any bytes can enter a
/// stage. A signed fetch URL is transient and never part of archive identity.
abstract final class DartHostedArchive {
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
