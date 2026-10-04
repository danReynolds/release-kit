import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:mime/mime.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:yaml/yaml.dart';

/// A local implementation of Pub's actual hosted upload/download protocol.
///
/// Transport and origin are supplied by the caller. Native qualification uses
/// an isolated loopback origin, and every upload, finalize and archive URL refers
/// to that service. The pub.dev default is only convenient for protocol tests
/// that inspect response URLs without following them.
///
/// Protocol: https://github.com/dart-lang/pub/blob/master/doc/repository-spec-v2.md
/// Native client: https://github.com/dart-lang/pub/blob/master/lib/src/command/lish.dart
final class PubRegistryFixture {
  PubRegistryFixture(
    this.storage, {
    this.token = 'rk-local-fixture-token',
    this.origin = 'https://pub.dev',
    this.onEvent,
  }) {
    storage.createSync(recursive: true);
    final archives = Directory('${storage.path}/archives');
    if (archives.existsSync()) {
      for (final file in archives.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('/package.tar.gz')) continue;
        final package = _readPackage(file.readAsBytesSync(), file);
        if (_archivePath(package.name, package.version) != file.path) {
          throw StateError('stored fixture archive has the wrong coordinate');
        }
        _committed[package.coordinate] = package;
      }
    }
  }

  static const maxArchiveBytes = 8 * 1024 * 1024;
  static const maxExpandedBytes = 32 * 1024 * 1024;

  final Directory storage;
  final String token;
  final String origin;
  final List<PubRegistryEvent> events = [];

  /// An observation barrier for scenario control, after the event is recorded.
  /// The callback must not change the response being observed.
  void Function(PubRegistryEvent)? onEvent;
  final Map<String, PubRegistryPackage> _committed = {};
  final Map<String, _Upload> _uploads = {};
  var _sequence = 0;

  /// Faults are package-scoped; clear the corresponding set to recover.
  final Set<String> rejectUploads = {};
  final Set<String> loseFinalizeResponses = {};
  final Set<String> unavailableArchives = {};
  final Set<String> hiddenCoordinates = {};
  final Set<String> hiddenListings = {};

  Map<String, PubRegistryPackage> get committed => Map.unmodifiable(_committed);

  File archive(String name, String version) =>
      _committed['$name@$version']!.archive;

  /// Seeds background or deliberately conflicting packages only. Packages
  /// released by the operation under test must arrive through HTTP upload.
  void seedArchive(File archive) {
    final bytes = archive.readAsBytesSync();
    final package = _readPackage(bytes, archive);
    final stored = _commit(package, bytes);
    _record('seeded', package: stored);
  }

  Future<void> handle(HttpRequest request) async {
    try {
      final path = request.uri.pathSegments;
      if (request.uri.hasQuery || request.uri.hasFragment) {
        await _deny(request, HttpStatus.notFound, 'unexpected route');
      } else if (request.method == 'GET' &&
          request.uri.path == '/api/packages/versions/new') {
        if (!await _authenticate(request)) return;
        final ticket = (++_sequence).toString();
        _uploads[ticket] = _Upload();
        _record('initiated', path: request.uri.path);
        await _json(request, {
          'url': '$origin/_uploads/$ticket',
          'fields': {'ticket': ticket},
        });
      } else if (request.method == 'POST' &&
          path.length == 2 &&
          path[0] == '_uploads') {
        await _upload(request, path[1]);
      } else if (request.method == 'GET' &&
          path.length == 3 &&
          path[0] == '_uploads' &&
          path[2] == 'finalize') {
        if (!await _authenticate(request)) return;
        await _finalize(request, path[1]);
      } else if (request.method == 'GET' &&
          path.length == 3 &&
          path[0] == 'api' &&
          path[1] == 'packages') {
        await _listing(request, path[2]);
      } else if (request.method == 'GET' &&
          path.length == 5 &&
          path[0] == 'api' &&
          path[1] == 'packages' &&
          path[3] == 'versions') {
        final package = _committed['${path[2]}@${path[4]}'];
        if (package == null || hiddenCoordinates.contains(path[2])) {
          await _jsonError(request, HttpStatus.notFound, 'package not found');
          // Recovery scenarios may interrupt RK once this server has answered
          // its real confirmation read, without changing RK's
          // production propagation deadline or inventing a registry failure.
          _record(
            'coordinate_missing',
            name: path[2],
            version: path[4],
            path: request.uri.path,
            status: HttpStatus.notFound,
          );
        } else {
          _record('coordinate_read', package: package);
          await _json(request, _metadata(package));
        }
      } else if (request.method == 'GET' &&
          path.length == 4 &&
          path[0] == 'packages' &&
          path[2] == 'versions' &&
          path[3].endsWith('.tar.gz')) {
        final version = path[3].substring(0, path[3].length - 7);
        final package = _committed['${path[1]}@$version'];
        if (package == null) {
          await _jsonError(request, HttpStatus.notFound, 'archive not found');
        } else if (unavailableArchives.contains(package.name)) {
          await _jsonError(request, HttpStatus.notFound, 'archive not visible');
          _record('archive_unavailable', package: package);
        } else {
          _record('downloaded', package: package);
          request.response.headers.contentType = ContentType.binary;
          request.response.add(package.archive.readAsBytesSync());
          await request.response.close();
        }
      } else {
        await _deny(request, HttpStatus.notFound, 'unexpected route');
      }
    } on Object catch (_) {
      // Never echo arbitrary headers, credential material, or archive text.
      _record('invalid_request', path: request.uri.path);
      try {
        await _jsonError(
          request,
          HttpStatus.badRequest,
          'invalid fixture request',
        );
      } on Object {
        // A deliberately closed or disconnected client needs no second reply.
      }
    }
  }

  Future<bool> _authenticate(HttpRequest request) async {
    if (request.headers.value(HttpHeaders.authorizationHeader) ==
        'Bearer $token') {
      return true;
    }
    request.response.headers.set(
      HttpHeaders.wwwAuthenticateHeader,
      'Bearer realm="pub", message="fixture token required"',
    );
    await _deny(request, HttpStatus.unauthorized, 'fixture token required');
    return false;
  }

  Future<void> _upload(HttpRequest request, String ticket) async {
    final upload = _uploads[ticket];
    if (upload == null) {
      await _deny(request, HttpStatus.notFound, 'unknown upload ticket');
      return;
    }
    final contentType = request.headers.contentType;
    final boundary = contentType?.parameters['boundary'];
    if (contentType?.mimeType != 'multipart/form-data' ||
        boundary == null ||
        boundary.isEmpty ||
        boundary.length > 200) {
      await _deny(request, HttpStatus.badRequest, 'expected multipart upload');
      return;
    }
    final body = await _readLimited(
      request,
      maxArchiveBytes + 8192,
    ).timeout(const Duration(seconds: 15));
    Uint8List? bytes;
    String? fieldTicket;
    var fields = 0;
    await for (final part in MimeMultipartTransformer(
      boundary,
    ).bind(Stream.value(body))) {
      fields++;
      final disposition = HeaderValue.parse(
        part.headers['content-disposition'] ?? '',
      );
      final name = disposition.parameters['name'];
      final value = await _readLimited(part, maxArchiveBytes);
      if (disposition.value != 'form-data') {
        throw const FormatException('not form data');
      } else if (name == 'ticket' && fieldTicket == null) {
        fieldTicket = utf8.decode(value);
      } else if (name == 'file' &&
          bytes == null &&
          disposition.parameters['filename'] == 'package.tar.gz') {
        bytes = value;
      } else {
        throw const FormatException('unexpected upload field');
      }
    }
    if (fields != 2 || fieldTicket != ticket || bytes == null) {
      throw const FormatException('missing upload field');
    }
    final file = File('${storage.path}/uploads/$ticket.tar.gz');
    final package = _readPackage(bytes, file);
    // Count attempts before acceptance checks. A rejected duplicate is still a
    // real upload and must not make a no-reupload assertion falsely pass.
    _record('upload_attempted', package: package);
    if (rejectUploads.contains(package.name)) {
      _record('rejected', package: package);
      await _jsonError(
        request,
        HttpStatus.badRequest,
        'fixture rejected upload',
      );
      return;
    }
    final previous = _committed[package.coordinate];
    if (previous != null) {
      _record('rejected', package: package);
      await _jsonError(
        request,
        HttpStatus.badRequest,
        'version already published',
      );
      return;
    }
    if (upload.package != null && upload.package!.digest != package.digest) {
      await _deny(
        request,
        HttpStatus.badRequest,
        'upload ticket bytes changed',
      );
      return;
    }
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes, flush: true);
    upload.package = package;
    _record('uploaded', package: package);
    request.response.statusCode = HttpStatus.noContent;
    request.response.headers.set(
      HttpHeaders.locationHeader,
      '$origin/_uploads/$ticket/finalize',
    );
    await request.response.close();
  }

  Future<void> _finalize(HttpRequest request, String ticket) async {
    final upload = _uploads[ticket];
    final package = upload?.package;
    if (upload == null || package == null) {
      await _deny(request, HttpStatus.notFound, 'upload not found');
      return;
    }
    if (!upload.finalized) {
      if (_committed.containsKey(package.coordinate)) {
        await _jsonError(
          request,
          HttpStatus.badRequest,
          'version already published',
        );
        return;
      }
      _commit(package, package.archive.readAsBytesSync());
      upload.finalized = true;
    }
    if (loseFinalizeResponses.contains(package.name)) {
      // Keep dropping every native retry for this ticket. Otherwise native Pub
      // could repair the response itself and RK's reconciliation would not run.
      _record('response_lost', package: package);
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.destroy();
      return;
    }
    _record('finalized', package: package);
    await _json(request, {
      'success': {'message': 'Fixture accepted ${package.coordinate}.'},
    });
  }

  PubRegistryPackage _commit(PubRegistryPackage package, List<int> bytes) {
    if (_committed.containsKey(package.coordinate)) {
      throw StateError('fixture versions are immutable');
    }
    final destination = File(_archivePath(package.name, package.version));
    destination.parent.createSync(recursive: true);
    final pending = File('${destination.path}.pending');
    pending.writeAsBytesSync(bytes, flush: true);
    pending.renameSync(destination.path);
    final stored = PubRegistryPackage._(
      name: package.name,
      version: package.version,
      digest: package.digest,
      manifest: package.manifest,
      archive: destination,
    );
    _committed[stored.coordinate] = stored;
    _record('committed', package: stored);
    return stored;
  }

  Future<void> _listing(HttpRequest request, String name) async {
    final versions =
        _committed.values.where((package) => package.name == name).toList()
          ..sort(
            (a, b) =>
                Version.parse(a.version).compareTo(Version.parse(b.version)),
          );
    if (versions.isEmpty || hiddenListings.contains(name)) {
      await _jsonError(request, HttpStatus.notFound, 'package not found');
      return;
    }
    _record('listing_read', package: versions.last);
    await _json(request, {
      'name': name,
      'latest': _metadata(versions.last),
      'versions': versions.map(_metadata).toList(),
    });
  }

  Map<String, Object?> _metadata(PubRegistryPackage package) => {
    'version': package.version,
    'pubspec': package.manifest,
    'archive_url':
        '$origin/packages/${package.name}/versions/${package.version}.tar.gz',
    'archive_sha256': package.digest,
  };

  String _archivePath(String name, String version) =>
      '${storage.path}/archives/$name/$version/package.tar.gz';

  PubRegistryPackage _readPackage(List<int> bytes, File archive) {
    if (bytes.length > maxArchiveBytes) {
      throw const FormatException('archive too large');
    }
    final expanded = _LimitedBytes(maxExpandedBytes);
    gzip.decoder.startChunkedConversion(expanded)
      ..add(bytes)
      ..close();
    final contents = TarDecoder().decodeBytes(expanded.bytes.takeBytes());
    final manifests = contents.files.where(
      (entry) =>
          entry.isFile &&
          entry.name.replaceFirst(RegExp(r'^(\./)+'), '') == 'pubspec.yaml',
    );
    final manifest = jsonDecode(
      jsonEncode(loadYaml(utf8.decode(manifests.single.content))),
    );
    if (manifest is! Map<String, dynamic>) {
      throw const FormatException('invalid manifest');
    }
    final name = manifest['name'];
    final version = manifest['version'];
    if (name is! String ||
        !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name) ||
        version is! String ||
        Version.parse(version).toString() != version ||
        version.contains('/') ||
        version.contains('\\')) {
      throw const FormatException('invalid package coordinate');
    }
    return PubRegistryPackage._(
      name: name,
      version: version,
      digest: Sha256.hex(bytes),
      manifest: Map.unmodifiable(manifest),
      archive: archive,
    );
  }

  Future<void> _deny(HttpRequest request, int status, String message) async {
    _record('denied', path: request.uri.path, status: status);
    await _jsonError(request, status, message);
  }

  Future<void> _jsonError(HttpRequest request, int status, String message) =>
      _json(request, {
        'error': {'code': 'fixture', 'message': message},
      }, status: status);

  Future<void> _json(
    HttpRequest request,
    Object value, {
    int status = HttpStatus.ok,
  }) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType(
      'application',
      'vnd.pub.v2+json',
      charset: 'utf-8',
    );
    request.response.write(jsonEncode(value));
    await request.response.close();
  }

  void _record(
    String kind, {
    PubRegistryPackage? package,
    String? name,
    String? version,
    String? path,
    int? status,
  }) {
    final event = PubRegistryEvent(
      kind: kind,
      name: package?.name ?? name,
      version: package?.version ?? version,
      digest: package?.digest,
      path: path,
      status: status,
    );
    events.add(event);
    onEvent?.call(event);
  }
}

final class PubRegistryPackage {
  const PubRegistryPackage._({
    required this.name,
    required this.version,
    required this.digest,
    required this.manifest,
    required this.archive,
  });

  final String name;
  final String version;
  final String digest;
  final Map<String, Object?> manifest;
  final File archive;
  String get coordinate => '$name@$version';
}

final class PubRegistryEvent {
  const PubRegistryEvent({
    required this.kind,
    this.name,
    this.version,
    this.digest,
    this.path,
    this.status,
  });

  final String kind;
  final String? name;
  final String? version;
  final String? digest;
  final String? path;
  final int? status;

  Map<String, Object?> toJson() => {
    'kind': kind,
    if (name != null) 'name': name,
    if (version != null) 'version': version,
    if (digest != null) 'sha256': digest,
    if (path != null) 'path': path,
    if (status != null) 'status': status,
  };

  @override
  String toString() =>
      '$kind ${name ?? path ?? ""}${version == null ? "" : "@$version"}';
}

final class _Upload {
  PubRegistryPackage? package;
  bool finalized = false;
}

Future<Uint8List> _readLimited(Stream<List<int>> stream, int limit) async {
  final sink = _LimitedBytes(limit);
  await for (final chunk in stream) {
    sink.add(chunk);
  }
  return sink.bytes.takeBytes();
}

final class _LimitedBytes extends ByteConversionSink {
  _LimitedBytes(this.limit);
  final int limit;
  final bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > limit) {
      throw const FormatException('fixture size limit');
    }
    bytes.add(chunk);
  }

  @override
  void close() {}
}
