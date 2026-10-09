import 'dart:async';
import 'dart:io';

import 'package:fleury/fleury.dart';
import 'package:fleury/fleury_test_support.dart';
import 'package:rk/src/installations/model.dart';
import 'package:rk/src/installations/provider.dart';
import 'package:rk/src/tui/use_picker.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late Directory scratch;
  late ExecutableProject project;
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('rk-use-queue-');
    project = fixture(scratch);
  });
  tearDown(() => scratch.deleteSync(recursive: true));

  Installation installed(InstallationSource source, String version) =>
      Installation(
        source: source,
        version: version,
        location: '/fixture',
        commands: const {},
      );

  test(
    'checks, keyboard navigation and queued actions remain live during update',
    () async {
      final versions = {
        InstallationSource.pub: '1.2.0',
        InstallationSource.github: '1.2.0',
      };
      List<ProjectInstallations> inspect() => [
        ProjectInstallations(project, {
          InstallationSource.local: const SourceInspection(),
          for (final entry in versions.entries)
            entry.key: SourceInspection(
              installation: installed(entry.key, entry.value),
            ),
        }),
      ];
      final gates = {
        for (final source in versions.keys) source: Completer<void>(),
      };
      final calls = <InstallationSource>[], switched = <InstallationSource>[];
      var checks = 0, running = 0, closed = false;
      final model = UsePicker(
        states: inspect(),
        refresh: () async => inspect(),
        check: (_, _, _) async {
          checks++;
          return const AvailableInstallation('1.3.0');
        },
        perform: perform(
          install: (_, source, release, progress, _) async {
            calls.add(source);
            expect(
              ++running,
              1,
              reason: 'Mutations retain the store lock contract.',
            );
            progress('Downloading ${source.label}…');
            await gates[source]!.future;
            versions[source] = release.version;
            running--;
            return '${source.label} installed';
          },
          use: (_, source, _, _) async {
            switched.add(source);
            return 'Used';
          },
        ),
        close: () => closed = true,
      );
      addTearDown(model.dispose);
      final tester = FleuryTester(viewportSize: const CellSize(104, 24));
      addTearDown(tester.dispose);
      tester.pumpWidget(FleuryApp(title: 'rk', home: UseScreen(model)));
      tester.pump();
      await settle();
      tester.pump();
      final first = model.download(model.states.single, InstallationSource.pub);
      tester.pump();
      expect(tester.renderToString(), contains('Updating…'));
      void key(KeyCode code) {
        tester.sendKey(KeyEvent(code));
        tester.pump();
      }

      key(KeyCode.arrowDown); // Local Use.
      key(KeyCode.arrowDown); // GitHub Use, skipping active Pub.
      key(KeyCode.arrowLeft); // GitHub Update.
      key(KeyCode.enter);
      expect(
        model.operationLabel(model.states.single, InstallationSource.github),
        'Queued',
      );
      expect(tester.renderToString(), contains('Queued'));
      key(KeyCode.enter); // Cannot enqueue a duplicate or switch to a neighbor.
      expect(calls, [InstallationSource.pub]);
      tester.sendKey(const KeyEvent(KeyCode.char('r')));
      tester.pump();
      expect(
        checks,
        4,
        reason: 'Refresh checks both sources while an update runs.',
      );
      await settle();
      key(KeyCode.arrowDown); // Keep Local Use focused while other rows finish.
      gates[InstallationSource.pub]!.complete();
      await first;
      await settle();
      tester.pump();
      expect(calls, [InstallationSource.pub, InstallationSource.github]);
      expect(
        model
            .states
            .single
            .sources[InstallationSource.pub]!
            .installation!
            .version,
        '1.3.0',
      );
      expect(
        model.canDownload(model.states.single, InstallationSource.pub),
        isFalse,
      );
      gates[InstallationSource.github]!.complete();
      await settle();
      tester.pump();
      expect(model.busy, isFalse);
      expect(closed, isFalse);
      expect(switched, isEmpty);
      key(KeyCode.enter);
      await settle();
      expect(switched, [
        InstallationSource.local,
      ], reason: 'Finishing another source must not steal focus.');
    },
  );

  for (final failure in [false, true]) {
    test(
      '${failure ? 'failure' : 'cancel'} clears queued work without starting it',
      () async {
        final state = ProjectInstallations(project, {
          InstallationSource.pub: const SourceInspection(),
          InstallationSource.github: const SourceInspection(),
        });
        final gate = Completer<void>();
        var calls = 0, closed = false;
        final model = UsePicker(
          states: [state],
          refresh: () async => [state],
          check: (_, _, _) async => const AvailableInstallation('1.3.0'),
          perform: perform(
            install: (_, _, _, _, cancel) async {
              calls++;
              await gate.future;
              if (failure) throw const InstallationFailure('Download failed.');
              expect(cancel.cancelled, isTrue);
              return 'Completed installation';
            },
            use: (_, _, _, _) async => throw StateError('No switch'),
          ),
          close: () => closed = true,
        );
        addTearDown(model.dispose);
        model.checkAll();
        await settle();
        final first = model.download(state, InstallationSource.pub);
        final second = model.download(state, InstallationSource.github);
        expect(
          model.operationLabel(state, InstallationSource.github),
          'Queued',
        );
        if (!failure) model.interrupt();
        expect(closed, isFalse);
        gate.complete();
        await Future.wait([first, second]);
        expect(calls, 1);
        expect(model.busy, isFalse);
        expect(closed, !failure);
        expect(model.details != null, failure);
      },
    );
  }

  test('an update failure dismisses a pending removal confirmation', () async {
    final state = ProjectInstallations(project, {
      InstallationSource.pub: const SourceInspection(),
      InstallationSource.github: SourceInspection(
        installation: installed(InstallationSource.github, '1.2.0'),
      ),
    });
    final gate = Completer<String>();
    var removals = 0;
    final model = UsePicker(
      states: [state],
      refresh: () async => [state],
      check: (_, _, _) async => const AvailableInstallation('1.3.0'),
      perform: perform(
        install: (_, _, _, _, _) => gate.future,
        use: (_, _, _, _) async => 'Used',
        uninstall: (_, _, _, _) async {
          removals++;
          return 'Removed';
        },
      ),
      close: () {},
    );
    addTearDown(model.dispose);
    await model.check(state, InstallationSource.pub);
    final updating = model.download(state, InstallationSource.pub);
    model.requestRemoval(state, InstallationSource.github);
    expect(model.removal, isNotNull);
    gate.completeError(const InstallationFailure('Update failed.'));
    await updating;
    expect(model.details?.body, contains('Update failed.'));
    expect(
      model.removal,
      isNull,
      reason: 'The failure must replace the old confirmation.',
    );
    await model.confirmRemoval();
    expect(removals, 0);
  });

  test(
    'Update exists only after a successful check proves a newer version',
    () async {
      final state = ProjectInstallations(project, {
        InstallationSource.pub: SourceInspection(
          installation: installed(InstallationSource.pub, '1.3.0'),
        ),
      });
      final replies = <Completer<AvailableInstallation>>[];
      final model = UsePicker(
        states: [state],
        refresh: () async => [state],
        check: (_, _, _) {
          final reply = Completer<AvailableInstallation>();
          replies.add(reply);
          return reply.future;
        },
        perform: perform(
          install: (_, _, _, _, _) async => throw StateError('No update'),
          use: (_, _, _, _) async => 'Used',
        ),
        close: () {},
      );
      addTearDown(model.dispose);
      final tester = FleuryTester(viewportSize: const CellSize(104, 24));
      addTearDown(tester.dispose);
      tester.pumpWidget(FleuryApp(title: 'rk', home: UseScreen(model)));
      tester.pump();
      bool updateVisible() => tester
          .renderToString()
          .split('\n')
          .any((line) => line.contains('[') && line.contains('Update'));
      expect(updateVisible(), isFalse);
      expect(tester.renderToString(), contains('Checking…'));
      for (final version in ['1.3.0', '1.2.0', '1.4.0']) {
        if (replies.last.isCompleted) {
          model.checkAll();
          tester.pump();
        }
        expect(updateVisible(), isFalse);
        replies.last.complete(AvailableInstallation(version));
        await settle();
        tester.pump();
        expect(updateVisible(), version == '1.4.0');
      }
      model.checkAll();
      tester.pump();
      expect(updateVisible(), isFalse);
      replies.last.completeError(const InstallationFailure('Offline'));
      await settle();
      tester.pump();
      expect(updateVisible(), isFalse);
      expect(tester.renderToString(), contains('Retry'));
      expect(tester.renderToString(), contains('1.3.0'));
    },
  );
}
