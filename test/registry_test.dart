import 'dart:io';

import 'package:rk/src/targets/pub_dev/client.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/registry.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:test/test.dart';

/// The pub.dev client, against a real server rather than a fake.
///
/// The rule being defended is the cardinal one. `absent` may be concluded only
/// from an authenticated negative, because `absent` is what lets rk publish —
/// and a timeout, a captive portal, or a 500 answered as `absent` is rk
/// publishing over a version it never managed to look at.
void main() {
  late HttpServer server;
  late Registry registry;
  late ResolvedProject project;

  /// What the next request gets.
  late int status;
  late String body;
  late Duration delay;
  late int versionStatus;
  late String versionBody;
  late Duration versionDelay;

  late List<HttpHeaders> requestHeaders;
  late List<Uri> requestUris;

  setUp(() async {
    status = 200;
    body = '{"versions": []}';
    delay = Duration.zero;
    versionStatus = 404;
    versionBody = '';
    versionDelay = Duration.zero;
    requestHeaders = [];
    requestUris = [];

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requestHeaders.add(request.headers);
      requestUris.add(request.uri);
      final exact = request.uri.path.contains('/versions/');
      final responseDelay = exact ? versionDelay : delay;
      if (responseDelay > Duration.zero) {
        await Future<void>.delayed(responseDelay);
      }
      request.response.statusCode = exact ? versionStatus : status;
      request.response.write(exact ? versionBody : body);
      await request.response.close();
    });

    registry = Registry(
      host: '${server.address.host}:${server.port}',
      secure: false,
    );
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse(
      '''
schema = 2

[release.keybay]
publish = ["pub.dev"]
''',
      'release.toml',
      diagnostics,
    )!;
    final resolution = Resolution.resolve(
      config,
      MemorySourceTree({
        'pubspec.yaml': 'name: keybay\nversion: 1.0.0\n',
        'CHANGELOG.md': '## 1.0.0\n',
      }),
      diagnostics,
    );
    expect(diagnostics.found, isEmpty);
    project = resolution!.units.single.projects.single;
  });

  tearDown(() async {
    registry.close();
    await server.close(force: true);
  });

  Future<Inspection> inspect() =>
      PubDevTarget(registry: registry).inspectProject(project);

  group('only an authenticated negative means absent', () {
    test('a 404 does, and says the package has never existed', () async {
      status = 404;
      final inspection = await inspect();
      expect(inspection.verdict, Verdict.absent);
      expect(
        inspection.detail,
        contains('does not exist yet'),
        reason:
            'the first publish is interactive, which is a fact about the '
            'ceremony rather than about the version',
      );
    });

    test('a version missing from a package that exists does', () async {
      body = '{"versions": [{"version": "0.9.0"}]}';
      expect((await inspect()).verdict, Verdict.absent);
    });
  });

  group('everything else is unknown, never absent', () {
    test(
      'an unreadable exact coordinate is not hidden by readable history',
      () async {
        versionStatus = 500;
        body = '{"versions": [{"version": "0.9.0"}]}';

        final inspection = await inspect();

        expect(inspection.verdict, Verdict.unknown);
        expect(inspection.detail, contains('500'));
        expect(requestUris, hasLength(1));
      },
    );

    test(
      'a provider that does not answer is bounded and stays unknown',
      () async {
        registry.close();
        registry = Registry(
          host: '${server.address.host}:${server.port}',
          secure: false,
          responseTimeout: const Duration(milliseconds: 20),
        );
        delay = const Duration(seconds: 1);

        final stopwatch = Stopwatch()..start();
        final inspection = await inspect();

        expect(inspection.verdict, Verdict.unknown);
        expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
      },
    );

    test('a 500', () async {
      status = 500;
      final inspection = await inspect();
      expect(
        inspection.verdict,
        Verdict.unknown,
        reason: 'answered absent, rk would publish over whatever is there',
      );
      expect(inspection.detail, contains('500'));
    });

    test('a captive portal answering 200 with HTML', () async {
      body = '<html><body>Sign in to continue</body></html>';
      expect((await inspect()).verdict, Verdict.unknown);
    });

    test('valid JSON that is not the shape rk expects', () async {
      body = '{"versions": "all of them"}';
      expect((await inspect()).verdict, Verdict.unknown);
    });
  });

  group('what is there is reported as what is there', () {
    test(
      'the exact coordinate can confirm before package history catches up',
      () async {
        versionStatus = 200;
        versionBody =
            '{"version": "1.0.0", '
            '"archive_sha256": "AB12cd"}';
        body = '{"versions": [{"version": "0.9.0"}]}';

        final inspection = await PubDevTarget(
          registry: registry,
        ).inspectProject(project, expectedArchiveSha256: 'AB12cd');

        expect(inspection.verdict, Verdict.exact);
        expect(inspection.evidence['archive'], 'sha256:ab12cd');
        expect(requestUris, hasLength(1));
        expect(requestUris.single.path, endsWith('/versions/1.0.0'));
      },
    );

    test('an exact match', () async {
      body = '{"versions": [{"version": "1.0.0"}]}';
      final inspection = await inspect();
      expect(inspection.verdict, Verdict.exact);
    });

    test('a published date is carried into the detail', () async {
      body =
          '{"versions": [{"version": "1.0.0", '
          '"published": "2020-01-01T00:00:00Z"}]}';
      expect((await inspect()).detail, contains('years ago'));
    });
  });

  group('lookup', () {
    test('uses the supported hosted-repository v2 media type', () async {
      await registry.lookup('keybay');

      expect(
        requestHeaders.single.value(HttpHeaders.acceptHeader),
        'application/vnd.pub.v2+json',
      );
      expect(
        requestHeaders.single.value(HttpHeaders.userAgentHeader),
        contains('release-kit'),
      );
    });

    test('a version rk cannot parse is skipped, not fatal', () async {
      body =
          '{"versions": [{"version": "not-a-version"}, '
          '{"version": "1.0.0"}]}';
      final package = await registry.lookup('keybay');
      expect(package!.versions.map((v) => v.version.canonical), ['1.0.0']);
    });

    test('the repository is read from each published pubspec', () async {
      body =
          '{"versions": [{"version": "1.0.0", "pubspec": {'
          '"repository": "https://github.com/example/keybay"}}]}';
      final package = await registry.lookup('keybay');
      expect(
        package!.versions.single.repository,
        'https://github.com/example/keybay',
      );
    });

    test('a number where a string belongs does not throw', () async {
      body = '{"versions": [{"version": "1.0.0", "archive_sha256": 7}]}';
      final package = await registry.lookup('keybay');
      expect(package!.versions.single.archiveSha256, isNull);
    });

    test('the newest version is by precedence, not by position', () async {
      body =
          '{"versions": [{"version": "1.0.0"}, {"version": "0.9.0"}, '
          '{"version": "1.0.0-beta"}]}';
      final package = await registry.lookup('keybay');
      expect(package!.latest!.version.canonical, '1.0.0');
    });

    test('a success is cached for the run, and forget discards it', () async {
      body = '{"versions": []}';
      expect((await registry.lookup('keybay'))!.versions, isEmpty);

      body = '{"versions": [{"version": "1.0.0"}]}';
      expect(
        (await registry.lookup('keybay'))!.versions,
        isEmpty,
        reason: 'one inspection sweep should not hammer the registry',
      );

      registry.forget('keybay');
      expect(
        (await registry.lookup('keybay'))!.versions,
        hasLength(1),
        reason:
            'after rk acts on the package, its own knowledge is stale by '
            'its own hand — a post-act verification that reads the memo the '
            'pre-act inspection wrote is a verification that cannot fire',
      );
    });

    test('overlapping reads of one package share one request', () async {
      body = '{"versions": [{"version": "1.0.0"}]}';
      delay = const Duration(milliseconds: 50);
      final reads = await Future.wait([
        registry.lookup('keybay'),
        registry.lookup('keybay'),
        registry.lookup('keybay'),
      ]);
      expect(
        [for (final package in reads) package!.latest!.version.canonical],
        ['1.0.0', '1.0.0', '1.0.0'],
      );
      expect(requestUris, hasLength(1));
    });

    test('an unreadable answer is not cached as a fact', () async {
      status = 500;
      await expectLater(
        registry.lookup('keybay'),
        throwsA(isA<RegistryUnavailable>()),
      );

      status = 200;
      body = '{"versions": [{"version": "1.0.0"}]}';
      final package = await registry.lookup('keybay');
      expect(
        package?.versions,
        hasLength(1),
        reason: 'a failure that stuck would make the rest of the run blind',
      );
    });
  });
}
