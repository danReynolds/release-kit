import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'model.dart';

/// Reads one public resource; a [check] can cancel it. Providers take this as
/// a parameter so tests can serve releases without a network.
typedef HttpsFetch =
    Future<Uint8List> Function(
      Uri uri,
      int maxBytes, {
      InstallationCheck? check,
    });

/// Cancels read-only checks without waiting for a network timeout on UI exit.
class InstallationCheck {
  final _close = <void Function()>{};
  bool cancelled = false;
  void add(void Function() close) {
    if (cancelled) {
      close();
    } else {
      _close.add(close);
    }
  }

  void remove(void Function() close) => _close.remove(close);
  void cancel() {
    cancelled = true;
    for (final close in _close.toList()) {
      close();
    }
    _close.clear();
  }
}

/// Reads a public pub.dev or GitHub resource over HTTPS, following redirects
/// only between those hosts, bounded in size and time. A check gives up after
/// 15 seconds; a download may take three minutes.
Future<Uint8List> fetchHttps(
  Uri uri,
  int maxBytes, {
  InstallationCheck? check,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  void close() => client.close(force: true);
  check?.add(close);
  final deadline = Timer(
    check == null ? const Duration(minutes: 3) : const Duration(seconds: 15),
    close,
  );
  try {
    for (var redirects = 0; redirects < 6; redirects++) {
      if (uri.scheme != 'https' ||
          uri.port != 443 ||
          uri.userInfo.isNotEmpty ||
          !(const {
                'pub.dev',
                'github.com',
                'api.github.com',
              }.contains(uri.host) ||
              uri.host.endsWith('.githubusercontent.com'))) {
        throw const InstallationFailure(
          'A download left the supported pub.dev and GitHub HTTPS hosts.',
        );
      }
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 30));
      request.followRedirects = false;
      request.headers.set('User-Agent', 'rk-installation');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers.value('location');
        if (location == null) {
          throw const InstallationFailure('A redirect has no destination.');
        }
        uri = uri.resolve(location);
        await response.drain<void>().timeout(const Duration(seconds: 10));
        continue;
      }
      if (response.statusCode != 200) {
        throw InstallationFailure(
          '${uri.host} returned HTTP ${response.statusCode}.',
          'Installed versions are still available. Retry later, or check the '
              'public release. Private GitHub downloads are not supported yet.',
        );
      }
      final data = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (data.length + chunk.length > maxBytes) {
          throw const InstallationFailure(
            'A download exceeded its size limit.',
          );
        }
        data.add(chunk);
      }
      return data.takeBytes();
    }
    throw const InstallationFailure('A download was redirected too often.');
  } finally {
    check?.remove(close);
    deadline.cancel();
    client.close(force: true);
  }
}
