import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'model.dart';

typedef MetadataFetch = Future<Uint8List> Function(Uri, int);

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

Future<Uint8List> fetchInstallationMetadata(
  Uri uri,
  int maxBytes, {
  InstallationCheck? check,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  void close() => client.close(force: true);
  check?.add(close);
  final deadline = Timer(
    const Duration(seconds: 15),
    () => client.close(force: true),
  );
  try {
    if (uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        !{'api.github.com', 'pub.dev'}.contains(uri.host)) {
      throw const InstallationFailure('Unsupported update metadata host.');
    }
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    request.headers.set('User-Agent', 'rk-installation');
    final response = await request.close();
    if (response.statusCode != 200) {
      throw InstallationFailure(
        'Update check returned HTTP ${response.statusCode}.',
        'Installed versions are still available. Retry later.',
      );
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const InstallationFailure(
          'Update metadata exceeded its size limit.',
        );
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  } finally {
    check?.remove(close);
    deadline.cancel();
    client.close(force: true);
  }
}
