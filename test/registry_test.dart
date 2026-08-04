import 'dart:io';

import 'package:release_kit/src/engine/registry.dart';
import 'package:release_kit/src/transforms/digest.dart';
import 'package:release_kit/src/engine/verdict.dart';
import 'package:release_kit/src/engine/version.dart';
import 'package:test/test.dart';

/// The pub.dev client, against a real server rather than a fake.
///
/// Every other test that touches verdicts goes through a FakeRegistry that
/// hand-writes them, so the contract was asserted by the double and never by
/// the code that ships. A mutation proved it: changing the real `inspect` to
/// answer `absent` where it should answer `unknown` broke nothing in the whole
/// suite. This file exists so that mutation fails.
///
/// The rule being defended is the cardinal one. `absent` may be concluded only
/// from an authenticated negative, because `absent` is what lets rk publish —
/// and a timeout, a captive portal, or a 500 answered as `absent` is rk
/// publishing over a version it never managed to look at.
void main() {
  late HttpServer server;
  late Registry registry;

  /// What the next request gets.
  late int status;
  late String body;
  late Duration delay;

  /// Served for any path ending `.tar.gz`, so an archive URL can point here.
  List<int>? archiveBytes;

  setUp(() async {
    status = 200;
    body = '{"versions": []}';
    delay = Duration.zero;
    archiveBytes = null;

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      request.response.statusCode = status;
      if (archiveBytes != null && request.uri.path.endsWith('.tar.gz')) {
        request.response.add(archiveBytes!);
      } else {
        request.response.write(body);
      }
      await request.response.close();
    });

    registry = Registry(
      host: '${server.address.host}:${server.port}',
      secure: false,
    );
  });

  tearDown(() async {
    registry.close();
    await server.close(force: true);
  });

  Future<Inspection> inspect([String version = '1.0.0']) =>
      registry.inspect('keybay', Version.tryParse(version)!);

  group('only an authenticated negative means absent', () {
    test('a 404 does', () async {
      status = 404;
      final inspection = await inspect();
      expect(inspection.verdict, Verdict.absent);
    });

    test('a version missing from a package that exists does', () async {
      body = '{"versions": [{"version": "0.9.0"}]}';
      expect((await inspect()).verdict, Verdict.absent);
    });
  });

  group('everything else is unknown, never absent', () {
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

    test('a 403, which is a credential problem and not an answer', () async {
      status = 403;
      expect((await inspect()).verdict, Verdict.unknown);
    });

    test('a 301 rk did not follow', () async {
      status = 301;
      expect((await inspect()).verdict, Verdict.unknown);
    });

    test('a captive portal answering 200 with HTML', () async {
      body = '<html><body>Sign in to continue</body></html>';
      expect((await inspect()).verdict, Verdict.unknown);
    });

    test('a truncated body that will not decode', () async {
      body = '{"versions": [{"version": "1.0.0"}';
      expect((await inspect()).verdict, Verdict.unknown);
    });

    test('valid JSON that is not the shape rk expects', () async {
      body = '{"versions": "all of them"}';
      expect((await inspect()).verdict, Verdict.unknown);
    });

    test('a body that decodes to a list rather than an object', () async {
      body = '[]';
      expect((await inspect()).verdict, Verdict.unknown);
    });

    test('nothing listening at all', () async {
      await server.close(force: true);
      expect((await inspect()).verdict, Verdict.unknown);
    });
  });

  group('what is there is reported as what is there', () {
    test('an exact match', () async {
      body = '{"versions": [{"version": "1.0.0"}]}';
      final inspection = await inspect();
      expect(inspection.verdict, Verdict.exact);
    });

    test('a published date is carried into the detail', () async {
      body = '{"versions": [{"version": "1.0.0", '
          '"published": "2020-01-01T00:00:00Z"}]}';
      expect((await inspect()).detail, contains('years ago'));
    });

    test('a package that has never existed says so', () async {
      status = 404;
      expect(
        (await inspect()).detail,
        contains('does not exist yet'),
        reason: 'the first publish is interactive, which is a fact about the '
            'ceremony rather than about the version',
      );
    });
  });

  group('lookup', () {
    test('returns null only for a 404', () async {
      status = 404;
      expect(await registry.lookup('keybay'), isNull);
    });

    test('throws rather than returning null when it could not find out',
        () async {
      status = 500;
      expect(
        () => registry.lookup('keybay'),
        throwsA(isA<RegistryUnavailable>()),
        reason: 'a null would be indistinguishable from "never published"',
      );
    });

    test('a version rk cannot parse is skipped, not fatal', () async {
      body = '{"versions": [{"version": "not-a-version"}, '
          '{"version": "1.0.0"}]}';
      final package = await registry.lookup('keybay');
      expect(package!.versions.map((v) => v.version.canonical), ['1.0.0']);
    });

    test('the archive url and digest are read from the wire', () async {
      // The digest proof is only as real as the field that feeds it: with
      // archive_sha256 never parsed, the proof never runs and nothing else
      // notices — a mutation demonstrated exactly that.
      body = '{"versions": [{"version": "1.0.0", '
          '"archive_url": "https://x/a.tar.gz", '
          '"archive_sha256": "AB12cd"}]}';
      final package = await registry.lookup('keybay');
      expect(package!.versions.single.archiveUrl, 'https://x/a.tar.gz');
      expect(package.versions.single.archiveSha256, 'AB12cd');
    });

    test('a number where a string belongs does not throw', () async {
      body = '{"versions": [{"version": "1.0.0", "archive_url": 7}]}';
      final package = await registry.lookup('keybay');
      expect(package!.versions.single.archiveUrl, isNull);
    });

    test('the newest version is by precedence, not by position', () async {
      body = '{"versions": [{"version": "1.0.0"}, {"version": "0.9.0"}, '
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
        reason: 'after rk acts on the package, its own knowledge is stale by '
            'its own hand — a post-act verification that reads the memo the '
            'pre-act inspection wrote is a verification that cannot fire',
      );
    });

    group('the archive fetch', () {
      PublishedVersion published({String? sha}) => PublishedVersion(
            version: Version.tryParse('1.0.0')!,
            published: null,
            archiveUrl: 'http://${server.address.host}:${server.port}/a.tar.gz',
            archiveSha256: sha,
          );

      test('returns the bytes when they match the stated digest', () async {
        archiveBytes = [1, 2, 3, 4];
        final bytes = await registry.archive(published(
          sha: Sha256.hex([1, 2, 3, 4]),
        ));
        expect(bytes, [1, 2, 3, 4]);
      });

      test(
          'bytes that do not match the stated digest are tampering, not '
          'unavailability', () async {
        archiveBytes = [9, 9, 9];
        await expectLater(
          registry.archive(published(sha: Sha256.hex([1, 2, 3, 4]))),
          throwsA(isA<ArchiveTampered>()),
          reason: 'retrying will not change what the registry serves, and '
              'proceeding would verify source against content nobody '
              'vouches for',
        );
      });

      test('a non-200 answer is unavailability', () async {
        status = 503;
        archiveBytes = [1];
        await expectLater(
          registry.archive(published()),
          throwsA(isA<RegistryUnavailable>()),
        );
      });

      test('a version with no archive URL cannot be fetched', () async {
        await expectLater(
          registry.archive(PublishedVersion(
            version: Version.tryParse('1.0.0')!,
            published: null,
            archiveUrl: null,
            archiveSha256: null,
          )),
          throwsA(isA<RegistryUnavailable>()),
        );
      });
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
