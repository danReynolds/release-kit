import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fleury/fleury.dart';
import 'package:fleury/fleury_test_support.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/installations/manager.dart';
import 'package:rk/src/installations/metadata.dart';
import 'package:rk/src/installations/model.dart';
import 'package:rk/src/installations/provider.dart';
import 'package:rk/src/installations/store.dart';
import 'package:rk/src/targets/homebrew/installation.dart';
import 'package:rk/src/targets/pub_dev/installation.dart';
import 'package:rk/src/tui/use_picker.dart';
import 'package:test/test.dart';
import 'fixtures.dart';

class UpdatingBrew extends HomebrewInstallationProvider {
  UpdatingBrew(
    super.tools,
    super.brew, {
    required super.fetch,
    required super.platform,
  });
  Installation? installed;
  @override
  Future<SourceInspection> inspect(ExecutableProject project) async =>
      SourceInspection(installation: installed);
}

void main() {
  late Directory scratch;
  late ExecutableProject project;
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('rk-updates-');
    project = fixture(scratch);
  });
  tearDown(() => scratch.deleteSync(recursive: true));

  test(
    'updating an inactive source keeps selection; selected update advances all launchers even on late cancellation',
    () async {
      final store = InstallationStore(
        '${scratch.path}/store',
        const SystemTools(),
      );
      final local = StubProvider(InstallationSource.local);
      final pub = StubProvider(InstallationSource.pub);
      final manager = InstallationManager(
        store: store,
        providers: {local.source: local, pub.source: pub},
        environment: {},
      );
      await manager.act(
        project,
        local.source,
        InstallationAction.use,
        progress: (_) {},
      );
      await manager.download(
        project,
        pub.source,
        await pub.latest(project),
        progress: (_) {},
      );
      expect(store.selected(project)!.source, local.source);
      expect((await pub.inspect(project)).installation!.version, '1.3.0');
      await manager.act(
        project,
        pub.source,
        InstallationAction.use,
        progress: (_) {},
      );
      final cancel = InstallationCancellation();
      pub.preparing = () async {
        cancel.cancel();
      };
      await manager.download(
        project,
        pub.source,
        const AvailableInstallation('1.4.0'),
        progress: (_) {},
        cancellation: cancel,
      );
      expect(store.selected(project)!.source, pub.source);
      for (final command in project.commands) {
        expect(
          (await Process.run('${store.bin}/$command', [])).stdout,
          '1.4.0\n',
        );
      }
      await expectLater(
        manager.download(
          project,
          pub.source,
          const AvailableInstallation('1.3.0'),
          progress: (_) {},
        ),
        throwsA(
          isA<InstallationFailure>().having(
            (e) => e.message,
            'message',
            contains('newer'),
          ),
        ),
      );
    },
  );

  test(
    'checks are independent, preserve installations, cancel on dispose, and ignore stale replies',
    () async {
      final pub = StubProvider(InstallationSource.pub);
      await pub.install(project, null, (_) {});
      final states = [
        ProjectInstallations(project, {
          InstallationSource.local: const SourceInspection(),
          pub.source: SourceInspection(installation: pub.installed),
        }),
      ];
      final replies = <Completer<AvailableInstallation>>[];
      final requests = <InstallationCheck>[];
      final model = UsePicker(
        states: states,
        refresh: () async => states,
        checkAvailable: (_, _, check) {
          requests.add(check);
          final reply = Completer<AvailableInstallation>();
          replies.add(reply);
          return reply.future;
        },
        downloadAvailable: (_, _, _, _, _) async => 'Downloaded',
        use: (_, _, _, _) async => 'Used',
        close: () {},
      );
      model.checkAll();
      expect(model.availability(states.single, pub.source).checking, isTrue);
      model.checkAll();
      expect(requests.first.cancelled, isTrue);
      replies.first.complete(const AvailableInstallation('1.3.0'));
      replies.last.completeError(const InstallationFailure('Offline'));
      await Future<void>.delayed(Duration.zero);
      expect(model.availability(states.single, pub.source).release, isNull);
      expect(
        model.availability(states.single, pub.source).error,
        contains('Offline'),
      );
      expect(
        model.states.single.sources[pub.source]!.installation,
        same(pub.installed),
      );
      model.checkAll();
      model.dispose();
      expect(requests.last.cancelled, isTrue);
      replies.last.complete(const AvailableInstallation('1.3.0'));
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'duplicate downloads are ignored and a switch queues until installation settles',
    () async {
      var downloads = 0, uses = 0, closes = 0;
      final gate = Completer<void>();
      final states = [
        ProjectInstallations(project, {
          InstallationSource.local: const SourceInspection(),
          InstallationSource.pub: const SourceInspection(),
        }),
      ];
      final model = UsePicker(
        states: states,
        refresh: () async => states,
        checkAvailable: (_, _, _) async => const AvailableInstallation('1.3.0'),
        downloadAvailable: (_, _, _, _, _) async {
          downloads++;
          await gate.future;
          return 'Downloaded';
        },
        use: (_, _, _, _) async {
          uses++;
          return 'Used';
        },
        close: () => closes++,
      );
      addTearDown(model.dispose);
      await model.check(states.single, InstallationSource.pub);
      await model.choose(states.single, InstallationSource.pub);
      expect(uses, 0);
      final pending = model.download(states.single, InstallationSource.pub);
      await model.download(states.single, InstallationSource.pub);
      final switching = model.choose(states.single, InstallationSource.local);
      expect(
        model.operationLabel(states.single, InstallationSource.local),
        'Queued',
      );
      expect(downloads, 1);
      expect(uses, 0);
      gate.complete();
      await pending;
      await switching;
      expect(uses, 1);
      expect(closes, 1);
    },
  );

  test(
    'table starts unfocused, row navigation and Enter use installed sources while checks are pending',
    () async {
      final local = StubProvider(InstallationSource.local);
      final pub = StubProvider(InstallationSource.pub);
      await local.install(project, null, (_) {});
      await pub.install(project, null, (_) {});
      local.installed = Installation(
        source: local.source,
        version: '1.2.0',
        location: project.directory,
        commands: local.installed!.commands,
      );
      var source = InstallationSource.local;
      var uses = 0;
      final states = [
        ProjectInstallations(
          project,
          {
            local.source: SourceInspection(installation: local.installed),
            pub.source: SourceInspection(installation: pub.installed),
          },
          selected: local.source,
          currentSources: {for (final c in project.commands) c: local.source},
        ),
      ];
      final gate = Completer<AvailableInstallation>();
      final model = UsePicker(
        states: states,
        refresh: () async => states,
        checkAvailable: (_, _, _) => gate.future,
        downloadAvailable: (_, _, _, _, _) async => 'Downloaded',
        use: (_, s, _, _) async {
          source = s;
          uses++;
          return 'Used';
        },
        close: () {},
      );
      addTearDown(model.dispose);
      final tester = FleuryTester(viewportSize: const CellSize(110, 24));
      addTearDown(tester.dispose);
      tester.pumpWidget(FleuryApp(title: 'rk', home: UseScreen(model)));
      tester.pump();
      expect(tester.renderToString(), contains('Checking…'));
      expect(tester.renderToString(), contains('✓ Default'));
      tester.sendKey(const KeyEvent(KeyCode.enter));
      tester.pump();
      expect(uses, 0);
      tester.sendKey(const KeyEvent(KeyCode.arrowDown));
      tester.pump();
      tester.sendKey(const KeyEvent(KeyCode.arrowDown));
      tester.pump();
      tester.sendKey(const KeyEvent(KeyCode.enter));
      tester.pump();
      await Future<void>.delayed(Duration.zero);
      tester.pump();
      expect(uses, 1);
      expect(source, pub.source);
      gate.complete(const AvailableInstallation('1.3.0'));
      await Future<void>.delayed(Duration.zero);
    },
  );

  for (final broken in [false, true]) {
    test(
      'uninstall ${broken ? 'broken owned' : 'inactive'} source requires confirmation and stays open',
      () async {
        final pub = StubProvider(InstallationSource.pub);
        await pub.install(project, null, (_) {});
        var removed = false, calls = 0, closes = 0;
        final gate = Completer<String>();
        List<ProjectInstallations> inspect() => [
          ProjectInstallations(project, {
            InstallationSource.local: const SourceInspection(),
            pub.source: SourceInspection(
              installation: removed ? null : pub.installed,
              problem: broken && !removed
                  ? 'Archive was damaged. Remove before reinstalling.'
                  : null,
            ),
          }),
        ];
        final model = UsePicker(
          states: inspect(),
          refresh: () async => inspect(),
          checkAvailable: (_, _, _) async =>
              const AvailableInstallation('1.3.0'),
          downloadAvailable: (_, _, _, _, _) async =>
              throw StateError('No download'),
          use: (_, _, _, _) async => throw StateError('No switch'),
          uninstall: (_, source, _, _) {
            expect(source, pub.source);
            calls++;
            return gate.future;
          },
          close: () => closes++,
        );
        addTearDown(model.dispose);
        final tester = FleuryTester(viewportSize: const CellSize(104, 28));
        addTearDown(tester.dispose);
        tester.pumpWidget(FleuryApp(title: 'rk', home: UseScreen(model)));
        tester.pump();
        void key(KeyCode code) {
          tester.sendKey(KeyEvent(code));
          tester.pump();
        }

        key(KeyCode.arrowDown); // Local.
        key(KeyCode.arrowDown); // Pub Use, or recovery Remove.
        expect(tester.renderToString(), contains('u Uninstall Pub'));
        if (broken) {
          key(KeyCode.enter);
        } else {
          model.requestRemoval(model.states.single, pub.source);
          tester.pump();
        }
        expect(
          tester.renderToString(),
          contains('Remove ${project.label} from Pub?'),
        );
        key(KeyCode.enter); // Cancel is the default.
        expect(calls, 0);
        expect(model.removal, isNull);
        model.requestRemoval(model.states.single, pub.source);
        tester.pump();
        final operation = model.confirmRemoval();
        tester.pump();
        expect(tester.renderToString(), contains('Removing'));
        expect(tester.renderToString(), isNot(contains('Switching')));
        await model
            .confirmRemoval(); // Duplicate confirmation cannot remove twice.
        expect(calls, 1);
        removed = true;
        gate.complete('Removed Pub.');
        await operation;
        tester.pump();
        expect(closes, 0);
        expect(tester.renderToString(), contains('Not installed'));
        expect(model.canUninstall(model.states.single, pub.source), isFalse);
      },
    );
  }

  test('an install that finishes never turns Enter into Use', () async {
    var downloads = 0, uses = 0, closes = 0;
    Installation? installed;
    final gate = Completer<String>();
    List<ProjectInstallations> inspect() => [
      ProjectInstallations(project, {
        InstallationSource.local: const SourceInspection(),
        InstallationSource.pub: const SourceInspection(
          problem: 'Blocked activation',
        ),
        InstallationSource.github: SourceInspection(installation: installed),
      }),
    ];
    final model = UsePicker(
      states: inspect(),
      refresh: () async => inspect(),
      checkAvailable: (_, _, _) async => const AvailableInstallation('1.3.0'),
      downloadAvailable: (_, _, _, _, _) {
        downloads++;
        return gate.future;
      },
      use: (_, source, _, _) async {
        expect(source, InstallationSource.github);
        uses++;
        return 'Used';
      },
      close: () => closes++,
    );
    addTearDown(model.dispose);
    final tester = FleuryTester(viewportSize: const CellSize(104, 24));
    addTearDown(tester.dispose);
    tester.pumpWidget(FleuryApp(title: 'rk', home: UseScreen(model)));
    tester.pump();
    await Future<void>.delayed(Duration.zero);
    tester.pump();
    void key(KeyCode code) {
      tester.sendKey(KeyEvent(code));
      tester.pump();
    }

    key(KeyCode.enter);
    expect(downloads, 0, reason: 'nothing is focused until a key moves');
    key(KeyCode.arrowDown); // Local Use.
    key(
      KeyCode.arrowDown,
    ); // Past blocked Pub to GitHub, which can only install.
    key(KeyCode.enter);
    key(KeyCode.enter); // A second Enter does not install twice.
    expect(downloads, 1);
    expect(uses, 0);
    expect(tester.renderToString(), contains('Installing…'));
    installed = Installation(
      source: InstallationSource.github,
      version: '1.3.0',
      location: '/fixture',
      commands: const {},
    );
    gate.complete('GitHub installed');
    await Future<void>.delayed(Duration.zero);
    tester.pump();
    tester.pump();
    key(KeyCode.enter);
    await Future<void>.delayed(Duration.zero);
    expect(downloads, 1);
    expect(uses, 0);
    expect(closes, 0);
    // Finishing an install clears its focus; Use needs deliberate navigation.
    key(KeyCode.arrowDown); // Local Use.
    key(KeyCode.arrowDown); // GitHub Use.
    key(KeyCode.enter);
    await Future<void>.delayed(Duration.zero);
    expect(uses, 1);
    expect(closes, 1);
  });

  test(
    'Default is inert; Done closes without preparing or rewriting the active source',
    () async {
      final states = [
        ProjectInstallations(
          project,
          {
            InstallationSource.pub: SourceInspection(
              installation: Installation(
                source: InstallationSource.pub,
                version: '1.3.0',
                location: '/pub',
                commands: {
                  for (final c in project.commands)
                    c: LaunchCommand('/bin/echo'),
                },
              ),
            ),
          },
          currentSources: {
            for (final c in project.commands) c: InstallationSource.pub,
          },
        ),
      ];
      var closed = false;
      final model = UsePicker(
        states: states,
        refresh: () async => throw StateError('No rescan'),
        checkAvailable: (_, _, _) async => const AvailableInstallation('1.3.0'),
        downloadAvailable: (_, _, _, _, _) async =>
            throw StateError('No download'),
        use: (_, _, _, _) async => throw StateError('No reinstall'),
        close: () => closed = true,
      );
      addTearDown(model.dispose);
      await model.choose(states.single, InstallationSource.pub);
      expect(closed, isFalse);
      model.exit();
      expect(closed, isTrue);
    },
  );

  test(
    'Pub checks SDK, command set, retractions and stable versions without activating',
    () async {
      final calls = <List<String>>[];
      final provider = PubInstallationProvider(
        TestTools((_, args, _, _) async {
          calls.add(args);
          return ok('Dart SDK version: 3.12.2 (stable)');
        }),
        '/dart',
        {},
        fetch: (_, _, {check}) async => Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'versions': [
                for (final (version, sdk, retracted, commands) in [
                  ('1.1.0', '^3.10.0', false, ['orbit', 'orbit_admin']),
                  ('1.2.0', '^3.10.0', true, ['orbit', 'orbit_admin']),
                  ('1.3.0', '^3.14.0', false, ['orbit', 'orbit_admin']),
                  ('1.4.0', '^3.10.0', false, ['different']),
                  ('1.5.0-beta.1', '^3.10.0', false, ['orbit', 'orbit_admin']),
                ])
                  {
                    'version': version,
                    'retracted': retracted,
                    'pubspec': {
                      'name': project.name,
                      'environment': {'sdk': sdk},
                      'executables': {for (final c in commands) c: c},
                    },
                  },
              ],
            }),
          ),
        ),
      );
      expect((await provider.latest(project)).version, '1.1.0');
      expect(calls, [
        ['--version'],
      ]);
    },
  );

  test(
    'Homebrew downloads the checked formula, upgrades only it, and preserves old kegs',
    () async {
      project = fixture(
        scratch,
        name: 'binary',
        commands: ['orbit'],
        binary: true,
      );
      const formula =
          '# Generated by rk.\n  version "1.3.0"\n orbit-1.3.0-linux-x64.tar.gz\n';
      File('${scratch.path}/tap/Formula/orbit.rb')
        ..createSync(recursive: true)
        ..writeAsStringSync(formula);
      for (final previouslyInstalled in [false, true]) {
        final calls = <List<String>>[];
        late UpdatingBrew provider;
        Installation installed(String version) => Installation(
          source: InstallationSource.homebrew,
          version: version,
          location: '/keg/$version',
          commands: {'orbit': LaunchCommand('/bin/echo')},
        );
        provider = UpdatingBrew(
          TestTools((_, args, _, environment) async {
            calls.add(args);
            expect(environment!['HOMEBREW_NO_INSTALL_CLEANUP'], '1');
            expect(environment['HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK'], '1');
            if (args.first == 'install' || args.first == 'upgrade') {
              provider.installed = installed('1.3.0');
            }
            return ok(
              args.first == '--repository' ? '${scratch.path}/tap' : '',
            );
          }),
          '/brew',
          platform: 'linux-x64',
          fetch: (_, _, {check}) async => Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'encoding': 'base64',
                'content': base64Encode(utf8.encode(formula)),
              }),
            ),
          ),
        );
        if (previouslyInstalled) provider.installed = installed('1.2.0');
        final release = await provider.latest(project);
        expect(calls, isEmpty);
        expect(
          (await provider.install(project, release, (_) {})).version,
          '1.3.0',
        );
        expect(calls.last, [
          previouslyInstalled ? 'upgrade' : 'install',
          '--formula',
          if (!previouslyInstalled) '--skip-link',
          project.formula,
        ]);
        expect(calls.length, 4);
      }
    },
  );

  test(
    'Homebrew check is read-only; changed formula refuses installation after refresh',
    () async {
      project = fixture(
        scratch,
        name: 'binary',
        commands: ['orbit'],
        binary: true,
      );
      File('${scratch.path}/tap/Formula/orbit.rb')
        ..createSync(recursive: true)
        ..writeAsStringSync('changed formula');
      final calls = <List<String>>[];
      final provider = HomebrewInstallationProvider(
        TestTools((_, args, _, _) async {
          calls.add(args);
          return ok(args.first == '--repository' ? '${scratch.path}/tap' : '');
        }),
        '/brew',
        platform: 'linux-x64',
        fetch: (_, _, {check}) async => Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'encoding': 'base64',
              'content': base64Encode(
                utf8.encode(
                  '# Generated by rk.\n  version "1.3.0"\n orbit-1.3.0-linux-x64.tar.gz\n',
                ),
              ),
            }),
          ),
        ),
      );
      final release = await provider.latest(project);
      expect(release.version, '1.3.0');
      expect(calls, isEmpty);
      await expectLater(
        provider.install(project, release, (_) {}),
        throwsA(
          isA<InstallationFailure>().having(
            (e) => e.message,
            'message',
            contains('changed'),
          ),
        ),
      );
      expect(calls.map((c) => c.first), ['tap', 'update', '--repository']);
    },
  );
}
