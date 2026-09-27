import 'dart:async';
import 'dart:io';
import 'package:fleury/fleury.dart';
import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/commands/init.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/init_plan.dart';
import 'package:rk/src/engine/release_choice.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/installations/model.dart';
import 'package:rk/src/tui/init_picker.dart';
import 'package:rk/src/tui/installation_picker.dart';
import 'package:rk/src/tui/terminal.dart';
import 'package:test/test.dart';
import 'fixtures.dart';

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 80));
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
    'selection, review, Back, and create share one terminal session',
    () async {
      final driver = FakeTerminalDriver(size: const CellSize(132, 30));
      final interaction = InitInteraction(driver: driver);
      try {
        var selecting = interaction.select(plan());
        await settle();
        for (var round = 0; round < 2; round++) {
          for (var i = 0; i < 2; i++) {
            driver.enqueue(
              const KeyEvent(KeyCode.tab, modifiers: {KeyModifier.shift}),
            );
            await settle();
          }
          driver.enqueue(const KeyEvent(KeyCode.enter));
          final selected = await selecting.timeout(const Duration(seconds: 3));
          expect(selected, isNotNull);
          final reviewing = interaction.review(selected!.renderToml(), false);
          await settle();
          expect(driver.restoreCallCount, 0);
          if (round == 0) {
            driver.enqueue(const KeyEvent(KeyCode.escape));
            expect(await reviewing, InitReviewDecision.back);
            selecting = interaction.select(selected);
            await settle();
          } else {
            driver.enqueue(const KeyEvent(KeyCode.tab));
            await settle();
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
    'a failed refresh still clears busy state and honors cancellation',
    () async {
      final scratch = Directory.systemTemp.createTempSync('rk-refresh-test-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final project = fixture(scratch);
      var closed = false;
      late InstallationPicker model;
      model = InstallationPicker(
        action: InstallationAction.use,
        states: [],
        refresh: () async => throw const FormatException('bad metadata'),
        close: () => closed = true,
        operate: (p, s, progress, cancel) async {
          model.exit();
          return 'Prepared';
        },
      );
      await model.apply(project, InstallationSource.local);
      expect(model.busy, isFalse);
      expect(model.failed, isTrue);
      expect(model.message, contains('Could not refresh'));
      expect(closed, isTrue);
      model.dispose();
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
        await settle();
        expect(driver.output, contains('rk init'));
        expect(driver.output, contains('Added'));
        expect(driver.output, isNot(contains('Included')));
        driver.enqueue(const TextInputEvent(' '));
        await settle();
        expect(
          model.plan.candidates.single.selected,
          contains(ReleaseChoice.binary),
        );
        driver.resize(const CellSize(55, 24));
        await settle();
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
    await settle();
    // The scroll viewport precedes its first cell in reading order.
    driver.enqueue(const KeyEvent(KeyCode.tab, modifiers: {KeyModifier.shift}));
    await settle();
    driver.enqueue(const KeyEvent(KeyCode.tab, modifiers: {KeyModifier.shift}));
    await settle();
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

  test(
    'Ctrl+C during preparation waits for completion and cancels selection',
    () async {
      final scratch = Directory.systemTemp.createTempSync('rk-tui-test-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final project = fixture(scratch);
      final states = [
        ProjectInstallations(project, {
          InstallationSource.local: const SourceInspection(),
          InstallationSource.pub: const SourceInspection(),
        }),
      ];
      final pending = Completer<void>();
      var operations = 0, selected = false, closed = false;
      final model = InstallationPicker(
        action: InstallationAction.use,
        states: states,
        refresh: () async => states,
        close: () {
          closed = true;
          exitApp();
        },
        operate: (p, s, progress, cancel) async {
          operations++;
          await pending.future;
          cancel.check();
          selected = true;
          return 'Selected';
        },
      );
      final driver = FakeTerminalDriver(size: const CellSize(110, 25));
      final done = runMatrixScreen(
        InstallationScreen(model),
        interrupt: model.interrupt,
        driver: driver,
      );
      await settle();
      driver.enqueue(const KeyEvent(KeyCode.enter));
      await settle();
      expect(operations, 1);
      driver.enqueue(
        const KeyEvent(KeyCode.char('c'), modifiers: {KeyModifier.ctrl}),
      );
      await settle();
      expect(closed, isFalse);
      expect(model.closing, isTrue);
      driver.enqueue(const KeyEvent(KeyCode.enter));
      await settle();
      expect(
        operations,
        1,
        reason: 'Busy controls cannot trigger a second installer.',
      );
      pending.complete();
      expect(await done.timeout(const Duration(seconds: 3)), 130);
      expect(closed, isTrue);
      expect(selected, isFalse);
      expect(driver.restoreCallCount, 1);
      model.dispose();
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
        await settle();
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
    await settle();
    driver.enqueue(const KeyEvent(KeyCode.tab, modifiers: {KeyModifier.shift}));
    await settle();
    driver.enqueue(const KeyEvent(KeyCode.tab, modifiers: {KeyModifier.shift}));
    await settle();
    driver.enqueue(const KeyEvent(KeyCode.enter));
    final selected = await selecting.timeout(const Duration(seconds: 3));
    final reviewing = interaction.review(selected!.renderToml(), false);
    await settle();
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

  test('removal requires a separate confirmation; Escape cancels it', () async {
    final scratch = Directory.systemTemp.createTempSync('rk-remove-test-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final project = fixture(scratch);
    final state = ProjectInstallations(project, {
      InstallationSource.pub: SourceInspection(
        installation: Installation(
          source: InstallationSource.pub,
          version: '1.2.0',
          location: '/test',
          commands: const {},
        ),
      ),
    });
    var removed = false;
    final model = InstallationPicker(
      action: InstallationAction.uninstall,
      states: [state],
      refresh: () async => [state],
      close: () {},
      operate: (_, __, ___, ____) async {
        removed = true;
        return 'Removed';
      },
    );
    await model.choose(state, InstallationSource.pub);
    expect(model.removal, isNotNull);
    expect(removed, isFalse);
    model.exit();
    expect(model.removal, isNull);
    expect(removed, isFalse);
    await model.choose(state, InstallationSource.pub);
    await model.apply(project, InstallationSource.pub);
    expect(removed, isTrue);
    model.dispose();
  });
}
