import 'package:rk/src/commands/stage_check_progress.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/output/output.dart';
import 'package:test/test.dart';

/// The repository-wide stage check used to print nothing at all, often for
/// tens of seconds, between the last "Releasing" heading and the
/// preparation order.
void main() {
  late List<ResolvedUnit> units;
  late ResolvedUnit core;
  late ResolvedUnit cli;

  setUp(() {
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse(
      '''
schema = 2

[release.core]
path = "packages/core"
publish = ["pub.dev"]

[release.cli]
path = "packages/cli"
publish = ["pub.dev"]
''',
      'release.toml',
      diagnostics,
    )!;
    units = Resolution.resolve(
      config,
      MemorySourceTree({
        'packages/core/pubspec.yaml': 'name: core\nversion: 1.0.0\n',
        'packages/cli/pubspec.yaml': 'name: cli\nversion: 2.0.0\n',
      }),
      diagnostics,
    )!.units;
    core = units.singleWhere((unit) => unit.name == 'core');
    cli = units.singleWhere((unit) => unit.name == 'cli');
  });

  ({StringBuffer text, Output output}) harness({required bool terminal}) {
    final text = StringBuffer();
    final output = Output(
      sink: text.write,
      isTerminal: terminal,
      useColor: false,
      terminalWidth: terminal ? 100 : null,
    );
    return (text: text, output: output);
  }

  Future<void> pause() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  test('a slow check shows each unit and what it is doing', () async {
    final (:text, :output) = harness(terminal: true);
    final checking = StageCheckProgress(
      output,
      units: units,
      delay: const Duration(milliseconds: 5),
    );

    checking.restoring(core);
    await pause();
    expect(text.toString(), contains('Checking stages'));
    expect(text.toString(), contains('core 1.0.0'));
    expect(text.toString(), contains('saved stage'));
    expect(text.toString(), contains('verifying'));

    checking
      ..restored(core, found: true)
      ..restoring(cli)
      ..restored(cli, found: false);
    await pause();
    expect(text.toString(), contains('verified'));
    expect(text.toString(), contains('none'));

    await checking.checkingPublicTargets(core, () async {
      await pause();
      expect(text.toString(), contains('public targets'));
      expect(text.toString(), contains('checking · core 1.0.0'));
    });
    checking.publicTargetsChecked();

    checking.discovering(cli);
    await pause();
    expect(text.toString(), contains('dependencies'));
    expect(text.toString(), contains('resolving'));

    checking
      ..discovered(cli)
      ..finish();
    output.close();
  });

  test('a fast check prints nothing to a pipe', () async {
    final (:text, :output) = harness(terminal: false);
    final checking = StageCheckProgress(
      output,
      units: units,
      delay: const Duration(seconds: 1),
    );
    checking
      ..restoring(core)
      ..restored(core, found: true)
      ..restoring(cli)
      ..restored(cli, found: true)
      ..finish();
    output.close();

    expect(text.toString(), isEmpty);
  });

  test('a slow unit is printed to a pipe once, then its result', () async {
    final (:text, :output) = harness(terminal: false);
    final checking = StageCheckProgress(
      output,
      units: units,
      delay: const Duration(milliseconds: 5),
    );
    checking.restoring(core);
    await pause();
    checking
      ..restored(core, found: true)
      ..restoring(cli)
      ..restored(cli, found: true)
      ..finish();
    output.close();

    final printed = text.toString();
    expect(RegExp('verifying').allMatches(printed), hasLength(1));
    expect(printed, contains('core 1.0.0'));
    expect(printed, contains('verified'));
    expect(printed, isNot(contains('\x1b')));
    expect(printed, isNot(contains('\r')));
  });

  // Each row is active only while its own unit's work runs, so a stop
  // fails what was running and leaves every other row as it was found.
  group('a refusal marks only the work that was running', () {
    test('a stage that would not verify', () {
      final (:text, :output) = harness(terminal: false);
      final checking = StageCheckProgress(
        output,
        units: units,
        delay: const Duration(seconds: 1),
      );
      checking
        ..restoring(core)
        ..stop();
      output.close();

      expect(text.toString(), contains('verification failed'));
      expect(
        text.toString(),
        matches(RegExp(r'cli 2\.0\.0 · saved stage +not attempted')),
      );
    });

    test('a public target read that refused', () async {
      final (:text, :output) = harness(terminal: false);
      final checking = StageCheckProgress(
        output,
        units: units,
        delay: const Duration(seconds: 1),
      );
      checking
        ..restoring(core)
        ..restored(core, found: true)
        ..restoring(cli)
        ..restored(cli, found: false);
      await expectLater(
        checking.checkingPublicTargets(cli, () async => throw StateError('no')),
        throwsStateError,
      );
      checking.stop();
      output.close();

      final printed = text.toString();
      expect(printed, matches(RegExp(r'core 1\.0\.0 · saved stage +verified')));
      expect(printed, matches(RegExp(r'cli 2\.0\.0 · saved stage +none')));
      expect(printed, matches(RegExp(r'public targets +check failed')));
      expect(RegExp('failed').allMatches(printed), hasLength(1));
    });

    test('dependencies that would not resolve', () {
      final (:text, :output) = harness(terminal: false);
      final checking = StageCheckProgress(
        output,
        units: units,
        delay: const Duration(seconds: 1),
      );
      checking
        ..restoring(core)
        ..restored(core, found: false)
        ..restoring(cli)
        ..restored(cli, found: false)
        ..discovering(core)
        ..discovered(core)
        ..discovering(cli)
        ..stop();
      output.close();

      final printed = text.toString();
      expect(
        printed,
        matches(RegExp(r'core 1\.0\.0 · dependencies +resolved')),
      );
      expect(
        printed,
        matches(RegExp(r'cli 2\.0\.0 · dependencies +resolution failed')),
      );
      expect(RegExp('failed').allMatches(printed), hasLength(1));
    });

    test('a failure after every unit was checked', () {
      final (:text, :output) = harness(terminal: false);
      final checking = StageCheckProgress(
        output,
        units: units,
        delay: const Duration(seconds: 1),
      );
      checking
        ..restoring(core)
        ..restored(core, found: true)
        ..restoring(cli)
        ..restored(cli, found: false)
        ..discovering(cli)
        ..discovered(cli)
        ..stop();
      output.close();

      expect(text.toString(), isNot(contains('failed')));
    });
  });

  test('a sibling checked as a provider gets its own row', () {
    final (:text, :output) = harness(terminal: false);
    final checking = StageCheckProgress(
      output,
      units: [cli],
      delay: const Duration(seconds: 1),
    );
    checking
      ..restoring(cli)
      ..restored(cli, found: true)
      ..restoring(core)
      ..restored(core, found: true)
      ..stop();
    output.close();

    expect(
      text.toString(),
      matches(RegExp(r'core 1\.0\.0 · saved stage +verified')),
    );
  });
}
