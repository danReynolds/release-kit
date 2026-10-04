import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/targets/catalog.dart';
import 'package:rk/src/targets/pub_dev/endpoint.dart';
import 'package:rk/src/targets/pub_dev/module.dart';
import 'package:rk/src/targets/pub_dev/session.dart';
import 'package:rk/src/targets/target_module.dart';
import 'package:test/test.dart';

import 'scripted_tools.dart';

void main() {
  final local = PubEndpoint.loopback(Uri.parse('http://127.0.0.1:41523/'));

  ResolvedUnit unit() {
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse(
      'schema = 2\n[release.core]\npublish = ["pub.dev"]\n',
      'release.toml',
      diagnostics,
    )!;
    final resolved = Resolution.resolve(
      config,
      MemorySourceTree({'pubspec.yaml': 'name: example\nversion: 0.1.0\n'}),
      diagnostics,
    );
    expect(diagnostics.found, isEmpty);
    return resolved!.units.single;
  }

  TargetReadinessContext context(
    ScriptedTools tools, {
    Map<String, String> environment = const {},
    ProgressInteractiveRunner? runInteractive,
  }) => TargetReadinessContext(
    tools: tools,
    git: GitState.unbound('/fixture'),
    environment: environment,
    runInteractive: runInteractive,
  );

  test('public endpoint preserves strict public destination matching', () {
    const public = PubEndpoint.pubDev();
    expect(public.origin, 'https://pub.dev');
    expect(public.uri, Uri.parse('https://pub.dev'));
    expect(public.isPubDev, isTrue);
    for (final value in ['https://pub.dev', 'https://PUB.DEV:443/']) {
      expect(public.matches(value), isTrue);
    }
    for (final value in [
      local.origin,
      'http://pub.dev',
      'https://pub.dev:444',
      'https://pub.dev/path',
      'https://pub.dev?token=secret',
      'https://secret@pub.dev',
    ]) {
      expect(public.matches(value), isFalse, reason: value);
    }
  });

  test('loopback composition allows only one explicit root IPv4 origin', () {
    expect(local.origin, 'http://127.0.0.1:41523');
    expect(local.isPubDev, isFalse);
    expect(local.matches('${local.origin}/'), isTrue);
    expect(local.matches('http://127.0.0.1:41524'), isFalse);
    expect(local.matches('http://localhost:41523'), isFalse);
    for (final value in [
      'https://pub.dev',
      'http://example.test:41523',
      'http://localhost:41523',
      'http://127.0.0.2:41523',
      'http://127.0.0.1',
      'http://127.0.0.1:0',
      'http://127.0.0.1:65536',
      'https://127.0.0.1:41523',
      'http://127.0.0.1:41523/path',
      'http://secret@127.0.0.1:41523',
      'http://127.0.0.1:41523?token=secret',
      'http://127.0.0.1:41523#fragment',
    ]) {
      expect(
        () => PubEndpoint.loopback(Uri.parse(value)),
        throwsArgumentError,
        reason: value,
      );
    }
  });

  test('catalog binds module and session to the same explicit endpoint', () {
    final original = TargetCatalog.builtIn();
    final composed = TargetCatalog.builtIn(pubEndpoint: local);
    final module = composed.modules.whereType<PubDevTargetModule>().single;
    expect(module.endpoint, same(local));
    expect((module.authentication as PubDevSession).endpoint, same(local));
    expect(TargetCatalog.builtIn(), same(original));
    expect(
      original.modules.whereType<PubDevTargetModule>().single.endpoint.isPubDev,
      isTrue,
    );
  });

  test(
    'readiness refuses ambient redirects and independently mismatched ports',
    () async {
      final tools = ScriptedTools({});
      final nativeLocal = context(
        tools,
        environment: {'PUB_HOSTED_URL': local.origin},
      );
      final publicRefusal = await const PubDevTargetModule().checkReadiness(
        nativeLocal,
        unit(),
      );
      expect(publicRefusal, isA<TargetNotReady>());
      expect((publicRefusal as TargetNotReady).diagnostic.code, 'RK-PUB-009');

      final module = PubDevTargetModule(endpoint: local);
      expect(
        await module.checkReadiness(nativeLocal, unit()),
        isA<TargetReady>(),
      );
      for (final native in ['http://127.0.0.1:41524', 'https://pub.dev']) {
        final mismatch = await module.checkReadiness(
          context(tools, environment: {'PUB_HOSTED_URL': native}),
          unit(),
        );
        expect(mismatch, isA<TargetNotReady>(), reason: native);
        expect((mismatch as TargetNotReady).diagnostic.code, 'RK-PUB-009');
      }
      expect(
        tools.calls,
        isEmpty,
        reason: 'endpoint refusal precedes native authentication',
      );
    },
  );

  test(
    'loopback sessions require an exact native token and never public login/logout',
    () async {
      final tools = ScriptedTools({
        'dart': ok('You have 1 token.\n${local.origin}/\n'),
      });
      final session = PubDevSession(endpoint: local);
      final ready = context(
        tools,
        environment: {'PUB_HOSTED_URL': local.origin},
      );
      expect(await session.established(ready), isTrue);
      expect(
        await session.acquire(ready, unit(), const []),
        isA<TargetReady>(),
      );
      expect(await session.restore(ready), isNull);
      expect(tools.calls, everyElement(['dart', 'pub', 'token', 'list']));
    },
  );

  test(
    'public or other-port credentials cannot establish a loopback session',
    () async {
      for (final listed in ['https://pub.dev', 'http://127.0.0.1:41524', '']) {
        final tools = ScriptedTools({'dart': ok(listed)});
        final session = PubDevSession(endpoint: local);
        final ready = context(
          tools,
          environment: {'PUB_HOSTED_URL': local.origin},
          runInteractive: (_, _, {workingDirectory}) async {
            fail(
              'a loopback composition must never acquire a public OAuth session',
            );
          },
        );
        expect(await session.established(ready), isFalse);
        final refused = await session.acquire(ready, unit(), const []);
        expect(refused, isA<TargetNotReady>());
        expect((refused as TargetNotReady).diagnostic.code, 'RK-PUB-007');
        expect(await session.restore(ready), isNull);
        expect(tools.calls, everyElement(['dart', 'pub', 'token', 'list']));
      }
    },
  );

  test('default public session ignores loopback token configuration', () async {
    final tools = ScriptedTools({'dart': ok(local.origin)});
    final ready = context(tools, environment: {'PUB_HOSTED_URL': local.origin});
    final refused = await const PubDevSession().acquire(
      ready,
      unit(),
      const [],
    );
    expect(refused, isA<TargetNotReady>());
    expect((refused as TargetNotReady).diagnostic.code, 'RK-PUB-007');
    expect(tools.calls, [
      ['dart', 'pub', 'token', 'list'],
    ]);
  });

  test(
    'explicit custom manifest destination still fails source resolution',
    () {
      final diagnostics = Diagnostics();
      final config = ReleaseConfig.parse(
        'schema = 2\n[release.core]\npublish = ["pub.dev"]\n',
        'release.toml',
        diagnostics,
      )!;
      final resolved = Resolution.resolve(
        config,
        MemorySourceTree({
          'pubspec.yaml':
              'name: example\nversion: 0.1.0\npublish_to: ${local.origin}\n',
        }),
        diagnostics,
      );
      expect(resolved, isNull);
      expect(
        diagnostics.found.map((diagnostic) => diagnostic.code),
        contains('RK-RES-014'),
      );
    },
  );
}
