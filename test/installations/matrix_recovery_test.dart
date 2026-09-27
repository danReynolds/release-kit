import 'dart:io';

import 'package:fleury/fleury.dart';
import 'package:fleury/fleury_test_support.dart';
import 'package:rk/src/installations/model.dart';
import 'package:rk/src/engine/init_plan.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/tui/init_picker.dart';
import 'package:rk/src/tui/installation_picker.dart';
import 'package:rk/src/tui/matrix.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  test(
    'init reasons use the same reversible details flow without toggling outputs',
    () {
      final plan = InitPlan.discover(
        tree: MemorySourceTree({'pubspec.yaml': 'name: sdk\nversion: 1.0.0\n'}),
        gitBound: false,
        hasRemote: false,
        githubRepository: null,
        platformCapabilities: const [],
      );
      final model = InitPicker(
        plan,
        (_) => fail('Reading a reason is not a decision'),
      );
      addTearDown(model.dispose);
      final tester = FleuryTester(viewportSize: const CellSize(40, 12));
      addTearDown(tester.dispose);
      tester.pumpWidget(FleuryApp(title: 'rk', home: InitScreen(model)));
      tester.pump();
      tester.sendKey(const KeyEvent(KeyCode.tab));
      tester.pump();
      tester.sendKey(const KeyEvent(KeyCode.enter));
      tester.pump();
      expect(tester.renderToString(), contains('sdk · Binary'));
      expect(tester.renderToString(), contains('Back'));
      expect(model.plan, same(plan));
      expect(model.failed, isFalse);
      tester.sendKey(const KeyEvent(KeyCode.escape));
      tester.pump();
      tester.pump();
      tester.sendKey(const KeyEvent(KeyCode.enter));
      tester.pump();
      expect(tester.renderToString(), contains('sdk · Binary'));
    },
  );
  test(
    'refresh failure retains successful action and identifies inspection failure',
    () async {
      final scratch = Directory.systemTemp.createTempSync(
        'rk-refresh-detail-test-',
      );
      addTearDown(() => scratch.deleteSync(recursive: true));
      final model = InstallationPicker(
        action: InstallationAction.install,
        states: [],
        refresh: () async => throw const FormatException('bad metadata'),
        close: () => fail('Inspection failure must remain open'),
        operate: (_, _, _, _) async => 'Installed tool from Local.',
      );
      addTearDown(model.dispose);
      await model.apply(fixture(scratch), InstallationSource.local);
      expect(model.outcomes, ['Installed tool from Local.']);
      expect(model.details?.title, 'Could not refresh installations');
      expect(model.details?.body, contains('Installed tool from Local.'));
      expect(model.details?.body, contains('bad metadata'));
      expect(model.failed, isTrue);
    },
  );
  test('compact details can page to the remedy without leaving Back', () {
    final tester = FleuryTester(viewportSize: const CellSize(40, 12));
    addTearDown(tester.dispose);
    var returned = false;
    tester.pumpWidget(
      FleuryApp(
        title: 'rk',
        home: MatrixDetails(
          command: 'rk use',
          title: 'Pub unavailable',
          body:
              '${List.generate(20, (i) => 'Detail $i').join('\n')}\nRepair: dart pub global activate tool',
          onBack: () => returned = true,
        ),
      ),
    );
    tester.pump();
    expect(tester.renderToString(), contains('More below'));
    expect(tester.renderToString(), isNot(contains('Repair:')));
    tester.sendKey(const KeyEvent(KeyCode.end));
    tester.pump();
    expect(
      tester.renderToString(),
      contains('Repair: dart pub global activate'),
    );
    expect(tester.renderToString(), contains('End · PgUp/PgDn scroll'));
    tester.sendKey(const KeyEvent(KeyCode.enter));
    expect(
      returned,
      isTrue,
      reason: 'Paging must leave the safe Back action focused.',
    );
  });

  test(
    'inspecting a reason is reversible and does not fail the command',
    () async {
      final scratch = Directory.systemTemp.createTempSync('rk-reason-test-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final project = fixture(scratch);
      final state = ProjectInstallations(project, {
        InstallationSource.pub: const SourceInspection(
          problem: 'Repair the Pub activation.',
        ),
      });
      var operations = 0, closed = false;
      final model = InstallationPicker(
        action: InstallationAction.use,
        states: [state],
        refresh: () async => [state],
        close: () => closed = true,
        operate: (_, _, _, _) async {
          operations++;
          return 'Done';
        },
      );
      addTearDown(model.dispose);
      await model.choose(state, InstallationSource.pub);
      expect(model.details?.body, 'Repair the Pub activation.');
      expect(model.failed, isFalse);
      model.exit();
      expect(model.details, isNull);
      expect(closed, isFalse);
      model.exit();
      expect(closed, isTrue);
      expect(operations, 0);
    },
  );

  test(
    'cancelling removal restores the originating row and keyboard action',
    () {
      final scratch = Directory.systemTemp.createTempSync('rk-restore-test-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final states = [
        for (var i = 0; i < 10; i++)
          ProjectInstallations(fixture(scratch, name: 'app_$i'), {
            InstallationSource.local: SourceInspection(
              installation: i == 0 || i == 9
                  ? Installation(
                      source: InstallationSource.local,
                      version: '1.0.0',
                      location: '/fixture/app_$i',
                      commands: const {},
                    )
                  : null,
            ),
          }),
      ];
      final model = InstallationPicker(
        action: InstallationAction.uninstall,
        states: states,
        refresh: () async => states,
        close: () {},
        operate: (_, _, _, _) async => 'Removed',
      );
      addTearDown(model.dispose);
      final tester = FleuryTester(viewportSize: const CellSize(90, 18));
      addTearDown(tester.dispose);
      tester.pumpWidget(
        FleuryApp(
          title: 'rk',
          theme: matrixTheme,
          home: InstallationScreen(model),
        ),
      );
      tester.pump();
      tester.sendKey(const KeyEvent(KeyCode.tab));
      tester.pump();
      tester.sendKey(const KeyEvent(KeyCode.tab));
      tester.pump();
      expect(tester.renderToString(), contains('app_9'));
      tester.sendKey(const KeyEvent(KeyCode.enter));
      tester.pump();
      expect(model.removal?.$1.name, 'app_9');
      tester.sendKey(const KeyEvent(KeyCode.escape));
      tester.pump();
      tester.pump();
      expect(model.removal, isNull);
      expect(tester.renderToString(), contains('app_9'));
      tester.sendKey(const KeyEvent(KeyCode.enter));
      tester.pump();
      expect(
        model.removal?.$1.name,
        'app_9',
        reason: 'Enter returns to the same confirmation.',
      );
    },
  );
}
