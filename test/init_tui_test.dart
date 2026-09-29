import 'package:fleury/fleury.dart';
import 'package:fleury/fleury_test_support.dart';
import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/commands/init.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/init_plan.dart';
import 'package:rk/src/engine/release_choice.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/tui/init_picker.dart';
import 'package:test/test.dart';

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 80));

String textOutput(FakeTerminalDriver driver) =>
    driver.output.replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '');

const missingPackage =
    '1 pubspec.yaml is not tracked by git — '
    'git add packages/second/pubspec.yaml to include it';

InitPlan discoveryPlan({List<String> notices = const [missingPackage]}) {
  final discovered = InitPlan.discover(
    tree: MemorySourceTree({
      'pubspec.yaml':
          'name: tool\nversion: 1.0.0\nexecutables:\n  tool: tool\n',
    }),
    gitBound: true,
    hasRemote: false,
    githubRepository: null,
    platformCapabilities: ReleaseConfig.supportedPlatformsList.map(
      HostCapabilities(
        hostPlatform: 'linux-x64',
        containerRuntime: null,
        hasNativeAssets: false,
      ).resolve,
    ),
  );
  return InitPlan(
    candidates: discovered.candidates,
    notices: notices,
    platformCapabilities: discovered.platformCapabilities,
    gitBound: discovered.gitBound,
    hasRemote: discovered.hasRemote,
    githubRepository: discovered.githubRepository,
  );
}

void main() {
  test('compact init keeps the focused output visible when notes appear', () {
    final model = InitPicker(discoveryPlan(notices: const []), (_) {});
    addTearDown(model.dispose);
    final tester = FleuryTester(viewportSize: const CellSize(40, 12));
    addTearDown(tester.dispose);
    tester.pumpWidget(FleuryApp(title: 'rk', home: InitScreen(model)));
    tester.pump();
    expect(tester.renderToString(), contains('Local build'));
    expect(tester.renderToString(), isNot(contains('Discovery notes')));

    tester.sendKey(const KeyEvent(KeyCode.tab));
    tester.type(' ');
    tester.pump();
    tester.pump();
    final output = tester.renderToString();
    expect(output, contains('Discovery notes (1)'));
    expect(output, contains('Binary enabled'));
    expect(output, contains('✓ Added'));
    expect(output, contains('Local build'));
    expect(output, contains('Review configuration'));
  });

  test('discovery notes remain available through selection and review', () async {
    final driver = FakeTerminalDriver(size: const CellSize(132, 30));
    final interaction = InitInteraction(driver: driver);
    Future<void> key(KeyEvent event) async {
      driver.enqueue(event);
      await settle();
    }

    const backwards = KeyEvent(KeyCode.tab, modifiers: {KeyModifier.shift});
    try {
      var selected = false;
      final selecting = interaction.select(discoveryPlan()).then((value) {
        selected = true;
        return value;
      });
      await settle();
      expect(driver.output, contains('Discovery notes (1)'));

      // Customize the plan before reading why another package was omitted.
      await key(const KeyEvent(KeyCode.tab));
      driver.enqueue(const TextInputEvent(' '));
      await settle();
      await key(backwards); // Review configuration.
      await key(backwards); // Cancel.
      await key(backwards); // Discovery notes.
      driver.clearOutput();
      await key(const KeyEvent(KeyCode.enter));
      expect(textOutput(driver), contains(missingPackage));
      expect(driver.output, contains('macos-arm64 was not selected'));
      expect(selected, isFalse);

      await key(const KeyEvent(KeyCode.escape));
      driver.clearOutput();
      await key(const KeyEvent(KeyCode.enter)); // Notes keeps its focus.
      expect(textOutput(driver), contains(missingPackage));
      await key(const KeyEvent(KeyCode.escape));
      await key(const KeyEvent(KeyCode.tab)); // Cancel.
      await key(const KeyEvent(KeyCode.tab)); // Review configuration.
      await key(const KeyEvent(KeyCode.enter));
      final plan = await selecting.timeout(const Duration(seconds: 3));
      expect(plan!.candidates.single.selected, contains(ReleaseChoice.binary));
      final proposal =
          '${List.generate(35, (index) => '# Review note $index').join('\n')}\n'
          '${plan.renderToml()}';
      var reviewed = false;
      final reviewing = interaction.review(proposal, true).then((value) {
        reviewed = true;
        return value;
      });
      await settle();
      expect(driver.output, contains('Discovery notes (2)'));
      await key(const KeyEvent(KeyCode.end));
      await key(const KeyEvent(KeyCode.tab)); // Create.
      await key(const KeyEvent(KeyCode.tab)); // Cancel.
      await key(const KeyEvent(KeyCode.tab)); // Discovery notes.
      driver.clearOutput();
      await key(const KeyEvent(KeyCode.enter));
      expect(textOutput(driver), contains(missingPackage));
      expect(reviewed, isFalse);

      // Escape returns to the same proposal; reading notes is not a decision.
      driver.clearOutput();
      await key(const KeyEvent(KeyCode.escape));
      expect(driver.output, contains('Review release.toml'));
      expect(driver.output, contains('binary_platforms'));
      expect(reviewed, isFalse);
      driver.clearOutput();
      await key(const KeyEvent(KeyCode.enter)); // Notes keeps its focus.
      expect(textOutput(driver), contains(missingPackage));
      await key(const KeyEvent(KeyCode.escape));
      await key(backwards); // Cancel.
      await key(backwards); // Create.
      await key(const KeyEvent(KeyCode.enter));
      expect(
        await reviewing.timeout(const Duration(seconds: 3)),
        InitReviewDecision.write,
      );
    } finally {
      await interaction.close();
      await driver.dispose();
    }
    expect(driver.restoreCallCount, 1);
  });
}
