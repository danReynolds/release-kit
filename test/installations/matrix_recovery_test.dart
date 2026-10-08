import 'package:fleury/fleury.dart';
import 'package:fleury/fleury_test_support.dart';
import 'package:rk/src/engine/init_plan.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/tui/init_picker.dart';
import 'package:rk/src/tui/matrix.dart';
import 'package:test/test.dart';

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
}
