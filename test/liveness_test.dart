import 'package:release_kit/src/engine/checklist.dart';
import 'package:release_kit/src/output/output.dart';
import 'package:test/test.dart';

/// A step to hang liveness off. The checklist's own derivation is tested
/// elsewhere; what matters here is that a step being worked on reads as work.
Step aStep() => Step(
      id: 'cli/notarize/macos-arm64',
      unit: 'cli',
      project: 'keybay_cli',
      kind: StepKind.notarize,
      coordinate: 'macos-arm64',
      summary: 'notarize macos-arm64',
      needs: const ['cli/sign/macos-arm64'],
    );

/// Output writing into a buffer, with a clock the test drives.
class Harness {
  Harness({this.isTerminal = false}) {
    output = Output(
      sink: buffer.write,
      isTerminal: isTerminal,
      useColor: false,
      clock: () => () => elapsed,
    );
  }

  final bool isTerminal;
  final StringBuffer buffer = StringBuffer();
  late final Output output;

  /// What the clock reports. Set it and the next frame says so.
  var elapsed = Duration.zero;

  String get text => buffer.toString();

  /// What a terminal is left showing once the transient lines are erased.
  ///
  /// This replays the writes the way a terminal would: `\r` with a clear-line
  /// escape discards the current line, a newline commits it. It is how the
  /// "identical content" rule can be asserted rather than trusted.
  String get settled {
    final out = StringBuffer();
    var line = StringBuffer();
    var i = 0;
    while (i < text.length) {
      if (text.startsWith('\r\x1b[2K', i)) {
        line = StringBuffer();
        i += 5;
        continue;
      }
      final ch = text[i];
      if (ch == '\n') {
        out.writeln(line.toString());
        line = StringBuffer();
      } else {
        line.write(ch);
      }
      i++;
    }
    out.write(line.toString());
    return out.toString();
  }
}

void main() {
  group('off a terminal, a step is one line on completion', () {
    test('nothing is printed while it runs', () {
      final h = Harness();
      final activity = h.output.begin(aStep());
      h.elapsed = const Duration(minutes: 2);
      activity.update('waiting on Apple');
      expect(h.text, isEmpty, reason: 'a pipe sees no spinner and no counter');
    });

    test('and one line when it finishes', () {
      final h = Harness();
      final activity = h.output.begin(aStep());
      h.elapsed = const Duration(minutes: 2, seconds: 4);
      activity.done('accepted');

      expect(h.text.trim().split('\n'), hasLength(1));
      expect(h.text, contains('notarize macos-arm64'));
      expect(h.text, contains('accepted'));
      expect(h.text, isNot(contains('\x1b')));
      expect(h.text, isNot(contains('\r')));
    });
  });

  group('on a terminal, a wait says how long it has been waiting', () {
    test('the frame carries the elapsed time', () {
      final h = Harness(isTerminal: true);
      final activity = h.output.begin(aStep());
      h.elapsed = const Duration(seconds: 42);
      expect(activity.frame(), contains('42s'));
      expect(activity.frame(), contains('notarize macos-arm64'));
    });

    test('and what it is doing right now', () {
      final h = Harness(isTerminal: true);
      final activity = h.output.begin(aStep());
      activity.update('waiting on Apple');
      expect(activity.frame(), contains('waiting on Apple'));
    });

    test('a step that waits on someone else says how long that usually is', () {
      final h = Harness(isTerminal: true);
      final activity = h.output.begin(
        aStep(),
        typically: const Duration(minutes: 5),
      );
      h.elapsed = const Duration(minutes: 1);
      expect(
        activity.frame(),
        contains('typically 5m'),
        reason: 'the difference between patience and a cancelled release',
      );
    });

    test('running past that is itself surfaced', () {
      final h = Harness(isTerminal: true);
      final activity = h.output.begin(
        aStep(),
        typically: const Duration(minutes: 5),
      );
      h.elapsed = const Duration(minutes: 9);
      expect(activity.frame(), contains('longer than the usual 5m'));
    });

    test('the spinner advances so a blocked step does not look frozen', () {
      final h = Harness(isTerminal: true);
      final activity = h.output.begin(aStep());
      final first = activity.frame()[0];
      activity.update('still waiting');
      expect(activity.frame()[0], isNot(first));
    });
  });

  group('a finished step keeps only what is worth keeping', () {
    test('a duration appears when it is notable', () {
      final h = Harness();
      final activity = h.output.begin(aStep());
      h.elapsed = const Duration(minutes: 2, seconds: 4);
      activity.done('accepted');
      expect(h.text, contains('2m 4s'));
    });

    test('and not when it is not', () {
      final h = Harness();
      final activity = h.output.begin(aStep());
      h.elapsed = const Duration(milliseconds: 300);
      activity.done('accepted');
      expect(h.text, isNot(contains('0s')));
    });

    test('a failure is marked as one', () {
      final h = Harness();
      final activity = h.output.begin(aStep());
      activity.failed('Apple rejected the submission');
      expect(h.text, contains('✗'));
      expect(h.text, contains('Apple rejected'));
    });

    test('finishing twice prints once', () {
      final h = Harness();
      final activity = h.output.begin(aStep())
        ..done('accepted')
        ..done('accepted again');
      expect(h.text.trim().split('\n'), hasLength(1));
      expect(activity, isNotNull);
    });
  });

  group('the step is recorded as well as printed', () {
    test('with its duration and result', () {
      final h = Harness();
      final activity = h.output.begin(aStep());
      h.elapsed = const Duration(seconds: 90);
      activity.done('accepted');

      final json = h.output.report.encode(exit: 0);
      expect(json, contains('"id": "cli/notarize/macos-arm64"'));
      expect(json, contains('"took_ms": 90000'));
    });

    test('the verdict stays in its vocabulary and the prose goes beside it',
        () {
      final h = Harness();
      h.output.begin(aStep()).done('Apple accepted the submission');

      final json = h.output.report.encode(exit: 0);
      expect(
        json,
        contains('"verdict": "exact"'),
        reason: 'a caller keys on the verdict, so it cannot be a sentence '
            'somebody may reword',
      );
      expect(json, contains('"detail": "Apple accepted the submission"'));
    });

    test('a failure leaves the verdict unknown, not decided', () {
      final h = Harness();
      h.output.begin(aStep()).failed('the request timed out');

      expect(
        h.output.report.encode(exit: 1),
        contains('"verdict": "unknown"'),
        reason: 'rk tried and got no answer, which is not the same as having '
            'learned that nothing is there',
      );
    });
  });

  group('an unfinished step never outlives its run', () {
    test('closing prints nothing, because there is no result to report', () {
      final h = Harness(isTerminal: true);
      h.output.begin(aStep());
      h.output.close();
      expect(h.settled.trim(), isEmpty);
    });

    test('beginning another step abandons the one before it', () {
      final h = Harness(isTerminal: true);
      h.output.begin(aStep());
      h.output.begin(aStep()).done('accepted');
      expect(
        h.output.report.encode(exit: 0),
        isNot(contains('"verdict": "abandoned"')),
      );
      expect(h.settled, contains('accepted'));
    });
  });

  group('DONE WHEN: a terminal and a pipe show identical content', () {
    /// The same calls, made twice.
    String render({required bool isTerminal}) {
      final h = Harness(isTerminal: isTerminal);
      h.output.repository(name: 'keybay', branch: 'main', uncommitted: 2);
      h.output.unit('cli', version: '0.2.0', tag: 'keybay_cli-v0.2.0');
      final activity = h.output.begin(aStep());
      h.elapsed = const Duration(minutes: 2, seconds: 4);
      activity.update('waiting on Apple');
      activity.done('accepted');
      h.output.next('rk release cli');
      return h.settled;
    }

    test('once the transient lines are erased, nothing differs', () {
      expect(
        render(isTerminal: true),
        render(isTerminal: false),
        reason: 'a log, a pipe, and an agent see what the terminal ended up '
            'showing — the spinner is the only thing a terminal gets extra',
      );
    });
  });
}
