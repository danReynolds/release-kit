import 'package:fleury/fleury.dart';
import 'package:fleury/fleury_test_support.dart';
import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/commands/init.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/init_plan.dart';
import 'package:rk/src/engine/release_choice.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/tui/init_picker.dart';
import 'package:rk/src/tui/terminal.dart';
import 'package:test/test.dart';

import 'support/screen.dart';

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

/// A command-line tool on a macOS host with a GitHub remote.
InitPlan plan() => InitPlan.discover(
  tree: MemorySourceTree({
    'pubspec.yaml': 'name: tool\nversion: 1.0.0\nexecutables:\n  tool: tool\n',
  }),
  gitBound: true,
  hasRemote: true,
  githubRepository: 'owner/repo',
  platformCapabilities: ReleaseConfig.supportedPlatformsList.map(
    HostCapabilities(
      hostPlatform: 'macos-arm64',
      containerRuntime: null,
    ).resolve,
  ),
);

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
    Future<void> key(KeyEvent event) => driver.send(event);

    const backwards = KeyEvent(KeyCode.tab, modifiers: {KeyModifier.shift});
    try {
      var selected = false;
      late Future<InitPlan?> selecting;
      await driver.redrawn(
        () => selecting = interaction.select(discoveryPlan()).then((value) {
          selected = true;
          return value;
        }),
      );
      expect(driver.output, contains('Discovery notes (1)'));

      // Customize the plan before reading why another package was omitted.
      await key(const KeyEvent(KeyCode.tab));
      await driver.send(const TextInputEvent(' '));
      await key(backwards); // Review configuration.
      await key(backwards); // Cancel.
      await key(backwards); // Discovery notes.
      driver.clearOutput();
      await key(const KeyEvent(KeyCode.enter));
      expect(textOutput(driver), contains(missingPackage));
      expect(driver.output, contains('macos-arm64 was not selected'));
      expect(selected, isFalse);

      await key(const KeyEvent(KeyCode.escape)); // Back on Discovery notes.
      await key(const KeyEvent(KeyCode.tab)); // Cancel.
      await key(const KeyEvent(KeyCode.tab)); // Review configuration.
      driver.enqueue(const KeyEvent(KeyCode.enter));
      final plan = await selecting.timeout(const Duration(seconds: 3));
      expect(plan!.candidates.single.selected, contains(ReleaseChoice.binary));
      final proposal =
          '${List.generate(35, (index) => '# Review note $index').join('\n')}\n'
          '${plan.renderToml()}';
      var reviewed = false;
      late Future<InitReviewDecision> reviewing;
      await driver.redrawn(
        () => reviewing = interaction.review(proposal, true).then((value) {
          reviewed = true;
          return value;
        }),
      );
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
      await key(backwards); // Cancel.
      await key(backwards); // Create.
      driver.enqueue(const KeyEvent(KeyCode.enter));
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

  test(
    'an unavailable output opens its reason, and Back returns to it unchanged',
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
    'selection, review, Back, and create share one terminal session',
    () async {
      final driver = FakeTerminalDriver(size: const CellSize(132, 30));
      final interaction = InitInteraction(driver: driver);
      try {
        var selecting = interaction.select(plan());
        await driver.drawn();
        for (var round = 0; round < 2; round++) {
          await driver.send(
            const KeyEvent(KeyCode.tab, modifiers: {KeyModifier.shift}),
          );
          driver.enqueue(const KeyEvent(KeyCode.enter));
          final selected = await selecting.timeout(const Duration(seconds: 3));
          expect(selected, isNotNull);
          final chosen = selected!;
          late Future<InitReviewDecision> reviewing;
          await driver.redrawn(
            () => reviewing = interaction.review(chosen.renderToml(), false),
          );
          expect(driver.restoreCallCount, 0);
          if (round == 0) {
            driver.enqueue(const KeyEvent(KeyCode.escape));
            expect(await reviewing, InitReviewDecision.back);
            await driver.redrawn(() => selecting = interaction.select(chosen));
          } else {
            await driver.send(const KeyEvent(KeyCode.tab));
            driver.enqueue(const KeyEvent(KeyCode.enter));
            expect(
              await reviewing.timeout(const Duration(seconds: 3)),
              InitReviewDecision.write,
            );
          }
        }
      } finally {
        await interaction.close();
      }
      expect(driver.restoreCallCount, 1);
      expect(driver.currentMode?.isInline, isTrue);
    },
  );

  test(
    'the keyboard toggles an output, a resize keeps the session, and Escape cancels',
    () async {
      InitPlan? result;
      final model = InitPicker(plan(), (value) {
        result = value;
        exitApp();
      });
      addTearDown(model.dispose);
      final driver = FakeTerminalDriver(size: const CellSize(130, 28));
      final done = runMatrixScreen(
        InitScreen(model),
        interrupt: () => model.finish(null),
        driver: driver,
      );
      await driver.drawn();
      await driver.send(const KeyEvent(KeyCode.tab));
      await driver.send(const TextInputEvent(' '));
      expect(
        model.plan.candidates.single.selected,
        contains(ReleaseChoice.binary),
      );
      await driver.redrawn(() => driver.resize(const CellSize(55, 24)));
      driver.enqueue(const KeyEvent(KeyCode.escape));
      await done.timeout(const Duration(seconds: 3));
      expect(result, isNull);
      expect(driver.restoreCallCount, 1);
    },
  );

  for (final (signal, code) in [
    (AppSignal.interrupt, 130),
    (AppSignal.terminate, 143),
    (AppSignal.hangup, 129),
  ]) {
    test(
      'init cancels without a proposal and preserves ${signal.name}',
      () async {
        final driver = FakeTerminalDriver(size: const CellSize(100, 20));
        final interaction = InitInteraction(driver: driver);
        final selecting = interaction.select(plan());
        await driver.drawn();
        driver.enqueue(SignalEvent(signal));
        expect(await selecting.timeout(const Duration(seconds: 3)), isNull);
        await interaction.close();
        expect(interaction.signalExitCode, code);
        expect(driver.restoreCallCount, 1);
      },
    );
  }

  test('an interrupted init review cannot authorize a write', () async {
    final driver = FakeTerminalDriver(size: const CellSize(100, 20));
    final interaction = InitInteraction(driver: driver);
    final selecting = interaction.select(plan());
    await driver.drawn();
    await driver.send(
      const KeyEvent(KeyCode.tab, modifiers: {KeyModifier.shift}),
    );
    driver.enqueue(const KeyEvent(KeyCode.enter));
    final selected = await selecting.timeout(const Duration(seconds: 3));
    late Future<InitReviewDecision> reviewing;
    await driver.redrawn(
      () => reviewing = interaction.review(selected!.renderToml(), false),
    );
    driver.enqueue(
      const KeyEvent(KeyCode.char('c'), modifiers: {KeyModifier.ctrl}),
    );
    expect(
      await reviewing.timeout(const Duration(seconds: 3)),
      InitReviewDecision.cancel,
    );
    await interaction.close();
    expect(interaction.signalExitCode, 130);
  });
}
