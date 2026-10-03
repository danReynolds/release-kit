import 'dart:convert';
import 'dart:io';

import 'package:rk/src/native/dart/hosted_archive.dart';
import 'package:rk/src/native/dart/hosted_discovery.dart';
import 'package:rk/src/native/dart/package_archive.dart';
import 'package:rk/src/native/package_archive.dart';
import 'package:test/test.dart';

import 'support/native_pub_fixture.dart';

void main() {
  late NativePubFixture origin;
  late HttpServer server;
  late DartPackageManifest manifest;
  late NativePackageArchive archive;
  late Map<String, Object?> metadata;
  late List<int> servedBytes;
  late String registry;
  final paths = <String>[];
  setUp(() async {
    origin = await NativePubFixture.create();
    final root = origin.package('provider', 'provider', '0.2.0');
    origin.host(root);
    manifest = DartPackageManifest.parse(
      File('${root.path}/pubspec.yaml').readAsStringSync(),
    );
    archive = await NativePackageArchive.read(
      origin.hostedArchive('provider', '0.2.0'),
    );
    servedBytes = archive.bytes;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    registry = 'http://127.0.0.1:${server.port}/custom';
    metadata = {
      'version': manifest.version,
      'pubspec': manifest.fields,
      'archive_sha256': archive.sha256,
      'archive_url': '$registry/provider.tar.gz?token=transient-secret',
    };
    paths.clear();
    server.listen((request) async {
      expect(request.method, 'GET');
      expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
      paths.add(request.uri.path);
      if (request.uri.path == '/custom/api/packages/provider/versions/0.2.0') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(metadata));
      } else if (request.uri.path == '/custom/provider.tar.gz') {
        expect(request.uri.queryParameters['token'], 'transient-secret');
        request.response.add(servedBytes);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    await server.close(force: true);
    await origin.close();
  });

  Future<Object> fetch({int? metadataLimit, int? archiveLimit}) =>
      DartHostedArchive.fetchPublic(
        registry: registry,
        manifest: manifest,
        expectedSha256: archive.sha256,
        maxMetadataBytes: metadataLimit ?? 16 * 1024 * 1024,
        maxCompressedBytes: archiveLimit ?? 128 * 1024 * 1024,
      );

  test(
    'public exact coordinate preserves registry path and transient signed URL',
    () async {
      final result = await DartHostedArchive.fetchPublic(
        registry: registry,
        manifest: manifest,
        expectedSha256: archive.sha256,
      );
      expect(result.archive.bytes, archive.bytes);
      expect(result.registry, registry);
      expect(paths, [
        '/custom/api/packages/provider/versions/0.2.0',
        '/custom/provider.tar.gz',
      ]);
      final selected = DartDiscoveredPackage.fromHostedMetadata(
        registry: registry,
        metadata: metadata,
      );
      expect(selected.archiveUrl!.query, 'token=transient-secret');
      expect(
        jsonEncode(selected.toJson()),
        isNot(contains('transient-secret')),
      );
    },
  );

  test(
    'matching archive hash cannot hide changed original manifest metadata',
    () async {
      metadata['pubspec'] = {
        ...manifest.fields,
        'dependencies': {'concealed': 'any'},
      };
      await expectLater(
        fetch(),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'detail',
            contains('manifest'),
          ),
        ),
      );
      expect(paths, ['/custom/api/packages/provider/versions/0.2.0']);
    },
  );

  test('changed coordinate archive hash refuses before download', () async {
    metadata['archive_sha256'] = 'a' * 64;
    await expectLater(
      fetch(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'detail',
          contains('public archive bytes differ'),
        ),
      ),
    );
    expect(paths, ['/custom/api/packages/provider/versions/0.2.0']);
  });

  test('correct metadata hash cannot hide changed downloaded bytes', () async {
    servedBytes = [...archive.bytes, 1];
    await expectLater(
      fetch(),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'detail',
          contains('digest changed'),
        ),
      ),
    );
    expect(paths.last, '/custom/provider.tar.gz');
  });

  test('public metadata and archive reads remain bounded', () async {
    await expectLater(
      fetch(metadataLimit: 8),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'detail',
          contains('metadata exceeds'),
        ),
      ),
    );
    expect(paths, ['/custom/api/packages/provider/versions/0.2.0']);
    paths.clear();
    await expectLater(
      fetch(archiveLimit: 8),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'detail',
          contains('byte limit'),
        ),
      ),
    );
    expect(paths.last, '/custom/provider.tar.gz');
  });
}
