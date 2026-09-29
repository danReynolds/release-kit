import 'dart:async';

import 'package:fleury/fleury.dart';
import 'package:fleury/fleury_test_support.dart';
import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/commands/status.dart';
import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/targets.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/tui/status_picker.dart';
import 'package:rk/src/tui/terminal.dart';
import 'package:test/test.dart';

import 'status_test.dart' as fixtures;

StatusCommand command({
  fixtures.FixedInspector? inspector,
  StringBuffer? buffer,
  MemorySourceTree? source,
  String configuration = fixtures.config,
}) {
  final diagnostics = Diagnostics();
  source ??= fixtures.tree();
  final config = ReleaseConfig.parse(
    configuration,
    'release.toml',
    diagnostics,
  )!;
  final resolution = Resolution.resolve(config, source, diagnostics)!;
  return StatusCommand(
    resolution: resolution,
    tree: source,
    git: fixtures.git(),
    inspector:
        inspector ??
        fixtures.FixedInspector(
          registry: fixtures.FakeRegistry({}),
          git: fixtures.git(),
          answer: const Inspection.absent(),
        ),
    output: Output(sink: (buffer ?? StringBuffer()).write, isTerminal: false),
    capabilities: HostCapabilities(
      hostPlatform: 'macos-arm64',
      containerRuntime: null,
      hasNativeAssets: false,
    ),
  );
}

class GatedInspector extends fixtures.FixedInspector {
  GatedInspector()
    : super(
        registry: fixtures.FakeRegistry({}),
        git: fixtures.git(),
        answer: const Inspection.absent(),
      );
  final gates = <StepKind, Completer<void>>{};
  final started = Completer<void>();
  @override
  Future<Inspection> inspect(Step step, ResolvedUnit unit) async {
    final gate = gates.putIfAbsent(step.kind, Completer<void>.new);
    if (gates.length == 2 && !started.isCompleted) started.complete();
    await gate.future;
    return const Inspection.absent();
  }

  void finish(StepKind kind) => gates[kind]!.complete();
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 80));

void main() {
  test(
    'published destinations cannot hide source drift on the release unit',
    () async {
      final model = StatusPicker(
        load: () async => StatusReadSession(
          command(
            inspector: fixtures.FixedInspector(
              registry: fixtures.FakeRegistry({}),
              git: fixtures.git(),
              answer: const Inspection.exact(),
              latest: const Inspection.exact(evidence: {'version': '0.2.0'}),
              answers: const {
                StepKind.tag: Inspection.conflict(
                  'source differs',
                  sourceMismatch: SourceBindingMismatch(
                    releasedCommit: 'dddddddddddddddddddddddddddddddddddddddd',
                    currentCommit: fixtures.testHead,
                  ),
                ),
              },
            ),
          ),
          () {},
        ),
        close: () {},
      );
      addTearDown(model.dispose);
      await model.refresh();
      final row = model.rows.single;
      expect(statusCell(row, 'gitTag').$1, '✓ Published');
      expect(statusCell(row, 'unit').$2, '0.2.0 · changed');
      expect(
        model.issues.first.diagnostic.message,
        contains('already released'),
      );
      expect(model.snapshot!.nextCommand, isNull);
    },
  );
  test(
    'a grouped publication cell keeps each package and partial completion visible',
    () async {
      final reader = command(
        source: MemorySourceTree({
          for (final name in ['first', 'second']) ...{
            '$name/pubspec.yaml': 'name: $name\nversion: 0.2.0\n',
            '$name/CHANGELOG.md': '## 0.2.0\n',
          },
        }),
        configuration: '''
schema = 2
[release.group]
publish = []
[[release.group.project]]
path = "first"
publish = ["pub.dev"]
[[release.group.project]]
path = "second"
publish = ["pub.dev"]
''',
      );
      final model = StatusPicker(
        load: () async => StatusReadSession(reader, () {}),
        close: () {},
      );
      addTearDown(model.dispose);
      await model.refresh();
      expect(model.rows, hasLength(1));
      final row = model.rows.single;
      final first = row.plans.first;
      row.targets[first.step.id] = TargetObservation(
        expectation: first,
        inspection: const Inspection.exact(),
        currentVersion: '0.2.0',
        currentKnown: true,
        artifacts: const [],
      );
      expect(statusCell(row, 'pubDev').$1, '1/2 published');
      expect(statusCell(row, 'pubDev').$2, '2 packages');
      final detail = statusDetails(row, 'pubDev', model.snapshot);
      expect(detail, contains('pub.dev · first'));
      expect(detail, contains('pub.dev · second'));
      expect(detail, contains('Published: 0.2.0'));
      expect(detail, contains('Published: None'));
      final otherNext = StatusSnapshot(
        units: model.snapshot!.units,
        issues: const [],
        nextUnit: 'another',
        nextCommand: 'rk release another',
      );
      expect(
        statusDetails(row, 'unit', otherNext),
        isNot(contains('rk release another')),
      );
    },
  );
  test(
    'destinations update independently; completed snapshot renders without another read',
    () async {
      final inspector = GatedInspector();
      final buffer = StringBuffer();
      final reader = command(inspector: inspector, buffer: buffer);
      var closed = 0;
      final model = StatusPicker(
        load: () async => StatusReadSession(reader, () => closed++),
        close: () {},
      );
      addTearDown(model.dispose);
      final pending = model.refresh();
      await inspector.started.future;
      final row = model.rows.single;
      expect(statusCell(row, 'pubDev').$1, 'Checking…');
      inspector.finish(StepKind.tag);
      await settle();
      expect(statusCell(row, 'gitTag').$1, 'Not published');
      expect(statusCell(row, 'pubDev').$1, 'Checking…');
      expect(model.snapshot, isNull);
      expect(
        buffer.toString(),
        isEmpty,
        reason: 'inspection must not print over the TUI',
      );
      inspector.finish(StepKind.publishRegistry);
      await pending;
      expect(model.snapshot, isNotNull);
      expect(closed, 1);
      reader.render(model.snapshot!);
      expect(buffer.toString(), contains('keybay'));
      expect(inspector.gates.length, 2);
      expect(model.checking, isFalse);
    },
  );

  test(
    'cancellation during discovery disposes the eventual reader and never commits stale state',
    () async {
      final loaded = Completer<StatusReadSession>();
      var closed = 0, exited = false;
      final model = StatusPicker(
        load: () => loaded.future,
        close: () => exited = true,
      );
      final pending = model.refresh();
      model.interrupt();
      model.dispose();
      loaded.complete(StatusReadSession(command(), () => closed++));
      await pending;
      expect(closed, 1);
      expect(exited, isTrue);
      expect(model.rows, isEmpty);
      expect(model.snapshot, isNull);
    },
  );

  test(
    'cancelled readers close exactly once and ignore late target replies',
    () async {
      final inspector = GatedInspector();
      var closed = 0;
      final model = StatusPicker(
        load: () async =>
            StatusReadSession(command(inspector: inspector), () => closed++),
        close: () {},
      );
      final pending = model.refresh();
      await inspector.started.future;
      model.interrupt();
      model.dispose();
      inspector.finish(StepKind.tag);
      inspector.finish(StepKind.publishRegistry);
      await pending;
      expect(closed, 1);
      expect(model.rows.single.targets, isEmpty);
      expect(model.snapshot, isNull);
    },
  );

  test(
    'refresh owns a fresh reader; a failed discovery labels retained results as previous',
    () async {
      var opened = 0, closed = 0;
      final model = StatusPicker(
        load: () async {
          opened++;
          if (opened == 2) throw StatusLoadFailure('Invalid release.toml', 1);
          return StatusReadSession(command(), () => closed++);
        },
        close: () {},
      );
      addTearDown(model.dispose);
      await model.refresh();
      final previous = model.snapshot;
      await model.refresh();
      expect(model.snapshot, same(previous));
      expect(model.error, 'Invalid release.toml');
      await model.refresh();
      expect(model.error, isNull);
      expect(model.snapshot, isNot(same(previous)));
      expect(opened, 3);
      expect(closed, 2);
    },
  );

  test(
    'failed reads remain unknown and destination details stay scoped',
    () async {
      final reader = command(
        inspector: fixtures.FixedInspector(
          registry: fixtures.FakeRegistry({}),
          git: fixtures.git(),
          answer: const Inspection.unknown('Provider is offline'),
        ),
      );
      final model = StatusPicker(
        load: () async => StatusReadSession(reader, () {}),
        close: () {},
      );
      addTearDown(model.dispose);
      await model.refresh();
      final row = model.rows.single;
      expect(statusCell(row, 'pubDev').$1, '! Check failed');
      expect(statusCell(row, 'pubDev').$2, 'Version unknown');
      expect(model.snapshot!.nextCommand, isNull);
      final detail = statusDetails(row, 'pubDev', model.snapshot);
      expect(detail, contains('Provider is offline'));
      expect(detail, contains('pub.dev'));
      expect(detail, isNot(contains('git tag ·')));
      expect(detail, isNot(contains('Stage:')));
    },
  );

  for (final width in [132, 40]) {
    test(
      'status keys preserve destination focus across Back and resize at $width columns',
      () async {
        var closed = false;
        final model = StatusPicker(
          load: () async => StatusReadSession(command(), () {}),
          close: () => closed = true,
        );
        addTearDown(model.dispose);
        final tester = FleuryTester(viewportSize: CellSize(width, 24));
        addTearDown(tester.dispose);
        tester.pumpWidget(FleuryApp(title: 'rk', home: StatusScreen(model)));
        tester.pump();
        await Future<void>.delayed(Duration.zero);
        tester.pump();
        expect(model.snapshot, isNotNull);
        expect(tester.renderToString(), contains('rk status'));
        final buffer = tester.render();
        for (var row = 0; row < 24; row++) {
          for (var col = 0; col < width; col++) {
            expect(
              buffer.atColRow(col, row).style.background,
              isNot(const RgbColor(42, 76, 108)),
              reason: 'No focus on opening',
            );
          }
        }
        void key(KeyCode code) {
          tester.sendKey(KeyEvent(code));
          tester.pump();
          tester
              .pump(); // Paint post-frame focus restoration before the next key.
        }

        key(KeyCode.arrowDown); // Unit, then Stage, then Git tag.
        key(KeyCode.arrowRight);
        key(KeyCode.arrowRight);
        key(KeyCode.enter);
        expect(model.detail, ('core', 'gitTag'));
        expect(tester.renderToString(), contains('Back'));
        key(KeyCode.escape);
        expect(model.detail, isNull);
        key(KeyCode.enter);
        expect(model.detail, (
          'core',
          'gitTag',
        ), reason: 'Back restores the same cell');
        tester.render(size: const CellSize(40, 12));
        tester.pump();
        key(KeyCode.escape);
        key(KeyCode.escape);
        expect(closed, isTrue);
      },
    );
  }

  test(
    'a refresh that removes the inspected unit returns focus to Done',
    () async {
      final refreshed = Completer<StatusReadSession>();
      var reads = 0;
      final model = StatusPicker(
        load: () async => ++reads == 1
            ? StatusReadSession(command(), () {})
            : refreshed.future,
        close: exitApp,
      );
      final driver = FakeTerminalDriver(size: const CellSize(104, 24));
      final running = runMatrixScreen(
        StatusScreen(model),
        interrupt: model.interrupt,
        driver: driver,
      );
      try {
        await settle();
        driver.enqueue(const KeyEvent(KeyCode.arrowDown));
        await settle();
        final pending = model.refresh();
        model.inspect(('core', 'unit'));
        await settle();
        refreshed.complete(
          StatusReadSession(
            command(
              configuration: fixtures.config.replaceFirst(
                '[release.core]',
                '[release.other]',
              ),
            ),
            () {},
          ),
        );
        await pending;
        await settle();
        expect(model.rows.single.unit.name, 'other');
        expect(model.detail, isNull);
        driver.enqueue(const KeyEvent(KeyCode.enter));
        expect(await running.timeout(const Duration(seconds: 3)), 0);
      } finally {
        exitApp();
        await running;
        model.dispose();
      }
    },
  );
}
