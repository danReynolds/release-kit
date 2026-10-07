import 'dart:async';

import 'package:rk/src/engine/timings.dart';
import 'package:test/test.dart';

/// The maintainer trace (`RK_TIMINGS=1`) has to charge work to the right
/// span even when the work interleaves, or it points at the wrong step.
void main() {
  var now = Duration.zero;

  setUp(() {
    now = Duration.zero;
    Timings.startRecording(clock: () => now);
  });
  tearDown(Timings.stopRecording);

  List<String> lines() => Timings.reportText()!.trimRight().split('\n');

  test('recording off, every call runs its body and records nothing', () async {
    Timings.stopRecording();
    expect(await Timings.span('a', () async => 1), 1);
    expect(Timings.spanSync('b', () => 2), 2);
    expect(Timings.timeTally('c', () => 3), 3);
    expect(await Timings.timeTallyAsync('d', () async => 4), 4);
    Timings.tally('e');
    expect(Timings.reportText(), isNull);
  });

  test('spans nest across awaits and concurrent futures', () async {
    await Timings.span('outer', () async {
      await Future.wait([
        Timings.span('first', () async {
          await Future<void>.delayed(Duration.zero);
          now += const Duration(milliseconds: 1500);
          Timings.tally('sha256', bytes: 2000000);
        }),
        Timings.span('second', () async {
          await Future<void>.delayed(Duration.zero);
          Timings.tally('sha256', bytes: 1000000);
        }),
      ]);
    });

    expect(lines(), [
      'rk timings (wall clock; nested spans overlap their parent)',
      '  0.000s +1.500s    rk',
      '    0.000s +1.500s    outer',
      '      0.000s +1.500s    first',
      '               = 0.000s    sha256 × 1, 2.0 MB',
      '      0.000s +1.500s    second',
      '               = 0.000s    sha256 × 1, 1.0 MB',
    ]);
  });

  test('a timed tally is charged to the span it ran in', () {
    Timings.spanSync('hashing', () {
      Timings.timeTally('sha256', () {
        now += const Duration(milliseconds: 250);
      }, bytes: 500000);
    });

    expect(lines(), [
      'rk timings (wall clock; nested spans overlap their parent)',
      '  0.000s +0.250s    rk',
      '    0.000s +0.250s    hashing',
      '             = 0.250s    sha256 × 1, 0.5 MB',
    ]);
  });

  test(
    'a span whose body throws before returning a future still ends',
    () async {
      await expectLater(
        Timings.span<void>('refused', () => throw StateError('no')),
        throwsStateError,
      );

      expect(Timings.reportText(), isNot(contains('unfinished')));
    },
  );

  test('an async tally names the caller that started it', () async {
    Timings.startRecording(clock: () => now, callers: true);
    Future<int> readsSomething() =>
        Timings.timeTallyAsync('tool git', () async {
          await Future<void>.delayed(Duration.zero);
          return 1;
        });

    await readsSomething();

    expect(Timings.reportText(), contains('tool git  ← main.'));
    expect(Timings.reportText(), isNot(contains('← ?')));
  });

  test('a command run again and again is one tally', () {
    expect(
      processTally('/sdk/bin/dart', ['/tmp/rk-dart-sdk-AbC/sdk.dart']),
      'dart',
    );
    expect(
      processTally('git', ['show', 'HEAD:pubspec.yaml']),
      processTally('git', ['show', 'HEAD:packages/core/pubspec.yaml']),
    );
    expect(processTally('git', ['show', 'HEAD:a']), 'git show');
    expect(processTally('/sdk/bin/dart', ['--version']), 'dart --version');
    expect(
      processTally('git', ['ls-remote', 'origin', 'refs/tags/v1']),
      'git ls-remote origin',
    );
  });

  test('an unfinished span says so', () async {
    final pending = Completer<void>();
    final waiting = Timings.span('waiting', () => pending.future);
    await Future<void>.delayed(Duration.zero);

    expect(Timings.reportText(), contains('+unfinished waiting'));
    pending.complete();
    await waiting;
  });
}
