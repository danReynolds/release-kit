import 'dart:async';
import 'package:fleury/fleury.dart';
import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/commands/init.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/init_plan.dart';
import 'package:rk/src/engine/release_choice.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/tui/init_picker.dart';
import 'package:rk/src/tui/terminal.dart';
import 'package:test/test.dart';

import '../support/screen.dart';

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
      hasNativeAssets: false,
    ).resolve,
  ),
);

void main() {
  test(
    'an unavailable init choice reports a problem without changing the plan',
    () {
      final model = InitPicker(plan(), (_) {});
      final sdkPlan = InitPlan.discover(
        tree: MemorySourceTree({'pubspec.yaml': 'name: sdk\nversion: 1.0.0\n'}),
        gitBound: false,
        hasRemote: false,
        githubRepository: null,
        platformCapabilities: const [],
      );
      model.plan = sdkPlan;
      model.toggle(0, ReleaseChoice.binary);
      expect(model.plan, same(sdkPlan));
      expect(model.failed, isTrue);
      model.toggle(0, ReleaseChoice.pubDev);
      expect(model.failed, isFalse);
      model.dispose();
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
    'real init plan toggles dependencies and supports keyboard at wide and narrow widths',
    () async {
      for (final width in [130, 40]) {
        InitPlan? result;
        final model = InitPicker(plan(), (value) {
          result = value;
          exitApp();
        });
        final driver = FakeTerminalDriver(size: CellSize(width, 28));
        final done = runMatrixScreen(
          InitScreen(model),
          interrupt: () => model.finish(null),
          driver: driver,
        );
        await driver.drawn();
        expect(driver.currentMode!.mouse, isFalse);
        expect(driver.currentMode!.mouseMotion, isFalse);
        expect(driver.output, contains('rk init'));
        expect(driver.output, contains('Added'));
        expect(driver.output, isNot(contains('Included')));
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
        model.dispose();
      }
    },
  );

  test('Homebrew init dependency changes stay in the shared plan', () {
    final model = InitPicker(plan(), (_) {});
    model.toggle(0, ReleaseChoice.homebrew);
    expect(
      model.plan.candidates.single.selected,
      containsAll([
        ReleaseChoice.homebrew,
        ReleaseChoice.binary,
        ReleaseChoice.gitTag,
        ReleaseChoice.githubRelease,
      ]),
    );
    model.toggle(0, ReleaseChoice.gitTag);
    expect(
      model.plan.candidates.single.selected,
      isNot(contains(ReleaseChoice.homebrew)),
    );
    model.dispose();
  });

  test('init keyboard traversal reaches configuration review', () async {
    InitPlan? result;
    final model = InitPicker(plan(), (value) {
      result = value;
      exitApp();
    });
    final driver = FakeTerminalDriver(size: const CellSize(132, 30));
    final done = runMatrixScreen(
      InitScreen(model),
      interrupt: () => model.finish(null),
      driver: driver,
    );
    await driver.drawn();
    // With no initial focus, Shift+Tab starts at the last action.
    await driver.send(
      const KeyEvent(KeyCode.tab, modifiers: {KeyModifier.shift}),
    );
    driver.enqueue(const KeyEvent(KeyCode.enter));
    try {
      await done.timeout(const Duration(seconds: 3));
      expect(result, isNotNull);
    } finally {
      exitApp();
      await done;
      model.dispose();
    }
  });

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
