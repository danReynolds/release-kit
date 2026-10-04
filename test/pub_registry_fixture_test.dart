import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

import 'support/pub_registry_fixture.dart';

void main() {
  late Directory root;
  late PubRegistryFixture registry;
  late HttpServer server;
  late HttpClient client;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('rk-pub-protocol-');
    addTearDown(() => root.deleteSync(recursive: true));
    registry = PubRegistryFixture(root);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) => registry.handle(request));
    client = HttpClient()..findProxy = (_) => 'DIRECT';
    addTearDown(() => client.close(force: true));
  });

  Future<({int status, List<int> body, String? location})> request(
    String method,
    String path, {
    bool authenticated = false,
    String? contentType,
    List<int>? body,
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    if (authenticated) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${registry.token}',
      );
    }
    if (contentType != null) {
      request.headers.set(HttpHeaders.contentTypeHeader, contentType);
    }
    if (body != null) request.add(body);
    final response = await request.close();
    final bytes = await response.fold<List<int>>(
      [],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    return (
      status: response.statusCode,
      body: bytes,
      location: response.headers.value(HttpHeaders.locationHeader),
    );
  }

  Future<String> initiate() async {
    final response = await request(
      'GET',
      '/api/packages/versions/new',
      authenticated: true,
    );
    expect(response.status, 200);
    final parameters = jsonDecode(utf8.decode(response.body)) as Map;
    expect(parameters['url'], startsWith('https://pub.dev/_uploads/'));
    final ticket = (parameters['fields'] as Map)['ticket'] as String;
    expect(Uri.parse(parameters['url'] as String).path, '/_uploads/$ticket');
    return ticket;
  }

  Future<({int status, List<int> body, String? location})> upload(
    String ticket,
    List<int> archive, {
    String? fieldTicket,
  }) => request(
    'POST',
    '/_uploads/$ticket',
    contentType: 'multipart/form-data; boundary=fixture-boundary',
    body: [
      ...utf8.encode(
        '--fixture-boundary\r\n'
        'Content-Disposition: form-data; name="ticket"\r\n\r\n'
        '${fieldTicket ?? ticket}\r\n'
        '--fixture-boundary\r\n'
        'Content-Type: application/octet-stream\r\n'
        'Content-Disposition: form-data; name="file"; filename="package.tar.gz"\r\n\r\n',
      ),
      ...archive,
      ...utf8.encode('\r\n--fixture-boundary--\r\n'),
    ],
  );

  test(
    'native upload protocol persists exact bytes only after authenticated finalize',
    () async {
      final bytes = _archive('provider', '0.2.0');
      final ticket = await initiate();
      final uploaded = await upload(ticket, bytes);
      expect(uploaded.status, 204);
      expect(uploaded.location, 'https://pub.dev/_uploads/$ticket/finalize');
      expect(registry.committed, isEmpty);
      expect((await request('GET', '/_uploads/$ticket/finalize')).status, 401);
      expect(registry.committed, isEmpty);
      expect(
        (await request(
          'GET',
          '/_uploads/$ticket/finalize',
          authenticated: true,
        )).status,
        200,
      );
      expect(registry.archive('provider', '0.2.0').readAsBytesSync(), bytes);
      expect(registry.committed['provider@0.2.0']!.digest, Sha256.hex(bytes));
      expect(
        (await request(
          'GET',
          '/_uploads/$ticket/finalize',
          authenticated: true,
        )).status,
        200,
      );
      expect(
        registry.events.where((event) => event.kind == 'committed'),
        hasLength(1),
      );

      // A new server state object has only durable archive storage to rely on.
      registry = PubRegistryFixture(root);
      final metadata = await request(
        'GET',
        '/api/packages/provider/versions/0.2.0',
      );
      final version = jsonDecode(utf8.decode(metadata.body)) as Map;
      expect(version['archive_sha256'], Sha256.hex(bytes));
      final downloaded = await request(
        'GET',
        Uri.parse(version['archive_url'] as String).path,
      );
      expect(downloaded.body, bytes);
    },
  );

  test('an explicit loopback origin owns every native protocol URL', () async {
    final origin = 'http://127.0.0.1:${server.port}';
    registry = PubRegistryFixture(root, origin: origin);
    final parameters = await request(
      'GET',
      '/api/packages/versions/new',
      authenticated: true,
    );
    final upload = jsonDecode(utf8.decode(parameters.body)) as Map;
    expect(upload['url'], '$origin/_uploads/1');
    registry.seedArchive(
      File('${root.path}/seed.tar.gz')
        ..writeAsBytesSync(_archive('provider', '0.2.0')),
    );
    final metadata = await request(
      'GET',
      '/api/packages/provider/versions/0.2.0',
    );
    final version = jsonDecode(utf8.decode(metadata.body)) as Map;
    expect(
      version['archive_url'],
      '$origin/packages/provider/versions/0.2.0.tar.gz',
    );
  });

  test(
    'rejection leaves no committed version and a later retry can publish',
    () async {
      registry.rejectUploads.add('provider');
      final bytes = _archive('provider', '0.2.0');
      final ticket = await initiate();
      expect((await upload(ticket, bytes)).status, 400);
      expect(registry.committed, isEmpty);
      expect(
        (await request(
          'GET',
          '/_uploads/$ticket/finalize',
          authenticated: true,
        )).status,
        404,
      );
      registry.rejectUploads.clear();
      expect((await upload(ticket, bytes)).status, 204);
      expect(
        (await request(
          'GET',
          '/_uploads/$ticket/finalize',
          authenticated: true,
        )).status,
        200,
      );
      expect(registry.committed.keys, ['provider@0.2.0']);
    },
  );

  test(
    'lost finalize responses commit once and keep public reads independent',
    () async {
      registry.loseFinalizeResponses.add('provider');
      final ticket = await initiate();
      final bytes = _archive('provider', '0.2.0');
      expect((await upload(ticket, bytes)).status, 204);
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          request('GET', '/_uploads/$ticket/finalize', authenticated: true),
          throwsA(isA<HttpException>()),
        );
      }
      expect(
        registry.events.where((event) => event.kind == 'committed'),
        hasLength(1),
      );
      expect(
        registry.events.where((event) => event.kind == 'response_lost').length,
        greaterThanOrEqualTo(2),
      );
      expect(
        (await request('GET', '/api/packages/provider/versions/0.2.0')).status,
        200,
      );
      expect(
        (await request('GET', '/packages/provider/versions/0.2.0.tar.gz')).body,
        bytes,
      );
      registry.loseFinalizeResponses.clear();
      expect(
        (await request(
          'GET',
          '/_uploads/$ticket/finalize',
          authenticated: true,
        )).status,
        200,
      );
    },
  );

  test(
    'observation barriers follow rejection and the recorded confirmation read',
    () async {
      final observed = <PubRegistryEvent>[];
      registry.onEvent = (event) {
        expect(registry.events.last, same(event));
        observed.add(event);
      };
      registry.rejectUploads.add('provider');
      final ticket = await initiate();
      expect((await upload(ticket, _archive('provider', '0.2.0'))).status, 400);
      expect(observed.last.kind, 'rejected');
      final missing = await request(
        'GET',
        '/api/packages/provider/versions/0.2.0',
      );
      expect(missing.status, 404);
      expect(jsonDecode(utf8.decode(missing.body)), contains('error'));
      expect(observed.last.kind, 'coordinate_missing');
      expect(observed.last.name, 'provider');
      expect(observed.last.version, '0.2.0');
      expect(observed.last.path, '/api/packages/provider/versions/0.2.0');
      expect(observed.last.status, 404);
      expect(observed.map((event) => event.kind), [
        'initiated',
        'upload_attempted',
        'rejected',
        'coordinate_missing',
      ]);
      expect(registry.committed, isEmpty);
    },
  );

  test(
    'coordinate, listing and archive visibility fail independently',
    () async {
      final source = File('${root.path}/seed.tar.gz')
        ..writeAsBytesSync(_archive('provider', '0.2.0'));
      registry.seedArchive(source);
      registry.hiddenListings.add('provider');
      expect((await request('GET', '/api/packages/provider')).status, 404);
      expect(
        (await request('GET', '/api/packages/provider/versions/0.2.0')).status,
        200,
      );
      registry.hiddenCoordinates.add('provider');
      registry.hiddenListings.clear();
      expect((await request('GET', '/api/packages/provider')).status, 200);
      expect(
        (await request('GET', '/api/packages/provider/versions/0.2.0')).status,
        404,
      );
      registry.unavailableArchives.add('provider');
      expect(
        (await request(
          'GET',
          '/packages/provider/versions/0.2.0.tar.gz',
        )).status,
        404,
      );
      registry.unavailableArchives.clear();
      expect(
        (await request(
          'GET',
          '/packages/provider/versions/0.2.0.tar.gz',
        )).status,
        200,
      );
    },
  );

  test(
    'immutable coordinates reject a second upload with different payload bytes',
    () async {
      final original = _archive('provider', '0.2.0');
      registry.seedArchive(
        File('${root.path}/seed.tar.gz')..writeAsBytesSync(original),
      );
      final ticket = await initiate();
      expect(
        (await upload(ticket, _archive('provider', '0.2.0', value: 99))).status,
        400,
      );
      expect(registry.archive('provider', '0.2.0').readAsBytesSync(), original);
      expect(registry.committed, hasLength(1));
      expect(
        registry.events.where((event) => event.kind == 'upload_attempted'),
        hasLength(1),
      );
      expect(
        registry.events.where((event) => event.kind == 'uploaded'),
        isEmpty,
      );
    },
  );

  test(
    'unexpected routes, bad upload fields and malformed archives cannot publish',
    () async {
      expect((await request('GET', '/api/packages/versions/new')).status, 401);
      expect((await request('POST', '/anything')).status, 404);
      final ticket = await initiate();
      expect(
        (await upload(
          ticket,
          _archive('provider', '0.2.0'),
          fieldTicket: 'wrong',
        )).status,
        400,
      );
      expect((await upload(ticket, [1, 2, 3])).status, 400);
      expect(registry.committed, isEmpty);
      expect(
        registry.events.map((event) => event.toString()).join('\n'),
        isNot(contains(registry.token)),
      );
    },
  );
}

List<int> _archive(String name, String version, {int value = 42}) {
  final contents = Archive()
    ..addFile(
      ArchiveFile.string(
        'pubspec.yaml',
        'name: $name\nversion: $version\nenvironment:\n  sdk: ^3.10.4\n',
      ),
    )
    ..addFile(ArchiveFile.string('lib/$name.dart', 'const value = $value;\n'));
  return gzip.encode(TarEncoder().encode(contents));
}
